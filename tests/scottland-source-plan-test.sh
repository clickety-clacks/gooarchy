#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/install/helpers/repository.sh"

expect_local_build() {
  local expected=$1 explicit_override=$2 source_kind=$3 actual=0
  if scottland_local_build_required "$explicit_override" "$source_kind"; then
    actual=1
  fi
  [[ $actual == "$expected" ]] || {
    printf 'source plan mismatch: explicit=%s kind=%s expected=%s got=%s\n' \
      "$explicit_override" "$source_kind" "$expected" "$actual" >&2
    return 1
  }
}

expect_local_build 1 0 branch
expect_local_build 0 0 tag
expect_local_build 0 0 commit
expect_local_build 1 1 tag
expect_local_build 1 1 branch
printf 'Scottland source plan checks passed.\n'
