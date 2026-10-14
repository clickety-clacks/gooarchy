#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sources_conf=$repo_root/install/sources.conf
public_key=$repo_root/packaging/keys/gooarchy.asc
fingerprint_file=$repo_root/packaging/keys/gooarchy.fingerprint
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

override_url=https://mirror.example.invalid/gooarchy.db
overridden_url=$(env -i PATH="$PATH" GOOARCHY_REPOSITORY_URL="$override_url" \
  bash --noprofile --norc -c '
    source "$1"
    printf "%s\n" "$GOOARCHY_REPOSITORY_URL"
  ' _ "$sources_conf")
[[ $overridden_url == "$override_url" ]] || {
  printf 'expected explicit repository override %s, got %s\n' "$override_url" "$overridden_url" >&2
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

echo 'Repository URL, verified public key/fingerprint, and fail-closed Flavorings pin assertions passed.'
