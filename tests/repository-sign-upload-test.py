#!/usr/bin/env python3
"""Exercise explicit signer roles and the separately invoked upload boundary."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = sorted({
    "gooarchy",
    "gooarchy-flavorings",
    "scottland",
    "xdg-desktop-portal-wlr-gooarchy",
    "linux-gooarchy",
    "linux-gooarchy-headers",
})
VERSION = "1.0.0-1"
PRIMARY_REF = "op://test/vault/primary/private-key"
BACKUP_REF = "op://test/vault/backup/private-key"


def run(command: list[str], *, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=check, capture_output=True, text=True, env=env)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def create_package(path: Path, name: str) -> None:
    body = (
        f"pkgname = {name}\n"
        f"pkgver = {VERSION}\n"
        "arch = any\n"
        "packager = Gooarchy\n"
    ).encode()
    import io
    with tarfile.open(path, "w") as archive:
        item = tarfile.TarInfo(".PKGINFO")
        item.size = len(body)
        archive.addfile(item, io.BytesIO(body))


def create_database(path: Path, records: list[tuple[str, str, str]]) -> None:
    import io
    with tarfile.open(path, "w:gz") as archive:
        for name, version, filename in records:
            body = f"%NAME%\n{name}\n\n%VERSION%\n{version}\n\n%FILENAME%\n{filename}\n".encode()
            item = tarfile.TarInfo(f"{name}-{version}/desc")
            item.size = len(body)
            archive.addfile(item, io.BytesIO(body))


class SignAndUploadTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="gooarchy-signer-test-")
        self.root = Path(self.temp.name)
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()
        self.bundle = self.root / "transfer"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.state = self.root / "release-state.json"
        self.releases = self.root / "releases"
        self.drafts = self.root / "drafts"
        self.releases.mkdir()
        self.drafts.mkdir()
        self.key_home = self.root / "key-home"
        self.key_home.mkdir(mode=0o700)
        self.secret_key = self.root / "test-secret.asc"
        self.release_notes = self.root / "release-notes.md"
        self.release_notes.write_text(
            "Synthetic package repository release notes.\n", encoding="utf-8"
        )
        self.base_env = os.environ.copy()
        self.base_env.update({
            "GOOARCHY_TEST_RELEASE_STATE": str(self.state),
            "GOOARCHY_TEST_RELEASES": str(self.releases),
            "GOOARCHY_TEST_DRAFTS": str(self.drafts),
            "GOOARCHY_TEST_SECRET_KEY": str(self.secret_key),
            "GOOARCHY_TEST_UPLOAD_TOKEN_REF": "op://test/vault/release/credential",
            "GOOARCHY_RELEASE_UPLOAD_TOKEN_REF": "op://test/vault/release/credential",
            "PATH": f"{self.bin}:{os.environ['PATH']}",
        })
        self.install_test_commands()
        self.create_key()
        self.create_checkout_and_transfer()
        self.signed_primary = self.root / "signed-primary"
        signed = self.sign("primary", self.signed_primary)
        self.assertEqual(signed.returncode, 0, signed.stdout + signed.stderr)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def install_test_commands(self) -> None:
        bsdtar = self.bin / "bsdtar"
        bsdtar.write_text("""#!/usr/bin/env python3
import sys, tarfile
if len(sys.argv) != 4 or sys.argv[1] != '-xOf': raise SystemExit(2)
with tarfile.open(sys.argv[2], 'r:*') as archive:
    stream = archive.extractfile(sys.argv[3])
    if stream is None: raise SystemExit(1)
    sys.stdout.buffer.write(stream.read())
""")
        bsdtar.chmod(0o755)
        op = self.bin / "op"
        op.write_text("""#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == read && $# == 2 ]] || exit 2
if [[ ${2:-} == ${GOOARCHY_TEST_EXPECT_KEY_REF:-} ]]; then
  cat "$GOOARCHY_TEST_SECRET_KEY"
elif [[ ${2:-} == ${GOOARCHY_TEST_UPLOAD_TOKEN_REF:-} ]]; then
  printf 'synthetic-release-token\\n'
else
  exit 2
fi
""")
        op.chmod(0o755)
        curl = self.bin / "curl"
        curl.write_text("""#!/usr/bin/env python3
import pathlib, sys
args = sys.argv[1:]
try:
    output = pathlib.Path(args[args.index('--output') + 1])
    output.write_bytes(b'')
except (ValueError, IndexError):
    raise SystemExit(2)
if not args or not args[-1].endswith('/releases/latest'):
    raise SystemExit(2)
sys.stdout.write('404')
""")
        curl.chmod(0o755)

    def create_key(self) -> None:
        run([
            "gpg", "--homedir", str(self.key_home), "--batch", "--pinentry-mode", "loopback",
            "--passphrase", "", "--quick-generate-key", "Gooarchy transfer test", "ed25519", "sign", "0",
        ])
        listing = run([
            "gpg", "--homedir", str(self.key_home), "--batch", "--with-colons",
            "--list-secret-keys", "--with-fingerprint",
        ]).stdout
        self.fingerprint = next(line.split(":")[9].upper() for line in listing.splitlines() if line.startswith("fpr:"))
        public_key = run([
            "gpg", "--homedir", str(self.key_home), "--batch", "--armor", "--export", self.fingerprint,
        ]).stdout
        secret_key = run([
            "gpg", "--homedir", str(self.key_home), "--batch", "--armor", "--export-secret-keys", self.fingerprint,
        ]).stdout
        keys = self.checkout / "packaging/keys"
        keys.mkdir(parents=True)
        (keys / "gooarchy.asc").write_text(public_key)
        (keys / "gooarchy.fingerprint").write_text(self.fingerprint + "\n")
        self.secret_key.write_text(secret_key)
        self.secret_key.chmod(0o600)

    def create_checkout_and_transfer(self) -> None:
        repository = self.checkout / "packaging/repository"
        repository.mkdir(parents=True)
        for name in ("sign.sh", "upload.sh", "repository-protocol.py", "read-db.py"):
            shutil.copy2(ROOT / "packaging/repository" / name, repository / name)
        (repository / "release-api.py").write_text("""#!/usr/bin/env python3
import argparse, hashlib, json, os, shutil, sys
parser = argparse.ArgumentParser()
sub = parser.add_subparsers(dest='command', required=True)
publish = sub.add_parser('publish')
for name in ('manifest', 'signatures', 'assets-dir', 'manifest-sha256', 'release-tag', 'source-commit', 'source-tree', 'signer-role', 'release-notes'):
    publish.add_argument('--' + name, required=True)
args = parser.parse_args()
token = sys.stdin.buffer.read().decode('ascii').strip()
if token != 'synthetic-release-token': raise SystemExit('mock vault token mismatch')
with open(args.release_notes, encoding='utf-8') as stream:
    if not stream.read().strip(): raise SystemExit('release notes are empty')
manifest_path = args.manifest
with open(manifest_path, encoding='utf-8') as stream: manifest = json.load(stream)
digest = hashlib.sha256(open(manifest_path, 'rb').read()).hexdigest()
if digest != args.manifest_sha256: raise SystemExit('manifest hash mismatch')
if manifest['source_commit'] != args.source_commit or manifest['source_tree'] != args.source_tree:
    raise SystemExit('source mismatch')
state_path = os.environ['GOOARCHY_TEST_RELEASE_STATE']
drafts = os.environ['GOOARCHY_TEST_DRAFTS']
releases = os.environ['GOOARCHY_TEST_RELEASES']
try:
    with open(state_path, encoding='utf-8') as stream: state = json.load(stream)
except FileNotFoundError:
    state = {'latest': ''}
base = (manifest.get('base') or {}).get('release_tag', '')
if state['latest'] != base: raise SystemExit('base/latest mismatch')
expected = {'gooarchy.db', 'gooarchy.db.sig'}
for package in manifest['packages']:
    expected.add(package['filename'])
    expected.add(package['filename'] + '.sig')
source_dir = args.assets_dir
if set(os.listdir(source_dir)) != expected: raise SystemExit('asset set mismatch')
target = os.path.join(drafts, args.release_tag)
if os.path.exists(target): raise SystemExit('draft tag already exists')
os.mkdir(target)
names = sorted(expected)
if os.environ.get('GOOARCHY_TEST_FAIL_UPLOAD') == '1': names = names[:1]
if os.environ.get('GOOARCHY_TEST_OMIT_ASSET') == '1': names = names[:-1]
for name in names: shutil.copyfile(os.path.join(source_dir, name), os.path.join(target, name))
if set(os.listdir(target)) != expected: raise SystemExit('draft did not contain the complete release')
published = os.path.join(releases, args.release_tag)
shutil.move(target, published)
state['latest'] = args.release_tag
with open(state_path, 'w', encoding='utf-8') as stream: json.dump(state, stream)
""")
        (repository / "release-api.py").chmod(0o755)
        run(["git", "init", "-q", "-b", "main", str(self.checkout)])
        run(["git", "-C", str(self.checkout), "config", "user.name", "Transfer Test"])
        run(["git", "-C", str(self.checkout), "config", "user.email", "transfer-test@example.invalid"])
        run(["git", "-C", str(self.checkout), "add", "."])
        run(["git", "-C", str(self.checkout), "commit", "-qm", "signer fixture source"])
        self.commit = run(["git", "-C", str(self.checkout), "rev-parse", "HEAD"]).stdout.strip()
        self.tree = run(["git", "-C", str(self.checkout), "rev-parse", "HEAD^{tree}"]).stdout.strip()
        self.bundle.mkdir()
        payload = self.bundle / "payload"
        payload.mkdir()
        records = []
        packages = []
        for name in REQUIRED:
            filename = f"{name}-{VERSION}-any.pkg.tar.zst"
            path = payload / filename
            create_package(path, name)
            records.append((name, VERSION, filename))
            packages.append({
                "name": name,
                "version": VERSION,
                "filename": filename,
                "sha256": digest(path),
                "architecture": "any",
                "source_revision": f"Gooarchy {self.commit}",
                "origin_kind": "source-build",
            })
        database = payload / "gooarchy.db"
        create_database(database, records)
        manifest = {
            "schema": "gooarchy-repository-transfer-v2",
            "repository": "clickety-clacks/gooarchy",
            "source_commit": self.commit,
            "source_tree": self.tree,
            "signing_fingerprint": self.fingerprint,
            "base": None,
            "packages": packages,
            "database": {"filename": "gooarchy.db", "sha256": digest(database)},
        }
        manifest_path = self.bundle / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n")
        checksum_files = ["gooarchy.db", *(entry["filename"] for entry in packages)]
        (self.bundle / "SHA256SUMS").write_text(
            "\n".join(f"{digest(payload / name)}  payload/{name}" for name in sorted(checksum_files)) + "\n",
            encoding="ascii",
        )
        self.manifest_hash = digest(manifest_path)

    def sign(self, role: str, output: Path, *, reference: str | None = None) -> subprocess.CompletedProcess[str]:
        env = self.base_env.copy()
        selected_reference = reference or (PRIMARY_REF if role == "primary" else BACKUP_REF)
        env["GOOARCHY_TEST_EXPECT_KEY_REF"] = selected_reference
        env["GOOARCHY_SIGNING_KEY_REF"] = PRIMARY_REF
        env["GOOARCHY_BACKUP_SIGNING_KEY_REF"] = BACKUP_REF
        return run([
            str(self.checkout / "packaging/repository/sign.sh"),
            "--signer-role", role,
            "--bundle", str(self.bundle),
            "--output", str(output),
            "--manifest-sha256", self.manifest_hash,
        ], env=env, check=False)

    def upload(self, signed: Path, *, fail_upload: bool = False, omit_asset: bool = False) -> subprocess.CompletedProcess[str]:
        env = self.base_env.copy()
        if fail_upload:
            env["GOOARCHY_TEST_FAIL_UPLOAD"] = "1"
        if omit_asset:
            env["GOOARCHY_TEST_OMIT_ASSET"] = "1"
        env["GOOARCHY_RELEASE_UPLOAD_TOKEN_REF"] = "op://test/vault/release/credential"
        return run([
            str(self.checkout / "packaging/repository/upload.sh"),
            "--uploader-role", "primary",
            "--signed-bundle", str(signed),
            "--release-notes", str(self.release_notes),
            "--manifest-sha256", self.manifest_hash,
        ], env=env, check=False)

    def latest(self) -> str:
        if not self.state.exists():
            return ""
        return json.loads(self.state.read_text())["latest"]

    def test_backup_signs_all_assets_but_upload_is_separate(self) -> None:
        signed_backup = self.root / "signed-backup"
        result = self.sign("backup", signed_backup)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads((signed_backup / "SIGNATURES.json").read_text())
        self.assertEqual(receipt["signer_role"], "backup")
        self.assertEqual(receipt["signing_fingerprint"], self.fingerprint)
        self.assertEqual(len(receipt["signatures"]), len(REQUIRED) + 1)
        self.assertEqual(len(list((signed_backup / "signatures").iterdir())), len(REQUIRED) + 1)
        self.assertFalse(self.state.exists())
        self.assertEqual(list(self.drafts.iterdir()), [])

        # A distinct uploader invocation consumes the exact signed output.
        uploaded = self.upload(signed_backup)
        self.assertEqual(uploaded.returncode, 0, uploaded.stderr)
        self.assertTrue(self.latest())

    def test_primary_signs_all_assets_without_upload_then_uploads_complete_set(self) -> None:
        receipt = json.loads((self.signed_primary / "SIGNATURES.json").read_text())
        self.assertEqual(receipt["signer_role"], "primary")
        self.assertEqual(len(receipt["signatures"]), len(REQUIRED) + 1)
        self.assertFalse(self.state.exists())
        self.assertEqual(list(self.drafts.iterdir()), [])

        uploaded = self.upload(self.signed_primary)
        self.assertEqual(uploaded.returncode, 0, uploaded.stderr)
        latest = self.latest()
        self.assertTrue(latest)
        assets = set(os.listdir(self.releases / latest))
        expected = {"gooarchy.db", "gooarchy.db.sig"}
        for package in REQUIRED:
            filename = f"{package}-{VERSION}-any.pkg.tar.zst"
            expected.update({filename, f"{filename}.sig"})
        self.assertEqual(assets, expected)

    def test_upload_failures_never_advance_latest(self) -> None:
        failed_upload = self.upload(self.signed_primary, fail_upload=True)
        self.assertNotEqual(failed_upload.returncode, 0)
        self.assertEqual(self.latest(), "")

        failed_readback = self.upload(self.signed_primary, omit_asset=True)
        self.assertNotEqual(failed_readback.returncode, 0)
        self.assertEqual(self.latest(), "")
        self.assertEqual(len(list(self.drafts.iterdir())), 2)
        self.assertEqual(list(self.releases.iterdir()), [])

    def test_signer_rejects_wrong_manifest_digest_and_wrong_fingerprint(self) -> None:
        wrong_hash = run([
            str(self.checkout / "packaging/repository/sign.sh"),
            "--signer-role", "backup",
            "--bundle", str(self.bundle),
            "--output", str(self.root / "wrong-hash"),
            "--manifest-sha256", "0" * 64,
        ], env=self.base_env.copy(), check=False)
        self.assertNotEqual(wrong_hash.returncode, 0)

        env = self.base_env.copy()
        env["GOOARCHY_TEST_EXPECT_KEY_REF"] = BACKUP_REF
        env["GOOARCHY_BACKUP_SIGNING_KEY_REF"] = BACKUP_REF
        env["GOOARCHY_SIGNING_KEY_REF"] = PRIMARY_REF
        old_manifest_hash = self.manifest_hash
        manifest_path = self.bundle / "manifest.json"
        original = manifest_path.read_bytes()
        try:
            manifest = json.loads(original)
            manifest["signing_fingerprint"] = "A" * 40
            manifest_path.write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n")
            self.manifest_hash = digest(manifest_path)
            mismatch = self.sign("backup", self.root / "wrong-fingerprint", reference=BACKUP_REF)
        finally:
            manifest_path.write_bytes(original)
            self.manifest_hash = old_manifest_hash
        self.assertNotEqual(mismatch.returncode, 0)

    def test_uploader_rejects_tampered_payload_before_creating_a_draft(self) -> None:
        package = next((self.signed_primary / "payload").glob("*.pkg.tar.zst"))
        package.write_bytes(package.read_bytes() + b"tamper")
        result = self.upload(self.signed_primary)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.drafts.iterdir()), [])
        self.assertFalse(self.state.exists())


if __name__ == "__main__":
    unittest.main()
