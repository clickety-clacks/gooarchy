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
has_seabios=0
for arg in "${args[@]}"; do
  [[ $arg == seabios ]] && has_seabios=1
done
[[ $has_seabios == 1 ]] || {
  echo "test pacman: seabios was not requested as package data" >&2
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
if [[ ${TEST_INCLUDE_FIRMWARE:-0} == 1 ]]; then
  printf 'synthetic SeaBIOS firmware\n' >"$package_root/usr/share/qemu/bios-256k.bin"
fi
"$REAL_TAR" -C "$package_root" -cf "$cachedir/seabios.pkg.tar.zst" usr/share/qemu
EOF

chmod +x "$fakebin/cp" "$fakebin/fakeroot" "$fakebin/pacman"

run_helper() {
  local case_dir=$1 include_firmware=$2
  REAL_CP=$real_cp REAL_TAR=$real_tar TEST_PACKAGE_ROOT="$tmp/package" \
    TEST_INCLUDE_FIRMWARE=$include_firmware PACMAN_ARGS_FILE="$tmp/pacman-args" \
    QEMU_ARGS_FILE="$tmp/qemu-args" GOOARCHY_VM_DIR="$case_dir" \
    PATH="$fakebin:$PATH" "$helper" >"$tmp/helper.log" 2>&1
}

success_dir=$tmp/success
mkdir -p "$tmp/package"
run_helper "$success_dir" 1 || {
  cat "$tmp/helper.log" >&2
  echo "FAIL: helper did not stage a package-provided BIOS" >&2
  exit 1
}
[[ -s $success_dir/qemu/usr/share/qemu/bios-256k.bin ]] || {
  echo "FAIL: staged SeaBIOS file is missing or empty" >&2
  exit 1
}
grep -Fxq seabios "$tmp/pacman-args" || {
  echo "FAIL: SeaBIOS was not an explicit package download target" >&2
  exit 1
}
expected_args=$(printf '%s\n' -L "$success_dir/qemu/usr/share/qemu" --version)
[[ $(cat "$tmp/qemu-args") == "$expected_args" ]] || {
  echo "FAIL: QEMU wrapper did not preserve private -L lookup" >&2
  exit 1
}
echo "PASS: installed-host package state still stages SeaBIOS and keeps private -L lookup"

missing_dir=$tmp/missing
mkdir -p "$missing_dir/qemu/bin"
cat >"$missing_dir/qemu/bin/qemu-system-x86_64" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$missing_dir/qemu/bin/qemu-system-x86_64"
if run_helper "$missing_dir" 0; then
  echo "FAIL: missing private BIOS was accepted" >&2
  exit 1
fi
grep -Fq 'fetch-qemu: SeaBIOS firmware missing after package staging:' "$tmp/helper.log" || {
  cat "$tmp/helper.log" >&2
  echo "FAIL: missing private BIOS did not produce a clear error" >&2
  exit 1
}
grep -Fxq seabios "$tmp/pacman-args" || {
  echo "FAIL: stale QEMU prefix bypassed SeaBIOS staging" >&2
  exit 1
}
echo "PASS: missing firmware fails clearly, including for a pre-existing QEMU prefix"
