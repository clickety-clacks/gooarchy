#!/bin/bash
set -euo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
qemu_pid=
seed_pid=

cleanup() {
  [[ -z $qemu_pid ]] || kill "$qemu_pid" 2>/dev/null || true
  [[ -z $seed_pid ]] || kill "$seed_pid" 2>/dev/null || true
  [[ -z $qemu_pid ]] || wait "$qemu_pid" 2>/dev/null || true
  [[ -z $seed_pid ]] || wait "$seed_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/run"
sleep 30 &
qemu_pid=$!
sleep 30 &
seed_pid=$!
printf '%s\n' "$qemu_pid" >"$tmp/run/qemu.pid"
printf '%s\n' "$qemu_pid" >"$tmp/run/qemu.launch.pid"
printf '%s\n' "$seed_pid" >"$tmp/run/seed-http.pid"

if GOOARCHY_VM_DIR=$tmp "$here/run.sh" stop >/dev/null 2>&1; then
  echo "FAIL: stop accepted an unrelated process as the owned QEMU" >&2
  exit 1
fi
kill -0 "$qemu_pid" 2>/dev/null
kill -0 "$seed_pid" 2>/dev/null
[[ -e $tmp/run/qemu.pid && -e $tmp/run/qemu.launch.pid && ! -e $tmp/run/seed-http.pid ]]
[[ $(stat -c '%a' "$tmp") == 700 && $(stat -c '%a' "$tmp/run") == 700 ]]
printf 'unverified QEMU PID was not signalled or erased; run root is private\n'
