#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
unset GOOARCHY_SCOTTLAND_REF GOOARCHY_SCOTTLAND_REF_KIND
source "$repo_root/install/sources.conf"

[[ $GOOARCHY_SCOTTLAND_PIN_REF == v0.3.0 ]]
[[ $GOOARCHY_SCOTTLAND_PIN_KIND == tag ]]
[[ $GOOARCHY_SCOTTLAND_SOURCE_KIND == tag ]]
[[ $GOOARCHY_SCOTTLAND_REF == "$GOOARCHY_SCOTTLAND_PIN_REF" ]]

# The repository upgrade may already have installed Arch's portal package as Scottland's
# dependency. Exercise the real packaging step against that initial state and verify that the
# installed package identity changes to Gooarchy's fork before later install steps run.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/install/helpers" "$tmp/build" "$tmp/state"
printf '%s\n' xdg-desktop-portal-wlr >"$tmp/installed"

cat >"$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat >"$tmp/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case $1 in
  -Qq)
    cat "$PORTAL_TEST_INSTALLED"
    ;;
  -Q)
    package=$2
    grep -Fxq "$package" "$PORTAL_TEST_INSTALLED" || exit 1
    case $package in
      xdg-desktop-portal-wlr) printf '%s\n' "$package 0.8.4-1" ;;
      xdg-desktop-portal-wlr-gooarchy) printf '%s\n' "$package 0.8.4.gooarchy.1-1" ;;
      *) exit 2 ;;
    esac
    ;;
  -U)
    archive=
    for argument in "$@"; do
      if [[ $argument == *.pkg.tar.zst && -f $argument ]]; then archive=$argument; fi
    done
    [[ -n $archive ]] || { echo 'no Gooarchy package archive supplied' >&2; exit 1; }
    printf '%s\n' xdg-desktop-portal-wlr-gooarchy >"$PORTAL_TEST_INSTALLED"
    ;;
  *)
    echo "unexpected pacman command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$tmp/bin/sudo" "$tmp/bin/pacman"

cat >"$tmp/install/helpers/packages.sh" <<'EOF'
build_package() {
  : >"$1/xdg-desktop-portal-wlr-gooarchy-0.8.4.gooarchy.1-1-x86_64.pkg.tar.zst"
}
built_files() {
  printf '%s\n' "$1/xdg-desktop-portal-wlr-gooarchy-0.8.4.gooarchy.1-1-x86_64.pkg.tar.zst"
}
record_build() { :; }
EOF

(
  set -euo pipefail
  export PATH="$tmp/bin:$PATH"
  export PORTAL_TEST_INSTALLED="$tmp/installed"
  export GOOARCHY_INSTALL="$tmp/install"
  export GOOARCHY_BUILD="$tmp/build"
  export GOOARCHY_PATH="$repo_root"
  export GOOARCHY_STATE="$tmp/state"
  source "$repo_root/install/packaging/xdg-desktop-portal-wlr.sh"
) >"$tmp/portal-step.log"

grep -Fq "Replacing xdg-desktop-portal-wlr 0.8.4-1 (Arch's) with Gooarchy's build" \
  "$tmp/portal-step.log"
grep -Fxq xdg-desktop-portal-wlr-gooarchy "$tmp/installed"
! grep -Fxq xdg-desktop-portal-wlr "$tmp/installed"

# Keep the replacement step after repository/bootstrap and base packages, but before the later
# Scottland source build. This is ordering of the installer behavior, not a claim that Arch's
# package cannot be installed by the preceding repository upgrade.
GOOARCHY_INSTALL="$repo_root/install"
GOOARCHY_KERNEL=0
packaging_steps=()
run_logged() { packaging_steps+=("${1##*/}"); }
source "$GOOARCHY_INSTALL/packaging/all.sh"
base_index=-1
portal_index=-1
scottland_index=-1
for index in "${!packaging_steps[@]}"; do
  case ${packaging_steps[$index]} in
    base.sh) base_index=$index ;;
    xdg-desktop-portal-wlr.sh) portal_index=$index ;;
    scottland.sh) scottland_index=$index ;;
  esac
done
((base_index >= 0 && portal_index > base_index && scottland_index > portal_index)) || {
  echo 'portal replacement must follow base packages and precede the Scottland source build' >&2
  exit 1
}

printf 'Scottland portal provider and Arch-package replacement checks passed.\n'
