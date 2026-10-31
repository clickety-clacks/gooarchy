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
        self.assertEqual(protocol.scottland_pair_manifest_path().name, "scottland-v0.3.5-input.json")
        self.assertEqual(manifest["source"]["repository"], "clickety-clacks/scottland")
        self.assertEqual(manifest["source"]["tag"], "v0.3.5")
        self.assertEqual(manifest["source"]["commit"], "d3e61d54d4318019678cd57c19b87d5778faab65")
        self.assertEqual(manifest["source"]["tree"], "c433206aaf1da31a8b2d671600ecefe3a66c375e")
        self.assertEqual(manifest["checksums"]["sha256"], "1d09803529cf535571030f8e031c05456a7b5c98819e3874f1d2cad235e1cc66")
        self.assertEqual(
            {item["name"]: item["sha256"] for item in manifest["packages"]},
            {
                "scottland": "5f99a6b3739210591c8fa8c0118506866bf918ea8637c0c17cd8d1844441444c",
                "scottland-omarchy": "19ddd59083b0654284e85a7ce23f3862ff94fcec7fc2533dd811b7dff10062bc",
            },
        )
        self.assertEqual({item["version"] for item in manifest["packages"]}, {"0.3.5-1"})
        core = next(item for item in manifest["packages"] if item["name"] == "scottland")
        revision = protocol.scottland_source_revision(manifest, core)
        self.assertIn("source-PKGBUILD-sha256:aabf2369", revision)
        self.assertIn("embedded-BUILDINFO-PKGBUILD-sha256:9a8c586e", revision)
        self.assertIn("source-PKGBUILD-matches-BUILDINFO:no", revision)
        self.assertIn("asset:scottland-0.3.5-1-x86_64.pkg.tar.zst sha256:5f99a6b3", revision)

    def test_previous_release_manifest_remains_exactly_pinned(self) -> None:
        historical = ROOT / "packaging/repository/scottland-v0.3.4-input.json"
        manifest = protocol.load_scottland_pair_manifest(historical)
        self.assertEqual(manifest["source"]["tag"], "v0.3.4")
        self.assertEqual({item["version"] for item in manifest["packages"]}, {"0.3.4-1"})
        self.assertEqual(
            {item["name"]: item["sha256"] for item in manifest["packages"]},
            {
                "scottland": "e6a1bf08b324ba01a38bbbdb633156827ec7cd6144c0b1dcb120d6b7fc902986",
                "scottland-omarchy": "c25611cd270bbf7dcfb5012a89223029f790e9a645c7bd6794b167dd2bd8f832",
            },
        )

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
