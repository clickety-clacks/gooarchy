#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/install/helpers/repository.sh"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/gooarchy-strata-bootstrap.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/cache"
pacman_calls=$test_root/pacman-calls

# Model the reviewed case: strata-bin is not installed and is the only
# dependency absent from the signed Gooarchy repository.
pacman() {
  local mode=${1:-} argument assumed= count=0
  printf '%s\0' "$@" >>"$pacman_calls"
  printf '\0' >>"$pacman_calls"
  for argument in "$@"; do
    if [[ $assumed == pending ]]; then
      assumed=$argument
      ((count += 1))
    elif [[ $argument == --assume-installed ]]; then
      assumed=pending
    fi
  done
  [[ $assumed != pending && $count == 1 && $assumed == strata-bin=0 ]] || {
    echo "pacman did not receive the single strata-bin bootstrap assumption" >&2
    return 1
  }
  case $mode in
    -Sp) printf '%s\n' gooarchy-1-1-any.pkg.tar.zst ;;
    -Sw) return 0 ;;
    *) echo "unexpected pacman operation: $mode" >&2; return 1 ;;
  esac
}

sudo() {
  [[ ${1:-} == pacman ]] || { echo "unexpected sudo command: $*" >&2; return 1; }
  shift
  pacman "$@"
}

filename=$(repository_gooarchy_bootstrap_filename)
[[ $filename == gooarchy-1-1-any.pkg.tar.zst ]] || {
  echo "unexpected bootstrap package filename: $filename" >&2
  exit 1
}
download_repository_gooarchy_bootstrap "$test_root/cache"

grep -Fq "'strata-bin'" "$repo_root/packaging/arch/PKGBUILD" || {
  echo "the Gooarchy package must retain strata-bin as a hard dependency" >&2
  exit 1
}

python3 - "$pacman_calls" "$test_root/cache" <<'PY'
from pathlib import Path
import sys

tokens = Path(sys.argv[1]).read_bytes().decode().split("\0")
calls, current = [], []
for token in tokens:
    if token:
        current.append(token)
    elif current:
        calls.append(current)
        current = []
expected = [
    [
        "-Sp", "--nodeps", "--assume-installed", "strata-bin=0",
        "--print-format", "%f", "gooarchy/gooarchy",
    ],
    [
        "-Sw", "--nodeps", "--assume-installed", "strata-bin=0",
        "--noconfirm", "--cachedir", sys.argv[2], "gooarchy/gooarchy",
    ],
]
if calls != expected:
    raise SystemExit(f"unexpected bootstrap pacman calls: {calls!r}")
print("strata-bin bootstrap assumption passed to both package-resolution and download calls")
PY

echo "Gooarchy retains the hard strata-bin dependency and resolves the signed bootstrap archive before the later AUR build."
