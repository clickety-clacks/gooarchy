#!/usr/bin/env bash
# Exercise the publisher against a local GitHub Releases-shaped stand-in and a throwaway key.
set -euo pipefail

stage1_consumer=0
if (($#)); then
  [[ $# == 1 && $1 == --with-stage1-consumer ]] || {
    echo "Usage: tests/repository-publish-test.sh [--with-stage1-consumer]" >&2
    exit 2
  }
  stage1_consumer=1
fi

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
export TMPDIR="$test_root"

for command_name in bsdtar curl gpg git jq pacman python3 repo-add sha256sum vercmp zstd; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "repository-publish-test: required command is missing: $command_name" >&2
    exit 1
  }
done
real_pacman=$(command -v pacman)
original_path=$PATH
test_wayfire_package_version=0.11.0-1
if ((stage1_consumer)); then
  command -v sudo >/dev/null 2>&1 || {
    echo "repository-publish-test: sudo is required for stage 1 package integration" >&2
    exit 1
  }
  if ! sudo "$real_pacman" -Syy --noconfirm >"$test_root/arch-refresh.log" 2>&1; then
    cat "$test_root/arch-refresh.log" >&2
    echo "repository-publish-test: could not refresh Arch package databases for installer integration" >&2
    exit 1
  fi
  test_wayfire_package_version=$("$real_pacman" -Si extra/wayfire |
    awk '/^[[:space:]]*Version[[:space:]]*:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
  [[ -n $test_wayfire_package_version ]] || {
    echo "repository-publish-test: Arch extra has no current wayfire version" >&2
    exit 1
  }
fi
test_wayfire_version=${test_wayfire_package_version#*:}
test_wayfire_version=${test_wayfire_version%-*}
[[ -n $test_wayfire_version ]] || {
  echo "repository-publish-test: Arch wayfire version is invalid" >&2
  exit 1
}

fixture="$test_root/checkout"
release_root="$test_root/releases"
test_bin="$test_root/bin"
mkdir -m 700 -p "$fixture/packaging/repository" "$fixture/packaging/keys" \
  "$fixture/packaging/arch/xdg-desktop-portal-wlr" "$fixture/packaging/gooarchy-flavorings" \
  "$fixture/packaging/linux-gooarchy" "$fixture/install" "$release_root" "$test_bin"
cp -- "$source_root/packaging/repository/publish.sh" "$fixture/packaging/repository/"
cp -- "$source_root/packaging/repository/read-db.py" "$fixture/packaging/repository/"

scottland_source="$test_root/scottland-source"
mkdir -m 700 -p "$scottland_source/packaging/arch" \
  "$scottland_source/omarchy/themes/watercolor-dream-light" \
  "$scottland_source/omarchy/themes/watercolor-dream-dark"
cat >"$scottland_source/packaging/arch/PKGBUILD" <<'PKG'
pkgname=scottland
pkgver=1.0
pkgrel=1
arch=('x86_64')
  depends=('wayfire=__GOOARCHY_TEST_WAYFIRE_VERSION__')
package() {
  install -d "$pkgdir/usr/share/scottland"
  printf 'repository test fixture\n' >"$pkgdir/usr/share/scottland/fixture"
}
PKG
python3 - "$scottland_source/packaging/arch/PKGBUILD" "$test_wayfire_version" <<'PY'
from pathlib import Path
import sys

path, wayfire_version = sys.argv[1:]
text = Path(path).read_text()
Path(path).write_text(text.replace("__GOOARCHY_TEST_WAYFIRE_VERSION__", wayfire_version))
PY
for theme in watercolor-dream-light watercolor-dream-dark; do
  cat >"$scottland_source/omarchy/themes/$theme/colors.toml" <<'TOML'
background = "#101010"
foreground = "#f0f0f0"
bright_foreground = "#ffffff"
selection = "#303030"
selection_foreground = "#ffffff"
red = "#ff0000"
green = "#00ff00"
yellow = "#ffff00"
blue = "#0000ff"
magenta = "#ff00ff"
cyan = "#00ffff"
muted = "#808080"
bright_red = "#ff8080"
bright_green = "#80ff80"
bright_yellow = "#ffff80"
bright_blue = "#8080ff"
bright_magenta = "#ff80ff"
bright_cyan = "#80ffff"
TOML
  printf 'repository test fixture\n' >"$scottland_source/omarchy/themes/$theme/preview.webp"
done
git -C "$scottland_source" init -q -b main
GIT_AUTHOR_NAME='Test' GIT_AUTHOR_EMAIL='test@example.invalid' \
  GIT_COMMITTER_NAME='Test' GIT_COMMITTER_EMAIL='test@example.invalid' \
  git -C "$scottland_source" add .
GIT_AUTHOR_NAME='Test' GIT_AUTHOR_EMAIL='test@example.invalid' \
  GIT_COMMITTER_NAME='Test' GIT_COMMITTER_EMAIL='test@example.invalid' \
  git -C "$scottland_source" commit -qm 'pinned Scottland fixture'
scottland_commit=$(git -C "$scottland_source" rev-parse HEAD)
scottland_ref=v100.0.0
git -C "$scottland_source" tag "$scottland_ref" "$scottland_commit"

strata_source="$test_root/strata-source"
mkdir -m 700 -p "$strata_source"
cat >"$strata_source/PKGBUILD" <<'PKG'
pkgname=strata-bin
pkgver=1.0
pkgrel=1
arch=('any')
package() {
  install -d "$pkgdir/usr/share/strata"
  printf 'repository test fixture\n' >"$pkgdir/usr/share/strata/fixture"
}
PKG
git -C "$strata_source" init -q -b main
GIT_AUTHOR_NAME='Test' GIT_AUTHOR_EMAIL='test@example.invalid' \
  GIT_COMMITTER_NAME='Test' GIT_COMMITTER_EMAIL='test@example.invalid' \
  git -C "$strata_source" add .
GIT_AUTHOR_NAME='Test' GIT_AUTHOR_EMAIL='test@example.invalid' \
  GIT_COMMITTER_NAME='Test' GIT_COMMITTER_EMAIL='test@example.invalid' \
  git -C "$strata_source" commit -qm 'pinned Strata fixture'
strata_ref=$(git -C "$strata_source" rev-parse HEAD)
cat >"$fixture/install/sources.conf" <<SOURCES
GOOARCHY_SCOTTLAND_REPO=file://$scottland_source
GOOARCHY_SCOTTLAND_LEGACY_PIN_REF=f325ab1331944334010923fb5712558efd3f2395
GOOARCHY_SCOTTLAND_PIN_REF=$scottland_ref
GOOARCHY_SCOTTLAND_PIN_KIND=tag
GOOARCHY_STRATA_AUR=file://$strata_source
GOOARCHY_STRATA_REF=$strata_ref
SOURCES

cat >"$fixture/packaging/arch/PKGBUILD" <<'PKG'
pkgname=gooarchy
pkgver=1.0
pkgrel=1
arch=('any')
PKG
cat >"$fixture/packaging/gooarchy-flavorings/PKGBUILD" <<'PKG'
pkgname=gooarchy-flavorings
_tag=v0.1.0
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

consumer_root=
consumer_commit=$(git -C "$source_root" rev-parse HEAD)
if ((stage1_consumer)); then
  for consumer_file in install/helpers/all.sh install/helpers/logging.sh \
    install/helpers/packages.sh install/helpers/repository.sh install/sources.conf \
    install/packaging/repository.sh install/packaging/gooarchy.sh \
    packaging/keys/gooarchy.asc packaging/keys/gooarchy.fingerprint; do
    [[ -f $source_root/$consumer_file ]] || {
      echo "repository-publish-test: landed stage 1 installer file is missing: $consumer_file" >&2
      exit 1
    }
  done
  consumer_root="$test_root/consumer-checkout"
  git clone --quiet --shared "$source_root" "$consumer_root"
  git -C "$consumer_root" config user.name 'Repository Test'
  git -C "$consumer_root" config user.email 'repository-test@example.invalid'
  cp -- "$fixture/packaging/keys/gooarchy.asc" "$consumer_root/packaging/keys/gooarchy.asc"
  cp -- "$fixture/packaging/keys/gooarchy.fingerprint" \
    "$consumer_root/packaging/keys/gooarchy.fingerprint"
  git -C "$consumer_root" add packaging/keys/gooarchy.asc packaging/keys/gooarchy.fingerprint
  GIT_AUTHOR_NAME='Repository Test' GIT_AUTHOR_EMAIL='repository-test@example.invalid' \
    GIT_COMMITTER_NAME='Repository Test' GIT_COMMITTER_EMAIL='repository-test@example.invalid' \
    git -C "$consumer_root" commit -qm 'configure disposable repository key fixture'
  consumer_commit=$(git -C "$consumer_root" rev-parse HEAD)
fi
export GOOARCHY_TEST_CONSUMER_COMMIT="$consumer_commit"

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
epoch_match = re.search(r"^\s*epoch\s*=\s*['\"]?([^'\"\s]+)", text, re.M)
epoch = epoch_match.group(1) if epoch_match else None
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
            + (f"epoch = {epoch}\n" if epoch else "")
            + "".join(f"depend = {dependency}\n" for dependency in depends)
        )
        archive_entries = [".PKGINFO"]
        if name == "gooarchy":
            build_info = Path(temporary) / "usr/share/gooarchy/build-info"
            build_info.parent.mkdir(parents=True)
            build_info.write_text(
                "gooarchy repository test fixture\n"
                f"checkout {os.environ['GOOARCHY_TEST_CONSUMER_COMMIT']}\n"
            )
            archive_entries.append("usr")
        if name == "gooarchy-flavorings":
            apply_tool = Path(temporary) / "usr/bin/gooarchy-flavorings-apply"
            apply_tool.parent.mkdir(parents=True)
            apply_tool.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "[[ -n ${GOOARCHY_TEST_FLAVORINGS_APPLY_MARKER:-} ]]\n"
                "printf 'invoked\\n' >>\"$GOOARCHY_TEST_FLAVORINGS_APPLY_MARKER\"\n"
            )
            apply_tool.chmod(0o755)
            archive_entries.append("usr")
        destination = Path(package_dest) / filename
        with destination.open("wb") as output:
            archive = subprocess.Popen(
                ["bsdtar", "-C", temporary, "-cf", "-", *archive_entries],
                stdout=subprocess.PIPE,
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
INFO
  printf 'Version         : %s\n' "$GOOARCHY_TEST_WAYFIRE_PACKAGE_VERSION"
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
        self._serve(send_body=True)

    def do_HEAD(self):
        self._serve(send_body=False)

    def _serve(self, send_body):
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
        if send_body:
            self.wfile.write(body)

    def log_message(self, *_args):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
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
export GOOARCHY_TEST_WAYFIRE_PACKAGE_VERSION="$test_wayfire_package_version"
unset GOOARCHY_SCOTTLAND_REF GOOARCHY_SCOTTLAND_REF_KIND

publish="$fixture/packaging/repository/publish.sh"
valid_scottland_sources="$test_root/valid-scottland-sources.conf"
cp -- "$fixture/install/sources.conf" "$valid_scottland_sources"
for pin_case in commit branch; do
  cp -- "$valid_scottland_sources" "$fixture/install/sources.conf"
  if [[ $pin_case == commit ]]; then
    sed -i -e 's/^GOOARCHY_SCOTTLAND_PIN_REF=.*/GOOARCHY_SCOTTLAND_PIN_REF=0123456789abcdef0123456789abcdef01234567/' \
      -e 's/^GOOARCHY_SCOTTLAND_PIN_KIND=.*/GOOARCHY_SCOTTLAND_PIN_KIND=commit/' \
      "$fixture/install/sources.conf"
  else
    sed -i -e 's/^GOOARCHY_SCOTTLAND_PIN_REF=.*/GOOARCHY_SCOTTLAND_PIN_REF=0.3/' \
      -e 's/^GOOARCHY_SCOTTLAND_PIN_KIND=.*/GOOARCHY_SCOTTLAND_PIN_KIND=branch/' \
      "$fixture/install/sources.conf"
  fi
  fixture_commit
  if "$publish" --all >"$test_root/nonfinal-scottland-$pin_case.out" \
      2>"$test_root/nonfinal-scottland-$pin_case.err"; then
    echo "repository-publish-test: publisher accepted the non-final Scottland $pin_case pin" >&2
    exit 1
  fi
  if [[ $pin_case == commit ]]; then
    expected_pin_error='commit pins are reserved for the unchanged current Scottland default'
  else
    expected_pin_error='Gooarchy main publication requires a final Scottland version tag or the unchanged current fixed pin'
  fi
  grep -Fq "$expected_pin_error" "$test_root/nonfinal-scottland-$pin_case.err" || {
    echo "repository-publish-test: non-final Scottland $pin_case pin had no clear refusal" >&2
    exit 1
  }
  [[ ! -e $release_root/LATEST ]] || {
    echo "repository-publish-test: non-final Scottland $pin_case pin created a release" >&2
    exit 1
  }
done
cp -- "$valid_scottland_sources" "$fixture/install/sources.conf"
fixture_commit
if GOOARCHY_SCOTTLAND_REF=v100.0.0 GOOARCHY_SCOTTLAND_REF_KIND=tag \
    "$publish" --all >"$test_root/local-scottland-override.out" \
    2>"$test_root/local-scottland-override.err"; then
  echo "repository-publish-test: publisher accepted a local Scottland ref override" >&2
  exit 1
fi
grep -Fq 'publisher reads the configured main pin and does not accept local Scottland ref overrides' \
  "$test_root/local-scottland-override.err" || {
  echo "repository-publish-test: local Scottland ref override had no clear refusal" >&2
  exit 1
}
first_publish_output=$("$publish" --all)
grep -Fq 'gooarchy-flavorings tag:v0.1.0' \
  <<<"$first_publish_output" || {
  echo "repository-publish-test: publish output omitted the flavorings tag pin" >&2
  exit 1
}
grep -Fq "Scottland tag:$scottland_ref (resolved $scottland_commit)" \
  <<<"$first_publish_output" || {
  echo "repository-publish-test: publish output omitted the Scottland tag and resolved source" >&2
  exit 1
}
initial_tag=$(cat "$release_root/LATEST")
valid_flavorings_recipe="$test_root/valid-flavorings-PKGBUILD"
cp -- "$fixture/packaging/gooarchy-flavorings/PKGBUILD" "$valid_flavorings_recipe"
assert_invalid_flavorings_pin() {
  local case_name=$1
  fixture_commit
  if "$publish" gooarchy-flavorings >"$test_root/$case_name.out" 2>"$test_root/$case_name.err"; then
    echo "repository-publish-test: publisher accepted invalid flavorings pin case $case_name" >&2
    exit 1
  fi
  grep -Fq 'must pin exactly one final version _tag for main publication' \
    "$test_root/$case_name.err" || {
    echo "repository-publish-test: invalid flavorings pin case $case_name had no clear error" >&2
    exit 1
  }
  [[ $(cat "$release_root/LATEST") == "$initial_tag" ]] || {
    echo "repository-publish-test: invalid flavorings pin case $case_name changed latest" >&2
    exit 1
  }
}
sed -i -e 's/^_tag=v0.1.0$/_tag=v0.1.1/' \
  -e 's/^pkgver=1.0$/pkgver=1.1/' "$fixture/packaging/gooarchy-flavorings/PKGBUILD"
printf '_commit=0123456789abcdef0123456789abcdef01234567\n' >>"$fixture/packaging/gooarchy-flavorings/PKGBUILD"
assert_invalid_flavorings_pin commit-and-tag
cp -- "$valid_flavorings_recipe" "$fixture/packaging/gooarchy-flavorings/PKGBUILD"
sed -i -e 's/^_tag=v0.1.0$/_tag=v0.1.1/' \
  -e 's/^pkgver=1.0$/pkgver=1.1/' "$fixture/packaging/gooarchy-flavorings/PKGBUILD"
sed -i '/^_tag=/d' "$fixture/packaging/gooarchy-flavorings/PKGBUILD"
printf '_commit=0123456789abcdef0123456789abcdef01234567\n' >>"$fixture/packaging/gooarchy-flavorings/PKGBUILD"
assert_invalid_flavorings_pin commit-only
cp -- "$valid_flavorings_recipe" "$fixture/packaging/gooarchy-flavorings/PKGBUILD"
sed -i -e 's/^_tag=v0.1.0$/_tag=v0.1.1/' \
  -e 's/^pkgver=1.0$/pkgver=1.1/' "$fixture/packaging/gooarchy-flavorings/PKGBUILD"
sed -i '/^_tag=/d' "$fixture/packaging/gooarchy-flavorings/PKGBUILD"
printf '_branch=0.3\n' >>"$fixture/packaging/gooarchy-flavorings/PKGBUILD"
assert_invalid_flavorings_pin branch-only
cp -- "$valid_flavorings_recipe" "$fixture/packaging/gooarchy-flavorings/PKGBUILD"
sed -i -e 's/^_tag=v0.1.0$/_tag=v0.1.1/' \
  -e 's/^pkgver=1.0$/pkgver=1.1/' "$fixture/packaging/gooarchy-flavorings/PKGBUILD"
printf '\n_tag=v0.1.1\n' >>"$fixture/packaging/gooarchy-flavorings/PKGBUILD"
assert_invalid_flavorings_pin both
cp -- "$valid_flavorings_recipe" "$fixture/packaging/gooarchy-flavorings/PKGBUILD"
sed -i '/^_tag=/d' "$fixture/packaging/gooarchy-flavorings/PKGBUILD"
assert_invalid_flavorings_pin missing
cp -- "$valid_flavorings_recipe" "$fixture/packaging/gooarchy-flavorings/PKGBUILD"
sed -i 's/^_tag=.*/_tag=v0.1.1-rc1/' "$fixture/packaging/gooarchy-flavorings/PKGBUILD"
assert_invalid_flavorings_pin malformed
cp -- "$valid_flavorings_recipe" "$fixture/packaging/gooarchy-flavorings/PKGBUILD"
fixture_commit
python3 - "$test_root/incomplete.db" <<'PY'
import io
import sys
import tarfile

database = sys.argv[1]
payload = b"%NAME%\nmissing-metadata\n\n%VERSION%\n1-1\n\n"
with tarfile.open(database, mode="w:gz") as archive:
    member = tarfile.TarInfo("missing-metadata/desc")
    member.size = len(payload)
    archive.addfile(member, io.BytesIO(payload))
PY
if python3 "$fixture/packaging/repository/read-db.py" "$test_root/incomplete.db" \
  >"$test_root/incomplete.out" 2>"$test_root/incomplete.err"; then
  echo "repository-publish-test: the database reader accepted a package record missing required fields" >&2
  exit 1
fi
grep -Fq 'must contain exactly one %FILENAME% field' "$test_root/incomplete.err" || {
  echo "repository-publish-test: malformed database refusal did not identify its missing filename" >&2
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
[[ $first_scottland_version == *.wf$test_wayfire_version-1 ]] || {
  echo "repository-publish-test: Scottland version did not include the current Arch Wayfire version" >&2
  exit 1
}
grep -Fq "source revision: Scottland tag:$scottland_ref (resolved $scottland_commit)" \
  <<<"$first_publish_output" || {
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
grep -Fq "Refused scottland: new version 1.1-1 is not newer than published version $new_scottland_version; source revision: Scottland tag:$scottland_ref (resolved $scottland_commit); this package remains unchanged." \
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

if ((stage1_consumer)); then
  if ! sudo pacman-key --init >"$test_root/pacman-key-init.log" 2>&1; then
    cat "$test_root/pacman-key-init.log" >&2
    echo "repository-publish-test: pacman-key could not initialize in the disposable guest" >&2
    exit 1
  fi
  if ! sudo pacman-key --populate archlinux >"$test_root/pacman-key-populate.log" 2>&1; then
    cat "$test_root/pacman-key-populate.log" >&2
    echo "repository-publish-test: Arch pacman keys could not be populated in the disposable guest" >&2
    exit 1
  fi

  consumer_url="http://127.0.0.1:$port"
  if ! (
    export PATH="$original_path"
    export GOOARCHY_PATH="$consumer_root"
    export GOOARCHY_INSTALL="$consumer_root/install"
    export GOOARCHY_STATE="$test_root/consumer-state/gooarchy"
    export GOOARCHY_BUILD="$test_root/consumer-cache/gooarchy/build"
    export GOOARCHY_YES=1
    export GOOARCHY_AUTOLOGIN=0
    export GOOARCHY_REPOSITORY_URL="$consumer_url"
    export GNUPGHOME="$key_home"
    export HOME="$test_root/consumer-home"
    export XDG_CACHE_HOME="$test_root/consumer-cache"
    export XDG_CONFIG_HOME="$test_root/consumer-config"
    export XDG_DATA_HOME="$test_root/consumer-data"
    export XDG_STATE_HOME="$test_root/consumer-state"
    mkdir -m 700 -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" \
      "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$GOOARCHY_STATE" "$GOOARCHY_BUILD"
    unset GOOARCHY_SCOTTLAND_REF
    source "$GOOARCHY_INSTALL/helpers/all.sh"
    start_install_log
    run_logged "$GOOARCHY_INSTALL/packaging/repository.sh"
    run_logged "$GOOARCHY_INSTALL/packaging/gooarchy.sh"
    stop_install_log
  ) >"$test_root/consumer-install.log" 2>&1; then
    cat "$test_root/consumer-install.log" >&2
    echo "repository-publish-test: stage 1 repository and Gooarchy package paths did not consume the published stand-in" >&2
    exit 1
  fi

  for package_name in gooarchy gooarchy-flavorings; do
    expected_version=$(awk -F '\t' -v package="$package_name" \
      '$1 == package { print $2; exit }' <<<"$upgrade_records")
    installed_version=$("$real_pacman" -Q "$package_name" | awk '{print $2}')
    installed_packager=$("$real_pacman" -Qi "$package_name" |
      awk -F ':[[:space:]]*' '$1 == "Packager" { print $2; exit }')
    validation=$("$real_pacman" -Qi "$package_name" |
      awk -F ':[[:space:]]*' '$1 == "Validated By" { print $2; exit }')
    [[ -n $expected_version && $installed_version == "$expected_version" &&
      $installed_packager == Gooarchy && $validation == *Signature* ]] || {
      echo "repository-publish-test: pacman installed $package_name $installed_version from '$installed_packager' validated by '$validation', expected signed repository version $expected_version" >&2
      exit 1
    }
  done
  grep -Fq "checkout $consumer_commit" /usr/share/gooarchy/build-info || {
    echo "repository-publish-test: installed gooarchy package did not carry the matching source commit" >&2
    exit 1
  }
  grep -Fq "gooarchy and gooarchy-flavorings are installed from the Gooarchy repository." \
    "$test_root/consumer-install.log" || {
    echo "repository-publish-test: the Gooarchy package path did not report repository package consumption" >&2
    exit 1
  }
  grep -Fq "Gooarchy: Trusted Gooarchy repository key $fingerprint." \
    "$test_root/consumer-install.log" &&
    grep -Fq "Gooarchy: Added [gooarchy] at $consumer_url with package signatures required." \
      "$test_root/consumer-install.log" || {
    echo "repository-publish-test: the repository path did not report key trust and repository setup" >&2
    exit 1
  }
  grep -Fq "GOOARCHY_REPOSITORY_SOURCE_COMMIT=$consumer_commit" \
    "$test_root/consumer-state/gooarchy/repository-plan.sh" &&
    grep -Fq 'GOOARCHY_BUILD_LOCAL_GOOARCHY=0' \
      "$test_root/consumer-state/gooarchy/repository-plan.sh" || {
    echo "repository-publish-test: package path did not select repository packages for its exact clean source commit" >&2
    exit 1
  }
  grep -Fq "[gooarchy]" /etc/pacman.conf &&
    grep -Fq "SigLevel = PackageRequired DatabaseOptional" /etc/pacman.conf &&
    grep -Fq "Server = $consumer_url" /etc/pacman.conf || {
    echo "repository-publish-test: the repository path did not configure the signed stand-in" >&2
    exit 1
  }
  printf 'PASS: stage 1 repository and Gooarchy package paths consume signed Gooarchy packages through real pacman.\n'
fi

printf 'x' >>"$upgrade_assets/gooarchy.db"
if GOOARCHY_TEST_VERSION_SCOTTLAND=1.3 "$publish" scottland \
  >"$test_root/tampered-db.log" 2>&1; then
  echo "repository-publish-test: the publisher accepted a repository database with a broken signature" >&2
  exit 1
fi
grep -Fq 'the latest repository database signature is invalid' "$test_root/tampered-db.log" || {
  echo "repository-publish-test: tampered database refusal did not identify the invalid signature" >&2
  exit 1
}
[[ $(cat "$release_root/LATEST") == "$upgrade_tag" ]] || {
  echo "repository-publish-test: a tampered database changed the current repository" >&2
  exit 1
}

printf 'PASS: final-tag source reporting and commit/branch refusal, initial six-package publish, R2 recipe addition, signatures, strict database records, R8 refusal, R9 retention, redirect lookup, and A3 filename guard.\n'
