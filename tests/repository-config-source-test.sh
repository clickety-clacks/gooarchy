#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sources_conf=$repo_root/install/sources.conf
public_key=$repo_root/packaging/keys/gooarchy.asc
fingerprint_file=$repo_root/packaging/keys/gooarchy.fingerprint
url_helper=$repo_root/install/helpers/repository-url.sh
repository_installer=$repo_root/install/packaging/repository.sh
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
if bash --noprofile --norc -c 'source "$1"; gooarchy_pacman_server "$2"' _ "$url_helper" https://mirror.example.invalid/repository; then
  echo 'a directory-only mirror URL must not be accepted as a database URL' >&2
  exit 1
fi

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
mkdir -m 700 "$test_root/gnupg"
actual_fingerprint=$(gpg --homedir "$test_root/gnupg" --batch --no-options \
  --show-keys --with-colons --with-fingerprint "$public_key" 2>/dev/null |
  awk -F: '$1 == "fpr" { print toupper($10); exit }')
[[ $actual_fingerprint == "$committed_fingerprint" ]] || {
  echo 'committed public key does not match its fingerprint' >&2
  exit 1
}

[[ $(grep -c '^_tag=' "$flavorings_recipe") == 1 ]] || {
  echo 'Flavorings recipe must retain exactly one _tag selector' >&2
  exit 1
}
grep -Fq 'repository_server=$(gooarchy_pacman_server "$repository_url")' "$repository_installer" || {
  echo 'repository installer does not derive the Pacman Server directory from the database URL' >&2
  exit 1
}
grep -Fq 'awk -v url="$repository_server"' "$repository_installer" || {
  echo 'persistent Pacman configuration does not use the derived Server directory' >&2
  exit 1
}
grep -Fq 'Server = $repository_server' "$repository_installer" || {
  echo 'refresh Pacman configuration does not use the derived Server directory' >&2
  exit 1
}

grep -Fxq '_tag=' "$flavorings_recipe" || {
  echo 'Flavorings _tag must remain empty until an authorized final tag is available' >&2
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
