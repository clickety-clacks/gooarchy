#!/usr/bin/env python3
"""Check the pinned Scottland release pair import contract."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
PROTOCOL_PATH = ROOT / "packaging/repository/repository-protocol.py"
spec = importlib.util.spec_from_file_location("repository_protocol", PROTOCOL_PATH)
assert spec is not None and spec.loader is not None
protocol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protocol)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ScottlandPairTests(unittest.TestCase):
    def test_manifest_binds_exact_release_assets_and_truthful_source_provenance(self) -> None:
        manifest = protocol.load_scottland_pair_manifest()
        self.assertEqual(manifest["source"]["repository"], "clickety-clacks/scottland")
        self.assertEqual(manifest["source"]["tag"], "v0.3.4")
        self.assertEqual(manifest["source"]["commit"], "bbf09cbd6b9cb80adc9d7fa0a7cf88f6c8641f25")
        self.assertEqual(manifest["source"]["tree"], "33f1fe1bde2e647606134661db377a291829677f")
        self.assertEqual(manifest["checksums"]["sha256"], "969be4b5d480e9a762f9434d41dfb50e3b73f80deb50b37f4eb66b2031598e24")
        self.assertEqual(
            {item["name"]: item["sha256"] for item in manifest["packages"]},
            {
                "scottland": "e6a1bf08b324ba01a38bbbdb633156827ec7cd6144c0b1dcb120d6b7fc902986",
                "scottland-omarchy": "c25611cd270bbf7dcfb5012a89223029f790e9a645c7bd6794b167dd2bd8f832",
            },
        )
        core = next(item for item in manifest["packages"] if item["name"] == "scottland")
        revision = protocol.scottland_source_revision(manifest, core)
        self.assertIn("source-PKGBUILD-sha256:aabf2369", revision)
        self.assertIn("embedded-BUILDINFO-PKGBUILD-sha256:5c725899", revision)
        self.assertIn("source-PKGBUILD-matches-BUILDINFO:no", revision)
        self.assertIn("asset:scottland-0.3.4-1-x86_64.pkg.tar.zst sha256:e6a1bf08", revision)

    def test_manifest_rejects_a_changed_upstream_commit_pin(self) -> None:
        manifest = protocol.load_scottland_pair_manifest()
        manifest["source"]["commit"] = "0" * 40
        with tempfile.TemporaryDirectory(prefix="gooarchy-pair-pin-") as temporary:
            path = Path(temporary) / "pin.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "pinned upstream source"):
                protocol.load_scottland_pair_manifest(path)

    def test_package_metadata_must_match_the_exact_archives_and_dependencies(self) -> None:
        manifest = protocol.load_scottland_pair_manifest()
        for package in manifest["packages"]:
            with self.subTest(package=package["name"]):
                with tempfile.TemporaryDirectory(prefix="gooarchy-pair-metadata-") as temporary:
                    archive = Path(temporary) / package["filename"]
                    archive.write_bytes(b"synthetic package bytes")
                    package_pin = {**package, "sha256": digest(archive)}
                    expected_info = {
                        "name": package["name"],
                        "version": package["version"],
                        "arch": package["architecture"],
                        "packager": package["packager"],
                    }
                    expected_build = {
                        **expected_info,
                        "pkgbuild_sha256": package["pkgbuild_sha256"],
                        "installed": [f"wayfire-{package['wayfire_build']}-x86_64"],
                    }
                    with patch.object(protocol, "package_info", return_value=expected_info), \
                         patch.object(protocol, "build_info_details", return_value=expected_build), \
                         patch.object(protocol, "package_dependencies", return_value=[package["required_dependency"]]):
                        protocol.verify_scottland_pair_package(archive, package_pin)

                    with patch.object(protocol, "package_info", return_value=expected_info), \
                         patch.object(protocol, "build_info_details", return_value=expected_build), \
                         patch.object(protocol, "package_dependencies", return_value=["unrelated-dependency"]):
                        with self.assertRaisesRegex(ValueError, "dependency metadata"):
                            protocol.verify_scottland_pair_package(archive, package_pin)

    def test_staging_copies_the_pair_bytes_unchanged(self) -> None:
        manifest = protocol.load_scottland_pair_manifest()
        with tempfile.TemporaryDirectory(prefix="gooarchy-pair-stage-") as temporary:
            root = Path(temporary)
            source = root / "source"
            output = root / "staged"
            source.mkdir()
            output.mkdir()
            for package in manifest["packages"]:
                (source / package["filename"]).write_bytes(f"unchanged:{package['name']}".encode())
            sums = "\n".join(
                f"{item['sha256']}  {item['filename']}"
                for item in sorted(manifest["packages"], key=lambda entry: entry["filename"])
            ) + "\n"
            (source / "SHA256SUMS").write_text(sums, encoding="ascii")
            expected_record = {"source": manifest["source"], "checksums": manifest["checksums"], "packages": {}}
            with patch.object(protocol, "load_scottland_pair_manifest", return_value=manifest), \
                 patch.object(protocol, "verify_scottland_pair_input", return_value=expected_record), \
                 patch.object(protocol, "verify_scottland_pair_package"):
                observed = protocol.stage_scottland_pair_input(source, output)
            self.assertEqual(observed, expected_record)
            for package in manifest["packages"]:
                staged = output / package["filename"]
                self.assertEqual(staged.read_bytes(), (source / package["filename"]).read_bytes())
                self.assertEqual(staged.stat().st_mode & 0o777, 0o400)


if __name__ == "__main__":
    unittest.main(verbosity=2)
