#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
root=$tmp/usr/lib/cua-driver
mkdir -p "$root" "$tmp/bin"
install -m755 "$repo_root/packaging/arch/cua-driver/cua-driver-wrapper.sh" "$root/cua-driver"
cat >"$root/cua-driver-upstream" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CUA_TEST_UPSTREAM_LOG"
EOF
chmod +x "$root/cua-driver-upstream"
cat >"$tmp/bin/pacman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CUA_TEST_PACMAN_LOG"
[[ $# == 3 && $1 == -Qoq && $2 == -- && $3 == "$CUA_TEST_EXPECTED_BINARY" ]] || exit 90
[[ $CUA_TEST_PACMAN_OWNER == yes ]] || exit 1
printf 'cua-driver\n'
EOF
chmod +x "$tmp/bin/pacman"
export PATH="$tmp/bin:$PATH"
export CUA_TEST_UPSTREAM_LOG=$tmp/upstream.log
export CUA_TEST_PACMAN_LOG=$tmp/pacman.log
export CUA_TEST_EXPECTED_BINARY=$root/cua-driver-upstream
export CUA_TEST_PACMAN_OWNER=yes
touch "$CUA_TEST_UPSTREAM_LOG" "$CUA_TEST_PACMAN_LOG"

expected='This executable is managed by pacman. Update with `sudo pacman -Syu`; release selection and availability are controlled by your package repository. The upstream installer and stable/nightly channel switching are disabled.'
for operation in channel update; do
  : >"$CUA_TEST_UPSTREAM_LOG"
  : >"$CUA_TEST_PACMAN_LOG"
  if [[ $operation == channel ]]; then
    set -- channel set nightly
  else
    set -- update --apply
  fi
  if "$root/cua-driver" "$@" >"$tmp/$operation.out" 2>&1; then
    echo "pacman-managed cua-driver accepted mutation: $*" >&2
    exit 1
  fi
  grep -Fxq -- "$expected" "$tmp/$operation.out"
  grep -Fxq -- "-Qoq -- $CUA_TEST_EXPECTED_BINARY" "$CUA_TEST_PACMAN_LOG"
  [[ ! -s $CUA_TEST_UPSTREAM_LOG ]]
done

: >"$CUA_TEST_UPSTREAM_LOG"
: >"$CUA_TEST_PACMAN_LOG"
"$root/cua-driver" status
grep -Fxq status "$CUA_TEST_UPSTREAM_LOG"
[[ ! -s $CUA_TEST_PACMAN_LOG ]]

: >"$CUA_TEST_UPSTREAM_LOG"
export CUA_TEST_PACMAN_OWNER=no
if "$root/cua-driver" update --apply >"$tmp/unconfirmed.out" 2>&1; then
  echo 'cua-driver accepted update --apply when ownership was unconfirmed' >&2
  exit 1
fi
grep -Fq 'Unable to confirm pacman ownership of cua-driver' "$tmp/unconfirmed.out"
[[ ! -s $CUA_TEST_UPSTREAM_LOG ]]

echo 'cua-driver pacman ownership test passed: packaged mutations are blocked; read-only commands pass through.'
