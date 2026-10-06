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
#   tests/vm/run.sh terminal-check  foot and Ghostty, side by side, in the running session
#                           (terminal-check.py): bells, titles, colors, folders, glyphs, clipboard,
#                           start time and memory
#   tests/vm/run.sh check   check the running session (guest-check.py); screenshots and logs
#   tests/vm/run.sh login-check     password logins typed at the consoles (login-check.py)
#   tests/vm/run.sh upgrade-guard   a newer Wayfire must not install over the Scottland built for this one
#   tests/vm/run.sh start   boot the existing disk again (after stop)
#   tests/vm/run.sh ssh [CMD]   a shell (or CMD) in the guest
#   tests/vm/run.sh stop    power the guest off
#
# Looking at the desktop: GOOARCHY_VM_GPU=software GOOARCHY_VM_VNC=1 tests/vm/run.sh start, then
# point a VNC viewer at 127.0.0.1:5900 on this machine (e.g. through ssh -L 5900:127.0.0.1:5900).
# The seed server and the guest's network stay as the test uses them.
#
# Configuration (environment):
#   GOOARCHY_VM_DIR         work directory (default ~/.cache/gooarchy-vm-test): image, disk, logs
#   GOOARCHY_VM_IMAGE_URL   Arch cloud image (default: the latest official one; to repeat a run,
#                           use the dated image named in its manifest.json)
#   GOOARCHY_VM_IMAGE_SHA256  expected checksum of that image (checked on every run when set)
#   GOOARCHY_VM_QEMU_BIN    directory holding qemu-system-x86_64 and qemu-img (default: the copy
#                           tests/vm/fetch-qemu.sh unpacked, else PATH)
#   GOOARCHY_VM_GPU         virgl (default: guest GL through the host GPU) or software (llvmpipe)
#   GOOARCHY_VM_RENDERNODE  host render node for virgl (default: the first /dev/dri/renderD*)
#   GOOARCHY_VM_SIZE        guest screen size (default 1920x1080)
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
# Host needs: x86_64 Linux with KVM (/dev/kvm), QEMU (or tests/vm/fetch-qemu.sh), with virgl a
# usable render node, plus python3, ssh/ssh-keygen, curl, git, tar.
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
  # passwordless sudo) gets this run's SSH key. Disable the network-time wait in bootcmd, before
  # its ordering can hold sshd on the first boot. QEMU supplies the RTC; this is test-only.
  [[ -f $run/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C gooarchy-vm-test -f "$run/id_ed25519"
  mkdir -p "$run/seed"
  # One instance id per disk: a new one makes cloud-init set the machine up again.
  [[ -f $run/seed/meta-data ]] ||
    printf 'instance-id: gooarchy-vm-%s\nlocal-hostname: gooarchy-vm\n' "$(date +%s)" >"$run/seed/meta-data"
  cat >"$run/seed/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "$run/id_ed25519.pub")
bootcmd:
  - [systemctl, mask, --now, systemd-time-wait-sync.service]
EOF
  local seed_port
  seed_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  setsid python3 -m http.server --bind 127.0.0.1 --directory "$run/seed" "$seed_port" \
    >"$run/seed-http.log" 2>&1 </dev/null &
  echo $! >"$run/seed-http.pid"
  echo "$seed_port"
}

ensure_seed() {
  # cloud-init asks for its seed at every boot; without it, it re-initializes the instance (new
  # host keys, no SSH key). Keep serving it on the port the guest was booted with.
  [[ -f $run/seed-http.pid ]] && kill -0 "$(cat "$run/seed-http.pid")" 2>/dev/null && return 0
  local seed_port
  seed_port=$(tr '\0' '\n' <"/proc/$(cat "$run/qemu.pid")/cmdline" | sed -n 's|.*10\.0\.2\.2:\([0-9]*\)/.*|\1|p')
  setsid python3 -m http.server --bind 127.0.0.1 --directory "$run/seed" "$seed_port" \
    >"$run/seed-http.log" 2>&1 </dev/null &
  echo $! >"$run/seed-http.pid"
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
  local image
  image=$(fetch_image)
  rm -rf "$run/disk.qcow2" "$run/artifacts" "$run/seed"
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
  local seed_port display
  seed_port=$(seed)
  local xres=${size%x*} yres=${size#*x}
  case $gpu in
    virgl)
      local node=${GOOARCHY_VM_RENDERNODE:-$(ls /dev/dri/renderD* 2>/dev/null | head -1)}
      [[ -n $node ]] || die "no render node for virgl; set GOOARCHY_VM_GPU=software"
      display=(-device "virtio-vga-gl,xres=$xres,yres=$yres" -display "egl-headless,rendernode=$node")
      [[ ${GOOARCHY_VM_VNC:-} == 1 ]] && die "GOOARCHY_VM_VNC needs GOOARCHY_VM_GPU=software"
      ;;
    software)
      display=(-device "virtio-vga,xres=$xres,yres=$yres" -display none)
      [[ ${GOOARCHY_VM_VNC:-} == 1 ]] && display+=(-vnc 127.0.0.1:0)
      ;;
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

copy_checkout() {
  log "copying the checkout (tracked and untracked files, and its history) into the guest"
  (cd "$repo" && { git ls-files -co --exclude-standard -z; printf '.git\0'; } | tar --null -T - -cf -) |
    guest 'rm -rf ~/gooarchy && mkdir ~/gooarchy && tar -C ~/gooarchy -xf -'
}

cmd_install() {
  running || die "the guest isn't running (tests/vm/run.sh boot)"
  local out; out=$(artifacts)
  copy_checkout
  local status=0
  if [[ ${GOOARCHY_VM_RETRY_TEST:-1} == 1 ]]; then
    # A failed attempt (made to fail at the Strata step), then a retry that must complete.
    log "running ./install.sh, made to fail at packaging/strata.sh (log: $out/install-failed-attempt.log)"
    guest "cd ~/gooarchy && GOOARCHY_TEST_FAIL_AT=packaging/strata.sh $(guest_proxy_env) ./install.sh --yes --autologin" \
      >"$out/install-failed-attempt.log" 2>&1 || status=$?
    local last; last=$(guest 'cat ~/.local/state/gooarchy/last-step 2>/dev/null')
    local ok=0
    [[ $status != 0 && $last == packaging/scottland.sh ]] &&
      grep -q 'last completed: packaging/scottland.sh' "$out/install-failed-attempt.log" && ok=1
    hcheck "an install that fails at a step stops there and says what completed" "$ok" \
      "exit $status, last completed step: $last"
    status=0
  fi
  log "running ./install.sh --yes --autologin (log: $out/install.log)"
  guest "cd ~/gooarchy && $(guest_proxy_env) ./install.sh --yes --autologin" >"$out/install.log" 2>&1 || status=$?
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
  log "install finished"
}

plugin_state() {
  guest 'printf "%s %s\n" "$(pacman -Q scottland | cut -d" " -f2)" \
           "$(sha256sum "$(pacman -Qlq scottland | grep "/libscottland.so$")" | cut -c1-16)"'
}

cmd_rebuild_check() {
  # Scottland's PKGBUILD has a fixed version; a rebuild at another commit (or for another Wayfire)
  # must still replace the installed plugin, and the package version must say what was built.
  running || die "the guest isn't running"
  local out; out=$(artifacts)
  local pinned; pinned=$(sed -n 's/.*GOOARCHY_SCOTTLAND_REF:-\([0-9a-f]*\)}.*/\1/p' "$repo/install/sources.conf")
  local other=${GOOARCHY_VM_REBUILD_REF:-f3ba4c56d9d84e906e9023cce9f2fa786c6bce45}
  local a b c d status=0
  a=$(plugin_state)
  guest "cd ~/gooarchy && GOOARCHY_SCOTTLAND_REF=$other $(guest_proxy_env) ./install.sh --yes" >"$out/rebuild-b.log" 2>&1 || status=$?
  b=$(plugin_state)
  local ok=0
  [[ $status == 0 && ${a#* } != "${b#* }" && $b == *g${other:0:7}* ]] && ok=1
  hcheck "rebuilding Scottland at another commit (same upstream version) replaces the installed plugin" "$ok" \
    "A: $a; B: $b"
  status=0
  guest "cd ~/gooarchy && $(guest_proxy_env) ./install.sh --yes" >"$out/rebuild-a.log" 2>&1 || status=$?
  c=$(plugin_state)
  ok=0
  [[ $status == 0 && $c == *g${pinned:0:7}* && ${c#* } != "${b#* }" ]] && ok=1
  hcheck "going back to the pinned commit replaces the plugin again" "$ok" "now: $c"
  status=0
  guest "cd ~/gooarchy && $(guest_proxy_env) ./install.sh --yes" >"$out/rebuild-same.log" 2>&1 || status=$?
  d=$(plugin_state)
  local reinstalled; reinstalled=$(guest 'grep -c "reinstalled scottland" /var/log/pacman.log')
  ok=0
  [[ $status == 0 && $reinstalled -gt 0 && $d == *g${pinned:0:7}* ]] && ok=1
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
cmd_reboot() {
  running || die "the guest isn't running"
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
  local out; out=$(artifacts)
  screendump vm-display-before-check.png
  guest 'rm -rf /tmp/gooarchy-check && mkdir -p /tmp/gooarchy-check'
  guest 'cat >/tmp/gooarchy-check/guest-check.py' <"$here/guest-check.py"
  log "checking the session in the guest"
  local status=0
  guest "timeout 1500 python3 /tmp/gooarchy-check/guest-check.py /tmp/gooarchy-check/out --gpu $gpu" 2>&1 |
    tee "$out/guest-check.log" >&2 || status=$?
  screendump vm-display-after-check.png
  guest 'cd /tmp/gooarchy-check/out && tar -cf - .' | tar -C "$out" -xf - || true
  guest 'journalctl -b --no-pager -o short-monotonic' >"$out/journal.log" 2>/dev/null || true
  guest 'cat ~/.local/state/scottland/wayfire.log' >"$out/wayfire-last-session.log" 2>/dev/null || true
  guest 'cat ~/.local/state/scottland/wayfire.log.previous' >"$out/wayfire-previous-session.log" 2>/dev/null || true
  cp "$run/serial.log" "$out/serial.log" 2>/dev/null || true
  log "artifacts: $out"
  return "$status"
}

cmd_terminal_check() {
  running || die "the guest isn't running"
  local out; out=$(artifacts)
  # Test-only additions: wl-clipboard as the clipboard oracle, Ghostty as the baseline when
  # Gooarchy doesn't ship it, and an SSH key so the guest can SSH to itself (bells over SSH).
  guest "sudo $(guest_proxy_env) pacman -S --needed --noconfirm wl-clipboard ghostty foot >/dev/null"
  guest 'test -f ~/.ssh/id_localtest || { ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_localtest &&
         cat ~/.ssh/id_localtest.pub >>~/.ssh/authorized_keys &&
         printf "Host localhost\n  IdentityFile ~/.ssh/id_localtest\n  StrictHostKeyChecking accept-new\n" >>~/.ssh/config &&
         chmod 600 ~/.ssh/config; }'
  guest 'rm -rf /tmp/gooarchy-terminal && mkdir -p /tmp/gooarchy-terminal'
  guest 'cat >/tmp/gooarchy-terminal/guest-check.py' <"$here/guest-check.py"
  guest 'cat >/tmp/gooarchy-terminal/terminal-check.py' <"$here/terminal-check.py"
  local terminal status=0
  for terminal in foot ghostty; do
    log "checking $terminal"
    guest "timeout 1300 python3 /tmp/gooarchy-terminal/terminal-check.py /tmp/gooarchy-terminal/out --terminal $terminal" \
      2>&1 | tee -a "$out/terminal-check.log" >&2 || status=1
  done
  guest 'cd /tmp/gooarchy-terminal/out && tar -cf - .' | tar -C "$out" -xf - || true
  python3 - "$out" <<'EOF' | tee "$out/terminal-comparison.txt" >&2
import json, os, sys
out = sys.argv[1]
data = {t: json.load(open(os.path.join(out, f"terminal-{t}.json"))) for t in ("foot", "ghostty")
        if os.path.exists(os.path.join(out, f"terminal-{t}.json"))}
names = []
for d in data.values():
    for r in d["results"]:
        if r["check"] not in names:
            names.append(r["check"])
print(f"{'check':90} " + " ".join(f"{t:8}" for t in data))
for n in names:
    row = []
    for t, d in data.items():
        r = next((r for r in d["results"] if r["check"] == n), None)
        row.append("-" if r is None else ("pass" if r["ok"] else "FAIL"))
    print(f"{n[:90]:90} " + " ".join(f"{c:8}" for c in row))
for t, d in data.items():
    print(f"{t}: start {d['metrics'].get('start_seconds')} s, memory {d['metrics'].get('pss_mib')} MiB")
EOF
  return "$status"
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
                          "terminal check: wl-clipboard (clipboard oracle), Ghostty (baseline) and a loopback SSH key added",
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
for name in ("harness-checks.json", "results.json", "login-check.json", "terminal-foot.json", "terminal-ghostty.json"):
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
  start) cmd_start ;;
  install) cmd_install ;;
  rebuild-check) cmd_rebuild_check ;;
  reboot) cmd_reboot ;;
  check) cmd_check ;;
  terminal-check) cmd_terminal_check ;;
  login-check) cmd_login_check ;;
  upgrade-guard) cmd_upgrade_guard ;;
  ssh) shift; guest -t "$@" ;;
  stop) cmd_stop ;;
  all)
    rm -f "$run/artifacts"
    trap cmd_stop EXIT
    cmd_boot
    manifest
    cmd_install
    cmd_rebuild_check
    cmd_reboot
    cmd_terminal_check || true
    cmd_check || true
    cmd_login_check || true
    cmd_upgrade_guard
    manifest
    log "artifacts: $(artifacts)"
    summary
    ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
esac
