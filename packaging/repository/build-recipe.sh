#!/usr/bin/env bash
# Check declared build tools, then build without asking pacman to install package dependencies.
# Runtime depends remain in the package metadata; --syncdeps would try to install packages that
# may be produced by this same repository transfer.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for argument in "$@"; do
  if [[ $argument == --syncdeps || $argument =~ ^-[^-]*s ]]; then
    echo "build-recipe: dependency installation is disabled; pass build flags without --syncdeps/-s" >&2
    exit 2
  fi
done

srcinfo=$(makepkg --printsrcinfo) || {
  echo "build-recipe: makepkg could not read the recipe metadata" >&2
  exit 1
}
printf '%s\n' "$srcinfo" | python3 "$script_dir/check-build-dependencies.py" || exit $?

exec makepkg --nodeps "$@"
