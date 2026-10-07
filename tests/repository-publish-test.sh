#!/usr/bin/env bash
# Exercise the publisher against a local GitHub Releases-shaped stand-in and a throwaway key.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_root=$(git -C "$script_dir" rev-parse --show-toplevel)
test_parent=${TMPDIR:-/tmp}
test_root=$(mktemp -d "$test_parent/gooarchy-repository-test.XXXXXX")
server_pid=
cleanup() {
  [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true
  rm -rf -- "$test_root"
}
trap cleanup EXIT

for command_name in bsdtar curl gpg git jq pacman python3 repo-add sha256sum vercmp zstd; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "repository-publish-test: required command is missing: $command_name" >&2
    exit 1
  }
done
real_pacman=$(command -v pacman)

fixture="$test_root/checkout"
release_root="$test_root/releases"
test_bin="$test_root/bin"
mkdir -m 700 -p "$fixture/packaging/repository" "$fixture/packaging/keys" \
  "$fixture/packaging/arch/xdg-desktop-portal-wlr" "$fixture/packaging/gooarchy-flavorings" \
  "$fixture/packaging/linux-gooarchy" "$fixture/install" "$release_root" "$test_bin"
cp -- "$source_root/packaging/repository/publish.sh" "$fixture/packaging/repository/"
cp -- "$source_root/packaging/repository/read-db.py" "$fixture/packaging/repository/"

scottland_source="$test_root/scottland-source"
mkdir -m 700 -p "$scottland_source/packaging/arch"
cat >"$scottland_source/packaging/arch/PKGBUILD" <<'PKG'
pkgname=scottland
pkgver=1.0
pkgrel=1
arch=('x86_64')
  depends=('wayfire' 'test-runtime')
PKG
git -C "$scottland_source" init -q -b main
GIT_AUTHOR_NAME='Test' GIT_AUTHOR_EMAIL='test@example.invalid' \
  GIT_COMMITTER_NAME='Test' GIT_COMMITTER_EMAIL='test@example.invalid' \
  git -C "$scottland_source" add .
GIT_AUTHOR_NAME='Test' GIT_AUTHOR_EMAIL='test@example.invalid' \
  GIT_COMMITTER_NAME='Test' GIT_COMMITTER_EMAIL='test@example.invalid' \
  git -C "$scottland_source" commit -qm 'pinned Scottland fixture'
scottland_ref=$(git -C "$scottland_source" rev-parse HEAD)
cat >"$fixture/install/sources.conf" <<SOURCES
GOOARCHY_SCOTTLAND_REPO=file://$scottland_source
GOOARCHY_SCOTTLAND_REF=$scottland_ref
SOURCES

cat >"$fixture/packaging/arch/PKGBUILD" <<'PKG'
pkgname=gooarchy
pkgver=1.0
pkgrel=1
arch=('any')
PKG
cat >"$fixture/packaging/gooarchy-flavorings/PKGBUILD" <<'PKG'
pkgname=gooarchy-flavorings
_commit=0123456789abcdef0123456789abcdef01234567
pkgver=1.0
pkgrel=1
arch=('any')
PKG
cat >"$fixture/packaging/arch/xdg-desktop-portal-wlr/PKGBUILD" <<'PKG'
pkgname=xdg-desktop-portal-wlr-gooarchy
pkgver=1.0
pkgrel=1
arch=('x86_64')
_tag=v0.8.4-gooarchy.1
PKG
cat >"$fixture/packaging/linux-gooarchy/PKGBUILD" <<'PKG'
pkgbase=linux-gooarchy
pkgname=(linux-gooarchy linux-gooarchy-headers)
pkgver=1.0
pkgrel=1
arch=('x86_64')
_omarchy_commit=0123456789abcdef0123456789abcdef01234567
PKG

key_home="$test_root/key-home"
mkdir -m 700 "$key_home"
gpg --homedir "$key_home" --batch --pinentry-mode loopback --passphrase '' --quick-generate-key \
  'Gooarchy repository test key' ed25519 sign 0 >/dev/null 2>&1
fingerprint=$(gpg --homedir "$key_home" --batch --with-colons --list-secret-keys \
  --with-fingerprint | awk -F: '$1 == "fpr" { print toupper($10); exit }')
gpg --homedir "$key_home" --batch --armor --export "$fingerprint" \
  >"$fixture/packaging/keys/gooarchy.asc"
printf '%s\n' "$fingerprint" >"$fixture/packaging/keys/gooarchy.fingerprint"
gpg --homedir "$key_home" --batch --armor --export-secret-keys "$fingerprint" \
  >"$test_root/test-private-key.asc"
chmod 600 "$test_root/test-private-key.asc"

cat >"$test_bin/op" <<'OP'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == read && $# == 2 ]] || exit 2
cat "$GOOARCHY_TEST_SECRET_KEY"
OP
chmod 755 "$test_bin/op"

cat >"$test_bin/makepkg" <<'MAKEPKG'
#!/usr/bin/env python3
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

text = Path("PKGBUILD").read_text()
match = re.search(r"^\s*pkgname\s*=\s*(?:\(([^)]*)\)|([^\n#]+))", text, re.M)
if not match:
    raise SystemExit("fixture PKGBUILD has no pkgname")
raw_names = match.group(1) if match.group(1) is not None else match.group(2)
names = shlex.split(raw_names.strip().strip("()"))
version = re.search(r"^\s*pkgver\s*=\s*['\"]?([^'\"\s]+)", text, re.M).group(1)
release = re.search(r"^\s*pkgrel\s*=\s*['\"]?([^'\"\s]+)", text, re.M).group(1)
architecture = re.search(r"^\s*arch\s*=\s*\(([^)]*)\)", text, re.M).group(1)
architecture = shlex.split(architecture)[0]
depends_match = re.search(r"^\s*depends\s*=\s*\(([^)]*)\)", text, re.M)
depends = shlex.split(depends_match.group(1)) if depends_match else []

if "--printsrcinfo" in sys.argv:
    for name in names:
        print(f"pkgname = {name}")
    raise SystemExit(0)

config = Path(os.environ["MAKEPKG_CONF"]).read_text()
package_dest = shlex.split(re.search(r"^PKGDEST=(.+)$", config, re.M).group(1))[0]
Path(package_dest).mkdir(parents=True, exist_ok=True)
for name in names:
    override_name = "GOOARCHY_TEST_VERSION_" + re.sub(r"[^A-Za-z0-9]", "_", name).upper()
    package_version = os.environ.get(override_name, version)
    filename = f"{name}-{package_version}-{release}-{architecture}.pkg.tar.zst"
    with tempfile.TemporaryDirectory() as temporary:
        package_info = Path(temporary) / ".PKGINFO"
        package_info.write_text(
            f"pkgname = {name}\npkgbase = {name}\npkgver = {package_version}-{release}\n"
            f"pkgdesc = repository test fixture\nurl = https://example.invalid/\n"
            f"builddate = 0\npackager = Gooarchy\nsize = 0\narch = {architecture}\n"
            + "".join(f"depend = {dependency}\n" for dependency in depends)
        )
        destination = Path(package_dest) / filename
        with destination.open("wb") as output:
            archive = subprocess.Popen(
                ["bsdtar", "-C", temporary, "-cf", "-", ".PKGINFO"],
                stdout=subprocess.PIPE,
                check=False,
            )
            compressor = subprocess.run(
                ["zstd", "-q", "-c"], stdin=archive.stdout, stdout=output, check=False
            )
            archive.stdout.close()
            if compressor.returncode != 0 or archive.wait() != 0:
                raise SystemExit("could not create synthetic Arch package")
MAKEPKG
chmod 755 "$test_bin/makepkg"

cat >"$test_bin/pacman" <<'PACMAN'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -Si && ${2:-} == extra/wayfire ]]; then
  cat <<'INFO'
Repository      : extra
Name            : wayfire
Version         : 0.11.0-1
INFO
  exit 0
fi
exec "$GOOARCHY_TEST_REAL_PACMAN" "$@"
PACMAN
chmod 755 "$test_bin/pacman"

cat >"$test_bin/gh" <<'GH'
#!/usr/bin/env python3
import json
import os
import shutil
import sys
from pathlib import Path

root = Path(os.environ["GOOARCHY_TEST_RELEASE_ROOT"])
releases = root / "releases"
releases.mkdir(parents=True, exist_ok=True)
args = sys.argv[1:]
if len(args) < 2 or args[0] != "release":
    raise SystemExit("unsupported fake gh command")
command = args[1]
latest_file = root / "LATEST"
if command == "list":
    latest = latest_file.read_text().strip() if latest_file.exists() else ""
    rows = []
    for release_dir in sorted(releases.iterdir()):
        info_file = release_dir / "release.json"
        if info_file.exists():
            info = json.loads(info_file.read_text())
            if not info["draft"]:
                rows.append({"tagName": info["tagName"], "isLatest": info["tagName"] == latest})
    print(json.dumps(rows))
elif command == "download":
    tag = args[2]
    destination = Path(args[args.index("--dir") + 1])
    assets = releases / tag / "assets"
    if not assets.is_dir():
        raise SystemExit("release is missing")
    for asset in assets.iterdir():
        shutil.copy2(asset, destination / asset.name)
elif command == "create":
    tag = args[2]
    paths = []
    index = 3
    options_with_values = {"--repo", "--target", "--title", "--notes"}
    while index < len(args):
        value = args[index]
        if value in options_with_values:
            index += 2
        elif value.startswith("--"):
            index += 1
        else:
            paths.append(Path(value))
            index += 1
    release_dir = releases / tag
    assets_dir = release_dir / "assets"
    assets_dir.mkdir(parents=True)
    names = []
    for path in paths:
        name = path.name
        if os.environ.get("GOOARCHY_TEST_RENAME_ASSET") == "1":
            name = name.replace(".", "_")
        shutil.copy2(path, assets_dir / name)
        names.append(name)
    (release_dir / "release.json").write_text(json.dumps({"tagName": tag, "draft": True, "assets": names}))
elif command == "view":
    tag = args[2]
    info = json.loads((releases / tag / "release.json").read_text())
    print("\n".join(info["assets"]))
elif command == "edit":
    tag = args[2]
    info_file = releases / tag / "release.json"
    info = json.loads(info_file.read_text())
    if "--draft=false" in args:
        info["draft"] = False
        info_file.write_text(json.dumps(info))
    if "--latest" in args:
        latest_file.write_text(tag + "\n")
else:
    raise SystemExit(f"unsupported fake gh release command: {command}")
GH
chmod 755 "$test_bin/gh"

cat >"$test_root/redirect-server.py" <<'SERVER'
import http.server
import sys
import urllib.parse
from pathlib import Path

root = Path(sys.argv[1])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        if path == "/health":
            self.send_response(200)
            self.end_headers()
            return
        prefix = "/releases/latest/download/"
        if not path.startswith(prefix):
            filename = path.lstrip("/")
            location = prefix + urllib.parse.quote(filename, safe="")
            self.send_response(302)
            self.send_header("Location", location)
            self.end_headers()
            return
        filename = path[len(prefix):]
        latest = (root / "LATEST").read_text().strip()
        asset = root / "releases" / latest / "assets" / filename
        if not asset.is_file():
            self.send_error(404)
            return
        body = asset.read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass

http.server.HTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
SERVER

fixture_commit() {
  git -C "$fixture" add .
  GIT_AUTHOR_NAME='Test' GIT_AUTHOR_EMAIL='test@example.invalid' \
    GIT_COMMITTER_NAME='Test' GIT_COMMITTER_EMAIL='test@example.invalid' \
    git -C "$fixture" commit -qm 'fixture'
}
git -C "$fixture" init -q -b main
GIT_AUTHOR_NAME='Test' GIT_AUTHOR_EMAIL='test@example.invalid' \
  GIT_COMMITTER_NAME='Test' GIT_COMMITTER_EMAIL='test@example.invalid' \
  git -C "$fixture" commit --allow-empty -qm 'initialize fixture'
fixture_commit

export PATH="$test_bin:$PATH"
export GOOARCHY_RELEASE_REPOSITORY=local/standin
export GOOARCHY_SIGNING_KEY_REF=op://test/repository/signing-key/private-key
export GOOARCHY_TEST_SECRET_KEY="$test_root/test-private-key.asc"
export GOOARCHY_TEST_RELEASE_ROOT="$release_root"
export GOOARCHY_PUBLISH_TMPDIR="$test_root"
export GOOARCHY_TEST_REAL_PACMAN="$real_pacman"

publish="$fixture/packaging/repository/publish.sh"
first_publish_output=$("$publish" --all)
grep -Fq 'gooarchy-flavorings 0123456789abcdef0123456789abcdef01234567' \
  <<<"$first_publish_output" || {
  echo "repository-publish-test: publish output omitted the flavorings source revision" >&2
  exit 1
}
first_tag=$(cat "$release_root/LATEST")
first_assets="$release_root/releases/$first_tag/assets"
first_records=$(python3 "$fixture/packaging/repository/read-db.py" "$first_assets/gooarchy.db")
actual_names=$(cut -f1 <<<"$first_records" | sort)
expected_names=$(printf '%s\n' gooarchy gooarchy-flavorings linux-gooarchy \
  linux-gooarchy-headers scottland xdg-desktop-portal-wlr-gooarchy | sort)
[[ $actual_names == "$expected_names" ]] || {
  echo "repository-publish-test: initial database did not contain the six rev 5 packages" >&2
  exit 1
}
first_scottland_version=$(awk -F '\t' '$1 == "scottland" { print $2 }' <<<"$first_records")
first_scottland_file=$(awk -F '\t' '$1 == "scottland" { print $3 }' <<<"$first_records")
[[ $first_scottland_version == *.wf0.11.0-1 ]] || {
  echo "repository-publish-test: Scottland version did not include the current Arch Wayfire version" >&2
  exit 1
}
grep -Fq "source revision: $scottland_ref." <<<"$first_publish_output" || {
  echo "repository-publish-test: publish output omitted the pinned Scottland source revision" >&2
  exit 1
}
first_scottland_metadata=$(bsdtar -xOf "$first_assets/$first_scottland_file" .PKGINFO)
grep -Fxq 'depend = wayfire=0.11.0' <<<"$first_scottland_metadata" || {
  echo "repository-publish-test: Scottland did not declare the exact Arch Wayfire dependency" >&2
  exit 1
}
gpg --homedir "$key_home" --batch --verify "$first_assets/gooarchy.db.sig" \
  "$first_assets/gooarchy.db" >/dev/null 2>&1 || {
  echo "repository-publish-test: initial repository database signature did not verify" >&2
  exit 1
}
while IFS=$'\t' read -r package_name package_version package_file; do
  [[ -s $first_assets/$package_file && -s $first_assets/$package_file.sig ]] || {
    echo "repository-publish-test: initial release omitted $package_file or its signature" >&2
    exit 1
  }
  gpg --homedir "$key_home" --batch --verify "$first_assets/$package_file.sig" \
    "$first_assets/$package_file" >/dev/null 2>&1 || {
    echo "repository-publish-test: signature did not verify for $package_file" >&2
    exit 1
  }
done <<<"$first_records"

mkdir -m 700 -p "$fixture/packaging/arch/gooarchy-extra"
cat >"$fixture/packaging/arch/gooarchy-extra/PKGBUILD" <<'PKG'
pkgname=gooarchy-extra
pkgver=1.0
pkgrel=1
arch=('any')
PKG
fixture_commit
extension_publish_output=$("$publish" --all)
extension_tag=$(cat "$release_root/LATEST")
[[ $extension_tag != "$first_tag" ]] || {
  echo "repository-publish-test: adding a recipe did not advance the repository" >&2
  exit 1
}
extension_assets="$release_root/releases/$extension_tag/assets"
extension_records=$(python3 "$fixture/packaging/repository/read-db.py" "$extension_assets/gooarchy.db")
actual_extended_names=$(cut -f1 <<<"$extension_records" | sort)
expected_extended_names=$(printf '%s\n' gooarchy gooarchy-extra gooarchy-flavorings \
  linux-gooarchy linux-gooarchy-headers scottland xdg-desktop-portal-wlr-gooarchy | sort)
[[ $actual_extended_names == "$expected_extended_names" ]] || {
  echo "repository-publish-test: adding a recipe did not extend the database without changing its existing packages" >&2
  exit 1
}
grep -Fq 'Published gooarchy-extra version 1.0-1 (replaced none)' <<<"$extension_publish_output" || {
  echo "repository-publish-test: the added recipe was not published as a new package" >&2
  exit 1
}
while IFS=$'\t' read -r prior_name prior_version prior_file; do
  [[ -n $prior_name ]] || continue
  [[ -s $extension_assets/$prior_file && -s $extension_assets/$prior_file.sig ]] || {
    echo "repository-publish-test: adding a recipe dropped a previous database asset for $prior_name" >&2
    exit 1
  }
done <<<"$first_records"

first_scottland_version=$(awk -F '\t' '$1 == "scottland" { print $2 }' <<<"$extension_records")
old_scottland_file=$(awk -F '\t' '$1 == "scottland" { print $3 }' <<<"$extension_records")
old_scottland_hash=$(sha256sum "$extension_assets/$old_scottland_file" | awk '{print $1}')
upgrade_publish_output=$(GOOARCHY_TEST_VERSION_SCOTTLAND=1.1 "$publish" scottland)
upgrade_tag=$(cat "$release_root/LATEST")
[[ $upgrade_tag != "$extension_tag" ]] || {
  echo "repository-publish-test: successful package upgrade did not advance latest" >&2
  exit 1
}
upgrade_assets="$release_root/releases/$upgrade_tag/assets"
upgrade_records=$(python3 "$fixture/packaging/repository/read-db.py" "$upgrade_assets/gooarchy.db")
actual_upgraded_names=$(cut -f1 <<<"$upgrade_records" | sort)
[[ $actual_upgraded_names == "$expected_extended_names" ]] || {
  echo "repository-publish-test: a package update changed the repository's package set" >&2
  exit 1
}
new_scottland_version=$(awk -F '\t' '$1 == "scottland" { print $2 }' <<<"$upgrade_records")
[[ $(vercmp "$new_scottland_version" "$first_scottland_version") -gt 0 ]] || {
  echo "repository-publish-test: new Scottland version did not advance" >&2
  exit 1
}
grep -Fq "Published scottland version $new_scottland_version (replaced $first_scottland_version)" \
  <<<"$upgrade_publish_output" || {
  echo "repository-publish-test: publish output omitted the replacement version" >&2
  exit 1
}
gpg --homedir "$key_home" --batch --verify "$upgrade_assets/gooarchy.db.sig" \
  "$upgrade_assets/gooarchy.db" >/dev/null 2>&1 || {
  echo "repository-publish-test: updated repository database signature did not verify" >&2
  exit 1
}
[[ -s $upgrade_assets/$old_scottland_file && -s $upgrade_assets/$old_scottland_file.sig ]] || {
  echo "repository-publish-test: previous database package files were not retained" >&2
  exit 1
}
[[ $(sha256sum "$upgrade_assets/$old_scottland_file" | awk '{print $1}') == "$old_scottland_hash" ]] || {
  echo "repository-publish-test: retained package changed bytes" >&2
  exit 1
}
while IFS=$'\t' read -r old_name old_version old_file; do
  [[ -n $old_name ]] || continue
  [[ -s $upgrade_assets/$old_file && -s $upgrade_assets/$old_file.sig ]] || {
    echo "repository-publish-test: R9 dropped a prior database asset for $old_name" >&2
    exit 1
  }
done <<<"$extension_records"

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 "$test_root/redirect-server.py" "$release_root" "$port" >/dev/null 2>&1 &
server_pid=$!
for _ in {1..50}; do
  if curl --silent --output /dev/null "http://127.0.0.1:$port/health"; then break; fi
  sleep 0.1
done
curl --fail --silent --show-error --location \
  "http://127.0.0.1:$port/$old_scottland_file" --output "$test_root/retained.pkg"
[[ $(sha256sum "$test_root/retained.pkg" | awk '{print $1}') == "$old_scottland_hash" ]] || {
  echo "repository-publish-test: redirect stand-in could not serve the previous package" >&2
  exit 1
}

if GOOARCHY_TEST_VERSION_SCOTTLAND=1.1 "$publish" scottland >"$test_root/refusal.log" 2>&1; then
  echo "repository-publish-test: R8 accepted a package version that was not newer" >&2
  exit 1
fi
grep -Fq "Refused scottland: new version 1.1-1 is not newer than published version $new_scottland_version; source revision: $scottland_ref; this package remains unchanged." \
  "$test_root/refusal.log" || {
  echo "repository-publish-test: R8 refusal omitted the compared versions or source revision" >&2
  exit 1
}
[[ $(cat "$release_root/LATEST") == "$upgrade_tag" ]] || {
  echo "repository-publish-test: R8 changed the current repository" >&2
  exit 1
}

if GOOARCHY_TEST_RENAME_ASSET=1 GOOARCHY_TEST_VERSION_SCOTTLAND=1.2 \
  "$publish" scottland >"$test_root/rename.log" 2>&1; then
  echo "repository-publish-test: the publisher accepted a renamed release asset" >&2
  exit 1
fi
[[ $(cat "$release_root/LATEST") == "$upgrade_tag" ]] || {
  echo "repository-publish-test: an asset-name mismatch advanced latest" >&2
  exit 1
}

printf 'PASS: initial six-package publish, R2 recipe addition, signatures, R8 refusal, R9 retention, redirect lookup, and A3 filename guard.\n'
