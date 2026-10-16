#!/usr/bin/env bash
# Build the graphics-related QEMU arguments without starting QEMU.
qemu_graphics_args() {
  local target_name=$1 gpu=$2 size=$3 vnc=$4
  local -n target=$target_name
  local xres=${size%x*} yres=${size#*x}
  target=()

  case $gpu in
    virgl)
      [[ $vnc != 1 ]] || { echo "GOOARCHY_VM_VNC needs GOOARCHY_VM_GPU=software" >&2; return 1; }
      local node=${GOOARCHY_VM_RENDERNODE:-$(ls /dev/dri/renderD* 2>/dev/null | head -1)}
      [[ -n $node ]] || { echo "no render node for virgl; set GOOARCHY_VM_GPU=software" >&2; return 1; }
      target=(-device "virtio-vga-gl,xres=$xres,yres=$yres" -display "egl-headless,rendernode=$node")
      ;;
    software)
      target=(-device VGA -display none)
      if [[ $vnc == 1 ]]; then target+=(-vnc 127.0.0.1:0); fi
      ;;
    *)
      echo "GOOARCHY_VM_GPU must be virgl or software" >&2
      return 1
      ;;
  esac
}
