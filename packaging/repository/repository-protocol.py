#!/usr/bin/env python3
"""Create and verify immutable Gooarchy builder-to-signer transfer manifests."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
from pathlib import Path
from typing import Any

# The protocol runs from a required-clean checkout; importing the database reader must not dirty it.
sys.dont_write_bytecode = True

SCHEMA = "gooarchy-repository-transfer-v2"
LEGACY_SCHEMA = "gooarchy-repository-transfer-v1"
SIGNATURE_SCHEMA = "gooarchy-repository-signatures-v1"
PACKAGE_INPUT_SCHEMA = "gooarchy-prebuilt-package-v1"
SCOTTLAND_PAIR_SCHEMA = "gooarchy-scottland-pair-input-v1"
REPOSITORY = "clickety-clacks/gooarchy"
FLAVORINGS_REPOSITORY = "clickety-clacks/gooarchy-flavorings"
SCOTTLAND_REPOSITORY = "clickety-clacks/scottland"
SCOTTLAND_PACKAGE_NAMES = {"scottland", "scottland-omarchy"}
PACKAGE_ORIGINS = {"source-build", "prebuilt-input", "upstream-release", "retained-release"}
SCOTTLAND_PAIR_PIN = {
    "source": {
        "repository": SCOTTLAND_REPOSITORY,
        "tag": "v0.3.4",
        "commit": "bbf09cbd6b9cb80adc9d7fa0a7cf88f6c8641f25",
        "tree": "33f1fe1bde2e647606134661db377a291829677f",
        "release_url": "https://github.com/clickety-clacks/scottland/releases/tag/v0.3.4",
        "source_pkgbuild_sha256": "aabf2369223c39f8a1f0e90deece23c72eb01612e0c16bd85d01ecdae6ef2f39",
    },
    "checksums": {
        "filename": "SHA256SUMS",
        "sha256": "969be4b5d480e9a762f9434d41dfb50e3b73f80deb50b37f4eb66b2031598e24",
    },
    "packages": {
        "scottland": {
            "name": "scottland",
            "version": "0.3.4-1",
            "architecture": "x86_64",
            "filename": "scottland-0.3.4-1-x86_64.pkg.tar.zst",
            "sha256": "e6a1bf08b324ba01a38bbbdb633156827ec7cd6144c0b1dcb120d6b7fc902986",
            "packager": "Unknown Packager",
            "pkgbuild_sha256": "5c7258994a4c8c780573b29c3659c54061809e80fc1c4345bcb6b68f8195fa14",
            "wayfire_build": "0.11.0-1",
            "required_dependency": "wayfire",
        },
        "scottland-omarchy": {
            "name": "scottland-omarchy",
            "version": "0.3.4-1",
            "architecture": "any",
            "filename": "scottland-omarchy-0.3.4-1-any.pkg.tar.zst",
            "sha256": "c25611cd270bbf7dcfb5012a89223029f790e9a645c7bd6794b167dd2bd8f832",
            "packager": "Unknown Packager",
            "pkgbuild_sha256": "5c7258994a4c8c780573b29c3659c54061809e80fc1c4345bcb6b68f8195fa14",
            "wayfire_build": "0.11.0-1",
            "required_dependency": "scottland=0.3.4-1",
        },
    },
}
FINGERPRINT_RE = re.compile(r"^(?:[0-9A-F]{40}|[0-9A-F]{64})$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
VERSION_TAG_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
ASSET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+:-]*$")
REQUIRED_INITIAL = {
    "gooarchy",
    "gooarchy-flavorings",
    "scottland",
    "xdg-desktop-portal-wlr-gooarchy",
    "linux-gooarchy",
    "linux-gooarchy-headers",
}


def fail(message: str) -> None:
    raise ValueError(message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_asset_name(value: Any) -> str:
    if not isinstance(value, str) or not ASSET_RE.fullmatch(value):
        fail(f"unsafe asset filename: {value!r}")
    if value in {".", ".."} or ".." in value or value.endswith("."):
        fail(f"unsafe asset filename: {value!r}")
    return value


def load_database_reader() -> Any:
    path = Path(__file__).with_name("read-db.py")
    spec = importlib.util.spec_from_file_location("gooarchy_read_db", path)
    if spec is None or spec.loader is None:
        fail("could not load the repository database reader")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def database_records(database: Path) -> list[tuple[str, str, str]]:
    return load_database_reader().records(database)


def parse_package_info(text: str, source: str) -> dict[str, str]:
    fields: dict[str, list[str]] = {}
    for line in text.splitlines():
        if " = " not in line:
            continue
        key, value = line.split(" = ", 1)
        fields.setdefault(key, []).append(value)
    for field in ("pkgname", "pkgver", "arch", "packager"):
        if len(fields.get(field, [])) != 1 or not fields[field][0]:
            fail(f"{source} must contain exactly one non-empty {field} field")
    return {
        "name": fields["pkgname"][0],
        "version": fields["pkgver"][0],
        "arch": fields["arch"][0],
        "packager": fields["packager"][0],
    }


def package_info(path: Path) -> dict[str, str]:
    completed = subprocess.run(
        ["bsdtar", "-xOf", str(path), ".PKGINFO"],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        fail(f"cannot read package metadata from {path.name}")
    return parse_package_info(completed.stdout, path.name)


def build_info(path: Path) -> dict[str, str]:
    completed = subprocess.run(
        ["bsdtar", "-xOf", str(path), ".BUILDINFO"],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        fail(f"cannot read build metadata from {path.name}")
    fields: dict[str, list[str]] = {}
    for line in completed.stdout.splitlines():
        if " = " not in line:
            continue
        key, value = line.split(" = ", 1)
        fields.setdefault(key, []).append(value)
    for field in ("pkgname", "pkgver", "pkgarch", "packager", "pkgbuild_sha256sum"):
        if len(fields.get(field, [])) != 1 or not fields[field][0]:
            fail(f"{path.name} build metadata must contain exactly one non-empty {field} field")
    return {
        "name": fields["pkgname"][0],
        "version": fields["pkgver"][0],
        "arch": fields["pkgarch"][0],
        "packager": fields["packager"][0],
        "pkgbuild_sha256": fields["pkgbuild_sha256sum"][0],
    }


def build_info_details(path: Path) -> dict[str, Any]:
    """Return the pinned build identity plus repeated installed package records."""
    completed = subprocess.run(
        ["bsdtar", "-xOf", str(path), ".BUILDINFO"],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        fail(f"cannot read build metadata from {path.name}")
    fields: dict[str, list[str]] = {}
    for line in completed.stdout.splitlines():
        if " = " not in line:
            continue
        key, value = line.split(" = ", 1)
        fields.setdefault(key, []).append(value)
    identity = build_info(path)
    installed = fields.get("installed", [])
    return {**identity, "installed": installed}


def package_dependencies(path: Path) -> list[str]:
    completed = subprocess.run(
        ["bsdtar", "-xOf", str(path), ".PKGINFO"],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        fail(f"cannot read package metadata from {path.name}")
    return [
        line.split(" = ", 1)[1]
        for line in completed.stdout.splitlines()
        if line.startswith("depend = ")
    ]


def scottland_pair_manifest_path() -> Path:
    return Path(__file__).with_name("scottland-v0.3.4-input.json")


def load_scottland_pair_manifest(path: Path | None = None) -> dict[str, Any]:
    """Read the reviewed upstream asset pins and reject ambiguous pair metadata."""
    manifest_path = path or scottland_pair_manifest_path()
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read Scottland pair input manifest: {error}")
    if not isinstance(manifest, dict) or set(manifest) != {"schema", "source", "checksums", "packages"}:
        fail("Scottland pair input manifest has invalid fields")
    if manifest["schema"] != SCOTTLAND_PAIR_SCHEMA:
        fail("Scottland pair input manifest has the wrong schema")
    if (
        manifest["source"] != SCOTTLAND_PAIR_PIN["source"]
        or manifest["checksums"] != SCOTTLAND_PAIR_PIN["checksums"]
    ):
        fail("Scottland pair input manifest differs from the pinned upstream source or release checksum")
    source = manifest["source"]
    source_fields = {
        "repository", "tag", "commit", "tree", "release_url", "source_pkgbuild_sha256"
    }
    if not isinstance(source, dict) or set(source) != source_fields:
        fail("Scottland source identity has invalid fields")
    if source["repository"] != SCOTTLAND_REPOSITORY or source["tag"] != "v0.3.4":
        fail("Scottland source identity is not the reviewed upstream release")
    if (
        not isinstance(source["commit"], str) or not COMMIT_RE.fullmatch(source["commit"])
        or not isinstance(source["tree"], str) or not COMMIT_RE.fullmatch(source["tree"])
    ):
        fail("Scottland source commit or tree is invalid")
    if source["release_url"] != f"https://github.com/{SCOTTLAND_REPOSITORY}/releases/tag/{source['tag']}":
        fail("Scottland release URL does not match its pinned repository and tag")
    if not isinstance(source["source_pkgbuild_sha256"], str) or not SHA256_RE.fullmatch(source["source_pkgbuild_sha256"]):
        fail("Scottland source PKGBUILD hash is invalid")
    checksums = manifest["checksums"]
    if not isinstance(checksums, dict) or set(checksums) != {"filename", "sha256"}:
        fail("Scottland checksum record has invalid fields")
    if checksums["filename"] != "SHA256SUMS" or not isinstance(checksums["sha256"], str) or not SHA256_RE.fullmatch(checksums["sha256"]):
        fail("Scottland checksum identity is invalid")
    packages = manifest["packages"]
    if not isinstance(packages, list) or len(packages) != 2:
        fail("Scottland input must pin exactly the core and adapter packages")
    observed: dict[str, dict[str, Any]] = {}
    required_fields = {
        "name", "version", "architecture", "filename", "sha256", "packager",
        "pkgbuild_sha256", "wayfire_build", "required_dependency",
    }
    for package in packages:
        if not isinstance(package, dict) or set(package) != required_fields:
            fail("Scottland package input has invalid fields")
        name = package["name"]
        if not isinstance(name, str):
            fail("Scottland package name is invalid")
        expected = {
            "scottland": ("0.3.4-1", "x86_64", "wayfire"),
            "scottland-omarchy": ("0.3.4-1", "any", "scottland=0.3.4-1"),
        }.get(name)
        if expected is None or name in observed:
            fail("Scottland input must contain each pinned package exactly once")
        if (package["version"], package["architecture"], package["required_dependency"]) != expected:
            fail(f"Scottland package identity or dependency pin is invalid for {name}")
        expected_filename = f"{name}-{expected[0]}-{expected[1]}.pkg.tar.zst"
        if package["filename"] != expected_filename:
            fail(f"Scottland package filename is invalid for {name}")
        safe_asset_name(package["filename"])
        if not isinstance(package["sha256"], str) or not SHA256_RE.fullmatch(package["sha256"]):
            fail(f"Scottland package hash is invalid for {name}")
        if package["packager"] != "Unknown Packager":
            fail(f"Scottland upstream packager identity is invalid for {name}")
        if not isinstance(package["pkgbuild_sha256"], str) or not SHA256_RE.fullmatch(package["pkgbuild_sha256"]):
            fail(f"Scottland build recipe hash is invalid for {name}")
        if package["wayfire_build"] != "0.11.0-1":
            fail(f"Scottland build Wayfire identity is invalid for {name}")
        if package != SCOTTLAND_PAIR_PIN["packages"][name]:
            fail(f"Scottland package metadata differs from the pinned release asset: {name}")
        observed[name] = package
    if set(observed) != SCOTTLAND_PACKAGE_NAMES:
        fail("Scottland input is missing a member of the reviewed package pair")
    return manifest


def scottland_source_revision(manifest: dict[str, Any], package: dict[str, Any]) -> str:
    source = manifest["source"]
    source_pkgbuild_matches_buildinfo = source["source_pkgbuild_sha256"] == package["pkgbuild_sha256"]
    return (
        f"upstream release asset; repository:{source['repository']}; tag:{source['tag']}; "
        f"commit:{source['commit']}; tree:{source['tree']}; "
        f"release-checksums-sha256:{manifest['checksums']['sha256']}; "
        f"source-PKGBUILD-sha256:{source['source_pkgbuild_sha256']}; "
        f"embedded-BUILDINFO-PKGBUILD-sha256:{package['pkgbuild_sha256']}; "
        f"source-PKGBUILD-matches-BUILDINFO:{'yes' if source_pkgbuild_matches_buildinfo else 'no'}; "
        f"asset:{package['filename']} sha256:{package['sha256']}"
    )


def verify_scottland_pair_package(
    archive: Path, package: dict[str, Any]
) -> None:
    if archive.is_symlink() or not archive.is_file():
        fail(f"Scottland package is not a regular file: {archive.name}")
    if sha256_file(archive) != package["sha256"]:
        fail(f"Scottland package hash does not match its pin: {archive.name}")
    expected_info = {
        "name": package["name"], "version": package["version"],
        "arch": package["architecture"], "packager": package["packager"],
    }
    if package_info(archive) != expected_info:
        fail(f"Scottland .PKGINFO does not match its pinned identity: {package['name']}")
    expected_build = {
        "name": package["name"], "version": package["version"],
        "arch": package["architecture"], "packager": package["packager"],
        "pkgbuild_sha256": package["pkgbuild_sha256"],
    }
    build = build_info_details(archive)
    if any(build.get(key) != value for key, value in expected_build.items()):
        fail(f"Scottland .BUILDINFO does not match its pinned build evidence: {package['name']}")
    expected_wayfire = f"wayfire-{package['wayfire_build']}-x86_64"
    installed_wayfire = [value for value in build["installed"] if value.startswith("wayfire-")]
    if installed_wayfire != [expected_wayfire]:
        fail(f"Scottland .BUILDINFO does not match its pinned build evidence: {package['name']}")
    if package_dependencies(archive).count(package["required_dependency"]) != 1:
        fail(f"Scottland dependency metadata does not match its pin: {package['name']}")


def verify_scottland_pair_input(directory: Path, manifest_path: Path | None = None) -> dict[str, Any]:
    if directory.is_symlink() or not directory.is_dir():
        fail("Scottland pair input must be a real directory")
    manifest = load_scottland_pair_manifest(manifest_path)
    source_pkgbuild = directory / "PKGBUILD"
    if source_pkgbuild.is_symlink() or not source_pkgbuild.is_file():
        fail("Scottland pair input is missing the pinned upstream PKGBUILD")
    if sha256_file(source_pkgbuild) != manifest["source"]["source_pkgbuild_sha256"]:
        fail("Scottland upstream PKGBUILD does not match the pinned release source")
    checksum_path = directory / manifest["checksums"]["filename"]
    if checksum_path.is_symlink() or not checksum_path.is_file():
        fail("Scottland pair input is missing its pinned SHA256SUMS file")
    if sha256_file(checksum_path) != manifest["checksums"]["sha256"]:
        fail("Scottland SHA256SUMS does not match its pinned release digest")
    expected_sums = [
        f"{item['sha256']}  {item['filename']}"
        for item in sorted(manifest["packages"], key=lambda entry: entry["filename"])
    ]
    try:
        actual_sums = checksum_path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError) as error:
        fail(f"cannot read Scottland SHA256SUMS: {error}")
    if actual_sums != expected_sums:
        fail("Scottland SHA256SUMS entries do not match the pinned package pair")
    records: dict[str, dict[str, Any]] = {}
    for package in manifest["packages"]:
        archive = directory / package["filename"]
        if not archive.exists():
            fail(f"Scottland pair input is missing a regular archive: {package['filename']}")
        verify_scottland_pair_package(archive, package)
        records[package["name"]] = {
            **package,
            "source_revision": scottland_source_revision(manifest, package),
            "origin_kind": "upstream-release",
        }
    return {"source": manifest["source"], "checksums": manifest["checksums"], "packages": records}


def stage_scottland_pair_input(
    directory: Path, output_directory: Path, manifest_path: Path | None = None
) -> dict[str, Any]:
    """Copy the two verified release assets without changing their bytes."""
    if output_directory.is_symlink() or not output_directory.is_dir():
        fail("Scottland staging output must be a real directory")
    if not hasattr(os, "O_NOFOLLOW"):
        fail("safe Scottland input staging requires O_NOFOLLOW support")
    source_record = verify_scottland_pair_input(directory, manifest_path)
    manifest = load_scottland_pair_manifest(manifest_path)
    created: list[Path] = []
    try:
        for package in manifest["packages"]:
            source = directory / package["filename"]
            destination = output_directory / package["filename"]
            if destination.exists() or destination.is_symlink():
                fail(f"staged Scottland package already exists: {destination.name}")
            source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            output_fd = -1
            created_output = False
            try:
                if not stat.S_ISREG(os.fstat(source_fd).st_mode):
                    fail(f"Scottland input is not a regular file: {source.name}")
                output_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                created_output = True
                created.append(destination)
                with os.fdopen(source_fd, "rb") as source_stream:
                    source_fd = -1
                    with os.fdopen(output_fd, "wb") as destination_stream:
                        output_fd = -1
                        shutil.copyfileobj(source_stream, destination_stream)
                os.chmod(destination, 0o400)
            except BaseException:
                if created_output:
                    destination.unlink(missing_ok=True)
                    if destination in created:
                        created.remove(destination)
                raise
            finally:
                if source_fd >= 0:
                    os.close(source_fd)
                if output_fd >= 0:
                    os.close(output_fd)
        for package in manifest["packages"]:
            verify_scottland_pair_package(output_directory / package["filename"], package)
        return source_record
    except BaseException:
        for path in created:
            path.unlink(missing_ok=True)
        raise


def flavorings_recipe_identity(recipe_path: Path) -> dict[str, Any]:
    text = recipe_path.read_text(encoding="utf-8")

    def assignment(name: str) -> str:
        matches = re.findall(rf"(?m)^{re.escape(name)}=([^\r\n]*)$", text)
        if len(matches) != 1 or not matches[0]:
            fail(f"Flavorings recipe must define exactly one {name}")
        return matches[0]

    package = assignment("pkgname")
    tag = assignment("_tag")
    pkgver = assignment("pkgver")
    pkgrel = assignment("pkgrel")
    commit = assignment("_upstream_commit")
    tree = assignment("_upstream_tree")
    archive_sha256 = assignment("_upstream_archive_sha256")
    if package != "gooarchy-flavorings":
        fail("Flavorings recipe has an unexpected package name")
    if not VERSION_TAG_RE.fullmatch(tag) or pkgver != tag[1:] or not re.fullmatch(r"[0-9]+", pkgrel):
        fail("Flavorings recipe tag and package version do not agree")
    if not COMMIT_RE.fullmatch(commit) or not COMMIT_RE.fullmatch(tree):
        fail("Flavorings recipe source commit or tree identity is invalid")
    if not SHA256_RE.fullmatch(archive_sha256):
        fail("Flavorings recipe source archive hash is invalid")
    return {
        "package": package,
        "pkgver": pkgver,
        "pkgrel": pkgrel,
        "version": f"{pkgver}-{pkgrel}",
        "source": {
            "repository": FLAVORINGS_REPOSITORY,
            "tag": tag,
            "commit": commit,
            "tree": tree,
            "archive_sha256": archive_sha256,
        },
    }


def verify_flavorings_input(archive: Path, manifest_path: Path, recipe_path: Path) -> dict[str, Any]:
    if archive.is_symlink() or not archive.is_file():
        fail("prebuilt Flavorings input must be a regular package archive")
    expected = flavorings_recipe_identity(recipe_path)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    required = {"schema", "package", "version", "architecture", "filename", "sha256", "packager", "pkgbuild_sha256", "source"}
    if not isinstance(manifest, dict) or set(manifest) != required:
        fail("prebuilt Flavorings manifest has invalid fields")
    if manifest["schema"] != PACKAGE_INPUT_SCHEMA or manifest["package"] != "gooarchy-flavorings":
        fail("prebuilt input is not the supported gooarchy-flavorings package")
    source = manifest["source"]
    source_fields = {"repository", "tag", "commit", "tree", "archive_sha256"}
    if not isinstance(source, dict) or set(source) != source_fields:
        fail("prebuilt Flavorings source identity has invalid fields")
    if source["repository"] != FLAVORINGS_REPOSITORY:
        fail("prebuilt Flavorings source repository is not the reviewed upstream")
    if source != expected["source"]:
        fail("prebuilt Flavorings source identity does not match the current recipe")
    if manifest["version"] != expected["version"]:
        fail("prebuilt Flavorings package version does not match the current recipe")
    if manifest["architecture"] != "any" or manifest["packager"] != "Gooarchy":
        fail("prebuilt Flavorings architecture or packager is not eligible")
    if not isinstance(manifest["filename"], str) or manifest["filename"] != (
        f"gooarchy-flavorings-{expected['version']}-any.pkg.tar.zst"
    ):
        fail("prebuilt Flavorings filename does not match its package identity")
    safe_asset_name(manifest["filename"])
    if archive.name != manifest["filename"]:
        fail("prebuilt Flavorings archive filename does not match its manifest")
    if not isinstance(manifest["sha256"], str) or not SHA256_RE.fullmatch(manifest["sha256"]):
        fail("prebuilt Flavorings package hash is invalid")
    if not isinstance(manifest["pkgbuild_sha256"], str) or not SHA256_RE.fullmatch(manifest["pkgbuild_sha256"]):
        fail("prebuilt Flavorings PKGBUILD hash is invalid")
    if sha256_file(archive) != manifest["sha256"]:
        fail("prebuilt Flavorings package hash does not match its manifest")

    package = package_info(archive)
    build = build_info(archive)
    package_expected = {
        "name": "gooarchy-flavorings",
        "version": expected["version"],
        "arch": "any",
        "packager": "Gooarchy",
    }
    if package != package_expected:
        fail("prebuilt Flavorings .PKGINFO does not match the reviewed package identity")
    if build != {
        **package_expected,
        "pkgbuild_sha256": manifest["pkgbuild_sha256"],
    }:
        fail("prebuilt Flavorings .BUILDINFO does not match its reviewed build identity")
    return manifest


def flavorings_source_revision(manifest: dict[str, Any]) -> str:
    source = manifest["source"]
    return (
        f"Flavorings tag:{source['tag']} commit:{source['commit']} tree:{source['tree']}; "
        f"source archive SHA256:{source['archive_sha256']}; "
        f"PKGBUILD SHA256:{manifest['pkgbuild_sha256']}; "
        f"imported package SHA256:{manifest['sha256']}"
    )


def flavorings_input_manifest_path(recipe_path: Path) -> Path:
    """Resolve the package receipt belonging to the final source tag in the recipe."""
    identity = flavorings_recipe_identity(recipe_path)
    return recipe_path.parent / f"{identity['source']['tag']}-input.json"


def verify_flavorings_prebuilt_package(archive: Path) -> dict[str, Any]:
    repository_root = Path(__file__).resolve().parents[2]
    recipe_path = repository_root / "packaging/gooarchy-flavorings/PKGBUILD"
    manifest_path = flavorings_input_manifest_path(recipe_path)
    return verify_flavorings_input(archive, manifest_path, recipe_path)


def stage_flavorings_input(archive: Path, output: Path, manifest_path: Path, recipe_path: Path) -> dict[str, Any]:
    """Copy a prebuilt input into private staging, then validate the staged bytes."""
    if output.exists() or output.is_symlink():
        fail("staged Flavorings output already exists")
    if not hasattr(os, "O_NOFOLLOW"):
        fail("safe Flavorings input staging requires O_NOFOLLOW support")

    source_fd = os.open(archive, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    output_fd = -1
    created_output = False
    try:
        if not stat.S_ISREG(os.fstat(source_fd).st_mode):
            fail("prebuilt Flavorings input must be a regular package archive")
        output_fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        created_output = True
        with os.fdopen(source_fd, "rb") as source:
            source_fd = -1
            with os.fdopen(output_fd, "wb") as destination:
                output_fd = -1
                shutil.copyfileobj(source, destination)
        os.chmod(output, 0o400)
        return verify_flavorings_input(output, manifest_path, recipe_path)
    except BaseException:
        if created_output:
            output.unlink(missing_ok=True)
        raise
    finally:
        if source_fd >= 0:
            os.close(source_fd)
        if output_fd >= 0:
            os.close(output_fd)


def cua_driver_recipe_identity(recipe_path: Path) -> dict[str, Any]:
    text = recipe_path.read_text(encoding="utf-8")

    def assignment(name: str) -> str:
        matches = re.findall(rf"(?m)^{re.escape(name)}=(.+)$", text)
        if len(matches) != 1:
            fail(f"cua-driver recipe must define exactly one {name}")
        value = matches[0].strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if not value:
            fail(f"cua-driver recipe has an empty {name}")
        return value

    def array(name: str) -> list[str]:
        matches = re.findall(rf"(?ms)^{re.escape(name)}=\((.*?)\)", text)
        if len(matches) != 1:
            fail(f"cua-driver recipe must define exactly one {name} array")
        values = re.findall(r"['\"]([^'\"]+)['\"]", matches[0])
        if not values:
            fail(f"cua-driver recipe has an empty {name} array")
        return values

    package = assignment("pkgname")
    pkgver = assignment("pkgver")
    pkgrel = assignment("pkgrel")
    architecture = array("arch")
    dependencies = array("depends")
    if package != "cua-driver" or len(architecture) != 1 or architecture[0] != "x86_64":
        fail("cua-driver recipe has an unexpected package identity")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", pkgver) or not re.fullmatch(r"[0-9]+", pkgrel):
        fail("cua-driver recipe version is invalid")
    return {
        "package": package,
        "version": f"{pkgver}-{pkgrel}",
        "architecture": architecture[0],
        "filename": f"{package}-{pkgver}-{pkgrel}-{architecture[0]}.pkg.tar.zst",
        "packager": "Gooarchy",
        "depends": dependencies,
        "pkgbuild_sha256": sha256_file(recipe_path),
    }


def cua_driver_input_manifest_path(recipe_path: Path) -> Path:
    """Resolve the checked-in archive receipt for the current cua-driver recipe version."""
    identity = cua_driver_recipe_identity(recipe_path)
    return recipe_path.parent / f"{identity['version']}-input.json"


def verify_cua_driver_input(archive: Path, manifest_path: Path, recipe_path: Path) -> dict[str, Any]:
    if archive.is_symlink() or not archive.is_file():
        fail("prebuilt cua-driver input must be a regular package archive")
    expected = cua_driver_recipe_identity(recipe_path)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read prebuilt cua-driver manifest: {error}")
    required = {
        "schema", "package", "version", "architecture", "filename", "sha256",
        "packager", "pkgbuild_sha256", "depends",
    }
    if not isinstance(manifest, dict) or set(manifest) != required:
        fail("prebuilt cua-driver manifest has invalid fields")
    if manifest["schema"] != PACKAGE_INPUT_SCHEMA or manifest["package"] != "cua-driver":
        fail("prebuilt input is not the supported cua-driver package")
    for field in ("version", "architecture", "filename", "packager", "depends"):
        if manifest[field] != expected[field]:
            fail(f"prebuilt cua-driver {field} does not match the current recipe")
    if manifest["packager"] != "Gooarchy":
        fail("prebuilt cua-driver packager is not eligible")
    safe_asset_name(manifest["filename"])
    if archive.name != manifest["filename"]:
        fail("prebuilt cua-driver archive filename does not match its manifest")
    if not isinstance(manifest["sha256"], str) or not SHA256_RE.fullmatch(manifest["sha256"]):
        fail("prebuilt cua-driver package hash is invalid")
    if not isinstance(manifest["pkgbuild_sha256"], str) or not SHA256_RE.fullmatch(manifest["pkgbuild_sha256"]):
        fail("prebuilt cua-driver PKGBUILD hash is invalid")
    if manifest["pkgbuild_sha256"] != expected["pkgbuild_sha256"]:
        fail("prebuilt cua-driver PKGBUILD hash does not match the current recipe")
    if sha256_file(archive) != manifest["sha256"]:
        fail("prebuilt cua-driver package hash does not match its manifest")

    package_expected = {
        "name": "cua-driver",
        "version": expected["version"],
        "arch": "x86_64",
        "packager": "Gooarchy",
    }
    if package_info(archive) != package_expected:
        fail("prebuilt cua-driver .PKGINFO does not match its reviewed package identity")
    if build_info(archive) != {
        **package_expected,
        "pkgbuild_sha256": manifest["pkgbuild_sha256"],
    }:
        fail("prebuilt cua-driver .BUILDINFO does not match its reviewed build identity")
    if package_dependencies(archive) != expected["depends"]:
        fail("prebuilt cua-driver dependencies do not match its current recipe")
    return manifest


def verify_cua_driver_prebuilt_package(archive: Path) -> dict[str, Any]:
    repository_root = Path(__file__).resolve().parents[2]
    recipe_path = repository_root / "packaging/arch/cua-driver/PKGBUILD"
    manifest_path = cua_driver_input_manifest_path(recipe_path)
    return verify_cua_driver_input(archive, manifest_path, recipe_path)


def cua_driver_source_revision(manifest: dict[str, Any]) -> str:
    return (
        f"prebuilt cua-driver package SHA256:{manifest['sha256']}; "
        f"PKGBUILD SHA256:{manifest['pkgbuild_sha256']}"
    )


def stage_cua_driver_input(archive: Path, output: Path, manifest_path: Path, recipe_path: Path) -> dict[str, Any]:
    """Copy an approved cua-driver archive byte-for-byte into private staging."""
    if output.exists() or output.is_symlink():
        fail("staged cua-driver output already exists")
    if not hasattr(os, "O_NOFOLLOW"):
        fail("safe cua-driver input staging requires O_NOFOLLOW support")

    source_fd = os.open(archive, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    output_fd = -1
    created_output = False
    try:
        if not stat.S_ISREG(os.fstat(source_fd).st_mode):
            fail("prebuilt cua-driver input must be a regular package archive")
        output_fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        created_output = True
        with os.fdopen(source_fd, "rb") as source:
            source_fd = -1
            with os.fdopen(output_fd, "wb") as destination:
                output_fd = -1
                shutil.copyfileobj(source, destination)
        os.chmod(output, 0o400)
        return verify_cua_driver_input(output, manifest_path, recipe_path)
    except BaseException:
        if created_output:
            output.unlink(missing_ok=True)
        raise
    finally:
        if source_fd >= 0:
            os.close(source_fd)
        if output_fd >= 0:
            os.close(output_fd)


def load_sources(path: Path) -> dict[str, dict[str, Any]]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        fail("source map must be a JSON object")
    result: dict[str, dict[str, Any]] = {}
    for name, entry in value.items():
        if not isinstance(name, str) or not isinstance(entry, dict):
            fail("source map entries must map package names to objects")
        if set(entry) != {"revision", "origin_kind"}:
            fail(f"source map fields are invalid for {name}")
        revision = entry.get("revision")
        origin_kind = entry.get("origin_kind")
        if not isinstance(revision, str) or not revision.strip() or any(ord(c) < 32 for c in revision):
            fail(f"source revision is missing or invalid for {name}")
        if origin_kind not in PACKAGE_ORIGINS:
            fail(f"package origin kind is invalid for {name}")
        result[name] = {"revision": revision, "origin_kind": origin_kind}
    return result


def write_base(args: argparse.Namespace) -> None:
    package_dir = args.package_dir.resolve(strict=True)
    database = args.database.resolve(strict=True)
    if not ASSET_RE.fullmatch(args.release_tag) or ".." in args.release_tag:
        fail("base release tag is invalid")
    records = database_records(database)
    packages: list[dict[str, str]] = []
    for name, version, filename in records:
        safe_asset_name(filename)
        package_path = package_dir / filename
        signature_path = package_dir / f"{filename}.sig"
        if not package_path.is_file() or package_path.is_symlink():
            fail(f"base release is missing package {filename}")
        if not signature_path.is_file() or signature_path.is_symlink():
            fail(f"base release is missing package signature {filename}.sig")
        info = package_info(package_path)
        if info["name"] != name or info["version"] != version:
            fail(f"base package metadata and database disagree for {name}")
        packages.append({
            "name": name,
            "version": version,
            "filename": filename,
            "sha256": sha256_file(package_path),
            "signature_sha256": sha256_file(signature_path),
        })
    value = {
        "release_tag": args.release_tag,
        "database_sha256": sha256_file(database),
        "packages": sorted(packages, key=lambda item: item["name"]),
    }
    validate_base(value)
    print(json.dumps(value, sort_keys=True, separators=(",", ":")))

def write_manifest(args: argparse.Namespace) -> None:
    bundle = args.bundle.resolve()
    payload = bundle / "payload"
    database = payload / "gooarchy.db"
    if not payload.is_dir() or not database.is_file() or database.is_symlink():
        fail("bundle payload must contain a regular gooarchy.db file")

    source_root = args.source_root.resolve()
    commit = subprocess.run(
        ["git", "-C", str(source_root), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    tree = subprocess.run(
        ["git", "-C", str(source_root), "rev-parse", "HEAD^{tree}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if not COMMIT_RE.fullmatch(commit) or not COMMIT_RE.fullmatch(tree):
        fail("source checkout did not resolve to full Git commit and tree IDs")
    if not FINGERPRINT_RE.fullmatch(args.fingerprint):
        fail("signing fingerprint must be a normalized 40- or 64-digit uppercase fingerprint")

    if args.base_json:
        base = json.loads(args.base_json.read_text(encoding="utf-8"))
    else:
        base = None
    if base is not None:
        validate_base(base)

    sources = load_sources(args.source_map)
    records = database_records(database)
    package_names = {name for name, _, _ in records}
    if package_names != set(sources):
        fail("source map package names do not match the unsigned repository database")

    packages: list[dict[str, Any]] = []
    expected_payload: set[str] = {"gooarchy.db"}
    base_by_name = {entry["name"]: entry for entry in (base["packages"] if base else [])}
    pair_manifest = (
        load_scottland_pair_manifest()
        if any(source["origin_kind"] == "upstream-release" for source in sources.values())
        else None
    )
    upstream_names: set[str] = set()
    for name, version, filename in records:
        safe_asset_name(filename)
        path = payload / filename
        if not path.is_file() or path.is_symlink():
            fail(f"repository database lists missing or non-regular package asset {filename}")
        info = package_info(path)
        if info["name"] != name or info["version"] != version:
            fail(f"package metadata and repository database disagree for {name}")
        if info["arch"] not in {"any", "x86_64"}:
            fail(f"{name} has unsupported architecture {info['arch']}")
        source = sources[name]
        origin_kind = source["origin_kind"]
        previous = base_by_name.get(name)
        if origin_kind == "retained-release" and (
            previous is None
            or previous["version"] != version
            or previous["filename"] != filename
            or previous["sha256"] != sha256_file(path)
        ):
            fail(f"retained package does not match the exact base release: {name}")
        if origin_kind == "retained-release":
            if source["revision"] != f"retained from release tag:{base['release_tag']}":
                fail(f"retained package source does not identify the exact base release: {name}")
        elif origin_kind == "source-build":
            if info["packager"] != "Gooarchy":
                fail(f"{name} does not carry the Gooarchy source-build packager identity")
        elif origin_kind == "prebuilt-input":
            if name == "gooarchy-flavorings":
                prebuilt = verify_flavorings_prebuilt_package(path)
                if source["revision"] != flavorings_source_revision(prebuilt):
                    fail("prebuilt Flavorings source provenance differs from its pinned input")
            elif name == "cua-driver":
                prebuilt = verify_cua_driver_prebuilt_package(path)
                if source["revision"] != cua_driver_source_revision(prebuilt):
                    fail("prebuilt cua-driver source provenance differs from its pinned input")
            else:
                fail(f"{name} is not an approved prebuilt package input")
        elif origin_kind == "upstream-release":
            if pair_manifest is None:
                fail("Scottland package provenance is missing its pin manifest")
            pinned = next((item for item in pair_manifest["packages"] if item["name"] == name), None)
            if pinned is None or source["revision"] != scottland_source_revision(pair_manifest, pinned):
                fail(f"{name} does not identify the pinned upstream Scottland release asset")
            if (version, filename, info["arch"]) != (
                pinned["version"], pinned["filename"], pinned["architecture"]
            ):
                fail(f"{name} package identity differs from its pinned upstream release asset")
            verify_scottland_pair_package(path, pinned)
            upstream_names.add(name)
        else:
            fail(f"unsupported package origin kind for {name}")
        if origin_kind != "retained-release" and previous is not None:
            comparison = subprocess.run(
                ["vercmp", version, previous["version"]],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            try:
                comparison_value = int(comparison)
            except ValueError:
                fail(f"vercmp returned an invalid result for {name}")
            if comparison_value <= 0:
                fail(f"new package is not newer than the base release: {name}")
        packages.append(
            {
                "name": name,
                "version": version,
                "filename": filename,
                "sha256": sha256_file(path),
                "architecture": info["arch"],
                "source_revision": source["revision"],
                "origin_kind": origin_kind,
            }
        )
        expected_payload.add(filename)

    if upstream_names and upstream_names != SCOTTLAND_PACKAGE_NAMES:
        fail("an upstream Scottland import must contain the exact core and adapter pair")

    if base is not None:
        if not set(base_by_name).issubset(package_names):
            fail("repository database dropped a package from the base release")
    elif not REQUIRED_INITIAL.issubset(package_names):
        fail("first repository bundle must contain all six required packages")

    actual_payload: set[str] = set()
    for path in payload.iterdir():
        if path.is_symlink() or not path.is_file():
            fail("payload may contain only regular, non-symlink files")
        actual_payload.add(path.name)
    if actual_payload != expected_payload:
        fail("payload files do not exactly match the repository database")

    manifest = {
        "schema": SCHEMA,
        "repository": REPOSITORY,
        "source_commit": commit,
        "source_tree": tree,
        "signing_fingerprint": args.fingerprint,
        "base": base,
        "packages": sorted(packages, key=lambda item: item["name"]),
        "database": {
            "filename": "gooarchy.db",
            "sha256": sha256_file(database),
        },
    }
    manifest_path = bundle / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    checksum_lines = [
        f"{sha256_file(payload / name)}  payload/{name}"
        for name in sorted(expected_payload)
    ]
    (bundle / "SHA256SUMS").write_text("\n".join(checksum_lines) + "\n", encoding="ascii")
    print(sha256_file(manifest_path))


def write_signature_receipt(args: argparse.Namespace) -> None:
    if args.signer_role not in {"primary", "backup"}:
        fail("signer role must be selected as primary or backup")
    if not FINGERPRINT_RE.fullmatch(args.fingerprint):
        fail("signing fingerprint must be a normalized 40- or 64-digit uppercase fingerprint")
    if args.bundle.is_symlink() or not args.bundle.is_dir():
        fail("signature receipt source must be a regular transfer directory")
    if args.signatures.is_symlink() or not args.signatures.is_dir():
        fail("signature source must be a regular directory")
    bundle = args.bundle.resolve(strict=True)
    signatures_dir = args.signatures.resolve(strict=True)
    manifest = load_and_verify_bundle(
        bundle, args.expected_manifest_sha256, args.fingerprint
    )
    expected: dict[str, str] = {
        item["filename"]: item["sha256"] for item in manifest["packages"]
    }
    expected["gooarchy.db"] = manifest["database"]["sha256"]
    entries: list[dict[str, str]] = []
    for filename, payload_sha256 in sorted(expected.items()):
        signature_filename = safe_asset_name(f"{filename}.sig")
        signature_path = signatures_dir / signature_filename
        if not signature_path.is_file() or signature_path.is_symlink():
            fail(f"missing regular detached signature for {filename}")
        entries.append({
            "filename": filename,
            "payload_sha256": payload_sha256,
            "signature_filename": signature_filename,
            "signature_sha256": sha256_file(signature_path),
        })
    actual = set()
    for path in signatures_dir.iterdir():
        if path.is_symlink() or not path.is_file():
            fail("signature directory may contain only regular, non-symlink files")
        actual.add(path.name)
    if actual != {entry["signature_filename"] for entry in entries}:
        fail("signature directory does not exactly match packages and repository database")
    receipt = {
        "schema": SIGNATURE_SCHEMA,
        "manifest_sha256": args.expected_manifest_sha256,
        "signer_role": args.signer_role,
        "signing_fingerprint": args.fingerprint,
        "signatures": entries,
    }
    output = args.output
    if output.exists() or output.is_symlink():
        fail("signature receipt output already exists")
    output.write_text(
        json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    print(sha256_file(output))


def validate_base(base: Any) -> None:
    if not isinstance(base, dict) or set(base) != {"release_tag", "database_sha256", "packages"}:
        fail("base release manifest has invalid fields")
    tag = base["release_tag"]
    if not isinstance(tag, str) or not ASSET_RE.fullmatch(tag) or ".." in tag:
        fail("base release tag is invalid")
    if not isinstance(base["database_sha256"], str) or not SHA256_RE.fullmatch(base["database_sha256"]):
        fail("base database hash is invalid")
    if not isinstance(base["packages"], list):
        fail("base packages must be a list")
    names: set[str] = set()
    filenames: set[str] = set()
    release_asset_names = {"gooarchy.db", "gooarchy.db.sig"}
    for package in base["packages"]:
        if not isinstance(package, dict) or set(package) != {
            "name", "version", "filename", "sha256", "signature_sha256"
        }:
            fail("base package entry has invalid fields")
        name = package["name"]
        if not isinstance(name, str) or not name or name in names:
            fail("base package names must be non-empty and unique")
        filename = safe_asset_name(package["filename"])
        if filename in filenames:
            fail("base package filenames must be unique")
        signature_filename = safe_asset_name(f"{filename}.sig")
        if filename in release_asset_names or signature_filename in release_asset_names:
            fail("base package assets collide with another release asset")
        release_asset_names.update({filename, signature_filename})
        if not isinstance(package["version"], str) or not package["version"]:
            fail("base package version is invalid")
        if not isinstance(package["sha256"], str) or not SHA256_RE.fullmatch(package["sha256"]):
            fail("base package hash is invalid")
        if not isinstance(package["signature_sha256"], str) or not SHA256_RE.fullmatch(package["signature_sha256"]):
            fail("base package signature hash is invalid")
        names.add(name)
        filenames.add(filename)


def load_and_verify_bundle(
    bundle: Path,
    expected_manifest: str,
    expected_fingerprint: str | None,
    *,
    signed: bool = False,
) -> dict[str, Any]:
    if bundle.is_symlink() or not bundle.is_dir():
        fail("transfer bundle must be a real directory")
    bundle = bundle.resolve(strict=True)
    manifest_path = bundle / "manifest.json"
    sums_path = bundle / "SHA256SUMS"
    payload = bundle / "payload"
    root_entries = {path.name for path in bundle.iterdir()}
    expected_root = {"manifest.json", "SHA256SUMS", "payload"}
    if signed:
        expected_root |= {"SIGNATURES.json", "signatures"}
    if root_entries != expected_root:
        fail("transfer bundle root has unexpected entries")
    if not manifest_path.is_file() or manifest_path.is_symlink():
        fail("transfer bundle is missing a regular manifest.json")
    if not sums_path.is_file() or sums_path.is_symlink():
        fail("transfer bundle is missing a regular SHA256SUMS")
    if not payload.is_dir() or payload.is_symlink():
        fail("transfer bundle is missing a regular payload directory")
    if signed:
        signature_manifest = bundle / "SIGNATURES.json"
        signatures = bundle / "signatures"
        if not signature_manifest.is_file() or signature_manifest.is_symlink():
            fail("signed transfer is missing a regular SIGNATURES.json")
        if not signatures.is_dir() or signatures.is_symlink():
            fail("signed transfer is missing a regular signatures directory")
    if not isinstance(expected_manifest, str) or not SHA256_RE.fullmatch(expected_manifest) or sha256_file(manifest_path) != expected_manifest:
        fail("transfer manifest hash does not match the independently supplied SHA-256")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read transfer manifest: {error}")
    if not isinstance(manifest, dict) or set(manifest) != {
        "schema", "repository", "source_commit", "source_tree", "signing_fingerprint",
        "base", "packages", "database"
    }:
        fail("transfer manifest has invalid fields")
    schema = manifest["schema"]
    if not isinstance(schema, str) or schema not in {SCHEMA, LEGACY_SCHEMA} or manifest["repository"] != REPOSITORY:
        fail("transfer bundle has the wrong protocol or repository identity")
    if not isinstance(manifest["source_commit"], str) or not COMMIT_RE.fullmatch(manifest["source_commit"]):
        fail("source commit must be a full Git SHA")
    if not isinstance(manifest["source_tree"], str) or not COMMIT_RE.fullmatch(manifest["source_tree"]):
        fail("source tree must be a full Git SHA")
    fingerprint = manifest["signing_fingerprint"]
    if not isinstance(fingerprint, str) or not FINGERPRINT_RE.fullmatch(fingerprint):
        fail("transfer manifest contains an invalid signing fingerprint")
    if expected_fingerprint is not None and fingerprint != expected_fingerprint:
        fail("transfer manifest signing fingerprint does not match the source configuration")
    base = manifest["base"]
    if base is not None:
        validate_base(base)

    database = manifest["database"]
    if not isinstance(database, dict) or set(database) != {"filename", "sha256"}:
        fail("database record has invalid fields")
    if database["filename"] != "gooarchy.db" or not isinstance(database["sha256"], str) or not SHA256_RE.fullmatch(database["sha256"]):
        fail("database record is invalid")
    packages = manifest["packages"]
    if not isinstance(packages, list) or not packages:
        fail("transfer manifest must contain package records")
    names: set[str] = set()
    filenames: set[str] = {"gooarchy.db"}
    release_asset_names = {"gooarchy.db", "gooarchy.db.sig"}
    origins: dict[str, str] = {}
    for package in packages:
        expected_fields = (
            {"name", "version", "filename", "sha256", "architecture", "source_revision", "rebuilt"}
            if schema == LEGACY_SCHEMA else
            {"name", "version", "filename", "sha256", "architecture", "source_revision", "origin_kind"}
        )
        if not isinstance(package, dict) or set(package) != expected_fields:
            fail("package record has invalid fields")
        name = package["name"]
        if not isinstance(name, str) or not name or name in names:
            fail("package names must be non-empty and unique")
        filename = safe_asset_name(package["filename"])
        if filename in filenames:
            fail("package filenames must be unique")
        signature_filename = safe_asset_name(f"{filename}.sig")
        if filename in release_asset_names or signature_filename in release_asset_names:
            fail("package assets collide with another release asset")
        release_asset_names.update({filename, signature_filename})
        if not isinstance(package["version"], str) or not package["version"]:
            fail(f"package version is invalid for {name}")
        if not isinstance(package["sha256"], str) or not SHA256_RE.fullmatch(package["sha256"]):
            fail(f"package hash is invalid for {name}")
        if not isinstance(package["architecture"], str) or package["architecture"] not in {"any", "x86_64"}:
            fail(f"package architecture is invalid for {name}")
        revision = package["source_revision"]
        if not isinstance(revision, str) or not revision.strip() or any(ord(c) < 32 for c in revision):
            fail(f"source revision is invalid for {name}")
        if schema == LEGACY_SCHEMA:
            if not isinstance(package["rebuilt"], bool):
                fail(f"rebuilt must be a boolean for {name}")
            origins[name] = "source-build" if package["rebuilt"] else "retained-release"
        else:
            origin_kind = package["origin_kind"]
            if not isinstance(origin_kind, str) or origin_kind not in PACKAGE_ORIGINS:
                fail(f"package origin kind is invalid for {name}")
            origins[name] = origin_kind
        names.add(name)
        filenames.add(filename)

    upstream_names = {name for name, origin in origins.items() if origin == "upstream-release"}
    pair_manifest = load_scottland_pair_manifest() if upstream_names else None
    if upstream_names and upstream_names != SCOTTLAND_PACKAGE_NAMES:
        fail("an upstream Scottland import must contain the exact core and adapter pair")

    if base is None:
        if not REQUIRED_INITIAL.issubset(names):
            fail("first repository bundle is missing one or more required packages")
        if any(origin == "retained-release" for origin in origins.values()):
            fail("first repository bundle cannot contain retained packages")
    else:
        base_by_name = {package["name"]: package for package in base["packages"]}
        if not set(base_by_name).issubset(names):
            fail("transfer bundle dropped a package from its base release")
        for package in packages:
            old = base_by_name.get(package["name"])
            origin = origins[package["name"]]
            if origin == "retained-release":
                if old is None or any(
                    package[key] != old[old_key]
                    for key, old_key in (("version", "version"), ("filename", "filename"), ("sha256", "sha256"))
                ):
                    fail(f"retained package does not match the base release: {package['name']}")
                if package["source_revision"] != f"retained from release tag:{base['release_tag']}":
                    fail(f"retained package source does not identify the exact base release: {package['name']}")
            elif old is not None:
                comparison = subprocess.run(
                    ["vercmp", package["version"], old["version"]],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip()
                try:
                    comparison_value = int(comparison)
                except ValueError:
                    fail(f"vercmp returned an invalid result for {package['name']}")
                if comparison_value <= 0:
                    fail(f"new package is not newer than the base release: {package['name']}")

    expected_payload = filenames
    actual_payload: set[str] = set()
    for path in payload.iterdir():
        if path.is_symlink() or not path.is_file():
            fail("payload may contain only regular, non-symlink files")
        actual_payload.add(path.name)
    if actual_payload != expected_payload:
        fail("payload files do not exactly match the manifest")

    expected_lines = [
        f"{package['sha256']}  payload/{package['filename']}"
        for package in sorted(packages, key=lambda item: item["filename"])
    ]
    expected_lines.append(f"{database['sha256']}  payload/gooarchy.db")
    expected_lines.sort(key=lambda line: line.split("  ", 1)[1])
    actual_lines = sums_path.read_text(encoding="ascii").splitlines()
    if actual_lines != expected_lines:
        fail("SHA256SUMS does not match the manifest")
    for package in packages:
        path = payload / package["filename"]
        if sha256_file(path) != package["sha256"]:
            fail(f"package hash mismatch: {package['filename']}")
        info = package_info(path)
        if info["name"] != package["name"] or info["version"] != package["version"]:
            fail(f"package metadata differs from the manifest: {package['name']}")
        if info["arch"] != package["architecture"]:
            fail(f"package architecture differs from the manifest: {package['name']}")
        if schema == LEGACY_SCHEMA and info["packager"] != "Gooarchy":
            fail(f"legacy package identity differs from the manifest: {package['name']}")
        origin = origins[package["name"]]
        if origin == "source-build":
            if info["packager"] != "Gooarchy":
                fail(f"source-built package does not carry the Gooarchy packager identity: {package['name']}")
        elif origin == "prebuilt-input":
            if package["name"] == "gooarchy-flavorings":
                prebuilt = verify_flavorings_prebuilt_package(path)
                if package["source_revision"] != flavorings_source_revision(prebuilt):
                    fail("prebuilt Flavorings source provenance differs from its pinned input")
            elif package["name"] == "cua-driver":
                prebuilt = verify_cua_driver_prebuilt_package(path)
                if package["source_revision"] != cua_driver_source_revision(prebuilt):
                    fail("prebuilt cua-driver source provenance differs from its pinned input")
            else:
                fail(f"{package['name']} is not an approved prebuilt package input")
        elif origin == "upstream-release":
            if pair_manifest is None:
                fail("Scottland package provenance is missing its pin manifest")
            pinned = next(
                (item for item in pair_manifest["packages"] if item["name"] == package["name"]),
                None,
            )
            if pinned is None or package["source_revision"] != scottland_source_revision(pair_manifest, pinned):
                fail(f"upstream source provenance differs from the pinned Scottland asset: {package['name']}")
            if (
                package["version"], package["filename"], package["sha256"], package["architecture"]
            ) != (
                pinned["version"], pinned["filename"], pinned["sha256"], pinned["architecture"]
            ):
                fail(f"package identity differs from the pinned Scottland release asset: {package['name']}")
            verify_scottland_pair_package(path, pinned)
        elif origin == "retained-release":
            # The exact base-release hash above is the provenance for retained bytes;
            # the upstream or Gooarchy packager field remains unchanged in the archive.
            pass
        else:
            fail(f"unsupported package origin kind for {package['name']}")
    database_path = payload / "gooarchy.db"
    if sha256_file(database_path) != database["sha256"]:
        fail("repository database hash mismatch")
    actual_records = database_records(database_path)
    expected_records = sorted(
        ((item["name"], item["version"], item["filename"]) for item in packages)
    )
    if actual_records != expected_records:
        fail("repository database package records do not match the transfer manifest")
    if signed:
        verify_signature_manifest(bundle, manifest, expected_manifest, expected_fingerprint)
    return manifest


def verify_signature_manifest(
    bundle: Path,
    manifest: dict[str, Any],
    expected_manifest: str,
    expected_fingerprint: str | None,
) -> dict[str, Any]:
    receipt_path = bundle / "SIGNATURES.json"
    signatures_dir = bundle / "signatures"
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read signature receipt: {error}")
    if not isinstance(receipt, dict) or set(receipt) != {
        "schema", "manifest_sha256", "signer_role", "signing_fingerprint", "signatures"
    }:
        fail("signature receipt has invalid fields")
    if receipt["schema"] != SIGNATURE_SCHEMA:
        fail("signature receipt has the wrong schema")
    if receipt["manifest_sha256"] != expected_manifest:
        fail("signature receipt does not bind the expected immutable build manifest")
    if not isinstance(receipt["signer_role"], str) or receipt["signer_role"] not in {"primary", "backup"}:
        fail("signature receipt has an unsupported signer role")
    fingerprint = receipt["signing_fingerprint"]
    if not isinstance(fingerprint, str) or not FINGERPRINT_RE.fullmatch(fingerprint):
        fail("signature receipt contains an invalid fingerprint")
    if fingerprint != manifest["signing_fingerprint"] or (
        expected_fingerprint is not None and fingerprint != expected_fingerprint
    ):
        fail("signature receipt key does not match the build manifest and source configuration")

    expected_assets = {
        item["filename"]: item["sha256"] for item in manifest["packages"]
    }
    expected_assets["gooarchy.db"] = manifest["database"]["sha256"]
    entries = receipt["signatures"]
    if not isinstance(entries, list):
        fail("signature receipt entries must be a list")
    actual_assets: dict[str, str] = {}
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {
            "filename", "payload_sha256", "signature_filename", "signature_sha256"
        }:
            fail("signature receipt entry has invalid fields")
        filename = safe_asset_name(entry["filename"])
        signature_filename = safe_asset_name(entry["signature_filename"])
        if signature_filename != f"{filename}.sig":
            fail(f"signature filename does not match its payload: {filename}")
        if filename in actual_assets:
            fail(f"signature receipt repeats payload {filename}")
        actual_assets[filename] = entry["payload_sha256"]
        if entry["payload_sha256"] != expected_assets.get(filename):
            fail(f"signature receipt payload differs from the build manifest: {filename}")
        if not isinstance(entry["signature_sha256"], str) or not SHA256_RE.fullmatch(entry["signature_sha256"]):
            fail(f"signature hash is invalid for {filename}")
        signature_path = signatures_dir / signature_filename
        if not signature_path.is_file() or signature_path.is_symlink():
            fail(f"signed transfer is missing a regular signature for {filename}")
        if sha256_file(signature_path) != entry["signature_sha256"]:
            fail(f"signature hash mismatch for {filename}")
    if actual_assets != expected_assets:
        fail("signature receipt must cover every package and the repository database exactly once")
    actual_signatures: set[str] = set()
    for path in signatures_dir.iterdir():
        if path.is_symlink() or not path.is_file():
            fail("signature directory may contain only regular, non-symlink files")
        actual_signatures.add(path.name)
    if actual_signatures != {f"{name}.sig" for name in expected_assets}:
        fail("signature directory contains an incomplete or unexpected asset set")
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    flavorings_recipe = commands.add_parser("flavorings-recipe-identity")
    flavorings_recipe.add_argument("--recipe", type=Path, required=True)
    flavorings_input = commands.add_parser("verify-flavorings-input")
    flavorings_input.add_argument("--archive", type=Path, required=True)
    flavorings_input.add_argument("--manifest", type=Path, required=True)
    flavorings_input.add_argument("--recipe", type=Path, required=True)
    flavorings_manifest_path = commands.add_parser("flavorings-input-manifest-path")
    flavorings_manifest_path.add_argument("--recipe", type=Path, required=True)
    flavorings_stage = commands.add_parser("stage-flavorings-input")
    flavorings_stage.add_argument("--archive", type=Path, required=True)
    flavorings_stage.add_argument("--output", type=Path, required=True)
    flavorings_stage.add_argument("--manifest", type=Path, required=True)
    flavorings_stage.add_argument("--recipe", type=Path, required=True)
    cua_driver_input = commands.add_parser("verify-cua-driver-input")
    cua_driver_input.add_argument("--archive", type=Path, required=True)
    cua_driver_input.add_argument("--manifest", type=Path, required=True)
    cua_driver_input.add_argument("--recipe", type=Path, required=True)
    cua_driver_manifest_path = commands.add_parser("cua-driver-input-manifest-path")
    cua_driver_manifest_path.add_argument("--recipe", type=Path, required=True)
    cua_driver_stage = commands.add_parser("stage-cua-driver-input")
    cua_driver_stage.add_argument("--archive", type=Path, required=True)
    cua_driver_stage.add_argument("--output", type=Path, required=True)
    cua_driver_stage.add_argument("--manifest", type=Path, required=True)
    cua_driver_stage.add_argument("--recipe", type=Path, required=True)
    scottland_pair_path = commands.add_parser("scottland-pair-input-manifest-path")
    scottland_pair_input = commands.add_parser("verify-scottland-pair-input")
    scottland_pair_input.add_argument("--directory", type=Path, required=True)
    scottland_pair_stage = commands.add_parser("stage-scottland-pair-input")
    scottland_pair_stage.add_argument("--directory", type=Path, required=True)
    scottland_pair_stage.add_argument("--output-directory", type=Path, required=True)
    package_metadata = commands.add_parser("package-info")
    package_metadata_source = package_metadata.add_mutually_exclusive_group(required=True)
    package_metadata_source.add_argument("--archive", type=Path)
    package_metadata_source.add_argument("--stdin", action="store_true")
    writer = commands.add_parser("write")
    writer.add_argument("--bundle", type=Path, required=True)
    writer.add_argument("--source-root", type=Path, required=True)
    writer.add_argument("--source-map", type=Path, required=True)
    writer.add_argument("--fingerprint", required=True)
    writer.add_argument("--base-json", type=Path)
    receipt_writer = commands.add_parser("sign-receipt")
    receipt_writer.add_argument("--bundle", type=Path, required=True)
    receipt_writer.add_argument("--signatures", type=Path, required=True)
    receipt_writer.add_argument("--expected-manifest-sha256", required=True)
    receipt_writer.add_argument("--fingerprint", required=True)
    receipt_writer.add_argument("--signer-role", required=True)
    receipt_writer.add_argument("--output", type=Path, required=True)
    base_writer = commands.add_parser("base")
    base_writer.add_argument("--release-tag", required=True)
    base_writer.add_argument("--database", type=Path, required=True)
    base_writer.add_argument("--package-dir", type=Path, required=True)
    verifier = commands.add_parser("verify")
    verifier.add_argument("--bundle", type=Path, required=True)
    verifier.add_argument("--expected-manifest-sha256", required=True)
    verifier.add_argument("--expected-fingerprint")
    signed_verifier = commands.add_parser("verify-signed")
    signed_verifier.add_argument("--bundle", type=Path, required=True)
    signed_verifier.add_argument("--expected-manifest-sha256", required=True)
    signed_verifier.add_argument("--expected-fingerprint")
    args = parser.parse_args()
    try:
        if args.command == "package-info":
            info = package_info(args.archive) if args.archive else parse_package_info(
                sys.stdin.read(), "package metadata"
            )
            print(json.dumps(info, sort_keys=True, separators=(",", ":")))
        elif args.command == "flavorings-recipe-identity":
            print(json.dumps(flavorings_recipe_identity(args.recipe), sort_keys=True, separators=(",", ":")))
        elif args.command == "verify-flavorings-input":
            manifest = verify_flavorings_input(
                args.archive, args.manifest, args.recipe
            )
            print(json.dumps({
                "package": manifest["package"],
                "version": manifest["version"],
                "filename": manifest["filename"],
                "sha256": manifest["sha256"],
                "source": manifest["source"],
                "pkgbuild_sha256": manifest["pkgbuild_sha256"],
                "source_revision": flavorings_source_revision(manifest),
            }, sort_keys=True, separators=(",", ":")))
        elif args.command == "flavorings-input-manifest-path":
            print(flavorings_input_manifest_path(args.recipe))
        elif args.command == "stage-flavorings-input":
            manifest = stage_flavorings_input(
                args.archive, args.output, args.manifest, args.recipe
            )
            print(json.dumps({
                "package": manifest["package"],
                "version": manifest["version"],
                "filename": manifest["filename"],
                "sha256": manifest["sha256"],
                "source": manifest["source"],
                "pkgbuild_sha256": manifest["pkgbuild_sha256"],
                "source_revision": flavorings_source_revision(manifest),
            }, sort_keys=True, separators=(",", ":")))
        elif args.command == "verify-cua-driver-input":
            manifest = verify_cua_driver_input(args.archive, args.manifest, args.recipe)
            print(json.dumps({
                "package": manifest["package"],
                "version": manifest["version"],
                "filename": manifest["filename"],
                "sha256": manifest["sha256"],
                "pkgbuild_sha256": manifest["pkgbuild_sha256"],
                "source_revision": cua_driver_source_revision(manifest),
            }, sort_keys=True, separators=(",", ":")))
        elif args.command == "cua-driver-input-manifest-path":
            print(cua_driver_input_manifest_path(args.recipe))
        elif args.command == "stage-cua-driver-input":
            manifest = stage_cua_driver_input(args.archive, args.output, args.manifest, args.recipe)
            print(json.dumps({
                "package": manifest["package"],
                "version": manifest["version"],
                "filename": manifest["filename"],
                "sha256": manifest["sha256"],
                "pkgbuild_sha256": manifest["pkgbuild_sha256"],
                "source_revision": cua_driver_source_revision(manifest),
            }, sort_keys=True, separators=(",", ":")))
        elif args.command == "scottland-pair-input-manifest-path":
            print(scottland_pair_manifest_path())
        elif args.command == "verify-scottland-pair-input":
            print(json.dumps(
                verify_scottland_pair_input(args.directory),
                sort_keys=True,
                separators=(",", ":"),
            ))
        elif args.command == "stage-scottland-pair-input":
            print(json.dumps(
                stage_scottland_pair_input(args.directory, args.output_directory),
                sort_keys=True,
                separators=(",", ":"),
            ))
        elif args.command == "write":
            write_manifest(args)
        elif args.command == "base":
            write_base(args)
        elif args.command == "sign-receipt":
            write_signature_receipt(args)
        elif args.command == "verify-signed":
            manifest = load_and_verify_bundle(
                args.bundle,
                args.expected_manifest_sha256,
                args.expected_fingerprint,
                signed=True,
            )
            receipt = verify_signature_manifest(
                args.bundle.resolve(strict=True),
                manifest,
                args.expected_manifest_sha256,
                args.expected_fingerprint,
            )
            print(json.dumps({
                "source_commit": manifest["source_commit"],
                "source_tree": manifest["source_tree"],
                "signer_role": receipt["signer_role"],
                "signing_fingerprint": receipt["signing_fingerprint"],
                "packages": len(manifest["packages"]),
                "base_release": manifest["base"]["release_tag"] if manifest["base"] else None,
            }, sort_keys=True))
        else:
            manifest = load_and_verify_bundle(
                args.bundle, args.expected_manifest_sha256, args.expected_fingerprint
            )
            print(json.dumps({
                "source_commit": manifest["source_commit"],
                "source_tree": manifest["source_tree"],
                "packages": len(manifest["packages"]),
                "base_release": manifest["base"]["release_tag"] if manifest["base"] else None,
            }, sort_keys=True))
    except (OSError, subprocess.CalledProcessError, ValueError, tarfile.TarError) as error:
        print(f"repository-protocol.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
