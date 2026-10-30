#!/usr/bin/env python3
"""Exercise the builder-to-signer transfer contract with synthetic package data."""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
PROTOCOL_PATH = ROOT / "packaging/repository/repository-protocol.py"
spec = importlib.util.spec_from_file_location("repository_protocol", PROTOCOL_PATH)
assert spec is not None and spec.loader is not None
protocol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protocol)

NAMES = sorted(protocol.REQUIRED_INITIAL)
FINGERPRINT = "A" * 40
COMMIT = "1" * 40
TREE = "2" * 40
BASE_TAG = "gooarchy-repo-base"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def package_filename(name: str, version: str) -> str:
    return f"{name}-{version}-any.pkg.tar.zst"


def create_package(path: Path, name: str, version: str, *, packager: str = "Gooarchy") -> None:
    pkginfo = (
        f"pkgname = {name}\n"
        f"pkgbase = {name}\n"
        "xdata = pkgtype=pkg\n"
        f"pkgver = {version}\n"
        f"pkgdesc = Synthetic {name} package\n"
        "builddate = 0\n"
        "size = 1\n"
        "arch = any\n"
        f"packager = {packager}\n"
    ).encode()
    tar_bytes = io.BytesIO()
    with tarfile.open(fileobj=tar_bytes, mode="w") as archive:
        member = tarfile.TarInfo(".PKGINFO")
        member.size = len(pkginfo)
        archive.addfile(member, io.BytesIO(pkginfo))
    compressed = subprocess.run(["zstd", "-q", "-c"], input=tar_bytes.getvalue(), check=True, capture_output=True)
    path.write_bytes(compressed.stdout)


def create_database(path: Path, packages: dict[str, tuple[str, str]]) -> None:
    with tarfile.open(path, "w:gz") as archive:
        import io
        for name, (version, filename) in sorted(packages.items()):
            body = f"%NAME%\n{name}\n\n%VERSION%\n{version}\n\n%FILENAME%\n{filename}\n".encode()
            member = tarfile.TarInfo(f"{name}-{version}/desc")
            member.size = len(body)
            archive.addfile(member, io.BytesIO(body))


def write_sums(bundle: Path, files: list[str]) -> None:
    lines = [f"{sha256(bundle / 'payload' / name)}  payload/{name}" for name in sorted(files)]
    (bundle / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="ascii")


def make_bundle(parent: Path, versions: dict[str, str], *, base: dict[str, Any] | None = None,
                retained: set[str] | None = None) -> tuple[Path, str, dict[str, Any]]:
    retained = retained or set()
    bundle = parent / "transfer"
    payload = bundle / "payload"
    payload.mkdir(parents=True)
    package_records: list[dict[str, Any]] = []
    database_records: dict[str, tuple[str, str]] = {}
    for name in sorted(versions):
        version = versions[name]
        filename = package_filename(name, version)
        create_package(payload / filename, name, version)
        database_records[name] = (version, filename)
        source = f"retained from release tag:{BASE_TAG}" if name in retained else f"Gooarchy {COMMIT}"
        package_records.append({
            "name": name,
            "version": version,
            "filename": filename,
            "sha256": sha256(payload / filename),
            "architecture": "any",
            "source_revision": source,
            "origin_kind": "retained-release" if name in retained else "source-build",
        })
    create_database(payload / "gooarchy.db", database_records)
    manifest = {
        "schema": protocol.SCHEMA,
        "repository": protocol.REPOSITORY,
        "source_commit": COMMIT,
        "source_tree": TREE,
        "signing_fingerprint": FINGERPRINT,
        "base": base,
        "packages": package_records,
        "database": {"filename": "gooarchy.db", "sha256": sha256(payload / "gooarchy.db")},
    }
    manifest_path = bundle / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n")
    write_sums(bundle, ["gooarchy.db", *(record["filename"] for record in package_records)])
    return bundle, sha256(manifest_path), manifest


def make_base(parent: Path) -> tuple[dict[str, Any], dict[str, str]]:
    old_versions = {name: "1.0.0-1" for name in NAMES}
    base_dir = parent / "base"
    base_dir.mkdir()
    package_entries = []
    for name, version in old_versions.items():
        filename = package_filename(name, version)
        package_path = base_dir / filename
        create_package(package_path, name, version)
        package_entries.append({
            "name": name,
            "version": version,
            "filename": filename,
            "sha256": sha256(package_path),
            "signature_sha256": "b" * 64,
        })
    database = base_dir / "gooarchy.db"
    create_database(database, {name: (version, package_filename(name, version)) for name, version in old_versions.items()})
    base = {
        "release_tag": BASE_TAG,
        "database_sha256": sha256(database),
        "packages": package_entries,
    }
    protocol.validate_base(base)
    return base, old_versions


class RepositoryTransferTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="gooarchy-transfer-test-")
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def verify(self, bundle: Path, manifest_hash: str) -> dict[str, Any]:
        return protocol.load_and_verify_bundle(bundle, manifest_hash, FINGERPRINT)

    def test_flavorings_input_manifest_path_tracks_recipe_tag(self) -> None:
        recipe_path = ROOT / "packaging/gooarchy-flavorings/PKGBUILD"
        identity = protocol.flavorings_recipe_identity(recipe_path)
        selected = protocol.flavorings_input_manifest_path(recipe_path)
        self.assertEqual(selected, recipe_path.parent / f"{identity['source']['tag']}-input.json")
        self.assertEqual(identity["source"], {
            "repository": "clickety-clacks/gooarchy-flavorings",
            "tag": "v0.2.1",
            "commit": "a7107415e39be00fb50745788c17429932bf6829",
            "tree": "d1ec6a0ded81b8e4cb8ccb167a8679fb9f8542b6",
            "archive_sha256": "722d4cf2f83c2f1f16e27e0a2e1105a28cf46716025bf1f290565df6300763af",
        })

    def make_cua_driver_input(self) -> tuple[Path, Path, dict[str, Any], dict[str, Any], dict[str, Any]]:
        recipe_path = ROOT / "packaging/arch/cua-driver/PKGBUILD"
        identity = protocol.cua_driver_recipe_identity(recipe_path)
        archive = self.root / identity["filename"]
        archive.write_bytes(b"synthetic reviewed cua-driver archive")
        manifest = {
            "schema": protocol.PACKAGE_INPUT_SCHEMA,
            "package": identity["package"],
            "version": identity["version"],
            "architecture": identity["architecture"],
            "filename": identity["filename"],
            "sha256": sha256(archive),
            "packager": identity["packager"],
            "pkgbuild_sha256": identity["pkgbuild_sha256"],
            "depends": identity["depends"],
        }
        manifest_path = self.root / "cua-driver-input.json"
        manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")
        package = {
            "name": identity["package"],
            "version": identity["version"],
            "arch": identity["architecture"],
            "packager": identity["packager"],
        }
        build = {
            "name": identity["package"],
            "version": identity["version"],
            "arch": identity["architecture"],
            "packager": identity["packager"],
            "pkgbuild_sha256": identity["pkgbuild_sha256"],
        }
        metadata = {"package": package, "build": build, "depends": identity["depends"]}
        return archive, manifest_path, identity, manifest, metadata

    def test_cua_driver_manifest_pins_reviewed_package_and_recipe_identity(self) -> None:
        recipe_path = ROOT / "packaging/arch/cua-driver/PKGBUILD"
        identity = protocol.cua_driver_recipe_identity(recipe_path)
        manifest_path = protocol.cua_driver_input_manifest_path(recipe_path)
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

        self.assertEqual(manifest_path, recipe_path.parent / "0.38.0-1-input.json")
        self.assertEqual(manifest["package"], "cua-driver")
        self.assertEqual(manifest["version"], "0.38.0-1")
        self.assertEqual(manifest["architecture"], "x86_64")
        self.assertEqual(manifest["filename"], "cua-driver-0.38.0-1-x86_64.pkg.tar.zst")
        self.assertEqual(
            manifest["sha256"],
            "b81a651045d1ea5ccf3d63f696070db50df5eb0978971bcbec3f14e3a95cbd87",
        )
        self.assertEqual(manifest["packager"], "Gooarchy")
        self.assertEqual(manifest["pkgbuild_sha256"], identity["pkgbuild_sha256"])
        self.assertEqual(manifest["depends"], identity["depends"])

    def test_prebuilt_cua_driver_is_verified_and_staged_byte_for_byte(self) -> None:
        archive, manifest_path, _identity, _manifest, metadata = self.make_cua_driver_input()
        recipe_path = ROOT / "packaging/arch/cua-driver/PKGBUILD"
        output_dir = self.root / "staged"
        output_dir.mkdir()
        output = output_dir / archive.name
        original = archive.read_bytes()

        with patch.object(protocol, "package_info", return_value=metadata["package"]), \
             patch.object(protocol, "build_info", return_value=metadata["build"]), \
             patch.object(protocol, "package_dependencies", return_value=metadata["depends"]):
            verified = protocol.verify_cua_driver_input(archive, manifest_path, recipe_path)
            staged = protocol.stage_cua_driver_input(archive, output, manifest_path, recipe_path)

        self.assertEqual(staged, verified)
        self.assertEqual(output.read_bytes(), original)
        self.assertEqual(sha256(output), verified["sha256"])
        self.assertEqual(output.stat().st_mode & 0o777, 0o400)

    def test_prebuilt_cua_driver_rejects_hash_and_metadata_mismatches(self) -> None:
        archive, manifest_path, _identity, manifest, metadata = self.make_cua_driver_input()
        recipe_path = ROOT / "packaging/arch/cua-driver/PKGBUILD"
        manifest["sha256"] = "0" * 64
        manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "package hash does not match"):
            protocol.verify_cua_driver_input(archive, manifest_path, recipe_path)

        manifest["sha256"] = sha256(archive)
        manifest["depends"] = ["unexpected-dependency"]
        manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "depends does not match"):
            protocol.verify_cua_driver_input(archive, manifest_path, recipe_path)

        manifest["depends"] = metadata["depends"]
        manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with patch.object(protocol, "package_info", return_value={**metadata["package"], "name": "other"}):
            with self.assertRaisesRegex(ValueError, "PKGINFO does not match"):
                protocol.verify_cua_driver_input(archive, manifest_path, recipe_path)

        with patch.object(protocol, "package_info", return_value=metadata["package"]), \
             patch.object(protocol, "build_info", return_value={**metadata["build"], "pkgbuild_sha256": "1" * 64}):
            with self.assertRaisesRegex(ValueError, "BUILDINFO does not match"):
                protocol.verify_cua_driver_input(archive, manifest_path, recipe_path)

    def test_cua_driver_prebuilt_origin_is_written_and_verified_in_transfer_manifest(self) -> None:
        versions = {name: "1.0.0-1" for name in NAMES}
        bundle, _, base_manifest = make_bundle(self.root, versions)
        payload = bundle / "payload"
        archive, input_manifest_path, identity, input_manifest, cua_metadata = self.make_cua_driver_input()
        staged_input = payload / identity["filename"]
        shutil.copyfile(archive, staged_input)
        database_records = {
            item["name"]: (item["version"], item["filename"])
            for item in base_manifest["packages"]
        }
        database_records["cua-driver"] = (identity["version"], identity["filename"])
        create_database(payload / "gooarchy.db", database_records)

        source_map = {
            name: {"revision": f"Gooarchy {COMMIT}", "origin_kind": "source-build"}
            for name in NAMES
        }
        source_map["cua-driver"] = {
            "revision": protocol.cua_driver_source_revision(input_manifest),
            "origin_kind": "prebuilt-input",
        }
        source_map_path = self.root / "sources.json"
        source_map_path.write_text(json.dumps(source_map), encoding="utf-8")
        package_metadata = {
            item["filename"]: {
                "name": item["name"], "version": item["version"],
                "arch": item["architecture"], "packager": "Gooarchy",
            }
            for item in base_manifest["packages"]
        }
        package_metadata[identity["filename"]] = cua_metadata["package"]

        with patch.object(protocol, "package_info", side_effect=lambda path: package_metadata[path.name]), \
             patch.object(protocol, "build_info", return_value=cua_metadata["build"]), \
             patch.object(protocol, "package_dependencies", return_value=cua_metadata["depends"]), \
             patch.object(protocol, "cua_driver_input_manifest_path", return_value=input_manifest_path):
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                protocol.write_manifest(SimpleNamespace(
                    bundle=bundle,
                    source_root=ROOT,
                    source_map=source_map_path,
                    fingerprint=FINGERPRINT,
                    base_json=None,
                ))
            transfer = self.verify(bundle, stdout.getvalue().strip())

        record = next(item for item in transfer["packages"] if item["name"] == "cua-driver")
        self.assertEqual(record["origin_kind"], "prebuilt-input")
        self.assertEqual(record["filename"], identity["filename"])
        self.assertEqual(record["sha256"], sha256(staged_input))
        self.assertEqual(record["source_revision"], source_map["cua-driver"]["revision"])

    def make_flavorings_input(self) -> tuple[Path, Path, str, str, dict[str, str]]:
        recipe_path = ROOT / "packaging/gooarchy-flavorings/PKGBUILD"
        identity = protocol.flavorings_recipe_identity(recipe_path)
        version = identity["version"]
        tag = identity["source"]["tag"]
        filename = f"gooarchy-flavorings-{version}-any.pkg.tar.zst"
        archive = self.root / filename
        archive.write_bytes(b"synthetic pinned Flavorings archive")
        manifest = {
            "schema": protocol.PACKAGE_INPUT_SCHEMA,
            "package": "gooarchy-flavorings",
            "version": version,
            "architecture": "any",
            "filename": filename,
            "sha256": sha256(archive),
            "packager": "Gooarchy",
            "pkgbuild_sha256": "c" * 64,
            "source": identity["source"],
        }
        manifest_path = self.root / f"{tag}-input.json"
        manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")
        pkginfo = (
            "pkgname = gooarchy-flavorings\n"
            f"pkgver = {version}\n"
            "arch = any\n"
            "packager = Gooarchy\n"
        )
        buildinfo = (
            "pkgname = gooarchy-flavorings\n"
            f"pkgver = {version}\n"
            "pkgarch = any\n"
            "packager = Gooarchy\n"
            f"pkgbuild_sha256sum = {manifest['pkgbuild_sha256']}\n"
        )
        metadata = {".PKGINFO": pkginfo, ".BUILDINFO": buildinfo}
        return archive, manifest_path, tag, version, metadata

    def test_prebuilt_flavorings_input_matches_source_archive_and_package_metadata(self) -> None:
        archive, manifest_path, tag, version, metadata = self.make_flavorings_input()

        def fake_bsdtar(args, **kwargs):
            text = metadata.get(args[-1])
            return SimpleNamespace(returncode=0 if text is not None else 1, stdout=text or "", stderr="")

        with patch.object(protocol.subprocess, "run", side_effect=fake_bsdtar):
            observed = protocol.verify_flavorings_input(
                archive, manifest_path, ROOT / "packaging/gooarchy-flavorings/PKGBUILD"
            )
        self.assertEqual(observed["source"]["tag"], tag)
        self.assertEqual(observed["source"]["commit"], "a7107415e39be00fb50745788c17429932bf6829")
        self.assertEqual(observed["sha256"], sha256(archive))
        source = observed["source"]
        self.assertEqual(
            protocol.flavorings_source_revision(observed),
            "Flavorings tag:{} commit:{} tree:{}; source archive SHA256:{}; "
            "PKGBUILD SHA256:{}; imported package SHA256:{}".format(
                source["tag"], source["commit"], source["tree"], source["archive_sha256"],
                observed["pkgbuild_sha256"], observed["sha256"],
            ),
        )

    def test_prebuilt_flavorings_input_rejects_wrong_tag_version_hash_and_build_identity(self) -> None:
        archive, manifest_path, _tag, _version, metadata = self.make_flavorings_input()
        recipe_path = ROOT / "packaging/gooarchy-flavorings/PKGBUILD"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["source"]["tag"] = "v0.2.2"
        manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "does not match the current recipe"):
            protocol.verify_flavorings_input(archive, manifest_path, recipe_path)

        manifest["source"]["tag"] = "v0.2.1"
        manifest["version"] = "0.2.2-1"
        manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "does not match the current recipe"):
            protocol.verify_flavorings_input(archive, manifest_path, recipe_path)

        manifest["version"] = _version
        manifest["sha256"] = "e" * 64
        manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "package hash does not match"):
            protocol.verify_flavorings_input(archive, manifest_path, recipe_path)

        manifest["sha256"] = sha256(archive)
        manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        metadata[".BUILDINFO"] = metadata[".BUILDINFO"].replace("packager = Gooarchy", "packager = Unknown Packager")

        def fake_bsdtar(args, **kwargs):
            text = metadata.get(args[-1])
            return SimpleNamespace(returncode=0 if text is not None else 1, stdout=text or "", stderr="")

        with patch.object(protocol.subprocess, "run", side_effect=fake_bsdtar):
            with self.assertRaisesRegex(ValueError, "BUILDINFO does not match"):
                protocol.verify_flavorings_input(archive, manifest_path, recipe_path)

    def test_prebuilt_flavorings_input_rejects_unmatched_commit_tree_or_source_archive(self) -> None:
        archive, manifest_path, _tag, _version, _metadata = self.make_flavorings_input()
        recipe_path = ROOT / "packaging/gooarchy-flavorings/PKGBUILD"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        for field, replacement in (
            ("commit", "0" * 40),
            ("tree", "1" * 40),
            ("archive_sha256", "2" * 64),
        ):
            with self.subTest(field=field):
                manifest["source"][field] = replacement
                manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "source identity does not match the current recipe"):
                    protocol.verify_flavorings_input(archive, manifest_path, recipe_path)
                manifest["source"] = protocol.flavorings_recipe_identity(recipe_path)["source"]

    def test_staged_flavorings_input_rejects_source_swap_after_initial_verification(self) -> None:
        archive, manifest_path, tag, version, metadata = self.make_flavorings_input()
        recipe_path = ROOT / "packaging/gooarchy-flavorings/PKGBUILD"
        staged_dir = self.root / "built"
        staged_dir.mkdir()
        staged_archive = staged_dir / archive.name

        def fake_bsdtar(args, **kwargs):
            text = metadata.get(args[-1])
            return SimpleNamespace(returncode=0 if text is not None else 1, stdout=text or "", stderr="")

        with patch.object(protocol.subprocess, "run", side_effect=fake_bsdtar):
            verified = protocol.verify_flavorings_input(archive, manifest_path, recipe_path)
            original_bytes = archive.read_bytes()
            archive.write_bytes(b"replacement after validation")
            with self.assertRaisesRegex(ValueError, "package hash does not match"):
                protocol.stage_flavorings_input(archive, staged_archive, manifest_path, recipe_path)
            self.assertFalse(staged_archive.exists())

            archive.write_bytes(original_bytes)
            staged = protocol.stage_flavorings_input(archive, staged_archive, manifest_path, recipe_path)
            archive.write_bytes(b"replacement after private staging")

        self.assertEqual(staged["sha256"], verified["sha256"])
        self.assertEqual(sha256(staged_archive), verified["sha256"])
        self.assertEqual(staged_archive.stat().st_mode & 0o777, 0o400)

    def test_complete_initial_snapshot_matches_database_and_manifest(self) -> None:
        versions = {name: "1.0.0-1" for name in NAMES}
        bundle, manifest_hash, manifest = make_bundle(self.root, versions)
        observed = self.verify(bundle, manifest_hash)
        self.assertEqual(observed["source_commit"], COMMIT)
        self.assertEqual(observed["source_tree"], TREE)
        self.assertEqual(len(observed["packages"]), 6)
        self.assertEqual({item["name"] for item in observed["packages"]}, protocol.REQUIRED_INITIAL)

    def test_builder_transfer_stops_before_signature_artifacts(self) -> None:
        versions = {name: "1.0.0-1" for name in NAMES}
        bundle, manifest_hash, manifest = make_bundle(self.root, versions)
        expected_payload = {"gooarchy.db", *(record["filename"] for record in manifest["packages"])}
        self.assertEqual(
            {path.name for path in bundle.iterdir()},
            {"manifest.json", "SHA256SUMS", "payload"},
        )
        self.assertEqual({path.name for path in (bundle / "payload").iterdir()}, expected_payload)
        self.assertFalse(any(path.name.endswith(".sig") for path in (bundle / "payload").iterdir()))

        # This check targets transfer-envelope custody; package metadata parsing has its own test.
        metadata = {
            record["filename"]: {
                "name": record["name"],
                "version": record["version"],
                "arch": "any",
                "packager": "Gooarchy",
            }
            for record in manifest["packages"]
        }
        with patch.object(protocol, "package_info", side_effect=lambda path: metadata[path.name]):
            self.verify(bundle, manifest_hash)

            signature = bundle / "payload" / "gooarchy.db.sig"
            signature.write_bytes(b"synthetic signature artifact")
            with self.assertRaisesRegex(ValueError, "payload files do not exactly match"):
                self.verify(bundle, manifest_hash)

            signature.unlink()
            (bundle / "signatures").mkdir()
            (bundle / "SIGNATURES.json").write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "root has unexpected entries"):
                self.verify(bundle, manifest_hash)

    def test_primary_and_backup_receipts_bind_the_same_complete_transfer(self) -> None:
        versions = {name: "1.0.0-1" for name in NAMES}
        bundle, manifest_hash, manifest = make_bundle(self.root, versions)
        expected_payloads = {
            record["filename"]: record["sha256"] for record in manifest["packages"]
        }
        expected_payloads["gooarchy.db"] = manifest["database"]["sha256"]
        package_metadata = {
            record["filename"]: {
                "name": record["name"],
                "version": record["version"],
                "arch": "any",
                "packager": "Gooarchy",
            }
            for record in manifest["packages"]
        }
        observed_payloads: dict[str, dict[str, str]] = {}

        # These synthetic .sig files exercise receipt and bundle binding only; no key or GPG is used.
        with patch.object(protocol, "package_info", side_effect=lambda path: package_metadata[path.name]):
            for role in ("primary", "backup"):
                signed = self.root / f"signed-{role}"
                signed.mkdir()
                shutil.copy2(bundle / "manifest.json", signed / "manifest.json")
                shutil.copy2(bundle / "SHA256SUMS", signed / "SHA256SUMS")
                shutil.copytree(bundle / "payload", signed / "payload")
                signatures = signed / "signatures"
                signatures.mkdir()
                for filename in expected_payloads:
                    (signatures / f"{filename}.sig").write_bytes(
                        f"synthetic-only:{role}:{filename}".encode("ascii")
                    )

                protocol.write_signature_receipt(SimpleNamespace(
                    bundle=bundle,
                    signatures=signatures,
                    expected_manifest_sha256=manifest_hash,
                    fingerprint=FINGERPRINT,
                    signer_role=role,
                    output=signed / "SIGNATURES.json",
                ))
                verified_manifest = protocol.load_and_verify_bundle(
                    signed, manifest_hash, FINGERPRINT, signed=True
                )
                receipt = json.loads((signed / "SIGNATURES.json").read_text(encoding="utf-8"))
                self.assertEqual(verified_manifest["source_commit"], COMMIT)
                self.assertEqual(verified_manifest["source_tree"], TREE)
                self.assertEqual(receipt["signer_role"], role)
                self.assertEqual(receipt["manifest_sha256"], manifest_hash)
                self.assertEqual(receipt["signing_fingerprint"], FINGERPRINT)
                self.assertEqual(
                    {entry["filename"]: entry["payload_sha256"] for entry in receipt["signatures"]},
                    expected_payloads,
                )
                self.assertEqual(
                    {path.name for path in signatures.iterdir()},
                    {f"{filename}.sig" for filename in expected_payloads},
                )
                observed_payloads[role] = {
                    entry["filename"]: entry["payload_sha256"]
                    for entry in receipt["signatures"]
                }

        self.assertEqual(observed_payloads["primary"], observed_payloads["backup"])

    def test_backup_uploader_role_fails_before_token_or_release_clients(self) -> None:
        private_bin = self.root / "bin"
        private_bin.mkdir()
        for command in ("bash", "cat", "dirname", "git"):
            target = shutil.which(command)
            self.assertIsNotNone(target, f"test requires local {command}")
            (private_bin / command).symlink_to(target)

        markers = self.root / "markers"
        markers.mkdir()
        for command in ("curl", "op"):
            client = private_bin / command
            client.write_text(
                f'#!/bin/sh\nprintf called > "$GOOARCHY_TEST_MARKER_DIR/{command}"\nexit 97\n',
                encoding="utf-8",
            )
            client.chmod(0o700)

        signed_bundle = self.root / "signed-bundle"
        signed_bundle.mkdir()
        result = subprocess.run(
            [
                str(ROOT / "packaging/repository/upload.sh"),
                "--uploader-role", "backup",
                "--signed-bundle", str(signed_bundle),
                "--manifest-sha256", "a" * 64,
            ],
            capture_output=True,
            text=True,
            check=False,
            env={
                "PATH": str(private_bin),
                "LC_ALL": "C",
                "GOOARCHY_TEST_MARKER_DIR": str(markers),
            },
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("Usage:", result.stderr)
        self.assertIn("--uploader-role primary", result.stderr)
        self.assertEqual(list(markers.iterdir()), [])

    def test_pkginfo_version_uses_full_arch_pkgver_field(self) -> None:
        path = self.root / package_filename("gooarchy", "2:1.2.3-4")
        create_package(path, "gooarchy", "2:1.2.3-4")
        self.assertEqual(protocol.package_info(path)["version"], "2:1.2.3-4")

    def test_package_info_cli_preserves_full_arch_pkgver_field(self) -> None:
        pkginfo = (
            "pkgname = gooarchy\n"
            "pkgver = 2:1.2.3-4\n"
            "arch = x86_64\n"
            "packager = Gooarchy\n"
        )
        result = subprocess.run(
            [sys.executable, str(PROTOCOL_PATH), "package-info", "--stdin"],
            input=pkginfo,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["version"], "2:1.2.3-4")

    def test_pkginfo_parser_rejects_ambiguous_version_fields(self) -> None:
        pkginfo = (
            "pkgname = gooarchy\n"
            "pkgver = 1.2.3-1\n"
            "pkgver = 9.9.9-9\n"
            "arch = x86_64\n"
            "packager = Gooarchy\n"
        )
        result = subprocess.run(
            [sys.executable, str(PROTOCOL_PATH), "package-info", "--stdin"],
            input=pkginfo,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("exactly one non-empty pkgver field", result.stderr)

    def test_manifest_writer_binds_source_tree_and_package_records(self) -> None:
        versions = {name: "1.0.0-1" for name in NAMES}
        bundle, _, _ = make_bundle(self.root, versions)
        source_map_path = self.root / "sources.json"
        source_map_path.write_text(json.dumps({
            name: {"revision": f"Gooarchy {COMMIT}", "origin_kind": "source-build"}
            for name in NAMES
        }))
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            protocol.write_manifest(SimpleNamespace(
                bundle=bundle,
                source_root=ROOT,
                source_map=source_map_path,
                fingerprint=FINGERPRINT,
                base_json=None,
            ))
        manifest_hash = stdout.getvalue().strip()
        observed = self.verify(bundle, manifest_hash)
        self.assertEqual(observed["source_commit"], subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True
        ).strip())
        self.assertEqual(observed["source_tree"], subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD^{tree}"], text=True
        ).strip())

    def test_legacy_transfer_manifest_remains_verifiable(self) -> None:
        versions = {name: "1.0.0-1" for name in NAMES}
        bundle, _manifest_hash, manifest = make_bundle(self.root, versions)
        manifest["schema"] = protocol.LEGACY_SCHEMA
        for package in manifest["packages"]:
            package["rebuilt"] = package.pop("origin_kind") == "source-build"
        manifest_path = bundle / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n")
        observed = self.verify(bundle, sha256(manifest_path))
        self.assertEqual(observed["schema"], protocol.LEGACY_SCHEMA)

    def test_signed_upstream_pair_manifest_covers_unknown_packager_assets(self) -> None:
        versions = {name: "1.0.0-1" for name in NAMES}
        versions["scottland-omarchy"] = "1.0.0-1"
        bundle, _manifest_hash, manifest = make_bundle(self.root, versions)
        payload = bundle / "payload"
        pair_records: dict[str, dict[str, Any]] = {}
        fake_source = {
            "repository": protocol.SCOTTLAND_REPOSITORY,
            "tag": "v0.3.4",
            "commit": "3" * 40,
            "tree": "4" * 40,
            "release_url": "https://github.com/clickety-clacks/scottland/releases/tag/v0.3.4",
            "source_pkgbuild_sha256": "5" * 64,
        }
        fake_checksums = {"filename": "SHA256SUMS", "sha256": "6" * 64}
        for name in sorted(protocol.SCOTTLAND_PACKAGE_NAMES):
            filename = package_filename(name, versions[name])
            path = payload / filename
            create_package(path, name, versions[name], packager="Unknown Packager")
            entry = {
                "name": name,
                "version": versions[name],
                "architecture": "any",
                "filename": filename,
                "sha256": sha256(path),
                "packager": "Unknown Packager",
                "pkgbuild_sha256": "7" * 64,
                "wayfire_build": "0.11.0-1",
                "required_dependency": "wayfire" if name == "scottland" else "scottland=0.3.4-1",
            }
            pair_records[name] = entry
            package_record = next(item for item in manifest["packages"] if item["name"] == name)
            package_record.update({
                "filename": filename,
                "sha256": entry["sha256"],
                "architecture": "any",
                "source_revision": protocol.scottland_source_revision(
                    {"source": fake_source, "checksums": fake_checksums}, entry
                ),
                "origin_kind": "upstream-release",
            })
        checksum_files = ["gooarchy.db", *(entry["filename"] for entry in manifest["packages"])]
        write_sums(bundle, checksum_files)
        manifest_path = bundle / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n")
        manifest_hash = sha256(manifest_path)
        pair_pin = {"source": fake_source, "checksums": fake_checksums, "packages": list(pair_records.values())}

        expected_payloads = {
            entry["filename"]: entry["sha256"] for entry in manifest["packages"]
        }
        expected_payloads["gooarchy.db"] = manifest["database"]["sha256"]
        with patch.object(protocol, "load_scottland_pair_manifest", return_value=pair_pin), \
             patch.object(protocol, "verify_scottland_pair_package"), \
             patch.object(protocol, "package_info", side_effect=lambda path: {
                 "name": next(item["name"] for item in manifest["packages"] if item["filename"] == path.name),
                 "version": next(item["version"] for item in manifest["packages"] if item["filename"] == path.name),
                 "arch": next(item["architecture"] for item in manifest["packages"] if item["filename"] == path.name),
                 "packager": "Unknown Packager" if path.name in {item["filename"] for item in pair_records.values()} else "Gooarchy",
             }):
            signed = self.root / "signed-upstream"
            signed.mkdir()
            shutil.copy2(manifest_path, signed / "manifest.json")
            shutil.copy2(bundle / "SHA256SUMS", signed / "SHA256SUMS")
            shutil.copytree(payload, signed / "payload")
            signatures = signed / "signatures"
            signatures.mkdir()
            for filename in expected_payloads:
                (signatures / f"{filename}.sig").write_bytes(f"synthetic:{filename}".encode())
            protocol.write_signature_receipt(SimpleNamespace(
                bundle=bundle,
                signatures=signatures,
                expected_manifest_sha256=manifest_hash,
                fingerprint=FINGERPRINT,
                signer_role="primary",
                output=signed / "SIGNATURES.json",
            ))
            (signed / "SHA256SUMS").write_text((bundle / "SHA256SUMS").read_text())
            observed = protocol.load_and_verify_bundle(signed, manifest_hash, FINGERPRINT, signed=True)
        self.assertEqual(
            {item["name"] for item in observed["packages"] if item["origin_kind"] == "upstream-release"},
            protocol.SCOTTLAND_PACKAGE_NAMES,
        )
        self.assertEqual(
            {entry["filename"]: entry["payload_sha256"] for entry in json.loads((signed / "SIGNATURES.json").read_text())["signatures"]},
            expected_payloads,
        )

    def test_transfer_hash_rejects_tampering_and_wrong_out_of_band_hash(self) -> None:
        versions = {name: "1.0.0-1" for name in NAMES}
        bundle, manifest_hash, _ = make_bundle(self.root, versions)
        with self.assertRaisesRegex(ValueError, "manifest hash"):
            self.verify(bundle, "0" * 64)
        target = bundle / "payload" / package_filename(NAMES[0], "1.0.0-1")
        target.write_bytes(target.read_bytes() + b"tampered")
        with self.assertRaisesRegex(ValueError, "SHA256SUMS|package hash"):
            self.verify(bundle, manifest_hash)

    def test_extra_payload_is_rejected(self) -> None:
        versions = {name: "1.0.0-1" for name in NAMES}
        bundle, manifest_hash, _ = make_bundle(self.root, versions)
        (bundle / "payload" / "unlisted.pkg.tar.zst").write_bytes(b"unexpected")
        with self.assertRaisesRegex(ValueError, "exactly match"):
            self.verify(bundle, manifest_hash)

    def test_database_records_must_match_signed_manifest_identity(self) -> None:
        versions = {name: "1.0.0-1" for name in NAMES}
        bundle, _, manifest = make_bundle(self.root, versions)
        mismatched = dict(versions)
        mismatched[NAMES[0]] = "1.0.0-2"
        create_database(bundle / "payload" / "gooarchy.db", {
            name: (version, package_filename(name, version))
            for name, version in mismatched.items()
        })
        manifest["database"]["sha256"] = sha256(bundle / "payload" / "gooarchy.db")
        manifest_path = bundle / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n")
        write_sums(bundle, ["gooarchy.db", *(record["filename"] for record in manifest["packages"])])
        with self.assertRaisesRegex(ValueError, "database package records"):
            self.verify(bundle, sha256(manifest_path))

    def test_base_upgrade_keeps_unchanged_packages_and_advances_rebuilt_package(self) -> None:
        base, old = make_base(self.root)
        versions = dict(old)
        versions["gooarchy"] = "2.0.0-1"
        bundle, manifest_hash, manifest = make_bundle(
            self.root, versions, base=base, retained=set(NAMES) - {"gooarchy"}
        )
        # The base validator compares versions with Arch's comparator. This fixture uses only numeric versions.
        old_run = protocol.subprocess.run
        def fake_run(args, **kwargs):
            if args[0] == "vercmp":
                def parts(value: str) -> tuple[int, ...]:
                    return tuple(int(part) for part in re.findall(r"\d+", value))
                a, b = parts(args[1]), parts(args[2])
                return type("Result", (), {"stdout": str((a > b) - (a < b))})()
            return old_run(args, **kwargs)
        protocol.subprocess.run = fake_run
        try:
            observed = self.verify(bundle, manifest_hash)
        finally:
            protocol.subprocess.run = old_run
        self.assertEqual(observed["base"]["release_tag"], BASE_TAG)
        self.assertEqual(len(manifest["packages"]), 6)

    def test_base_upgrade_rejects_nonadvancing_rebuild(self) -> None:
        base, old = make_base(self.root)
        bundle, manifest_hash, _ = make_bundle(
            self.root, old, base=base, retained=set(NAMES) - {"gooarchy"}
        )
        old_run = protocol.subprocess.run
        def fake_run(args, **kwargs):
            if args[0] == "vercmp":
                return type("Result", (), {"stdout": "0"})()
            return old_run(args, **kwargs)
        protocol.subprocess.run = fake_run
        try:
            with self.assertRaisesRegex(ValueError, "not newer"):
                self.verify(bundle, manifest_hash)
        finally:
            protocol.subprocess.run = old_run

    def test_retired_single_machine_entry_point_fails_closed(self) -> None:
        result = subprocess.run(
            [str(ROOT / "packaging/repository/publish.sh")],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("single-machine publisher is retired", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
