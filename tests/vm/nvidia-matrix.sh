#!/bin/bash
# Guest-side checks for the NVIDIA installer. Run only through tests/vm/run.sh on a
# disposable guest; this script changes packages, initramfs images and test config.
# R15 boot rows pause with a per-kernel manifest; the runner reboots its sound kernels, records a
# result file for each at r15-boot-evidence-<row>-<kernel>.tsv, then calls r15-release <row> before
# recovering the held fixture. Each result records schema, row, stamp, kernel, boot-id, desktop=pass,
# and nvidia-device=no-device as tab-separated key/value lines.
# The pacman-lock R15 row verifies fail-closed behavior with a test-owned stale db.lck; cleanup
# removes only that exact lock file after the matrix records whether the installer preserved it.
# Product rows in results.tsv assert installer behavior: C1 rejects ambiguous preset assignments
# without mutation; C2 preserves sound images through a bounded-space hook failure; C3 surfaces the
# generated Arch hook failure; C4 regenerates only selected images while preserving direct-config
# siblings; C5 retains the user-partial fix report without rewriting the user's config. Fixture and
# cleanup evidence belongs in fixture.tsv and never increments product pass/fail counts.
# Other retained rows are named for their product behavior: R2/R3 fallback on unsupported devices,
# R6/R9 per-kernel coverage and user-partial reporting, R7/R8 package replacement and hold behavior,
# R10 user MODULES handling, R11 per-preset image/config behavior, R13 neutral service state and
# notifier defaults, R14 desktop GPU selection, R15/R15a safe failure and stale-image handling, R16
# user-file preservation, R17 rerun convergence, and R18 idempotence. VM hostname, machine identity,
# repository readiness and incidental runner state are not product gates.
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
supported='0x10de,0x030000,0x25a2,0'
legacy='0x10de,0x030000,0x1b80,0'
dual_gpu=$'0x8086,0x030000,0x9a49,1\n0x10de,0x030200,0x25a2,0'
checks=0
failures=0
last_status=0

driver_module_files() {
  find "$1" -type f \
    \( -name 'nvidia.ko*' -o -name 'nvidia_modeset.ko*' -o -name 'nvidia_uvm.ko*' -o -name 'nvidia_drm.ko*' \
       -o -name 'nvidia-modeset.ko*' -o -name 'nvidia-uvm.ko*' -o -name 'nvidia-drm.ko*' \) \
    -print0
}

driver_module_hashes() {
  local module_dir
  for module_dir in /usr/lib/modules/*; do
    [[ -d $module_dir ]] || continue
    driver_module_files "$module_dir" | sort -z | xargs -0r sha256sum
  done
}

repository_version() {
  local output
  output=$(LC_ALL=C pacman -Si "$1" 2>/dev/null) || return 1
  awk '
    /^[[:space:]]*Version[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/[[:space:]]+$/, "")
      if (length) { print; found=1; exit }
    }
    END { if (!found) exit 1 }
  ' <<<"$output"
}
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
  grep -Eq '^[[:space:]]*Exec[[:space:]]*=[[:space:]]*(/usr/bin/mkinitcpio[[:space:]]+-P|/usr/share/libalpm/scripts/mkinitcpio[[:space:]]+install)[[:space:]]*$' "$hook" || return 1
  # Current Arch delegates from the package hook to the script, which resolves mkinitcpio through
  # PATH. The pacman test invocation supplies the wrapper there, so preserve and exercise that
  # generated hook unchanged. Older direct hooks need their Exec redirected to the wrapper.
  if ! grep -Eq '^[[:space:]]*Exec[[:space:]]*=[[:space:]]*/usr/bin/mkinitcpio[[:space:]]+-P[[:space:]]*$' "$hook"; then
    return 0
  fi
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
  local fail_preset= fail_kernel fail_image= pkgbase rc is_upgrade=0 hook_installed=0
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
    fail_image=${GOOARCHY_TEST_PACMAN_HOOK_FAIL_IMAGE:-}
    [[ -n $fail_image && $fail_image == /* ]] || return 97
    if ! gooarchy_test_install_mkinitcpio_hook; then return 97; fi
    hook_installed=1
    if ((is_upgrade)); then args+=(--ignore mkinitcpio); fi
    if command sudo env GOOARCHY_VM_NVIDIA_TEST_ROOT="${GOOARCHY_VM_NVIDIA_TEST_ROOT:-$HOME}" \
      GOOARCHY_TEST_PACMAN_HOOK_FAIL_PRESET="$fail_preset" \
      GOOARCHY_TEST_PACMAN_HOOK_FAIL_AFTER_WRITE=1 GOOARCHY_TEST_PACMAN_HOOK_FAIL_IMAGE="$fail_image" \
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
driver_module_files() {
  find "$1" -type f \
    \( -name 'nvidia.ko*' -o -name 'nvidia_modeset.ko*' -o -name 'nvidia_uvm.ko*' -o -name 'nvidia_drm.ko*' \
       -o -name 'nvidia-modeset.ko*' -o -name 'nvidia-uvm.ko*' -o -name 'nvidia-drm.ko*' \) \
    -print0
}
preset_images() {
  local preset=$1 line lhs body= operator tail started=0 found=0 reading=0 closed=0 invalid=0 entry suffix key value entry_image_count
  local -a entries=()
  local -A seen=() seen_entries=()
  NV_IMAGES=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    if ((reading == 0)); then
      if [[ $line =~ ^[[:space:]]*PRESETS[[:space:]]*(\+?=) ]]; then
        operator=${BASH_REMATCH[1]}
        ((found += 1))
        if [[ $operator != '=' || $found > 1 ]]; then invalid=1; break; fi
        body=${line#*=}
        reading=1
      else
        continue
      fi
    else
      body+=" $line"
    fi
    if ((reading)) && [[ $body == *')'* ]]; then
      closed=1
      reading=0
      tail=${body#*)}
      tail=${tail#"${tail%%[![:space:]]*}"}
      [[ -z $tail ]] || { invalid=1; break; }
    fi
  done <"$preset"
  ((invalid == 0 && found == 1 && closed && reading == 0)) || return 1
  body=${body#"${body%%[![:space:]]*}"}
  [[ ${body:0:1} == '(' ]] || return 1
  body=${body:1}
  body=${body%)}
  [[ $body != *'$'* && $body != *'`'* && $body != *';'* && $body != *'('* && $body != *')'* ]] || return 1
  read -r -a entries <<<"$body"
  ((${#entries[@]} > 0)) || return 1
  for entry in "${entries[@]}"; do
    case $entry in
      \'*\') entry=${entry:1:${#entry}-2} ;;
      \"*\") entry=${entry:1:${#entry}-2} ;;
    esac
    [[ $entry =~ ^[[:alnum:]_.+-]+$ ]] || return 1
    [[ ! ${seen_entries[$entry]:-} ]] || return 1
    seen_entries[$entry]=1
    entry_image_count=0
    for suffix in image uki; do
      key=${entry}_${suffix}
      value= matches=0 appended=0
      while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}
        [[ $line == *=* ]] || continue
        lhs=${line%%=*}
        lhs=${lhs#"${lhs%%[![:space:]]*}"}
        lhs=${lhs%"${lhs##*[![:space:]]}"}
        if [[ $lhs == "$key+" ]]; then appended=1; continue; fi
        [[ $lhs == "$key" ]] || continue
        ((matches += 1))
        value=${line#*=}
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        value=${value#\"}; value=${value%\"}
        value=${value#\'}; value=${value%\'}
        :
      done <"$preset"
      ((appended == 0 && matches <= 1)) || return 1
      [[ -n $value ]] || continue
      [[ $value != *'$'* && $value != *'`'* ]] || return 1
      [[ ! ${seen[$value]:-} ]] || return 1
      seen[$value]=1
      NV_IMAGES+=("$value")
      ((entry_image_count += 1))
    done
    ((entry_image_count > 0)) || return 1
  done
  ((${#NV_IMAGES[@]} > 0))
}
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
  driver_module_files "$module_dir" | sort -z | xargs -0r sha256sum
done
if [[ -r /etc/mkinitcpio.d/linux.preset ]]; then
if ! preset_images /etc/mkinitcpio.d/linux.preset; then
  printf 'unresolved-preset  /etc/mkinitcpio.d/linux.preset\n'
  exit 1
fi
for image in "${NV_IMAGES[@]}"; do
  if [[ -f $image ]]; then sha256sum "$image"; else printf 'missing  %s\n' "$image"; fi
  [[ -f $image ]] && images+=("$image")
done
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
    done < <(find "$tmp" -type f \
      \( -name 'nvidia.ko*' -o -name 'nvidia_modeset.ko*' -o -name 'nvidia_uvm.ko*' -o -name 'nvidia_drm.ko*' \
         -o -name 'nvidia-modeset.ko*' -o -name 'nvidia-uvm.ko*' -o -name 'nvidia-drm.ko*' \) \
      -print0)
  fi
  rm -rf "$tmp"
done
EOF
chmod 0644 "$test_root/capture-upgrade-state.sh"
cat >"$test_root/bin/mkinitcpio" <<'EOF'
#!/bin/bash
if [[ -n ${GOOARCHY_TEST_PACMAN_HOOK_FAIL_PRESET:-} && ${1:-} == -P ]]; then
  status=0
  marker=${GOOARCHY_VM_NVIDIA_TEST_ROOT:-}/r15-package-hook-invocations.tsv
  for preset in /etc/mkinitcpio.d/*.preset; do
    [[ -f $preset ]] || continue
    pkgbase=${preset##*/}
    pkgbase=${pkgbase%.preset}
    if [[ $pkgbase == "$GOOARCHY_TEST_PACMAN_HOOK_FAIL_PRESET" ]]; then
      if [[ -n ${GOOARCHY_VM_NVIDIA_TEST_ROOT:-} ]]; then
        filesystem=$(df -k --output=source -- "$GOOARCHY_TEST_PACMAN_HOOK_FAIL_IMAGE" | awk 'NR == 2 { print $1 }')
        available=$(df -k --output=avail -- "$GOOARCHY_TEST_PACMAN_HOOK_FAIL_IMAGE" | awk 'NR == 2 { print $1 }')
        printf 'invoke\t%s\t%s\t%s\t%s\n' "$pkgbase" "$GOOARCHY_TEST_PACMAN_HOOK_FAIL_IMAGE" \
          "$filesystem" "$available" >>"$marker"
      fi
      printf '==> Building image from preset: %s\n' "$preset"
      if [[ ${GOOARCHY_TEST_PACMAN_HOOK_FAIL_AFTER_WRITE:-} == 1 &&
            -n ${GOOARCHY_TEST_PACMAN_HOOK_FAIL_IMAGE:-} ]]; then
        /usr/bin/mkinitcpio -p "$pkgbase" || { status=1; continue; }
        if ! : >"$GOOARCHY_TEST_PACMAN_HOOK_FAIL_IMAGE"; then
          printf 'ERROR: Gooarchy VM could not truncate the injected image %s\n' "$GOOARCHY_TEST_PACMAN_HOOK_FAIL_IMAGE"
        else
          printf 'ERROR: Gooarchy VM injected package-hook failure after writing %s\n' \
            "$GOOARCHY_TEST_PACMAN_HOOK_FAIL_IMAGE"
          if [[ -n ${GOOARCHY_VM_NVIDIA_TEST_ROOT:-} ]]; then
            printf 'after-write\t%s\t%s\n' "$pkgbase" "$GOOARCHY_TEST_PACMAN_HOOK_FAIL_IMAGE" >>"$marker"
          fi
        fi
      else
        printf 'ERROR: Gooarchy VM test injected package-hook failure for %s\n' "$pkgbase"
      fi
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

cleanup_bounded_pressure() {
  local path expected_device expected_inode actual status=0
  [[ -f $test_root/r15-bounded-pressure-owned.tsv ]] || return 0
  while IFS=$'\t' read -r path expected_device expected_inode; do
    [[ -n $path && -n $expected_device && -n $expected_inode ]] || continue
    if [[ ! -f $path || -L $path ]]; then
      status=1
      continue
    fi
    actual=$(sudo stat -c '%d:%i' -- "$path" 2>/dev/null || true)
    if [[ $actual != "$expected_device:$expected_inode" ]] || ! sudo rm -f -- "$path"; then
      status=1
    fi
  done <"$test_root/r15-bounded-pressure-owned.tsv"
  if ((status == 0)); then rm -f "$test_root/r15-bounded-pressure-owned.tsv"; fi
  return "$status"
}

bounded_pressure_files_present() {
  local path expected_device expected_inode actual count=0
  [[ -s $test_root/r15-bounded-pressure.tsv ]] || return 1
  awk -F '\t' 'NR == 1 { next } $5 < $3 || $5 > $3 + $9 + 4096 || $4 !~ /^[0-9]+$/ || $9 !~ /^[0-9]+$/ { bad=1 } END { exit !(NR > 1 && !bad) }' \
    "$test_root/r15-bounded-pressure.tsv" || return 1
  if [[ -s $test_root/r15-bounded-pressure-owned.tsv ]]; then
    while IFS=$'\t' read -r path expected_device expected_inode; do
      [[ -n $path && -n $expected_device && -n $expected_inode ]] || continue
      [[ -f $path && ! -L $path ]] || return 1
      actual=$(sudo stat -c '%d:%i' -- "$path" 2>/dev/null || true)
      [[ $actual == "$expected_device:$expected_inode" ]] || return 1
      ((count += 1))
    done <"$test_root/r15-bounded-pressure-owned.tsv"
    ((count > 0))
  else
    awk -F '\t' 'NR == 1 { next } $4 != 0 { bad=1 } END { exit !(NR > 1 && !bad) }' \
      "$test_root/r15-bounded-pressure.tsv"
  fi
}

cleanup() {
  local status=$? build_link_record build_link_path saved_link partial_kernel path
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
  if [[ -f $test_root/r15-bounded-pressure-owned.tsv ]] && ! cleanup_bounded_pressure; then
    printf 'The test-owned bounded pressure file could not be safely removed; see r15-bounded-pressure-owned.tsv.\n' \
      >"$test_root/cleanup-failure.txt"
    status=1
  fi
  if [[ -f $test_root/linux.preset.saved ]]; then
    if sudo mv -f "$test_root/linux.preset.saved" /etc/mkinitcpio.d/linux.preset; then
      fixture_event CLEANUP-OK 'C1 preset assignment-edge fixture' 'stock Linux preset restored after early exit'
    else
      fixture_event CLEANUP-FAIL 'C1 preset assignment-edge fixture' 'could not restore stock Linux preset after early exit'
      status=1
    fi
  fi
  if [[ -f $test_root/c1-stale-image-paths.tsv ]]; then
    while IFS= read -r path; do
      [[ -n $path && $path != path ]] || continue
      if [[ -f $path && ! -L $path ]]; then
        sudo rm -f -- "$path" || status=1
      elif [[ -e $path || -L $path ]]; then
        printf 'C1 stale output path changed type; left in place: %s\n' "$path" \
          >>"$test_root/cleanup-failure.txt"
        status=1
      fi
    done <"$test_root/c1-stale-image-paths.tsv"
  fi
  if [[ -f $test_root/90-mkinitcpio-install.hook.saved ]]; then
    sudo mv -f "$test_root/90-mkinitcpio-install.hook.saved" \
      /usr/share/libalpm/hooks/90-mkinitcpio-install.hook 2>/dev/null || status=1
  fi
  if [[ -f $test_root/linux.preset.mixed.saved ]]; then
    sudo mv -f "$test_root/linux.preset.mixed.saved" /etc/mkinitcpio.d/linux.preset 2>/dev/null || status=1
  fi
  if [[ -f $test_root/r11-mixed-images.tsv ]]; then
    if restore_kernel_images r11-mixed; then
      rm -f "$test_root/r11-mixed-images.tsv"
      sudo rm -f "$test_root"/r11-mixed-image-*.img || status=1
    else
      status=1
    fi
  fi
  remove_r11_mixed_synthetic_image || status=1
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

fixture_event() {
  local disposition=$1 name=$2 detail=${3:-}
  printf '%s\t%s\t%s\n' "$disposition" "$name" "$detail" | tee -a "$test_root/fixture.tsv" >&2
}

fixture_refuse() {
  fixture_event REFUSED "$1" "$2"
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
  utils_version=$(repository_version extra/nvidia-utils || true)
  dkms_version=$(repository_version extra/nvidia-open-dkms || true)
  if [[ -z $utils_version || -z $dkms_version || $utils_version != "$dkms_version" ]]; then
    local evidence
    evidence=$(capture_repository_pair_mismatch)
    fixture_refuse 'NVIDIA repository package pair' \
      "nvidia-utils ${utils_version:-unavailable}; nvidia-open-dkms ${dkms_version:-unavailable}; source evidence $evidence"
    return 75
  fi
  fixture_event READY 'NVIDIA repository package pair' \
    "nvidia-utils/nvidia-open-dkms $utils_version"
}

ensure_archive_pair() {
  local current_version utils_url dkms_url utils_version dkms_version metadata
  local saved_current saved_utils saved_utils_version saved_utils_sha saved_dkms saved_dkms_version saved_dkms_sha
  local -a urls=()
  metadata=$test_root/nvidia-archive-pair.tsv
  current_version=$(repository_version extra/nvidia-utils)
  if [[ -s $metadata && -n $current_version ]]; then
    saved_current=$(awk -F '\t' '$1 == "current" {print $2; exit}' "$metadata")
    saved_utils=$(awk -F '\t' '$1 == "nvidia-utils" {print $2; exit}' "$metadata")
    saved_utils_version=$(awk -F '\t' '$1 == "nvidia-utils" {print $3; exit}' "$metadata")
    saved_utils_sha=$(awk -F '\t' '$1 == "nvidia-utils" {print $4; exit}' "$metadata")
    saved_dkms=$(awk -F '\t' '$1 == "nvidia-open-dkms" {print $2; exit}' "$metadata")
    saved_dkms_version=$(awk -F '\t' '$1 == "nvidia-open-dkms" {print $3; exit}' "$metadata")
    saved_dkms_sha=$(awk -F '\t' '$1 == "nvidia-open-dkms" {print $4; exit}' "$metadata")
    if [[ $saved_current == "$current_version" &&
          $saved_utils =~ ^nvidia-utils-[[:alnum:].+_-]+-x86_64\.pkg\.tar\.zst$ &&
          $saved_dkms =~ ^nvidia-open-dkms-[[:alnum:].+_-]+-x86_64\.pkg\.tar\.zst$ &&
          $saved_utils_sha =~ ^[[:xdigit:]]{64}$ && $saved_dkms_sha =~ ^[[:xdigit:]]{64}$ ]]; then
      old_utils_package=$test_root/$saved_utils
      old_dkms_package=$test_root/$saved_dkms
      old_utils_sha=$saved_utils_sha
      old_dkms_sha=$saved_dkms_sha
    if [[ -f $old_utils_package && -f $old_dkms_package &&
          $(sha256sum "$old_utils_package" | awk '{print $1}') == "$old_utils_sha" &&
          $(sha256sum "$old_dkms_package" | awk '{print $1}') == "$old_dkms_sha" &&
          $(pacman -Qp "$old_utils_package" | awk '{print $2}') == "$saved_utils_version" &&
          $(pacman -Qp "$old_dkms_package" | awk '{print $2}') == "$saved_dkms_version" &&
          $saved_utils_version == "$saved_dkms_version" &&
            $(vercmp "$saved_utils_version" "$current_version") -lt 0 ]]; then
        return 0
      fi
    fi
  fi
  if [[ -n $old_utils_package && -n $old_dkms_package &&
        -n $old_utils_sha && -n $old_dkms_sha &&
        -f $old_utils_package && -f $old_dkms_package &&
        $(sha256sum "$old_utils_package" | awk '{print $1}') == "$old_utils_sha" &&
        $(sha256sum "$old_dkms_package" | awk '{print $1}') == "$old_dkms_sha" ]]; then
    return 0
  fi
  [[ -z $old_utils_package ]] || rm -f "$old_utils_package"
  [[ -z $old_dkms_package ]] || rm -f "$old_dkms_package"
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
     $(vercmp "$utils_version" "$current_version") -lt 0 ]] || return 1
  {
    printf 'current\t%s\n' "$current_version"
    printf 'nvidia-utils\t%s\t%s\t%s\n' "${old_utils_package##*/}" "$utils_version" "$old_utils_sha"
    printf 'nvidia-open-dkms\t%s\t%s\t%s\n' "${old_dkms_package##*/}" "$dkms_version" "$old_dkms_sha"
  } >"$metadata.tmp"
  mv "$metadata.tmp" "$metadata"
}

report_count() {
  [[ -f $state/reports.log ]] || { printf '0\n'; return; }
  wc -l <"$state/reports.log" | tr -d ' '
}

run_nvidia_step() {
  local name=$1 devices=${2:--} injected_failure=${3:--}
  local log=$test_root/$name.log install_log=$test_root/$name.step.log
  local fail_kernel fail_pkgbase fail_preset fail_image
  local -a overrides=()
  [[ $devices == - ]] || overrides+=("GOOARCHY_TEST_NVIDIA_DEVICES=$devices")
  [[ $injected_failure == - ]] || overrides+=("GOOARCHY_TEST_NVIDIA_FAIL=$injected_failure")
  if [[ $injected_failure == *pacman-hook:* ]]; then
    fail_kernel=${injected_failure#*pacman-hook:}
    fail_kernel=${fail_kernel%%,*}
    if [[ ! $fail_kernel =~ ^[[:alnum:]_.+-]+$ || ! -r /usr/lib/modules/$fail_kernel/pkgbase ]]; then
      last_status=97
      printf '%s\n' 'could not resolve the injected pacman-hook kernel for its image fixture.' >"$log"
      return
    fi
    fail_pkgbase=$(</usr/lib/modules/$fail_kernel/pkgbase)
    fail_preset=/etc/mkinitcpio.d/$fail_pkgbase.preset
    if [[ -z $fail_pkgbase ]] || ! preset_images "$fail_preset"; then
      last_status=97
      printf '%s\n' "could not resolve active image paths in $fail_preset for the injected pacman-hook fixture." >"$log"
      return
    fi
    fail_image=${NV_TEST_IMAGES[0]:-}
    if [[ -z $fail_image ]]; then
      last_status=97
      printf '%s\n' "no active output image found in $fail_preset for the injected pacman-hook fixture." >"$log"
      return
    fi
    overrides+=("GOOARCHY_TEST_PACMAN_HOOK_FAIL_IMAGE=$fail_image")
  fi
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
  local fail_image
  local -a overrides=("GOOARCHY_TEST_CAPTURE_ARCH_UPGRADE=1")
  [[ $hook_fail_preset == - ]] || overrides+=("GOOARCHY_TEST_ARCH_UPGRADE_HOOK_FAIL_PRESET=$hook_fail_preset")
  [[ $failpoint == - ]] || overrides+=("GOOARCHY_TEST_NVIDIA_FAIL=$failpoint")
  if [[ $hook_fail_preset != - ]]; then
    if ! preset_images "/etc/mkinitcpio.d/$hook_fail_preset.preset"; then
      last_status=97
      printf '%s\n' "could not resolve active image paths in /etc/mkinitcpio.d/$hook_fail_preset.preset for the Arch-upgrade hook fixture." >"$log"
      return
    fi
    fail_image=${NV_TEST_IMAGES[0]:-}
    if [[ -z $fail_image ]]; then
      last_status=97
      printf '%s\n' "no active output image found in /etc/mkinitcpio.d/$hook_fail_preset.preset for the Arch-upgrade hook fixture." >"$log"
      return
    fi
    overrides+=("GOOARCHY_TEST_PACMAN_HOOK_FAIL_IMAGE=$fail_image")
  fi
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
  local preset=$1 line lhs value body= operator tail found=0 reading=0 closed=0 invalid=0 entry suffix key matches appended entry_image_count
  local -a entries=()
  local -A seen=() seen_entries=()
  NV_TEST_IMAGES=()
  NV_TEST_PRESET_ENTRIES=()
  NV_TEST_IMAGE_ENTRIES=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    if ((reading == 0)); then
      if [[ $line =~ ^[[:space:]]*PRESETS[[:space:]]*(\+?=) ]]; then
        operator=${BASH_REMATCH[1]}
        ((found += 1))
        if [[ $operator != '=' || $found > 1 ]]; then invalid=1; break; fi
        body=${line#*=}
        reading=1
      else
        continue
      fi
    else
      body+=" $line"
    fi
    if ((reading)) && [[ $body == *')'* ]]; then
      closed=1
      reading=0
      tail=${body#*)}
      tail=${tail#"${tail%%[![:space:]]*}"}
      [[ -z $tail ]] || { invalid=1; break; }
    fi
  done <"$preset"
  ((invalid == 0 && found == 1 && closed && reading == 0)) || return 1
  body=${body#"${body%%[![:space:]]*}"}
  [[ ${body:0:1} == '(' ]] || return 1
  body=${body:1}
  body=${body%)}
  [[ $body != *'$'* && $body != *'`'* && $body != *';'* && $body != *'('* && $body != *')'* ]] || return 1
  read -r -a entries <<<"$body"
  ((${#entries[@]} > 0)) || return 1
  for entry in "${entries[@]}"; do
    case $entry in
      \'*\') entry=${entry:1:${#entry}-2} ;;
      \"*\") entry=${entry:1:${#entry}-2} ;;
    esac
    [[ $entry =~ ^[[:alnum:]_.+-]+$ ]] || return 1
    [[ ! ${seen_entries[$entry]:-} ]] || return 1
    seen_entries[$entry]=1
    entry_image_count=0
    NV_TEST_PRESET_ENTRIES+=("$entry")
    for suffix in image uki; do
      key=${entry}_${suffix}
      value= matches=0 appended=0
      while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}
        [[ $line == *=* ]] || continue
        lhs=${line%%=*}
        lhs=${lhs#"${lhs%%[![:space:]]*}"}
        lhs=${lhs%"${lhs##*[![:space:]]}"}
        if [[ $lhs == "$key+" ]]; then appended=1; continue; fi
        [[ $lhs == "$key" ]] || continue
        ((matches += 1))
        value=${line#*=}
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        value=${value#\"}; value=${value%\"}
        value=${value#\'}; value=${value%\'}
        :
      done <"$preset"
      ((appended == 0 && matches <= 1)) || return 1
      [[ -n $value ]] || continue
      [[ $value != *'$'* && $value != *'`'* ]] || return 1
      [[ ! ${seen[$value]:-} ]] || return 1
      seen[$value]=1
      NV_TEST_IMAGES+=("$value")
      NV_TEST_IMAGE_ENTRIES+=("$entry")
      ((entry_image_count += 1))
    done
    ((entry_image_count > 0)) || return 1
  done
  ((${#NV_TEST_IMAGES[@]} > 0))
}

image_modules() {
  local image=$1 tmp
  tmp=$(mktemp -d "$test_root/image.XXXXXXXX") || return 1
  if ! (cd "$tmp" && sudo lsinitcpio -x "$image" >/dev/null 2>&1); then
    sudo rm -rf "$tmp"
    return 1
  fi
  sudo find "$tmp" -type f \
    \( -name 'nvidia.ko*' -o -name 'nvidia_modeset.ko*' -o -name 'nvidia_uvm.ko*' -o -name 'nvidia_drm.ko*' \
       -o -name 'nvidia-modeset.ko*' -o -name 'nvidia-uvm.ko*' -o -name 'nvidia-drm.ko*' \) \
    -printf '%f\n' |
    sed -E 's/\.ko.*$//; s/-/_/g' | sort -u
  sudo rm -rf "$tmp"
}

check_image_versions_and_firmware() {
  local image=$1 expected=$2 tmp file version firmware firmware_path
  tmp=$(mktemp -d "$test_root/image-check.XXXXXXXX") || return 1
  if ! (cd "$tmp" && sudo lsinitcpio -x "$image" >/dev/null 2>&1); then
    sudo rm -rf "$tmp"
    return 1
  fi
  while IFS= read -r -d '' file; do
    version=$(sudo modinfo -F version "$file" 2>/dev/null || true)
    if [[ $version != "$expected" ]]; then sudo rm -rf "$tmp"; return 1; fi
    [[ ${file##*/} == nvidia.ko* ]] || continue
    while IFS= read -r firmware; do
      [[ -n $firmware ]] || continue
      firmware_path=$(sudo find "$tmp" -type f \
        \( -path "*/firmware/$firmware" -o -path "*/firmware/$firmware.zst" -o -path "*/firmware/$firmware.xz" \) \
        -print -quit)
      [[ -n $firmware_path ]] || { sudo rm -rf "$tmp"; return 1; }
    done < <(sudo modinfo -F firmware "$file" 2>/dev/null || true)
  done < <(sudo find "$tmp" -type f \
    \( -name 'nvidia.ko*' -o -name 'nvidia_modeset.ko*' -o -name 'nvidia_uvm.ko*' -o -name 'nvidia_drm.ko*' \
       -o -name 'nvidia-modeset.ko*' -o -name 'nvidia-uvm.ko*' -o -name 'nvidia-drm.ko*' \) \
    -print0)
  sudo rm -rf "$tmp"
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
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do sudo sha256sum -- "$image"; done
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
  done < <(driver_module_files "/usr/lib/modules/$kernel")
  image_set_for_kernel "$pkgbase" || return 1
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    sudo test -f "$image" && sudo lsinitcpio "$image" >/dev/null 2>&1 || return 1
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
          image_hash=$(sudo sha256sum -- "$image" | awk '{print $1}') || exit 1
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
        actual_hash=$(sudo sha256sum -- "$path" | awk '{print $1}') || return 1
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
      image_set_for_kernel "$pkgbase" || {
        fixture_refuse "R10 image inventory for $kernel" 'no resolvable preset images'
        continue
      }
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

capture_repository_pair() {
  local output=$test_root/nvidia-repository-pair.txt repo
  {
    printf 'Configured repositories:\n'
    pacman-conf --repo-list
    while IFS= read -r repo; do
      [[ -n $repo ]] || continue
      printf '\n[%s] Server and CacheServer:\n' "$repo"
      pacman-conf --repo "$repo" Server 2>/dev/null || true
      pacman-conf --repo "$repo" CacheServer 2>/dev/null || true
    done < <(pacman-conf --repo-list)
    printf '\nRepository package records:\n'
    pacman -Si extra/nvidia-utils 2>&1 || true
    pacman -Si extra/nvidia-open-dkms 2>&1 || true
    printf '\nInstalled NVIDIA package records:\n'
    pacman -Q nvidia-utils nvidia-open-dkms 2>&1 || true
    if [[ -s $test_root/nvidia-archive-pair.tsv ]]; then
      printf '\nVerified older Archive pair and hashes:\n'
      cat "$test_root/nvidia-archive-pair.tsv"
    fi
  } | python3 -c 'import re,sys; s=sys.stdin.read(); s=re.sub(r"(?i)(https?://)[^/\s@]+@", r"\1[REDACTED]@", s); s=re.sub(r"(?i)([?&](?:access_token|token|password|passwd|secret|key|signature|sig|credential|auth)=)[^&\s]+", r"\1[REDACTED]", s); sys.stdout.write(s)' >"$output"
}

preflight() {
  verify_repository_driver_pair || { capture_repository_pair; return 75; }
  if ! ensure_archive_pair; then
    capture_repository_pair
    fixture_refuse 'NVIDIA older Archive package pair' \
      'could not download and verify an older matching nvidia-utils/nvidia-open-dkms pair'
    return 75
  fi
  capture_repository_pair
  fixture_event READY 'NVIDIA older Archive package pair' \
    "nvidia-utils/nvidia-open-dkms $(pacman -Qp "$old_utils_package" | awk '{print $2}'); SHA256s in $test_root/nvidia-archive-pair.tsv"
  printf 'Repository and Archive evidence: %s\n' "$test_root/nvidia-repository-pair.txt"
}

test_r15_precommit_failure() {
  local row=$1 failure name packages_before etc_before boot_before modules_before status ok=0
  case $row in
    precommit-download) failure=pacman:before-commit; name=download ;;
    precommit-space) failure=space; name=space ;;
    *) echo "unknown pre-commit R15 row: $row" >&2; return 2 ;;
  esac
  packages_before=$(package_manifest)
  etc_before=$(tree_hash /etc)
  boot_before=$(tree_hash /boot)
  modules_before=$(tree_hash /usr/lib/modules)
  run_nvidia_step "r15-precommit-$name" "$supported" "$failure"
  status=$last_status
  if [[ $status != 0 && $packages_before == "$(package_manifest)" &&
        $etc_before == "$(tree_hash /etc)" && $boot_before == "$(tree_hash /boot)" &&
        $modules_before == "$(tree_hash /usr/lib/modules)" ]]; then
    ok=1
  fi
  record "R15 $name fails before package, module, configuration, or image change" "$ok" "status $status"
  hold_r15_failure_row "$row"
}

preinstall() {
  local packages_before etc_before boot_before reports_before status
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

  if [[ ${GOOARCHY_VM_NVIDIA_SKIP_R15_ROWS:-} != 1 ]]; then
    test_r15_precommit_failure precommit-download
    test_r15_precommit_failure precommit-space
  fi

  unit_states >"$test_root/units-before-nvidia-utils.txt"
  sudo pacman -S --noconfirm --asexplicit nvidia-utils
  unit_states >"$test_root/units-after-nvidia-utils-transaction.txt"
  package_manifest >"$test_root/packages-after-nvidia-utils.txt"
  pacman -Q nvidia-utils >"$test_root/nvidia-utils-version-before-full-install.txt"
  fixture_event READY 'R13 package-state fixture' 'package and unit state snapshots captured around the nvidia-utils transaction'
}

postinstall() {
  local before_packages before_etc before_boot before_reports after_units before_units unit
  local source_hash status output unit_before unit_after
  verify_repository_driver_pair || return 1
  check_covered_kernels

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
  before_packages=$(package_manifest)
  before_etc=$(tree_hash /etc)
  before_boot=$(tree_hash /boot)
  run_nvidia_step r14-dual-gpu "$dual_gpu" -
  record 'R14 built-in boot GPU leaves selection to desktop' "$([[ $last_status == 0 && $(grep -c 'built-in GPU is the boot GPU' "$test_root/r14-dual-gpu.log") -eq 1 && $before_packages == "$(package_manifest)" && $before_etc == "$(tree_hash /etc)" && $before_boot == "$(tree_hash /boot)" ]] && echo 1 || echo 0)" 'no GPU-selection configuration written'

  if ensure_archive_pair; then
    fixture_event READY 'R8/R15a older Archive package pair' \
      "nvidia-utils/nvidia-open-dkms $(pacman -Qp "$old_utils_package" | awk '{print $2}'); SHA256s recorded in $test_root"
  else
    fixture_refuse 'R8/R15a older Archive package pair' \
      'no older matching official package pair could be fetched and verified'
  fi

  test_foreign_owned_file
  test_user_full_list
  test_dynamic_full_list
  test_pre_enabled_units
  test_custom_preset
  test_mixed_preset_selected_entry_regeneration
  test_r17_header_repair
  test_user_partial_kernels
  test_foreign_driver
  test_held_driver
  test_r13_full_installer_systemctl_trace

  if [[ ${GOOARCHY_VM_NVIDIA_SKIP_R15_ROWS:-} != 1 ]]; then
    test_r15_linux_gooarchy_dkms_failure
    test_pacman_hook_failure_with_partial_kernel
    test_prebuilt_replacement
    test_r15_step_regeneration_after_successful_arch_upgrade
    test_r15a_stale_baseline
    test_r15a_arch_upgrade_hook
    test_r15_interrupted_after_commit
  fi

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
  local kernel module_version units_before units_after packages_before etc_before boot_before
  local image image_ok=1 module status
  local -a required=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
  verify_repository_driver_pair || return 1
  kernel=$(kernel_for_pkgbase linux 2>/dev/null || true)
  if [[ -z $kernel ]]; then
    fixture_refuse 'R18 reference kernel fixture' 'linux module tree missing'
    return 75
  fi
  fixture_event READY 'R18 reference kernel fixture' \
    "linux $kernel is available; other installed kernel state remains in the idempotence comparison"
  units_before=$(unit_states)
  run_nvidia_step r18-reference-bootstrap "$supported" -
  status=$last_status
  if ((status != 0)); then
    record 'R18 installer establishes the reference state' 0 "installer status $status"
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
      fixture_refuse 'R10 static all-four user-config fixture' "$owned is not Gooarchy-owned"
      return 75
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
      fixture_refuse 'R10 dynamic all-four user-config fixture' "$owned is not Gooarchy-owned"
      return 75
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
    fixture_refuse 'R13 pre-enabled unit fixture' 'nvidia-suspend.service could not be enabled in the disposable guest'
    return 75
  fi
  fixture_event READY 'R13 pre-enabled unit fixture' 'nvidia-suspend.service enabled before installer rerun'
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
  [[ -f $owned ]] || { fixture_refuse 'R16 owned-path fixture' "$owned missing"; return 75; }
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
  local fallback_config=$test_root/r11-fallback-config.conf
  local before_images after_images before_etc before_packages preset_hash config_hash hook_seen=0 report_seen=0 fallback_report_seen=0 rerun_report_seen=0
  local image image_ok=1 module_version modules status disabled_image=$test_root/inactive-fallback.img
  local entry entry_index=0 first_entry= second_entry=
  local -a active_entries=()
  if [[ ! -f $preset ]]; then fixture_refuse 'R11 custom-preset fixture' "$preset missing"; return 75; fi
  if ! grep -Eq '^[[:space:]]*MODULES[[:space:]]*=[[:space:]]*\(\)[[:space:]]*$' /etc/mkinitcpio.conf; then
    fixture_refuse 'R11 custom-preset fixture' '/etc/mkinitcpio.conf must begin with MODULES=()'
    return 75
  fi
  sudo cp -a "$preset" "$saved"
  sudo cp -a "$preset" "$test_copy"
  preset_images "$test_copy" || {
    sudo mv "$saved" "$preset"
    fixture_refuse 'R11 custom-preset fixture' 'could not parse literal active entries and output paths'
    return 75
  }
  active_entries=("${NV_TEST_PRESET_ENTRIES[@]}")
  first_entry=${active_entries[0]}
  second_entry=${active_entries[1]:-}
  if [[ -n $second_entry ]]; then sudo cp /etc/mkinitcpio.conf "$fallback_config"; fi
  for entry in "${active_entries[@]}"; do
    if ((entry_index == 0)); then
      printf '\n%s_config="/etc/mkinitcpio.conf"\n' "$entry" | sudo tee -a "$test_copy" >/dev/null
    else
      printf '\n%s_config="%s"\n' "$entry" "$fallback_config" | sudo tee -a "$test_copy" >/dev/null
    fi
    ((entry_index += 1))
  done
  printf '\ngooarchy_inactive_image="%s"\n' "$disabled_image" | sudo tee -a "$test_copy" >/dev/null
  sudo cp "$test_copy" "$preset"
  preset_images "$preset" || { sudo mv "$saved" "$preset"; fixture_refuse 'R11 custom-preset fixture' 'could not parse the prepared preset'; return 75; }
  record 'R11 inactive preset image path is excluded from the active image set' \
    "$([[ ${#NV_TEST_IMAGES[@]} -gt 0 ]] && ! printf '%s\n' "${NV_TEST_IMAGES[@]}" | grep -Fxq "$disabled_image" && echo 1 || echo 0)" \
    "active entries ${active_entries[*]}; inactive path $disabled_image ignored"
  preset_hash=$(sha256sum "$preset" | awk '{print $1}')
  config_hash=$(sha256sum /etc/mkinitcpio.conf | awk '{print $1}')
  before_etc=$(tree_hash /etc)
  before_packages=$(package_manifest)
  run_nvidia_step r11-custom-config-pacman-hook "$supported" pacman:force-transaction
  status=$last_status
  grep -Fq "Building image from preset: $preset" "$test_root/r11-custom-config-pacman-hook.log" && hook_seen=1
  grep -Fq "$first_entry image in linux.preset reads /etc/mkinitcpio.conf directly" "$test_root/r11-custom-config-pacman-hook.log" && report_seen=1
  if [[ -n $second_entry ]]; then
    grep -Fq "$second_entry image in linux.preset reads $fallback_config directly" "$test_root/r11-custom-config-pacman-hook.log" && fallback_report_seen=1
  else
    fallback_report_seen=1
  fi
  module_version=$(module_version_from_package "$(pacman -Q nvidia-utils | awk '{print $2}')")
  for image in "${NV_TEST_IMAGES[@]}"; do
    sudo lsinitcpio "$image" >/dev/null 2>&1 || image_ok=0
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
  record 'R11 active fallback entry uses its own configuration' \
    "$([[ $status == 0 && $fallback_report_seen == 1 ]] && echo 1 || echo 0)" \
    "$preset; ${second_entry:-single active entry}; ${fallback_config}"

  before_images=$(sudo sha256sum -- "${NV_TEST_IMAGES[@]}")
  before_etc=$(tree_hash /etc)
  before_packages=$(package_manifest)
  run_nvidia_step r11-custom-config "$supported" -
  after_images=$(sudo sha256sum -- "${NV_TEST_IMAGES[@]}")
  record 'R11 bypassed drop-in is left alone, reported, and unchanged on rerun' \
    "$([[ $last_status == 0 && $before_images == "$after_images" && $before_etc == "$(tree_hash /etc)" && $before_packages == "$(package_manifest)" && $preset_hash == "$(sha256sum "$preset" | awk '{print $1}')" && $config_hash == "$(sha256sum /etc/mkinitcpio.conf | awk '{print $1}')" ]] && echo 1 || echo 0)" \
    "$preset; no package transaction on rerun"
  grep -Fq "$first_entry image in linux.preset reads /etc/mkinitcpio.conf directly" "$test_root/r11-custom-config.log" && rerun_report_seen=1
  record 'R11 rerun reports missing early KMS for the named preset' \
    "$([[ $last_status == 0 && $rerun_report_seen == 1 ]] && echo 1 || echo 0)" "$preset"
  sudo mv "$saved" "$preset"
  sudo rm -f "$fallback_config"
  run_nvidia_step r11-restore-default "$supported" -
  record 'R17 rerun after removing the R11 test preset converges to the stock preset' \
    "$([[ $last_status == 0 ]] && echo 1 || echo 0)" 'stock preset and its output images restored by the installer'
}

restore_mixed_preset_fixture() {
  local status=0
  if [[ -f $test_root/linux.preset.mixed.saved ]]; then
    sudo mv -f "$test_root/linux.preset.mixed.saved" /etc/mkinitcpio.d/linux.preset || status=1
  fi
  if [[ -f $test_root/r11-mixed-images.tsv ]]; then
    restore_kernel_images r11-mixed || status=1
  fi
  remove_r11_mixed_synthetic_image || status=1
  if ((status == 0)); then
    rm -f "$test_root/r11-mixed-images.tsv"
    rm -f "$test_root/linux.preset.mixed.seed"
    sudo rm -f "$test_root"/r11-mixed-image-*.img || status=1
    sudo rm -f "$r11_config"
  fi
  return "$status"
}

remove_r11_mixed_synthetic_image() {
  local marker=$test_root/r11-mixed-synthetic-image.path image expected
  [[ -f $marker ]] || return 0
  image=$(<"$marker")
  expected=/boot/.gooarchy-nvidia-r11-${test_stamp}.img
  [[ $image == "$expected" && ! -L $image ]] || return 1
  if [[ -f $image ]]; then
    sudo rm -f -- "$image" || return 1
  elif [[ -e $image ]]; then
    return 1
  fi
  rm -f "$marker"
}

test_mixed_preset_selected_entry_regeneration() {
  local preset=/etc/mkinitcpio.d/linux.preset saved=$test_root/linux.preset.mixed.saved
  local test_copy=$test_root/linux.preset.mixed seed_preset=$test_root/linux.preset.mixed.seed
  local base_preset=$saved empty_config=$r11_config active_pattern kernel module_version
  local preset_hash config_hash image modules status image_ok=1 first_entry entry idx
  local synthetic_entry=gooarchy_r11_test_${test_stamp}
  local synthetic_image=/boot/.gooarchy-nvidia-r11-${test_stamp}.img
  local first_after= other_images_ok=1 other_changed=1 image_hash
  local -a active_entries=() other_entries=() first_images=() other_images=() first_hashes=() other_hashes=()
  if [[ ! -f $preset ]]; then
    fixture_refuse 'R11 mixed-preset fixture' "$preset missing"
    return 75
  fi
  if ! kernel=$(kernel_for_pkgbase linux 2>/dev/null || true) || [[ -z $kernel ]]; then
    fixture_refuse 'R11 mixed-preset fixture' 'linux kernel modules missing'
    return 75
  fi
  sudo cp -a "$preset" "$saved"
  if ! preset_images "$saved"; then
    sudo mv -f "$saved" "$preset"
    fixture_refuse 'R11 mixed-preset fixture' 'could not parse the stock preset'
    return 75
  fi
  active_entries=("${NV_TEST_PRESET_ENTRIES[@]}")
  if ((${#active_entries[@]} < 2)); then
    if [[ -e $synthetic_image || -L $synthetic_image ]]; then
      sudo mv -f "$saved" "$preset"
      fixture_refuse 'R11 mixed-preset fixture' "$synthetic_image already exists; left it untouched"
      return 75
    fi
    awk -v first="${active_entries[0]}" -v second="$synthetic_entry" '
      BEGIN { replaced=0 }
      /^[[:space:]]*PRESETS[[:space:]]*=[[:space:]]*\([^)]*\)[[:space:]]*$/ && !replaced {
        printf "PRESETS=(%s %s)\n", first, second
        replaced=1
        next
      }
      { print }
      END { if (!replaced) exit 1 }
    ' "$saved" >"$seed_preset" || {
      sudo mv -f "$saved" "$preset"
      fixture_refuse 'R11 mixed-preset fixture' 'could not seed a second literal active preset entry'
      return 75
    }
    printf '%s_image="%s"\n' "$synthetic_entry" "$synthetic_image" >>"$seed_preset"
    if ! sudo cp "$seed_preset" "$preset" || ! preset_images "$preset"; then
      if restore_mixed_preset_fixture; then
        fixture_event CLEANUP-OK 'R11 mixed-preset setup refusal' 'original preset restored'
      else
        fixture_event CLEANUP-FAIL 'R11 mixed-preset setup refusal' 'could not restore the original preset'
      fi
      fixture_refuse 'R11 mixed-preset fixture' 'could not activate the seeded second preset entry'
      return 75
    fi
    if [[ -e $synthetic_image || -L $synthetic_image ]]; then
      restore_mixed_preset_fixture || true
      fixture_refuse 'R11 mixed-preset fixture' "$synthetic_image appeared during fixture setup; left it untouched"
      return 75
    fi
    printf '%s\n' "$synthetic_image" >"$test_root/r11-mixed-synthetic-image.path"
    if ! sudo cp -a -- "${NV_TEST_IMAGES[0]}" "$synthetic_image"; then
      if restore_mixed_preset_fixture; then
        fixture_event CLEANUP-OK 'R11 mixed-preset setup refusal' 'original preset restored and synthetic image removed'
      else
        fixture_event CLEANUP-FAIL 'R11 mixed-preset setup refusal' 'could not restore the preset or remove the synthetic image'
      fi
      fixture_refuse 'R11 mixed-preset fixture' 'could not create the second listable image fixture'
      return 75
    fi
    base_preset=$seed_preset
    active_entries=("${NV_TEST_PRESET_ENTRIES[@]}")
  fi
  if ! save_kernel_images linux r11-mixed; then
    restore_mixed_preset_fixture || true
    fixture_refuse 'R11 mixed-preset fixture' 'could not save the stock images'
    return 75
  fi
  first_entry=${active_entries[0]}
  other_entries=("${active_entries[@]:1}")
  active_pattern=$(IFS='|'; printf '%s' "${active_entries[*]}")
  awk -v first="$first_entry" -v entries="$active_pattern" -v config="$empty_config" '
    {
      key=$0
      sub(/=.*/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key == "ALL_config" || key ~ "^(" entries ")_config$") next
      print
    }
    END { print first "_config=\"" config "\"" }
  ' "$base_preset" >"$test_copy" || {
    if restore_mixed_preset_fixture; then
      fixture_event CLEANUP-OK 'R11 mixed-preset setup refusal' 'original preset and images restored'
    else
      fixture_event CLEANUP-FAIL 'R11 mixed-preset setup refusal' 'could not restore the preset and saved images'
    fi
    fixture_refuse 'R11 mixed-preset fixture' 'could not prepare the mixed preset'
    return 75
  }
  sudo cp "$test_copy" "$preset"
  if ! preset_images "$preset"; then
    if restore_mixed_preset_fixture; then
      fixture_event CLEANUP-OK 'R11 mixed-preset setup refusal' 'original preset and images restored'
    else
      fixture_event CLEANUP-FAIL 'R11 mixed-preset setup refusal' 'could not restore the preset and saved images'
    fi
    fixture_refuse 'R11 mixed-preset fixture' 'mixed preset did not parse'
    return 75
  fi
  sudo cp /etc/mkinitcpio.conf "$empty_config"
  if ! grep -Eq '^[[:space:]]*MODULES[[:space:]]*=[[:space:]]*\(\)[[:space:]]*$' "$empty_config"; then
    if restore_mixed_preset_fixture; then
      fixture_event CLEANUP-OK 'R11 mixed-preset setup refusal' 'original preset and images restored'
    else
      fixture_event CLEANUP-FAIL 'R11 mixed-preset setup refusal' 'could not restore the preset and saved images'
    fi
    fixture_refuse 'R11 mixed-preset fixture' 'default mkinitcpio MODULES setting is not empty'
    return 75
  fi
  for idx in "${!NV_TEST_IMAGES[@]}"; do
    image=${NV_TEST_IMAGES[$idx]}
    entry=${NV_TEST_IMAGE_ENTRIES[$idx]}
    if ! sudo mkinitcpio -k "$kernel" -g "$image" -c "$empty_config" \
      >"$test_root/r11-mixed-prepare.log" 2>&1; then
      image_ok=0
      break
    fi
    sudo lsinitcpio "$image" >/dev/null 2>&1 || image_ok=0
    modules=$(image_modules "$image" 2>/dev/null) || image_ok=0
    [[ -z $modules ]] || image_ok=0
    if [[ $entry == "$first_entry" ]]; then first_images+=("$image"); else other_images+=("$image"); fi
  done
  if ((image_ok == 0)) || ((${#first_images[@]} == 0 || ${#other_images[@]} == 0)); then
    if restore_mixed_preset_fixture; then
      fixture_event CLEANUP-OK 'R11 mixed-preset setup refusal' 'original preset and images restored'
    else
      fixture_event CLEANUP-FAIL 'R11 mixed-preset setup refusal' 'could not restore the preset and saved images'
    fi
    fixture_refuse 'R11 mixed-preset fixture' 'could not prepare listable module-free images for both entry classes'
    return 75
  fi
  for image in "${first_images[@]}"; do first_hashes+=("$(sudo sha256sum -- "$image" | awk '{print $1}')"); done
  for image in "${other_images[@]}"; do other_hashes+=("$(sudo sha256sum -- "$image" | awk '{print $1}')"); done
  preset_hash=$(sha256sum "$preset" | awk '{print $1}')
  config_hash=$(sha256sum "$empty_config" | awk '{print $1}')
  module_version=$(module_version_from_package "$(pacman -Q nvidia-utils | awk '{print $2}')")
  run_nvidia_step r11-mixed-selected-repair "$supported" -
  status=$last_status
  first_after= other_changed=1
  for idx in "${!first_images[@]}"; do
    image=${first_images[$idx]}
    image_hash=$(sudo sha256sum -- "$image" | awk '{print $1}')
    [[ $image_hash == "${first_hashes[$idx]}" ]] || first_after=changed
  done
  for idx in "${!other_images[@]}"; do
    image=${other_images[$idx]}
    image_hash=$(sudo sha256sum -- "$image" | awk '{print $1}')
    [[ $image_hash != "${other_hashes[$idx]}" ]] || other_changed=0
    image_has_modules_at_version "$image" "$module_version" nvidia nvidia_modeset nvidia_uvm nvidia_drm || other_images_ok=0
  done
  record 'R11 mixed preset repair regenerates drop-in entries and preserves direct-config images' \
    "$([[ $status == 0 && -z $first_after && $other_changed == 1 && $other_images_ok == 1 && \
          $preset_hash == "$(sha256sum "$preset" | awk '{print $1}')" && \
          $config_hash == "$(sha256sum "$empty_config" | awk '{print $1}')" ]] && echo 1 || echo 0)" \
    "$first_entry images byte-identical; ${other_entries[*]} regenerated with NVIDIA modules; preset and direct config preserved"
  if ! restore_mixed_preset_fixture; then
    fixture_event CLEANUP-FAIL 'R11 mixed-preset fixture' 'could not restore saved stock images or preset'
    return 1
  fi
  fixture_event CLEANUP-OK 'R11 mixed-preset fixture' 'stock images and preset restored'
  run_nvidia_step r11-mixed-restore-default "$supported" -
  record 'R17 rerun after the mixed-preset case returns to the stock preset and images' \
    "$([[ $last_status == 0 ]] && echo 1 || echo 0)" 'installer rerun completed against the restored stock preset and images'
}

test_preset_assignment_edge() {
  local preset=/etc/mkinitcpio.d/linux.preset saved=$test_root/linux.preset.saved
  local variant entry key stale packages_before database_before etc_before modules_before status error_ok image_hash_ok original_hash
  local -a variants=(duplicate-presets appended-presets duplicate-image appended-image)
  if [[ ! -f $preset || -e $saved ]]; then
    fixture_refuse 'C1 preset assignment-edge fixture' 'Linux preset missing or another preset backup is active'
    return 75
  fi
  sudo cp -a "$preset" "$saved"
  original_hash=$(sha256sum "$saved" | awk '{print $1}')
  if ! preset_images "$saved"; then
    sudo mv -f "$saved" "$preset" || fixture_event CLEANUP-FAIL 'C1 preset assignment-edge fixture' 'could not restore preset after parse refusal'
    fixture_refuse 'C1 preset assignment-edge fixture' 'could not parse the original active image entries'
    return 75
  fi
  if ! c1_capture_image_inventory; then
    sudo mv -f "$saved" "$preset" || fixture_event CLEANUP-FAIL 'C1 preset assignment-edge fixture' 'could not restore preset after inventory refusal'
    fixture_refuse 'C1 preset assignment-edge fixture' 'could not build saved paths for every kernel preset'
    return 75
  fi
  if ! preset_images "$saved"; then
    sudo mv -f "$saved" "$preset" || fixture_event CLEANUP-FAIL 'C1 preset assignment-edge fixture' 'could not restore preset after parser-state refusal'
    fixture_refuse 'C1 preset assignment-edge fixture' 'could not restore the saved Linux preset parser state'
    return 75
  fi
  entry=${NV_TEST_PRESET_ENTRIES[0]:-}
  if [[ -z $entry ]]; then
    sudo mv -f "$saved" "$preset" || fixture_event CLEANUP-FAIL 'C1 preset assignment-edge fixture' 'could not restore preset after empty-entry refusal'
    fixture_refuse 'C1 preset assignment-edge fixture' 'stock preset has no active entry'
    return 75
  fi
  key=${entry}_image
  if ! awk -v key="$key" 'index($0, "#") { sub(/#.*/, "") } { lhs=$0; sub(/=.*/, "", lhs); gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs); if (lhs == key) found=1 } END { exit !found }' "$saved"; then
    key=${entry}_uki
    if ! awk -v key="$key" 'index($0, "#") { sub(/#.*/, "") } { lhs=$0; sub(/=.*/, "", lhs); gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs); if (lhs == key) found=1 } END { exit !found }' "$saved"; then
      sudo mv -f "$saved" "$preset" || fixture_event CLEANUP-FAIL 'C1 preset assignment-edge fixture' 'could not restore preset after assignment refusal'
      fixture_refuse 'C1 preset assignment-edge fixture' "active entry $entry has no literal image or UKI assignment"
      return 75
    fi
  fi
  printf 'path\n' >"$test_root/c1-stale-image-paths.tsv"

  for variant in "${variants[@]}"; do
    sudo cp -a "$saved" "$preset"
    stale=
    case $variant in
      duplicate-presets)
        printf '\nPRESETS=(%s)\n' "${NV_TEST_PRESET_ENTRIES[*]}" | sudo tee -a "$preset" >/dev/null
        ;;
      appended-presets)
        printf '\nPRESETS+=(gooarchy-c1-edge)\n' | sudo tee -a "$preset" >/dev/null
        ;;
      duplicate-image|appended-image)
        stale=${NV_TEST_IMAGES[0]}.gooarchy-c1-${test_stamp}-${variant}
        if [[ -e $stale || -L $stale ]]; then
          fixture_refuse "C1 $variant assignment-edge fixture" "$stale already exists"
          return 75
        fi
        printf '%s\n' "$stale" >>"$test_root/c1-stale-image-paths.tsv"
        if [[ $variant == duplicate-image ]]; then
          printf '\n%s="%s"\n' "$key" "$stale" | sudo tee -a "$preset" >/dev/null
        else
          printf '\n%s+="%s"\n' "$key" "$stale" | sudo tee -a "$preset" >/dev/null
        fi
        ;;
    esac
    packages_before=$(package_manifest)
    database_before=$(tree_hash /var/lib/pacman/local)
    etc_before=$(tree_hash /etc)
    modules_before=$(driver_module_hashes)
    if ! c1_hash_image_inventory >"$test_root/c1-images-before.sha256"; then
      fixture_refuse "C1 $variant assignment-edge fixture" 'active images could not all be hashed'
      return 75
    fi
    run_nvidia_step "c1-$variant" "$supported" -
    status=$last_status
    error_ok=0
    grep -Eq 'could not resolve (every image path|every active image path|active image entries)|could not resolve every image' \
      "$test_root/c1-$variant.log" && error_ok=1
    image_hash_ok=0
    if c1_hash_image_inventory >"$test_root/c1-images-after.sha256" &&
       cmp -s "$test_root/c1-images-before.sha256" "$test_root/c1-images-after.sha256"; then
      image_hash_ok=1
    fi
    record "C1 $variant assignment fails closed without package, configuration, module, or image changes" \
      "$([[ $status != 0 && $error_ok == 1 && $packages_before == "$(package_manifest)" &&
            $database_before == "$(tree_hash /var/lib/pacman/local)" && $etc_before == "$(tree_hash /etc)" &&
            $modules_before == "$(driver_module_hashes)" &&
            $image_hash_ok == 1 && ( -z $stale || ! -e $stale ) ]] && echo 1 || echo 0)" \
      "status $status; stale first-match output ${stale:-none}; fixture diagnostic and before/after hashes retained"
  done

  if ! sudo mv -f "$saved" "$preset"; then
    fixture_event CLEANUP-FAIL 'C1 preset assignment-edge fixture' 'could not restore the stock Linux preset'
    return 1
  fi
  if [[ -f $test_root/c1-stale-image-paths.tsv ]]; then
    while IFS= read -r stale; do
      [[ -n $stale && $stale != path ]] || continue
      if [[ -f $stale && ! -L $stale ]]; then sudo rm -f -- "$stale"; fi
    done <"$test_root/c1-stale-image-paths.tsv"
  fi
  if [[ $(sha256sum "$preset" | awk '{print $1}') == "$original_hash" ]]; then
    fixture_event CLEANUP-OK 'C1 preset assignment-edge fixture' 'original preset bytes restored and checked'
  else
    fixture_event CLEANUP-FAIL 'C1 preset assignment-edge fixture' 'restored preset bytes differ from the saved baseline'
    return 1
  fi
}

test_r17_header_repair() {
  local kernel pkg_version header_version module_version module image image_ok=1 status
  local -a required=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
  if ! pacman -Si linux-lts >/dev/null 2>&1; then
    fixture_refuse 'R17 linux-lts header-repair fixture' 'configured repositories do not provide linux-lts'
    return 75
  fi
  if [[ -z $(kernel_for_pkgbase linux-lts 2>/dev/null || true) ]]; then
    if ! sudo pacman -S --noconfirm --needed linux-lts; then
      fixture_refuse 'R17 linux-lts header-repair fixture' 'could not install linux-lts without headers'
      return 75
    fi
  fi
  if pacman -Q linux-lts-headers >/dev/null 2>&1; then
    sudo pacman -Rdd --noconfirm linux-lts-headers
  fi
  kernel=$(kernel_for_pkgbase linux-lts 2>/dev/null || true)
  if [[ -z $kernel ]]; then
    fixture_refuse 'R17 linux-lts header-repair fixture' 'linux-lts module tree missing after package setup'
    return 75
  fi
  fixture_event READY 'R17 linux-lts header-repair fixture' "linux-lts $kernel installed without linux-lts-headers"
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
    fixture_refuse 'R15 linux-gooarchy DKMS-failure fixture' \
      'the integrated linux-gooarchy and linux kernels are both required'
    return 75
  fi
  if [[ $(pacman -Q linux-gooarchy-headers 2>/dev/null | awk '{print $2}' || true) != \
        "$(pacman -Q linux-gooarchy 2>/dev/null | awk '{print $2}' || true)" ]]; then
    fixture_refuse 'R15 linux-gooarchy DKMS-failure fixture' \
      'linux-gooarchy-headers does not match linux-gooarchy'
    return 75
  fi
  build_link_path=/usr/lib/modules/$kernel/build
  if [[ ! -e $build_link_path && ! -L $build_link_path ]]; then
    fixture_refuse 'R15 linux-gooarchy DKMS-failure fixture' "$build_link_path is missing"
    return 75
  fi
  if [[ -e $owned ]] && ! grep -Fxq \
      '# Gooarchy NVIDIA early KMS modules; managed by the Gooarchy installer.' "$owned"; then
    fixture_refuse 'R15 linux-gooarchy DKMS-failure fixture' \
      "$owned contains user-owned content"
    return 75
  fi

  package_version=$(pacman -Q nvidia-utils | awk '{print $2}')
  module_version=$(module_version_from_package "$package_version")
  repo_version=$(repository_version extra/nvidia-utils)
  for module in "${required[@]}"; do
    [[ $(modinfo -k "$linux_kernel" -F version "$module" 2>/dev/null || true) == "$module_version" ]] ||
      linux_covered=0
  done
  image_set_for_kernel linux || linux_covered=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$module_version" "${required[@]}" || linux_covered=0
  done
  if ((linux_covered == 0)); then
    fixture_refuse 'R15 linux-gooarchy DKMS-failure fixture' 'linux baseline is not sound before failure injection'
    return 75
  fi
  fixture_event READY 'R15 linux-gooarchy DKMS-failure fixture' \
    "linux $linux_kernel; module version $module_version; matching images verified"

  : >"$test_root/driver-recovery-needed"
  printf '%s' "$build_link_path" >"$test_root/gooarchy-build-link-path"
  if ! sudo mv "$build_link_path" "$test_root/gooarchy-build-link.saved"; then
    fixture_refuse 'R15 linux-gooarchy DKMS-failure fixture' 'could not hold the build link for failure injection'
    return 75
  fi
  if ! sudo pacman -Rdd --noconfirm nvidia-open-dkms nvidia-utils; then
    fixture_refuse 'R15 linux-gooarchy DKMS-failure fixture' 'pacman could not remove the driver packages for a fresh transaction'
    if ! sudo mv "$test_root/gooarchy-build-link.saved" "$build_link_path" 2>/dev/null; then
      fixture_event CLEANUP-FAIL 'R15 linux-gooarchy DKMS-failure fixture' "$build_link_path remains missing after package removal refusal"
      return 1
    fi
    fixture_event CLEANUP-OK 'R15 linux-gooarchy DKMS-failure fixture' 'build link restored after package removal refusal'
    rm -f "$test_root/gooarchy-build-link-path"
    restore_r15a_current_state || return 1
    return 75
  fi
  for dir in /usr/lib/modules/*; do
    [[ -f $dir/pkgbase ]] || continue
    pkgbase=$(<"$dir/pkgbase")
    if ! sudo mkinitcpio -p "$pkgbase" >"$test_root/r15-fresh-image-${dir##*/}.log" 2>&1; then
      fixture_refuse 'R15 linux-gooarchy DKMS-failure fixture' "mkinitcpio failed to prepare fallback images for ${dir##*/}"
      if ! sudo mv "$test_root/gooarchy-build-link.saved" "$build_link_path" 2>/dev/null; then
        fixture_event CLEANUP-FAIL 'R15 linux-gooarchy DKMS-failure fixture' "$build_link_path remains missing after image preparation failure"
        return 1
      fi
      fixture_event CLEANUP-OK 'R15 linux-gooarchy DKMS-failure fixture' 'build link restored after image preparation failure'
      rm -f "$test_root/gooarchy-build-link-path"
      restore_r15a_current_state || return 1
      return 75
    fi
  done

  run_nvidia_step r15-linux-gooarchy-dkms-failure "$supported" "dkms:$kernel"
  status=$last_status
  package_version=$(pacman -Q nvidia-utils 2>/dev/null | awk '{print $2}' || true)
  module_version=$(module_version_from_package "$package_version")
  repo_version=$(repository_version extra/nvidia-utils || true)
  image_set_for_kernel linux-gooarchy || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    sudo lsinitcpio "$image" >/dev/null 2>&1 || image_ok=0
    check_image_versions_and_firmware "$image" "$module_version" || image_ok=0
    [[ -z $(image_modules "$image" 2>/dev/null || true) ]] || image_ok=0
  done
  while IFS= read -r -d '' file; do
    version=$(modinfo -F version "$file" 2>/dev/null || true)
    [[ $version == "$module_version" ]] || gooarchy_modules_ok=0
  done < <(driver_module_files "/usr/lib/modules/$kernel")
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
    done < <(driver_module_files "$dir")
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
      sudo lsinitcpio "$image" >/dev/null 2>&1 || other_kernels_ok=0
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
    fixture_event CLEANUP-OK 'R15 linux-gooarchy DKMS-failure fixture' 'build link restored before R17 rerun'
    rm -f "$test_root/gooarchy-build-link-path"
  else
    fixture_event CLEANUP-FAIL 'R15 linux-gooarchy DKMS-failure fixture' "$build_link_path remains missing"
    return 1
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
    fixture_refuse 'R15 after-commit fixture' "$owned is user-owned"
    return 75
  fi
  : >"$test_root/driver-recovery-needed"
  if [[ -e $owned ]]; then sudo cp -a "$owned" "$test_root/r15-interrupted-owned.saved"; fi
  sudo rm -f "$owned" "$user_config" "$dynamic_modules"
  if ! sudo pacman -Rdd --noconfirm nvidia-open-dkms nvidia-utils; then
    fixture_refuse 'R15 after-commit fixture' 'pacman could not remove driver packages before fixture preparation'
    return 75
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
      sudo lsinitcpio "$image" >/dev/null 2>&1 || images_ok=0
      modules=$(image_modules "$image" 2>/dev/null || true)
      [[ -z $modules ]] || images_ok=0
    done
  done
  if ((status != 0 || images_ok == 0)); then
    fixture_refuse 'R15 after-commit fixture' 'fallback images are not listable and module-free'
    return 75
  fi
  fixture_event READY 'R15 after-commit fixture' 'driver packages removed; every kernel image listable without NVIDIA modules'
  if ! capture_all_kernel_image_hashes >"$image_hashes_before"; then
    fixture_refuse 'R15 after-commit fixture' 'could not hash every image before the package transaction'
    return 75
  fi

  run_nvidia_step r15-interrupted-after-commit "$supported" interrupt:after-commit
  status=$last_status
  if ! capture_all_kernel_image_hashes >"$image_hashes_after"; then image_hashes_ok=0; fi
  if ! cmp -s "$image_hashes_before" "$image_hashes_after"; then
    diff -u "$image_hashes_before" "$image_hashes_after" \
      >"$test_root/r15-after-commit-image-hash-diff.txt" || true
  fi
  fixture_event "$([[ $image_hashes_ok == 1 ]] && echo OBSERVED || echo UNAVAILABLE)" \
    'R15 after-commit image hash measurements' \
    "before=$image_hashes_before after=$image_hashes_after; differences retained for diagnosis"
  package_version=$(pacman -Q nvidia-utils 2>/dev/null | awk '{print $2}' || true)
  module_version=$(module_version_from_package "$package_version")
  repo_utils=$(repository_version extra/nvidia-utils || true)
  repo_dkms=$(repository_version extra/nvidia-open-dkms || true)
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
      sudo lsinitcpio "$image" >/dev/null 2>&1 || images_ok=0
      check_image_versions_and_firmware "$image" "$module_version" || images_ok=0
      modules=$(image_modules "$image" 2>/dev/null || true)
      [[ -z $modules ]] || images_ok=0
    done
  done
  record 'R15 interruption after commit leaves every kernel covered with listable fallback images' \
    "$([[ $status != 0 && $report_ok == 1 && $modules_ok == 1 && $images_ok == 1 ]] && echo 1 || echo 0)" \
    "nvidia-utils $package_version; transaction committed; owned early-KMS file and step image setup not reached"
  hold_r15_failure_row interrupt-after-commit

  if [[ -f $test_root/r15-interrupted-owned.saved ]]; then
    sudo mv -f "$test_root/r15-interrupted-owned.saved" "$owned"
  fi
  if restore_r15a_current_state; then
    fixture_event CLEANUP-OK 'R15 after-commit fixture' 'current packages, DKMS modules and images restored'
  else
    fixture_event CLEANUP-FAIL 'R15 after-commit fixture' 'package and image cleanup recovery failed'
    return 1
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

c1_capture_image_inventory() {
  local preset source image
  : >"$test_root/c1-image-paths.tsv"
  for preset in /etc/mkinitcpio.d/*.preset; do
    [[ -f $preset ]] || continue
    source=$preset
    [[ ${preset##*/} == linux.preset ]] && source=$test_root/linux.preset.saved
    preset_images "$source" || return 1
    for image in "${NV_TEST_IMAGES[@]}"; do printf '%s\n' "$image" >>"$test_root/c1-image-paths.tsv"; done
  done
  [[ -s $test_root/c1-image-paths.tsv ]]
}

c1_hash_image_inventory() {
  local image
  while IFS= read -r image; do
    [[ -f $image ]] || return 1
    sudo sha256sum -- "$image" || return 1
  done <"$test_root/c1-image-paths.tsv"
}

focused_installed_size_kb() {
  local output
  output=$(LC_ALL=C pacman -Si "$1" 2>/dev/null) || return 1
  awk -F: '
    $1 ~ /^[[:space:]]*Installed Size[[:space:]]*$/ {
      value=$2
      sub(/^[[:space:]]+/, "", value)
      split(value, part, /[[:space:]]+/)
      amount=part[1]+0
      unit=part[2]
      if (unit ~ /^KiB/) print int(amount)
      else if (unit ~ /^MiB/) print int(amount*1024)
      else if (unit ~ /^GiB/) print int(amount*1024*1024)
      else if (unit ~ /^B/) print int(amount/1024)
      exit
    }
  ' <<<"$output"
}

prepare_bounded_disk_pressure() {
  local cap=${GOOARCHY_VM_NVIDIA_PRESSURE_MAX_KB:-4194304} utils_growth dkms_growth growth
  local margin_kb=131072 total_kb=0 preset image filesystem available size required allocated path identity after index=0
  local -A required_by_fs=() available_by_fs=() directory_by_fs=() allocated_by_fs=()
  local -a filesystems=()
  [[ $cap =~ ^[0-9]+$ ]] && ((cap > 0 && cap <= 4194304)) || {
    fixture_refuse 'C2 bounded disk-pressure setup' 'cap must be 1..4194304 KiB'
    return 75
  }
  utils_growth=$(focused_installed_size_kb extra/nvidia-utils) || utils_growth=
  dkms_growth=$(focused_installed_size_kb extra/nvidia-open-dkms) || dkms_growth=
  [[ $utils_growth =~ ^[0-9]+$ && $dkms_growth =~ ^[0-9]+$ ]] || {
    fixture_refuse 'C2 bounded disk-pressure setup' 'configured repositories did not report both package installed sizes'
    return 75
  }
  growth=$((utils_growth + dkms_growth))
  ((growth >= 131072)) || growth=131072

  for preset in /etc/mkinitcpio.d/*.preset; do
    [[ -f $preset ]] || continue
    if ! preset_images "$preset"; then
      fixture_refuse 'C2 bounded disk-pressure setup' "could not resolve active image inventory from $preset"
      return 75
    fi
    for image in "${NV_TEST_IMAGES[@]}"; do
      [[ -f $image && $image != *$'\t'* && $image != *$'\n'* ]] || {
        fixture_refuse 'C2 bounded disk-pressure setup' "active image is missing or not safely representable: $image"
        return 75
      }
      read -r filesystem available < <(df -k --output=source,avail -- "$image" | awk 'NR == 2 { print $1, $2 }')
      [[ -n $filesystem && $available =~ ^[0-9]+$ ]] || {
        fixture_refuse 'C2 bounded disk-pressure setup' "could not measure filesystem capacity for $image"
        return 75
      }
      size=$(sudo stat -c %s -- "$image") || {
        fixture_refuse 'C2 bounded disk-pressure setup' "could not read image size for $image"
        return 75
      }
      required=$(((size + 1023) / 1024 + growth + 16 * 1024))
      if [[ ! ${required_by_fs[$filesystem]+present} ]]; then
        filesystems+=("$filesystem")
        required_by_fs[$filesystem]=0
        available_by_fs[$filesystem]=$available
        directory_by_fs[$filesystem]=$(dirname -- "$image")
      elif ((available < available_by_fs[$filesystem])); then
        available_by_fs[$filesystem]=$available
      fi
      required_by_fs[$filesystem]=$((required_by_fs[$filesystem] + required))
    done
  done
  ((${#filesystems[@]} > 0)) || {
    fixture_refuse 'C2 bounded disk-pressure setup' 'no active images found across installed kernel presets'
    return 75
  }

  for filesystem in "${filesystems[@]}"; do
    available=${available_by_fs[$filesystem]}
    required=${required_by_fs[$filesystem]}
    if ((available < required)); then
      fixture_refuse 'C2 bounded disk-pressure setup' \
        "$filesystem has ${available} KiB; fixture requires ${required} KiB plus boot and cleanup reserve"
      return 75
    fi
    allocated=0
    if ((available > required + margin_kb)); then
      allocated=$((available - required - margin_kb))
    fi
    allocated_by_fs[$filesystem]=$allocated
    total_kb=$((total_kb + allocated))
  done
  if ((total_kb > cap)); then
    fixture_refuse 'C2 bounded disk-pressure setup' \
      "would need ${total_kb} KiB; bounded fixture cap is ${cap} KiB"
    return 75
  fi

  : >"$test_root/r15-bounded-pressure.tsv"
  : >"$test_root/r15-bounded-pressure-owned.tsv"
  printf 'filesystem\tavailable-before-kb\trequired-kb\tallocated-kb\tavailable-after-kb\tfile\tdevice\tinode\tsafety-margin-kb\n' \
    >"$test_root/r15-bounded-pressure.tsv"
  for filesystem in "${filesystems[@]}"; do
    available=${available_by_fs[$filesystem]}
    required=${required_by_fs[$filesystem]}
    allocated=${allocated_by_fs[$filesystem]}
    path=${directory_by_fs[$filesystem]}/.gooarchy-nvidia-pressure-${test_stamp}-${index}
    ((index += 1))
    if [[ -e $path || -L $path ]]; then
      cleanup_bounded_pressure || true
      fixture_refuse 'C2 bounded disk-pressure setup' "test-owned pressure path already exists: $path"
      return 75
    fi
    if ((allocated > 0)); then
      if ! sudo install -m 0600 /dev/null "$path"; then
        if [[ -f $path && ! -L $path ]]; then sudo rm -f -- "$path" 2>/dev/null || true; fi
        cleanup_bounded_pressure || true
        fixture_refuse 'C2 bounded disk-pressure setup' "could not create a test-owned pressure file: $path"
        return 75
      fi
      identity=$(sudo stat -c '%d:%i' -- "$path") || {
        sudo rm -f -- "$path" 2>/dev/null || true
        cleanup_bounded_pressure || true
        fixture_refuse 'C2 bounded disk-pressure setup' "could not record test-owned pressure-file identity: $path"
        return 75
      }
      printf '%s\t%s\t%s\n' "$path" "${identity%%:*}" "${identity##*:}" \
        >>"$test_root/r15-bounded-pressure-owned.tsv"
      if ! sudo fallocate -l "${allocated}K" -- "$path"; then
        cleanup_bounded_pressure || true
        fixture_refuse 'C2 bounded disk-pressure setup' "$filesystem could not allocate ${allocated} KiB within the ${cap} KiB cap"
        return 75
      fi
    else
      path=-
      identity=-:-
    fi
    read -r after < <(df -k --output=avail -- "${directory_by_fs[$filesystem]}" | awk 'NR == 2 { print $1 }')
    [[ $after =~ ^[0-9]+$ ]] || {
      cleanup_bounded_pressure || true
      fixture_refuse 'C2 bounded disk-pressure setup' "could not measure free space after preparing $filesystem"
      return 75
    }
    if ((after < required + margin_kb || after > required + margin_kb + 16384)); then
      cleanup_bounded_pressure || true
      fixture_refuse 'C2 bounded disk-pressure setup' \
        "$filesystem reports ${after} KiB; fixture target is ${required} KiB plus ${margin_kb} KiB reserve"
      return 75
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$filesystem" "$available" "$required" "$allocated" "$after" "$path" \
      "${identity%%:*}" "${identity##*:}" "$margin_kb" >>"$test_root/r15-bounded-pressure.tsv"
  done
  fixture_event READY 'C2 bounded disk-pressure setup' \
    "${total_kb} KiB allocated (cap ${cap} KiB); measured rows in $test_root/r15-bounded-pressure.tsv"
}

focused_baseline_valid() {
  local linux_kernel lts_kernel utils_version dkms_version linux_version linux_headers_version
  local lts_version lts_headers_version module_version status=0 pkgbase kernel image module
  local -a required=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
  verify_repository_driver_pair || status=1
  utils_version=$(repository_version extra/nvidia-utils || true)
  dkms_version=$(repository_version extra/nvidia-open-dkms || true)
  [[ -n $utils_version && $(pacman -Q nvidia-utils 2>/dev/null | awk '{print $2}') == "$utils_version" ]] || status=1
  [[ -n $dkms_version && $(pacman -Q nvidia-open-dkms 2>/dev/null | awk '{print $2}') == "$dkms_version" ]] || status=1
  linux_kernel=$(kernel_for_pkgbase linux 2>/dev/null || true)
  lts_kernel=$(kernel_for_pkgbase linux-lts 2>/dev/null || true)
  linux_version=$(pacman -Q linux 2>/dev/null | awk '{print $2}' || true)
  linux_headers_version=$(pacman -Q linux-headers 2>/dev/null | awk '{print $2}' || true)
  lts_version=$(pacman -Q linux-lts 2>/dev/null | awk '{print $2}' || true)
  lts_headers_version=$(pacman -Q linux-lts-headers 2>/dev/null | awk '{print $2}' || true)
  [[ -n $linux_kernel && -n $lts_kernel && $linux_version == "$linux_headers_version" &&
     $lts_version == "$lts_headers_version" ]] || status=1
  module_version=$(module_version_from_package "${utils_version:-}")
  if ((status == 0)); then
    for pkgbase in linux linux-lts; do
      kernel=$(kernel_for_pkgbase "$pkgbase" 2>/dev/null || true)
      for module in "${required[@]}"; do
        [[ $(modinfo -k "$kernel" -F version "$module" 2>/dev/null || true) == "$module_version" ]] || status=1
      done
      image_set_for_kernel "$pkgbase" || { status=1; continue; }
      for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
        image_has_modules_at_version "$image" "$module_version" "${required[@]}" || status=1
      done
    done
  fi
  ((status == 0))
}

focused_baseline_ready() {
  local linux_kernel lts_kernel linux_headers_version lts_headers_version utils_version dkms_version
  if focused_baseline_valid; then
    utils_version=$(pacman -Q nvidia-utils 2>/dev/null | awk '{print $2}' || true)
    dkms_version=$(pacman -Q nvidia-open-dkms 2>/dev/null | awk '{print $2}' || true)
    linux_kernel=$(kernel_for_pkgbase linux 2>/dev/null || true)
    lts_kernel=$(kernel_for_pkgbase linux-lts 2>/dev/null || true)
    linux_headers_version=$(pacman -Q linux-headers 2>/dev/null | awk '{print $2}' || true)
    lts_headers_version=$(pacman -Q linux-lts-headers 2>/dev/null | awk '{print $2}' || true)
    fixture_event READY 'C2-C5 focused baseline' \
      "linux $linux_kernel headers $linux_headers_version; linux-lts $lts_kernel headers $lts_headers_version; NVIDIA $utils_version/$dkms_version"
    return 0
  fi
  fixture_refuse 'C2-C5 focused baseline' 'requires a version-consistent linux and linux-lts NVIDIA module/image baseline'
  return 75
}

focused_prepare() {
  local status=0 package
  verify_repository_driver_pair || return $?
  for package in core/linux core/linux-headers core/linux-lts core/linux-lts-headers \
      extra/nvidia-utils extra/nvidia-open-dkms; do
    if ! pacman -Si "$package" >/dev/null 2>&1; then
      fixture_refuse 'C2-C5 focused baseline setup' "$package is unavailable from the configured repository"
      return 75
    fi
  done
  if ! sudo pacman -S --noconfirm --needed core/linux core/linux-headers core/linux-lts core/linux-lts-headers \
      extra/nvidia-utils extra/nvidia-open-dkms; then
    fixture_refuse 'C2-C5 focused baseline setup' 'pacman could not provision the selected kernel and NVIDIA packages'
    return 75
  fi
  fixture_event READY 'C2-C5 focused baseline packages' \
    'linux/linux-lts with matching headers; nvidia-utils/nvidia-open-dkms from configured repositories'
  run_nvidia_step focused-two-kernel-baseline "$supported" -
  status=$last_status
  local baseline_ok=0
  [[ $status == 0 ]] && focused_baseline_valid && baseline_ok=1
  record 'NVIDIA installer establishes matching modules and initramfs images for linux and linux-lts' \
    "$baseline_ok" "step status $status; package and image versions checked for both kernels"
  ((status == 0)) || return 1
  ((baseline_ok == 1)) || return 1
  focused_baseline_ready
}

test_r15_pacman_stale_lock() {
  local lock=/var/lib/pacman/db.lck packages_before database_before etc_before
  local modules_before boot_before lock_hash lock_identity status lock_ok=1 reports_before
  local lock_marker=$test_root/r15-stale-lock-owned
  local image_hashes_before=$test_root/r15-stale-lock-images-before.sha256
  local image_hashes_after=$test_root/r15-stale-lock-images-after.sha256

  if [[ -e $lock || -L $lock ]]; then
    fixture_refuse 'R15 stale-lock fixture' \
      'pre-existing db.lck left untouched'
    return 75
  fi
  if ! command -v pgrep >/dev/null 2>&1 || pgrep -x pacman >/dev/null 2>&1; then
    fixture_refuse 'R15 stale-lock fixture' \
      'could not establish that the lock would be stale'
    return 75
  fi
  if ! capture_all_kernel_image_hashes >"$image_hashes_before"; then
    fixture_refuse 'R15 stale-lock fixture' 'baseline image inventory could not be hashed'
    return 75
  fi
  local lock_contents="gooarchy-nvidia-stale-lock $test_stamp"
  printf '%s\n' "$lock_contents" |
    sudo tee "$lock" >/dev/null || {
      fixture_refuse 'R15 stale-lock fixture' 'could not create a test-owned db.lck'
      return 75
    }
  lock_hash=$(printf '%s\n' "$lock_contents" | sha256sum | awk '{print $1}') || {
    fixture_refuse 'R15 stale-lock fixture' 'could not identify the test-owned lock contents'
    return 75
  }
  lock_identity=$(sudo stat -c '%d:%i' -- "$lock") || {
    fixture_refuse 'R15 stale-lock fixture' 'could not record the test-owned lock identity'
    return 75
  }
  fixture_event READY 'R15 stale-lock fixture' 'test-owned lock hash and filesystem identity recorded'
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
    if ! sudo pacman -S --noconfirm --needed linux-lts linux-lts-headers; then
      fixture_refuse 'R9/R10 linux-lts kernel fixture' 'could not install linux-lts and matching headers'
      return 75
    fi
    kernel=$(kernel_for_pkgbase linux-lts 2>/dev/null || true)
  fi
  if [[ -z $kernel ]]; then
    fixture_refuse 'R9/R10 linux-lts kernel fixture' 'linux-lts module tree not found after package setup'
    return 75
  fi
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
      fixture_refuse "R10 $scenario user-partial fixture" 'no resolvable preset images before failure injection'
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
        sudo lsinitcpio "$image" >/dev/null 2>&1 || image_ok=0
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
  local module modules step_log hook_report_ok partial_report_ok current_version linux_preset focused_case
  local linux_preset_hash r11_config_hash r11_report_ok=0 r11_image_ok=1 r11_files_unchanged=0
  local hook_before hook_after hook_image hook_marker_ok=0 hook_after_write_ok=0 pressure_hook_ok=0 hook_wrapper_restored=0
  local hook_filesystem hook_available pressure_target hook_path=/usr/share/libalpm/hooks/90-mkinitcpio-install.hook
  local -a required_partial=(nvidia nvidia_modeset)
  linux_kernel=$(kernel_for_pkgbase linux 2>/dev/null || true)
  lts_kernel=$(kernel_for_pkgbase linux-lts 2>/dev/null || true)
  if [[ -z $linux_kernel || -z $lts_kernel ]]; then
    fixture_refuse 'C2-C5 package-hook fixture' 'linux and linux-lts must both be installed'
    return 75
  fi
  build_link_path=/usr/lib/modules/$lts_kernel/build
  if [[ ! -e $build_link_path && ! -L $build_link_path ]]; then
    fixture_refuse 'C2-C5 package-hook fixture' "$build_link_path missing"
    return 75
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
    fixture_refuse 'C2-C5 user-partial kernel fixture' 'linux-lts images did not preserve nvidia and nvidia_modeset only'
    sudo rm -f "$user_config"
    if restore_kernel_modules "$lts_kernel"; then rm -f "$test_root/partial-kernel-path"; fi
    return 75
  fi
  fixture_event READY 'C2-C5 user-partial kernel fixture' "linux-lts $lts_kernel images contain nvidia and nvidia_modeset only"
  linux_preset=/etc/mkinitcpio.d/linux.preset
  if [[ -e $test_root/linux.preset.saved ]] ||
     ! grep -Eq '^[[:space:]]*MODULES[[:space:]]*=[[:space:]]*\(\)[[:space:]]*$' /etc/mkinitcpio.conf; then
    fixture_refuse 'C2-C5 custom-preset hook fixture' 'preset backup exists or /etc/mkinitcpio.conf is not MODULES=()'
    sudo rm -f "$user_config"
    if restore_kernel_modules "$lts_kernel"; then rm -f "$test_root/partial-kernel-path"; fi
    return 75
  fi
  sudo cp -a "$linux_preset" "$test_root/linux.preset.saved"
  sudo cp /etc/mkinitcpio.conf "$r11_config"
  r11_config_hash=$(sha256sum "$r11_config" | awk '{print $1}')
  if grep -Eq '^[[:space:]]*([[:alnum:]_-]+_)?config[[:space:]]*=' "$linux_preset"; then
    sudo sed -i -E "s|^([[:space:]]*([[:alnum:]_-]+_)?config[[:space:]]*=).*|\\1\"$r11_config\"|" "$linux_preset"
  else
    printf '\nALL_config="%s"\n' "$r11_config" | sudo tee -a "$linux_preset" >/dev/null
  fi
  if ! sudo mkinitcpio -p linux >"$test_root/r15-hook-r11-prepare.log" 2>&1; then
    fixture_refuse 'C2-C5 custom-preset hook fixture' 'mkinitcpio failed using the named config'
    sudo mv "$test_root/linux.preset.saved" "$linux_preset"
    sudo rm -f "$r11_config" "$user_config"
    if restore_kernel_modules "$lts_kernel"; then rm -f "$test_root/partial-kernel-path"; fi
    return 75
  fi
  image_set_for_kernel linux || r11_image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    sudo lsinitcpio "$image" >/dev/null 2>&1 || r11_image_ok=0
    check_image_versions_and_firmware "$image" "$(module_version_from_package "$(pacman -Q nvidia-utils | awk '{print $2}')")" || r11_image_ok=0
    modules=$(image_modules "$image" 2>/dev/null || true)
    [[ -z $modules ]] || r11_image_ok=0
  done
  if ((r11_image_ok == 0)); then
    fixture_refuse 'C2-C5 custom-preset hook fixture' 'linux images are not listable, firmware-consistent and module-free'
    sudo mv "$test_root/linux.preset.saved" "$linux_preset"
    sudo rm -f "$r11_config" "$user_config"
    if restore_kernel_modules "$lts_kernel"; then rm -f "$test_root/partial-kernel-path"; fi
    return 75
  fi
  fixture_event READY 'C2-C5 custom-preset hook fixture' "$linux_preset and $r11_config have listable module-free images"
  linux_preset_hash=$(sha256sum "$linux_preset" | awk '{print $1}')
  module_version=$current_version
  linux_images_before=$(kernel_image_hashes linux 2>/dev/null || true)
  lts_images_before=$(kernel_image_hashes linux-lts 2>/dev/null || true)
  printf '%s' "$build_link_path" >"$test_root/linux-lts-build-link-path"
  sudo mv "$build_link_path" "$test_root/linux-lts-build-link.saved"

  focused_case=${GOOARCHY_VM_NVIDIA_FOCUSED_CASE:-}
  if [[ ! -f $hook_path ]] ||
     ! grep -Eq '^[[:space:]]*Exec[[:space:]]*=[[:space:]]*(/usr/bin/mkinitcpio[[:space:]]+-P|/usr/share/libalpm/scripts/mkinitcpio[[:space:]]+install)[[:space:]]*$' "$hook_path"; then
    fixture_refuse 'C3 generated Arch package hook fixture' "$hook_path missing or uses an unsupported mkinitcpio command"
    return 75
  fi
  hook_before=$(sha256sum "$hook_path" | awk '{print $1}')
  : >"$test_root/r15-package-hook-invocations.tsv"
  image_set_for_kernel linux || image_ok=0
  hook_image=${NV_TEST_IMAGES[0]:-}
  if [[ $focused_case == package-hook-partial-lts ]]; then
    prepare_bounded_disk_pressure || return $?
  fi

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
  hook_after=$(sha256sum "$hook_path" | awk '{print $1}')
  if [[ $hook_before == "$hook_after" && ! -e $test_root/90-mkinitcpio-install.hook.saved ]]; then
    hook_wrapper_restored=1
    fixture_event CLEANUP-OK 'C3 generated-hook test wrapper' 'original Arch hook preserved byte-for-byte'
  else
    fixture_event CLEANUP-FAIL 'C3 generated-hook test wrapper' 'original Arch hook was not restored byte-for-byte'
  fi
  if [[ -n $hook_image ]] && awk -F '\t' -v image="$hook_image" \
      '$1 == "invoke" && $2 == "linux" && $3 == image { invoked=1 }
       END { exit !invoked }' "$test_root/r15-package-hook-invocations.tsv"; then
    hook_marker_ok=1
  fi
  if [[ -n $hook_image ]] && awk -F '\t' -v image="$hook_image" \
      '$1 == "after-write" && $2 == "linux" && $3 == image { wrote=1 }
       END { exit !wrote }' "$test_root/r15-package-hook-invocations.tsv"; then
    hook_after_write_ok=1
  fi
  if [[ $focused_case == package-hook-partial-lts ]]; then
    hook_filesystem=$(awk -F '\t' -v image="$hook_image" '$1 == "invoke" && $3 == image { print $4; exit }' \
      "$test_root/r15-package-hook-invocations.tsv")
    hook_available=$(awk -F '\t' -v image="$hook_image" '$1 == "invoke" && $3 == image { print $5; exit }' \
      "$test_root/r15-package-hook-invocations.tsv")
    pressure_target=$(awk -F '\t' -v fs="$hook_filesystem" '$1 == fs { print $5; exit }' \
      "$test_root/r15-bounded-pressure.tsv")
    if [[ $hook_available =~ ^[0-9]+$ && $pressure_target =~ ^[0-9]+$ ]] &&
       ((hook_available >= pressure_target - 16384 && hook_available <= pressure_target + 16384)) &&
       ((hook_after_write_ok == 1)) && bounded_pressure_files_present; then
      pressure_hook_ok=1
    fi
  fi
  partial_report_ok=0
  if grep -Fq "linux-lts kernel $lts_kernel" "$step_log" &&
     grep -Fq "$user_config" "$step_log" &&
     grep -Fq 'does not promise this kernel reaches the desktop' "$step_log"; then
    partial_report_ok=1
  fi
  r11_image_ok=1
  image_set_for_kernel linux || r11_image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    sudo lsinitcpio "$image" >/dev/null 2>&1 || r11_image_ok=0
    check_image_versions_and_firmware "$image" "$module_version" || r11_image_ok=0
    modules=$(image_modules "$image" 2>/dev/null || true)
    [[ -z $modules ]] || r11_image_ok=0
  done
  if grep -Fq "image in linux.preset reads $r11_config directly" "$step_log"; then r11_report_ok=1; fi
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
  if [[ $focused_case == package-hook-partial-lts ]]; then
    record 'C2 measured bounded disk pressure overlaps hook failure while linux images restore byte-identically' \
      "$([[ $status != 0 && $hook_report_ok == 1 && $pressure_hook_ok == 1 && -n $linux_images_before &&
            $linux_images_before == "$linux_images_after" ]] && echo 1 || echo 0)" \
      "hook free space ${hook_available:-unmeasured} KiB; target ${pressure_target:-unmeasured} KiB; pressure evidence $test_root/r15-bounded-pressure.tsv"
    record 'C3 generated Arch hook invokes mkinitcpio after image write and reports the failure' \
      "$([[ $status != 0 && $hook_report_ok == 1 && $hook_marker_ok == 1 && $hook_after_write_ok == 1 ]] && echo 1 || echo 0)" \
      "failure reported=$hook_report_ok; invoked=$hook_marker_ok after-write=$hook_after_write_ok; linux image $hook_image"
    record 'C5 hook-failure interaction retains the user-partial fix report without changing its config' \
      "$([[ $status != 0 && $partial_report_ok == 1 && $r11_report_ok == 1 && $r11_files_unchanged == 1 &&
            $config_hash == "$(sha256sum "$user_config" | awk '{print $1}')" ]] && echo 1 || echo 0)" \
      "linux-lts $lts_kernel; report and named user config asserted on the hook-failure path"
  fi
  hold_r15_failure_row package-hook-linux-partial-lts

  if ((hook_wrapper_restored == 0)); then
    return 1
  fi

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
    record 'R17 rerun repairs the user-partial kernel after the package-hook failure' \
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
    fixture_event CLEANUP-FAIL 'C2-C5 user-partial kernel fixture' "DKMS recovery failed for $lts_kernel; cleanup will retry"
    return 1
  fi
}

test_prebuilt_replacement() {
  local before_packages before_etc before_boot status kernel build_link_path
  if ! pacman -Si nvidia-open >/dev/null 2>&1; then
    fixture_refuse 'R7 prebuilt replacement fixture' 'configured repositories do not provide nvidia-open'
    return 75
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
  if [[ -z $kernel ]]; then fixture_refuse 'R15 prebuilt replacement fixture' 'linux kernel tree missing'; return 75; fi
  build_link_path=/usr/lib/modules/$kernel/build
  if [[ ! -e $build_link_path && ! -L $build_link_path ]]; then
    fixture_refuse 'R15 prebuilt replacement fixture' "$build_link_path missing before fixture"
    return 75
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
    fixture_refuse 'R8 held-version package fixture' 'missing pinned package paths or checksums'
    return 75
  fi
  if [[ $(sha256sum "$utils_pkg" | awk '{print $1}') != "$utils_sha" || $(sha256sum "$dkms_pkg" | awk '{print $1}') != "$dkms_sha" ]]; then
    fixture_refuse 'R8 held-version package fixture' 'archive package hash mismatch'
    return 75
  fi
  fixture_event READY 'R8 held-version package fixture' 'pinned Archive package paths and SHA256 values verified'
  : >"$test_root/driver-recovery-needed"
  sudo cp -a "$pacman_conf" "$saved_conf"
  sudo pacman -U --noconfirm "$utils_pkg" "$dkms_pkg"
  grep -Eq '^[[:space:]]*\[options\][[:space:]]*$' "$pacman_conf" || {
    fixture_refuse 'R8 pacman hold fixture' "$pacman_conf has no [options] section"
    sudo mv "$saved_conf" "$pacman_conf"
    restore_r15a_current_state || true
    return 75
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
  if [[ $last_status == 0 && $(pacman -Q nvidia-utils | awk '{print $2}') == "$(repository_version extra/nvidia-utils)" ]]; then
    fixture_event CLEANUP-OK 'R8 held-version package fixture' 'repository driver restored after held-version check'
  else
    fixture_event CLEANUP-FAIL 'R8 held-version package fixture' 'repository driver recovery did not converge'
    return 1
  fi
  if [[ $last_status == 0 && $(pacman -Q nvidia-utils | awk '{print $2}') == "$(repository_version extra/nvidia-utils)" ]]; then
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
    fixture_refuse 'R15a stale-image fixture' 'missing pinned package paths or checksum mismatch'
    return 75
  fi
  kernel=$(kernel_for_pkgbase linux 2>/dev/null || true)
  if [[ -z $kernel ]]; then fixture_refuse 'R15a stale-image fixture' 'linux module tree missing'; return 75; fi
  current_package_version=$(pacman -Q nvidia-utils | awk '{print $2}')
  old_package_version=$(pacman -Qp "$utils_pkg" | awk '{print $2}')
  old_dkms_version=$(pacman -Qp "$dkms_pkg" | awk '{print $2}')
  if [[ -z $old_package_version || $old_package_version != "$old_dkms_version" ||
        $(vercmp "$old_package_version" "$current_package_version") -ge 0 ]]; then
    fixture_refuse 'R15a stale-image fixture' \
      "archive nvidia-utils/nvidia-open-dkms $old_package_version/$old_dkms_version; installed $current_package_version"
    return 75
  fi
  fixture_event READY 'R15a stale-image fixture' "older matching Archive package pair $old_package_version"

  : >"$test_root/r15a-recovery-needed"
  printf 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\n' >"$test_root/r15a-user-modules.conf"
  sudo cp "$test_root/r15a-user-modules.conf" "$user_config"
  if ! sudo pacman -U --noconfirm "$utils_pkg" "$dkms_pkg"; then
    fixture_refuse 'R15a stale-image fixture' 'pacman -U failed while installing the archived NVIDIA pair'
    restore_r15a_current_state || true
    return 75
  fi
  old_package_version=$(pacman -Q nvidia-utils | awk '{print $2}')
  old_dkms_version=$(pacman -Q nvidia-open-dkms | awk '{print $2}')
  old_module_version=$(module_version_from_package "$old_package_version")
  if [[ $old_package_version != "$old_dkms_version" ]]; then
    fixture_refuse 'R15a stale-image fixture' \
      "installed nvidia-utils/nvidia-open-dkms $old_package_version/$old_dkms_version"
    restore_r15a_current_state || true
    return 75
  fi
  if ! save_kernel_images linux r15a-old; then
    fixture_refuse 'R15a stale-image fixture' 'linux preset images unavailable for the archived driver'
    restore_r15a_current_state || true
    return 75
  fi
  image_set_for_kernel linux || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$old_module_version" "${required[@]}" || image_ok=0
  done
  old_images_expected=$(kernel_image_hashes linux 2>/dev/null || true)
  if ((image_ok == 0)); then
    fixture_refuse 'R15a stale-image fixture' 'saved baseline images do not contain the archived module version'
    restore_r15a_current_state || true
    return 75
  fi
  fixture_event READY 'R15a stale-image fixture' \
    "linux images contain archived module version $old_module_version; hashes saved"
  sudo rm -f "$user_config"
  if ! sudo pacman -S --noconfirm --needed nvidia-utils nvidia-open-dkms; then
    fixture_refuse 'R15a stale-image fixture' 'pacman -S could not restore current repository driver packages'
    restore_r15a_current_state || true
    return 75
  fi
  current_module_version=$(module_version_from_package "$(pacman -Q nvidia-utils | awk '{print $2}')")
  if [[ $current_module_version == "$old_module_version" ]]; then
    fixture_refuse 'R15a stale-image fixture' "current repository module version still equals archived version $current_module_version"
    restore_r15a_current_state || true
    return 75
  fi
  if ! restore_kernel_images r15a-old; then
    fixture_refuse 'R15a stale-image fixture' 'could not restore archived baseline images'
    restore_r15a_current_state || true
    return 75
  fi
  stale_images=$(kernel_image_hashes linux 2>/dev/null || true)
  image_ok=1
  image_set_for_kernel linux || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$old_module_version" "${required[@]}" || image_ok=0
  done
  if ((image_ok == 0)); then
    fixture_refuse 'R15a stale-image fixture' 'restored image modules differ from the archived baseline'
    restore_r15a_current_state || true
    return 75
  fi
  fixture_event READY 'R15a stale-image fixture' "linux $kernel; archived module version $old_module_version; image hashes match"
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
    fixture_refuse 'R15 step-regeneration fixture' 'Archive package pair is unavailable'
    return 75
  fi
  kernel=$(kernel_for_pkgbase linux 2>/dev/null || true)
  if [[ -z $kernel ]]; then
    fixture_refuse 'R15 step-regeneration fixture' 'linux module tree missing'
    return 75
  fi
  if [[ -e $owned ]] && ! grep -Fxq '# Gooarchy NVIDIA early KMS modules; managed by the Gooarchy installer.' "$owned"; then
    fixture_refuse 'R15 step-regeneration fixture' "$owned is user-owned"
    return 75
  fi
  : >"$test_root/r15a-recovery-needed"
  sudo rm -f "$owned"
  old_package_version=$(pacman -Qp "$old_utils_package" | awk '{print $2}')
  old_module_version=$(module_version_from_package "$old_package_version")
  if ! sudo pacman -U --noconfirm "$old_utils_package" "$old_dkms_package"; then
    fixture_refuse 'R15 step-regeneration fixture' 'pacman -U failed while installing the older driver pair'
    restore_r15a_current_state || true
    return 75
  fi
  image_set_for_kernel linux || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    sudo lsinitcpio "$image" >/dev/null 2>&1 || image_ok=0
    modules=$(image_modules "$image" 2>/dev/null || true)
    [[ -z $modules ]] || image_ok=0
  done
  if ((image_ok == 0)); then
    fixture_refuse 'R15 step-regeneration fixture' 'old-version starting images are not sound and module-free'
    restore_r15a_current_state || true
    return 75
  fi
  fixture_event READY 'R15 step-regeneration fixture' "linux $kernel; old driver module version $old_module_version; fallback images sound"

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
    sudo lsinitcpio "$image" >/dev/null 2>&1 || image_ok=0
    check_image_versions_and_firmware "$image" "$(module_version_from_package "$current_package_version")" || image_ok=0
    modules=$(image_modules "$image" 2>/dev/null || true)
    [[ -z $modules ]] || image_ok=0
  done
  record 'R15 Arch upgrade hooks succeed and the step regeneration fails with complete, consistent fallback images' \
    "$([[ $status != 0 && $state_unchanged == 1 && $hook_ok == 1 && $step_failure == 1 && $image_ok == 1 && -e $owned &&
          $current_package_version == "$(repository_version extra/nvidia-utils)" ]] && echo 1 || echo 0)" \
    "linux $kernel; nvidia-utils $current_package_version; owned early-KMS file remains for rerun"
  hold_r15_failure_row arch-upgrade-step-regen
  if restore_r15a_current_state; then
    fixture_event CLEANUP-OK 'R15 step-regeneration fixture' 'current packages, DKMS modules and images restored'
  else
    fixture_event CLEANUP-FAIL 'R15 step-regeneration fixture' 'cleanup recovery failed'
    return 1
  fi
}

test_r15a_arch_upgrade_hook() {
  local kernel old_package_version old_module_version current_package_version current_module_version
  local old_images old_image_preserved expected_image_hash image image_ok hook_failed stale_report boundary state_unchanged
  local status recovery_report
  local -a required=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
  if [[ -z $old_utils_package || -z $old_dkms_package || ! -f $old_utils_package || ! -f $old_dkms_package ]]; then
    fixture_refuse 'R15a Arch-upgrade fixture' 'Archive package pair is unavailable'
    return 75
  fi
  kernel=$(kernel_for_pkgbase linux 2>/dev/null || true)
  if [[ -z $kernel ]]; then
    fixture_refuse 'R15a Arch-upgrade fixture' 'linux module tree missing'
    return 75
  fi
  : >"$test_root/r15a-recovery-needed"
  old_package_version=$(pacman -Qp "$old_utils_package" | awk '{print $2}')
  old_module_version=$(module_version_from_package "$old_package_version")
  if ! sudo pacman -U --noconfirm "$old_utils_package" "$old_dkms_package"; then
    fixture_refuse 'R15a Arch-upgrade fixture' 'pacman -U failed while installing the archived pair'
    restore_r15a_current_state || true
    return 75
  fi
  printf 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\n' >"$test_root/r15a-arch-upgrade-modules.conf"
  sudo cp "$test_root/r15a-arch-upgrade-modules.conf" "$user_config"
  if ! sudo mkinitcpio -p linux >"$test_root/r15a-arch-upgrade-old-image.log" 2>&1; then
    fixture_refuse 'R15a Arch-upgrade fixture' 'mkinitcpio failed to prepare old-version Linux images'
    restore_r15a_current_state || true
    return 75
  fi
  image_ok=1
  image_set_for_kernel linux || image_ok=0
  for image in "${NV_TEST_KERNEL_IMAGES[@]}"; do
    image_has_modules_at_version "$image" "$old_module_version" "${required[@]}" || image_ok=0
  done
  old_images=$(kernel_image_hashes linux 2>/dev/null || true)
  if ((image_ok == 0)); then
    fixture_refuse 'R15a Arch-upgrade fixture' 'old-version Linux images are incomplete or unlistable'
    restore_r15a_current_state || true
    return 75
  fi
  fixture_event READY 'R15a Arch-upgrade fixture' "linux $kernel; old module version $old_module_version; image hashes captured"
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
    "$([[ $status == 0 && $current_package_version == "$(repository_version extra/nvidia-utils)" && $image_ok == 1 ]] && echo 1 || echo 0)" \
    "nvidia-utils $current_package_version; module version $current_module_version"
  hold_r15_failure_row arch-upgrade-hook-repaired
  if ((status != 0 || image_ok == 0)) ||
     [[ $current_package_version != "$(repository_version extra/nvidia-utils)" ]]; then
    restore_r15a_current_state || true
    return
  fi

  : >"$test_root/r15a-recovery-needed"
  if ! sudo pacman -U --noconfirm "$old_utils_package" "$old_dkms_package"; then
    fixture_refuse 'R15a Arch-upgrade fixture' 'second pacman -U failed while preparing the refusal case'
    restore_r15a_current_state || true
    return 75
  fi
  sudo cp "$test_root/r15a-arch-upgrade-modules.conf" "$user_config"
  if ! sudo mkinitcpio -p linux >"$test_root/r15a-arch-upgrade-refusal-old-image.log" 2>&1; then
    fixture_refuse 'R15a Arch-upgrade fixture' 'mkinitcpio failed to prepare old images for the refusal case'
    restore_r15a_current_state || true
    return 75
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
    fixture_event CLEANUP-OK 'R15a Arch-upgrade fixture' 'current packages, DKMS modules and images restored'
  else
    fixture_event CLEANUP-FAIL 'R15a Arch-upgrade fixture' 'cleanup recovery failed'
    return 1
  fi
}

r15_row() {
  local row=$1
  GOOARCHY_NVIDIA_HOLD_R15_ROW=$row
  export GOOARCHY_NVIDIA_HOLD_R15_ROW
  case $row in
    precommit-download|precommit-space)
      test_r15_precommit_failure "$row"
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
      if [[ ${GOOARCHY_VM_NVIDIA_FOCUSED_CASE:-} == package-hook-partial-lts ]]; then
        focused_baseline_ready || return 1
      fi
      test_pacman_hook_failure_with_partial_kernel
      ;;
    prebuilt-refused|prebuilt-linux-dkms)
      verify_repository_driver_pair || return 1
      test_prebuilt_replacement
      ;;
    stale-baseline-repair-failure|arch-upgrade-step-regen|arch-upgrade-hook-repaired|arch-upgrade-hook-repair-failure)
      verify_repository_driver_pair || return 1
      if ! ensure_archive_pair; then
        fixture_refuse "R15 row $row" 'older matching Archive package pair unavailable'
        return 75
      fi
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

focused_case() {
  local selected=${1:-}
  case $selected in
    prepare)
      focused_prepare
      ;;
    preset-assignment-edge)
      focused_baseline_ready || return $?
      test_preset_assignment_edge
      ;;
    mixed-preset)
      focused_baseline_ready || return $?
      test_mixed_preset_selected_entry_regeneration
      ;;
    *)
      echo 'focused case must be prepare, preset-assignment-edge, or mixed-preset' >&2
      return 2
      ;;
  esac
  ((failures == 0))
}

case $phase in
  preflight) preflight ;;
  preinstall) preinstall ;;
  postinstall) postinstall ;;
  reference) reference ;;
  focused) focused_case "${2:-}" ;;
  r15-row) r15_row "${2:-${GOOARCHY_NVIDIA_HOLD_R15_ROW:-}}" ;;
  r15-release)
    verify_r15_boot_evidence "$held_row" "$held_stamp" "$held_plan_sha"
    held=$(cut -f1 "$test_root/r15-boot-held")
    [[ ${2:-} == "$held" ]] || { echo 'r15-release row changed during validation.' >&2; exit 2; }
    rm -f "$test_root/r15-boot-held"
    ;;
  *) echo "usage: $0 preflight|preinstall|postinstall|reference|focused <case>|r15-row <row>|r15-release <row>" >&2; exit 2 ;;
esac
