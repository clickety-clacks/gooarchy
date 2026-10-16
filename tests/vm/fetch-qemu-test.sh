#!/bin/bash
# Exercise the private QEMU package staging path with synthetic packages and command stubs.
# The test never starts a real QEMU process or modifies the system package database.
set -euo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
helper=$here/fetch-qemu.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
real_cp=$(command -v cp)
real_tar=$(command -v tar)
fakebin=$tmp/bin
mkdir -p "$fakebin"

cat >"$fakebin/cp" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ ${1:-} == -a && ${2:-} == /var/lib/pacman/local ]]; then
  mkdir -p "$3/local"
  : >"$3/local/seabios-installed"
  : >"$3/local/qemu-common-installed"
  : >"$3/local/qemu-system-x86-firmware-installed"
else
  exec "$REAL_CP" "$@"
fi
EOF

cat >"$fakebin/fakeroot" <<'EOF'
#!/bin/sh
exec "$@"
EOF

cat >"$fakebin/pacman" <<'EOF'
#!/bin/bash
set -euo pipefail
args=("$@")
dbpath=
cachedir=
while (($#)); do
  case $1 in
    --dbpath) dbpath=$2; shift 2 ;;
    --cachedir) cachedir=$2; shift 2 ;;
    *) shift ;;
  esac
done
[[ -f $dbpath/local/seabios-installed ]] || {
  echo "test pacman: expected SeaBIOS in the copied host package database" >&2
  exit 1
}
[[ -f $dbpath/local/qemu-common-installed && -f $dbpath/local/qemu-system-x86-firmware-installed ]] || {
  echo "test pacman: expected split QEMU firmware packages in the copied host package database" >&2
  exit 1
}
has_seabios=0
has_qemu_common=0
has_qemu_firmware=0
for arg in "${args[@]}"; do
  [[ $arg == seabios ]] && has_seabios=1
  [[ $arg == qemu-common ]] && has_qemu_common=1
  [[ $arg == qemu-system-x86-firmware ]] && has_qemu_firmware=1
done
[[ $has_seabios == 1 ]] || {
  echo "test pacman: seabios was not requested as package data" >&2
  exit 1
}
[[ $has_qemu_common == 1 ]] || {
  echo "test pacman: qemu-common was not requested as package data" >&2
  exit 1
}
[[ $has_qemu_firmware == 1 ]] || {
  echo "test pacman: qemu-system-x86-firmware was not requested as package data" >&2
  exit 1
}
printf '%s\n' "${args[@]}" >"$PACMAN_ARGS_FILE"

package_root=$TEST_PACKAGE_ROOT
rm -rf "$package_root"
mkdir -p "$package_root/usr/bin" "$package_root/usr/share/qemu"
cat >"$package_root/usr/bin/qemu-system-x86_64" <<'QEMU'
#!/bin/sh
printf '%s\n' "$@" >"$QEMU_ARGS_FILE"
printf 'QEMU emulator version test-stub\n'
QEMU
chmod +x "$package_root/usr/bin/qemu-system-x86_64"
"$REAL_TAR" -C "$package_root" -cf "$cachedir/qemu-system-x86.pkg.tar.zst" usr/bin/qemu-system-x86_64
for firmware in bios-256k.bin kvmvapic.bin efi-virtio.rom; do
  [[ $firmware == ${TEST_MISSING_FIRMWARE:-} ]] && continue
  printf 'synthetic %s firmware\n' "$firmware" >"$package_root/usr/share/qemu/$firmware"
  case $firmware in
    bios-256k.bin) package=seabios ;;
    kvmvapic.bin) package=qemu-system-x86-firmware ;;
    efi-virtio.rom) package=qemu-common ;;
  esac
  "$REAL_TAR" -C "$package_root" -cf "$cachedir/$package.pkg.tar.zst" "usr/share/qemu/$firmware"
done
EOF

chmod +x "$fakebin/cp" "$fakebin/fakeroot" "$fakebin/pacman"

run_helper() {
  local case_dir=$1 missing_firmware=${2:-}
  REAL_CP=$real_cp REAL_TAR=$real_tar TEST_PACKAGE_ROOT="$tmp/package" \
    TEST_MISSING_FIRMWARE=$missing_firmware PACMAN_ARGS_FILE="$tmp/pacman-args" \
    QEMU_ARGS_FILE="$tmp/qemu-args" GOOARCHY_VM_DIR="$case_dir" \
    PATH="$fakebin:$PATH" "$helper" >"$tmp/helper.log" 2>&1
}

assert_download_target() {
  local package=$1
  grep -Fxq "$package" "$tmp/pacman-args" || {
    echo "FAIL: $package was not an explicit package download target" >&2
    exit 1
  }
}

success_dir=$tmp/success
mkdir -p "$tmp/package"
run_helper "$success_dir" || {
  cat "$tmp/helper.log" >&2
  echo "FAIL: helper did not stage the required QEMU firmware" >&2
  exit 1
}
for firmware in bios-256k.bin kvmvapic.bin efi-virtio.rom; do
  [[ -s $success_dir/qemu/usr/share/qemu/$firmware ]] || {
    echo "FAIL: staged firmware is missing or empty: $firmware" >&2
    exit 1
  }
done
assert_download_target seabios
assert_download_target qemu-system-x86-firmware
assert_download_target qemu-common
expected_args=$(printf '%s\n' -L "$success_dir/qemu/usr/share/qemu" --version)
[[ $(cat "$tmp/qemu-args") == "$expected_args" ]] || {
  echo "FAIL: QEMU wrapper did not preserve private -L lookup" >&2
  exit 1
}
echo "PASS: all required firmware is staged and private -L lookup is preserved"

partial_dir=$tmp/partial
mkdir -p "$partial_dir/qemu/bin" "$partial_dir/qemu/usr/share/qemu"
printf 'old QEMU stub\n' >"$partial_dir/qemu/bin/qemu-system-x86_64"
chmod +x "$partial_dir/qemu/bin/qemu-system-x86_64"
printf 'existing SeaBIOS\n' >"$partial_dir/qemu/usr/share/qemu/bios-256k.bin"
run_helper "$partial_dir" || {
  cat "$tmp/helper.log" >&2
  echo "FAIL: incomplete QEMU prefix was not repaired" >&2
  exit 1
}
for firmware in bios-256k.bin kvmvapic.bin efi-virtio.rom; do
  [[ -s $partial_dir/qemu/usr/share/qemu/$firmware ]] || {
    echo "FAIL: incomplete prefix remains missing firmware: $firmware" >&2
    exit 1
  }
done
echo "PASS: incomplete existing prefix is refreshed with the complete firmware set"

for missing_firmware in bios-256k.bin kvmvapic.bin efi-virtio.rom; do
  missing_dir=$tmp/missing-${missing_firmware//./-}
  mkdir -p "$missing_dir/qemu/bin"
  cat >"$missing_dir/qemu/bin/qemu-system-x86_64" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$missing_dir/qemu/bin/qemu-system-x86_64"
  if run_helper "$missing_dir" "$missing_firmware"; then
    echo "FAIL: missing private firmware was accepted: $missing_firmware" >&2
    exit 1
  fi
  grep -Fq "fetch-qemu: required QEMU firmware missing after package staging: $missing_firmware" "$tmp/helper.log" || {
    cat "$tmp/helper.log" >&2
    echo "FAIL: missing firmware did not produce a clear error: $missing_firmware" >&2
    exit 1
  }
done
echo "PASS: every required firmware file is enforced with a clear error"
