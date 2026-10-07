#!/bin/bash
# Guest-side checks for the NVIDIA installer. Run only through tests/vm/run.sh on the
# disposable Plumbus guest; this script changes packages, initramfs images and test config.
# R15 boot rows pause with a per-kernel manifest; the runner reboots its sound kernels, records a
# result file for each at r15-boot-evidence-<row>-<kernel>.tsv, then calls r15-release <row> before
# recovering the held fixture. Each result records schema, row, stamp, kernel, boot-id, desktop=pass,
# and nvidia-device=no-device as tab-separated key/value lines.
# The pacman-lock R15 row verifies fail-closed behavior with a test-owned stale db.lck; cleanup
# removes only that exact lock file after the matrix records whether the installer preserved it.
set -euo pipefail

[[ ${GOOARCHY_VM_GUEST_NVIDIA_MATRIX:-} == 1 ]] || {
  echo 'Run this matrix only through tests/vm/run.sh in its disposable guest.' >&2
  exit 2
}

phase=${1:-postinstall}
repo=${GOOARCHY_NVIDIA_REPO:-$HOME/gooarchy}
test_stamp=${GOOARCHY_NVIDIA_TEST_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)-$$}
test_root=${GOOARCHY_NVIDIA_ARTIFACTS:-$HOME/gooarchy-nvidia-matrix/$test_stamp}
state=$HOME/.local/state/gooarchy
owned=/etc/mkinitcpio.conf.d/gooarchy-nvidia.conf
supported='10de,0x030000,0x25a2,0'
legacy='10de,0x030000,0x1b80,0'
dual_gpu=$'0x8086,0x030000,0x9a49,1\n10de,0x030200,0x25a2,0'
checks=0
failures=0
last_status=0
old_utils_package=
old_dkms_package=
old_utils_sha=
old_dkms_sha=

mkdir -p "$test_root" "$state"
test_root=$(realpath "$test_root")
if [[ $phase == r15-release ]]; then
  [[ -n ${GOOARCHY_NVIDIA_ARTIFACTS:-} && -f $test_root/r15-boot-held ]] || {
    echo 'r15-release requires the held row and its NVIDIA artifact directory.' >&2
    exit 2
  }
  IFS=$'\t' read -r held_row held_stamp held_plan_sha <"$test_root/r15-boot-held"
  [[ ${2:-} == "$held_row" && $held_stamp =~ ^[[:alnum:]_.-]+$ ]] || {
    echo 'r15-release row does not match the held NVIDIA failure state.' >&2
    exit 2
  }
  [[ $held_plan_sha =~ ^[[:xdigit:]]{64}$ ]] || {
    echo 'r15-release has no valid held-manifest hash.' >&2
    exit 2
  }
  if [[ -n ${GOOARCHY_NVIDIA_TEST_STAMP:-} && $GOOARCHY_NVIDIA_TEST_STAMP != "$held_stamp" ]]; then
    echo 'r15-release test stamp does not match the held NVIDIA fixture.' >&2
    exit 2
  fi
  test_stamp=$held_stamp
fi
[[ $test_stamp =~ ^[[:alnum:]_.-]+$ ]] || {
  echo 'GOOARCHY_NVIDIA_TEST_STAMP contains unsupported characters.' >&2
  exit 2
}
user_config=/etc/mkinitcpio.conf.d/gooarchy-nvidia-test-$test_stamp.conf
dynamic_modules=/etc/gooarchy-nvidia-test-modules-$test_stamp
r11_config=/etc/mkinitcpio-r11-test-$test_stamp.conf
mkdir -p "$test_root/bin"
cat >"$test_root/nvidia-test-bash-env.sh" <<'EOF'
gooarchy_test_restore_mkinitcpio_hook() {
  local hook=/usr/share/libalpm/hooks/90-mkinitcpio-install.hook
  local saved=${GOOARCHY_VM_NVIDIA_TEST_ROOT:-$HOME}/90-mkinitcpio-install.hook.saved
  if [[ -f $saved ]]; then command sudo mv -f "$saved" "$hook"; fi
}

gooarchy_test_install_mkinitcpio_hook() {
  local hook=/usr/share/libalpm/hooks/90-mkinitcpio-install.hook
  local saved=${GOOARCHY_VM_NVIDIA_TEST_ROOT:-$HOME}/90-mkinitcpio-install.hook.saved
  local wrapper=${GOOARCHY_VM_NVIDIA_TEST_ROOT:-$HOME}/bin/mkinitcpio
  [[ -f $hook && -x $wrapper && ! -e $saved ]] || return 1
  [[ $wrapper =~ ^/[[:alnum:]_./-]+$ ]] || return 1
  grep -Eq '^[[:space:]]*Exec[[:space:]]*=[[:space:]]*/usr/bin/mkinitcpio[[:space:]]+-P[[:space:]]*$' "$hook" || return 1
  command sudo cp -a "$hook" "$saved" || return 1
  if ! command sudo sed -i -E "s|^[[:space:]]*Exec[[:space:]]*=.*$|Exec = $wrapper -P|" "$hook"; then
    gooarchy_test_restore_mkinitcpio_hook
    return 1
  fi
}

systemctl() {
  printf '%s\n' "$*" >>"${GOOARCHY_VM_NVIDIA_TEST_ROOT:-$HOME}/systemctl.trace"
  command systemctl "$@"
}

sudo() {
  local fail_preset= fail_kernel pkgbase rc is_upgrade=0 hook_installed=0
  local -a args=("$@")
  if [[ ${args[0]:-} == systemctl ]]; then
    printf '%s\n' "${args[*]}" >>"${GOOARCHY_VM_NVIDIA_TEST_ROOT:-$HOME}/systemctl.trace"
  fi
  if [[ ${1:-} == pacman && " $* " == *' -Syu '* &&
        ${GOOARCHY_TEST_CAPTURE_ARCH_UPGRADE:-} == 1 ]]; then
    fail_preset=${GOOARCHY_TEST_ARCH_UPGRADE_HOOK_FAIL_PRESET:-}
    is_upgrade=1
  elif [[ ${1:-} == pacman && ${GOOARCHY_TEST_NVIDIA_FAIL:-} == *pacman-hook:* ]]; then
    fail_kernel=${GOOARCHY_TEST_NVIDIA_FAIL#*pacman-hook:}
    fail_kernel=${fail_kernel%%,*}
    if [[ -r /usr/lib/modules/$fail_kernel/pkgbase ]]; then
      pkgbase=$(</usr/lib/modules/$fail_kernel/pkgbase)
      fail_preset=$pkgbase
    fi
  fi
  if [[ -n $fail_preset ]]; then
    if ! gooarchy_test_install_mkinitcpio_hook; then return 97; fi
    hook_installed=1
    if ((is_upgrade)); then args+=(--ignore mkinitcpio); fi
    if command sudo env GOOARCHY_TEST_PACMAN_HOOK_FAIL_PRESET="$fail_preset" \
      PATH="${GOOARCHY_VM_NVIDIA_TEST_ROOT:-$HOME}/bin:$PATH" "${args[@]}"; then
      rc=0
    else
      rc=$?
    fi
  elif command sudo "${args[@]}"; then
    rc=0
  else
    rc=$?
  fi
  if ((hook_installed)) && ! gooarchy_test_restore_mkinitcpio_hook; then rc=98; fi
  if ((is_upgrade)) && ((rc == 0)); then
    command sudo env -u BASH_ENV bash "$GOOARCHY_VM_NVIDIA_TEST_ROOT/capture-upgrade-state.sh" \
      >"$GOOARCHY_VM_NVIDIA_TEST_ROOT/arch-upgrade-state.tsv" || rc=$?
  fi
  return "$rc"
}
EOF
cat >"$test_root/capture-upgrade-state.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
pacman -Q nvidia-utils nvidia-open-dkms | sort
if [[ -e /etc/mkinitcpio.conf.d/gooarchy-nvidia.conf ]]; then
  sha256sum /etc/mkinitcpio.conf.d/gooarchy-nvidia.conf
else
  printf 'absent  /etc/mkinitcpio.conf.d/gooarchy-nvidia.conf\n'
fi
images=()
for module_dir in /usr/lib/modules/*; do
  [[ -f $module_dir/pkgbase && $(<"$module_dir/pkgbase") == linux ]] || continue
  printf 'kernel  %s\n' "${module_dir##*/}"
  find "$module_dir" -type f -name 'nvidia*.ko*' -print0 | sort -z | xargs -0r sha256sum
done
if [[ -r /etc/mkinitcpio.d/linux.preset ]]; then
while IFS= read -r line || [[ -n $line ]]; do
  line=${line%%#*}
  [[ $line =~ ^[[:space:]]*[[:alnum:]_-]+_(image|uki)[[:space:]]*= ]] || continue
  image=${line#*=}
  image=${image#"${image%%[![:space:]]*}"}
  image=${image%"${image##*[![:space:]]}"}
  image=${image#\"}; image=${image%\"}
  image=${image#\'}; image=${image%\'}
  [[ -n $image && $image != *'$'* ]] || { printf 'unresolved  %s\n' "$line"; continue; }
  if [[ -f $image ]]; then sha256sum "$image"; else printf 'missing  %s\n' "$image"; fi
  [[ -f $image ]] && images+=("$image")
done </etc/mkinitcpio.d/linux.preset
else
  printf 'missing-preset  /etc/mkinitcpio.d/linux.preset\n'
fi
for image in "${images[@]}"; do
  tmp=$(mktemp -d)
  if (cd "$tmp" && lsinitcpio -x "$image" >/dev/null 2>&1); then
    while IFS= read -r -d '' module_file; do
      module_name=${module_file##*/}
      module_name=${module_name%.ko*}
      module_name=${module_name//-/_}
      version=$(modinfo -F version "$module_file" 2>/dev/null || true)
      printf 'image-module  %s  %s  %s\n' "$image" "$module_name" "${version:-unknown}"
    done < <(find "$tmp" -type f -name 'nvidia*.ko*' -print0)
  fi
  rm -rf "$tmp"
done
EOF
chmod 0644 "$test_root/capture-upgrade-state.sh"
cat >"$test_root/bin/mkinitcpio" <<'EOF'
#!/bin/bash
if [[ -n ${GOOARCHY_TEST_PACMAN_HOOK_FAIL_PRESET:-} && ${1:-} == -P ]]; then
  status=0
  for preset in /etc/mkinitcpio.d/*.preset; do
    [[ -f $preset ]] || continue
    pkgbase=${preset##*/}
    pkgbase=${pkgbase%.preset}
    if [[ $pkgbase == "$GOOARCHY_TEST_PACMAN_HOOK_FAIL_PRESET" ]]; then
      printf '==> Building image from preset: %s\n' "$preset"
      printf 'ERROR: Gooarchy VM test injected package-hook failure for %s\n' "$pkgbase"
      status=1
    elif ! /usr/bin/mkinitcpio -p "$pkgbase"; then
      status=1
    fi
  done
  exit "$status"
fi
exec /usr/bin/mkinitcpio "$@"
EOF
chmod 0755 "$test_root/bin/mkinitcpio"
restore_r15a_current_state() {
  local status=0 module_dir kernel pkgbase
  sudo rm -f "$user_config" "$dynamic_modules"
  if pacman -Q nvidia-open >/dev/null 2>&1; then
    sudo pacman -Rns --noconfirm nvidia-open || return 1
  fi
  sudo pacman -S --noconfirm --needed nvidia-utils nvidia-open-dkms || return 1
  for module_dir in /usr/lib/modules/*; do
    [[ -f $module_dir/pkgbase ]] || continue
    kernel=${module_dir##*/}
    pkgbase=$(<"$module_dir/pkgbase")
    sudo dkms autoinstall -k "$kernel" >/dev/null 2>&1 || status=1
    sudo mkinitcpio -p "$pkgbase" >/dev/null 2>&1 || status=1
  done
  if ((status == 0)); then
    rm -f "$test_root/r15a-recovery-needed" "$test_root/driver-recovery-needed" \
      "$test_root"/r15a-old-image-*.img "$test_root/r15a-old-images.tsv"
    return 0
  fi
  return 1
}

cleanup() {
  local status=$? build_link_record build_link_path saved_link partial_kernel
  local lock_expected lock_identity_expected lock_actual lock_identity_actual
  if [[ -f $test_root/r15-stale-lock-owned ]]; then
    IFS=$'\t' read -r lock_expected lock_identity_expected <"$test_root/r15-stale-lock-owned"
    if [[ ! -e /var/lib/pacman/db.lck && ! -L /var/lib/pacman/db.lck ]]; then
      rm -f "$test_root/r15-stale-lock-owned"
    elif [[ -f /var/lib/pacman/db.lck && ! -L /var/lib/pacman/db.lck ]]; then
      lock_actual=$(sudo sha256sum -- /var/lib/pacman/db.lck 2>/dev/null | awk '{print $1}' || true)
      lock_identity_actual=$(sudo stat -c '%d:%i' -- /var/lib/pacman/db.lck 2>/dev/null || true)
      if [[ -n $lock_expected && $lock_actual == "$lock_expected" &&
            -n $lock_identity_expected && $lock_identity_actual == "$lock_identity_expected" ]] &&
         sudo rm -f -- /var/lib/pacman/db.lck; then
        rm -f "$test_root/r15-stale-lock-owned"
      else
        printf 'The test-owned pacman lock changed during cleanup; it was left untouched.\n' \
          >"$test_root/cleanup-failure.txt"
        status=1
      fi
    else
      printf 'The test-owned pacman lock was replaced by a non-regular path; it was left untouched.\n' \
        >"$test_root/cleanup-failure.txt"
      status=1
    fi
  fi
  if [[ -f $test_root/r15-boot-held ]]; then
    if [[ -f $test_root/90-mkinitcpio-install.hook.saved ]]; then
      sudo mv -f "$test_root/90-mkinitcpio-install.hook.saved" \
        /usr/share/libalpm/hooks/90-mkinitcpio-install.hook 2>/dev/null || status=1
    fi
    printf 'Preserving the failed R15 state for per-kernel reboot evidence: %s\n' \
      "$(cut -f1 "$test_root/r15-boot-held")" >&2
    return "$status"
  fi
  if [[ -f $test_root/90-mkinitcpio-install.hook.saved ]]; then
    sudo mv -f "$test_root/90-mkinitcpio-install.hook.saved" \
      /usr/share/libalpm/hooks/90-mkinitcpio-install.hook 2>/dev/null || status=1
  fi
  sudo rm -f "$user_config" "$dynamic_modules" "$r11_config" "$test_root"/config-probe-*.img 2>/dev/null || true
  if [[ -f $test_root/owned-original.conf ]]; then sudo mv -f "$test_root/owned-original.conf" "$owned" 2>/dev/null || true; fi
  if [[ -f $test_root/owned-before-dynamic.conf ]]; then sudo mv -f "$test_root/owned-before-dynamic.conf" "$owned" 2>/dev/null || true; fi
  if [[ -f $test_root/owned-held ]]; then sudo mv -f "$test_root/owned-held" "$owned" 2>/dev/null || true; fi
  if [[ -f $test_root/linux.preset.saved ]]; then sudo mv -f "$test_root/linux.preset.saved" /etc/mkinitcpio.d/linux.preset 2>/dev/null || true; fi
  for build_link_record in "$test_root"/*-build-link-path; do
    [[ -f $build_link_record ]] || continue
    build_link_path=$(<"$build_link_record")
    saved_link=${build_link_record%-path}.saved
    [[ -e $saved_link ]] || continue
    [[ -e $build_link_path || -L $build_link_path ]] || sudo mv -f "$saved_link" "$build_link_path" 2>/dev/null || true
  done
  if [[ -f $test_root/pacman.conf.saved ]]; then sudo mv -f "$test_root/pacman.conf.saved" /etc/pacman.conf 2>/dev/null || true; fi
  if [[ -f $test_root/partial-kernel-path ]]; then
    partial_kernel=$(<"$test_root/partial-kernel-path")
    sudo rm -f "$user_config"
    restore_kernel_modules "$partial_kernel" >/dev/null 2>&1 || status=1
    rm -f "$test_root/partial-kernel-path"
  fi
  if [[ -e $test_root/foreign-driver-installed ]]; then
    if pacman -Q gooarchy-test-foreign-nvidia >/dev/null 2>&1; then
      sudo pacman -Rns --noconfirm gooarchy-test-foreign-nvidia >/dev/null 2>&1 || status=1
    fi
    rm -f "$test_root/foreign-driver-installed"
  fi
  if [[ -f $test_root/r15-interrupted-owned.saved ]]; then
    sudo mv -f "$test_root/r15-interrupted-owned.saved" "$owned" || status=1
  fi
  if [[ -e $test_root/r15a-recovery-needed || -e $test_root/driver-recovery-needed ]] &&
     ! restore_r15a_current_state; then
    printf 'NVIDIA package fixture cleanup could not restore current packages, DKMS modules, and images.\n' \
      >"$test_root/cleanup-failure.txt"
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

record() {
  local name=$1 ok=$2 detail=${3:-}
  ((checks += 1))
  if [[ $ok == 1 ]]; then
    printf 'PASS\t%s\t%s\n' "$name" "$detail" | tee -a "$test_root/results.tsv"
  else
    ((failures += 1))
    printf 'FAIL\t%s\t%s\n' "$name" "$detail" | tee -a "$test_root/results.tsv"
  fi
}

tree_hash() {
  sudo python3 - "$1" <<'PY'
import hashlib, os, stat, sys
root = sys.argv[1]
h = hashlib.sha256()
for base, dirs, files in os.walk(root, followlinks=False):
    dirs.sort()
    files.sort()
    for name in dirs + files:
        path = os.path.join(base, name)
        rel = os.path.relpath(path, root)
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode):
            kind, data = b'L', os.readlink(path).encode()
        elif stat.S_ISREG(info.st_mode):
            kind = b'F'
            with open(path, 'rb') as stream:
                data = stream.read()
        elif stat.S_ISDIR(info.st_mode):
            kind, data = b'D', b''
        else:
            kind, data = b'O', str(info.st_rdev).encode()
        h.update(rel.encode() + b'\0' + kind + b'\0' + data + b'\0')
print(h.hexdigest())
PY
}

package_manifest() { pacman -Q | sort; }

capture_repository_pair_mismatch() {
  local evidence=$test_root/nvidia-repository-pair-mismatch.txt repository directive servers package info
  {
    printf 'Observed UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Guest: %s\n' "$(uname -a)"
    printf '\nConfigured repository names and resolved Server values:\n'
    while IFS= read -r repository; do
      [[ -n $repository ]] || continue
      printf '[%s]\n' "$repository"
      for directive in Server CacheServer; do
        printf '  %s:\n' "$directive"
        if servers=$(pacman-conf --repo "$repository" "$directive" 2>/dev/null) && [[ -n $servers ]]; then
          printf '%s\n' "$servers" |
            sed -E 's#(://)[^/@[:space:]]+@#\1[credentials-redacted]@#g; s#([?&](token|key|password|passwd|auth|signature|sig|credential|access_token)=)[^&[:space:]]+#\1[redacted]#Ig' |
            sed 's/^/    /'
        else
          printf '    (none)\n'
        fi
      done
    done < <(pacman-conf --repo-list 2>&1 || true)

    printf '\nAvailable candidates from the configured extra repository:\n'
    for package in nvidia-utils nvidia-open-dkms; do
      if info=$(LC_ALL=C pacman -Si "extra/$package" 2>&1); then
        printf '%s\n' "$info" | awk -F ': ' \
          '$1 == "Repository" || $1 == "Name" || $1 == "Version" || $1 == "Depends On" { print }'
      else
        printf '%s: unavailable\n%s\n' "$package" "$info"
      fi
    done

    printf '\nInstalled NVIDIA package versions:\n'
    pacman -Q nvidia-utils nvidia-open-dkms 2>&1 || true
  } >"$evidence"
  printf '%s\n' "$evidence"
}

verify_repository_driver_pair() {
  local utils_version dkms_version
  utils_version=$(LC_ALL=C pacman -Si extra/nvidia-utils 2>/dev/null |
    awk -F ': ' '$1 == "Version" { print $2; exit }' || true)
  dkms_version=$(LC_ALL=C pacman -Si extra/nvidia-open-dkms 2>/dev/null |
    awk -F ': ' '$1 == "Version" { print $2; exit }' || true)
  if [[ -z $utils_version || -z $dkms_version || $utils_version != "$dkms_version" ]]; then
    local evidence
    evidence=$(capture_repository_pair_mismatch)
    record 'NVIDIA VM repository pair is version-consistent before package mutation' 0 \
      "nvidia-utils ${utils_version:-unavailable}; nvidia-open-dkms ${dkms_version:-unavailable}; source evidence $evidence"
    return 1
  fi
  record 'NVIDIA VM repository pair is version-consistent before package mutation' 1 \
    "nvidia-utils/nvidia-open-dkms $utils_version"
}

ensure_archive_pair() {
  local current_version utils_url dkms_url utils_version dkms_version
  local -a urls=()
  if [[ -n $old_utils_package && -n $old_dkms_package &&
        -n $old_utils_sha && -n $old_dkms_sha &&
        -f $old_utils_package && -f $old_dkms_package &&
        $(sha256sum "$old_utils_package" | awk '{print $1}') == "$old_utils_sha" &&
        $(sha256sum "$old_dkms_package" | awk '{print $1}') == "$old_dkms_sha" ]]; then
    return 0
  fi
  [[ -z $old_utils_package ]] || rm -f "$old_utils_package"
  [[ -z $old_dkms_package ]] || rm -f "$old_dkms_package"
  current_version=$(pacman -Si extra/nvidia-utils | awk -F ': ' '$1 == "Version" {print $2; exit}')
  [[ -n $current_version ]] || return 1
  mapfile -t urls < <(python3 - "$current_version" <<'PY'
from functools import cmp_to_key
from html.parser import HTMLParser
from urllib.request import urlopen
from urllib.parse import urlparse
import re
import subprocess
import sys

current = sys.argv[1]
base = "https://archive.archlinux.org/packages"

class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs = []
    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.hrefs.extend(value for key, value in attrs if key == "href" and value)

def package_versions(package):
    url = f"{base}/{package[0]}/{package}/"
    parser = Links()
    with urlopen(url, timeout=60) as response:
        parser.feed(response.read().decode("utf-8", "replace"))
    versions = set()
    pattern = re.compile(rf"{re.escape(package)}-(.+)-x86_64\.pkg\.tar\.zst$")
    for href in parser.hrefs:
        name = urlparse(href).path.rsplit("/", 1)[-1]
        match = pattern.fullmatch(name)
        if match:
            versions.add(match.group(1))
    return versions

def compare(left, right):
    return int(subprocess.check_output(["vercmp", left, right], text=True).strip())

common = package_versions("nvidia-utils") & package_versions("nvidia-open-dkms")
candidates = [version for version in common if compare(version, current) < 0]
if not candidates:
    raise SystemExit("Arch Linux Archive has no older matching NVIDIA package pair")
version = sorted(candidates, key=cmp_to_key(compare))[-1]
print(f"{base}/n/nvidia-utils/nvidia-utils-{version}-x86_64.pkg.tar.zst")
print(f"{base}/n/nvidia-open-dkms/nvidia-open-dkms-{version}-x86_64.pkg.tar.zst")
PY
)
  ((${#urls[@]} == 2)) || return 1
  utils_url=${urls[0]}
  dkms_url=${urls[1]}
  old_utils_package=$test_root/${utils_url##*/}
  old_dkms_package=$test_root/${dkms_url##*/}
  curl -fL --retry 3 --connect-timeout 30 "$utils_url" -o "$old_utils_package" || return 1
  curl -fL --retry 3 --connect-timeout 30 "$dkms_url" -o "$old_dkms_package" || return 1
  old_utils_sha=$(sha256sum "$old_utils_package" | awk '{print $1}')
  old_dkms_sha=$(sha256sum "$old_dkms_package" | awk '{print $1}')
  utils_version=$(pacman -Qp "$old_utils_package" | awk '{print $2}')
  dkms_version=$(pacman -Qp "$old_dkms_package" | awk '{print $2}')
  [[ -n $utils_version && $utils_version == "$dkms_version" &&
     $(vercmp "$utils_version" "$current_version") -lt 0 ]]
}

report_count() {
  [[ -f $state/reports.log ]] || { printf '0\n'; return; }
  wc -l <"$state/reports.log" | tr -d ' '
}

run_nvidia_step() {
  local name=$1 devices=${2:--} injected_failure=${3:--}
  local log=$test_root/$name.log install_log=$test_root/$name.step.log
  local -a overrides=()
  [[ $devices == - ]] || overrides+=("GOOARCHY_TEST_NVIDIA_DEVICES=$devices")
  [[ $injected_failure == - ]] || overrides+=("GOOARCHY_TEST_NVIDIA_FAIL=$injected_failure")
  if env -u GOOARCHY_TEST_NVIDIA_DEVICES -u GOOARCHY_TEST_NVIDIA_FAIL \
    GOOARCHY_INSTALL="$repo/install" GOOARCHY_STATE="$state" \
    GOOARCHY_INSTALL_LOG_FILE="$install_log" BASH_ENV="$test_root/nvidia-test-bash-env.sh" \
    GOOARCHY_VM_NVIDIA_TEST_ROOT="$test_root" "${overrides[@]}" \
    bash -eE -o pipefail -c \
      'source "$GOOARCHY_INSTALL/helpers/logging.sh"; source "$GOOARCHY_INSTALL/packaging/nvidia.sh"' \
      >"$log" 2>&1; then
    last_status=0
  else
    last_status=$?
  fi
}

run_full_installer() {
  local name=$1 failpoint=${2:--} hook_fail_preset=${3:-linux} log=$test_root/$1.full-install.log
  local -a overrides=("GOOARCHY_TEST_CAPTURE_ARCH_UPGRADE=1")
  [[ $hook_fail_preset == - ]] || overrides+=("GOOARCHY_TEST_ARCH_UPGRADE_HOOK_FAIL_PRESET=$hook_fail_preset")
  [[ $failpoint == - ]] || overrides+=("GOOARCHY_TEST_NVIDIA_FAIL=$failpoint")
  rm -f "$test_root/arch-upgrade-state.tsv"
  : >"$test_root/systemctl.trace"
  if (cd "$repo" && env -u GOOARCHY_TEST_NVIDIA_FAIL -u GOOARCHY_TEST_NVIDIA_DEVICES \
    GOOARCHY_TEST_NVIDIA_DEVICES="$supported" BASH_ENV="$test_root/nvidia-test-bash-env.sh" \
    GOOARCHY_VM_NVIDIA_TEST_ROOT="$test_root" "${overrides[@]}" \
    bash -eE ./install.sh --yes) >"$log" 2>&1; then
    last_status=0
  else
    last_status=$?
  fi
  [[ -f $test_root/arch-upgrade-state.tsv ]] &&
    cp "$test_root/arch-upgrade-state.tsv" "$test_root/$name-upgrade-state.tsv"
}

capture_upgrade_state() {
  local output=$1
  sudo env -u BASH_ENV bash "$test_root/capture-upgrade-state.sh" >"$output"
}

unit_states() {
  local unit output rc
  for unit in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service nvidia-suspend-then-hibernate.service; do
    if output=$(systemctl is-enabled "$unit" 2>&1); then rc=0; else rc=$?; fi
    printf '%s|%s|%s\n' "$unit" "$rc" "$output"
  done
}

preset_images() {
  local preset=$1 line value
  NV_TEST_IMAGES=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    [[ $line =~ ^[[:space:]]*[[:alnum:]_-]+_(image|uki)[[:space:]]*= ]] || continue
    value=${line#*=}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    value=${value#\"}; value=${value%\"}
    value=${value#\'}; value=${value%\'}
    [[ -n $value && $value != *'$'* ]] || return 1
    NV_TEST_IMAGES+=("$value")
  done <"$preset"
  ((${#NV_TEST_IMAGES[@]} > 0))
}

image_modules() {
  local image=$1 tmp
  tmp=$(mktemp -d "$test_root/image.XXXXXXXX") || return 1
  if ! (cd "$tmp" && lsinitcpio -x "$image" >/dev/null 2>&1); then
    rm -rf "$tmp"
    return 1
  fi
  find "$tmp" -type f -name 'nvidia*.ko*' -printf '%f\n' |
    sed -E 's/\.ko.*$//; s/-/_/g' | sort -u
  rm -rf "$tmp"
}

check_image_versions_and_firmware() {
  local image=$1 expected=$2 tmp file version firmware firmware_path
  tmp=$(mktemp -d "$test_root/image-check.XXXXXXXX") || return 1
  if ! (cd "$tmp" && lsinitcpio -x "$image" >/dev/null 2>&1); then
    rm -rf "$tmp"
    return 1
  fi
  while IFS= read -r -d '' file; do
    version=$(modinfo -F version "$file" 2>/dev/null || true)
    if [[ $version != "$expected" ]]; then rm -rf "$tmp"; return 1; fi
    [[ ${file##*/} == nvidia.ko* ]] || continue
    while IFS= read -r firmware; do
      [[ -n $firmware ]] || continue
      firmware_path=$(find "$tmp" -type f -path "*/firmware/$firmware" -print -quit)
      [[ -n $firmware_path ]] || { rm -rf "$tmp"; return 1; }
    done < <(modinfo -F firmware "$file" 2>/dev/null || true)
  done < <(find "$tmp" -type f -name 'nvidia*.ko*' -print0)
  rm -rf "$tmp"
}

image_has_modules_at_version() {
  local image=$1 expected=$2 module modules
  shift 2
  modules=$(image_modules "$image") || return 1
  for module in "$@"; do
    grep -Fxq "$module" <<<"$modules" || return 1
  done
  check_image_versions_and_firmware "$image" "$expected"
}

image_set_for_kernel() {
  local preset image modules
  NV_TEST_KERNEL_IMAGES=()
  for preset in /etc/mkinitcpio.d/*.preset; do
    [[ -f $preset ]] || continue
    [[ ${preset##*/} == "$1.preset" ]] || continue
    preset_images "$preset" || return 1
    NV_TEST_KERNEL_IMAGES+=("${NV_TEST_IMAGES[@]}")
  done
  ((${#NV_TEST_KERNEL_IMAGES[@]} > 0))
}

save_kernel_images() {
  local pkgbase=$1 prefix=$2 index=0 image backup
  image_set_for_kernel "$pkgbase" || return 1
  : >"$test_root/$prefix-images.tsv"
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    backup=$test_root/$prefix-image-$index.img
    sudo cp -a "$image" "$backup" || return 1
    printf '%s\t%s\n' "$image" "$backup" >>"$test_root/$prefix-images.tsv"
    ((index += 1))
  done
}

restore_kernel_images() {
  local prefix=$1 image backup
  [[ -f $test_root/$prefix-images.tsv ]] || return 1
  while IFS=$'\t' read -r image backup; do
    [[ -n $image && -n $backup && -f $backup ]] || return 1
    sudo cp -a "$backup" "$image" || return 1
  done <"$test_root/$prefix-images.tsv"
}

kernel_image_hashes() {
  local pkgbase=$1 image
  image_set_for_kernel "$pkgbase" || return 1
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do sha256sum "$image"; done
}

module_version_from_package() {
  local version=$1
  version=${version#*:}
  printf '%s\n' "${version%-*}"
}

kernel_for_pkgbase() {
  local dir
  for dir in /usr/lib/modules/*; do
    [[ -f $dir/pkgbase ]] || continue
    [[ $(<"$dir/pkgbase") == "$1" ]] && { printf '%s\n' "${dir##*/}"; return 0; }
  done
  return 1
}

kernel_sounds_for_boot() {
  local kernel=$1 pkgbase=$2 module_version=$3 module_file file_version image modules
  while IFS= read -r -d '' module_file; do
    [[ -n $module_version ]] || return 1
    file_version=$(modinfo -F version "$module_file" 2>/dev/null || true)
    [[ $file_version == "$module_version" ]] || return 1
  done < <(find "/usr/lib/modules/$kernel" -type f -name 'nvidia*.ko*' -print0)
  image_set_for_kernel "$pkgbase" || return 1
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    [[ -f $image ]] && lsinitcpio "$image" >/dev/null 2>&1 || return 1
    modules=$(image_modules "$image") || return 1
    if [[ -z $module_version ]]; then
      [[ -z $modules ]] || return 1
    else
      check_image_versions_and_firmware "$image" "$module_version" || return 1
    fi
  done
}

hold_r15_failure_row() {
  local row=$1 partial_kernel= package_version module_version kernel_dir kernel pkgbase
  local image image_hash image_path plan_tmp plan plan_sha boot_id
  [[ ${GOOARCHY_NVIDIA_HOLD_R15_ROW:-} == "$row" ]] || return 0
  [[ $row =~ ^[[:alnum:]_.-]+$ ]] || { echo "invalid R15 row name: $row" >&2; exit 2; }
  [[ -n ${GOOARCHY_NVIDIA_ARTIFACTS:-} ]] || {
    echo 'R15 boot evidence needs the runner-owned GOOARCHY_NVIDIA_ARTIFACTS directory.' >&2
    exit 2
  }
  if ((failures != 0)); then
    echo "R15 row $row cannot be held because an earlier NVIDIA matrix assertion failed." >&2
    exit 1
  fi
  if [[ -f $test_root/partial-kernel-path ]]; then
    partial_kernel=$(<"$test_root/partial-kernel-path")
  fi
  package_version=$(pacman -Q nvidia-utils 2>/dev/null | awk '{print $2}' || true)
  module_version=
  [[ -z $package_version ]] || module_version=$(module_version_from_package "$package_version")
  boot_id=$(cat /proc/sys/kernel/random/boot_id)
  plan=$test_root/r15-boot-$row.tsv
  plan_tmp=$plan.$$
  {
    printf 'schema\t1\nrow\t%s\nhold-boot-id\t%s\n' "$row" "$boot_id"
    printf 'nvidia-utils\t%s\n' "${package_version:-absent}"
    for kernel_dir in /usr/lib/modules/*; do
      [[ -f $kernel_dir/pkgbase ]] || continue
      kernel=${kernel_dir##*/}
      pkgbase=$(<"$kernel_dir/pkgbase")
      if [[ $kernel == "$partial_kernel" ]]; then
        printf 'kernel\tuser-partial\t%s\t%s\n' "$kernel" "$pkgbase"
        continue
      fi
      if kernel_sounds_for_boot "$kernel" "$pkgbase" "$module_version"; then
        printf 'kernel\tsound\t%s\t%s\n' "$kernel" "$pkgbase"
        for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
          image_hash=$(sha256sum "$image" | awk '{print $1}') || exit 1
          image_path=$image
          printf 'image\t%s\t%s\t%s\n' "$kernel" "$image_path" "$image_hash"
        done
      else
        printf 'kernel\tnot-sound\t%s\t%s\n' "$kernel" "$pkgbase"
      fi
    done
  } >"$plan_tmp"
  mv "$plan_tmp" "$plan"
  plan_sha=$(sha256sum -- "$plan" | awk '{print $1}')
  printf '%s\t%s\t%s\n' "$row" "$test_stamp" "$plan_sha" >"$test_root/r15-boot-held"
  printf 'R15 row %s held for reboot checks; eligible kernels are in %s\n' "$row" "$plan"
  exit 0
}

verify_r15_boot_evidence() {
  local row=$1 stamp=$2 manifest_hash=$3 plan=$test_root/r15-boot-$1.tsv
  local type a b c d kernel path expected_hash actual_hash expected_utils=absent actual_utils
  local evidence boot_id hold_boot_id line schema_count=0 row_count=0 utils_count=0 hold_boot_count=0
  local current_plan_hash
  local -A sound_kernels=() image_counts=() seen_boot_ids=()
  local -a expected_lines=()
  [[ -s $plan ]] || { echo "R15 boot manifest is missing for $row." >&2; return 1; }
  current_plan_hash=$(sha256sum -- "$plan" | awk '{print $1}') || return 1
  [[ $current_plan_hash == "$manifest_hash" ]] || {
    echo "R15 boot manifest changed before fixture recovery for $row." >&2
    return 1
  }
  while IFS=$'\t' read -r type a b c d; do
    case $type in
      schema)
        ((schema_count += 1))
        [[ $a == 1 ]] || { echo "unsupported R15 manifest schema for $row." >&2; return 1; }
        ;;
      row)
        ((row_count += 1))
        [[ $a == "$row" ]] || { echo "R15 manifest row mismatch for $row." >&2; return 1; }
        ;;
      hold-boot-id)
        ((hold_boot_count += 1))
        hold_boot_id=$a
        [[ $hold_boot_id =~ ^[[:xdigit:]-]{36}$ ]] || {
          echo "R15 manifest has an invalid hold boot ID for $row." >&2
          return 1
        }
        ;;
      nvidia-utils)
        ((utils_count += 1))
        expected_utils=${a:-absent}
        ;;
      kernel)
        kernel=$b
        [[ $kernel =~ ^[[:alnum:]_.+-]+$ ]] || { echo "invalid kernel in R15 manifest for $row." >&2; return 1; }
        case $a in
          sound) sound_kernels[$kernel]=1 ;;
          user-partial|not-sound) ;;
          *) echo "invalid kernel classification in R15 manifest for $row." >&2; return 1 ;;
        esac
        ;;
      image)
        kernel=$a; path=$b; expected_hash=$c
        [[ $kernel =~ ^[[:alnum:]_.+-]+$ && $expected_hash =~ ^[[:xdigit:]]{64}$ && $path == /* ]] || {
          echo "invalid image entry in R15 manifest for $row." >&2
          return 1
        }
        [[ -f $path ]] || { echo "R15 image disappeared before fixture recovery: $path" >&2; return 1; }
        actual_hash=$(sha256sum -- "$path" | awk '{print $1}') || return 1
        [[ $actual_hash == "$expected_hash" ]] || {
          echo "R15 image changed before fixture recovery: $path" >&2
          return 1
        }
        image_counts[$kernel]=$(( ${image_counts[$kernel]:-0} + 1 ))
        ;;
      *) echo "unknown R15 manifest record in $plan." >&2; return 1 ;;
    esac
  done <"$plan"
  [[ $schema_count == 1 && $row_count == 1 && $hold_boot_count == 1 && $utils_count == 1 ]] || {
    echo "R15 manifest is incomplete for $row." >&2
    return 1
  }
  [[ -n ${sound_kernels[*]:-} ]] || { echo "R15 manifest has no sound kernels for $row." >&2; return 1; }
  for kernel in "${!sound_kernels[@]}"; do
    (( ${image_counts[$kernel]:-0} > 0 )) || {
      echo "R15 sound kernel $kernel has no image hashes in its manifest." >&2
      return 1
    }
    evidence=$test_root/r15-boot-evidence-$row-$kernel.tsv
    [[ -s $evidence ]] || { echo "R15 boot evidence is missing for $row kernel $kernel." >&2; return 1; }
    boot_id=$(awk -F '\t' '$1 == "boot-id" { print $2; exit }' "$evidence")
    [[ $boot_id =~ ^[[:xdigit:]-]{36}$ ]] || {
      echo "R15 boot evidence has no valid boot ID for $row kernel $kernel." >&2
      return 1
    }
    [[ $boot_id != "$hold_boot_id" && -z ${seen_boot_ids[$boot_id]:-} ]] || {
      echo "R15 boot evidence does not show a distinct reboot for $row kernel $kernel." >&2
      return 1
    }
    seen_boot_ids[$boot_id]=1
    expected_lines=(
      $'schema\t1'
      $'row\t'"$row"
      $'stamp\t'"$stamp"
      $'kernel\t'"$kernel"
      $'boot-id\t'"$boot_id"
      $'desktop\tpass'
      $'nvidia-device\tno-device'
    )
    [[ $(wc -l <"$evidence") -eq ${#expected_lines[@]} ]] || {
      echo "R15 boot evidence has an unexpected record count for $row kernel $kernel." >&2
      return 1
    }
    for line in "${expected_lines[@]}"; do
      grep -Fqx -- "$line" "$evidence" || {
        echo "R15 boot evidence lacks '$line' for $row kernel $kernel." >&2
        return 1
      }
    done
  done
  actual_utils=$(pacman -Q nvidia-utils 2>/dev/null | awk '{print $2}' || true)
  [[ ${actual_utils:-absent} == "$expected_utils" ]] || {
    echo "NVIDIA package state changed before R15 fixture recovery for $row." >&2
    return 1
  }
}

remove_kernel_modules() {
  local kernel=$1 module pattern
  shift
  for module in "$@"; do
    case $module in
      nvidia) pattern=nvidia.ko\* ;;
      nvidia_modeset) pattern=nvidia-modeset.ko\* ;;
      nvidia_uvm) pattern=nvidia-uvm.ko\* ;;
      nvidia_drm) pattern=nvidia-drm.ko\* ;;
      *) return 2 ;;
    esac
    sudo find "/usr/lib/modules/$kernel" -type f -name "$pattern" -delete
  done
  sudo depmod -a "$kernel"
}

restore_kernel_modules() {
  local kernel=$1 package_version module_version pkgbase
  package_version=$(pacman -Q nvidia-open-dkms | awk '{print $2}')
  module_version=$(module_version_from_package "$package_version")
  pkgbase=$(<"/usr/lib/modules/$kernel/pkgbase")
  sudo dkms install --force -m nvidia -v "$module_version" -k "$kernel" ||
    sudo dkms autoinstall -k "$kernel"
  sudo depmod -a "$kernel"
  sudo mkinitcpio -p "$pkgbase"
}

compare_with_owned_file_removed() {
  local kernel=$1 preset_base=$2 without_rc with_rc
  local without_modules with_modules without_errors with_errors held=$test_root/owned-held
  local without_image=$test_root/config-probe-without-$kernel.img
  local with_image=$test_root/config-probe-with-$kernel.img
  sudo mv "$owned" "$held"
  if sudo mkinitcpio -k "$kernel" -g "$without_image" >"$test_root/$kernel-without-owned.log" 2>&1; then without_rc=0; else without_rc=$?; fi
  without_errors=$(grep -E 'ERROR: module not found:' "$test_root/$kernel-without-owned.log" | sed -E "s/^.*ERROR: /ERROR: /" | sort || true)
  sudo mv "$held" "$owned"
  if sudo mkinitcpio -k "$kernel" -g "$with_image" >"$test_root/$kernel-with-owned.log" 2>&1; then with_rc=0; else with_rc=$?; fi
  with_errors=$(grep -E 'ERROR: module not found:' "$test_root/$kernel-with-owned.log" | sed -E "s/^.*ERROR: /ERROR: /" | sort || true)
  without_modules=$(image_modules "$without_image" | sort || true)
  with_modules=$(image_modules "$with_image" | sort || true)
  sudo rm -f "$without_image" "$with_image"
  [[ $without_rc == "$with_rc" && $without_errors == "$with_errors" && $without_modules == "$with_modules" ]]
}

check_covered_kernels() {
  local package_version module_version dir kernel pkgbase header_version module version ok
  local -a required=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
  package_version=$(pacman -Q nvidia-utils | awk '{print $2}')
  module_version=$(module_version_from_package "$package_version")
  for dir in /usr/lib/modules/*; do
    [[ -f $dir/pkgbase ]] || continue
    kernel=${dir##*/}
    pkgbase=$(<"$dir/pkgbase")
    header_version=$(pacman -Q "$pkgbase-headers" 2>/dev/null | awk '{print $2}' || true)
    if [[ -z $header_version || $header_version != "$(pacman -Q "$pkgbase" 2>/dev/null | awk '{print $2}' || true)" ]]; then
      if grep -Fq "$kernel" "$state/reports.log"; then
        record "R6 reports uncovered kernel $kernel" 1 "matching headers are not installed"
      else
        record "R6 reports uncovered kernel $kernel" 0 "matching headers are not installed and no report names it"
      fi
      continue
    fi
    ok=1
    for module in "${required[@]}"; do
      version=$(modinfo -k "$kernel" -F version "$module" 2>/dev/null || true)
      [[ $version == "$module_version" ]] || ok=0
    done
    record "R6/R9 module coverage $kernel" "$ok" "nvidia-utils $package_version"
    if ((ok)); then
      image_set_for_kernel "$pkgbase" || { record "R10 images listed for $kernel" 0 "no resolvable preset images"; continue; }
      for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
        local modules
        modules=$(image_modules "$image" 2>/dev/null || true)
        local image_ok=1
        for module in "${required[@]}"; do
          grep -Fxq "$module" <<<"$modules" || image_ok=0
        done
        check_image_versions_and_firmware "$image" "$module_version" || image_ok=0
        record "R10 early-KMS image $image" "$image_ok" "four modules, current versions, declared firmware"
      done
    fi
  done
}

preinstall() {
  local packages_before etc_before boot_before modules_before reports_before status failure unit_before units_absent=1 unit
  verify_repository_driver_pair || return 1
  packages_before=$(package_manifest)
  etc_before=$(tree_hash /etc)
  boot_before=$(tree_hash /boot)
  reports_before=$(report_count)
  run_nvidia_step r2-no-nvidia - -
  status=$last_status
  record 'R2 no NVIDIA changes or report' "$([[ $status == 0 && $packages_before == "$(package_manifest)" && $etc_before == "$(tree_hash /etc)" && $boot_before == "$(tree_hash /boot)" && $reports_before == "$(report_count)" && $(grep -c 'no NVIDIA display function found' "$test_root/r2-no-nvidia.log") == 1 ]] && echo 1 || echo 0)" "status $status"

  packages_before=$(package_manifest)
  etc_before=$(tree_hash /etc)
  boot_before=$(tree_hash /boot)
  reports_before=$(report_count)
  run_nvidia_step r3-legacy "$legacy" -
  status=$last_status
  record 'R3 legacy device stays on fallback' "$([[ $status == 0 && $packages_before == "$(package_manifest)" && $etc_before == "$(tree_hash /etc)" && $boot_before == "$(tree_hash /boot)" && $(($(report_count) - reports_before)) == 1 && $(grep -c '10de:1b80' "$state/reports.log") -ge 1 ]] && echo 1 || echo 0)" "status $status"

  for failure in pacman:before-commit space; do
    packages_before=$(package_manifest)
    etc_before=$(tree_hash /etc)
    boot_before=$(tree_hash /boot)
    modules_before=$(tree_hash /usr/lib/modules)
    run_nvidia_step "r15-precommit-$failure" "$supported" "$failure"
    status=$last_status
    record "R15 $failure fails before package, module, config, or image change" "$([[ $status != 0 && $packages_before == "$(package_manifest)" && $etc_before == "$(tree_hash /etc)" && $boot_before == "$(tree_hash /boot)" && $modules_before == "$(tree_hash /usr/lib/modules)" && ! -e $owned ]] && echo 1 || echo 0)" "status $status"
    case $failure in
      pacman:before-commit) hold_r15_failure_row precommit-download ;;
      space) hold_r15_failure_row precommit-space ;;
    esac
  done

  unit_states >"$test_root/units-before-nvidia-utils.txt"
  unit_before=$(cat "$test_root/units-before-nvidia-utils.txt")
  while IFS= read -r unit; do
    [[ $unit == *'|not-found' ]] || units_absent=0
  done <<<"$unit_before"
  record 'R13 fresh VM begins without NVIDIA sleep units' "$units_absent" 'all four systemd units checked before nvidia-utils installation'
  sudo pacman -S --noconfirm --asexplicit nvidia-utils
  unit_states >"$test_root/units-after-nvidia-utils-transaction.txt"
  package_manifest >"$test_root/packages-after-nvidia-utils.txt"
  pacman -Q nvidia-utils >"$test_root/nvidia-utils-version-before-full-install.txt"
  record 'R13 fresh package transaction state captured' 1 "four service states saved after nvidia-utils installation"
}

postinstall() {
  local before_packages before_etc before_boot before_reports after_units before_units unit
  local source_hash status output unit_before unit_after
  verify_repository_driver_pair || return 1
  check_covered_kernels
  if [[ ${GOOARCHY_VM_REQUIRE_LINUX_GOOARCHY:-1} == 1 ]]; then
    local gooarchy_kernel
    gooarchy_kernel=$(kernel_for_pkgbase linux-gooarchy 2>/dev/null || true)
    record 'R6/R9 integrated linux-gooarchy kernel is present' "$([[ -n $gooarchy_kernel ]] && echo 1 || echo 0)" "${gooarchy_kernel:-kernel package not present}"
  fi

  before_packages=$(package_manifest)
  before_etc=$(tree_hash /etc)
  before_boot=$(tree_hash /boot)
  before_reports=$(report_count)
  run_nvidia_step r17-no-op "$supported" -
  status=$last_status
  record 'R17 same-state rerun is a no-op' "$([[ $status == 0 && $before_packages == "$(package_manifest)" && $before_etc == "$(tree_hash /etc)" && $before_boot == "$(tree_hash /boot)" && $before_reports == "$(report_count)" ]] && echo 1 || echo 0)" "status $status"
  record 'R17 reports already-set-up kernels' "$([[ $status == 0 && $(grep -c 'already set up for' "$test_root/r17-no-op.log") -ge 1 ]] && echo 1 || echo 0)" "no image regeneration requested"

  before_units=$(cat "$test_root/units-after-nvidia-utils-transaction.txt")
  after_units=$(unit_states)
  record 'R13 full install preserves package-supplied service state' "$([[ $before_units == "$after_units" ]] && echo 1 || echo 0)" "state after nvidia-utils transaction compared with installer end"
  if grep -Eq '^[[:space:]]*options[[:space:]]+nvidia[[:space:]].*NVreg_UseKernelSuspendNotifiers=1' /usr/lib/modprobe.d/nvidia-utils.conf &&
     modprobe -c | grep -Eq '^[[:space:]]*options[[:space:]]+nvidia[[:space:]].*NVreg_UseKernelSuspendNotifiers=1' &&
     ! grep -RqsE 'NVreg_UseKernelSuspendNotifiers|NVreg_PreserveVideoMemoryAllocations' /etc/modprobe.d/gooarchy-nvidia.conf; then status=1; else status=0; fi
  record 'R13 keeps Arch notifier default without a Gooarchy override' "$status" 'package default, modprobe -c, and Gooarchy file checked'
  if grep -Eq 'systemctl[[:space:]]+(enable|disable|mask|unmask|preset)[[:space:]]+.*nvidia-' "$repo/install/packaging/nvidia.sh"; then status=0; else status=1; fi
  record 'R13 installer does not change NVIDIA sleep unit state' "$([[ $status == 1 ]] && echo 1 || echo 0)" 'static scan of the step source'

  before_packages=$(package_manifest)
  before_etc=$(tree_hash /etc)
  before_boot=$(tree_hash /boot)
  run_nvidia_step r14-dual-gpu "$dual_gpu" -
  record 'R14 built-in boot GPU leaves selection to desktop' "$([[ $last_status == 0 && $(grep -c 'built-in GPU is the boot GPU' "$test_root/r14-dual-gpu.log") -eq 1 && $before_packages == "$(package_manifest)" && $before_etc == "$(tree_hash /etc)" && $before_boot == "$(tree_hash /boot)" ]] && echo 1 || echo 0)" 'no GPU-selection configuration written'

  if ensure_archive_pair; then
    record 'R8/R15a matching older NVIDIA packages are downloaded from the Arch Linux Archive inside the VM' 1 \
      "nvidia-utils/nvidia-open-dkms $(pacman -Qp "$old_utils_package" | awk '{print $2}'); SHA256s recorded in $test_root"
  else
    record 'R8/R15a matching older NVIDIA packages are downloaded from the Arch Linux Archive inside the VM' 0 \
      'no older matching official package pair could be fetched and verified'
  fi

  test_foreign_owned_file
  test_user_full_list
  test_dynamic_full_list
  test_r15_linux_gooarchy_dkms_failure
  test_pre_enabled_units
  test_custom_preset
  test_r17_header_repair
  test_user_partial_kernels
  test_pacman_hook_failure_with_partial_kernel
  test_prebuilt_replacement
  test_foreign_driver
  test_held_driver
  test_r15_step_regeneration_after_successful_arch_upgrade
  test_r13_full_installer_systemctl_trace
  test_r15a_stale_baseline
  test_r15a_arch_upgrade_hook
  test_r15_interrupted_after_commit

  printf '\nNVIDIA VM matrix: %s/%s checks passed\n' "$((checks - failures))" "$checks"
  printf 'Results: %s/results.tsv\n' "$test_root"
  ((failures == 0))
}

test_r13_full_installer_systemctl_trace() {
  local before after status=0
  before=$(cat "$test_root/units-after-nvidia-utils-transaction.txt")
  after=$(unit_states)
  [[ $before == "$after" ]] || status=1
  record 'R13 NVIDIA units retain their state through the full synthetic install' "$((status == 0))" \
    'states after the nvidia-utils transaction compared with the full installer result'
  status=0
  if [[ ! -f $test_root/systemctl.trace ]] ||
     grep -E '(^|[[:space:]])(enable|disable|mask|unmask|preset)([[:space:]].*)?[[:space:]]nvidia-' \
       "$test_root/systemctl.trace"; then
    status=1
  fi
  record 'R13 full installer systemctl trace contains no NVIDIA unit state changes' "$((status == 0))" \
    "trace $test_root/systemctl.trace"
}

reference() {
  local kernel pkgbase module_version units_before units_after packages_before etc_before boot_before
  local image image_ok=1 module status module_dir kernel_count=0
  local -a required=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
  verify_repository_driver_pair || return 1
  kernel=$(kernel_for_pkgbase linux 2>/dev/null || true)
  if [[ -z $kernel ]]; then
    record 'R18 Linux reference kernel is available' 0 'linux module tree missing'
    return 1
  fi
  for module_dir in /usr/lib/modules/*; do
    [[ -f $module_dir/pkgbase ]] || continue
    pkgbase=$(<"$module_dir/pkgbase")
    kernel_count=$((kernel_count + 1))
    if [[ $pkgbase != linux ]]; then
      record 'R18 reference VM contains only the linux kernel' 0 "found $pkgbase (${module_dir##*/})"
      return 1
    fi
  done
  if ((kernel_count != 1)); then
    record 'R18 reference VM contains only the linux kernel' 0 "found $kernel_count installed kernel trees"
    return 1
  fi
  record 'R18 reference VM contains only the linux kernel' 1 "$kernel"
  units_before=$(unit_states)
  run_nvidia_step r18-reference-bootstrap "$supported" -
  status=$last_status
  if ((status != 0)); then
    record 'R18 reference state can be established' 0 "installer status $status"
    return 1
  fi
  module_version=$(module_version_from_package "$(pacman -Q nvidia-utils | awk '{print $2}')")
  for module in "${required[@]}"; do
    [[ $(modinfo -k "$kernel" -F version "$module" 2>/dev/null || true) == "$module_version" ]] || image_ok=0
  done
  image_set_for_kernel linux || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$module_version" "${required[@]}" || image_ok=0
  done
  if ! grep -Eq '^[[:space:]]*options[[:space:]]+nvidia([[:space:]].*)?NVreg_UseKernelSuspendNotifiers=1' /usr/lib/modprobe.d/nvidia-utils.conf ||
     ! modprobe -c | grep -Eq '^[[:space:]]*options[[:space:]]+nvidia([[:space:]].*)?NVreg_UseKernelSuspendNotifiers=1' ||
     grep -RqsE 'NVreg_UseKernelSuspendNotifiers|NVreg_PreserveVideoMemoryAllocations' /etc/modprobe.d/gooarchy-nvidia.conf; then
    image_ok=0
  fi
  units_after=$(unit_states)
  [[ $units_before == "$units_after" ]] || image_ok=0
  record 'R18 reference state has four current modules, firmware, notifier default and unchanged sleep units' \
    "$image_ok" "linux $kernel; NVIDIA module version $module_version"
  if ((image_ok == 0)); then return 1; fi

  packages_before=$(package_manifest)
  etc_before=$(tree_hash /etc)
  boot_before=$(tree_hash /boot)
  units_before=$(unit_states)
  run_nvidia_step r18-reference-rerun "$supported" -
  status=$last_status
  units_after=$(unit_states)
  record 'R18 reference-state rerun is a no-op' \
    "$([[ $status == 0 && $packages_before == "$(package_manifest)" && $etc_before == "$(tree_hash /etc)" && $boot_before == "$(tree_hash /boot)" && $units_before == "$units_after" && $(grep -c 'already set up for' "$test_root/r18-reference-rerun.log") -ge 1 ]] && echo 1 || echo 0)" \
    "linux $kernel; nvidia-utils $(pacman -Q nvidia-utils | awk '{print $2}')"
}

test_user_full_list() {
  local saved=$test_root/owned-before-static.conf fixture=$test_root/static-modules.conf
  local had_owned=0 before_hash status
  if [[ -e $owned ]]; then
    if ! grep -Fxq '# Gooarchy NVIDIA early KMS modules; managed by the Gooarchy installer.' "$owned"; then
      record 'R10 static all-four fixture can preserve a non-owned path' 0 "$owned is not Gooarchy-owned"
      return
    fi
    sudo mv "$owned" "$saved"
    had_owned=1
  fi
  printf 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\n' >"$fixture"
  sudo cp "$fixture" "$user_config"
  before_hash=$(sha256sum "$user_config" | awk '{print $1}')
  run_nvidia_step r10-static-all-four "$supported" -
  status=$last_status
  record 'R10 static user config supplies all four without an owned drop-in' "$([[ $status == 0 && ! -e $owned && $before_hash == "$(sha256sum "$user_config" | awk '{print $1}')" ]] && echo 1 || echo 0)" "status $status"
  sudo rm -f "$user_config"
  if ((had_owned)); then sudo mv "$saved" "$owned"; fi
}

test_dynamic_full_list() {
  local saved=$test_root/owned-before-dynamic.conf fixture=$test_root/dynamic-modules.conf
  local had_owned=0 before_hash status
  if [[ -e $owned ]]; then
    if ! grep -Fxq '# Gooarchy NVIDIA early KMS modules; managed by the Gooarchy installer.' "$owned"; then
      record 'R10 dynamic all-four fixture can preserve a non-owned path' 0 "$owned is not Gooarchy-owned"
      return
    fi
    sudo mv "$owned" "$saved"
    had_owned=1
  fi
  printf 'nvidia nvidia_modeset nvidia_uvm nvidia_drm\n' | sudo tee "$dynamic_modules" >/dev/null
  printf 'MODULES=($(< %s))\n' "$dynamic_modules" >"$fixture"
  sudo cp "$fixture" "$user_config"
  before_hash=$(sha256sum "$user_config" | awk '{print $1}')
  run_nvidia_step r10-dynamic-all-four "$supported" -
  status=$last_status
  record 'R10 dynamic user config supplies all four without an owned drop-in' "$([[ $status == 0 && ! -e $owned && $before_hash == "$(sha256sum "$user_config" | awk '{print $1}')" ]] && echo 1 || echo 0)" "status $status"
  sudo rm -f "$user_config" "$dynamic_modules"
  if ((had_owned)); then sudo mv "$saved" "$owned"; fi
}

test_pre_enabled_units() {
  local before after status prior_state
  prior_state=$(systemctl is-enabled nvidia-suspend.service 2>&1 || true)
  if ! sudo systemctl enable nvidia-suspend.service >/dev/null 2>&1; then
    record 'R13 pre-enabled NVIDIA unit fixture available' 0 'nvidia-suspend.service could not be enabled in the VM'
    return
  fi
  unit_states >"$test_root/units-before-pre-enabled-rerun.txt"
  before=$(cat "$test_root/units-before-pre-enabled-rerun.txt")
  run_nvidia_step r13-pre-enabled-rerun "$supported" -
  after=$(unit_states)
  record 'R13 pre-enabled NVIDIA unit keeps its state' "$([[ $last_status == 0 && $before == "$after" && $(grep -F 'nvidia-suspend.service|0|enabled' <<<"$after" >/dev/null; echo $?) == 0 ]] && echo 1 || echo 0)" 'before and after states compared'
  case $prior_state in
    enabled | enabled-runtime) sudo systemctl enable nvidia-suspend.service >/dev/null 2>&1 || true ;;
    disabled | disabled-runtime) sudo systemctl disable nvidia-suspend.service >/dev/null 2>&1 || true ;;
    masked | masked-runtime) sudo systemctl mask nvidia-suspend.service >/dev/null 2>&1 || true ;;
    *) sudo systemctl disable nvidia-suspend.service >/dev/null 2>&1 || true ;;
  esac
}

test_foreign_owned_file() {
  local saved=$test_root/owned-original.conf foreign=$test_root/owned-foreign.conf before_hash after_hash
  [[ -f $owned ]] || { record 'R16 owned path exists for preservation test' 0 "$owned missing"; return; }
  sudo cp -a "$owned" "$saved"
  cat >"$foreign" <<'EOF'
# Test fixture: a user-owned file at the path Gooarchy normally owns.
MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
EOF
  sudo cp "$foreign" "$owned"
  before_hash=$(sha256sum "$owned" | awk '{print $1}')
  run_nvidia_step r16-foreign-owned-file "$supported" -
  after_hash=$(sha256sum "$owned" | awk '{print $1}')
  record 'R16 foreign file at owned path remains unchanged and reported' "$([[ $last_status == 0 && $before_hash == "$after_hash" && $(grep -c 'left /etc/mkinitcpio.conf.d/gooarchy-nvidia.conf unchanged' "$test_root/r16-foreign-owned-file.log") -eq 1 ]] && echo 1 || echo 0)" "$owned"
  sudo mv "$saved" "$owned"
}

test_custom_preset() {
  local preset=/etc/mkinitcpio.d/linux.preset saved=$test_root/linux.preset.saved test_copy=$test_root/linux.preset.custom
  local before_images after_images before_etc before_packages preset_hash config_hash hook_seen=0 report_seen=0 rerun_report_seen=0
  local image image_ok=1 module_version modules status
  if [[ ! -f $preset ]]; then record 'R11 custom preset case available' 0 "$preset missing"; return; fi
  if ! grep -Eq '^[[:space:]]*MODULES[[:space:]]*=[[:space:]]*\(\)[[:space:]]*$' /etc/mkinitcpio.conf; then
    record 'R11 empty-MODULES config fixture is available' 0 '/etc/mkinitcpio.conf must be the fresh VM empty-MODULES default'
    return
  fi
  sudo cp -a "$preset" "$saved"
  sudo cp -a "$preset" "$test_copy"
  printf '\nALL_config="/etc/mkinitcpio.conf"\n' | sudo tee -a "$test_copy" >/dev/null
  sudo cp "$test_copy" "$preset"
  preset_images "$preset" || { sudo mv "$saved" "$preset"; record 'R11 preset paths resolve' 0 'could not parse preset'; return; }
  preset_hash=$(sha256sum "$preset" | awk '{print $1}')
  config_hash=$(sha256sum /etc/mkinitcpio.conf | awk '{print $1}')
  before_etc=$(tree_hash /etc)
  before_packages=$(package_manifest)
  run_nvidia_step r11-custom-config-pacman-hook "$supported" pacman:force-transaction
  status=$last_status
  grep -Fq "Building image from preset: $preset" "$test_root/r11-custom-config-pacman-hook.log" && hook_seen=1
  grep -Fq 'linux.preset reads /etc/mkinitcpio.conf directly' "$test_root/r11-custom-config-pacman-hook.log" && report_seen=1
  module_version=$(module_version_from_package "$(pacman -Q nvidia-utils | awk '{print $2}')")
  for image in "${NV_TEST_IMAGES[@]}"; do
    lsinitcpio "$image" >/dev/null 2>&1 || image_ok=0
    check_image_versions_and_firmware "$image" "$module_version" || image_ok=0
    modules=$(image_modules "$image" 2>/dev/null || true)
    [[ -z $modules ]] || image_ok=0
  done
  record 'R11/R15 Arch package hook may regenerate the custom preset with consistent images' \
    "$([[ $status == 0 && $hook_seen == 1 && $image_ok == 1 ]] && echo 1 || echo 0)" \
    "$preset; nvidia-utils $module_version; all images listable with no NVIDIA modules"
  record 'R11 package hook preserves the named preset and config bytes' \
    "$([[ $preset_hash == "$(sha256sum "$preset" | awk '{print $1}')" && $config_hash == "$(sha256sum /etc/mkinitcpio.conf | awk '{print $1}')" && $before_etc == "$(tree_hash /etc)" ]] && echo 1 || echo 0)" \
    "$preset and /etc/mkinitcpio.conf"
  record 'R11 package-hook run reports missing early KMS for the named preset' \
    "$([[ $status == 0 && $report_seen == 1 ]] && echo 1 || echo 0)" "$preset"

  before_images=$(sha256sum "${NV_TEST_IMAGES[@]}")
  before_etc=$(tree_hash /etc)
  before_packages=$(package_manifest)
  run_nvidia_step r11-custom-config "$supported" -
  after_images=$(sha256sum "${NV_TEST_IMAGES[@]}")
  record 'R11 bypassed drop-in is left alone, reported, and unchanged on rerun' \
    "$([[ $last_status == 0 && $before_images == "$after_images" && $before_etc == "$(tree_hash /etc)" && $before_packages == "$(package_manifest)" && $preset_hash == "$(sha256sum "$preset" | awk '{print $1}')" && $config_hash == "$(sha256sum /etc/mkinitcpio.conf | awk '{print $1}')" ]] && echo 1 || echo 0)" \
    "$preset; no package transaction on rerun"
  grep -Fq 'linux.preset reads /etc/mkinitcpio.conf directly' "$test_root/r11-custom-config.log" && rerun_report_seen=1
  record 'R11 rerun reports missing early KMS for the named preset' \
    "$([[ $last_status == 0 && $rerun_report_seen == 1 ]] && echo 1 || echo 0)" "$preset"
  cmp -s "$test_copy" "$preset" || record 'R11 preset bytes are preserved' 0 "$preset changed during the step"
  sudo mv "$saved" "$preset"
  run_nvidia_step r11-restore-default "$supported" -
  record 'R11 default preset early KMS restored' "$([[ $last_status == 0 ]] && echo 1 || echo 0)" 'test preset removed and images regenerated'
}

test_r17_header_repair() {
  local kernel pkg_version header_version module_version module image image_ok=1 status
  local -a required=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
  if ! pacman -Si linux-lts >/dev/null 2>&1; then
    record 'R17 exact-version linux-lts header repair available' 0 'Arch repositories do not provide linux-lts'
    return
  fi
  if [[ -z $(kernel_for_pkgbase linux-lts 2>/dev/null || true) ]]; then
    sudo pacman -S --noconfirm --needed linux-lts || { record 'R17 linux-lts kernel installed without headers' 0 'pacman failed'; return; }
  fi
  if pacman -Q linux-lts-headers >/dev/null 2>&1; then
    sudo pacman -Rdd --noconfirm linux-lts-headers
  fi
  kernel=$(kernel_for_pkgbase linux-lts 2>/dev/null || true)
  if [[ -z $kernel ]]; then record 'R17 linux-lts kernel available without headers' 0 'module tree missing'; return; fi
  run_nvidia_step r17-repair-linux-lts-headers "$supported" -
  status=$last_status
  pkg_version=$(pacman -Q linux-lts | awk '{print $2}')
  header_version=$(pacman -Q linux-lts-headers 2>/dev/null | awk '{print $2}' || true)
  module_version=$(module_version_from_package "$(pacman -Q nvidia-utils | awk '{print $2}')")
  record 'R17 installs linux-lts headers at the exact kernel package version' "$([[ $status == 0 && -n $kernel && $header_version == "$pkg_version" ]] && echo 1 || echo 0)" "linux-lts $pkg_version; headers $header_version"
  for module in "${required[@]}"; do
    [[ $(modinfo -k "$kernel" -F version "$module" 2>/dev/null || true) == "$module_version" ]] || image_ok=0
  done
  image_set_for_kernel linux-lts || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    local modules
    modules=$(image_modules "$image" 2>/dev/null || true)
    for module in "${required[@]}"; do grep -Fxq "$module" <<<"$modules" || image_ok=0; done
    check_image_versions_and_firmware "$image" "$module_version" || image_ok=0
  done
  record 'R17 repairs the newly added kernel through DKMS and early KMS' "$image_ok" "$kernel; nvidia-utils $module_version"

  local before_packages before_etc before_boot
  before_packages=$(package_manifest)
  before_etc=$(tree_hash /etc)
  before_boot=$(tree_hash /boot)
  run_nvidia_step r17-linux-lts-no-op "$supported" -
  record 'R17 second run after header repair is a no-op' "$([[ $last_status == 0 && $before_packages == "$(package_manifest)" && $before_etc == "$(tree_hash /etc)" && $before_boot == "$(tree_hash /boot)" ]] && echo 1 || echo 0)" "$kernel"
}

test_r15_linux_gooarchy_dkms_failure() {
  local kernel linux_kernel build_link_path package_version module_version repo_version status
  local image image_ok=1 gooarchy_modules_ok=1 other_kernels_ok=1 retry_ok=1 dir other_kernel pkgbase module file version
  local headers_version kernel_package_version kernel_covered
  local linux_covered=1
  local -a required=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)

  kernel=$(kernel_for_pkgbase linux-gooarchy 2>/dev/null || true)
  linux_kernel=$(kernel_for_pkgbase linux 2>/dev/null || true)
  if [[ -z $kernel || -z $linux_kernel ]]; then
    record 'R15 linux-gooarchy-only DKMS failure fixture is available' 0 \
      'the integrated linux-gooarchy and linux kernels are both required'
    return
  fi
  if [[ $(pacman -Q linux-gooarchy-headers 2>/dev/null | awk '{print $2}' || true) != \
        "$(pacman -Q linux-gooarchy 2>/dev/null | awk '{print $2}' || true)" ]]; then
    record 'R15 linux-gooarchy matching headers are installed for the DKMS failure fixture' 0 \
      'linux-gooarchy-headers does not match linux-gooarchy'
    return
  fi
  build_link_path=/usr/lib/modules/$kernel/build
  if [[ ! -e $build_link_path && ! -L $build_link_path ]]; then
    record 'R15 linux-gooarchy DKMS build link exists before failure injection' 0 "$build_link_path is missing"
    return
  fi
  if [[ -e $owned ]] && ! grep -Fxq \
      '# Gooarchy NVIDIA early KMS modules; managed by the Gooarchy installer.' "$owned"; then
    record 'R15 linux-gooarchy fixture can preserve the pre-existing owned-path state' 0 \
      "$owned contains user-owned content"
    return
  fi

  package_version=$(pacman -Q nvidia-utils | awk '{print $2}')
  module_version=$(module_version_from_package "$package_version")
  repo_version=$(pacman -Si extra/nvidia-utils | awk -F ': ' '$1 == "Version" {print $2; exit}')
  for module in "${required[@]}"; do
    [[ $(modinfo -k "$linux_kernel" -F version "$module" 2>/dev/null || true) == "$module_version" ]] ||
      linux_covered=0
  done
  image_set_for_kernel linux || linux_covered=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$module_version" "${required[@]}" || linux_covered=0
  done
  record 'R15 linux begins covered before the linux-gooarchy DKMS failure' "$linux_covered" \
    "linux $linux_kernel; module version $module_version"
  if ((linux_covered == 0)); then return; fi

  : >"$test_root/driver-recovery-needed"
  printf '%s' "$build_link_path" >"$test_root/gooarchy-build-link-path"
  if ! sudo mv "$build_link_path" "$test_root/gooarchy-build-link.saved"; then
    record 'R15 linux-gooarchy build link is held for the transaction failure' 0 'could not hold build link'
    return 1
  fi
  if ! sudo pacman -Rdd --noconfirm nvidia-open-dkms nvidia-utils; then
    record 'R15 driver packages can be removed for a fresh transaction' 0 'pacman removal failed'
    if ! sudo mv "$test_root/gooarchy-build-link.saved" "$build_link_path" 2>/dev/null; then
      record 'R15 linux-gooarchy build link is restored after package removal refusal' 0 \
        "$build_link_path remains missing"
      return 1
    fi
    rm -f "$test_root/gooarchy-build-link-path"
    restore_r15a_current_state || return 1
    return
  fi
  for dir in /usr/lib/modules/*; do
    [[ -f $dir/pkgbase ]] || continue
    pkgbase=$(<"$dir/pkgbase")
    if ! sudo mkinitcpio -p "$pkgbase" >"$test_root/r15-fresh-image-${dir##*/}.log" 2>&1; then
      record 'R15 fresh transaction starts with listable fallback images' 0 "mkinitcpio failed for ${dir##*/}"
      if ! sudo mv "$test_root/gooarchy-build-link.saved" "$build_link_path" 2>/dev/null; then
        record 'R15 linux-gooarchy build link is restored after image preparation failure' 0 \
          "$build_link_path remains missing"
        return 1
      fi
      rm -f "$test_root/gooarchy-build-link-path"
      restore_r15a_current_state || return 1
      return
    fi
  done

  run_nvidia_step r15-linux-gooarchy-dkms-failure "$supported" "dkms:$kernel"
  status=$last_status
  package_version=$(pacman -Q nvidia-utils 2>/dev/null | awk '{print $2}' || true)
  module_version=$(module_version_from_package "$package_version")
  repo_version=$(pacman -Si extra/nvidia-utils 2>/dev/null | awk -F ': ' '$1 == "Version" {print $2; exit}' || true)
  image_set_for_kernel linux-gooarchy || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    lsinitcpio "$image" >/dev/null 2>&1 || image_ok=0
    check_image_versions_and_firmware "$image" "$module_version" || image_ok=0
    [[ -z $(image_modules "$image" 2>/dev/null || true) ]] || image_ok=0
  done
  while IFS= read -r -d '' file; do
    version=$(modinfo -F version "$file" 2>/dev/null || true)
    [[ $version == "$module_version" ]] || gooarchy_modules_ok=0
  done < <(find "/usr/lib/modules/$kernel" -type f -name 'nvidia*.ko*' -print0)
  if [[ $status == 0 && -n $module_version && $package_version == "$repo_version" &&
        $(pacman -Qe nvidia-open-dkms >/dev/null 2>&1; echo $?) == 0 &&
        -z $(modinfo -k "$kernel" -F version nvidia_drm 2>/dev/null || true) &&
        $image_ok == 1 && $gooarchy_modules_ok == 1 &&
        $(grep -Fq "linux-gooarchy kernel $kernel is uncovered" "$test_root/r15-linux-gooarchy-dkms-failure.log"; echo $?) == 0 &&
        $(grep -Fq "/var/lib/dkms/nvidia/$module_version/build/make.log" "$test_root/r15-linux-gooarchy-dkms-failure.log"; echo $?) == 0 ]]; then
    record 'R15 linux-gooarchy DKMS failure is reported while the installer completes' 1 \
      "linux-gooarchy $kernel; nvidia-utils $package_version; DKMS make.log named"
  else
    record 'R15 linux-gooarchy DKMS failure is reported while the installer completes' 0 \
      "status $status; kernel $kernel; nvidia-utils ${package_version:-missing}; repo $repo_version"
  fi

  linux_covered=1
  for module in "${required[@]}"; do
    [[ $(modinfo -k "$linux_kernel" -F version "$module" 2>/dev/null || true) == "$module_version" ]] ||
      linux_covered=0
  done
  image_set_for_kernel linux || linux_covered=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$module_version" "${required[@]}" || linux_covered=0
  done
  record 'R15 linux remains covered with current early-KMS images' "$linux_covered" \
    "linux $linux_kernel; module version $module_version"

  for dir in /usr/lib/modules/*; do
    [[ -f $dir/pkgbase ]] || continue
    other_kernel=${dir##*/}
    [[ $other_kernel == "$kernel" ]] && continue
    pkgbase=$(<"$dir/pkgbase")
    while IFS= read -r -d '' file; do
      version=$(modinfo -F version "$file" 2>/dev/null || true)
      [[ $version == "$module_version" ]] || other_kernels_ok=0
    done < <(find "$dir" -type f -name 'nvidia*.ko*' -print0)
    headers_version=$(pacman -Q "$pkgbase-headers" 2>/dev/null | awk '{print $2}' || true)
    kernel_package_version=$(pacman -Q "$pkgbase" 2>/dev/null | awk '{print $2}' || true)
    kernel_covered=0
    if [[ -n $headers_version && $headers_version == "$kernel_package_version" ]]; then
      kernel_covered=1
      for module in "${required[@]}"; do
        [[ $(modinfo -k "$other_kernel" -F version "$module" 2>/dev/null || true) == "$module_version" ]] ||
          other_kernels_ok=0
      done
    fi
    image_set_for_kernel "$pkgbase" || { other_kernels_ok=0; continue; }
    for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
      lsinitcpio "$image" >/dev/null 2>&1 || other_kernels_ok=0
      check_image_versions_and_firmware "$image" "$module_version" || other_kernels_ok=0
      if ((kernel_covered)); then
        image_has_modules_at_version "$image" "$module_version" "${required[@]}" || other_kernels_ok=0
      else
        [[ -z $(image_modules "$image" 2>/dev/null || true) ]] || other_kernels_ok=0
      fi
    done
  done
  record 'R15 other kernels keep consistent, listable images after the isolated DKMS failure' \
    "$other_kernels_ok" "linux-gooarchy $kernel is the injected build failure"
  record 'R15 linux-gooarchy fallback images stay consistent and listable' "$image_ok" \
    "all ${#NV_TEST_KERNEL_IMAGES[@]} linux-gooarchy images contain no NVIDIA modules"
  hold_r15_failure_row linux-gooarchy-dkms

  if sudo mv "$test_root/gooarchy-build-link.saved" "$build_link_path"; then
    rm -f "$test_root/gooarchy-build-link-path"
  else
    record 'R15 linux-gooarchy DKMS build link is restored' 0 "$build_link_path remains missing"
    return
  fi
  run_nvidia_step r17-linux-gooarchy-dkms-retry "$supported" -
  status=$last_status
  for module in "${required[@]}"; do
    [[ $(modinfo -k "$kernel" -F version "$module" 2>/dev/null || true) == "$module_version" ]] ||
      retry_ok=0
  done
  image_set_for_kernel linux-gooarchy || retry_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$module_version" "${required[@]}" || retry_ok=0
  done
  record 'R17 linux-gooarchy rerun retries the failed DKMS build and restores early KMS' \
    "$([[ $status == 0 && $retry_ok == 1 ]] && echo 1 || echo 0)" \
    "linux-gooarchy $kernel; module version $module_version"
  if [[ $status == 0 && $retry_ok == 1 ]]; then
    rm -f "$test_root/driver-recovery-needed"
  fi
}

test_r15_interrupted_after_commit() {
  local module_dir kernel pkgbase package_version module_version repo_utils repo_dkms status=0 image modules module
  local images_ok=1 modules_ok=1 report_ok=0 image_hashes_ok=1
  local image_hashes_before=$test_root/r15-after-commit-images-before.sha256
  local image_hashes_after=$test_root/r15-after-commit-images-after.sha256
  local -a required=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
  if [[ -e $owned ]] && ! grep -Fxq \
      '# Gooarchy NVIDIA early KMS modules; managed by the Gooarchy installer.' "$owned"; then
    record 'R15 interruption fixture can preserve the existing owned path' 0 "$owned is user-owned"
    return
  fi
  : >"$test_root/driver-recovery-needed"
  if [[ -e $owned ]]; then sudo cp -a "$owned" "$test_root/r15-interrupted-owned.saved"; fi
  sudo rm -f "$owned" "$user_config" "$dynamic_modules"
  if ! sudo pacman -Rdd --noconfirm nvidia-open-dkms nvidia-utils; then
    record 'R15 interruption fixture removes the driver before the transaction' 0 'pacman removal failed'
    return
  fi
  for module_dir in /usr/lib/modules/*; do
    [[ -f $module_dir/pkgbase ]] || continue
    pkgbase=$(<"$module_dir/pkgbase")
    sudo mkinitcpio -p "$pkgbase" >/dev/null 2>&1 || status=1
  done
  for module_dir in /usr/lib/modules/*; do
    [[ -f $module_dir/pkgbase ]] || continue
    pkgbase=$(<"$module_dir/pkgbase")
    image_set_for_kernel "$pkgbase" || { images_ok=0; continue; }
    for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
      lsinitcpio "$image" >/dev/null 2>&1 || images_ok=0
      modules=$(image_modules "$image" 2>/dev/null || true)
      [[ -z $modules ]] || images_ok=0
    done
  done
  record 'R15 interruption fixture starts from complete fallback images' \
    "$([[ $status == 0 && $images_ok == 1 ]] && echo 1 || echo 0)" \
    'driver packages removed; every kernel image listable without NVIDIA modules'
  if ((status != 0 || images_ok == 0)); then return; fi
  if ! capture_all_kernel_image_hashes >"$image_hashes_before"; then
    record 'R15 after-commit matrix captures pre-transaction image hashes' 0 \
      'could not hash every image before the package transaction'
    return
  fi

  run_nvidia_step r15-interrupted-after-commit "$supported" interrupt:after-commit
  status=$last_status
  if ! capture_all_kernel_image_hashes >"$image_hashes_after"; then image_hashes_ok=0; fi
  if ! cmp -s "$image_hashes_before" "$image_hashes_after"; then
    diff -u "$image_hashes_before" "$image_hashes_after" \
      >"$test_root/r15-after-commit-image-hash-diff.txt" || true
  fi
  record 'R15 existing after-commit matrix run records image hashes around pacman return' \
    "$image_hashes_ok" \
    "before=$image_hashes_before after=$image_hashes_after; any difference is recorded for hook attribution"
  package_version=$(pacman -Q nvidia-utils 2>/dev/null | awk '{print $2}' || true)
  module_version=$(module_version_from_package "$package_version")
  repo_utils=$(pacman -Si extra/nvidia-utils 2>/dev/null | awk -F ': ' '$1 == "Version" {print $2; exit}' || true)
  repo_dkms=$(pacman -Si extra/nvidia-open-dkms 2>/dev/null | awk -F ': ' '$1 == "Version" {print $2; exit}' || true)
  grep -Fq 'interrupted the NVIDIA step after the package transaction committed' \
    "$test_root/r15-interrupted-after-commit.log" && report_ok=1
  [[ $package_version == "$repo_utils" && $repo_utils == "$repo_dkms" &&
     $(pacman -Qe nvidia-open-dkms >/dev/null 2>&1; echo $?) == 0 && ! -e $owned ]] || modules_ok=0
  for module_dir in /usr/lib/modules/*; do
    [[ -f $module_dir/pkgbase ]] || continue
    kernel=${module_dir##*/}
    pkgbase=$(<"$module_dir/pkgbase")
    for module in "${required[@]}"; do
      [[ $(modinfo -k "$kernel" -F version "$module" 2>/dev/null || true) == "$module_version" ]] || modules_ok=0
    done
    image_set_for_kernel "$pkgbase" || { images_ok=0; continue; }
    for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
      lsinitcpio "$image" >/dev/null 2>&1 || images_ok=0
      check_image_versions_and_firmware "$image" "$module_version" || images_ok=0
      modules=$(image_modules "$image" 2>/dev/null || true)
      [[ -z $modules ]] || images_ok=0
    done
  done
  record 'R15 interruption after commit leaves every kernel covered with listable fallback images' \
    "$([[ $status != 0 && $report_ok == 1 && $modules_ok == 1 && $images_ok == 1 && $image_hashes_ok == 1 ]] && echo 1 || echo 0)" \
    "nvidia-utils $package_version; transaction committed; owned early-KMS file and step image setup not reached"
  hold_r15_failure_row interrupt-after-commit

  if [[ -f $test_root/r15-interrupted-owned.saved ]]; then
    sudo mv -f "$test_root/r15-interrupted-owned.saved" "$owned"
  fi
  if restore_r15a_current_state; then
    record 'R17 interrupted transaction fixture is restored to current early KMS' 1 'current packages, DKMS modules, and images restored'
  else
    record 'R17 interrupted transaction fixture is restored to current early KMS' 0 'cleanup recovery failed'
  fi
}

capture_all_kernel_image_hashes() {
  local module_dir pkgbase
  for module_dir in /usr/lib/modules/*; do
    [[ -f $module_dir/pkgbase ]] || continue
    pkgbase=$(<"$module_dir/pkgbase")
    kernel_image_hashes "$pkgbase" || return 1
  done
}

test_r15_pacman_stale_lock() {
  local lock=/var/lib/pacman/db.lck packages_before database_before etc_before
  local modules_before boot_before lock_hash lock_identity status lock_ok=1 reports_before
  local lock_marker=$test_root/r15-stale-lock-owned
  local image_hashes_before=$test_root/r15-stale-lock-images-before.sha256
  local image_hashes_after=$test_root/r15-stale-lock-images-after.sha256

  if [[ -e $lock || -L $lock ]]; then
    record 'R15 stale-lock fixture starts without an existing pacman lock' 0 \
      'pre-existing db.lck left untouched'
    return
  fi
  if ! command -v pgrep >/dev/null 2>&1 || pgrep -x pacman >/dev/null 2>&1; then
    record 'R15 stale-lock fixture has no active pacman process' 0 \
      'could not establish that the lock would be stale'
    return
  fi
  if ! capture_all_kernel_image_hashes >"$image_hashes_before"; then
    record 'R15 stale-lock fixture can hash every kernel image' 0 'baseline image inventory failed'
    return
  fi
  local lock_contents="gooarchy-nvidia-stale-lock $test_stamp"
  printf '%s\n' "$lock_contents" |
    sudo tee "$lock" >/dev/null || {
      record 'R15 stale-lock fixture creates its own db.lck' 0 'could not create the lock'
      return
    }
  lock_hash=$(printf '%s\n' "$lock_contents" | sha256sum | awk '{print $1}') || return
  lock_identity=$(sudo stat -c '%d:%i' -- "$lock") || return
  printf '%s\t%s\n' "$lock_hash" "$lock_identity" >"$lock_marker"

  packages_before=$(package_manifest)
  database_before=$(tree_hash /var/lib/pacman/local)
  etc_before=$(tree_hash /etc)
  modules_before=$(tree_hash /usr/lib/modules)
  boot_before=$(tree_hash /boot)
  reports_before=$(report_count)

  run_nvidia_step r15-pacman-stale-lock "$supported" -
  status=$last_status

  if ! capture_all_kernel_image_hashes >"$image_hashes_after"; then lock_ok=0; fi
  [[ $status != 0 && -e $lock && ! -L $lock &&
     $(sha256sum -- "$lock" | awk '{print $1}') == "$lock_hash" &&
     $(sudo stat -c '%d:%i' -- "$lock") == "$lock_identity" &&
     $packages_before == "$(package_manifest)" &&
     $database_before == "$(tree_hash /var/lib/pacman/local)" &&
     $etc_before == "$(tree_hash /etc)" &&
     $modules_before == "$(tree_hash /usr/lib/modules)" &&
     $boot_before == "$(tree_hash /boot)" &&
     $reports_before -lt $(report_count) ]] || lock_ok=0
  grep -Fq 'stale db.lck' "$test_root/r15-pacman-stale-lock.log" || lock_ok=0
  cmp -s "$image_hashes_before" "$image_hashes_after" || lock_ok=0
  record 'R15 stale-lock rerun reports the lock and preserves package, configuration, module and image state' \
    "$lock_ok" \
    "status $status; lock SHA256 $lock_hash retained; per-image SHA256 lists: $image_hashes_before and $image_hashes_after"
}

test_user_partial_kernels() {
  local kernel pkgbase scenario modules remove image config_hash source_hash preset base status expected
  local expected_report_file error_lines step_log report_ok
  local -a removals=()
  kernel=$(kernel_for_pkgbase linux-lts 2>/dev/null || true)
  if [[ -z $kernel ]]; then
    sudo pacman -S --noconfirm --needed linux-lts linux-lts-headers || { record 'R10 linux-lts test kernel installed' 0 'pacman failed'; return; }
    kernel=$(kernel_for_pkgbase linux-lts 2>/dev/null || true)
  fi
  if [[ -z $kernel ]]; then record 'R10 user partial kernel available' 0 'linux-lts module tree not found'; return; fi
  pkgbase=linux-lts
  base=linux-lts
  for scenario in full-list two-module dependency missing-dependency optional-missing-dependency dynamic-two-module dynamic-missing-dependency sourced-modules; do
    case $scenario in
      full-list)
        modules='nvidia nvidia_modeset nvidia_uvm nvidia_drm'
        removals=(nvidia_uvm nvidia_drm)
        ;;
      two-module)
        modules='nvidia_modeset'
        removals=(nvidia_uvm nvidia_drm)
        ;;
      dependency)
        modules='nvidia_modeset'
        removals=(nvidia_uvm nvidia_drm)
        ;;
      missing-dependency)
        modules='nvidia_modeset'
        removals=(nvidia nvidia_uvm nvidia_drm)
        ;;
      optional-missing-dependency)
        modules='nvidia_modeset?'
        removals=(nvidia nvidia_uvm nvidia_drm)
        ;;
      dynamic-two-module)
        modules='nvidia_modeset'
        removals=(nvidia_uvm nvidia_drm)
        ;;
      dynamic-missing-dependency)
        modules='nvidia_modeset'
        removals=(nvidia nvidia_uvm nvidia_drm)
        ;;
      sourced-modules)
        modules='nvidia_modeset'
        removals=(nvidia_uvm nvidia_drm)
        ;;
    esac
    if [[ $scenario == dynamic-two-module || $scenario == dynamic-missing-dependency ]]; then
      printf '%s\n' "$modules" | sudo tee "$dynamic_modules" >/dev/null
      printf 'MODULES=($(< %s))\n' "$dynamic_modules" >"$test_root/user-modules.conf"
    elif [[ $scenario == sourced-modules ]]; then
      printf 'MODULES=(%s)\n' "$modules" | sudo tee "$dynamic_modules" >/dev/null
      printf 'source %s\n' "$dynamic_modules" >"$test_root/user-modules.conf"
    else
      printf 'MODULES=(%s)\n' "$modules" >"$test_root/user-modules.conf"
    fi
    sudo cp "$test_root/user-modules.conf" "$user_config"
    config_hash=$(sha256sum "$user_config" | awk '{print $1}')
    source_hash=
    expected_report_file=$user_config
    if [[ $scenario == sourced-modules ]]; then
      source_hash=$(sha256sum "$dynamic_modules" | awk '{print $1}')
      expected_report_file=$dynamic_modules
    fi
    printf '%s' "$kernel" >"$test_root/partial-kernel-path"
    remove_kernel_modules "$kernel" "${removals[@]}"
    if ! image_set_for_kernel "$pkgbase"; then
      record "R10 $scenario preset images resolve" 0 'no preset'
      sudo rm -f "$user_config"
      if restore_kernel_modules "$kernel"; then rm -f "$test_root/partial-kernel-path"; fi
      continue
    fi
    image=${NV_TEST_KERNEL_IMAGES[0]}
    sudo rm -f "$image"
    run_nvidia_step "r10-user-partial-$scenario" "$supported" "dkms:$kernel"
    status=$last_status
    step_log=$test_root/r10-user-partial-$scenario.log
    report_ok=1
    if [[ $status != 0 ]] ||
       ! grep -Fq "$kernel is an uncovered user partial kernel" "$step_log" ||
       ! grep -Fq "$expected_report_file" "$step_log" ||
       ! grep -Fq 'does not promise this kernel reaches the desktop' "$step_log"; then
      report_ok=0
    fi
    record "R10/R16 $scenario leaves user partial kernel and succeeds" "$report_ok" "kernel $kernel; source $expected_report_file"
    if [[ $scenario == dynamic-missing-dependency ]]; then
      error_lines=$(grep -E 'ERROR:' "$step_log" | sed -E 's/^.*ERROR: /ERROR: /' | sort -u || true)
      if [[ $status == 0 && $error_lines == "ERROR: module not found: 'nvidia'" ]]; then
        record 'R9/R10 dynamic MODULES accepts only the missing nvidia dependency' 1 "$error_lines"
      else
        record 'R9/R10 dynamic MODULES accepts only the missing nvidia dependency' 0 "$error_lines"
      fi
    fi
    record "R10/R16 $scenario preserves user config bytes" "$([[ $config_hash == "$(sha256sum "$user_config" | awk '{print $1}')" && ( -z $source_hash || $source_hash == "$(sha256sum "$dynamic_modules" | awk '{print $1}')" ) ]] && echo 1 || echo 0)" "$user_config${source_hash:+; $dynamic_modules}"
    if image_set_for_kernel "$pkgbase"; then
      local image_ok modules_in_image module_version
      image_ok=1
      module_version=$(module_version_from_package "$(pacman -Q nvidia-utils | awk '{print $2}')")
      for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
        lsinitcpio "$image" >/dev/null 2>&1 || image_ok=0
        check_image_versions_and_firmware "$image" "$module_version" || image_ok=0
      done
      record "R15 $scenario partial images remain consistent and listable" "$image_ok" "$module_version"
      record "R10 $scenario owned file contributes nothing" "$(compare_with_owned_file_removed "$kernel" "$base" && echo 1 || echo 0)" 'module set and missing-module errors match without the owned file'
    else
      record "R15 $scenario partial images remain consistent and listable" 0 'no preset images after step'
    fi
    sudo rm -f "$user_config"
    sudo rm -f "$dynamic_modules"
    if restore_kernel_modules "$kernel"; then rm -f "$test_root/partial-kernel-path"; fi
    run_nvidia_step "r10-restore-$scenario" "$supported" -
    record "R17 $scenario repair restores covered kernel" "$([[ $last_status == 0 ]] && echo 1 || echo 0)" "$kernel"
  done
}

test_pacman_hook_failure_with_partial_kernel() {
  local linux_kernel lts_kernel build_link_path module_version config_hash
  local linux_images_before linux_images_after lts_images_before lts_images_after status image image_ok=1 restore_status=0
  local module modules step_log hook_report_ok partial_report_ok current_version linux_preset
  local linux_preset_hash r11_config_hash r11_report_ok=0 r11_image_ok=1 r11_files_unchanged=0
  local -a required_partial=(nvidia nvidia_modeset)
  linux_kernel=$(kernel_for_pkgbase linux 2>/dev/null || true)
  lts_kernel=$(kernel_for_pkgbase linux-lts 2>/dev/null || true)
  if [[ -z $linux_kernel || -z $lts_kernel ]]; then
    record 'R15 package-hook failure with another user-partial kernel is available' 0 'linux and linux-lts must both be installed'
    return
  fi
  build_link_path=/usr/lib/modules/$lts_kernel/build
  if [[ ! -e $build_link_path && ! -L $build_link_path ]]; then
    record 'R15 user-partial kernel can preserve its DKMS state during a package transaction' 0 "$build_link_path missing"
    return
  fi

  printf 'MODULES=(nvidia_modeset)\n' >"$test_root/r15-hook-user-modules.conf"
  sudo cp "$test_root/r15-hook-user-modules.conf" "$user_config"
  config_hash=$(sha256sum "$user_config" | awk '{print $1}')
  printf '%s' "$lts_kernel" >"$test_root/partial-kernel-path"
  remove_kernel_modules "$lts_kernel" nvidia_uvm nvidia_drm
  image_set_for_kernel linux-lts || image_ok=0
  sudo mkinitcpio -p linux-lts >"$test_root/r15-hook-partial-prepare.log" 2>&1 || image_ok=0
  current_version=$(module_version_from_package "$(pacman -Q nvidia-utils | awk '{print $2}')")
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$current_version" "${required_partial[@]}" || image_ok=0
    modules=$(image_modules "$image" 2>/dev/null || true)
    for module in nvidia_uvm nvidia_drm; do
      grep -Fxq "$module" <<<"$modules" && image_ok=0
    done
  done
  if ((image_ok == 0)); then
    record 'R15 user-partial kernel fixture is complete and version-consistent' 0 'linux-lts images did not preserve nvidia and nvidia_modeset only'
    sudo rm -f "$user_config"
    if restore_kernel_modules "$lts_kernel"; then rm -f "$test_root/partial-kernel-path"; fi
    return
  fi
  linux_preset=/etc/mkinitcpio.d/linux.preset
  if [[ -e $test_root/linux.preset.saved ]] ||
     ! grep -Eq '^[[:space:]]*MODULES[[:space:]]*=[[:space:]]*\(\)[[:space:]]*$' /etc/mkinitcpio.conf; then
    record 'R11/R15 custom-preset hook fixture is available' 0 'preset backup exists or the fresh VM config is not MODULES=()'
    sudo rm -f "$user_config"
    if restore_kernel_modules "$lts_kernel"; then rm -f "$test_root/partial-kernel-path"; fi
    return
  fi
  sudo cp -a "$linux_preset" "$test_root/linux.preset.saved"
  sudo cp /etc/mkinitcpio.conf "$r11_config"
  r11_config_hash=$(sha256sum "$r11_config" | awk '{print $1}')
  printf '\nALL_config="%s"\n' "$r11_config" >"$test_root/linux.preset.r11"
  sudo cp "$test_root/linux.preset.r11" "$linux_preset"
  if ! sudo mkinitcpio -p linux >"$test_root/r15-hook-r11-prepare.log" 2>&1; then
    record 'R11/R15 custom preset image fixture can be prepared' 0 'mkinitcpio failed using the named config'
    sudo mv "$test_root/linux.preset.saved" "$linux_preset"
    sudo rm -f "$r11_config" "$user_config"
    if restore_kernel_modules "$lts_kernel"; then rm -f "$test_root/partial-kernel-path"; fi
    return
  fi
  image_set_for_kernel linux || r11_image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    lsinitcpio "$image" >/dev/null 2>&1 || r11_image_ok=0
    check_image_versions_and_firmware "$image" "$(module_version_from_package "$(pacman -Q nvidia-utils | awk '{print $2}')")" || r11_image_ok=0
    modules=$(image_modules "$image" 2>/dev/null || true)
    [[ -z $modules ]] || r11_image_ok=0
  done
  if ((r11_image_ok == 0)); then
    record 'R11/R15 custom preset image fixture is consistent and listable' 0 'linux image contains NVIDIA modules or failed inspection'
    sudo mv "$test_root/linux.preset.saved" "$linux_preset"
    sudo rm -f "$r11_config" "$user_config"
    if restore_kernel_modules "$lts_kernel"; then rm -f "$test_root/partial-kernel-path"; fi
    return
  fi
  linux_preset_hash=$(sha256sum "$linux_preset" | awk '{print $1}')
  module_version=$current_version
  linux_images_before=$(kernel_image_hashes linux 2>/dev/null || true)
  lts_images_before=$(kernel_image_hashes linux-lts 2>/dev/null || true)
  printf '%s' "$build_link_path" >"$test_root/linux-lts-build-link-path"
  sudo mv "$build_link_path" "$test_root/linux-lts-build-link.saved"

  run_nvidia_step r15-package-hook-linux-partial-lts "$supported" \
    "pacman:force-transaction,pacman-hook:$linux_kernel,dkms:$lts_kernel"
  status=$last_status
  linux_images_after=$(kernel_image_hashes linux 2>/dev/null || true)
  lts_images_after=$(kernel_image_hashes linux-lts 2>/dev/null || true)
  image_set_for_kernel linux-lts || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$module_version" "${required_partial[@]}" || image_ok=0
    modules=$(image_modules "$image" 2>/dev/null || true)
    for module in nvidia_uvm nvidia_drm; do
      grep -Fxq "$module" <<<"$modules" && image_ok=0
    done
  done
  if [[ $lts_images_before != "$lts_images_after" ]] &&
     ! grep -Fq "/etc/mkinitcpio.d/linux-lts.preset" "$test_root/r15-package-hook-linux-partial-lts.log"; then
    image_ok=0
  fi
  step_log=$test_root/r15-package-hook-linux-partial-lts.log
  hook_report_ok=0
  grep -Fq "post-transaction mkinitcpio hook reported an image-generation error for linux kernel $linux_kernel" "$step_log" && hook_report_ok=1
  partial_report_ok=0
  if grep -Fq "linux-lts kernel $lts_kernel" "$step_log" &&
     grep -Fq "$user_config" "$step_log" &&
     grep -Fq 'does not promise this kernel reaches the desktop' "$step_log"; then
    partial_report_ok=1
  fi
  r11_image_ok=1
  image_set_for_kernel linux || r11_image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    lsinitcpio "$image" >/dev/null 2>&1 || r11_image_ok=0
    check_image_versions_and_firmware "$image" "$module_version" || r11_image_ok=0
    modules=$(image_modules "$image" 2>/dev/null || true)
    [[ -z $modules ]] || r11_image_ok=0
  done
  if grep -Fq "linux.preset reads $r11_config directly" "$step_log"; then r11_report_ok=1; fi
  if [[ $linux_preset_hash == "$(sha256sum "$linux_preset" | awk '{print $1}')" &&
        $r11_config_hash == "$(sha256sum "$r11_config" | awk '{print $1}')" ]]; then
    r11_files_unchanged=1
  fi
  record 'R15 failed linux package hook keeps its prior images byte-identical' \
    "$([[ $status != 0 && $hook_report_ok == 1 && -n $linux_images_before && $linux_images_before == "$linux_images_after" ]] && echo 1 || echo 0)" \
    "linux $linux_kernel; hook failure reported after the transaction"
  record 'R11/R15 failed hook leaves custom preset, config, and consistent image intact' \
    "$([[ $status != 0 && $hook_report_ok == 1 && $r11_report_ok == 1 && $r11_image_ok == 1 && $r11_files_unchanged == 1 && $linux_images_before == "$linux_images_after" ]] && echo 1 || echo 0)" \
    "$linux_preset; $r11_config; hook failure remains a step failure"
  record 'R15 other user-partial kernel stays consistent and is reported with its fix' \
    "$([[ $status != 0 && $image_ok == 1 && $partial_report_ok == 1 && \
          $config_hash == "$(sha256sum "$user_config" | awk '{print $1}')" ]] && echo 1 || echo 0)" \
    "linux-lts $lts_kernel; images ${lts_images_before:+checked}; config $user_config"
  hold_r15_failure_row package-hook-linux-partial-lts

  sudo mv "$test_root/linux-lts-build-link.saved" "$build_link_path"
  sudo mv "$test_root/linux.preset.saved" "$linux_preset"
  sudo rm -f "$r11_config"
  sudo rm -f "$user_config"
  if restore_kernel_modules "$lts_kernel"; then
    restore_status=0
    rm -f "$test_root/partial-kernel-path" "$test_root/linux-lts-build-link-path" "$test_root/linux-lts-build-link.saved"
  else
    restore_status=1
  fi
  if ((restore_status == 0)); then
    run_nvidia_step r15-package-hook-partial-lts-restored "$supported" -
    record 'R17 user-partial package-hook fixture is repaired before later cases' \
      "$([[ $last_status == 0 ]] && echo 1 || echo 0)" "linux-lts $lts_kernel"
    linux_images_before=$(kernel_image_hashes linux 2>/dev/null || true)
    run_nvidia_step r15-package-hook-linux-only "$supported" \
      "pacman:force-transaction,pacman-hook:$linux_kernel"
    status=$last_status
    linux_images_after=$(kernel_image_hashes linux 2>/dev/null || true)
    hook_report_ok=0
    grep -Fq "post-transaction mkinitcpio hook reported an image-generation error for linux kernel $linux_kernel" \
      "$test_root/r15-package-hook-linux-only.log" && hook_report_ok=1
    record 'R15 linux-only package hook failure preserves its sound fallback baseline' \
      "$([[ $status != 0 && $hook_report_ok == 1 && -n $linux_images_before && $linux_images_before == "$linux_images_after" ]] && echo 1 || echo 0)" \
      "linux $linux_kernel; package hook error reported after commit"
    hold_r15_failure_row package-hook-linux-only
    run_nvidia_step r15-package-hook-linux-only-restored "$supported" -
    record 'R17 linux package-hook failure is repaired on rerun' \
      "$([[ $last_status == 0 ]] && echo 1 || echo 0)" "linux $linux_kernel"
  else
    record 'R17 user-partial package-hook fixture is restored' 0 "DKMS recovery failed for $lts_kernel; cleanup will retry"
  fi
}

test_prebuilt_replacement() {
  local before_packages before_etc before_boot status kernel build_link_path
  if ! pacman -Si nvidia-open >/dev/null 2>&1; then
    record 'R7 same-driver prebuilt package available' 0 'Arch repositories do not provide nvidia-open'
    return
  fi
  : >"$test_root/driver-recovery-needed"
  sudo pacman -Rdd --noconfirm nvidia-open-dkms
  sudo pacman -S --noconfirm --needed nvidia-open
  before_packages=$(package_manifest)
  before_etc=$(tree_hash /etc)
  before_boot=$(tree_hash /boot)
  run_nvidia_step r7-prebuilt-refused "$supported" pacman:before-commit
  status=$last_status
  record 'R7 refused replacement leaves prebuilt and files untouched' "$([[ $status != 0 && $before_packages == "$(package_manifest)" && $before_etc == "$(tree_hash /etc)" && $before_boot == "$(tree_hash /boot)" && $(pacman -Q nvidia-open >/dev/null 2>&1; echo $?) == 0 ]] && echo 1 || echo 0)" "status $status"
  hold_r15_failure_row prebuilt-refused
  run_nvidia_step r7-prebuilt-replacement "$supported" -
  record 'R7 replaces same-version prebuilt with explicit DKMS package' "$([[ $last_status == 0 && $(pacman -Qe nvidia-open-dkms >/dev/null 2>&1; echo $?) == 0 && $(pacman -Q nvidia-open >/dev/null 2>&1; echo $?) != 0 && $(grep -c 'replaced nvidia-open' "$state/reports.log") -ge 1 ]] && echo 1 || echo 0)" 'prebuilt package names and replacement report checked'

  sudo pacman -Rdd --noconfirm nvidia-open-dkms
  sudo pacman -S --noconfirm --needed nvidia-open
  kernel=$(kernel_for_pkgbase linux 2>/dev/null || true)
  if [[ -z $kernel ]]; then record 'R15 prebuilt replacement build-failure kernel found' 0 'linux kernel tree missing'; return; fi
  build_link_path=/usr/lib/modules/$kernel/build
  if [[ ! -e $build_link_path && ! -L $build_link_path ]]; then
    record 'R15 prebuilt replacement build-failure fixture available' 0 "$build_link_path missing before fixture"
    return
  fi
  printf '%s' "$build_link_path" >"$test_root/linux-build-link-path"
  sudo mv "$build_link_path" "$test_root/linux-build-link.saved"
  run_nvidia_step r15-prebuilt-dkms-failure "$supported" "dkms:$kernel"
  status=$last_status
  if [[ $status == 0 ]] && pacman -Q nvidia-open-dkms >/dev/null 2>&1 &&
     ! pacman -Q nvidia-open >/dev/null 2>&1 &&
     grep -Fq "$kernel" "$state/reports.log" && grep -Fq 'make.log' "$state/reports.log" &&
     [[ -e $test_root/linux-build-link.saved ]]; then
    record 'R15 prebuilt replacement survives a failed DKMS build on the fallback path' 1 "kernel $kernel; DKMS hook and installer retry ran without its build link"
  else
    record 'R15 prebuilt replacement survives a failed DKMS build on the fallback path' 0 "kernel $kernel; DKMS hook and installer retry ran without its build link"
  fi
  hold_r15_failure_row prebuilt-linux-dkms
  sudo mv "$test_root/linux-build-link.saved" "$build_link_path"
  rm -f "$test_root/linux-build-link-path"
  run_nvidia_step r15-prebuilt-dkms-retry "$supported" -
  record 'R17 rerun retries the same-version failed DKMS build' "$([[ $last_status == 0 && $(modinfo -k "$kernel" -F version nvidia_drm 2>/dev/null || true) == "$(module_version_from_package "$(pacman -Q nvidia-utils | awk '{print $2}')")" ]] && echo 1 || echo 0)" "$kernel"
  if [[ $last_status == 0 && $(pacman -Q nvidia-open-dkms >/dev/null 2>&1; echo $?) == 0 &&
        $(pacman -Q nvidia-open >/dev/null 2>&1; echo $?) != 0 ]]; then
    rm -f "$test_root/driver-recovery-needed"
  fi
}

test_foreign_driver() {
  local dir=$test_root/foreign-driver before_packages before_etc before_boot status
  mkdir -p "$dir/foreign-driver/usr/share"
  cat >"$dir/PKGBUILD" <<'EOF'
pkgname=gooarchy-test-foreign-nvidia
pkgver=1.0
pkgrel=1
pkgdesc='Temporary VM test package advertising an NVIDIA module provider'
arch=('any')
license=('custom')
provides=('NVIDIA-MODULE')
package() { install -Dm644 /dev/null "$pkgdir/usr/share/gooarchy-test-foreign-nvidia"; }
EOF
  (cd "$dir" && makepkg --noconfirm --skipchecksums >/dev/null)
  : >"$test_root/foreign-driver-installed"
  sudo pacman -U --noconfirm "$dir"/gooarchy-test-foreign-nvidia-*.pkg.tar.*
  before_packages=$(package_manifest)
  before_etc=$(tree_hash /etc)
  before_boot=$(tree_hash /boot)
  run_nvidia_step r8-foreign-driver "$supported" -
  status=$last_status
  record 'R8 foreign driver is left installed and reported' "$([[ $status == 0 && $before_packages == "$(package_manifest)" && $before_etc == "$(tree_hash /etc)" && $before_boot == "$(tree_hash /boot)" && $(grep -c 'gooarchy-test-foreign-nvidia' "$state/reports.log") -ge 1 ]] && echo 1 || echo 0)" "status $status"
  sudo pacman -Rns --noconfirm gooarchy-test-foreign-nvidia
  rm -f "$test_root/foreign-driver-installed"
}

test_held_driver() {
  local utils_pkg=$old_utils_package dkms_pkg=$old_dkms_package
  local utils_sha=$old_utils_sha dkms_sha=$old_dkms_sha
  local pacman_conf=/etc/pacman.conf saved_conf=$test_root/pacman.conf.saved
  local packages_before etc_before boot_before modules_before reports_before status old_version
  if [[ -z $utils_pkg || -z $dkms_pkg || -z $utils_sha || -z $dkms_sha || ! -f $utils_pkg || ! -f $dkms_pkg ]]; then
    record 'R8 held-version NVIDIA packages supplied from the Arch Linux Archive' 0 'missing pinned package paths or checksums'
    return
  fi
  if [[ $(sha256sum "$utils_pkg" | awk '{print $1}') != "$utils_sha" || $(sha256sum "$dkms_pkg" | awk '{print $1}') != "$dkms_sha" ]]; then
    record 'R8 held-version NVIDIA package checksums match' 0 'archive package hash mismatch'
    return
  fi
  : >"$test_root/driver-recovery-needed"
  sudo cp -a "$pacman_conf" "$saved_conf"
  sudo pacman -U --noconfirm "$utils_pkg" "$dkms_pkg"
  grep -Eq '^[[:space:]]*\[options\][[:space:]]*$' "$pacman_conf" || {
    record 'R8 pacman hold fixture has an options section' 0 "$pacman_conf has no [options] section"
    sudo mv "$saved_conf" "$pacman_conf"
    restore_r15a_current_state || true
    return
  }
  sudo sed -i '/^[[:space:]]*\[options\][[:space:]]*$/a IgnorePkg = nvidia-utils nvidia-open-dkms' "$pacman_conf"
  old_version=$(pacman -Q nvidia-utils | awk '{print $2}')
  packages_before=$(package_manifest)
  etc_before=$(tree_hash /etc)
  boot_before=$(tree_hash /boot)
  modules_before=$(tree_hash /usr/lib/modules)
  reports_before=$(report_count)
  run_nvidia_step r8-held-driver "$supported" -
  status=$last_status
  if [[ $status == 0 && $packages_before == "$(package_manifest)" &&
        $etc_before == "$(tree_hash /etc)" && $boot_before == "$(tree_hash /boot)" &&
        $modules_before == "$(tree_hash /usr/lib/modules)" && $(($(report_count) - reports_before)) == 1 ]] &&
     grep -Fq "nvidia-utils $old_version" "$state/reports.log"; then
    record 'R8 held old driver package versions are left unchanged' 1 "nvidia-utils $old_version"
  else
    record 'R8 held old driver package versions are left unchanged' 0 "nvidia-utils $old_version"
  fi
  sudo mv "$saved_conf" "$pacman_conf"
  sudo pacman -S --noconfirm --needed nvidia-utils nvidia-open-dkms
  run_nvidia_step r8-held-driver-restored "$supported" -
  record 'R8 archive hold fixture is restored to the repository driver' "$([[ $last_status == 0 && $(pacman -Q nvidia-utils | awk '{print $2}') == "$(pacman -Si extra/nvidia-utils | awk -F ': ' '$1 == "Version" {print $2; exit}')" ]] && echo 1 || echo 0)" 'repository driver restored after held-version check'
  if [[ $last_status == 0 && $(pacman -Q nvidia-utils | awk '{print $2}') == "$(pacman -Si extra/nvidia-utils | awk -F ': ' '$1 == "Version" {print $2; exit}')" ]]; then
    rm -f "$test_root/driver-recovery-needed"
  fi
}

test_r15a_stale_baseline() {
  local utils_pkg=$old_utils_package dkms_pkg=$old_dkms_package
  local utils_sha=$old_utils_sha dkms_sha=$old_dkms_sha
  local kernel old_package_version old_dkms_version old_module_version current_package_version current_module_version
  local stale_images stale_packages stale_etc stale_modules old_images_expected status image_ok=1 image
  local -a required=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
  if [[ -z $utils_pkg || -z $dkms_pkg || ! -f $utils_pkg || ! -f $dkms_pkg ||
        $(sha256sum "$utils_pkg" | awk '{print $1}') != "$utils_sha" ||
        $(sha256sum "$dkms_pkg" | awk '{print $1}') != "$dkms_sha" ]]; then
    record 'R15a older driver from Arch Linux Archive is pinned' 0 'missing package paths or checksum mismatch'
    return
  fi
  kernel=$(kernel_for_pkgbase linux 2>/dev/null || true)
  if [[ -z $kernel ]]; then record 'R15a linux kernel for stale-image recovery exists' 0 'linux module tree missing'; return; fi
  current_package_version=$(pacman -Q nvidia-utils | awk '{print $2}')
  old_package_version=$(pacman -Qp "$utils_pkg" | awk '{print $2}')
  old_dkms_version=$(pacman -Qp "$dkms_pkg" | awk '{print $2}')
  if [[ -z $old_package_version || $old_package_version != "$old_dkms_version" ||
        $(vercmp "$old_package_version" "$current_package_version") -ge 0 ]]; then
    record 'R15a Archive packages are an older matching driver pair' 0 \
      "archive nvidia-utils/nvidia-open-dkms $old_package_version/$old_dkms_version; installed $current_package_version"
    return
  fi

  : >"$test_root/r15a-recovery-needed"
  printf 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\n' >"$test_root/r15a-user-modules.conf"
  sudo cp "$test_root/r15a-user-modules.conf" "$user_config"
  if ! sudo pacman -U --noconfirm "$utils_pkg" "$dkms_pkg"; then
    record 'R15a archived NVIDIA driver installs in the VM' 0 'pacman -U failed'
    restore_r15a_current_state || true
    return
  fi
  old_package_version=$(pacman -Q nvidia-utils | awk '{print $2}')
  old_dkms_version=$(pacman -Q nvidia-open-dkms | awk '{print $2}')
  old_module_version=$(module_version_from_package "$old_package_version")
  if [[ $old_package_version != "$old_dkms_version" ]]; then
    record 'R15a Archive packages install as a matching driver pair' 0 \
      "installed nvidia-utils/nvidia-open-dkms $old_package_version/$old_dkms_version"
    restore_r15a_current_state || true
    return
  fi
  if ! save_kernel_images linux r15a-old; then
    record 'R15a archived driver produced linux images to age' 0 'linux preset images unavailable'
    restore_r15a_current_state || true
    return
  fi
  image_set_for_kernel linux || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$old_module_version" "${required[@]}" || image_ok=0
  done
  old_images_expected=$(kernel_image_hashes linux 2>/dev/null || true)
  record 'R15a saved baseline images contain the archived module version' \
    "$([[ $image_ok == 1 && -n $old_images_expected ]] && echo 1 || echo 0)" \
    "nvidia-utils $old_package_version; module version $old_module_version"
  if ((image_ok == 0)); then
    restore_r15a_current_state || true
    return
  fi
  sudo rm -f "$user_config"
  if ! sudo pacman -S --noconfirm --needed nvidia-utils nvidia-open-dkms; then
    record 'R15a Arch upgrade returns the driver to current repository versions' 0 'pacman -S failed'
    restore_r15a_current_state || true
    return
  fi
  current_module_version=$(module_version_from_package "$(pacman -Q nvidia-utils | awk '{print $2}')")
  if [[ $current_module_version == "$old_module_version" ]]; then
    record 'R15a archive version differs from the current repository driver' 0 "both are $current_module_version"
    restore_r15a_current_state || true
    return
  fi
  if ! restore_kernel_images r15a-old; then
    record 'R15a stale image fixture restores the archived baseline' 0 'could not restore archived images'
    restore_r15a_current_state || true
    return
  fi
  stale_images=$(kernel_image_hashes linux 2>/dev/null || true)
  image_ok=1
  image_set_for_kernel linux || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$old_module_version" "${required[@]}" || image_ok=0
  done
  record 'R15a stale fixture keeps old NVIDIA modules in each restored image' \
    "$([[ $image_ok == 1 && $stale_images == "$old_images_expected" ]] && echo 1 || echo 0)" \
    "linux $kernel; archived module version $old_module_version"
  if ((image_ok == 0)); then
    restore_r15a_current_state || true
    return
  fi
  stale_packages=$(package_manifest)
  stale_etc=$(tree_hash /etc)
  stale_modules=$(tree_hash /usr/lib/modules)
  run_nvidia_step r15a-stale-baseline-refused "$supported" "mkinitcpio:$kernel"
  status=$last_status
  if [[ $image_ok == 1 && $status != 0 && $stale_packages == "$(package_manifest)" &&
        $stale_etc == "$(tree_hash /etc)" && $stale_modules == "$(tree_hash /usr/lib/modules)" &&
        $stale_images == "$(kernel_image_hashes linux 2>/dev/null || true)" ]] &&
     grep -Fq "$kernel" "$test_root/r15a-stale-baseline-refused.log" &&
     grep -Fq "$old_module_version" "$test_root/r15a-stale-baseline-refused.log" &&
     grep -Fq 'may not reach the desktop' "$test_root/r15a-stale-baseline-refused.log"; then
    record 'R15a refuses inherited stale images before changing packages or its owned file' 1 "linux image $old_module_version; current modules $current_module_version"
  else
    record 'R15a refuses inherited stale images before changing packages or its owned file' 0 "linux image $old_module_version; current modules $current_module_version"
  fi
  hold_r15_failure_row stale-baseline-repair-failure

  image_ok=1
  run_nvidia_step r15a-stale-baseline-repair "$supported" -
  status=$last_status
  image_set_for_kernel linux || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$current_module_version" "${required[@]}" || image_ok=0
  done
  record 'R15a rerun repairs stale linux images at the installed driver version' "$([[ $status == 0 && $image_ok == 1 ]] && echo 1 || echo 0)" "old $old_module_version; current $current_module_version"
  if ((status == 0 && image_ok == 1)); then rm -f "$test_root/r15a-recovery-needed"; fi
  rm -f "$test_root"/r15a-old-image-*.img "$test_root/r15a-old-images.tsv"
}

test_r15_step_regeneration_after_successful_arch_upgrade() {
  local kernel old_package_version old_module_version current_package_version status boundary
  local state_unchanged hook_ok step_failure image image_ok=1 modules
  if [[ -z $old_utils_package || -z $old_dkms_package || ! -f $old_utils_package || ! -f $old_dkms_package ]]; then
    record 'R15 older-driver upgrade failure fixture has a matching Archive pair' 0 'Archive package pair is unavailable'
    return
  fi
  kernel=$(kernel_for_pkgbase linux 2>/dev/null || true)
  if [[ -z $kernel ]]; then
    record 'R15 older-driver upgrade failure fixture has a linux kernel' 0 'linux module tree missing'
    return
  fi
  if [[ -e $owned ]] && ! grep -Fxq '# Gooarchy NVIDIA early KMS modules; managed by the Gooarchy installer.' "$owned"; then
    record 'R15 early-KMS config can be temporarily removed for the upgrade failure fixture' 0 "$owned is user-owned"
    return
  fi
  : >"$test_root/r15a-recovery-needed"
  sudo rm -f "$owned"
  old_package_version=$(pacman -Qp "$old_utils_package" | awk '{print $2}')
  old_module_version=$(module_version_from_package "$old_package_version")
  if ! sudo pacman -U --noconfirm "$old_utils_package" "$old_dkms_package"; then
    record 'R15 older driver pair installs before the Arch upgrade' 0 'pacman -U failed'
    restore_r15a_current_state || true
    return
  fi
  image_set_for_kernel linux || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    lsinitcpio "$image" >/dev/null 2>&1 || image_ok=0
    modules=$(image_modules "$image" 2>/dev/null || true)
    [[ -z $modules ]] || image_ok=0
  done
  record 'R15 old-version starting images are sound without NVIDIA modules' "$([[ $image_ok == 1 ]] && echo 1 || echo 0)" \
    "linux $kernel; old driver module version $old_module_version"
  if ((image_ok == 0)); then
    restore_r15a_current_state || true
    return
  fi

  run_full_installer r15-step-regeneration-refused 'mkinitcpio-pkgbase:linux' -
  status=$last_status
  boundary=$test_root/r15-step-regeneration-refused-upgrade-state.tsv
  capture_upgrade_state "$test_root/r15-step-regeneration-refused-after-state.tsv" || true
  grep -v 'gooarchy-nvidia.conf' "$boundary" >"$test_root/r15-step-boundary-without-owned.tsv" 2>/dev/null || true
  grep -v 'gooarchy-nvidia.conf' "$test_root/r15-step-regeneration-refused-after-state.tsv" \
    >"$test_root/r15-step-after-without-owned.tsv" 2>/dev/null || true
  state_unchanged=0
  if [[ -s $test_root/r15-step-boundary-without-owned.tsv &&
        -s $test_root/r15-step-after-without-owned.tsv ]] &&
     cmp -s "$test_root/r15-step-boundary-without-owned.tsv" "$test_root/r15-step-after-without-owned.tsv"; then
    state_unchanged=1
  fi
  hook_ok=1
  grep -Fq 'ERROR: Gooarchy VM test injected package-hook failure' "$test_root/r15-step-regeneration-refused.full-install.log" && hook_ok=0
  step_failure=0
  if grep -Fq "mkinitcpio failed while generating early-KMS images for linux kernel" \
       "$test_root/r15-step-regeneration-refused.full-install.log" &&
     grep -Fq 'Gooarchy test hook failed mkinitcpio' "$test_root/r15-step-regeneration-refused.full-install.log"; then
    step_failure=1
  fi
  current_package_version=$(pacman -Q nvidia-utils | awk '{print $2}')
  image_ok=1
  image_set_for_kernel linux || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    lsinitcpio "$image" >/dev/null 2>&1 || image_ok=0
    check_image_versions_and_firmware "$image" "$(module_version_from_package "$current_package_version")" || image_ok=0
    modules=$(image_modules "$image" 2>/dev/null || true)
    [[ -z $modules ]] || image_ok=0
  done
  record 'R15 Arch upgrade hooks succeed and the step regeneration fails with complete, consistent fallback images' \
    "$([[ $status != 0 && $state_unchanged == 1 && $hook_ok == 1 && $step_failure == 1 && $image_ok == 1 && -e $owned &&
          $current_package_version == "$(pacman -Si extra/nvidia-utils | awk -F ': ' '$1 == "Version" {print $2; exit}')" ]] && echo 1 || echo 0)" \
    "linux $kernel; nvidia-utils $current_package_version; owned early-KMS file remains for rerun"
  hold_r15_failure_row arch-upgrade-step-regen
  if restore_r15a_current_state; then
    record 'R15 recovery after the injected step failure restores current early KMS' 1 'current packages, DKMS modules, and images restored'
  else
    record 'R15 recovery after the injected step failure restores current early KMS' 0 'cleanup recovery failed'
  fi
}

test_r15a_arch_upgrade_hook() {
  local kernel old_package_version old_module_version current_package_version current_module_version
  local old_images old_image_preserved expected_image_hash image image_ok hook_failed stale_report boundary state_unchanged
  local status recovery_report
  local -a required=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
  if [[ -z $old_utils_package || -z $old_dkms_package || ! -f $old_utils_package || ! -f $old_dkms_package ]]; then
    record 'R15a Arch-upgrade failure fixture has a matching Archive package pair' 0 'Archive package pair is unavailable'
    return
  fi
  kernel=$(kernel_for_pkgbase linux 2>/dev/null || true)
  if [[ -z $kernel ]]; then
    record 'R15a Arch-upgrade linux kernel is available' 0 'linux module tree missing'
    return
  fi
  : >"$test_root/r15a-recovery-needed"
  old_package_version=$(pacman -Qp "$old_utils_package" | awk '{print $2}')
  old_module_version=$(module_version_from_package "$old_package_version")
  if ! sudo pacman -U --noconfirm "$old_utils_package" "$old_dkms_package"; then
    record 'R15a older matching driver pair installs from the Archive' 0 'pacman -U failed'
    restore_r15a_current_state || true
    return
  fi
  printf 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\n' >"$test_root/r15a-arch-upgrade-modules.conf"
  sudo cp "$test_root/r15a-arch-upgrade-modules.conf" "$user_config"
  if ! sudo mkinitcpio -p linux >"$test_root/r15a-arch-upgrade-old-image.log" 2>&1; then
    record 'R15a old-version Linux images can be prepared' 0 'mkinitcpio failed with the archived driver'
    restore_r15a_current_state || true
    return
  fi
  image_ok=1
  image_set_for_kernel linux || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$old_module_version" "${required[@]}" || image_ok=0
  done
  old_images=$(kernel_image_hashes linux 2>/dev/null || true)
  record 'R15a Archive fixture has complete old-version Linux images' "$([[ $image_ok == 1 && -n $old_images ]] && echo 1 || echo 0)" \
    "linux $kernel; module version $old_module_version"
  if ((image_ok == 0)); then
    restore_r15a_current_state || true
    return
  fi
  sudo rm -f "$user_config"

  run_full_installer r15a-arch-hook-repaired -
  status=$last_status
  boundary=$test_root/r15a-arch-hook-repaired-upgrade-state.tsv
  hook_failed=0
  grep -Fq "ERROR: Gooarchy VM test injected package-hook failure for linux" \
    "$test_root/r15a-arch-hook-repaired.full-install.log" && hook_failed=1
  old_image_preserved=1
  [[ -s $boundary ]] || old_image_preserved=0
  while read -r expected_image_hash image; do
    [[ -n $expected_image_hash && -n $image && -f $image ]] || { old_image_preserved=0; continue; }
    grep -Fq "$expected_image_hash  $image" "$boundary" || old_image_preserved=0
  done <<<"$old_images"
  grep -Fq 'image-module' "$boundary" && grep -Fq "$old_module_version" "$boundary" || old_image_preserved=0
  current_package_version=$(pacman -Q nvidia-utils | awk '{print $2}')
  current_module_version=$(module_version_from_package "$current_package_version")
  image_ok=1
  image_set_for_kernel linux || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$current_module_version" "${required[@]}" || image_ok=0
  done
  stale_report=0
  if grep -Fq 'found an NVIDIA image baseline out of step' "$test_root/r15a-arch-hook-repaired.full-install.log" &&
     grep -Fq "$old_module_version" "$test_root/r15a-arch-hook-repaired.full-install.log"; then
    stale_report=1
  fi
  record 'R15a Arch upgrade hook fails for linux and leaves the inherited old image for the step to find' \
    "$([[ $status == 0 && $hook_failed == 1 && $old_image_preserved == 1 && $stale_report == 1 ]] && echo 1 || echo 0)" \
    "arch-upgrade hook failure injected for linux; old image version $old_module_version"
  record 'R15a step repairs the inherited stale Linux images and completes' \
    "$([[ $status == 0 && $current_package_version == "$(pacman -Si extra/nvidia-utils | awk -F ': ' '$1 == "Version" {print $2; exit}')" && $image_ok == 1 ]] && echo 1 || echo 0)" \
    "nvidia-utils $current_package_version; module version $current_module_version"
  hold_r15_failure_row arch-upgrade-hook-repaired
  if ((status != 0 || image_ok == 0)) ||
     [[ $current_package_version != "$(pacman -Si extra/nvidia-utils | awk -F ': ' '$1 == "Version" {print $2; exit}')" ]]; then
    restore_r15a_current_state || true
    return
  fi

  : >"$test_root/r15a-recovery-needed"
  if ! sudo pacman -U --noconfirm "$old_utils_package" "$old_dkms_package"; then
    record 'R15a second Archive downgrade is available for the refusal case' 0 'pacman -U failed'
    restore_r15a_current_state || true
    return
  fi
  sudo cp "$test_root/r15a-arch-upgrade-modules.conf" "$user_config"
  if ! sudo mkinitcpio -p linux >"$test_root/r15a-arch-upgrade-refusal-old-image.log" 2>&1; then
    record 'R15a refusal fixture old images can be prepared' 0 'mkinitcpio failed with the archived driver'
    restore_r15a_current_state || true
    return
  fi
  old_images=$(kernel_image_hashes linux 2>/dev/null || true)
  sudo rm -f "$user_config"
  run_full_installer r15a-arch-hook-refused mkinitcpio-pkgbase:linux
  status=$last_status
  boundary=$test_root/r15a-arch-hook-refused-upgrade-state.tsv
  capture_upgrade_state "$test_root/r15a-arch-hook-refused-after-state.tsv" || true
  state_unchanged=0
  if [[ -s $boundary && -s $test_root/r15a-arch-hook-refused-after-state.tsv ]] &&
     cmp -s "$boundary" "$test_root/r15a-arch-hook-refused-after-state.tsv"; then
    state_unchanged=1
  fi
  stale_report=0
  recovery_report=0
  if grep -Fq "found an NVIDIA image baseline out of step" "$test_root/r15a-arch-hook-refused.full-install.log" &&
     grep -Fq "$old_module_version" "$test_root/r15a-arch-hook-refused.full-install.log"; then
    stale_report=1
  fi
  grep -Fq 'may not reach the desktop' "$test_root/r15a-arch-hook-refused.full-install.log" &&
    grep -Fq 'Arch install media' "$test_root/r15a-arch-hook-refused.full-install.log" && recovery_report=1
  record 'R15a stale-repair failure stops before any further NVIDIA package, module, image, or owned-file change' \
    "$([[ $status != 0 && $state_unchanged == 1 && $old_images == "$(kernel_image_hashes linux 2>/dev/null || true)" && $stale_report == 1 && $recovery_report == 1 ]] && echo 1 || echo 0)" \
    "linux $kernel; stale module version $old_module_version; step regeneration injected to fail"
  hold_r15_failure_row arch-upgrade-hook-repair-failure
  if restore_r15a_current_state; then
    record 'R15a Arch-upgrade fixture restores current driver and images' 1 'current packages, DKMS modules, and images restored'
  else
    record 'R15a Arch-upgrade fixture restores current driver and images' 0 'cleanup recovery failed'
  fi
}

r15_row() {
  local row=$1
  GOOARCHY_NVIDIA_HOLD_R15_ROW=$row
  export GOOARCHY_NVIDIA_HOLD_R15_ROW
  case $row in
    precommit-download|precommit-space)
      preinstall
      ;;
    linux-gooarchy-dkms)
      verify_repository_driver_pair || return 1
      test_r15_linux_gooarchy_dkms_failure
      ;;
    interrupt-after-commit)
      verify_repository_driver_pair || return 1
      test_r15_interrupted_after_commit
      ;;
    pacman-commit-interruption)
      verify_repository_driver_pair || return 1
      test_r15_pacman_stale_lock
      ;;
    package-hook-linux-only|package-hook-linux-partial-lts)
      verify_repository_driver_pair || return 1
      test_pacman_hook_failure_with_partial_kernel
      ;;
    prebuilt-refused|prebuilt-linux-dkms)
      verify_repository_driver_pair || return 1
      test_prebuilt_replacement
      ;;
    stale-baseline-repair-failure|arch-upgrade-step-regen|arch-upgrade-hook-repaired|arch-upgrade-hook-repair-failure)
      verify_repository_driver_pair || return 1
      ensure_archive_pair || { record "R15 row $row has an older matching Archive package pair" 0 'Archive package pair unavailable'; return 1; }
      case $row in
        stale-baseline-repair-failure) test_r15a_stale_baseline ;;
        arch-upgrade-step-regen) test_r15_step_regeneration_after_successful_arch_upgrade ;;
        *) test_r15a_arch_upgrade_hook ;;
      esac
      ;;
    *)
      echo "unknown R15 boot-evidence row: $row" >&2
      return 2
      ;;
  esac
  ((failures == 0))
}

case $phase in
  preinstall) preinstall ;;
  postinstall) postinstall ;;
  reference) reference ;;
  r15-row) r15_row "${2:-${GOOARCHY_NVIDIA_HOLD_R15_ROW:-}}" ;;
  r15-release)
    verify_r15_boot_evidence "$held_row" "$held_stamp" "$held_plan_sha"
    held=$(cut -f1 "$test_root/r15-boot-held")
    [[ ${2:-} == "$held" ]] || { echo 'r15-release row changed during validation.' >&2; exit 2; }
    rm -f "$test_root/r15-boot-held"
    ;;
  *) echo "usage: $0 preinstall|postinstall|reference|r15-row <row>|r15-release <row>" >&2; exit 2 ;;
esac
