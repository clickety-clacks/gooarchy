#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# == 2 ]]
product=$(realpath "$1")
evidence=$(realpath -m "$2")
mkdir -p "$evidence"
exec > >(tee -a "$evidence/acceptance.log") 2>&1

finish() {
  local status=$?
  printf '%s\n' "$status" >"$evidence/exit-code"
  if [[ -n ${telemetry_output:-} && -f $telemetry_output ]]; then
    local hop_count
    hop_count=$(grep -c '"event":"http_hop"' "$telemetry_output" || true)
    printf 'PACMAN_HTTP_HOPS=%s\n' "$hop_count"
  fi
  printf 'ACCEPTANCE_EXIT=%s\n' "$status"
}
trap finish EXIT

readonly expected_commit=e33e6843aca5202f4014ca807c05b644211f2764
readonly expected_tree=5d893d28286425f695a334d13710fc80444dbfc0

unset XDG_CACHE_HOME
installer_home=/var/lib/gooarchy-installer
printf 'Stock Arch container image: %s\n' "$ARCH_CONTAINER_IMAGE"
cat /etc/os-release
printf 'Kernel architecture: %s\n' "$(uname -m)"
printf 'Pacman version: %s\n' "$(pacman --version | sed -n '2p')"
[[ -f /etc/arch-release ]]
[[ $(uname -m) == x86_64 ]]
[[ $(id -u) == 0 ]]
printf 'Container root UID: %s\n' "$(id -u)"

source_head=$(git -C "$product" rev-parse HEAD)
source_tree=$(git -C "$product" rev-parse 'HEAD^{tree}')
source_status=$(git -C "$product" status --porcelain)
printf 'Product source commit: %s\n' "$source_head"
printf 'Product source tree: %s\n' "$source_tree"
[[ $source_head == "$expected_commit" ]]
[[ $source_tree == "$expected_tree" ]]
[[ -z $source_status ]]

if pacman -Qq | grep -Fxq strata-bin; then
  echo 'strata-bin was already installed before the repository-step test began.' >&2
  exit 1
fi
echo 'Declared dependency strata-bin is absent at test start.'

if ! getent passwd alpm >/dev/null; then
  useradd --system --no-create-home --home-dir /var/lib/pacman --shell /usr/bin/nologin alpm
fi
if getent passwd installer >/dev/null; then
  echo 'The stock image unexpectedly already contains the installer user.' >&2
  exit 1
fi
useradd --create-home --user-group --home-dir "$installer_home" --shell /bin/bash installer
chmod 0700 "$installer_home"

pacman_conf_tmp=$(mktemp)
awk '
  /^[[:space:]]*DownloadUser[[:space:]]*=/ { next }
  /^[[:space:]]*\[options\][[:space:]]*$/ {
    print
    if (!inserted++) print "DownloadUser = alpm"
    next
  }
  { print }
  END { if (!inserted) exit 1 }
' /etc/pacman.conf >"$pacman_conf_tmp"
install -o root -g root -m 0644 "$pacman_conf_tmp" /etc/pacman.conf
rm -f -- "$pacman_conf_tmp"
[[ $(pacman-conf DownloadUser) == alpm ]]

printf 'Identity UIDs: root=%s installer=%s alpm=%s\n' \
  "$(id -u root)" "$(id -u installer)" "$(id -u alpm)"
[[ $(id -u root) != "$(id -u installer)" ]]
[[ $(id -u root) != "$(id -u alpm)" ]]
[[ $(id -u installer) != "$(id -u alpm)" ]]
[[ $(stat -c %a "$installer_home") == 700 ]]
printf 'Installer home mode: %s\n' "$(stat -c %a "$installer_home")"
printf 'Pacman DownloadUser before package setup: %s\n' "$(pacman-conf DownloadUser)"

pacman -Syu --noconfirm --needed sudo base-devel git
printf 'Installed pacman and Arch keyring versions:\n'
pacman -Q pacman archlinux-keyring
printf 'Global package signature policy: %s\n' "$(pacman-conf SigLevel)"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly telemetry_source="$script_dir/pacman-transfer-telemetry.c"
readonly telemetry_output="$evidence/pacman-transfer-telemetry.jsonl"
readonly telemetry_library="$evidence/pacman-transfer-telemetry.so"
readonly real_pacman=/usr/local/libexec/gooarchy-acceptance-pacman
cp -- "${BASH_SOURCE[0]}" "$evidence/arch-repository-step.sh"
cp -- "$telemetry_source" "$evidence/pacman-transfer-telemetry.c"
printf 'Telemetry compiler: %s\n' "$(cc --version | sed -n '1p')"
cc -std=c11 -Wall -Wextra -Werror -fPIC -shared \
  "$telemetry_source" -o "$telemetry_library" -lcurl -ldl -pthread
printf 'Telemetry library SHA-256: %s\n' "$(sha256sum "$telemetry_library" | awk '{print $1}')"
install -d -o root -g root -m 0755 /usr/local/libexec
if [[ -e $real_pacman ]]; then
  echo 'The task-local pacman telemetry path already exists.' >&2
  exit 1
fi
sha256sum /usr/bin/pacman >"$evidence/pacman-binary.sha256"
install -o root -g root -m 0755 /usr/bin/pacman "$real_pacman"
{
  printf '#!/usr/bin/bash\n'
  printf 'export GOOARCHY_TRANSFER_TELEMETRY=%q\n' "$telemetry_output"
  printf 'export LD_PRELOAD=%q\n' "$telemetry_library"
  printf 'exec %q "$@"\n' "$real_pacman"
} >/usr/bin/pacman
chmod 0755 /usr/bin/pacman
printf 'Pacman transfer telemetry enabled without changing pacman arguments or settings.\n'

install -d -o root -g root -m 0755 /etc/sudoers.d
printf 'installer ALL=(ALL:ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/installer
chmod 0440 /etc/sudoers.d/installer
visudo --check --file=/etc/sudoers.d/installer
sudo -u installer -H git config --global --add safe.directory "$product"
echo 'The installer user can read Git identity for the pinned product checkout.'

installer_home_mode=$(sudo -u installer -H env -u XDG_CACHE_HOME /bin/bash -c \
  'printf "uid=%s home=%s home_mode=%s\n" "$(id -u)" "$HOME" "$(stat -c %a "$HOME")"')
printf 'Installer execution identity: %s\n' "$installer_home_mode"
[[ $installer_home_mode == "uid=$(id -u installer) home=$installer_home home_mode=700" ]]

missing_repo_dir=$(mktemp -d /tmp/gooarchy-empty-repository.XXXXXX)
partial_repository_url="file://$missing_repo_dir/gooarchy.db"
printf 'First repository URL intentionally has no database: %s\n' "$partial_repository_url"
set +e
sudo -u installer -H env -u XDG_CACHE_HOME GOOARCHY_REPOSITORY_URL="$partial_repository_url" \
  /bin/bash -c 'set -Eeuo pipefail; cd "$1"; ./install.sh --yes' _ "$product"
first_attempt_exit=$?
set -e
printf 'Partial repository attempt exit: %s\n' "$first_attempt_exit"
[[ $first_attempt_exit -ne 0 ]]

section_count=$(awk '/^\[gooarchy\][[:space:]]*(#.*)?$/ {count++} END {print count + 0}' /etc/pacman.conf)
printf 'Managed repository sections after partial setup: %s\n' "$section_count"
[[ $section_count == 1 ]]
[[ $(cat "$installer_home/.local/state/gooarchy/last-step") == preflight/guard.sh ]]

set +e
sudo -u installer -H env -u XDG_CACHE_HOME GOOARCHY_TEST_FAIL_AT=packaging/base.sh \
  /bin/bash -c 'set -Eeuo pipefail; cd "$1"; ./install.sh --yes' _ "$product"
retry_exit=$?
set -e
printf 'Retry exit after repository step: %s\n' "$retry_exit"
[[ $retry_exit == 99 ]]
[[ $(cat "$installer_home/.local/state/gooarchy/last-step") == packaging/repository.sh ]]
section_count=$(awk '/^\[gooarchy\][[:space:]]*(#.*)?$/ {count++} END {print count + 0}' /etc/pacman.conf)
printf 'Managed repository sections after retry: %s\n' "$section_count"
[[ $section_count == 1 ]]
[[ $(stat -c %a "$installer_home") == 700 ]]
[[ $(pacman-conf DownloadUser) == alpm ]]

repo_siglevel=$(pacman-conf --repo gooarchy SigLevel)
printf 'Gooarchy package signature policy: %s\n' "$repo_siglevel"
grep -qw PackageRequired <<<"$repo_siglevel"

gooarchy_info=$(pacman -Si gooarchy/gooarchy)
printf '%s\n' "$gooarchy_info" | grep -E '^(Name|Version|Depends On|Packager|Signatures)[[:space:]]*:'
printf '%s\n' "$gooarchy_info" | grep -qE '^Depends On[[:space:]]*:.*(^|[[:space:]])strata-bin([[:space:]]|$)'
if pacman -Qq | grep -Fxq strata-bin; then
  echo 'strata-bin became installed during repository setup; the missing-dependency condition was masked.' >&2
  exit 1
fi

gooarchy_repo_info=$(pacman -Si gooarchy/gooarchy)
gooarchy_repo_name=$(awk -F: '$1 ~ /^[[:space:]]*Name[[:space:]]*$/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<<"$gooarchy_repo_info")
gooarchy_repo_version=$(awk -F: '$1 ~ /^[[:space:]]*Version[[:space:]]*$/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<<"$gooarchy_repo_info")
gooarchy_repo_arch=$(awk -F: '$1 ~ /^[[:space:]]*Architecture[[:space:]]*$/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<<"$gooarchy_repo_info")
[[ $gooarchy_repo_name == gooarchy && -n $gooarchy_repo_version && -n $gooarchy_repo_arch ]]
expected_bootstrap="${gooarchy_repo_name}-${gooarchy_repo_version}-${gooarchy_repo_arch}.pkg.tar.zst"
printf 'Gooarchy repository package identity: name=%s version=%s architecture=%s\n' \
  "$gooarchy_repo_name" "$gooarchy_repo_version" "$gooarchy_repo_arch"
printf 'Expected Gooarchy bootstrap archive: %s\n' "$expected_bootstrap"
actual_bootstrap=$(sudo -u installer -H env -u XDG_CACHE_HOME GOOARCHY_PATH="$product" \
  /bin/bash -c 'set -Eeuo pipefail; source "$GOOARCHY_PATH/install/helpers/repository.sh"; repository_gooarchy_bootstrap_filename')
printf 'Installer bootstrap helper selected: %s\n' "$actual_bootstrap"
[[ $actual_bootstrap == "$expected_bootstrap" ]]
if pacman -Qq | grep -Fxq strata-bin; then
  echo 'The bootstrap lookup changed the local missing-dependency state.' >&2
  exit 1
fi

source_info=$(/bin/bash -c 'source "$1/install/sources.conf"; printf "%s\t%s\n" "$GOOARCHY_STRATA_AUR" "$GOOARCHY_STRATA_REF"' _ "$product")
IFS=$'\t' read -r strata_aur strata_ref <<<"$source_info"
[[ $strata_ref =~ ^[[:xdigit:]]{40}$ ]]
printf 'Install only the declared package dependency from its pinned source: %s at %s\n' "$strata_aur" "$strata_ref"
strata_build_dir=$(mktemp -d /tmp/gooarchy-strata-dependency.XXXXXX)
chown installer:installer "$strata_build_dir"
sudo -u installer -H env -u XDG_CACHE_HOME git clone "$strata_aur" "$strata_build_dir"
sudo -u installer -H git -C "$strata_build_dir" checkout --detach "$strata_ref"
[[ $(sudo -u installer -H git -C "$strata_build_dir" rev-parse HEAD) == "$strata_ref" ]]
sudo -u installer -H env -u XDG_CACHE_HOME /bin/bash -c \
  'set -Eeuo pipefail; cd "$1"; makepkg --syncdeps --noconfirm --force' _ "$strata_build_dir"
strata_package=
strata_package_name=
while IFS= read -r candidate; do
  candidate_package_name=$(pacman -Qp --print-format '%n' "$candidate")
  [[ $candidate_package_name == strata-bin ]] || continue
  if [[ -n $strata_package ]]; then
    echo 'The dependency build produced more than one strata-bin package archive.' >&2
    exit 1
  fi
  strata_package=$candidate
  strata_package_name=$candidate_package_name
done < <(find "$strata_build_dir" -maxdepth 1 -type f -name 'strata-bin-*.pkg.tar.zst' -print)
[[ -n $strata_package ]]
printf 'Selected dependency fixture: package=%s archive=%s\n' "$strata_package_name" "$strata_package"
sudo pacman -U --noconfirm "$strata_package"
pacman -Q strata-bin
echo 'The dependency package is installed only to satisfy pacman for the following Gooarchy package transaction; its executable is not run.'

repo_plan=$installer_home/.local/state/gooarchy/repository-plan.sh
[[ -r $repo_plan ]]
plan_summary=$(sudo -u installer -H /bin/bash -c \
  'source "$1"; printf "source=%s local_build=%s\n" "$GOOARCHY_REPOSITORY_SOURCE_COMMIT" "$GOOARCHY_BUILD_LOCAL_GOOARCHY"' _ "$repo_plan")
printf 'Repository plan: %s\n' "$plan_summary"
[[ $plan_summary == "source=$expected_commit local_build=0" ]]

sudo -u installer -H env -u XDG_CACHE_HOME GOOARCHY_PATH="$product" \
  GOOARCHY_INSTALL="$product/install" /bin/bash -c '
    set -Eeuo pipefail
    export GOOARCHY_STATE="$HOME/.local/state/gooarchy"
    export GOOARCHY_BUILD="$HOME/.cache/gooarchy/build"
    source "$GOOARCHY_INSTALL/helpers/all.sh"
    start_install_log
    run_logged "$GOOARCHY_INSTALL/packaging/gooarchy.sh"
  '

[[ $(pacman -Qq | grep -Fx gooarchy) == gooarchy ]]
[[ $(pacman -Qq | grep -Fx gooarchy-flavorings) == gooarchy-flavorings ]]
for package in gooarchy gooarchy-flavorings; do
  package_info=$(pacman -Qi "$package")
  printf '%s\n' "$package_info" | grep -E '^(Name|Version|Packager|Validated By)[[:space:]]*:'
  printf '%s\n' "$package_info" | grep -qE '^Validated By[[:space:]]*:[[:space:]]*.*Signature'
done

[[ $(pacman-conf DownloadUser) == alpm ]]
[[ $(stat -c %a "$installer_home") == 700 ]]
section_count=$(awk '/^\[gooarchy\][[:space:]]*(#.*)?$/ {count++} END {print count + 0}' /etc/pacman.conf)
[[ $section_count == 1 ]]
printf 'Final checks: DownloadUser=%s installer_home_mode=%s repository_sections=%s XDG_CACHE_HOME=unset\n' \
  "$(pacman-conf DownloadUser)" "$(stat -c %a "$installer_home")" "$section_count"
echo 'Repository-step acceptance passed with a genuinely absent dependency at setup and signed Gooarchy packages installed.'
echo 'ACCEPTANCE_RESULT=PASS'
