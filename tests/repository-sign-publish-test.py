#!/usr/bin/env python3
"""Exercise signer draft/readback/latest behavior with local fake release services."""
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


def run(command: list[str], *, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=check, capture_output=True, text=True, env=env)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def create_package(path: Path, name: str) -> None:
    pkgver, pkgrel = VERSION.rsplit("-", 1)
    body = (
        f"pkgname = {name}\n"
        f"pkgver = {pkgver}\n"
        f"pkgrel = {pkgrel}\n"
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


class SignerPublishTests(unittest.TestCase):
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
        self.base_env = os.environ.copy()
        self.base_env.update({
            "GOOARCHY_TEST_RELEASE_STATE": str(self.state),
            "GOOARCHY_TEST_RELEASES": str(self.releases),
            "GOOARCHY_TEST_DRAFTS": str(self.drafts),
            "GOOARCHY_TEST_SECRET_KEY": str(self.secret_key),
            "GOOARCHY_SIGNING_KEY_REF": "op://test/vault/key/private-key",
            "PATH": f"{self.bin}:{os.environ['PATH']}",
        })
        self.install_test_commands()
        self.create_key()
        self.create_checkout_and_transfer()

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
[[ ${1:-} == read && ${2:-} == op://test/vault/key/private-key && $# == 2 ]] || exit 2
cat "$GOOARCHY_TEST_SECRET_KEY"
""")
        op.chmod(0o755)
        gh = self.bin / "gh"
        gh.write_text("""#!/usr/bin/env python3
import json, os, shutil, sys
args = sys.argv[1:]
state_path = os.environ['GOOARCHY_TEST_RELEASE_STATE']
releases = os.environ['GOOARCHY_TEST_RELEASES']
drafts = os.environ['GOOARCHY_TEST_DRAFTS']
try:
    state = json.load(open(state_path, encoding='utf-8'))
except FileNotFoundError:
    state = {'latest': ''}
if args[:2] == ['release', 'list']:
    print(json.dumps([{'tagName': state['latest'], 'isLatest': True}] if state['latest'] else []))
elif args[:2] == ['release', 'create']:
    tag = args[2]
    rest = args[3:]
    assets = []
    for value in rest:
        if value.startswith('--'): break
        assets.append(value)
    target = os.path.join(drafts, tag)
    os.mkdir(target)
    chosen = assets[:1] if os.environ.get('GOOARCHY_TEST_FAIL_UPLOAD') == '1' else assets
    for source in chosen:
        shutil.copyfile(source, os.path.join(target, os.path.basename(source)))
    if os.environ.get('GOOARCHY_TEST_FAIL_UPLOAD') == '1': raise SystemExit(1)
elif args[:2] == ['release', 'download']:
    tag = args[2]
    destination = args[args.index('--dir') + 1]
    source = os.path.join(releases, tag)
    if not os.path.isdir(source): source = os.path.join(drafts, tag)
    if not os.path.isdir(source): raise SystemExit(1)
    names = sorted(os.listdir(source))
    if os.environ.get('GOOARCHY_TEST_OMIT_ASSET') == '1' and names: names = names[1:]
    for name in names: shutil.copyfile(os.path.join(source, name), os.path.join(destination, name))
elif args[:2] == ['release', 'edit']:
    tag = args[2]
    source = os.path.join(drafts, tag)
    target = os.path.join(releases, tag)
    shutil.move(source, target)
    state['latest'] = tag
    with open(state_path, 'w', encoding='utf-8') as stream: json.dump(state, stream)
else:
    raise SystemExit(2)
""")
        gh.chmod(0o755)

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
        (self.checkout / "packaging/keys").mkdir(parents=True)
        (self.checkout / "packaging/keys/gooarchy.asc").write_text(public_key)
        (self.checkout / "packaging/keys/gooarchy.fingerprint").write_text(self.fingerprint + "\n")
        self.secret_key.write_text(secret_key)
        self.secret_key.chmod(0o600)

    def create_checkout_and_transfer(self) -> None:
        (self.checkout / "packaging/repository").mkdir(parents=True)
        source_files = [
            ROOT / "packaging/repository/sign-publish.sh",
            ROOT / "packaging/repository/repository-protocol.py",
            ROOT / "packaging/repository/read-db.py",
        ]
        for source in source_files:
            shutil.copy2(source, self.checkout / "packaging/repository" / source.name)
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
                "rebuilt": True,
            })
        database = payload / "gooarchy.db"
        create_database(database, records)
        manifest = {
            "schema": "gooarchy-repository-transfer-v1",
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
        lines = [f"{digest(payload / name)}  payload/{name}" for name in sorted(["gooarchy.db", *(entry["filename"] for entry in packages)])]
        (self.bundle / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="ascii")
        self.manifest_hash = digest(manifest_path)

    def publish(self, *, fail_upload: bool = False, omit_asset: bool = False) -> subprocess.CompletedProcess[str]:
        env = self.base_env.copy()
        if fail_upload:
            env["GOOARCHY_TEST_FAIL_UPLOAD"] = "1"
        if omit_asset:
            env["GOOARCHY_TEST_OMIT_ASSET"] = "1"
        return run([
            str(self.checkout / "packaging/repository/sign-publish.sh"),
            "--bundle", str(self.bundle),
            "--manifest-sha256", self.manifest_hash,
        ], env=env, check=False)

    def latest(self) -> str:
        if not self.state.exists():
            return ""
        return json.loads(self.state.read_text())["latest"]

    def test_incomplete_upload_and_failed_readback_never_advance_latest(self) -> None:
        failed_upload = self.publish(fail_upload=True)
        self.assertNotEqual(failed_upload.returncode, 0)
        self.assertEqual(self.latest(), "")

        failed_readback = self.publish(omit_asset=True)
        self.assertNotEqual(failed_readback.returncode, 0)
        self.assertEqual(self.latest(), "")
        self.assertEqual(len(list(self.drafts.iterdir())), 2)
        self.assertEqual(list(self.releases.iterdir()), [])

    def test_complete_verified_release_advances_latest_with_all_detached_signatures(self) -> None:
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        tag = self.latest()
        self.assertTrue(tag.startswith(f"gooarchy-repo-{self.commit[:12]}-"))
        release = self.releases / tag
        expected_names = {"gooarchy.db", "gooarchy.db.sig"}
        for path in (self.bundle / "payload").iterdir():
            if path.name != "gooarchy.db":
                expected_names.update({path.name, f"{path.name}.sig"})
        self.assertEqual({path.name for path in release.iterdir()}, expected_names)
        verify_home = self.root / "verify-home"
        verify_home.mkdir(mode=0o700)
        run(["gpg", "--homedir", str(verify_home), "--batch", "--import", str(self.checkout / "packaging/keys/gooarchy.asc")])
        for name in sorted(expected_names):
            if name.endswith(".sig"):
                continue
            run(["gpg", "--homedir", str(verify_home), "--batch", "--verify", str(release / f"{name}.sig"), str(release / name)])


if __name__ == "__main__":
    unittest.main(verbosity=2)
