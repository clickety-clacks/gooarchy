#!/usr/bin/env python3
"""Create and verify immutable Gooarchy builder-to-signer transfer manifests."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
import tarfile
from pathlib import Path
from typing import Any

SCHEMA = "gooarchy-repository-transfer-v1"
REPOSITORY = "clickety-clacks/gooarchy"
FINGERPRINT_RE = re.compile(r"^(?:[0-9A-F]{40}|[0-9A-F]{64})$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
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


def package_info(path: Path) -> dict[str, str]:
    completed = subprocess.run(
        ["bsdtar", "-xOf", str(path), ".PKGINFO"],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        fail(f"cannot read package metadata from {path.name}")
    fields: dict[str, list[str]] = {}
    for line in completed.stdout.splitlines():
        if " = " not in line:
            continue
        key, value = line.split(" = ", 1)
        fields.setdefault(key, []).append(value)
    for field in ("pkgname", "pkgver", "pkgrel", "arch", "packager"):
        if len(fields.get(field, [])) != 1 or not fields[field][0]:
            fail(f"{path.name} must contain exactly one non-empty {field} field")
    epoch = fields.get("epoch", ["0"])[0]
    version = f"{fields['pkgver'][0]}-{fields['pkgrel'][0]}"
    if epoch not in {"", "0"}:
        version = f"{epoch}:{version}"
    return {
        "name": fields["pkgname"][0],
        "version": version,
        "arch": fields["arch"][0],
        "packager": fields["packager"][0],
    }


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


def load_and_verify_bundle(bundle: Path, expected_manifest: str, expected_fingerprint: str | None) -> dict[str, Any]:
    if bundle.is_symlink() or not bundle.is_dir():
        fail("transfer bundle must be a real directory")
    bundle = bundle.resolve(strict=True)
    manifest_path = bundle / "manifest.json"
    sums_path = bundle / "SHA256SUMS"
    payload = bundle / "payload"
    root_entries = {path.name for path in bundle.iterdir()}
    if root_entries != {"manifest.json", "SHA256SUMS", "payload"}:
        fail("transfer bundle root must contain exactly manifest.json, SHA256SUMS, and payload")
    if not manifest_path.is_file() or manifest_path.is_symlink():
        fail("transfer bundle is missing a regular manifest.json")
    if not sums_path.is_file() or sums_path.is_symlink():
        fail("transfer bundle is missing a regular SHA256SUMS")
    if not payload.is_dir() or payload.is_symlink():
        fail("transfer bundle is missing a regular payload directory")
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
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    writer = commands.add_parser("write")
    writer.add_argument("--bundle", type=Path, required=True)
    writer.add_argument("--source-root", type=Path, required=True)
    writer.add_argument("--source-map", type=Path, required=True)
    writer.add_argument("--fingerprint", required=True)
    writer.add_argument("--base-json", type=Path)
    base_writer = commands.add_parser("base")
    base_writer.add_argument("--release-tag", required=True)
    base_writer.add_argument("--database", type=Path, required=True)
    base_writer.add_argument("--package-dir", type=Path, required=True)
    verifier = commands.add_parser("verify")
    verifier.add_argument("--bundle", type=Path, required=True)
    verifier.add_argument("--expected-manifest-sha256", required=True)
    verifier.add_argument("--expected-fingerprint")
    args = parser.parse_args()
    try:
        if args.command == "write":
            write_manifest(args)
        elif args.command == "base":
            write_base(args)
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
