#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sources_conf=$repo_root/install/sources.conf
public_key=$repo_root/packaging/keys/gooarchy.asc
fingerprint_file=$repo_root/packaging/keys/gooarchy.fingerprint
url_helper=$repo_root/install/helpers/repository-url.sh
flavorings_recipe=$repo_root/packaging/gooarchy-flavorings/PKGBUILD
expected_url=https://gooarchy.com/gooarchy.db
expected_fingerprint=F56B5368815D6C607C41265A69FCC98C28CD08EC

resolved_url=$(env -i PATH="$PATH" bash --noprofile --norc -c '
  source "$1"
  printf "%s\n" "$GOOARCHY_REPOSITORY_URL"
' _ "$sources_conf")
[[ $resolved_url == "$expected_url" ]] || {
  printf 'expected default repository URL %s, got %s\n' "$expected_url" "$resolved_url" >&2
  exit 1
}

server_url=$(bash --noprofile --norc -c 'source "$1"; gooarchy_pacman_server "$2"' _ "$url_helper" "$resolved_url")
[[ $server_url == https://gooarchy.com ]] || {
  printf 'expected Pacman Server directory https://gooarchy.com, got %s\n' "$server_url" >&2
  exit 1
}
pacman_database_url=${server_url%/}/gooarchy.db
[[ $pacman_database_url == "$expected_url" ]] || {
  printf 'Pacman would request %s instead of the configured database URL %s\n' "$pacman_database_url" "$expected_url" >&2
  exit 1
}
pacman_package_url=${server_url%/}/gooarchy-1.0-1-x86_64.pkg.tar.zst
[[ $pacman_package_url == https://gooarchy.com/gooarchy-1.0-1-x86_64.pkg.tar.zst ]] || {
  printf 'Pacman package URL was not resolved beside its database: %s\n' "$pacman_package_url" >&2
  exit 1
}

override_url=https://mirror.example.invalid/repository/gooarchy.db
overridden_url=$(env -i PATH="$PATH" GOOARCHY_REPOSITORY_URL="$override_url" \
  bash --noprofile --norc -c '
    source "$1"
    printf "%s\n" "$GOOARCHY_REPOSITORY_URL"
  ' _ "$sources_conf")
[[ $overridden_url == "$override_url" ]] || {
  printf 'expected explicit repository override %s, got %s\n' "$override_url" "$overridden_url" >&2
  exit 1
}
override_server=$(bash --noprofile --norc -c 'source "$1"; gooarchy_pacman_server "$2"' _ "$url_helper" "$overridden_url")
[[ $override_server == https://mirror.example.invalid/repository ]] || {
  printf 'mirror Pacman Server directory was not derived from the database URL: %s\n' "$override_server" >&2
  exit 1
}
directory_override=https://mirror.example.invalid/repository
directory_server=$(bash --noprofile --norc -c 'source "$1"; gooarchy_pacman_server "$2"' _ "$url_helper" "$directory_override")
[[ $directory_server == "$directory_override" ]] || {
  printf 'directory-style mirror override changed from %s to %s\n' "$directory_override" "$directory_server" >&2
  exit 1
}
directory_database_url=$(bash --noprofile --norc -c 'source "$1"; gooarchy_repository_database_url "$2"' _ "$url_helper" "$directory_override")
[[ $directory_database_url == https://mirror.example.invalid/repository/gooarchy.db ]] || {
  printf 'directory-style mirror did not resolve to its repository database: %s\n' "$directory_database_url" >&2
  exit 1
}
database_url=$(bash --noprofile --norc -c 'source "$1"; gooarchy_repository_database_url "$2"' _ "$url_helper" "$resolved_url")
[[ $database_url == "$expected_url" ]] || {
  printf 'full database URL changed during resolution: %s\n' "$database_url" >&2
  exit 1
}

[[ -s $public_key ]] || { echo 'committed public key is missing' >&2; exit 1; }
if grep -q '^Placeholder:' "$public_key" "$fingerprint_file"; then
  echo 'repository key configuration still contains a placeholder' >&2
  exit 1
fi
committed_fingerprint=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$fingerprint_file" | sed -n '/./{p;q;}')
[[ $committed_fingerprint == "$expected_fingerprint" ]] || {
  echo 'committed fingerprint differs from the verified Gooarchy repository key' >&2
  exit 1
}

test_root=$(mktemp -d "${TMPDIR:-/tmp}/gooarchy-repository-config.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
no_git_path=$test_root/no-git-path
mkdir -m 700 "$no_git_path"
bash_path=$(command -v bash)

# Fresh installs source helpers/all.sh before the base package step installs Git. Exercise the
# actual default and explicit branch selection with an empty PATH, where no Git command can run.
fresh_install_pin=$(env -i PATH="$no_git_path" GOOARCHY_INSTALL="$repo_root/install" \
  "$bash_path" --noprofile --norc -c '
    set -e
    source "$GOOARCHY_INSTALL/helpers/all.sh"
    printf "%s|%s\n" "$GOOARCHY_SCOTTLAND_REF" "$GOOARCHY_SCOTTLAND_SOURCE_KIND"
  ')
[[ $fresh_install_pin == 'v0.3.0|tag' ]] || {
  printf 'fresh-install source selection returned %s instead of the default final tag\n' "$fresh_install_pin" >&2
  exit 1
}

fresh_install_branch=$(env -i PATH="$no_git_path" GOOARCHY_INSTALL="$repo_root/install" \
  GOOARCHY_SCOTTLAND_REF=release/0.4 GOOARCHY_SCOTTLAND_REF_KIND=branch \
  "$bash_path" --noprofile --norc -c '
    set -e
    source "$GOOARCHY_INSTALL/helpers/all.sh"
    printf "%s|%s\n" "$GOOARCHY_SCOTTLAND_REF" "$GOOARCHY_SCOTTLAND_SOURCE_KIND"
  ')
[[ $fresh_install_branch == 'release/0.4|branch' ]] || {
  printf 'fresh-install branch selection returned %s instead of the explicit branch\n' "$fresh_install_branch" >&2
  exit 1
}

if env -i PATH="$no_git_path" GOOARCHY_INSTALL="$repo_root/install" \
  GOOARCHY_SCOTTLAND_REF=release//0.4 GOOARCHY_SCOTTLAND_REF_KIND=branch \
  "$bash_path" --noprofile --norc -c '
    set -e
    source "$GOOARCHY_INSTALL/helpers/all.sh"
  ' >"$test_root/invalid-branch.out" 2>"$test_root/invalid-branch.err"; then
  echo 'fresh-install source selection accepted a branch with an empty path component' >&2
  exit 1
fi
grep -Fq 'GOOARCHY_SCOTTLAND_REF is not a valid Git branch.' "$test_root/invalid-branch.err" || {
  echo 'invalid branch failure did not explain the rejected ref' >&2
  exit 1
}

mkdir -m 700 "$test_root/gnupg"
actual_fingerprint=$(gpg --homedir "$test_root/gnupg" --batch --no-options \
  --show-keys --with-colons --with-fingerprint "$public_key" 2>/dev/null |
  awk -F: '$1 == "fpr" { print toupper($10); exit }')
[[ $actual_fingerprint == "$committed_fingerprint" ]] || {
  echo 'committed public key does not match its fingerprint' >&2
  exit 1
}

if bash -c 'source "$1"' _ "$flavorings_recipe" >"$test_root/flavorings.out" 2>"$test_root/flavorings.err"; then
  echo 'Flavorings recipe must fail closed with an empty _tag' >&2
  exit 1
fi
grep -Fq 'Set exactly one final version _tag' "$test_root/flavorings.err" || {
  echo 'Flavorings empty-tag failure did not explain the missing final tag' >&2
  exit 1
}

echo 'Repository URL consumer, verified public key/fingerprint, and fail-closed Flavorings pin assertions passed.'
