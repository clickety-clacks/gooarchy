#!/usr/bin/env python3
"""Exercise release promotion rules without credentials or network access."""

from __future__ import annotations

import hashlib
import io
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "packaging/repository/release-api.py"
SPEC = importlib.util.spec_from_file_location("gooarchy_release_api", MODULE_PATH)
assert SPEC and SPEC.loader
release_api = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release_api
SPEC.loader.exec_module(release_api)


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class FakeReleaseAPI:
    def __init__(self, base_tag: str = "previous"):
        self.latest = base_tag
        self.tag = "gooarchy-repo-test"
        self.draft = False
        self.upload_url = "https://uploads.github.com/repos/clickety-clacks/gooarchy/releases/17/assets{?name,label}"
        self.assets: dict[str, bytes] = {}
        self.promotions = 0
        self.omit_asset = False
        self.corrupt_asset: str | None = None
        self.latest_change_during_upload: str | None = None

    def current_latest(self) -> str:
        return self.latest

    def tag_exists(self, tag: str) -> bool:
        return False

    def create_draft(self, tag: str, source_commit: str, title: str, body: str) -> dict:
        self.tag = tag
        self.draft = True
        return {
            "id": 17,
            "upload_url": self.upload_url,
            "tag_name": tag,
            "draft": True,
            "prerelease": False,
        }

    def upload_asset(self, upload_url: str, release_id: int, asset) -> dict:
        self.assets[asset.name] = asset.path.read_bytes()
        if self.latest_change_during_upload:
            self.latest = self.latest_change_during_upload
        return {"name": asset.name, "state": "uploaded", "size": asset.size}

    def release_assets(self, release_id: int) -> list[dict]:
        names = sorted(self.assets)
        if self.omit_asset and names:
            names = names[:-1]
        return [
            {
                "id": index + 1,
                "name": name,
                "state": "uploaded",
                "size": len(self.assets[name]),
                "digest": f"sha256:{digest(self.assets[name])}",
            }
            for index, name in enumerate(names)
        ]

    def read_asset_digest(self, asset_id: int) -> tuple[str, int]:
        name = sorted(self.assets)[asset_id - 1]
        value = self.assets[name]
        if self.corrupt_asset == name:
            value += b"changed"
        return digest(value), len(value)

    def get_release(self, release_id: int) -> dict:
        return {"id": 17, "tag_name": self.tag, "draft": self.draft, "prerelease": False}

    def promote_latest(self, release_id: int) -> dict:
        self.promotions += 1
        self.latest = self.tag
        self.draft = False
        return self.get_release(release_id)


class ReleaseAPITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="gooarchy-release-api-test-")
        self.root = Path(self.temporary.name)
        self.assets = self.root / "assets"
        self.assets.mkdir()
        self.asset_bytes = {
            "gooarchy.db": b"repository database bytes",
            "gooarchy-1.0.0-1-any.pkg.tar.zst": b"package bytes",
        }
        for name, value in self.asset_bytes.items():
            (self.assets / name).write_bytes(value)
        self.manifest = {
            "schema": "gooarchy-repository-transfer-v1",
            "repository": "clickety-clacks/gooarchy",
            "source_commit": "a" * 40,
            "source_tree": "b" * 40,
            "signing_fingerprint": "D" * 40,
            "base": {
                "release_tag": "previous",
                "database_sha256": "c" * 64,
                "packages": [],
            },
            "packages": [
                {
                    "name": "gooarchy",
                    "version": "1.0.0-1",
                    "filename": "gooarchy-1.0.0-1-any.pkg.tar.zst",
                    "sha256": digest(self.asset_bytes["gooarchy-1.0.0-1-any.pkg.tar.zst"]),
                }
            ],
            "database": {
                "filename": "gooarchy.db",
                "sha256": digest(self.asset_bytes["gooarchy.db"]),
            },
        }
        signature_entries = []
        for name, value in self.asset_bytes.items():
            signature = b"signature for " + value
            (self.assets / f"{name}.sig").write_bytes(signature)
            signature_entries.append({
                "filename": name,
                "payload_sha256": digest(value),
                "signature_filename": f"{name}.sig",
                "signature_sha256": digest(signature),
            })
        self.manifest_path = self.root / "manifest.json"
        self.manifest_path.write_text(json.dumps(self.manifest, sort_keys=True, separators=(",", ":")) + "\n")
        self.manifest_hash = digest(self.manifest_path.read_bytes())
        self.signatures_path = self.root / "SIGNATURES.json"
        self.signatures_path.write_text(json.dumps({
            "schema": "gooarchy-repository-signatures-v1",
            "manifest_sha256": self.manifest_hash,
            "signer_role": "primary",
            "signing_fingerprint": "D" * 40,
            "signatures": signature_entries,
        }, sort_keys=True, separators=(",", ":")) + "\n")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def publish(self, api: FakeReleaseAPI) -> None:
        release_api.publish_release(
            api,
            manifest_path=self.manifest_path,
            signatures_path=self.signatures_path,
            asset_dir=self.assets,
            manifest_sha256=self.manifest_hash,
            release_tag="gooarchy-repo-test",
            source_commit="a" * 40,
            source_tree="b" * 40,
            signer_role="primary",
        )

    def test_latest_moves_only_after_exact_assets_are_read_back(self) -> None:
        api = FakeReleaseAPI()
        self.publish(api)
        self.assertEqual(api.promotions, 1)
        self.assertEqual(api.latest, "gooarchy-repo-test")
        self.assertEqual(set(api.assets), {path.name for path in self.assets.iterdir()})

    def test_incomplete_draft_never_promotes_latest(self) -> None:
        api = FakeReleaseAPI()
        api.omit_asset = True
        with self.assertRaisesRegex(release_api.ReleaseError, "asset count"):
            self.publish(api)
        self.assertEqual(api.promotions, 0)
        self.assertEqual(api.latest, "previous")
        self.assertTrue(api.draft)

    def test_changed_asset_bytes_never_promote_latest(self) -> None:
        api = FakeReleaseAPI()
        api.corrupt_asset = "gooarchy.db"
        with self.assertRaisesRegex(release_api.ReleaseError, "byte readback differs"):
            self.publish(api)
        self.assertEqual(api.promotions, 0)
        self.assertEqual(api.latest, "previous")

    def test_latest_change_during_upload_leaves_draft_unpublished(self) -> None:
        api = FakeReleaseAPI()
        api.latest_change_during_upload = "concurrent-release"
        with self.assertRaisesRegex(release_api.ReleaseError, "changed during upload"):
            self.publish(api)
        self.assertEqual(api.promotions, 0)
        self.assertEqual(api.latest, "concurrent-release")
        self.assertTrue(api.draft)

    def test_extra_asset_is_rejected_before_remote_draft_creation(self) -> None:
        (self.assets / "unexpected.sig").write_bytes(b"extra")
        api = FakeReleaseAPI()
        with self.assertRaisesRegex(release_api.ReleaseError, "does not exactly match"):
            self.publish(api)
        self.assertEqual(api.promotions, 0)
        self.assertEqual(api.assets, {})

    def test_manifest_payload_hash_mismatch_is_rejected_before_draft_creation(self) -> None:
        (self.assets / "gooarchy.db").write_bytes(b"tampered database")
        api = FakeReleaseAPI()
        with self.assertRaisesRegex(release_api.ReleaseError, "manifest or signature receipt"):
            self.publish(api)
        self.assertEqual(api.promotions, 0)
        self.assertEqual(api.assets, {})

    def test_transfer_base_must_still_be_latest_before_draft_creation(self) -> None:
        api = FakeReleaseAPI(base_tag="newer-release")
        with self.assertRaisesRegex(release_api.ReleaseError, "no longer matches the transfer base"):
            self.publish(api)
        self.assertEqual(api.promotions, 0)
        self.assertEqual(api.assets, {})

    def test_token_input_rejects_empty_or_multiline_values(self) -> None:
        for value in (b"", b"token\nsecond-line\n"):
            with self.subTest(value=value), self.assertRaises(release_api.ReleaseError):
                release_api.read_upload_token(io.BytesIO(value))

    def test_rest_request_keeps_token_in_authorization_header(self) -> None:
        class Response(io.BytesIO):
            status = 201
            headers = {}

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                self.close()

        class Opener:
            request = None

            def open(self, request, timeout):
                self.request = request
                return Response(b'{"id":17}')

        api = release_api.GitHubReleaseAPI("synthetic-token")
        opener = Opener()
        api._opener = opener
        self.assertEqual(api._request_json("POST", "/releases", {"draft": True}), {"id": 17})
        self.assertEqual(opener.request.get_header("Authorization"), "Bearer synthetic-token")
        self.assertNotIn("synthetic-token", opener.request.full_url)
        self.assertEqual(opener.request.get_header("X-github-api-version"), release_api.API_VERSION)

    def test_asset_upload_includes_user_agent_header(self) -> None:
        asset_path = self.assets / "gooarchy.db"
        asset = release_api.Asset(
            name=asset_path.name,
            path=asset_path,
            size=asset_path.stat().st_size,
            sha256=digest(asset_path.read_bytes()),
        )

        class Response:
            status = 201

            def read(self, _limit: int) -> bytes:
                return json.dumps({"name": asset.name, "state": "uploaded", "size": asset.size}).encode()

        class Connection:
            def __init__(self) -> None:
                self.request: tuple[str, str] | None = None
                self.headers: list[tuple[str, str]] = []
                self.sent: list[bytes] = []
                self.closed = False

            def putrequest(self, method: str, target: str) -> None:
                self.request = (method, target)

            def putheader(self, name: str, value: str) -> None:
                self.headers.append((name, value))

            def endheaders(self) -> None:
                pass

            def send(self, body: bytes) -> None:
                self.sent.append(body)

            def getresponse(self) -> Response:
                return Response()

            def close(self) -> None:
                self.closed = True

        connection = Connection()
        upload_url = "https://uploads.github.com/repos/clickety-clacks/gooarchy/releases/17/assets{?name,label}"
        with patch.object(release_api.http.client, "HTTPSConnection", return_value=connection) as factory:
            result = release_api.GitHubReleaseAPI("synthetic-token").upload_asset(upload_url, 17, asset)

        factory.assert_called_once()
        self.assertEqual(
            connection.request,
            ("POST", "/repos/clickety-clacks/gooarchy/releases/17/assets?name=gooarchy.db"),
        )
        self.assertIn(("User-Agent", "Gooarchy-release-client"), connection.headers)
        self.assertIn(("Authorization", "Bearer synthetic-token"), connection.headers)
        self.assertEqual(b"".join(connection.sent), asset_path.read_bytes())
        self.assertEqual(result, {"name": asset.name, "state": "uploaded", "size": asset.size})
        self.assertTrue(connection.closed)

    def test_upload_endpoint_is_pinned_to_github_and_encodes_asset_names(self) -> None:
        valid = "https://uploads.github.com/repos/clickety-clacks/gooarchy/releases/17/assets{?name,label}"
        host, target, port = release_api.GitHubReleaseAPI._upload_target(valid, 17, "package+one.pkg.tar.zst")
        self.assertEqual(host, "uploads.github.com")
        self.assertEqual(target, "/repos/clickety-clacks/gooarchy/releases/17/assets?name=package%2Bone.pkg.tar.zst")
        self.assertIsNone(port)
        with self.assertRaises(release_api.ReleaseError):
            release_api.GitHubReleaseAPI._upload_target(
                "https://uploads.example.invalid/repos/clickety-clacks/gooarchy/releases/17/assets{?name}",
                17,
                "package.pkg.tar.zst",
            )


if __name__ == "__main__":
    unittest.main()
