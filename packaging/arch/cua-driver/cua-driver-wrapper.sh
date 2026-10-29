#!/usr/bin/env bash
set -euo pipefail

wrapper_path=$(readlink -f -- "${BASH_SOURCE[0]}")
upstream="$(dirname -- "$wrapper_path")/cua-driver-upstream"

is_managed_operation() {
  local previous= argument
  for argument in "$@"; do
    if [[ $previous == channel && $argument == set ]]; then
      return 0
    fi
    if [[ $previous == update && $argument == --apply ]]; then
      return 0
    fi
    previous=$argument
  done
  return 1
}

if is_managed_operation "$@"; then
  if ! pacman -Qoq -- "$upstream" >/dev/null 2>&1; then
    echo 'Unable to confirm pacman ownership of cua-driver; refusing the upstream update or release-channel change.' >&2
    exit 1
  fi

  printf '%s\n' \
    'This executable is managed by pacman. Update with `sudo pacman -Syu`; release selection and availability are controlled by your package repository. The upstream installer and stable/nightly channel switching are disabled.' >&2
  exit 1
fi

exec "$upstream" "$@"
