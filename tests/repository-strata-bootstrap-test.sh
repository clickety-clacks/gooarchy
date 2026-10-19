#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/install/helpers/repository.sh"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/gooarchy-strata-bootstrap.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/cache"
pacman_calls=$test_root/pacman-calls

# Model the bootstrap case: xorg-xwayland is declared but not installed, so
# its archive appears before Gooarchy in pacman's package-name/filename output.
pacman() {
  local mode=${1:-} argument assumed= count=0 cachedir= target= filename
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
  if ((count)); then
    [[ $assumed != pending && $count == 1 && $assumed == strata-bin=0 ]] || {
      echo "pacman did not receive the single strata-bin bootstrap assumption" >&2
      return 1
    }
  elif [[ $assumed == pending ]]; then
    echo "pacman received an incomplete bootstrap assumption" >&2
    return 1
  fi
  case $mode in
    -Sp)
      if [[ $assumed == strata-bin=0 ]]; then
        printf '%s %s\n' xorg-xwayland xorg-xwayland-24.1.6-1-x86_64.pkg.tar.zst
        printf '%s %s\n' gooarchy gooarchy-1-1-any.pkg.tar.zst
      else
        printf '%s %s\n' python python-3.13-1-x86_64.pkg.tar.zst
        printf '%s %s\n' gooarchy-flavorings gooarchy-flavorings-1-1-any.pkg.tar.zst
        printf '%s %s\n' libinih libinih-59-1-x86_64.pkg.tar.zst
        printf '%s %s\n' xdg-desktop-portal-wlr-gooarchy xdg-desktop-portal-wlr-gooarchy-1-1-any.pkg.tar.zst
        printf '%s %s\n' jq jq-1-1-x86_64.pkg.tar.zst
        printf '%s %s\n' gooarchy gooarchy-1-1-any.pkg.tar.zst
      fi
      ;;
    -Sw)
      if [[ $assumed == strata-bin=0 ]]; then return 0; fi
      for argument in "$@"; do
        if [[ $target == --cachedir ]]; then
          cachedir=$argument
          target=
        elif [[ $argument == --cachedir ]]; then
          target=--cachedir
        fi
      done
      [[ -n $cachedir ]] || { echo "pacman did not receive a cache directory" >&2; return 1; }
      for argument in "$@"; do
        case $argument in
          gooarchy/xdg-desktop-portal-wlr-gooarchy=*) filename=xdg-desktop-portal-wlr-gooarchy-1-1-any.pkg.tar.zst ;;
          gooarchy/gooarchy=*) filename=gooarchy-1-1-any.pkg.tar.zst ;;
          gooarchy/gooarchy-flavorings=*) filename=gooarchy-flavorings-1-1-any.pkg.tar.zst ;;
          *) continue ;;
        esac
        printf 'archive\n' >"$cachedir/$filename"
      done
      ;;
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

download_repository_packages "$test_root/cache" \
  gooarchy/xdg-desktop-portal-wlr-gooarchy=1-1 \
  gooarchy/gooarchy=1-1 \
  gooarchy/gooarchy-flavorings=1-1
[[ ${#REPOSITORY_PACKAGE_ARCHIVES[@]} == 3 ]] || {
  echo "unexpected number of selected repository packages: ${#REPOSITORY_PACKAGE_ARCHIVES[@]}" >&2
  exit 1
}
[[ ${REPOSITORY_PACKAGE_ARCHIVES[0]} == "$test_root/cache/xdg-desktop-portal-wlr-gooarchy-1-1-any.pkg.tar.zst" &&
  ${REPOSITORY_PACKAGE_ARCHIVES[1]} == "$test_root/cache/gooarchy-1-1-any.pkg.tar.zst" &&
  ${REPOSITORY_PACKAGE_ARCHIVES[2]} == "$test_root/cache/gooarchy-flavorings-1-1-any.pkg.tar.zst" ]] || {
  echo "dependency archives were not excluded or requested package order was not preserved" >&2
  exit 1
}

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
        "--print-format", "%n %f", "gooarchy/gooarchy",
    ],
    [
        "-Sw", "--nodeps", "--assume-installed", "strata-bin=0",
        "--noconfirm", "--cachedir", sys.argv[2], "gooarchy/gooarchy",
    ],
    [
        "-Sp", "--nodeps", "--print-format", "%n %f",
        "gooarchy/xdg-desktop-portal-wlr-gooarchy=1-1", "gooarchy/gooarchy=1-1",
        "gooarchy/gooarchy-flavorings=1-1",
    ],
    [
        "-Sw", "--nodeps", "--noconfirm", "--cachedir", sys.argv[2],
        "gooarchy/xdg-desktop-portal-wlr-gooarchy=1-1", "gooarchy/gooarchy=1-1",
        "gooarchy/gooarchy-flavorings=1-1",
    ],
]
if calls != expected:
    raise SystemExit(f"unexpected bootstrap pacman calls: {calls!r}")
print("strata-bin bootstrap assumption passed to both package-resolution and download calls")
PY

echo "Gooarchy bootstrap selected its own archive after xorg-xwayland appeared first."
echo "Gooarchy retains the strata-bin hard dependency; both bootstrap pacman calls assume only strata-bin=0."
echo "Repository package downloads selected the requested archives and ignored dependency archives."
