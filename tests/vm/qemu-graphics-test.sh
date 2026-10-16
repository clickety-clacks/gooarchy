#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
source "$here/qemu-graphics.sh"
GOOARCHY_VM_RENDERNODE=/dev/dri/renderD128

assert_args() {
  local label=$1
  shift
  local -a expected=("$@")
  if [[ ${#actual[@]} -ne ${#expected[@]} ]]; then
    echo "FAIL $label: got ${#actual[@]} args, expected ${#expected[@]}" >&2
    exit 1
  fi
  local i
  for ((i = 0; i < ${#expected[@]}; i++)); do
    if [[ ${actual[$i]} != "${expected[$i]}" ]]; then
      echo "FAIL $label: arg $i was '${actual[$i]}', expected '${expected[$i]}'" >&2
      exit 1
    fi
  done
  echo "PASS $label"
}

declare -a actual
qemu_graphics_args actual virgl 1920x1080 0
assert_args "virgl keeps its render-node EGL route" \
  -device virtio-vga-gl,xres=1920,yres=1080 -display egl-headless,rendernode=/dev/dri/renderD128

qemu_graphics_args actual software 1920x1080 0
assert_args "software route uses standard VGA and the none display backend" -device VGA -display none

qemu_graphics_args actual software 1920x1080 1
assert_args "software route exposes its VNC display" -device VGA -display none -vnc 127.0.0.1:0

if qemu_graphics_args actual virgl 1920x1080 1; then
  echo "FAIL VNC is rejected with virgl" >&2
  exit 1
fi
echo "PASS VNC remains limited to software graphics"

if qemu_graphics_args actual unsupported 1920x1080 0; then
  echo "FAIL unsupported graphics mode is rejected" >&2
  exit 1
fi
echo "PASS unsupported graphics mode is rejected"
