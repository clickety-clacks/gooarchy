#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gooarchy-install-git-preflight.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fixture=$tmp/checkout
tools=$tmp/bin
state=$tmp/state
cache=$tmp/cache
mkdir -p "$fixture/install/helpers" "$tools"
cp "$repo_root/install.sh" "$fixture/install.sh"
cat >"$fixture/install/helpers/all.sh" <<'SH'
start_install_log() {
  : >"$GOOARCHY_TEST_LOG_START"
  exit 77
}
SH

ln -s "$(command -v dirname)" "$tools/dirname"
bash_path=$(command -v bash)

set +e
env -i PATH="$tools" XDG_STATE_HOME="$state" XDG_CACHE_HOME="$cache" \
  GOOARCHY_TEST_LOG_START="$tmp/no-git-log-started" \
  "$bash_path" --noprofile --norc "$fixture/install.sh" --yes \
  >"$tmp/no-git.out" 2>&1
status=$?
set -e
[[ $status == 1 ]] || {
  echo "install.sh returned $status when Git was absent; expected 1" >&2
  cat "$tmp/no-git.out" >&2
  exit 1
}
grep -Fq "Update Arch and install it with 'sudo pacman -Syu --needed git', then rerun ./install.sh." "$tmp/no-git.out" || {
  echo "missing-Git failure did not provide an actionable instruction" >&2
  cat "$tmp/no-git.out" >&2
  exit 1
}
grep -Fq 'sudo pacman -Syu --needed git' "$repo_root/README.md" || {
  echo "README missing-Git instructions must fully upgrade Arch before installing Git" >&2
  exit 1
}
[[ ! -e $tmp/no-git-log-started ]] || {
  echo "install logging started before the missing-Git failure" >&2
  exit 1
}
[[ ! -e $state && ! -e $cache ]] || {
  echo "missing-Git failure changed installer state or cache" >&2
  exit 1
}

cat >"$tools/git" <<'SH'
#!/bin/sh
: >"$GOOARCHY_TEST_GIT_INVOKED"
SH
chmod +x "$tools/git"
set +e
env -i PATH="$tools" XDG_STATE_HOME="$state" XDG_CACHE_HOME="$cache" \
  GOOARCHY_TEST_LOG_START="$tmp/git-log-started" \
  GOOARCHY_TEST_GIT_INVOKED="$tmp/git-invoked" \
  "$bash_path" --noprofile --norc "$fixture/install.sh" --yes \
  >"$tmp/git-present.out" 2>&1
status=$?
set -e
[[ $status == 77 && -e $tmp/git-log-started ]] || {
  echo "install.sh did not continue past the Git check when Git was available" >&2
  cat "$tmp/git-present.out" >&2
  exit 1
}
[[ ! -e $tmp/git-invoked ]] || {
  echo "the early Git availability check executed Git" >&2
  exit 1
}

echo "Gooarchy Git preflight checks passed."
