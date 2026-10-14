#!/usr/bin/env bash
# Verify a builder transfer, sign its complete package set, and publish one complete latest release.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || {
  echo "sign-publish: run from the clean Gooarchy source checkout used for this transfer" >&2
  exit 1
}
die() { echo "sign-publish: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'USAGE'
Usage: packaging/repository/sign-publish.sh --bundle <transfer-directory> --manifest-sha256 <64-hex-digits>

Verifies the immutable builder bundle, signs package and database files, then
publishes one complete GitHub Release as latest only after its assets are read
back and verified. Run only where the authorized signing and release credentials
are provisioned.
USAGE
  exit 2
}

bundle=
expected_manifest_sha256=
while (($#)); do
  case $1 in
    --bundle)
      (($# >= 2)) || usage
      bundle=$2
      shift 2
      ;;
    --manifest-sha256)
      (($# >= 2)) || usage
      expected_manifest_sha256=$2
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *) usage ;;
  esac
done
[[ -n $bundle && $expected_manifest_sha256 =~ ^[0-9a-f]{64}$ ]] || usage
[[ -d $bundle && ! -L $bundle ]] || die "transfer bundle must be a regular directory."
shopt -s nullglob dotglob
root_paths=("$bundle"/*)
shopt -u nullglob dotglob
((${#root_paths[@]} == 3)) || die "transfer root must contain only manifest.json, SHA256SUMS, and payload."
for path in "${root_paths[@]}"; do
  case ${path##*/} in
    manifest.json|SHA256SUMS) [[ -f $path && ! -L $path ]] || die "transfer root has an invalid ${path##*/}." ;;
    payload) [[ -d $path && ! -L $path ]] || die "transfer root payload must be a regular directory." ;;
    *) die "transfer root contains an unexpected entry: ${path##*/}." ;;
  esac
done

checkout_branch=$(git -C "$repo_root" branch --show-current)
[[ $checkout_branch == main ]] || die "sign from Gooarchy main, not $checkout_branch."
[[ -z $(git -C "$repo_root" status --porcelain) ]] || die "the signer source checkout has uncommitted changes."
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
key_reference=${GOOARCHY_SIGNING_KEY_REF:-}
[[ $key_reference == op://* ]] || die "GOOARCHY_SIGNING_KEY_REF must point to the approved signing-key item."

# Snapshot the transfer before inspecting it so later changes to the shared transfer path cannot
# alter bytes after verification.
work_parent=${GOOARCHY_SIGNER_TMPDIR:-${TMPDIR:-/tmp}}
mkdir -p -- "$work_parent"
work_dir=$(mktemp -d "$work_parent/gooarchy-sign-publish.XXXXXX") || die "could not create a private signer workspace."
chmod 700 "$work_dir"
trap 'rm -rf -- "$work_dir"' EXIT
snapshot="$work_dir/transfer"
mkdir -m 700 "$snapshot"
for path in manifest.json SHA256SUMS; do
  [[ -f $bundle/$path && ! -L $bundle/$path ]] || die "transfer is missing regular $path."
  cp -- "$bundle/$path" "$snapshot/$path"
done
[[ -d $bundle/payload && ! -L $bundle/payload ]] || die "transfer is missing a regular payload directory."
mkdir -m 700 "$snapshot/payload"
shopt -s nullglob dotglob
payload_paths=("$bundle/payload"/*)
shopt -u nullglob dotglob
for path in "${payload_paths[@]}"; do
  [[ -f $path && ! -L $path ]] || die "transfer payload contains a non-regular file."
  cp -- "$path" "$snapshot/payload/$(basename -- "$path")"
done

manifest_summary=$(python3 "$script_dir/repository-protocol.py" verify --bundle "$snapshot" \
  --expected-manifest-sha256 "$expected_manifest_sha256" \
  --expected-fingerprint "$public_fingerprint") || die "transfer verification failed."
manifest_file="$snapshot/manifest.json"
source_commit=$(jq -r '.source_commit' "$manifest_file")
source_tree=$(jq -r '.source_tree' "$manifest_file")
[[ $source_commit == "$checkout_commit" && $source_tree == "$checkout_tree" ]] ||
  die "transfer source identity does not match this clean Gooarchy main checkout."

public_home="$work_dir/public-gnupg"
signer_home="$work_dir/signer-gnupg"
mkdir -m 700 "$public_home" "$signer_home"
GNUPGHOME=$public_home gpg --batch --import "$public_key_file" >/dev/null 2>&1 ||
  die "could not load the public repository key."
actual_public_fingerprint=$(GNUPGHOME=$public_home gpg --batch --with-colons --show-keys \
  --with-fingerprint "$public_key_file" | awk -F: '$1 == "fpr" { print toupper($10); exit }')
[[ $actual_public_fingerprint == "$public_fingerprint" ]] || die "public key and configured fingerprint differ."
manifest_fingerprint=$(jq -r '.signing_fingerprint' "$manifest_file")
[[ $manifest_fingerprint == "$public_fingerprint" ]] || die "transfer bundle targets a different signing key."

read_latest_tag() {
  local release_list
  release_list=$(gh release list --repo "$release_repo" --limit 1000 --exclude-drafts \
    --exclude-pre-releases --json tagName,isLatest) || return 1
  jq -r '[.[] | select(.isLatest == true)][0].tagName // ""' <<<"$release_list"
}

base_tag=$(jq -r '.base.release_tag // ""' "$manifest_file")
current_latest=$(read_latest_tag) || die "could not read the current published release."
[[ $current_latest == "$base_tag" ]] ||
  die "the current latest release changed after package production; rebuild from the current base."

previous_dir="$work_dir/previous"
mkdir -m 700 "$previous_dir"
if [[ -n $base_tag ]]; then
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

# The transferred database is intentionally unsigned and contains no embedded package signatures.
# Racter creates a detached signature for every package and the database after validating the bundle.
signing_log="$work_dir/op-import.log"
if ! op read "$key_reference" 2>/dev/null | \
  GNUPGHOME=$signer_home gpg --batch --import >"$signing_log" 2>&1; then
  die "1Password did not provide the configured Gooarchy signing key."
fi
secret_fingerprints=$(GNUPGHOME=$signer_home gpg --batch --with-colons \
  --list-secret-keys --with-fingerprint | awk -F: '$1 == "fpr" { print toupper($10) }')
grep -Fxq "$public_fingerprint" <<<"$secret_fingerprints" ||
  die "the 1Password signing key does not match the committed public fingerprint."

asset_dir="$work_dir/assets"
mkdir -m 700 "$asset_dir"
asset_names=()
while IFS= read -r filename; do
  [[ -n $filename ]] || continue
  [[ $filename =~ ^[A-Za-z0-9][A-Za-z0-9._+:-]*$ && $filename != *..* ]] ||
    die "transfer has an unsafe package filename."
  package_path="$snapshot/payload/$filename"
  signature_path="$package_path.sig"
  GNUPGHOME=$signer_home gpg --batch --yes --local-user "$public_fingerprint" \
    --detach-sign --output "$signature_path" "$package_path" || die "could not sign package $filename."
  GNUPGHOME=$public_home gpg --batch --verify "$signature_path" "$package_path" >/dev/null 2>&1 ||
    die "new package signature did not verify for $filename."
  cp -- "$package_path" "$asset_dir/$filename"
  cp -- "$signature_path" "$asset_dir/$filename.sig"
  asset_names+=("$filename" "$filename.sig")
done < <(jq -r '.packages[].filename' "$manifest_file" | sort)

unsigned_database="$snapshot/payload/gooarchy.db"
database_signature="$work_dir/gooarchy.db.sig"
GNUPGHOME=$signer_home gpg --batch --yes --local-user "$public_fingerprint" \
  --detach-sign --output "$database_signature" "$unsigned_database" ||
  die "could not sign the repository database."
GNUPGHOME=$public_home gpg --batch --verify "$database_signature" "$unsigned_database" >/dev/null 2>&1 ||
  die "new repository database signature did not verify."
cp -- "$unsigned_database" "$asset_dir/gooarchy.db"
cp -- "$database_signature" "$asset_dir/gooarchy.db.sig"
asset_names+=(gooarchy.db gooarchy.db.sig)

asset_paths=()
for filename in "${asset_names[@]}"; do asset_paths+=("$asset_dir/$filename"); done

assert_latest_unchanged() {
  local actual
  actual=$(read_latest_tag) || die "could not re-read the current latest release."
  [[ $actual == "$base_tag" ]] || die "the current latest release changed during this publication; leaving the draft unpublished."
}
assert_latest_unchanged
manifest_tag=${expected_manifest_sha256:0:12}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
nonce=${work_dir##*.}
release_tag="gooarchy-repo-${source_commit:0:12}-${timestamp}-${manifest_tag}-${nonce}"
notes=$(printf 'Complete repository snapshot built from Gooarchy %s (tree %s).\nTransfer manifest SHA-256: %s.' \
  "$source_commit" "$source_tree" "$expected_manifest_sha256")
gh release create "$release_tag" "${asset_paths[@]}" --repo "$release_repo" \
  --target "$source_commit" --draft --latest=false \
  --title "Gooarchy package repository $release_tag" --notes "$notes" ||
  die "could not upload the complete unpublished release draft; the previous latest remains supported."

# GitHub's draft is not eligible for latest until every release asset is read back byte-for-byte.
verify_dir="$work_dir/upload-readback"
mkdir -m 700 "$verify_dir"
gh release download "$release_tag" --repo "$release_repo" --dir "$verify_dir" ||
  die "could not read back the complete release draft; the previous latest remains supported."
expected_names=$(printf '%s\n' "${asset_names[@]}" | sort)
shopt -s nullglob dotglob
verify_paths=("$verify_dir"/*)
shopt -u nullglob dotglob
for path in "${verify_paths[@]}"; do
  [[ -f $path && ! -L $path ]] || die "draft download contains a non-regular entry."
done
actual_names=$(printf '%s\n' "${verify_paths[@]##*/}" | sort)
[[ $actual_names == "$expected_names" ]] || die "draft assets are incomplete or have changed names; the previous latest remains supported."
for filename in "${asset_names[@]}"; do
  cmp -s -- "$asset_dir/$filename" "$verify_dir/$filename" ||
    die "draft asset bytes differ for $filename; the previous latest remains supported."
done
assert_latest_unchanged

# One final GitHub operation makes the fully verified draft published and latest.
if ! gh release edit "$release_tag" --repo "$release_repo" --draft=false --latest; then
  current_latest=$(read_latest_tag) || die "publish response was unclear and latest readback failed."
  [[ $current_latest == "$release_tag" ]] || die "GitHub did not make the verified release latest."
fi
current_latest=$(read_latest_tag) || die "could not read back the published latest release."
[[ $current_latest == "$release_tag" ]] || die "the verified release was published but is not latest."
printf 'Published complete repository release %s as latest from Gooarchy %s.\n' "$release_tag" "$source_commit"
printf 'Transfer manifest SHA-256: %s\n' "$expected_manifest_sha256"
