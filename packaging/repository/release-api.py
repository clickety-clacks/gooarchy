#!/usr/bin/env python3
"""Publish a verified repository transfer through GitHub's Releases REST API."""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

REPOSITORY = "clickety-clacks/gooarchy"
API_ROOT = f"https://api.github.com/repos/{REPOSITORY}"
API_VERSION = "2026-03-10"
TOKEN_LIMIT = 8192
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
FINGERPRINT_RE = re.compile(r"^(?:[0-9A-F]{40}|[0-9A-F]{64})$")
TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
ASSET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+:-]*$")


class ReleaseError(Exception):
    """A safe-to-display release protocol failure."""


class HTTPFailure(ReleaseError):
    def __init__(self, status: int, method: str, path: str):
        super().__init__(f"GitHub Releases API returned HTTP {status} for {method} {path}.")
        self.status = status


@dataclass(frozen=True)
class Asset:
    name: str
    path: Path
    size: int
    sha256: str


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_upload_token(stream) -> str:
    raw = stream.read(TOKEN_LIMIT + 1)
    if len(raw) > TOKEN_LIMIT:
        raise ReleaseError("vault upload token exceeds the accepted input size.")
    try:
        token = raw.decode("ascii").strip()
    except UnicodeDecodeError as error:
        raise ReleaseError("vault upload token is not valid ASCII.") from error
    if not token or any(ord(character) < 33 or ord(character) > 126 for character in token):
        raise ReleaseError("vault upload token is empty or contains whitespace/control characters.")
    return token


def prepare_assets(
    manifest_path: Path,
    signatures_path: Path,
    asset_dir: Path,
    expected_manifest_sha256: str,
    expected_signer_role: str,
) -> tuple[dict[str, Any], list[Asset]]:
    if manifest_path.is_symlink() or signatures_path.is_symlink() or asset_dir.is_symlink():
        raise ReleaseError("manifest, signature receipt, and asset directory must not be symlinks.")
    try:
        manifest_path = manifest_path.resolve(strict=True)
        signatures_path = signatures_path.resolve(strict=True)
        asset_dir = asset_dir.resolve(strict=True)
    except OSError as error:
        raise ReleaseError("manifest, signature receipt, or release asset directory is unavailable.") from error
    if not asset_dir.is_dir() or asset_dir.is_symlink():
        raise ReleaseError("release asset path must be a regular directory.")
    if not manifest_path.is_file():
        raise ReleaseError("transfer manifest must be a regular file.")
    if not signatures_path.is_file():
        raise ReleaseError("signature receipt must be a regular file.")
    if not SHA256_RE.fullmatch(expected_manifest_sha256):
        raise ReleaseError("manifest SHA-256 must be 64 lowercase hexadecimal digits.")
    try:
        if sha256_file(manifest_path) != expected_manifest_sha256:
            raise ReleaseError("transfer manifest SHA-256 does not match the supplied value.")
    except OSError as error:
        raise ReleaseError("transfer manifest could not be hashed.") from error
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReleaseError("transfer manifest is unreadable or invalid JSON.") from error
    if not isinstance(manifest, dict) or manifest.get("schema") != "gooarchy-repository-transfer-v1":
        raise ReleaseError("transfer manifest schema is unsupported.")
    if manifest.get("repository") != REPOSITORY:
        raise ReleaseError("transfer manifest names a different release repository.")
    if not COMMIT_RE.fullmatch(str(manifest.get("source_commit", ""))) or not COMMIT_RE.fullmatch(
        str(manifest.get("source_tree", ""))
    ):
        raise ReleaseError("transfer manifest has an invalid source identity.")
    fingerprint = manifest.get("signing_fingerprint")
    if not isinstance(fingerprint, str) or not FINGERPRINT_RE.fullmatch(fingerprint):
        raise ReleaseError("transfer manifest has an invalid signing fingerprint.")
    packages = manifest.get("packages")
    if not isinstance(packages, list) or not packages:
        raise ReleaseError("transfer manifest has no package records.")
    database = manifest.get("database")
    if (
        not isinstance(database, dict)
        or database.get("filename") != "gooarchy.db"
        or not isinstance(database.get("sha256"), str)
        or not SHA256_RE.fullmatch(database["sha256"])
    ):
        raise ReleaseError("transfer manifest has an invalid repository database record.")
    payload_hashes = {"gooarchy.db": database["sha256"]}
    filenames = ["gooarchy.db"]
    seen: set[str] = set()
    for package in packages:
        if not isinstance(package, dict):
            raise ReleaseError("transfer manifest has an invalid package record.")
        name = package.get("filename")
        if not isinstance(name, str) or not ASSET_RE.fullmatch(name) or ".." in name or name.endswith("."):
            raise ReleaseError("transfer manifest contains an unsafe package filename.")
        package_hash = package.get("sha256")
        if (
            name in seen
            or name == "gooarchy.db"
            or name.endswith(".sig")
            or f"{name}.sig" in seen
            or not isinstance(package_hash, str)
            or not SHA256_RE.fullmatch(package_hash)
        ):
            raise ReleaseError("transfer manifest contains duplicate package filenames.")
        seen.add(name)
        payload_hashes[name] = package_hash
        filenames.append(name)
    try:
        receipt = json.loads(signatures_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReleaseError("signature receipt is unreadable or invalid JSON.") from error
    if (
        not isinstance(receipt, dict)
        or set(receipt) != {"schema", "manifest_sha256", "signer_role", "signing_fingerprint", "signatures"}
        or receipt.get("schema") != "gooarchy-repository-signatures-v1"
        or receipt.get("manifest_sha256") != expected_manifest_sha256
        or receipt.get("signer_role") != expected_signer_role
        or receipt.get("signing_fingerprint") != fingerprint
        or not isinstance(receipt.get("signatures"), list)
    ):
        raise ReleaseError("signature receipt does not match the verified transfer and signer role.")
    signature_hashes: dict[str, str] = {}
    for item in receipt["signatures"]:
        if not isinstance(item, dict) or set(item) != {
            "filename", "payload_sha256", "signature_filename", "signature_sha256"
        }:
            raise ReleaseError("signature receipt has an invalid asset entry.")
        filename = item.get("filename")
        signature_filename = item.get("signature_filename")
        signature_hash = item.get("signature_sha256")
        if (
            not isinstance(filename, str)
            or filename not in payload_hashes
            or item.get("payload_sha256") != payload_hashes.get(filename)
            or signature_filename != f"{filename}.sig"
            or not isinstance(signature_hash, str)
            or not SHA256_RE.fullmatch(signature_hash)
            or filename in signature_hashes
        ):
            raise ReleaseError("signature receipt does not bind the complete package and database set.")
        signature_hashes[filename] = signature_hash
    if set(signature_hashes) != set(payload_hashes):
        raise ReleaseError("signature receipt does not cover every package and database asset.")
    expected_hashes = dict(payload_hashes)
    expected_hashes.update({f"{name}.sig": value for name, value in signature_hashes.items()})
    filenames.extend(f"{name}.sig" for name in filenames.copy())
    expected_names = set(filenames)
    actual_paths = list(asset_dir.iterdir())
    if any(path.is_symlink() or not path.is_file() for path in actual_paths):
        raise ReleaseError("release asset directory contains a non-regular entry.")
    if {path.name for path in actual_paths} != expected_names or len(actual_paths) != len(expected_names):
        raise ReleaseError("release asset directory does not exactly match the signed package and database set.")
    assets = []
    for path in sorted(actual_paths, key=lambda item: item.name):
        actual_hash = sha256_file(path)
        if actual_hash != expected_hashes[path.name]:
            raise ReleaseError(f"local release asset differs from its manifest or signature receipt: {path.name}.")
        assets.append(Asset(path.name, path, path.stat().st_size, actual_hash))
    return manifest, assets


class GitHubReleaseAPI:
    def __init__(self, token: str):
        self._token = token
        self._opener = urllib.request.build_opener(NoRedirect())

    def _request_json(self, method: str, path: str, value: dict[str, Any] | None = None) -> Any:
        body = json.dumps(value, separators=(",", ":")).encode("utf-8") if value is not None else None
        request = urllib.request.Request(
            f"{API_ROOT}{path}",
            data=body,
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self._token}",
                "X-GitHub-Api-Version": API_VERSION,
                "User-Agent": "Gooarchy-release-client",
                **({"Content-Type": "application/json"} if body is not None else {}),
            },
        )
        try:
            with self._opener.open(request, timeout=90) as response:
                data = response.read(8 * 1024 * 1024 + 1)
                if len(data) > 8 * 1024 * 1024:
                    raise ReleaseError("GitHub Releases API response exceeded its size limit.")
                try:
                    return json.loads(data.decode("utf-8"))
                except (UnicodeError, json.JSONDecodeError) as error:
                    raise ReleaseError("GitHub Releases API returned invalid JSON.") from error
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
            raise HTTPFailure(status, method, path) from None
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise ReleaseError(f"GitHub Releases API request failed for {method} {path}.") from error

    def current_latest(self) -> str:
        path = "/releases/latest"
        try:
            release = self._request_json("GET", path)
        except HTTPFailure as error:
            if error.status != 404:
                raise
            repository = self._request_json("GET", "")
            full_name = repository.get("full_name") if isinstance(repository, dict) else None
            if not isinstance(full_name, str) or full_name.lower() != REPOSITORY:
                raise ReleaseError("latest release lookup returned 404 and the repository identity did not verify.")
            return ""
        if (
            not isinstance(release, dict)
            or release.get("draft") is not False
            or release.get("prerelease") is not False
            or not isinstance(release.get("tag_name"), str)
            or not TAG_RE.fullmatch(release["tag_name"])
        ):
            raise ReleaseError("GitHub latest-release response is not a published stable release.")
        return release["tag_name"]

    def tag_exists(self, tag: str) -> bool:
        encoded = urllib.parse.quote(tag, safe="")
        try:
            self._request_json("GET", f"/releases/tags/{encoded}")
            return True
        except HTTPFailure as error:
            if error.status == 404:
                return False
            raise

    def create_draft(self, tag: str, source_commit: str, title: str, body: str) -> dict[str, Any]:
        result = self._request_json(
            "POST",
            "/releases",
            {
                "tag_name": tag,
                "target_commitish": source_commit,
                "name": title,
                "body": body,
                "draft": True,
                "prerelease": False,
                "make_latest": "false",
                "generate_release_notes": False,
            },
        )
        if not isinstance(result, dict):
            raise ReleaseError("GitHub did not return a release record for the draft.")
        return result

    @staticmethod
    def _upload_target(upload_url: str, release_id: int, name: str) -> tuple[str, str, int | None]:
        base = upload_url.partition("{?")[0]
        parsed = urllib.parse.urlsplit(base)
        expected_path = f"/repos/{REPOSITORY}/releases/{release_id}/assets"
        if (
            parsed.scheme != "https"
            or parsed.hostname != "uploads.github.com"
            or parsed.port not in (None, 443)
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path != expected_path
            or parsed.query
            or parsed.fragment
        ):
            raise ReleaseError("GitHub draft supplied an unexpected asset upload endpoint.")
        query = urllib.parse.urlencode({"name": name})
        return parsed.hostname, f"{parsed.path}?{query}", parsed.port

    def upload_asset(self, upload_url: str, release_id: int, asset: Asset) -> dict[str, Any]:
        host, target, port = self._upload_target(upload_url, release_id, asset.name)
        connection = http.client.HTTPSConnection(
            host,
            port=port,
            timeout=180,
            context=ssl.create_default_context(),
        )
        try:
            connection.putrequest("POST", target)
            connection.putheader("Accept", "application/vnd.github+json")
            connection.putheader("User-Agent", "Gooarchy-release-client")
            connection.putheader("Authorization", f"Bearer {self._token}")
            connection.putheader("X-GitHub-Api-Version", API_VERSION)
            connection.putheader("Content-Type", "application/octet-stream")
            connection.putheader("Content-Length", str(asset.size))
            connection.endheaders()
            with asset.path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    connection.send(block)
            response = connection.getresponse()
            data = response.read(2 * 1024 * 1024 + 1)
            if response.status != 201:
                raise HTTPFailure(response.status, "POST", "/release-assets")
            if len(data) > 2 * 1024 * 1024:
                raise ReleaseError("GitHub asset upload response exceeded its size limit.")
            try:
                result = json.loads(data.decode("utf-8"))
            except (UnicodeError, json.JSONDecodeError) as error:
                raise ReleaseError("GitHub asset upload returned invalid JSON.") from error
            if not isinstance(result, dict):
                raise ReleaseError("GitHub asset upload returned an invalid asset record.")
            return result
        except (OSError, http.client.HTTPException, TimeoutError) as error:
            raise ReleaseError(f"GitHub asset upload failed for {asset.name}.") from error
        finally:
            connection.close()

    def release_assets(self, release_id: int) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        page = 1
        while True:
            records = self._request_json(
                "GET", f"/releases/{release_id}/assets?per_page=100&page={page}"
            )
            if not isinstance(records, list) or any(not isinstance(item, dict) for item in records):
                raise ReleaseError("GitHub returned an invalid release asset list.")
            result.extend(records)
            if len(records) < 100:
                return result
            page += 1
            if page > 1000:
                raise ReleaseError("GitHub release asset pagination exceeded its safety limit.")

    @staticmethod
    def _validate_download_url(value: str) -> None:
        parsed = urllib.parse.urlsplit(value)
        host = (parsed.hostname or "").lower()
        accepted = (
            host == "github.com"
            or host == "github-cloud.s3.amazonaws.com"
            or host.endswith(".githubusercontent.com")
        )
        if (
            parsed.scheme != "https"
            or not accepted
            or parsed.username is not None
            or parsed.password is not None
            or not parsed.path
        ):
            raise ReleaseError("GitHub supplied an unexpected release asset download location.")

    def read_asset_digest(self, asset_id: int) -> tuple[str, int]:
        path = f"/releases/assets/{asset_id}"
        request = urllib.request.Request(
            f"{API_ROOT}{path}",
            headers={
                "Accept": "application/octet-stream",
                "Authorization": f"Bearer {self._token}",
                "X-GitHub-Api-Version": API_VERSION,
                "User-Agent": "Gooarchy-release-client",
            },
        )
        redirect: str | None = None
        direct_response = None
        try:
            direct_response = self._opener.open(request, timeout=90)
        except urllib.error.HTTPError as error:
            if error.code != 302:
                status = error.code
                error.close()
                raise HTTPFailure(status, "GET", path) from None
            redirect = error.headers.get("Location")
            error.close()
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise ReleaseError("GitHub release asset readback request failed.") from error

        digest = hashlib.sha256()
        size = 0
        try:
            if direct_response is not None:
                if "json" in direct_response.headers.get("Content-Type", "").lower():
                    raise ReleaseError("GitHub returned asset metadata instead of asset bytes.")
                stream = direct_response
            else:
                if not redirect:
                    raise ReleaseError("GitHub asset readback redirect omitted its location.")
                self._validate_download_url(redirect)
                stream = urllib.request.urlopen(urllib.request.Request(redirect), timeout=180)
            with stream:
                if direct_response is None:
                    self._validate_download_url(stream.geturl())
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
                    size += len(block)
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
            raise HTTPFailure(status, "GET", "/asset-download") from None
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise ReleaseError("GitHub release asset byte readback failed.") from error
        return digest.hexdigest(), size

    def get_release(self, release_id: int) -> dict[str, Any]:
        result = self._request_json("GET", f"/releases/{release_id}")
        if not isinstance(result, dict):
            raise ReleaseError("GitHub returned an invalid release record.")
        return result

    def promote_latest(self, release_id: int) -> dict[str, Any]:
        result = self._request_json(
            "PATCH",
            f"/releases/{release_id}",
            {"draft": False, "make_latest": "true"},
        )
        if not isinstance(result, dict):
            raise ReleaseError("GitHub returned an invalid release promotion record.")
        return result


def publish_release(
    api: GitHubReleaseAPI,
    *,
    manifest_path: Path,
    signatures_path: Path,
    asset_dir: Path,
    manifest_sha256: str,
    release_tag: str,
    source_commit: str,
    source_tree: str,
    signer_role: str,
) -> None:
    if not TAG_RE.fullmatch(release_tag) or ".." in release_tag:
        raise ReleaseError("release tag is invalid.")
    if not COMMIT_RE.fullmatch(source_commit) or not COMMIT_RE.fullmatch(source_tree):
        raise ReleaseError("release source identity is invalid.")
    if signer_role not in {"primary", "backup"}:
        raise ReleaseError("signature receipt has an invalid signer role.")
    manifest, assets = prepare_assets(
        manifest_path, signatures_path, asset_dir, manifest_sha256, signer_role
    )
    if manifest["source_commit"] != source_commit or manifest["source_tree"] != source_tree:
        raise ReleaseError("transfer source identity changed before upload.")
    expected_base = ""
    if manifest.get("base") is not None:
        if not isinstance(manifest["base"], dict) or not isinstance(
            manifest["base"].get("release_tag"), str
        ):
            raise ReleaseError("transfer manifest has an invalid base release.")
        expected_base = manifest["base"]["release_tag"]
    if api.current_latest() != expected_base:
        raise ReleaseError("the published latest release no longer matches the transfer base.")
    if api.tag_exists(release_tag):
        raise ReleaseError("the generated release tag already exists; refusing to overwrite it.")
    title = f"Gooarchy package repository {release_tag}"
    notes = (
        f"Complete repository snapshot built from Gooarchy {source_commit} (tree {source_tree}).\n"
        f"Build manifest SHA-256: {manifest_sha256}. Signer role: {signer_role}."
    )
    draft = api.create_draft(release_tag, source_commit, title, notes)
    release_id = draft.get("id")
    upload_url = draft.get("upload_url")
    if (
        not isinstance(release_id, int)
        or release_id < 1
        or draft.get("tag_name") != release_tag
        or draft.get("draft") is not True
        or draft.get("prerelease") is not False
        or not isinstance(upload_url, str)
    ):
        raise ReleaseError("GitHub did not create the expected unpublished release draft.")

    for asset in assets:
        result = api.upload_asset(upload_url, release_id, asset)
        if (
            result.get("name") != asset.name
            or result.get("state") != "uploaded"
            or result.get("size") != asset.size
        ):
            raise ReleaseError(f"GitHub did not confirm complete upload of {asset.name}.")

    listed = api.release_assets(release_id)
    if len(listed) != len(assets):
        raise ReleaseError("draft release asset count does not match the complete repository set.")
    listed_by_name: dict[str, dict[str, Any]] = {}
    for record in listed:
        name = record.get("name")
        if not isinstance(name, str) or name in listed_by_name:
            raise ReleaseError("draft release contains an invalid or duplicate asset name.")
        listed_by_name[name] = record
    if set(listed_by_name) != {asset.name for asset in assets}:
        raise ReleaseError("draft release does not contain the exact package, signature, and database set.")
    for asset in assets:
        record = listed_by_name[asset.name]
        asset_id = record.get("id")
        if (
            not isinstance(asset_id, int)
            or record.get("state") != "uploaded"
            or record.get("size") != asset.size
        ):
            raise ReleaseError(f"draft release metadata is incomplete for {asset.name}.")
        remote_digest = record.get("digest")
        if remote_digest is not None and remote_digest != f"sha256:{asset.sha256}":
            raise ReleaseError(f"GitHub's asset digest differs for {asset.name}.")
        actual_digest, actual_size = api.read_asset_digest(asset_id)
        if actual_size != asset.size or actual_digest != asset.sha256:
            raise ReleaseError(f"draft release byte readback differs for {asset.name}.")

    current_draft = api.get_release(release_id)
    if (
        current_draft.get("tag_name") != release_tag
        or current_draft.get("draft") is not True
        or current_draft.get("prerelease") is not False
    ):
        raise ReleaseError("draft release identity or unpublished state changed before promotion.")
    if api.current_latest() != expected_base:
        raise ReleaseError("published latest changed during upload; leaving this draft unpublished.")

    promotion_error: ReleaseError | None = None
    try:
        api.promote_latest(release_id)
    except ReleaseError as error:
        promotion_error = error
    if promotion_error is not None and api.current_latest() != release_tag:
        raise ReleaseError("release promotion was not confirmed; the latest release was not advanced.") from None
    published = api.get_release(release_id)
    if (
        published.get("tag_name") != release_tag
        or published.get("draft") is not False
        or published.get("prerelease") is not False
    ):
        raise ReleaseError("promoted release did not read back as the expected published release.")
    if api.current_latest() != release_tag:
        raise ReleaseError("verified release was published but did not become the repository latest.")
    print(f"Published complete repository release {release_tag} as latest from Gooarchy {source_commit}.")
    print(f"Transfer manifest SHA-256: {manifest_sha256}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    publish_parser = subparsers.add_parser("publish")
    publish_parser.add_argument("--manifest", type=Path, required=True)
    publish_parser.add_argument("--signatures", type=Path, required=True)
    publish_parser.add_argument("--assets-dir", type=Path, required=True)
    publish_parser.add_argument("--manifest-sha256", required=True)
    publish_parser.add_argument("--release-tag", required=True)
    publish_parser.add_argument("--source-commit", required=True)
    publish_parser.add_argument("--source-tree", required=True)
    publish_parser.add_argument("--signer-role", choices=("primary", "backup"), required=True)
    arguments = parser.parse_args(argv)
    if sys.stdin.isatty():
        print("release upload refused: provide the approved vault token on standard input.", file=sys.stderr)
        return 2
    try:
        token = read_upload_token(sys.stdin.buffer)
        publish_release(
            GitHubReleaseAPI(token),
            manifest_path=arguments.manifest,
            signatures_path=arguments.signatures,
            asset_dir=arguments.assets_dir,
            manifest_sha256=arguments.manifest_sha256,
            release_tag=arguments.release_tag,
            source_commit=arguments.source_commit,
            source_tree=arguments.source_tree,
            signer_role=arguments.signer_role,
        )
    except ReleaseError as error:
        print(f"release upload refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
