#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
unset GOOARCHY_SCOTTLAND_REF GOOARCHY_SCOTTLAND_REF_KIND
source "$repo_root/install/sources.conf"
[[ $GOOARCHY_SCOTTLAND_PIN_REF == v0.3.0 ]]
[[ $GOOARCHY_SCOTTLAND_PIN_KIND == tag ]]
[[ $GOOARCHY_SCOTTLAND_SOURCE_KIND == tag ]]
[[ $GOOARCHY_SCOTTLAND_REF == "$GOOARCHY_SCOTTLAND_PIN_REF" ]]

# Exercise the portal consumer against a pacman model that reports package origin/signature,
# resolves and downloads the exact signed-repository version, and applies pacman -U conflicts.
# No makepkg implementation is available to the consumer; a call to it is a product failure.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/build" "$tmp/state"
cat >"$tmp/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
echo "unexpected portal makepkg invocation: $*" >&2
exit 97
EOF
cat >"$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat >"$tmp/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$PORTAL_TEST_CALLS"
state=$PORTAL_TEST_INSTALLED
find_package() { awk -F '\t' -v name="$1" '$1 == name { print; exit }' "$state"; }
repo_version=$PORTAL_TEST_REPO_VERSION
case $1 in
  -Qq)
    if (($# > 1)); then
      row=$(find_package "$2")
      [[ -n $row ]] || exit 1
      printf '%s\n' "${row%%$'\t'*}"
    else
      cut -f1 "$state"
    fi
    ;;
  -Q)
    row=$(find_package "$2")
    [[ -n $row ]] || exit 1
    IFS=$'\t' read -r name version origin <<<"$row"
    printf '%s %s\n' "$name" "$version"
    ;;
  -Qi)
    row=$(find_package "$2")
    [[ -n $row ]] || exit 1
    IFS=$'\t' read -r name version origin <<<"$row"
    case $origin in
      gooarchy) packager=Gooarchy; validated='Signature' ;;
      arch) packager='Arch Linux'; validated='Signature' ;;
      local) packager='Local build'; validated='Unknown' ;;
      *) exit 2 ;;
    esac
    printf 'Name            : %s\nVersion         : %s\nPackager        : %s\nValidated By    : %s\n' \
      "$name" "$version" "$packager" "$validated"
    ;;
  -Si)
    printf 'Name            : %s\nVersion         : %s\n' \
      "${2#gooarchy/}" "$repo_version"
    ;;
  -Sp)
    spec=${*: -1}
    name=${spec#gooarchy/}
    version=${name#*=}
    name=${name%%=*}
    [[ $version == "$repo_version" ]] || exit 3
    printf '%s-%s-x86_64.pkg.tar.zst\n' "$name" "$version"
    ;;
  -Sw)
    cache=
    spec=
    shift
    while (($#)); do
      case $1 in
        --cachedir) cache=$2; shift 2 ;;
        *) spec=$1; shift ;;
      esac
    done
    name=${spec#gooarchy/}
    version=${name#*=}
    name=${name%%=*}
    [[ -n $cache && $version == "$repo_version" ]] || exit 4
    printf 'signed package fixture\n' >"$cache/$name-$version-x86_64.pkg.tar.zst"
    ;;
  -U)
    archive=${*: -1}
    name=xdg-desktop-portal-wlr-gooarchy
    [[ ${archive##*/} == "$name-$repo_version-x86_64.pkg.tar.zst" && -s $archive ]] || exit 5
    tmp_state=$state.new
    awk -F '\t' '$1 != "xdg-desktop-portal-wlr" && $1 != "xdg-desktop-portal-wlr-gooarchy"' \
      "$state" >"$tmp_state"
    printf '%s\t%s\tgooarchy\n' "$name" "$repo_version" >>"$tmp_state"
    mv "$tmp_state" "$state"
    ;;
  *)
    echo "unexpected pacman command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$tmp/bin/makepkg" "$tmp/bin/sudo" "$tmp/bin/pacman"

export PATH="$tmp/bin:$PATH"
export PORTAL_TEST_CALLS="$tmp/pacman-calls.log"
export PORTAL_TEST_REPO_VERSION=0.8.4.gooarchy.1-1

run_consumer() {
  local label=$1
  : >"$tmp/install.log"
  : >"$PORTAL_TEST_CALLS"
  shift
  printf '%b\n' "$@" >"$PORTAL_TEST_INSTALLED"
  export GOOARCHY_BUILD="$tmp/build/$label"
  export GOOARCHY_STATE="$tmp/state/$label"
  export GOOARCHY_INSTALL_LOG_FILE="$tmp/install.log"
  mkdir -p "$GOOARCHY_BUILD" "$GOOARCHY_STATE"
  local portal_installed=0 portal_repository_copy=0 portal_version=
  local arch_installed=0 arch_version=
  if awk -F '\t' '$1 == "xdg-desktop-portal-wlr-gooarchy" { found=1 } END { exit !found }' "$PORTAL_TEST_INSTALLED"; then
    portal_installed=1
    portal_version=$(awk -F '\t' '$1 == "xdg-desktop-portal-wlr-gooarchy" {print $2}' "$PORTAL_TEST_INSTALLED")
    [[ $(awk -F '\t' '$1 == "xdg-desktop-portal-wlr-gooarchy" {print $3}' "$PORTAL_TEST_INSTALLED") == gooarchy ]] &&
      portal_repository_copy=1
  fi
  if awk -F '\t' '$1 == "xdg-desktop-portal-wlr" { found=1 } END { exit !found }' "$PORTAL_TEST_INSTALLED"; then
    arch_installed=1
    arch_version=$(awk -F '\t' '$1 == "xdg-desktop-portal-wlr" {print $2}' "$PORTAL_TEST_INSTALLED")
  fi
  cat >"$GOOARCHY_STATE/repository-plan.sh" <<EOF
GOOARCHY_REPOSITORY_PACKAGER=Gooarchy
GOOARCHY_PREVIOUS_PORTAL_INSTALLED=$portal_installed
GOOARCHY_PREVIOUS_PORTAL_REPOSITORY_COPY=$portal_repository_copy
GOOARCHY_PREVIOUS_PORTAL_VERSION=$portal_version
GOOARCHY_PREVIOUS_ARCH_PORTAL_INSTALLED=$arch_installed
GOOARCHY_PREVIOUS_ARCH_PORTAL_VERSION=$arch_version
EOF
  export PORTAL_TEST_INSTALLED="$tmp/installed.tsv"
  bash -eE -o pipefail -c 'source "$GOOARCHY_INSTALL/packaging/xdg-desktop-portal-wlr.sh"' \
    bash >"$tmp/$label.out" 2>&1 || {
      cat "$tmp/$label.out" >&2
      return 1
    }
  ! awk -F '\t' '$1 == "xdg-desktop-portal-wlr" { found=1 } END { exit !found }' "$PORTAL_TEST_INSTALLED"
  awk -F '\t' '$1 == "xdg-desktop-portal-wlr-gooarchy" { found=1 } END { exit !found }' "$PORTAL_TEST_INSTALLED"
  [[ $(awk -F '\t' '$1 == "xdg-desktop-portal-wlr-gooarchy" {print $2}' "$PORTAL_TEST_INSTALLED") == \
    "$PORTAL_TEST_REPO_VERSION" ]]
  [[ $(awk -F '\t' '$1 == "xdg-desktop-portal-wlr-gooarchy" {print $3}' "$PORTAL_TEST_INSTALLED") == gooarchy ]]
  if [[ ${EXPECT_INSTALL:-0} == 1 ]]; then
    grep -q -- '-U ' "$PORTAL_TEST_CALLS"
  else
    ! grep -q -- '-U ' "$PORTAL_TEST_CALLS"
  fi
  ! grep -q 'unexpected portal makepkg invocation' "$tmp/$label.out"
}

portal_version=0.8.4.gooarchy.1-1
local_install_version() {
  local label=$1 old_version=$2
  export EXPECT_INSTALL=1
  run_consumer "$label" "xdg-desktop-portal-wlr-gooarchy\t$old_version\tlocal"
  grep -Fq "local package xdg-desktop-portal-wlr-gooarchy $old_version" "$tmp/$label.out"
  grep -Fq "signed Gooarchy xdg-desktop-portal-wlr-gooarchy $portal_version" "$tmp/$label.out"
  grep -Fq 'because Gooarchy' "$tmp/$label.out"
  grep -Fq 'To go back, reinstall the previous' "$tmp/$label.out"
  grep -Fq "gooarchy/xdg-desktop-portal-wlr-gooarchy=$portal_version" "$PORTAL_TEST_CALLS"
  unset EXPECT_INSTALL
}

export GOOARCHY_INSTALL="$repo_root/install"
export PORTAL_TEST_INSTALLED="$tmp/installed.tsv"

# R21(a): a fresh setup obtains the signed repository package without a local makepkg build.
export EXPECT_INSTALL=1
run_consumer fresh
grep -Fq 'Installed signed Gooarchy xdg-desktop-portal-wlr-gooarchy' "$tmp/fresh.out"
grep -Fq 'maintained Wayfire screen-sharing backend' "$tmp/fresh.out"
grep -q -- '-U ' "$PORTAL_TEST_CALLS"
unset EXPECT_INSTALL

# R21(b): older, equal, and newer local versions all become the exact signed repository version,
# with both versions, the reason, and recovery guidance in the report.
local_install_version local-older 0.8.3-1
local_install_version local-equal "$portal_version"
local_install_version local-newer 0.8.5-1

# R21(c): an existing Arch package is replaced by Gooarchy's signed provider and can be restored.
export EXPECT_INSTALL=1
run_consumer arch-existing "xdg-desktop-portal-wlr\t0.8.4-1\tarch"
grep -Fq 'Arch xdg-desktop-portal-wlr 0.8.4-1' "$tmp/arch-existing.out"
grep -Fq "signed Gooarchy xdg-desktop-portal-wlr-gooarchy $portal_version" "$tmp/arch-existing.out"
grep -Fq 'run sudo pacman -S xdg-desktop-portal-wlr' "$tmp/arch-existing.out"
unset EXPECT_INSTALL

# R22: after the ordinary repository upgrade advances an already signed copy, the consumer stays
# on that exact version without downloading or rebuilding a second copy.
export PORTAL_TEST_REPO_VERSION=0.8.4.gooarchy.2-1
printf '%s\t%s\tgooarchy\n' xdg-desktop-portal-wlr-gooarchy 0.8.4.gooarchy.2-1 >"$PORTAL_TEST_INSTALLED"
# repository.sh captured the prior installed version before pacman -Syu; the state above is the
# package after that normal upgrade.
export GOOARCHY_BUILD="$tmp/build/repository-upgrade"
export GOOARCHY_STATE="$tmp/state/repository-upgrade"
export GOOARCHY_INSTALL_LOG_FILE="$tmp/install.log"
mkdir -p "$GOOARCHY_BUILD" "$GOOARCHY_STATE"
cat >"$GOOARCHY_STATE/repository-plan.sh" <<'EOF'
GOOARCHY_REPOSITORY_PACKAGER=Gooarchy
GOOARCHY_PREVIOUS_PORTAL_INSTALLED=1
GOOARCHY_PREVIOUS_PORTAL_REPOSITORY_COPY=1
GOOARCHY_PREVIOUS_PORTAL_VERSION=0.8.4.gooarchy.1-1
GOOARCHY_PREVIOUS_ARCH_PORTAL_INSTALLED=0
GOOARCHY_PREVIOUS_ARCH_PORTAL_VERSION=
EOF
: >"$PORTAL_TEST_CALLS"
bash -eE -o pipefail -c 'source "$GOOARCHY_INSTALL/packaging/xdg-desktop-portal-wlr.sh"' \
  bash >"$tmp/repository-upgrade.out" 2>&1
grep -Fq 'from 0.8.4.gooarchy.1-1 to 0.8.4.gooarchy.2-1 through the repository upgrade' \
  "$tmp/repository-upgrade.out"
[[ $(awk -F '\t' '$1 == "xdg-desktop-portal-wlr-gooarchy" {print $2}' "$PORTAL_TEST_INSTALLED") == \
  "$PORTAL_TEST_REPO_VERSION" ]]
[[ $(awk -F '\t' '$1 == "xdg-desktop-portal-wlr-gooarchy" {print $3}' "$PORTAL_TEST_INSTALLED") == gooarchy ]]
! grep -q -- '-U ' "$PORTAL_TEST_CALLS"
! grep -q -- '-Sw ' "$PORTAL_TEST_CALLS"

# The consumer remains between base/repository setup and Scottland's later source step.
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
  echo 'portal repository install must follow base/repository setup and precede Scottland source setup' >&2
  exit 1
}

printf 'Scottland portal repository-consumer checks passed.\n'
