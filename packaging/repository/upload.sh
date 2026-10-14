#!/usr/bin/env bash
# Verify a signed transfer and publish its complete asset set as the latest release.
set -euo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || {
  echo "upload: run from the clean Gooarchy source checkout used for this transfer" >&2
  exit 1
}
die() { echo "upload: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'USAGE'
Usage: packaging/repository/upload.sh --uploader-role primary \
       --signed-bundle <signed-transfer-directory> \
       --manifest-sha256 <64-hex-digits>

Verifies the signed transfer, uploads a complete GitHub Release draft, reads
every asset back byte-for-byte, and makes it latest only as the final step.
Signing authority alone does not authorize this separate upload operation.
USAGE
  exit 2
}

signed_bundle=
expected_manifest_sha256=
uploader_role=
while (($#)); do
  case $1 in
    --signed-bundle)
      (($# >= 2)) || usage
      signed_bundle=$2
      shift 2
      ;;
    --manifest-sha256)
      (($# >= 2)) || usage
      expected_manifest_sha256=$2
      shift 2
      ;;
    --uploader-role)
      (($# >= 2)) || usage
      uploader_role=$2
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *) usage ;;
  esac
done
[[ $uploader_role == primary ]] || usage
[[ -n $signed_bundle && $expected_manifest_sha256 =~ ^[0-9a-f]{64}$ ]] || usage
[[ -d $signed_bundle && ! -L $signed_bundle ]] || die "signed transfer must be a regular directory."

checkout_branch=$(git -C "$repo_root" branch --show-current)
[[ $checkout_branch == main ]] || die "upload from Gooarchy main, not $checkout_branch."
[[ -z $(git -C "$repo_root" status --porcelain) ]] || die "the uploader source checkout has uncommitted changes."
checkout_commit=$(git -C "$repo_root" rev-parse HEAD)
checkout_tree=$(git -C "$repo_root" rev-parse 'HEAD^{tree}')

fingerprint_file="$repo_root/packaging/keys/gooarchy.fingerprint"
public_key_file="$repo_root/packaging/keys/gooarchy.asc"
[[ -s $fingerprint_file && -s $public_key_file ]] || die "the public repository key and fingerprint are not configured."
if grep -q '^Placeholder:' "$fingerprint_file" "$public_key_file"; then
  die "the public repository key is still a placeholder."
fi
public_fingerprint=$(awk '/^[[:space:]]*($|#)/ { next } { gsub(/[[:space:]]/, ""); print toupper($0); exit }' "$fingerprint_file")
[[ $public_fingerprint =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]] ||
  die "the configured public fingerprint is invalid."

release_repo=${GOOARCHY_RELEASE_REPOSITORY:-clickety-clacks/gooarchy}
[[ $release_repo == clickety-clacks/gooarchy ]] || die "release repository must be clickety-clacks/gooarchy."

work_parent=${GOOARCHY_UPLOADER_TMPDIR:-${TMPDIR:-/tmp}}
mkdir -p -- "$work_parent"
work_dir=$(mktemp -d "$work_parent/gooarchy-upload.XXXXXX") || die "could not create a private uploader workspace."
chmod 700 "$work_dir"
trap 'rm -rf -- "$work_dir"' EXIT
snapshot="$work_dir/signed-transfer"
mkdir -m 700 "$snapshot" "$snapshot/payload" "$snapshot/signatures"

shopt -s nullglob dotglob
root_paths=("$signed_bundle"/*)
shopt -u nullglob dotglob
((${#root_paths[@]} == 5)) || die "signed transfer root has missing or unexpected entries."
for path in "${root_paths[@]}"; do
  case ${path##*/} in
    manifest.json|SHA256SUMS|SIGNATURES.json) [[ -f $path && ! -L $path ]] || die "signed transfer has an invalid ${path##*/}." ;;
    payload|signatures) [[ -d $path && ! -L $path ]] || die "signed transfer has an invalid ${path##*/} directory." ;;
    *) die "signed transfer contains an unexpected entry: ${path##*/}." ;;
  esac
done
for filename in manifest.json SHA256SUMS SIGNATURES.json; do
  cp -- "$signed_bundle/$filename" "$snapshot/$filename"
done
for dir_name in payload signatures; do
  shopt -s nullglob dotglob
  paths=("$signed_bundle/$dir_name"/*)
  shopt -u nullglob dotglob
  for path in "${paths[@]}"; do
    [[ -f $path && ! -L $path ]] || die "signed transfer $dir_name contains a non-regular file."
    cp -- "$path" "$snapshot/$dir_name/$(basename -- "$path")"
  done
done

signed_summary=$(python3 "$script_dir/repository-protocol.py" verify-signed \
  --bundle "$snapshot" --expected-manifest-sha256 "$expected_manifest_sha256" \
  --expected-fingerprint "$public_fingerprint") || die "signed transfer verification failed."
source_commit=$(jq -r '.source_commit' <<<"$signed_summary")
source_tree=$(jq -r '.source_tree' <<<"$signed_summary")
signer_role=$(jq -r '.signer_role' <<<"$signed_summary")
[[ $source_commit == "$checkout_commit" && $source_tree == "$checkout_tree" ]] ||
  die "signed transfer source identity does not match this clean Gooarchy main checkout."

public_home="$work_dir/public-gnupg"
mkdir -m 700 "$public_home"
GNUPGHOME=$public_home gpg --batch --import "$public_key_file" >/dev/null 2>&1 ||
  die "could not load the public repository key."
actual_public_fingerprint=$(GNUPGHOME=$public_home gpg --batch --with-colons --show-keys \
  --with-fingerprint "$public_key_file" 2>/dev/null | awk -F: '$1 == "fpr" { print toupper($10); exit }')
[[ $actual_public_fingerprint == "$public_fingerprint" ]] || die "public key and configured fingerprint differ."

manifest_file="$snapshot/manifest.json"
base_tag=$(jq -r '.base.release_tag // ""' "$manifest_file")
read_latest_tag() {
  local release_list
  release_list=$(gh release list --repo "$release_repo" --limit 1000 --exclude-drafts \
    --exclude-pre-releases --json tagName,isLatest) || return 1
  jq -r '[.[] | select(.isLatest == true)][0].tagName // ""' <<<"$release_list"
}
current_latest=$(read_latest_tag) || die "could not read the current published release."
[[ $current_latest == "$base_tag" ]] ||
  die "the current latest release changed after package production; rebuild from the current base."

asset_dir="$work_dir/assets"
mkdir -m 700 "$asset_dir"
mapfile -t asset_names < <(jq -r '[.packages[].filename, "gooarchy.db"] | sort[]' "$manifest_file")
for filename in "${asset_names[@]}"; do
  payload_path="$snapshot/payload/$filename"
  signature_path="$snapshot/signatures/$filename.sig"
  GNUPGHOME=$public_home gpg --batch --verify "$signature_path" "$payload_path" >/dev/null 2>&1 ||
    die "detached signature verification failed for $filename."
  cp -- "$payload_path" "$asset_dir/$filename"
  cp -- "$signature_path" "$asset_dir/$filename.sig"
done
release_asset_names=()
for filename in "${asset_names[@]}"; do release_asset_names+=("$filename" "$filename.sig"); done

if [[ -n $base_tag ]]; then
  previous_dir="$work_dir/previous"
  mkdir -m 700 "$previous_dir"
  gh release download "$base_tag" --repo "$release_repo" --dir "$previous_dir" ||
    die "could not download the current latest release for base verification."
  [[ -s $previous_dir/gooarchy.db && -s $previous_dir/gooarchy.db.sig ]] ||
    die "the current release is missing its repository database or detached signature."
  GNUPGHOME=$public_home gpg --batch --verify "$previous_dir/gooarchy.db.sig" \
    "$previous_dir/gooarchy.db" >/dev/null 2>&1 || die "the current repository database signature is invalid."
  while IFS=$'\t' read -r old_name old_version old_filename; do
    [[ -n $old_name ]] || continue
    [[ -s $previous_dir/$old_filename && -s $previous_dir/$old_filename.sig ]] ||
      die "the current release is missing package data for $old_name."
    GNUPGHOME=$public_home gpg --batch --verify "$previous_dir/$old_filename.sig" \
      "$previous_dir/$old_filename" >/dev/null 2>&1 || die "the current package signature is invalid: $old_name."
  done < <(python3 "$script_dir/read-db.py" "$previous_dir/gooarchy.db")
  actual_base="$work_dir/actual-base.json"
  python3 "$script_dir/repository-protocol.py" base --release-tag "$base_tag" \
    --database "$previous_dir/gooarchy.db" --package-dir "$previous_dir" >"$actual_base" ||
    die "could not read the exact current base asset set."
  expected_base="$work_dir/expected-base.json"
  jq -cS '.base' "$manifest_file" >"$expected_base"
  actual_canonical=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True, separators=(",", ":")))' "$actual_base")
  expected_canonical=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True, separators=(",", ":")))' "$expected_base")
  [[ $actual_canonical == "$expected_canonical" ]] ||
    die "the current latest release asset hashes differ from the builder's exact base."
fi

assert_latest_unchanged() {
  local actual
  actual=$(read_latest_tag) || die "could not re-read the current latest release."
  [[ $actual == "$base_tag" ]] || die "the current latest release changed; leaving this draft unpublished."
}
assert_latest_unchanged
manifest_tag=${expected_manifest_sha256:0:12}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
nonce=${work_dir##*.}
release_tag="gooarchy-repo-${source_commit:0:12}-${timestamp}-${manifest_tag}-${nonce}"
notes=$(printf 'Complete repository snapshot built from Gooarchy %s (tree %s).\nBuild manifest SHA-256: %s. Signer role: %s.' \
  "$source_commit" "$source_tree" "$expected_manifest_sha256" "$signer_role")
asset_paths=()
for filename in "${release_asset_names[@]}"; do asset_paths+=("$asset_dir/$filename"); done
gh release create "$release_tag" "${asset_paths[@]}" --repo "$release_repo" \
  --target "$source_commit" --draft --latest=false \
  --title "Gooarchy package repository $release_tag" --notes "$notes" ||
  die "could not upload the complete unpublished release draft; the previous latest remains supported."

# The draft cannot become latest until every expected asset has been read back byte-for-byte.
verify_dir="$work_dir/upload-readback"
mkdir -m 700 "$verify_dir"
gh release download "$release_tag" --repo "$release_repo" --dir "$verify_dir" ||
  die "could not read back the complete release draft; the previous latest remains supported."
expected_names=$(printf '%s\n' "${release_asset_names[@]}" | sort)
shopt -s nullglob dotglob
verify_paths=("$verify_dir"/*)
shopt -u nullglob dotglob
for path in "${verify_paths[@]}"; do
  [[ -f $path && ! -L $path ]] || die "draft download contains a non-regular entry."
done
actual_names=$(printf '%s\n' "${verify_paths[@]##*/}" | sort)
[[ $actual_names == "$expected_names" ]] ||
  die "draft assets are incomplete or have changed names; the previous latest remains supported."
for filename in "${release_asset_names[@]}"; do
  cmp -s -- "$asset_dir/$filename" "$verify_dir/$filename" ||
    die "draft asset bytes differ for $filename; the previous latest remains supported."
done
assert_latest_unchanged

# This final GitHub operation is the only step that advances the public latest release.
if ! gh release edit "$release_tag" --repo "$release_repo" --draft=false --latest; then
  current_latest=$(read_latest_tag) || die "publish response was unclear and latest readback failed."
  [[ $current_latest == "$release_tag" ]] || die "GitHub did not make the verified release latest."
fi
current_latest=$(read_latest_tag) || die "could not read back the published latest release."
[[ $current_latest == "$release_tag" ]] || die "the verified release was published but is not latest."
printf 'Published complete repository release %s as latest from Gooarchy %s.\n' "$release_tag" "$source_commit"
printf 'Transfer manifest SHA-256: %s\n' "$expected_manifest_sha256"
