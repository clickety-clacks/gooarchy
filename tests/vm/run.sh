#!/bin/bash
# Gooarchy's VM test: boot a fresh Arch Linux cloud image under QEMU/KVM, run Gooarchy's installer
# in it unattended, reboot into the session and check the desktop (tests/vm/guest-check.py).
# Run it on a test machine, never on a machine someone is using.
#
# What it is and isn't: an unattended test on the official Arch cloud image (cloud-init gives it an
# SSH key; see "Test-only" below for the accommodations the guest gets). It is not an archinstall
# minimal install, and real hardware is a different matter.
#
#   tests/vm/run.sh [all]   everything below in order, on a fresh disk (the default); exits 1 if
#                           any check failed. Results: GOOARCHY_VM_DIR/artifacts/<time>/
#   tests/vm/run.sh boot    fresh disk from the cloud image, boot, wait for SSH
#   tests/vm/run.sh install copy this checkout in; ./install.sh made to fail at one step first, then
#                           run again (it must recover); with --autologin
#   tests/vm/run.sh rebuild-check   rebuild Scottland at another commit with the same upstream
#                           version and back, plus an identical rebuild; the installed plugin must
#                           follow each time
#   tests/vm/run.sh reboot  reboot the guest and wait for the new boot
#   tests/vm/run.sh check   check the running session (guest-check.py); screenshots and logs
#   tests/vm/run.sh login-check     password logins typed at the consoles (login-check.py)
#   tests/vm/run.sh upgrade-guard   a newer Wayfire must not install over the Scottland built for this one
#   tests/vm/run.sh no-toolchain    the Rust toolchain is optional: the install leaves none, and
#                           without one the gooarchy package installs and its command runs
#   tests/vm/run.sh start   boot the existing disk again (after stop)
#   tests/vm/run.sh ssh [CMD]   a shell (or CMD) in the guest
#   tests/vm/run.sh stop    power the guest off
#   tests/vm/run.sh manifest capture the guest package set and VM build details
#   tests/vm/run.sh nvidia-preflight  check current and older NVIDIA package pairs before package changes
#   tests/vm/run.sh nvidia-matrix preinstall|postinstall|focused prepare|preset-assignment-edge|mixed-preset
#   tests/vm/run.sh nvidia-install   run the supported-device full install through this wrapper
#   tests/vm/run.sh nvidia-r15-row ROW   hold a failure state through each sound-kernel desktop reboot
#   focused package-hook R15 row: set GOOARCHY_VM_NVIDIA_FOCUSED_CASE=package-hook-partial-lts;
#   the bounded pressure cap defaults to 4 GiB and may be lowered by the runner
#   tests/vm/run.sh nvidia-reference   fresh VM for R18's reference-state rerun
#
# Looking at the desktop: GOOARCHY_VM_GPU=software GOOARCHY_VM_VNC=1 tests/vm/run.sh start, then
# point a VNC viewer at 127.0.0.1:5900 on this machine (e.g. through ssh -L 5900:127.0.0.1:5900).
# The seed server and the guest's network stay as the test uses them.
#
# Configuration (environment):
#   GOOARCHY_VM_KERNEL      1: install the opt-in kernel and direct-boot it in this test VM for
#                           the desktop checks; then build a module against its headers, check
#                           that the opt-in left GRUB alone, follow its advice, regenerate the
#                           disk's GRUB menu and check that the ordinary kernel still boots from
#                           it by default.
#   GOOARCHY_VM_KERNEL_JOBS kernel build parallelism (default 2; use 1 on a shared host)
#   GOOARCHY_VM_DIR         work directory (default ~/.cache/gooarchy-vm-test): image, disk, logs
#   GOOARCHY_VM_IMAGE_URL   Arch cloud image (default: the latest official one; to repeat a run,
#                           use the dated image named in its manifest.json)
#   GOOARCHY_VM_IMAGE_SHA256  expected checksum of that image (checked on every run when set)
#   GOOARCHY_VM_QEMU_BIN    directory holding qemu-system-x86_64 and qemu-img (default: the copy
#                           tests/vm/fetch-qemu.sh unpacked, else PATH)
#   GOOARCHY_VM_GPU         virgl (default: guest GL through the host GPU) or software (llvmpipe on
#                           standard VGA)
#   GOOARCHY_VM_RENDERNODE  host render node for virgl (default: the first /dev/dri/renderD*)
#   GOOARCHY_VM_SIZE        requested guest screen size in virgl mode (default 1920x1080)
#   GOOARCHY_VM_VNC         1: show the screen over VNC on 127.0.0.1:5900 (software graphics only)
#   GOOARCHY_VM_REBUILD_REF Scottland commit for rebuild-check (default: a later commit whose
#                           PKGBUILD has the same version as the pinned one)
#   GOOARCHY_VM_MEMORY, GOOARCHY_VM_CPUS, GOOARCHY_VM_DISK   (default 6144 MiB, 4, 40G)
#   The guest's pacman cache is kept in GOOARCHY_VM_DIR/pkgcache (shared into the guest over 9p).
#   GOOARCHY_VM_SSH_PORT    host port forwarded to the guest's SSH (default 2222, bound to loopback)
#   GOOARCHY_VM_PROXY       proxy URL for machines whose own connection can't be used (e.g.
#                           socks5h://127.0.0.1:1080): used for the image download and, with
#                           127.0.0.1 rewritten to the host as the guest sees it, inside the guest.
#                           Test-only; Gooarchy's installer knows nothing about it.
#   GOOARCHY_VM_KERNEL      1: pass --kernel when the integrated Gooarchy kernel step is present
# The NVIDIA wrapper sets GOOARCHY_TEST_NVIDIA_DEVICES only for its test commands. Ordinary install
# runs leave the synthetic sysfs override unset.
# Host needs: x86_64 Linux with KVM (/dev/kvm), QEMU (or tests/vm/fetch-qemu.sh), with virgl a
# usable render node, plus python3, ssh/ssh-keygen, curl, git, tar.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd -- "$here/../.." && pwd)
source "$here/qemu-graphics.sh"
dir=${GOOARCHY_VM_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/gooarchy-vm-test}
image_url=${GOOARCHY_VM_IMAGE_URL:-https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2}
gpu=${GOOARCHY_VM_GPU:-virgl}
size=${GOOARCHY_VM_SIZE:-1920x1080}
memory=${GOOARCHY_VM_MEMORY:-6144}
disk=${GOOARCHY_VM_DISK:-40G}
cpus=${GOOARCHY_VM_CPUS:-4}
kernel_jobs=${GOOARCHY_VM_KERNEL_JOBS:-2}
[[ $kernel_jobs =~ ^[1-9][0-9]*$ ]] || { echo "invalid GOOARCHY_VM_KERNEL_JOBS" >&2; exit 2; }
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

# A check made by the harness itself (results land in harness-checks.json next to guest-check's).
hcheck() {
  local name=$1 ok=$2 detail=${3:-}
  python3 - "$(artifacts)/harness-checks.json" "$name" "$ok" "$detail" <<'EOF'
import json, os, sys
path, name, ok, detail = sys.argv[1:]
data = json.load(open(path)) if os.path.exists(path) else {"failures": 0, "results": []}
data["results"].append({"check": name, "ok": ok == "1", "detail": detail})
data["failures"] = sum(not r["ok"] for r in data["results"])
json.dump(data, open(path, "w"), indent=1)
EOF
  if [[ $ok == 1 ]]; then log "PASS $name${detail:+: $detail}"; else log "FAIL $name${detail:+: $detail}"; fi
}

artifacts() {
  # One directory per run of the test, named when first needed.
  if [[ ! -f $run/artifacts ]]; then
    local stamp; stamp=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$dir/artifacts/$stamp"
    echo "$dir/artifacts/$stamp" >"$run/artifacts"
  fi
  cat "$run/artifacts"
}

nvidia_test_stamp() {
  [[ -s $run/nvidia-test-stamp ]] || die "boot the guest before an NVIDIA matrix command"
  cat "$run/nvidia-test-stamp"
}

nvidia_guest_env() {
  local stamp=$1 focused_case=${GOOARCHY_VM_NVIDIA_FOCUSED_CASE:-}
  local pressure_max=${GOOARCHY_VM_NVIDIA_PRESSURE_MAX_KB:-4194304}
  printf 'GOOARCHY_VM_GUEST_NVIDIA_MATRIX=1 GOOARCHY_NVIDIA_REPO=$HOME/gooarchy GOOARCHY_NVIDIA_ARTIFACTS=$HOME/gooarchy-nvidia-matrix/%s GOOARCHY_VM_NVIDIA_TEST_ROOT=$HOME/gooarchy-nvidia-matrix/%s GOOARCHY_NVIDIA_TEST_STAMP=%s' \
    "$stamp" "$stamp" "$stamp"
  if [[ -n $focused_case ]]; then
    [[ $focused_case == package-hook-partial-lts ]] || die "invalid focused NVIDIA R15 case"
    printf ' GOOARCHY_VM_NVIDIA_FOCUSED_CASE=%s' "$focused_case"
  fi
  [[ $pressure_max =~ ^[0-9]+$ ]] || die "NVIDIA pressure cap must be an integer KiB value"
  ((pressure_max > 0 && pressure_max <= 4194304)) || die "NVIDIA pressure cap must be at most 4 GiB"
  printf ' GOOARCHY_VM_NVIDIA_PRESSURE_MAX_KB=%s' "$pressure_max"
}

copy_nvidia_artifacts() {
  local stamp=$1 dest
  dest=$(artifacts)/nvidia-matrix/$stamp
  mkdir -p "$dest"
  guest "test -d \$HOME/gooarchy-nvidia-matrix/$stamp && tar -C \$HOME/gooarchy-nvidia-matrix/$stamp -cf - ." |
    tar -C "$dest" -xf -
}

installer_flags() {
  local -a flags=(--yes --autologin)
  if [[ ${GOOARCHY_VM_KERNEL:-0} == 1 ]]; then
    guest 'grep -q -- --kernel ~/gooarchy/install.sh' || die "GOOARCHY_VM_KERNEL=1 but the checkout has no --kernel option"
    flags+=(--kernel)
  fi
  printf '%q ' "${flags[@]}"
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
    sha256sum "$dir/images/$name" | cut -d' ' -f1 >"$dir/images/$name.sha256-local"
  fi
  [[ -f $dir/images/$name.sha256-local ]] || sha256sum "$dir/images/$name" | cut -d' ' -f1 >"$dir/images/$name.sha256-local"
  if [[ -n ${GOOARCHY_VM_IMAGE_SHA256:-} ]]; then
    [[ $(sha256sum "$dir/images/$name" | cut -d' ' -f1) == "$GOOARCHY_VM_IMAGE_SHA256" ]] ||
      die "$dir/images/$name doesn't match GOOARCHY_VM_IMAGE_SHA256"
  fi
  echo "$dir/images/$name"
}

seed() {
  # cloud-init NoCloud seed, served over HTTP from the host: the image's default user (arch, with
  # passwordless sudo) gets this run's SSH key. Nothing else is configured here.
  [[ -f $run/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C gooarchy-vm-test -f "$run/id_ed25519"
  mkdir -p "$run/seed"
  # One instance id per disk: a new one makes cloud-init set the machine up again.
  [[ -f $run/seed/meta-data ]] ||
    printf 'instance-id: gooarchy-vm-%s\nlocal-hostname: gooarchy-vm\n' "$(date +%s)" >"$run/seed/meta-data"
  cat >"$run/seed/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "$run/id_ed25519.pub")
EOF
  local seed_port
  seed_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  python3 -m http.server --bind 127.0.0.1 --directory "$run/seed" "$seed_port" \
    >"$run/seed-http.log" 2>&1 </dev/null &
  echo $! >"$run/seed-http.pid"
  echo "$seed_port"
}

ensure_seed() {
  # cloud-init asks for its seed at every boot; without it, it re-initializes the instance (new
  # host keys, no SSH key). Keep serving it on the port the guest was booted with.
  seed_running && return 0
  local seed_port
  seed_port=$(tr '\0' '\n' <"/proc/$(cat "$run/qemu.pid")/cmdline" | sed -n 's|.*10\.0\.2\.100:\([0-9]*\)/.*|\1|p')
  python3 -m http.server --bind 127.0.0.1 --directory "$run/seed" "$seed_port" \
    >"$run/seed-http.log" 2>&1 </dev/null &
  echo $! >"$run/seed-http.pid"
}

seed_running() {
  local pid
  local -a args
  [[ -f $run/seed-http.pid ]] || return 1
  pid=$(cat "$run/seed-http.pid")
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  mapfile -d '' -t args 2>/dev/null <"/proc/$pid/cmdline" || return 1
  [[ ${args[0]:-} == */python3 || ${args[0]:-} == python3 ]] &&
    [[ ${args[1]:-} == -m && ${args[2]:-} == http.server &&
       ${args[3]:-} == --bind && ${args[4]:-} == 127.0.0.1 &&
       ${args[5]:-} == --directory && ${args[6]:-} == "$run/seed" ]]
}

stop_seed() {
  seed_running && kill "$(cat "$run/seed-http.pid")" 2>/dev/null || true
  rm -f "$run/seed-http.pid"
}

running() {
  # A PID file can survive a host restart; verify the process before stop/kill uses it.
  local pid arg
  local -a args
  [[ -f $run/qemu.pid ]] || return 1
  pid=$(cat "$run/qemu.pid")
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  mapfile -d '' -t args 2>/dev/null <"/proc/$pid/cmdline" || return 1
  [[ ${args[0]:-} == */qemu-system-x86_64 || ${args[0]:-} == qemu-system-x86_64 ]] || return 1
  for arg in "${args[@]}"; do
    [[ $arg == "file=$run/disk.qcow2,if=virtio,discard=unmap" ]] && return 0
  done
  return 1
}

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
  mkdir -p "$(dirname "$out")"
  local reply
  if reply=$(python3 "$here/qmp.py" "$run/qmp.sock" screendump "{\"filename\": \"$out\", \"format\": \"png\"}"); then
    log "screendump $out"
  else
    log "screendump unavailable: $reply"
  fi
}

cmd_boot() {
  cmd_stop
  local image
  image=$(fetch_image)
  rm -rf "$run/disk.qcow2" "$run/artifacts" "$run/seed"
  python3 -c 'import uuid; print(uuid.uuid4().hex)' >"$run/nvidia-test-stamp"
  # Never smaller than the image (that would cut its partitions off); cloud-init grows the root
  # partition into the rest on first boot.
  "$qemu_img" create -q -f qcow2 -F qcow2 -b "$image" "$run/disk.qcow2" "$disk"
  start_qemu
  log "guest is up: $(guest 'uname -r; . /etc/os-release; echo $PRETTY_NAME' | tr '\n' ' ')"
  prepare_guest
}

cmd_start() {
  # Boot the existing disk again (after stop), e.g. to look at an installed system.
  cmd_stop
  [[ -f $run/disk.qcow2 ]] || die "no disk yet (tests/vm/run.sh boot)"
  start_qemu
  log "guest is up"
}

start_qemu() {
  local seed_port seed_bridge_command
  local -a display
  local kernel_args=()
  if [[ ${GOOARCHY_VM_KERNEL_BOOT:-0} == 1 ]]; then
    [[ -s $run/kernel/vmlinuz && -s $run/kernel/initramfs.img && -s $run/kernel/cmdline ]] ||
      die "candidate kernel boot files are missing"
    kernel_args=(-kernel "$run/kernel/vmlinuz" -initrd "$run/kernel/initramfs.img"
                 -append "$(cat "$run/kernel/cmdline")")
  fi
  qemu_graphics_args display "$gpu" "$size" "${GOOARCHY_VM_VNC:-}" || die "invalid VM graphics configuration"
  seed_port=$(seed)
  printf -v seed_bridge_command 'python3 %q %q' "$here/seed-http-bridge.py" "$seed_port"
  [[ -w /dev/kvm ]] || die "needs /dev/kvm"
  mkdir -p "$dir/pkgcache"
  log "booting ($gpu, ${size}, ${memory} MiB, $cpus CPUs)"
  # Keep QEMU in this process group so a test runner can clean it up with the wrapper.
  # guestfwd connects NoCloud requests to the loopback seed server without host-address access.
  "$qemu" -name gooarchy-vm -enable-kvm -cpu host -smp "$cpus" -m "$memory" -machine q35 \
    "${kernel_args[@]}" \
    -drive "file=$run/disk.qcow2,if=virtio,discard=unmap" \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$port-:22,guestfwd=tcp:10.0.2.100:$seed_port-cmd:$seed_bridge_command" \
    -smbios "type=1,serial=ds=nocloud;s=http://10.0.2.100:$seed_port/" \
    "${display[@]}" -audiodev none,id=noaudio -device intel-hda -device hda-duplex,audiodev=noaudio \
    -device virtio-tablet-pci -device virtio-keyboard-pci \
    -virtfs "local,path=$dir/pkgcache,mount_tag=gooarchy-pkgcache,security_model=mapped-xattr,id=pkgcache" \
    -serial "file:$run/serial.log" -qmp "unix:$run/qmp.sock,server,nowait" -pidfile "$run/qemu.pid" \
    >"$run/qemu.log" 2>&1 </dev/null &
  sleep 2
  running || die "QEMU didn't start: $(cat "$run/qemu.log")"
  wait_ssh 300
}

prepare_guest() {
  # Test-only: the guest's clock comes from QEMU's RTC, and a test machine may not pass NTP
  # through, which would leave systemd-time-wait-sync (and the cloud image's pacman-init, and
  # sshd after it) waiting forever on the next boot.
  guest 'sudo systemctl mask --quiet systemd-time-wait-sync.service'
  if [[ -n $proxy ]]; then
    # Test-only: let sudo (pacman, makepkg -s) keep the proxy variables.
    guest 'echo "Defaults env_keep += \"ALL_PROXY all_proxy HTTPS_PROXY https_proxy HTTP_PROXY http_proxy\"" |
           sudo tee /etc/sudoers.d/90-vm-test-proxy >/dev/null && sudo chmod 440 /etc/sudoers.d/90-vm-test-proxy'
  fi
  # Test-only: pacman's package cache lives on the host (shared over 9p), so reruns don't download
  # everything again; slow links get no download timeout. Pacman's unprivileged download user cannot
  # write the 9p mount (mapped-xattr), so the download sandbox is off in this disposable guest.
  guest 'sudo mkdir -p /var/cache/pacman/vm-test &&
         echo "gooarchy-pkgcache /var/cache/pacman/vm-test 9p trans=virtio,version=9p2000.L,msize=1048576,nofail 0 0" |
           sudo tee -a /etc/fstab >/dev/null && sudo systemctl daemon-reload && sudo mount /var/cache/pacman/vm-test &&
         sudo sed -i -e "s|^#\\?CacheDir.*|CacheDir = /var/cache/pacman/vm-test/|" \
                     -e "s|^#\\?ParallelDownloads.*|ParallelDownloads = 3\\nDisableDownloadTimeout\\nDisableSandbox|" /etc/pacman.conf'
  guest 'grep -E "^(CacheDir|ParallelDownloads|DisableDownloadTimeout|DisableSandbox)" /etc/pacman.conf' >&2
  # The cloud image is a minimal install; make sure its package databases are current before the
  # installer runs, as a freshly installed system's would be.
  guest "sudo $(guest_proxy_env) pacman -Sy --noconfirm >/dev/null"
}

copy_checkout() {
  log "copying the checkout (tracked and untracked files, and its history) into the guest"
  (cd "$repo" && { git ls-files -co --exclude-standard -z; printf '.git\0'; } | tar --null -T - -cf -) |
    guest 'rm -rf ~/gooarchy && mkdir ~/gooarchy && tar -C ~/gooarchy -xf -'
}

cmd_install() {
  running || die "the guest isn't running (tests/vm/run.sh boot)"
  local out; out=$(artifacts)
  copy_checkout
  local flags; flags=$(installer_flags)
  local status=0
  local kernel_build_env=
  if [[ ${GOOARCHY_VM_KERNEL:-0} == 1 ]]; then
    kernel_build_env=MAKEFLAGS=-j$kernel_jobs
    grub_snapshot
  fi
  if [[ ${GOOARCHY_VM_RETRY_TEST:-1} == 1 ]]; then
    # A failed attempt (made to fail at the Strata step), then a retry that must complete.
    log "running ./install.sh, made to fail at packaging/strata.sh (log: $out/install-failed-attempt.log)"
    guest "cd ~/gooarchy && GOOARCHY_TEST_FAIL_AT=packaging/strata.sh $(guest_proxy_env) ./install.sh $flags" \
      >"$out/install-failed-attempt.log" 2>&1 || status=$?
    local last; last=$(guest 'cat ~/.local/state/gooarchy/last-step 2>/dev/null')
    local ok=0
    [[ $status != 0 && $last == packaging/scottland.sh ]] &&
      grep -q 'last completed: packaging/scottland.sh' "$out/install-failed-attempt.log" && ok=1
    hcheck "an install that fails at a step stops there and says what completed" "$ok" \
      "exit $status, last completed step: $last"
    status=0
  fi
  log "running ./install.sh $flags (log: $out/install.log)"
  guest "cd ~/gooarchy && $kernel_build_env $(guest_proxy_env) ./install.sh $flags" >"$out/install.log" 2>&1 || status=$?
  tail -n 30 "$out/install.log" >&2
  guest 'tar -C ~/.local/state/gooarchy -cf - logs builds.tsv reports.log 2>/dev/null' | tar -C "$out" -xf - 2>/dev/null || true
  hcheck "./install.sh completes (after the failed attempt, when the retry test runs)" "$(( status == 0 ))" "exit $status"
  if [[ ${GOOARCHY_VM_RETRY_TEST:-1} == 1 ]]; then
    local attempts; attempts=$(guest 'ls ~/.local/state/gooarchy/logs | wc -l')
    local manifests; manifests=$(guest 'ls ~/.local/state/gooarchy/logs/*/packages-{before,after}.txt 2>/dev/null | wc -l')
    hcheck "each attempt keeps its own log and package manifests" "$(( attempts >= 2 && manifests >= 4 ))" \
      "$attempts attempt logs, $manifests manifests"
  fi
  (( status == 0 )) || die "install.sh exited with $status"
  if [[ ${GOOARCHY_VM_KERNEL:-0} == 1 ]]; then
    prepare_kernel_boot
  fi
  log "install finished"
}

cmd_install_observation() {
  running || die "the guest isn't running"
  local phase=$1
  [[ $phase == fresh-install || $phase == ordinary-rerun ]] || die "unknown install observation phase: $phase"
  local out; out=$(artifacts)
  local phase_out="/tmp/gooarchy-check/out/$phase"
  mkdir -p "$out/install-observation-$phase"
  log "checking Xwayland and linux-firmware after $phase"
  local status=0
  guest "timeout 240 python3 ~/gooarchy/tests/vm/guest-check.py '$phase_out' --install-observation '$phase'" \
    >"$out/install-observation-$phase.log" 2>&1 || status=$?
  guest "mkdir -p '$phase_out' && tar -C '$phase_out' -cf - ." |
    tar -C "$out/install-observation-$phase" -xf - || true
  hcheck "install-boundary Xwayland/firmware observation completes ($phase)" "$(( status == 0 ))" \
    "exit $status; guest report: install-observation-$phase/results.json"
  return "$status"
}

cmd_install_rerun() {
  running || die "the guest isn't running"
  local out; out=$(artifacts)
  local status=0
  log "running ordinary ./install.sh --yes after the fresh-install observation"
  guest "cd ~/gooarchy && $(guest_proxy_env) ./install.sh --yes" >"$out/install-ordinary-rerun.log" 2>&1 || status=$?
  hcheck "ordinary ./install.sh --yes rerun completes" "$(( status == 0 ))" "exit $status"
  return "$status"
}

prepare_kernel_boot() {
  mkdir -p "$run/kernel"
  guest 'sudo cat /boot/vmlinuz-linux-gooarchy' >"$run/kernel/vmlinuz"
  guest 'sudo cat /boot/initramfs-linux-gooarchy.img' >"$run/kernel/initramfs.img"
  guest 'sed -E "s/(^| )BOOT_IMAGE=[^ ]*//g" /proc/cmdline' >"$run/kernel/cmdline"
  guest 'pacman -Qlq linux-gooarchy | sed -n "s|/usr/lib/modules/\([^/]*\)/pkgbase|\1|p"' >"$run/kernel/version"
  [[ $(cat "$run/kernel/version") =~ ^[a-zA-Z0-9._+-]+-gooarchy$ ]] || die "cannot identify the candidate kernel"
  export GOOARCHY_VM_KERNEL_BOOT=1
}

cmd_kernel_check() {
  # An already installed test VM: exercise just the installer kernel step, then boot and test.
  running || die "the guest isn't running"
  local out; out=$(artifacts)
  copy_checkout
  grub_snapshot
  guest "cd ~/gooarchy && export GOOARCHY_PATH=\$PWD GOOARCHY_INSTALL=\$PWD/install
         export GOOARCHY_STATE=\$HOME/.local/state/gooarchy GOOARCHY_BUILD=\$HOME/.cache/gooarchy/build
         export GOOARCHY_INSTALL_LOG_FILE=\$GOOARCHY_STATE/kernel-check-install.log
         MAKEFLAGS=-j$kernel_jobs $(guest_proxy_env) bash -e -o pipefail install/packaging/kernel.sh" >"$out/kernel-install.log" 2>&1
  cmd_kernel_boot_check
}

cmd_kernel_boot_check() {
  # Boot an already installed candidate, e.g. after an interrupted build was recovered.
  running || die "the guest is not running"
  prepare_kernel_boot
  cmd_reboot
  local status=0
  cmd_check || status=$?
  kernel_headers_check
  kernel_bootloader_check
  return "$status"
}

grub_snapshot() {
  # The disk bootloader before the kernel opt-in: GRUB's menu (hash) and /etc/default/grub.
  mkdir -p "$run/kernel"
  guest 'sudo sha256sum /boot/grub/grub.cfg | cut -d" " -f1; cat /etc/default/grub' >"$run/kernel/grub-before.txt"
  cp "$run/kernel/grub-before.txt" "$(artifacts)/grub-before-kernel.txt"
}

kernel_headers_check() {
  # The installed headers build an external module whose version magic is the candidate's.
  local result ok=0
  result=$(guest 'bash -s' 2>&1 <<'EOF'
set -euo pipefail
version=$(pacman -Qlq linux-gooarchy | sed -n 's|/usr/lib/modules/\([^/]*\)/pkgbase|\1|p')
dir=$(mktemp -d /tmp/gooarchy-header-probe.XXXXXX)
trap 'rm -rf "$dir"' EXIT
cat >"$dir/gooarchy_probe.c" <<'SOURCE'
#include <linux/module.h>
static int __init probe_init(void) { return 0; }
static void __exit probe_exit(void) { }
module_init(probe_init);
module_exit(probe_exit);
MODULE_LICENSE("GPL");
SOURCE
echo 'obj-m += gooarchy_probe.o' >"$dir/Makefile"
make -C "/usr/lib/modules/$version/build" M="$dir" modules >"$dir/make.log" 2>&1 || { tail -n 20 "$dir/make.log"; exit 1; }
vermagic=$(modinfo -F vermagic "$dir/gooarchy_probe.ko")
echo "built against $version; vermagic: $vermagic"
[[ $vermagic == "$version "* ]]
EOF
  ) && ok=1
  echo "$result" >"$(artifacts)/kernel-headers-probe.log"
  hcheck "the installed linux-gooarchy headers build an external module for it" "$ok" "$(tail -n 1 <<<"$result")"
}

kernel_bootloader_check() {
  # The disk bootloader after the opt-in: GRUB's menu and /etc/default/grub exactly as they were.
  # Then a user's next steps: add the GRUB_TOP_LEVEL line the opt-in printed, regenerate the menu
  # (how linux-gooarchy gets into it), and the ordinary kernel still boots by default, through the
  # disk's own GRUB.
  local out; out=$(artifacts)
  local after=$out/grub-after-kernel.txt before=$run/kernel/grub-before.txt ok=0
  guest 'sudo sha256sum /boot/grub/grub.cfg | cut -d" " -f1; cat /etc/default/grub' >"$after"
  if [[ -f $before ]]; then
    cmp -s "$before" "$after" && ok=1
    hcheck "the kernel opt-in leaves GRUB's menu and /etc/default/grub as they were" "$ok" \
      "$(diff "$before" "$after" | head -n 5)"
  else
    log "no GRUB state from before the kernel opt-in; not comparing"
  fi
  # Regenerating as it stands, for comparison only (left in a scratch file).
  guest 'sudo grub-mkconfig -o /tmp/grub-control.cfg >/dev/null 2>&1; s=$?; sudo cat /tmp/grub-control.cfg; sudo rm -f /tmp/grub-control.cfg; exit $s' \
    >"$out/grub-control-without-top-level.cfg" || die "control regeneration failed"
  if guest 'grep -q "^GRUB_TOP_LEVEL=" /etc/default/grub'; then
    log "/etc/default/grub already sets GRUB_TOP_LEVEL; not adding the opt-in's advice"
  else
    local advice
    advice=$(guest 'grep -o "GRUB_TOP_LEVEL=\"/boot/[^\"]*\"" ~/.local/state/gooarchy/reports.log | tail -n 1')
    ok=0
    [[ $advice =~ ^GRUB_TOP_LEVEL=\"/boot/vmlinuz-[^\"]+\"$ && $advice != *vmlinuz-linux-gooarchy* ]] && ok=1
    hcheck "the kernel opt-in reports the GRUB_TOP_LEVEL line that keeps the booted kernel the default" "$ok" \
      "advice: ${advice:-none}"
    (( ok )) || die "no GRUB_TOP_LEVEL advice to follow"
    guest "printf '%s\\n' '$advice' | sudo tee -a /etc/default/grub >/dev/null"
  fi
  guest 'sudo grub-mkconfig -o /boot/grub/grub.cfg' >"$out/grub-mkconfig.log" 2>&1 || die "grub-mkconfig failed"
  guest 'sudo cat /boot/grub/grub.cfg' >"$out/grub-regenerated.cfg"
  local first control offered=0
  first=$(awk '$1 == "linux" {print $2; exit}' "$out/grub-regenerated.cfg")
  control=$(awk '$1 == "linux" {print $2; exit}' "$out/grub-control-without-top-level.cfg")
  grep -qE '^\s*linux\s+\S*/vmlinuz-linux-gooarchy\s' "$out/grub-regenerated.cfg" && offered=1
  hcheck "the regenerated GRUB menu offers linux-gooarchy" "$offered"
  boot_disk
  local version stock
  version=$(guest 'uname -r')
  stock=$(guest 'pacman -Qlq linux | sed -n "s|/usr/lib/modules/\([^/]*\)/pkgbase|\1|p"')
  guest 'cat /proc/cmdline' >"$out/stock-boot-cmdline.txt"
  ok=0
  [[ -n $stock && $version == "$stock" && ${first##*/} == vmlinuz-linux ]] && ok=1
  hcheck "with that line added and GRUB regenerated, the disk bootloader boots the ordinary kernel by default" "$ok" \
    "booted $version (ordinary: $stock); first entry $first; without GRUB_TOP_LEVEL it would be $control"
}

boot_disk() {
  # Power the guest off properly, then boot it through its own disk bootloader.
  guest 'sudo systemctl poweroff' || true
  local deadline=$((SECONDS + 120))
  while running && (( SECONDS < deadline )); do sleep 2; done
  export GOOARCHY_VM_KERNEL_BOOT=0
  cmd_stop
  start_qemu
  log "booted from the disk: $(guest 'uname -r')"
}

qemu_uses_direct_kernel() {
  running || return 1
  local pid
  pid=$(cat "$run/qemu.pid") || return 1
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  tr '\0' '\n' <"/proc/$pid/cmdline" | grep -Fxq -- -kernel
}

prepare_r15_grub() {
  local row=$1 out log_path
  # R15 needs a real disk-bootloader reboot for every sound kernel. If the optional-kernel
  # acceptance left QEMU running with -kernel, return to the disk first; changing a shell flag
  # cannot change the arguments of an already running emulator.
  if qemu_uses_direct_kernel; then
    log "R15 is switching from QEMU direct-kernel boot to the guest's disk GRUB"
    boot_disk
  fi
  export GOOARCHY_VM_KERNEL_BOOT=0
  guest 'command -v grub-mkconfig >/dev/null && command -v grub-reboot >/dev/null && test -d /boot/grub' ||
    die "R15 per-kernel checks require the fixture's GRUB bootloader"
  out=$(artifacts)
  log_path=$out/r15-grub-mkconfig-$row.log
  guest 'sudo grub-mkconfig -o /boot/grub/grub.cfg' >"$log_path" 2>&1 || {
    tail -n 30 "$log_path" >&2
    die "could not prepare GRUB entries for the held R15 kernels"
  }
  guest 'test -s /boot/grub/grub.cfg' || die "GRUB did not leave a usable menu for the held R15 kernels"
}

r15_grub_selector() {
  local grub_cfg=$1 pkgbase=$2
  python3 - "$grub_cfg" "$pkgbase" <<'PY'
import os
import re
import sys

path, pkgbase = sys.argv[1:]
lines = open(path, encoding="utf-8").read().splitlines()
stack = []
depth = 0
entries = []

for line in lines:
    header = re.match(r"^\s*(submenu|menuentry)\s+", line)
    delta = line.count("{") - line.count("}")
    if header:
        kind = header.group(1)
        menu_id = re.search(r"\$menuentry_id_option\s+(['\"])([^'\"]+)\1", line)
        title = re.match(r"^\s*(?:submenu|menuentry)\s+(['\"])(.*?)\1", line)
        node = {
            "kind": kind,
            "id": menu_id.group(2) if menu_id else None,
            "title": title.group(2) if title else "",
            "level": depth + delta,
            "linux": [],
            "initrd": [],
        }
        stack.append(node)
        if kind == "menuentry":
            node["selector_parts"] = [
                parent["id"] for parent in stack
                if parent["kind"] in ("submenu", "menuentry")
            ]
            entries.append(node)
    else:
        entry = next((node for node in reversed(stack) if node["kind"] == "menuentry"), None)
        if entry is not None:
            linux = re.match(r"^\s*linux(?:efi)?\s+(\S+)", line)
            if linux:
                entry["linux"].append(linux.group(1))
            initrd = re.match(r"^\s*initrd(?:efi)?\s+(.+)$", line)
            if initrd:
                entry["initrd"].extend(initrd.group(1).split())

    depth += delta
    while stack and stack[-1]["level"] > depth:
        stack.pop()

matches = []
for entry in entries:
    if not any(os.path.basename(image) == "vmlinuz-" + pkgbase for image in entry["linux"]):
        continue
    if not entry["initrd"]:
        continue
    parts = entry["selector_parts"]
    if not parts or any(not part for part in parts):
        continue
    selector = ">".join(parts)
    if not re.fullmatch(r"[A-Za-z0-9_.+-]+(?:>[A-Za-z0-9_.+-]+)*", selector):
        continue
    fallback = any("fallback" in os.path.basename(image).lower() for image in entry["initrd"])
    matches.append((fallback, selector, entry["title"]))

regular = [candidate for candidate in matches if not candidate[0]]
if not regular:
    raise SystemExit(f"no non-fallback GRUB entry with an initrd for vmlinuz-{pkgbase}")
print(regular[0][1])
PY
}

plugin_state() {
  guest 'printf "%s %s\n" "$(pacman -Q scottland | cut -d" " -f2)" \
           "$(sha256sum "$(pacman -Qlq scottland | grep "/libscottland.so$")" | cut -c1-16)"'
}

cmd_rebuild_check() {
  # A branch rebuild (or one for another Wayfire) must still replace the installed plugin, and
  # the package version must say what was built.
  running || die "the guest isn't running"
  local out; out=$(artifacts)
  local other=${GOOARCHY_VM_REBUILD_REF:-0.3}
  local other_kind=${GOOARCHY_VM_REBUILD_REF_KIND:-branch}
  local a b c d other_commit default_version status=0
  a=$(plugin_state)
  guest "cd ~/gooarchy && GOOARCHY_SCOTTLAND_REF=$other GOOARCHY_SCOTTLAND_REF_KIND=$other_kind $(guest_proxy_env) ./install.sh --yes" >"$out/rebuild-b.log" 2>&1 || status=$?
  b=$(plugin_state)
  other_commit=$(guest "awk -F '\t' '\$1 == \"scottland\" { ref = \$3 } END { print ref }' ~/.local/state/gooarchy/builds.tsv")
  local ok=0
  [[ $status == 0 && $other_commit =~ ^[[:xdigit:]]{40}$ &&
    ${a#* } != "${b#* }" && $b == *g${other_commit:0:7}* ]] && ok=1
  hcheck "rebuilding Scottland from a branch pin replaces the installed plugin" "$ok" \
    "A: $a; B: $b; branch resolved to $other_commit"
  status=0
  guest "cd ~/gooarchy && $(guest_proxy_env) ./install.sh --yes" >"$out/rebuild-a.log" 2>&1 || status=$?
  c=$(plugin_state)
  ok=0
  default_version=${c%% *}
  [[ $status == 0 && $default_version =~ \.g[[:xdigit:]]{7}\.wf &&
    ${c#* } != "${b#* }" ]] && ok=1
  hcheck "returning to the configured main pin replaces the branch build" "$ok" "now: $c"
  status=0
  guest "cd ~/gooarchy && $(guest_proxy_env) ./install.sh --yes" >"$out/rebuild-same.log" 2>&1 || status=$?
  d=$(plugin_state)
  local reinstalled; reinstalled=$(guest 'grep -c "reinstalled scottland" /var/log/pacman.log')
  ok=0
  [[ $status == 0 && $reinstalled -gt 0 && $d == "$c" ]] && ok=1
  hcheck "an identical rebuild is installed too (not skipped as already installed)" "$ok" \
    "pacman.log 'reinstalled scottland': $reinstalled; now: $d"
  guest 'pacman -Qi scottland | grep -E "^(Version|Depends On)"' | tee "$out/scottland-package.txt" >&2
  hcheck "the scottland package depends on the exact Wayfire it was built for" \
    "$(grep -q 'wayfire=[0-9]' "$out/scottland-package.txt" && echo 1 || echo 0)"
}

cmd_upgrade_guard() {
  # A Wayfire newer than the one Scottland was built for must not install over it silently.
  running || die "the guest isn't running"
  local out; out=$(artifacts)
  guest 'set -e; d=$(mktemp -d); cd "$d"; v=$(pacman -Q wayfire | cut -d" " -f2); v=${v%-*}
         cat >PKGBUILD <<EOF
pkgname=wayfire
pkgver=$v.99
pkgrel=1
arch=(any)
package() { :; }
EOF
         makepkg -f >/dev/null 2>&1; ls "$d"/wayfire-*.pkg.tar.* >~/fake-wayfire-path'
  local result status=0
  result=$(guest 'sudo pacman -U --noconfirm "$(cat ~/fake-wayfire-path)" 2>&1') || status=$?
  echo "$result" >"$out/upgrade-guard.log"
  local ok=0
  [[ $status != 0 ]] && grep -q 'required by scottland' <<<"$result" && ok=1
  hcheck "pacman refuses a newer Wayfire under the Scottland built for this one" "$ok" \
    "$(grep -m1 -E 'breaks dependency|required by' <<<"$result")"
}
# What Rust toolchain the guest has, if any: nothing when there is none.
guest_toolchain() {
  guest '{ pacman -Qq rust rustup 2>/dev/null; command -v cargo rustc; ls ~/.cargo/bin/cargo 2>/dev/null; } || true'
}

cmd_no_toolchain() {
  # The Rust toolchain is optional (docs/rulings.md): the gooarchy package doesn't require it, the
  # install leaves none behind, and on this guest without one the built package installs again
  # without pulling one in, and the gooarchy command runs. The package is the one install.sh built
  # from this checkout; the toolchain was there only for that build.
  running || die "the guest isn't running"
  local out; out=$(artifacts)
  local deps; deps=$(guest 'awk '\''/^%/ { s = $0; next } NF && s == "%DEPENDS%" { print "depends " $0 }
                                 NF && s == "%OPTDEPENDS%" { print "optdepends " $0 }'\'' /var/lib/pacman/local/gooarchy-[0-9]*/desc')
  echo "$deps" >"$out/gooarchy-dependencies.txt"
  local ok=0
  grep -q '^optdepends rust:' <<<"$deps" && ! grep -qE '^depends (rust|rustup|cargo)([<>=]|$)' <<<"$deps" && ok=1
  hcheck "the gooarchy package lists the Rust toolchain as optional, not required" "$ok" \
    "$(grep -E '^(opt)?depends (rust|rustup|cargo)' <<<"$deps" | tr '\n' ' ')"
  local left; left=$(guest_toolchain)
  hcheck "the install leaves no Rust toolchain behind" "$([[ -z $left ]] && echo 1 || echo 0)" "$left"

  local status=0
  guest 'source ~/gooarchy/install/helpers/packages.sh &&
         GOOARCHY_PATH=~/gooarchy built_files ~/.cache/gooarchy/build/gooarchy-packaging gooarchy >~/no-toolchain-package &&
         sudo pacman -U --noconfirm "$(cat ~/no-toolchain-package)"' >"$out/no-toolchain-install.log" 2>&1 || status=$?
  local after; after=$(guest_toolchain)
  ok=0
  [[ $status == 0 && -z $left && -z $after ]] && ok=1
  hcheck "without a Rust toolchain, the built gooarchy package installs without pulling one in" "$ok" \
    "exit $status; toolchain before: ${left:-none}, after: ${after:-none}"
  local built head
  built=$(guest 'sed -n "s/^checkout \([0-9a-f]*\).*/\1/p" /usr/share/gooarchy/build-info')
  head=$(guest 'git -C ~/gooarchy rev-parse HEAD')
  hcheck "the installed package is built from the checkout under test" "$([[ -n $head && $built == "$head" ]] && echo 1 || echo 0)" \
    "build-info: $built; checkout: $head"
  local listing; listing=$(guest 'gooarchy' 2>&1) || true
  ok=0
  grep -qx '  theme' <<<"$listing" && [[ -z $(guest_toolchain) ]] && ok=1
  hcheck "gooarchy runs without a Rust toolchain" "$ok" "$(head -c 300 <<<"$listing")"
}

cmd_reboot() {
  running || die "the guest isn't running"
  if [[ ${GOOARCHY_VM_KERNEL_BOOT:-0} == 1 ]]; then
    # QMP quit stops the emulator without shutting down the guest. Persist the
    # just-installed modules and package database before replacing its kernel.
    guest 'sync'
    cmd_stop
    start_qemu
    local version correct=0; version=$(guest 'uname -r')
    [[ $version == "$(cat "$run/kernel/version")" ]] && correct=1
    hcheck "the VM runs the opt-in Gooarchy kernel" "$correct" "$version"
    ((correct)) || die "the VM booted a different kernel ($version)"
    log "rebooted into $version (direct kernel boot; disk bootloader unchanged)"
    return
  fi
  ensure_seed
  local before; before=$(guest 'cat /proc/sys/kernel/random/boot_id')
  guest 'sudo systemctl reboot' || true
  local deadline=$((SECONDS + 300))
  until [[ $(guest 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) =~ ^[0-9a-f-]+$ &&
           $(guest 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) != "$before" ]]; do
    running || die "QEMU exited; see $run/qemu.log"
    (( SECONDS < deadline )) || die "the guest didn't come back from the reboot"
    sleep 5
  done
  log "rebooted"
}

cmd_check() {
  running || die "the guest isn't running"
  local root; root=$(artifacts)
  local suffix=${1:-} out=$root relative=.
  if [[ -n $suffix ]]; then
    [[ $suffix =~ ^[[:alnum:]_.+-]+$ ]] || die "invalid guest-check artifact suffix"
    out=$root/session-checks/$suffix
    relative=session-checks/$suffix
    mkdir -p "$out"
  fi
  screendump "$relative/vm-display-before-check.png"
  guest 'rm -rf /tmp/gooarchy-check && mkdir -p /tmp/gooarchy-check'
  guest 'cat >/tmp/gooarchy-check/guest-check.py' <"$here/guest-check.py"
  log "checking the session in the guest"
  local status=0
  guest "timeout 1500 python3 /tmp/gooarchy-check/guest-check.py /tmp/gooarchy-check/out --gpu $gpu" 2>&1 |
    tee "$out/guest-check.log" >&2 || status=$?
  screendump "$relative/vm-display-after-check.png"
  guest 'cd /tmp/gooarchy-check/out && tar -cf - .' | tar -C "$out" -xf - || true
  guest 'journalctl -b --no-pager -o short-monotonic' >"$out/journal.log" 2>/dev/null || true
  guest 'cat ~/.local/state/scottland/wayfire.log' >"$out/wayfire-last-session.log" 2>/dev/null || true
  guest 'cat ~/.local/state/scottland/wayfire.log.previous' >"$out/wayfire-previous-session.log" 2>/dev/null || true
  cp "$run/serial.log" "$out/serial.log" 2>/dev/null || true
  log "artifacts: $out"
  return "$status"
}

cmd_nvidia_matrix() {
  running || die "the guest isn't running"
  local phase=${1:-} arg=${2:-} stamp env out name remote_command status=0
  case $phase in
    preflight | preinstall | postinstall | reference | focused | r15-row | r15-release) ;;
    *) die "unknown NVIDIA matrix phase: $phase" ;;
  esac
  if [[ -n $arg ]]; then
    [[ $arg =~ ^[[:alnum:]_.+-]+$ ]] || die "invalid NVIDIA matrix row"
  fi
  stamp=$(nvidia_test_stamp)
  env=$(nvidia_guest_env "$stamp")
  out=$(artifacts)
  name=nvidia-$phase${arg:+-$arg}
  remote_command="cd ~/gooarchy && env $env"
  if [[ $phase == preinstall || $phase == postinstall ]]; then
    remote_command+=" GOOARCHY_VM_NVIDIA_SKIP_R15_ROWS=1"
  fi
  remote_command+=" bash tests/vm/nvidia-matrix.sh $phase${arg:+ $arg}"
  guest "$remote_command" >"$out/$name.log" 2>&1 || status=$?
  copy_nvidia_artifacts "$stamp" || status=1
  # This status controls safe orchestration only; the guest's results.tsv contains product assertions.
  ((status == 0)) || die "NVIDIA matrix $phase${arg:+ $arg} failed; see $out/$name.log"
  tail -n 30 "$out/$name.log" >&2
}

cmd_nvidia_preflight() {
  running || die "the guest isn't running"
  copy_checkout
  cmd_nvidia_matrix preflight
}

cmd_nvidia_install() {
  running || die "the guest isn't running"
  local stamp env flags out status=0
  stamp=$(nvidia_test_stamp)
  env=$(nvidia_guest_env "$stamp")
  flags=$(installer_flags)
  out=$(artifacts)
  guest "cd ~/gooarchy && test -r \$HOME/gooarchy-nvidia-matrix/$stamp/nvidia-test-bash-env.sh && env $env BASH_ENV=\$HOME/gooarchy-nvidia-matrix/$stamp/nvidia-test-bash-env.sh GOOARCHY_TEST_NVIDIA_DEVICES=0x10de,0x030000,0x25a2,0 $(guest_proxy_env) ./install.sh $flags" \
    >"$out/nvidia-supported-install.log" 2>&1 || status=$?
  guest 'tar -C ~/.local/state/gooarchy -cf - logs builds.tsv reports.log 2>/dev/null' |
    tar -C "$out" -xf - 2>/dev/null || true
  copy_nvidia_artifacts "$stamp" || status=1
  hcheck "full install.sh completes with the supported NVIDIA test device" "$((status == 0))" \
    "exit $status; synthetic sysfs input was set only by tests/vm/run.sh"
  ((status == 0)) || die "supported NVIDIA full install failed; see $out/nvidia-supported-install.log"
}

cmd_nvidia_r15_row() {
  running || die "the guest isn't running"
  local row=${1:-} stamp test_root held_data held_row held_stamp plan_sha plan
  local kernel pkgbase grub_cfg grub_map entry_selector current_kernel boot_id suffix evidence
  local -a sound_kernels=()
  local -A kernel_pkgbase=()
  case $row in
    precommit-download | precommit-space | prebuilt-refused | linux-gooarchy-dkms | interrupt-after-commit | \
    package-hook-linux-only | package-hook-linux-partial-lts | prebuilt-linux-dkms | stale-baseline-repair-failure | \
    arch-upgrade-step-regen | arch-upgrade-hook-repaired | arch-upgrade-hook-repair-failure | pacman-commit-interruption) ;;
    *) die "unknown NVIDIA R15 row: $row" ;;
  esac
  stamp=$(nvidia_test_stamp)
  test_root='$HOME/gooarchy-nvidia-matrix/'"$stamp"

  if guest "test -f $test_root/r15-boot-held"; then
    held_data=$(guest "cat $test_root/r15-boot-held")
    IFS=$'\t' read -r held_row held_stamp plan_sha <<<"$held_data"
    [[ $held_row == "$row" && $held_stamp == "$stamp" && $plan_sha =~ ^[[:xdigit:]]{64}$ ]] ||
      die "the guest is holding a different R15 row; preserve its state and inspect the artifacts"
  else
    cmd_nvidia_matrix r15-row "$row"
  fi

  if [[ $row == pacman-commit-interruption ]]; then
    if guest "test -f $test_root/r15-boot-held"; then
      die "the pacman-commit R15 row must not create a desktop-boot hold"
    fi
    log "R15 pacman-commit acceptance uses stale-lock refusal and no-image-write evidence; no reboot or simulated interruption"
    copy_nvidia_artifacts "$stamp"
    return 0
  fi

  held_data=$(guest "cat $test_root/r15-boot-held")
  IFS=$'\t' read -r held_row held_stamp plan_sha <<<"$held_data"
  [[ $held_row == "$row" && $held_stamp == "$stamp" && $plan_sha =~ ^[[:xdigit:]]{64}$ ]] ||
    die "the R15 row did not leave a valid held-state record"
  plan=$(artifacts)/nvidia-matrix/$stamp/r15-boot-$row.tsv
  guest "cat $test_root/r15-boot-$row.tsv" >"$plan"
  [[ $(sha256sum "$plan" | awk '{print $1}') == "$plan_sha" ]] ||
    die "the copied R15 boot manifest does not match the held-state hash"
  while IFS=$'\t' read -r kind classification kernel pkgbase _; do
    if [[ $kind == kernel && $classification == sound ]]; then
      [[ $kernel =~ ^[[:alnum:]_.+-]+$ && $pkgbase =~ ^[[:alnum:]_.+-]+$ ]] ||
        die "the R15 manifest contains an invalid kernel name"
      sound_kernels+=("$kernel")
      kernel_pkgbase[$kernel]=$pkgbase
    fi
  done <"$plan"
  ((${#sound_kernels[@]} > 0)) || die "the R15 manifest has no sound kernel to boot"

  prepare_r15_grub "$row"
  grub_cfg=$(artifacts)/nvidia-matrix/$stamp/grub-r15-$row-$stamp-$$.cfg
  grub_map=$(artifacts)/nvidia-matrix/$stamp/grub-r15-$row-$stamp-$$.tsv
  mkdir -p "$(dirname "$grub_cfg")"
  guest 'sudo cat /boot/grub/grub.cfg' >"$grub_cfg" || {
    copy_nvidia_artifacts "$stamp" || true
    die "could not capture the prepared GRUB menu while R15 row $row is held"
  }
  printf 'schema\t1\nrow\t%s\n' "$row" >"$grub_map"

  for kernel in "${sound_kernels[@]}"; do
    pkgbase=${kernel_pkgbase[$kernel]}
    if ! entry_selector=$(r15_grub_selector "$grub_cfg" "$pkgbase"); then
      copy_nvidia_artifacts "$stamp" || true
      die "could not select a GRUB entry for $pkgbase while the R15 failure is held"
    fi
    printf 'kernel\t%s\npkgbase\t%s\ngrub-one-shot\t%s\n' \
      "$kernel" "$pkgbase" "$entry_selector" >>"$grub_map"
    guest "sudo grub-reboot '$entry_selector'" || {
      copy_nvidia_artifacts "$stamp" || true
      die "GRUB refused the one-shot entry for $kernel; the R15 state remains held"
    }
    cmd_reboot
    current_kernel=$(guest 'uname -r')
    if [[ $current_kernel != "$kernel" ]]; then
      copy_nvidia_artifacts "$stamp" || true
      die "R15 selected $kernel but the guest started $current_kernel; the failure state remains held"
    fi
    suffix=r15-$row-$kernel
    local check_status=0
    cmd_check "$suffix" || check_status=$?
    if ((check_status != 0)); then
      copy_nvidia_artifacts "$stamp" || true
      die "desktop check failed on $kernel with R15 row $row still held"
    fi
    if ! guest 'for path in /sys/bus/pci/devices/*; do
         [[ -r $path/vendor && -r $path/class ]] || continue
         vendor=$(<"$path/vendor"); class=$(<"$path/class")
         if [[ $vendor == 0x10de && $class == 0x03* ]]; then printf "%s %s\\n" "$path" "$class"; exit 1; fi
       done
       printf "no NVIDIA display device\\n"'; then
      copy_nvidia_artifacts "$stamp" || true
      die "the R15 guest unexpectedly exposed an NVIDIA display device"
    fi
    boot_id=$(guest 'cat /proc/sys/kernel/random/boot_id')
    evidence="$test_root/r15-boot-evidence-$row-$kernel.tsv"
    if guest "test -e $evidence"; then
      die "R15 boot evidence already exists for $row on $kernel; do not overwrite it"
    fi
    printf 'schema\t1\nrow\t%s\nstamp\t%s\nkernel\t%s\nboot-id\t%s\ndesktop\tpass\nnvidia-device\tno-device\n' \
      "$row" "$stamp" "$kernel" "$boot_id" |
      guest "umask 077; cat >$evidence" || die "could not persist R15 boot evidence for $kernel"
    hcheck "R15 $row boots $kernel to the desktop" 1 "boot-id $boot_id; nvidia-device no-device"
  done
  cmd_nvidia_matrix r15-release "$row"
}

cmd_nvidia_reference() {
  cmd_boot
  manifest
  cmd_nvidia_preflight
  GOOARCHY_VM_KERNEL=0 GOOARCHY_VM_RETRY_TEST=0 cmd_install
  cmd_reboot
  cmd_check nvidia-reference-baseline
  cmd_nvidia_matrix reference
  manifest
}

cmd_login_check() {
  running || die "the guest isn't running"
  local out; out=$(artifacts)
  timeout 900 python3 "$here/login-check.py" "$run/qmp.sock" "$out" -- ssh "${ssh_opts[@]}" arch@127.0.0.1 2>&1 |
    tee "$out/login-check.log" >&2
}

manifest() {
  # What this run was: enough to repeat it and to know what the results are about.
  local out; out=$(artifacts)
  local image; image=$(fetch_image)
  guest 'pacman -Q' >"$out/guest-packages.txt" 2>/dev/null || true
  guest 'cat /usr/share/gooarchy/build-info' >"$out/gooarchy-build-info.txt" 2>/dev/null || true
  python3 - "$out/manifest.json" <<EOF
import json, sys
json.dump({
  "harness_revision": "$(git -C "$repo" rev-parse HEAD)$(git -C "$repo" status --porcelain | grep -q . && echo ' (with uncommitted changes)')",
  "image": "$(basename "$image")", "image_url": "$image_url",
  "image_sha256": "$(cat "$image.sha256-local")",
  "qemu": "$("$qemu" --version | head -1)",
  "graphics": "$gpu", "screen": "$size", "memory_mib": "$memory", "cpus": "$cpus", "disk": "$disk",
  "proxy_used": $([[ -n $proxy ]] && echo True || echo False),
  "test_accommodations": ["cloud-init seed (SSH key, passwordless sudo)", "systemd-time-wait-sync masked",
                          "pacman cache shared from the host, no download timeout", "Wayfire stipc plugin loaded at check time"],
  "guest_packages": "guest-packages.txt",
}, open(sys.argv[1], "w"), indent=1)
EOF
}

summary() {
  local out; out=$(artifacts)
  python3 - "$out" <<'EOF'
import json, os, sys
out, total, failed = sys.argv[1], 0, []
for name in ("harness-checks.json", "results.json", "login-check.json",
             "install-observation-fresh-install/results.json",
             "install-observation-ordinary-rerun/results.json"):
    path = os.path.join(out, name)
    if not os.path.exists(path):
        failed.append(f"{name} missing")
        continue
    for r in json.load(open(path))["results"]:
        total += 1
        if not r["ok"]:
            failed.append(r["check"])
print(f"{total - len([f for f in failed if not f.endswith('missing')])}/{total} checks passed")
for f in failed:
    print(f"  FAILED: {f}")
sys.exit(1 if failed else 0)
EOF
}

cmd_stop() {
  stop_seed
  if running; then
    python3 "$here/qmp.py" "$run/qmp.sock" quit >/dev/null 2>&1 ||
      { running && kill "$(cat "$run/qemu.pid")" 2>/dev/null; } || true
    local deadline=$((SECONDS + 20))
    while running && (( SECONDS < deadline )); do sleep 1; done
    running && kill -9 "$(cat "$run/qemu.pid")" 2>/dev/null || true
    log "guest stopped"
  fi
  rm -f "$run/qemu.pid"
}

# A successful boot/start invocation deliberately leaves the guest running for later wrapper
# commands. Failed or interrupted invocations stop it; pool callers also own all descendants in
# this process group and can reap them when their job exits.
cleanup_failed_invocation() {
  local status=$?
  trap - EXIT
  if (( status != 0 )); then
    cmd_stop || true
  fi
  exit "$status"
}

cleanup_interrupted_invocation() {
  local status=$1
  trap - HUP INT TERM EXIT
  cmd_stop || true
  exit "$status"
}

trap 'cleanup_interrupted_invocation 129' HUP
trap 'cleanup_interrupted_invocation 130' INT
trap 'cleanup_interrupted_invocation 143' TERM

case ${1:-all} in
  boot|start) trap cleanup_failed_invocation EXIT ;;
esac

case ${1:-all} in
  boot) cmd_boot ;;
  start) cmd_start ;;
  install) cmd_install ;;
  manifest) manifest ;;
  rebuild-check) cmd_rebuild_check ;;
  reboot) cmd_reboot ;;
  check) cmd_check ;;
  kernel-check) cmd_kernel_check ;;
  kernel-boot-check) cmd_kernel_boot_check ;;
  login-check) cmd_login_check ;;
  upgrade-guard) cmd_upgrade_guard ;;
  no-toolchain) cmd_no_toolchain ;;
  nvidia-preflight) cmd_nvidia_preflight ;;
  nvidia-matrix) shift; cmd_nvidia_matrix "$@" ;;
  nvidia-install) cmd_nvidia_install ;;
  nvidia-r15-row) shift; cmd_nvidia_r15_row "$@" ;;
  nvidia-reference) trap cmd_stop EXIT; cmd_nvidia_reference ;;
  ssh) shift; guest -t "$@" ;;
  stop) cmd_stop ;;
  all)
    rm -f "$run/artifacts"
    trap cmd_stop EXIT
    cmd_boot
    manifest
    cmd_install
    cmd_reboot
    cmd_install_observation fresh-install || true
    cmd_install_rerun || true
    cmd_install_observation ordinary-rerun || true
    cmd_rebuild_check
    cmd_reboot
    cmd_check || true
    cmd_login_check || true
    cmd_upgrade_guard
    if [[ ${GOOARCHY_VM_KERNEL:-0} == 1 ]]; then
      kernel_headers_check
      kernel_bootloader_check
    fi
    cmd_no_toolchain
    manifest
    log "artifacts: $(artifacts)"
    summary
    ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
esac
