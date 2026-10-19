#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe=$repo_root/packaging/gooarchy-flavorings/PKGBUILD
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

selected_source() {
  bash -c 'source "$1"; printf "%s\n" "${source[0]}"' _ "$1"
}

expect_rejected() {
  local variant=$1
  if bash -c 'source "$1"' _ "$variant" >/dev/null 2>&1; then
    printf 'expected invalid Flavorings source selectors to fail: %s\n' "$variant" >&2
    return 1
  fi
}

! grep -q '^_commit=' "$recipe"
! grep -q '^_branch=' "$recipe"
recipe_tag=$(sed -n 's/^_tag=//p' "$recipe")
[[ $(sed -n 's/^pkgname=//p' "$recipe") == 'gooarchy-flavorings' ]]
[[ $recipe_tag == 'v0.2.0' ]]
[[ $(sed -n 's/^pkgver=//p' "$recipe") == "${recipe_tag#v}" ]]
[[ $(sed -n 's/^_upstream_commit=//p' "$recipe") == 'ecbaafc1c92eecf6b21143241e1618707f3e3f36' ]]
[[ $(sed -n 's/^_upstream_tree=//p' "$recipe") == '032d9108982071a8a3c7452d137995ffb3e6e707' ]]
[[ $(sed -n 's/^_upstream_archive_sha256=//p' "$recipe") == 'cc151da8b5cb1108b739b8946bf54da48036403dbea34ccc3f224f2d8246bc02' ]]
[[ $(selected_source "$recipe") == 'gooarchy-flavorings::git+https://github.com/clickety-clacks/gooarchy-flavorings.git#tag=v0.2.0' ]]
grep -Fq 'resolved_commit == "$_upstream_commit" && $resolved_tree == "$_upstream_tree"' "$recipe"

empty_tag_recipe=$tmp/empty-tag.PKGBUILD
sed 's/^_tag=.*/_tag=/' "$recipe" >"$empty_tag_recipe"
expect_rejected "$empty_tag_recipe"

tag_recipe=$tmp/tag.PKGBUILD
sed 's/^_tag=.*/_tag=v0.2.0/' "$recipe" >"$tag_recipe"
tag_source=$(selected_source "$tag_recipe")
[[ $tag_source == 'gooarchy-flavorings::git+https://github.com/clickety-clacks/gooarchy-flavorings.git#tag=v0.2.0' ]]

duplicate_tag_recipe=$tmp/duplicate-tag.PKGBUILD
cat "$tag_recipe" >"$duplicate_tag_recipe"
printf '_tag=v1.2.3\n' >>"$duplicate_tag_recipe"
expect_rejected "$duplicate_tag_recipe"

invalid_tag_recipe=$tmp/invalid-tag.PKGBUILD
sed 's/^_tag=.*/_tag=bad..tag/' "$recipe" >"$invalid_tag_recipe"
expect_rejected "$invalid_tag_recipe"

release_candidate_recipe=$tmp/release-candidate.PKGBUILD
sed 's/^_tag=.*/_tag=v0.1.0-rc1/' "$recipe" >"$release_candidate_recipe"
expect_rejected "$release_candidate_recipe"

commit_recipe=$tmp/commit.PKGBUILD
cat "$tag_recipe" >"$commit_recipe"
printf '_commit=4dc4e7a5270312dea8a708973fbc45bf3bf30929\n' >>"$commit_recipe"
expect_rejected "$commit_recipe"

branch_recipe=$tmp/branch.PKGBUILD
cat "$tag_recipe" >"$branch_recipe"
printf '_branch=main\n' >>"$branch_recipe"
expect_rejected "$branch_recipe"

printf 'Flavorings PKGBUILD source selector checks passed.\n'
