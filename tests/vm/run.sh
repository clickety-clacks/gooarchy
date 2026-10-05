#!/bin/bash
# Gooarchy's VM test: boot a fresh Arch Linux cloud image under QEMU/KVM, run Gooarchy's installer
# in it unattended, reboot into the session and check the desktop (tests/vm/guest-check.py).
# Run it on a test machine, never on a machine someone is using.
#
#   tests/vm/run.sh [all]   everything below in order, on a fresh disk (the default)
#   tests/vm/run.sh boot    fresh disk from the cloud image, boot, wait for SSH
#   tests/vm/run.sh install copy this checkout in and run ./install.sh --yes --autologin
#   tests/vm/run.sh reboot  reboot the guest and wait for SSH
#   tests/vm/run.sh check   check the running session; screenshots and logs into the artifacts
#   tests/vm/run.sh ssh [CMD]   a shell (or CMD) in the guest
#   tests/vm/run.sh stop    power the guest off
#
# Configuration (environment):
#   GOOARCHY_VM_DIR         work directory (default ~/.cache/gooarchy-vm-test): image, disk, logs
#   GOOARCHY_VM_IMAGE_URL   Arch cloud image (default: the latest official one)
#   GOOARCHY_VM_QEMU_BIN    directory holding qemu-system-x86_64 and qemu-img (default: the copy
#                           tests/vm/fetch-qemu.sh unpacked, else PATH)
#   GOOARCHY_VM_GPU         virgl (default: guest GL through the host GPU) or software (llvmpipe)
#   GOOARCHY_VM_RENDERNODE  host render node for virgl (default: the first /dev/dri/renderD*)
#   GOOARCHY_VM_SIZE        guest screen size (default 1920x1080)
#   GOOARCHY_VM_MEMORY, GOOARCHY_VM_CPUS, GOOARCHY_VM_DISK   (default 6144 MiB, 4, 40G)
#   The guest's pacman cache is kept in GOOARCHY_VM_DIR/pkgcache (shared into the guest over 9p).
#   GOOARCHY_VM_SSH_PORT    host port forwarded to the guest's SSH (default 2222, bound to loopback)
#   GOOARCHY_VM_PROXY       proxy URL for machines whose own connection can't be used (e.g.
#                           socks5h://127.0.0.1:1080): used for the image download and, with
#                           127.0.0.1 rewritten to the host as the guest sees it, inside the guest.
#                           Test-only; Gooarchy's installer knows nothing about it.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd -- "$here/../.." && pwd)
dir=${GOOARCHY_VM_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/gooarchy-vm-test}
image_url=${GOOARCHY_VM_IMAGE_URL:-https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2}
gpu=${GOOARCHY_VM_GPU:-virgl}
size=${GOOARCHY_VM_SIZE:-1920x1080}
memory=${GOOARCHY_VM_MEMORY:-6144}
disk=${GOOARCHY_VM_DISK:-40G}
cpus=${GOOARCHY_VM_CPUS:-4}
port=${GOOARCHY_VM_SSH_PORT:-2222}
proxy=${GOOARCHY_VM_PROXY:-}
run=$dir/run
mkdir -p "$dir/images" "$run" "$dir/artifacts"

qemu_bin=${GOOARCHY_VM_QEMU_BIN:-}
[[ -z $qemu_bin && -x $dir/qemu/bin/qemu-system-x86_64 ]] && qemu_bin=$dir/qemu/bin
qemu=${qemu_bin:+$qemu_bin/}qemu-system-x86_64
qemu_img=${qemu_bin:+$qemu_bin/}qemu-img

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "FAILED: $*"; exit 1; }

artifacts() {
  # One directory per run of the test, named when first needed.
  if [[ ! -f $run/artifacts ]]; then
    local stamp; stamp=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$dir/artifacts/$stamp"
    echo "$dir/artifacts/$stamp" >"$run/artifacts"
  fi
  cat "$run/artifacts"
}

ssh_opts=(-i "$run/id_ed25519" -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=15)
guest() { ssh "${ssh_opts[@]}" arch@127.0.0.1 "$@"; }

guest_proxy_env() {
  [[ -n $proxy ]] || return 0
  local p=${proxy//127.0.0.1/10.0.2.2}
  p=${p//localhost/10.0.2.2}
  printf 'ALL_PROXY=%q all_proxy=%q HTTPS_PROXY=%q https_proxy=%q HTTP_PROXY=%q http_proxy=%q ' \
    "$p" "$p" "$p" "$p" "$p" "$p"
}

fetch_image() {
  local name; name=$(basename "$image_url")
  if [[ ! -f $dir/images/$name ]]; then
    log "downloading $image_url"
    curl -fsSL ${proxy:+--proxy "$proxy"} -o "$dir/images/$name.part" "$image_url"
    curl -fsSL ${proxy:+--proxy "$proxy"} -o "$dir/images/$name.SHA256" "$image_url.SHA256"
    (cd "$dir/images" && sed "s/ .*\$/  $name.part/" "$name.SHA256" | sha256sum -c --quiet) ||
      die "image checksum mismatch"
    mv "$dir/images/$name.part" "$dir/images/$name"
  fi
  echo "$dir/images/$name"
}

seed() {
  # cloud-init NoCloud seed, served over HTTP from the host: the image's default user (arch, with
  # passwordless sudo) gets this run's SSH key. Nothing else is configured here.
  [[ -f $run/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C gooarchy-vm-test -f "$run/id_ed25519"
  mkdir -p "$run/seed"
  printf 'instance-id: gooarchy-vm-%s\nlocal-hostname: gooarchy-vm\n' "$(date +%s)" >"$run/seed/meta-data"
  cat >"$run/seed/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "$run/id_ed25519.pub")
EOF
  local seed_port
  seed_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  setsid python3 -m http.server --bind 127.0.0.1 --directory "$run/seed" "$seed_port" \
    >"$run/seed-http.log" 2>&1 </dev/null &
  echo $! >"$run/seed-http.pid"
  echo "$seed_port"
}

stop_seed() {
  [[ -f $run/seed-http.pid ]] && kill "$(cat "$run/seed-http.pid")" 2>/dev/null || true
  rm -f "$run/seed-http.pid"
}

running() { [[ -f $run/qemu.pid ]] && kill -0 "$(cat "$run/qemu.pid")" 2>/dev/null; }

wait_ssh() {
  local deadline=$((SECONDS + ${1:-300}))
  until guest true 2>/dev/null; do
    running || die "QEMU exited; see $run/qemu.log"
    (( SECONDS < deadline )) || die "no SSH from the guest"
    sleep 5
  done
}

screendump() {
  # The display as QEMU shows it (independent of anything running in the guest).
  local out; out="$(artifacts)/$1"
  local reply
  if reply=$(python3 "$here/qmp.py" "$run/qmp.sock" screendump "{\"filename\": \"$out\", \"format\": \"png\"}"); then
    log "screendump $out"
  else
    log "screendump unavailable: $reply"
  fi
}

cmd_boot() {
  cmd_stop
  local image seed_port display
  image=$(fetch_image)
  rm -f "$run/disk.qcow2" "$run/artifacts"
  # Never smaller than the image (that would cut its partitions off); cloud-init grows the root
  # partition into the rest on first boot.
  "$qemu_img" create -q -f qcow2 -F qcow2 -b "$image" "$run/disk.qcow2" "$disk"
  seed_port=$(seed)
  local xres=${size%x*} yres=${size#*x}
  case $gpu in
    virgl)
      local node=${GOOARCHY_VM_RENDERNODE:-$(ls /dev/dri/renderD* 2>/dev/null | head -1)}
      [[ -n $node ]] || die "no render node for virgl; set GOOARCHY_VM_GPU=software"
      display=(-device "virtio-vga-gl,xres=$xres,yres=$yres" -display "egl-headless,rendernode=$node")
      ;;
    software) display=(-device "virtio-vga,xres=$xres,yres=$yres" -display none) ;;
    *) die "GOOARCHY_VM_GPU must be virgl or software" ;;
  esac
  [[ -w /dev/kvm ]] || die "needs /dev/kvm"
  mkdir -p "$dir/pkgcache"
  log "booting ($gpu, ${size}, ${memory} MiB, $cpus CPUs)"
  setsid "$qemu" -name gooarchy-vm -enable-kvm -cpu host -smp "$cpus" -m "$memory" -machine q35 \
    -drive "file=$run/disk.qcow2,if=virtio,discard=unmap" \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$port-:22" \
    -smbios "type=1,serial=ds=nocloud;s=http://10.0.2.2:$seed_port/" \
    "${display[@]}" -audiodev none,id=noaudio -device intel-hda -device hda-duplex,audiodev=noaudio \
    -device virtio-tablet-pci -device virtio-keyboard-pci \
    -virtfs "local,path=$dir/pkgcache,mount_tag=gooarchy-pkgcache,security_model=mapped-xattr,id=pkgcache" \
    -serial "file:$run/serial.log" -qmp "unix:$run/qmp.sock,server,nowait" -pidfile "$run/qemu.pid" \
    >"$run/qemu.log" 2>&1 </dev/null &
  sleep 2
  running || die "QEMU didn't start: $(cat "$run/qemu.log")"
  wait_ssh 300
  stop_seed
  log "guest is up: $(guest 'uname -r; . /etc/os-release; echo $PRETTY_NAME' | tr '\n' ' ')"
  if [[ -n $proxy ]]; then
    # Test-only: let sudo (pacman, makepkg -s) keep the proxy variables.
    guest 'echo "Defaults env_keep += \"ALL_PROXY all_proxy HTTPS_PROXY https_proxy HTTP_PROXY http_proxy\"" |
           sudo tee /etc/sudoers.d/90-vm-test-proxy >/dev/null && sudo chmod 440 /etc/sudoers.d/90-vm-test-proxy'
  fi
  # Test-only: pacman's package cache lives on the host (shared over 9p), so reruns don't download
  # everything again; slow links get no download timeout.
  guest 'sudo mkdir -p /var/cache/pacman/vm-test &&
         echo "gooarchy-pkgcache /var/cache/pacman/vm-test 9p trans=virtio,version=9p2000.L,msize=1048576,nofail 0 0" |
           sudo tee -a /etc/fstab >/dev/null && sudo systemctl daemon-reload && sudo mount /var/cache/pacman/vm-test &&
         sudo sed -i -e "s|^#\\?CacheDir.*|CacheDir = /var/cache/pacman/vm-test/|" \
                     -e "s|^#\\?ParallelDownloads.*|ParallelDownloads = 3\\nDisableDownloadTimeout|" /etc/pacman.conf'
  guest 'grep -E "^(CacheDir|ParallelDownloads|DisableDownloadTimeout)" /etc/pacman.conf' >&2
  # The cloud image is a minimal install; make sure its package databases are current before the
  # installer runs, as a freshly installed system's would be.
  guest "sudo $(guest_proxy_env) pacman -Sy --noconfirm >/dev/null"
}

cmd_install() {
  running || die "the guest isn't running (tests/vm/run.sh boot)"
  local out; out=$(artifacts)
  log "copying the checkout (tracked and untracked files) into the guest"
  (cd "$repo" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) |
    guest 'rm -rf ~/gooarchy && mkdir ~/gooarchy && tar -C ~/gooarchy -xf -'
  log "running ./install.sh --yes --autologin (log: $out/install.log)"
  local status=0
  guest "cd ~/gooarchy && $(guest_proxy_env) ./install.sh --yes --autologin" >"$out/install.log" 2>&1 || status=$?
  tail -n 25 "$out/install.log" >&2
  guest 'cat ~/.local/state/gooarchy/install.log 2>/dev/null' >"$out/install-steps.log" || true
  (( status == 0 )) || die "install.sh exited with $status"
  log "install finished"
}

cmd_reboot() {
  running || die "the guest isn't running"
  guest 'sudo systemctl reboot' || true
  sleep 10
  wait_ssh 300
  log "rebooted"
}

cmd_check() {
  running || die "the guest isn't running"
  local out; out=$(artifacts)
  screendump vm-display-before-check.png
  guest 'rm -rf /tmp/gooarchy-check && mkdir -p /tmp/gooarchy-check'
  guest 'cat >/tmp/gooarchy-check/guest-check.py' <"$here/guest-check.py"
  log "checking the session in the guest"
  local status=0
  guest 'python3 /tmp/gooarchy-check/guest-check.py /tmp/gooarchy-check/out' 2>&1 | tee "$out/guest-check.log" >&2 ||
    status=$?
  screendump vm-display-after-check.png
  guest 'cd /tmp/gooarchy-check/out && tar -cf - .' | tar -C "$out" -xf - || true
  guest 'journalctl -b --no-pager -o short-monotonic' >"$out/journal.log" 2>/dev/null || true
  guest 'cp ~/.local/state/scottland/wayfire.log /dev/stdout' >"$out/wayfire.log" 2>/dev/null || true
  cp "$run/serial.log" "$out/serial.log" 2>/dev/null || true
  log "artifacts: $out"
  return "$status"
}

cmd_stop() {
  stop_seed
  if running; then
    python3 "$here/qmp.py" "$run/qmp.sock" quit >/dev/null 2>&1 || kill "$(cat "$run/qemu.pid")" 2>/dev/null || true
    local deadline=$((SECONDS + 20))
    while running && (( SECONDS < deadline )); do sleep 1; done
    running && kill -9 "$(cat "$run/qemu.pid")" 2>/dev/null || true
    log "guest stopped"
  fi
  rm -f "$run/qemu.pid"
}

case ${1:-all} in
  boot) cmd_boot ;;
  install) cmd_install ;;
  reboot) cmd_reboot ;;
  check) cmd_check ;;
  ssh) shift; guest -t "$@" ;;
  stop) cmd_stop ;;
  all)
    rm -f "$run/artifacts"
    trap cmd_stop EXIT
    cmd_boot
    cmd_install
    cmd_reboot
    cmd_check
    ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
esac
