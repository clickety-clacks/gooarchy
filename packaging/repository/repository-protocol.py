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

SCHEMA = "gooarchy-repository-transfer-v1"
SIGNATURE_SCHEMA = "gooarchy-repository-signatures-v1"
PACKAGE_INPUT_SCHEMA = "gooarchy-prebuilt-package-v1"
REPOSITORY = "clickety-clacks/gooarchy"
FLAVORINGS_REPOSITORY = "clickety-clacks/gooarchy-flavorings"
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


def verify_flavorings_input(
    archive: Path, manifest_path: Path, expected_tag: str, expected_version: str
) -> dict[str, Any]:
    if archive.is_symlink() or not archive.is_file():
        fail("prebuilt Flavorings input must be a regular package archive")
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
    if not isinstance(source["tag"], str) or not VERSION_TAG_RE.fullmatch(source["tag"]):
        fail("prebuilt Flavorings source must identify one final version tag")
    if source["tag"] != expected_tag:
        fail("prebuilt Flavorings tag does not match the current recipe")
    if not isinstance(source["commit"], str) or not COMMIT_RE.fullmatch(source["commit"]):
        fail("prebuilt Flavorings source commit is invalid")
    if not isinstance(source["tree"], str) or not COMMIT_RE.fullmatch(source["tree"]):
        fail("prebuilt Flavorings source tree is invalid")
    if not isinstance(source["archive_sha256"], str) or not SHA256_RE.fullmatch(source["archive_sha256"]):
        fail("prebuilt Flavorings source archive hash is invalid")
    if manifest["version"] != expected_version:
        fail("prebuilt Flavorings package version does not match the current recipe")
    if manifest["architecture"] != "any" or manifest["packager"] != "Gooarchy":
        fail("prebuilt Flavorings architecture or packager is not eligible")
    if not isinstance(manifest["filename"], str) or manifest["filename"] != (
        f"gooarchy-flavorings-{expected_version}-any.pkg.tar.zst"
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
    expected = {
        "name": "gooarchy-flavorings",
        "version": expected_version,
        "arch": "any",
        "packager": "Gooarchy",
    }
    if package != expected:
        fail("prebuilt Flavorings .PKGINFO does not match the reviewed package identity")
    if build != {
        **expected,
        "pkgbuild_sha256": manifest["pkgbuild_sha256"],
    }:
        fail("prebuilt Flavorings .BUILDINFO does not match its reviewed build identity")
    return manifest


def stage_flavorings_input(
    archive: Path, output: Path, manifest_path: Path, expected_tag: str, expected_version: str
) -> dict[str, Any]:
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
        return verify_flavorings_input(output, manifest_path, expected_tag, expected_version)
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
        revision = entry.get("revision")
        rebuilt = entry.get("rebuilt")
        if not isinstance(revision, str) or not revision.strip() or any(ord(c) < 32 for c in revision):
            fail(f"source revision is missing or invalid for {name}")
        if not isinstance(rebuilt, bool):
            fail(f"rebuilt must be a boolean for {name}")
        result[name] = {"revision": revision, "rebuilt": rebuilt}
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
    for name, version, filename in records:
        safe_asset_name(filename)
        path = payload / filename
        if not path.is_file() or path.is_symlink():
            fail(f"repository database lists missing or non-regular package asset {filename}")
        info = package_info(path)
        if info["name"] != name or info["version"] != version:
            fail(f"package metadata and repository database disagree for {name}")
        if info["packager"] != "Gooarchy":
            fail(f"{name} does not carry the Gooarchy package identity")
        if info["arch"] not in {"any", "x86_64"}:
            fail(f"{name} has unsupported architecture {info['arch']}")
        source = sources[name]
        previous = base_by_name.get(name)
        if not source["rebuilt"] and (
            previous is None
            or previous["version"] != version
            or previous["filename"] != filename
            or previous["sha256"] != sha256_file(path)
        ):
            fail(f"retained package does not match the exact base release: {name}")
        if source["rebuilt"] and previous is not None:
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
                fail(f"rebuilt package is not newer than the base release: {name}")
        packages.append(
            {
                "name": name,
                "version": version,
                "filename": filename,
                "sha256": sha256_file(path),
                "architecture": info["arch"],
                "source_revision": source["revision"],
                "rebuilt": source["rebuilt"],
            }
        )
        expected_payload.add(filename)

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
    if manifest["schema"] != SCHEMA or manifest["repository"] != REPOSITORY:
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
    for package in packages:
        if not isinstance(package, dict) or set(package) != {
            "name", "version", "filename", "sha256", "architecture", "source_revision", "rebuilt"
        }:
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
        if not isinstance(package["rebuilt"], bool):
            fail(f"rebuilt must be a boolean for {name}")
        names.add(name)
        filenames.add(filename)

    if base is None:
        if not REQUIRED_INITIAL.issubset(names):
            fail("first repository bundle is missing one or more required packages")
        if not all(package["rebuilt"] for package in packages):
            fail("first repository bundle cannot contain retained packages")
    else:
        base_by_name = {package["name"]: package for package in base["packages"]}
        if not set(base_by_name).issubset(names):
            fail("transfer bundle dropped a package from its base release")
        for package in packages:
            old = base_by_name.get(package["name"])
            if not package["rebuilt"]:
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
                    fail(f"rebuilt package is not newer than the base release: {package['name']}")

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
        if info["arch"] != package["architecture"] or info["packager"] != "Gooarchy":
            fail(f"package identity differs from the manifest: {package['name']}")
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
    flavorings_input = commands.add_parser("verify-flavorings-input")
    flavorings_input.add_argument("--archive", type=Path, required=True)
    flavorings_input.add_argument("--manifest", type=Path, required=True)
    flavorings_input.add_argument("--expected-tag", required=True)
    flavorings_input.add_argument("--expected-version", required=True)
    flavorings_stage = commands.add_parser("stage-flavorings-input")
    flavorings_stage.add_argument("--archive", type=Path, required=True)
    flavorings_stage.add_argument("--output", type=Path, required=True)
    flavorings_stage.add_argument("--manifest", type=Path, required=True)
    flavorings_stage.add_argument("--expected-tag", required=True)
    flavorings_stage.add_argument("--expected-version", required=True)
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
        elif args.command == "verify-flavorings-input":
            manifest = verify_flavorings_input(
                args.archive, args.manifest, args.expected_tag, args.expected_version
            )
            print(json.dumps({
                "package": manifest["package"],
                "version": manifest["version"],
                "filename": manifest["filename"],
                "sha256": manifest["sha256"],
                "source": manifest["source"],
                "pkgbuild_sha256": manifest["pkgbuild_sha256"],
            }, sort_keys=True, separators=(",", ":")))
        elif args.command == "stage-flavorings-input":
            manifest = stage_flavorings_input(
                args.archive, args.output, args.manifest, args.expected_tag, args.expected_version
            )
            print(json.dumps({
                "package": manifest["package"],
                "version": manifest["version"],
                "filename": manifest["filename"],
                "sha256": manifest["sha256"],
                "source": manifest["source"],
                "pkgbuild_sha256": manifest["pkgbuild_sha256"],
            }, sort_keys=True, separators=(",", ":")))
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
