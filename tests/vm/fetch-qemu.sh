#!/bin/bash
# Put a private copy of QEMU (x86_64 system emulator, virgl display) under the VM test directory,
# for an Arch-based test machine where QEMU isn't installed and root isn't available. Downloads the
# Arch packages QEMU needs and its BIOS data packages, unpacks them into
# $GOOARCHY_VM_DIR/qemu and writes wrappers in $GOOARCHY_VM_DIR/qemu/bin. Nothing is installed
# system-wide. Needs pacman and fakeroot. GOOARCHY_VM_PROXY is used for downloads when set.
set -euo pipefail
dir=${GOOARCHY_VM_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/gooarchy-vm-test}
mirror=${GOOARCHY_VM_MIRROR:-https://geo.mirror.pkgbuild.com}
prefix=$dir/qemu
work=$dir/qemu-download
firmware_dir=$prefix/usr/share/qemu
firmware_files=(bios-256k.bin kvmvapic.bin efi-virtio.rom)
[[ -n ${GOOARCHY_VM_PROXY:-} ]] && export ALL_PROXY=$GOOARCHY_VM_PROXY

firmware_missing() {
  local file missing=()
  for file in "${firmware_files[@]}"; do
    [[ -s $firmware_dir/$file ]] || missing+=("$file")
  done
  printf '%s\n' "${missing[*]}"
}

if [[ -x $prefix/bin/qemu-system-x86_64 ]] && [[ -z $(firmware_missing) ]]; then
  echo "QEMU already unpacked in $prefix"
  exit 0
fi

command -v fakeroot >/dev/null || { echo "fetch-qemu: needs fakeroot" >&2; exit 1; }
rm -rf "$work"
mkdir -p "$work/db" "$work/cache" "$prefix"
# Start from the machine's own package database; explicitly target the firmware packages because
# their dependencies may already be installed and therefore absent from the download cache.
cp -a /var/lib/pacman/local "$work/db/"
cat >"$work/pacman.conf" <<EOF
[options]
Architecture = auto
SigLevel = Required DatabaseOptional
DisableSandbox
[core]
Server = $mirror/\$repo/os/\$arch
[extra]
Server = $mirror/\$repo/os/\$arch
EOF
fakeroot pacman --config "$work/pacman.conf" --dbpath "$work/db" --cachedir "$work/cache" \
  --logfile /dev/null -Syw --noconfirm \
  qemu-system-x86 qemu-img qemu-ui-egl-headless qemu-ui-opengl \
  qemu-hw-display-virtio-gpu qemu-hw-display-virtio-gpu-gl qemu-hw-display-virtio-gpu-pci \
  qemu-hw-display-virtio-gpu-pci-gl qemu-hw-display-virtio-vga qemu-hw-display-virtio-vga-gl \
  virglrenderer qemu-common qemu-system-x86-firmware seabios >/dev/null

for package in "$work"/cache/*.pkg.tar.zst; do
  [[ -f $package ]] || continue
  tar -C "$prefix" -xf "$package" --exclude=.PKGINFO --exclude=.BUILDINFO --exclude=.MTREE --exclude=.INSTALL
done

missing=$(firmware_missing)
[[ -z $missing ]] || {
  echo "fetch-qemu: required QEMU firmware missing after package staging: $missing" >&2
  rm -rf "$work"
  exit 1
}

mkdir -p "$prefix/bin"
for tool in qemu-system-x86_64 qemu-img; do
  extra=
  [[ $tool == qemu-system-x86_64 ]] && extra="-L $prefix/usr/share/qemu"
  cat >"$prefix/bin/$tool" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH="$prefix/usr/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export QEMU_MODULE_DIR="$prefix/usr/lib/qemu"
exec "$prefix/usr/bin/$tool" $extra "\$@"
EOF
  chmod +x "$prefix/bin/$tool"
done
rm -rf "$work"
"$prefix/bin/qemu-system-x86_64" --version | head -1
