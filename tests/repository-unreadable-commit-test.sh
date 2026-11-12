#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fixture=$tmp/checkout
mkdir -p "$fixture" "$tmp/bin" "$tmp/build" "$tmp/state" "$tmp/src/target/release"

copy_file() {
  local relative=$1
  mkdir -p "$fixture/$(dirname "$relative")"
  cp "$repo_root/$relative" "$fixture/$relative"
}

for relative in \
  install/sources.conf \
  install/helpers/logging.sh \
  install/helpers/packages.sh \
  install/helpers/repository.sh \
  install/helpers/repository-url.sh \
  install/packaging/repository.sh \
  install/packaging/gooarchy.sh \
  LICENSE \
  packaging/arch/PKGBUILD \
  packaging/arch/30-gooarchy-wayfire-update.hook \
  packaging/arch/gooarchy.install \
  packaging/gooarchy-flavorings/PKGBUILD; do
  copy_file "$relative"
done
mkdir -p "$fixture/packaging/keys" "$fixture/system-tools/vendor" "$fixture/system-tools/target/release"
printf '0123456789abcdef0123456789abcdef01234567\n' >"$fixture/packaging/keys/gooarchy.fingerprint"
printf 'public key fixture\n' >"$fixture/packaging/keys/gooarchy.asc"
printf 'fixture\n' >"$fixture/install/gooarchy-base.packages"
for relative in \
  session/gooarchy-session.sh \
  session/libexec/gooarchy-session-cleanup \
  session/30-gooarchy-keyboard \
  session/35-gooarchy-lock \
  session/gooarchy-lock.pam \
  session/35-gooarchy-lid \
  session/autostart.d/45-gooarchy-clamshell \
  session/libexec/gooarchy-clamshell \
  session/03-link-gooarchy-agent-skills \
  agents/skills/gooarchy/SKILL.md \
  system-tools/LICENSE-omarchy; do
  mkdir -p "$fixture/$(dirname "$relative")"
  : >"$fixture/$relative"
done
for binary in gooarchy gooarchy-look gooarchy-lock gooarchy-software gooarchy-source; do
  : >"$fixture/system-tools/target/release/$binary"
  : >"$tmp/src/target/release/$binary"
done
mkdir -p "$tmp/src/gooarchy-source" "$tmp/src/tools/base" "$tmp/scottland-source"
cp -a "$fixture/." "$tmp/src/gooarchy-source/"
printf '0123456789abcdef0123456789abcdef01234567\n' >"$tmp/src/build-commit"
: >"$tmp/src/base.bundle"
for binary in gooarchy gooarchy-look gooarchy-lock gooarchy-software gooarchy-source; do
  : >"$tmp/src/tools/base/$binary"
done
printf 'MIT license fixture\n' >"$tmp/scottland-source/LICENSE"
printf '[package]\nname = "scottland-source"\n' >"$tmp/scottland-source/Cargo.toml"

cat >"$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -C && ${2:-} == ${GOOARCHY_PATH:-} &&
  ( ${3:-} == rev-parse || ${3:-} == status ) ]]; then
  exit 1
fi
if [[ ${1:-} == -C && ${2:-} == ${TEST_SOURCE_ROOT:-} &&
  ${3:-} == rev-parse && ${4:-} == --show-toplevel ]]; then
  printf '%s\n' "$TEST_SOURCE_ROOT"
  exit 0
fi
exec /usr/bin/git "$@"
EOF
cat >"$tmp/bin/gpg" <<'EOF'
#!/usr/bin/env bash
printf 'fpr:::::::::0123456789ABCDEF0123456789ABCDEF01234567:\n'
EOF
cat >"$tmp/bin/grep" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ $arg == /etc/pacman.conf ]] && exit 1
done
exec /usr/bin/grep "$@"
EOF
cat >"$tmp/bin/awk" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ $arg == /etc/pacman.conf ]]; then
    [[ $* == *'print count + 0'* ]] && printf '0\n'
    exit 0
  fi
done
exec /usr/bin/awk "$@"
EOF
cat >"$tmp/bin/cmp" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ $arg == /etc/pacman.conf ]] && exit 1
done
exec /usr/bin/cmp "$@"
EOF
cat >"$tmp/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -d && ${2:-} == /tmp/gooarchy-repository-package.XXXXXX ]]; then
  exec /usr/bin/mktemp -d "$TEST_TMPDIR/gooarchy-repository-package.XXXXXX"
fi
exec /usr/bin/mktemp "$@"
EOF
cat >"$tmp/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' -Syy '* ]]; then exit 0; fi
case ${1:-} in
  -Si)
    package=${2##*/}
    case $package in
      wayfire) version=0.12.0-1 ;;
      scottland)
        printf 'Name : scottland\nVersion : 0.4.3-1\nPackager : Unknown Packager\nDepends On : wayfire\n'
        exit 0
        ;;
      scottland-sunlight)
        printf 'Name : scottland-sunlight\nVersion : 0.4.3-1\n'
        exit 0
        ;;
      cua-driver) version=0.1.0-1 ;;
      gooarchy) version=1.0-1 ;;
      gooarchy-flavorings) version=0.2.0-1 ;;
      xdg-desktop-portal-wlr-gooarchy) version=0.8.4-1 ;;
      *) exit 2 ;;
    esac
    printf 'Name : %s\nVersion : %s\n' "$package" "$version"
    ;;
  -Sp)
    printf 'gooarchy gooarchy-1.0-1-x86_64.pkg.tar.zst\n'
    ;;
  -Sw)
    cache=
    while (($#)); do
      if [[ $1 == --cachedir ]]; then cache=$2; shift 2; else shift; fi
    done
    [[ -n $cache ]]
    printf 'package fixture\n' >"$cache/gooarchy-1.0-1-x86_64.pkg.tar.zst"
    ;;
  -Qq)
    exit 0
    ;;
  -Q)
    printf '%s 1.0-1\n' "$2"
    ;;
  -U)
    exit 0
    ;;
  *)
    echo "unexpected pacman command: $*" >&2
    exit 2
    ;;
esac
EOF
cat >"$tmp/bin/bsdtar" <<'EOF'
#!/usr/bin/env bash
printf 'source 0123456789abcdef0123456789abcdef01234567\n'
EOF
cat >"$tmp/bin/pacman-key" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
case ${1:-} in
  pacman | pacman-key | bsdtar) exec "$@" ;;
  install | mv) exit 0 ;;
  rm)
    if [[ " $* " == *' /etc/'* ]]; then exit 0; fi
    exec /bin/rm "$@"
    ;;
  *)
    echo "unexpected privileged command: $*" >&2
    exit 97
    ;;
esac
EOF
cat >"$tmp/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
package=$(sed -nE "s/^pkgname=['\"]?([^'\"]+)['\"]?$/\1/p" PKGBUILD | head -n 1)
[[ -n $package ]]
archive=$PWD/$package-1.0-1-any.pkg.tar.zst
if [[ ${1:-} == --packagelist ]]; then
  : >"$archive"
  printf '%s\n' "$archive"
else
  printf '%s\n' "$package" >>"$TEST_BUILD_CALLS"
  : >"$archive"
fi
EOF
cat >"$tmp/bin/cargo" <<'EOF'
#!/usr/bin/env bash
printf '{"packages":[{"name":"scottland-source","manifest_path":"%s"}]}\n' "$TEST_SOURCE_MANIFEST"
EOF
cat >"$tmp/bin/jq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$TEST_SOURCE_MANIFEST"
EOF
chmod +x "$tmp"/bin/*

export PATH="$tmp/bin:$PATH"
export GOOARCHY_PATH=$fixture
export GOOARCHY_INSTALL=$fixture/install
export GOOARCHY_BUILD=$tmp/build
export GOOARCHY_STATE=$tmp/state
export GOOARCHY_INSTALL_LOG_FILE=$tmp/install.log
export TEST_BUILD_CALLS=$tmp/build-calls.log
export TEST_TMPDIR=$tmp
export TEST_SOURCE_ROOT=$tmp/scottland-source
export TEST_SOURCE_MANIFEST=$tmp/scottland-source/Cargo.toml
: >"$TEST_BUILD_CALLS"
: >"$GOOARCHY_INSTALL_LOG_FILE"

bash -eE -o pipefail -c 'source "$GOOARCHY_INSTALL/packaging/repository.sh"' \
  >"$tmp/repository.out" 2>&1 || { cat "$tmp/repository.out" >&2; exit 1; }
grep -Fq "Warning: the installer checkout's Git commit is unreadable; treating it as different from published source commit" \
  "$GOOARCHY_STATE/reports.log"
grep -Fqx 'GOOARCHY_CHECKOUT_COMMIT=unknown' "$GOOARCHY_STATE/repository-plan.sh"
grep -Fqx 'GOOARCHY_BUILD_LOCAL_GOOARCHY=1' "$GOOARCHY_STATE/repository-plan.sh"
grep -Fqx 'GOOARCHY_SCOTTLAND_SUNLIGHT_TARGET=gooarchy/scottland-sunlight=0.4.3-1' \
  "$GOOARCHY_STATE/repository-plan.sh"

bash -eE -o pipefail -c 'source "$GOOARCHY_INSTALL/packaging/gooarchy.sh"' \
  >"$tmp/gooarchy.out" 2>&1 || { cat "$tmp/gooarchy.out" >&2; exit 1; }
[[ $(cat "$TEST_BUILD_CALLS") == $'gooarchy\ngooarchy-flavorings' ]]
grep -Fq 'unknown checkout commit because it could not be read' "$GOOARCHY_STATE/reports.log"
awk -F '\t' '$1 == "gooarchy" && $3 == "unknown" { found=1 } END { exit !found }' \
  "$GOOARCHY_STATE/builds.tsv"

(
  export GOOARCHY_PATH=$fixture
  pkgdir=$tmp/package-root
  srcdir=$tmp/src
  startdir=$fixture/packaging/arch
  source "$fixture/packaging/arch/PKGBUILD"
  # package() uses jq; verify the build dependency before the fixture provides its mock.
  [[ " ${makedepends[*]} " == *' jq '* ]]
  package
)
grep -Fqx 'source 0123456789abcdef0123456789abcdef01234567' \
  "$tmp/package-root/usr/share/gooarchy/build-info"
[[ -x $tmp/package-root/usr/lib/gooarchy/tools/base/gooarchy-software ]]
[[ -f $tmp/package-root/usr/share/licenses/gooarchy/scottland-source/LICENSE ]]

printf 'Unreadable checkout commit local-build check passed.\n'
