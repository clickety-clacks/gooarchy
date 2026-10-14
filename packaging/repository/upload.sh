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
release_api="https://api.github.com/repos/$release_repo"
release_download="https://github.com/$release_repo/releases/download"

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
  local latest_json status
  latest_json="$work_dir/latest-release.json"
  status=$(curl --silent --show-error --output "$latest_json" --write-out '%{http_code}' \
    "$release_api/releases/latest") || return 1
  if [[ $status == 200 ]]; then
    jq -e '.draft == false and .prerelease == false and (.tag_name | type == "string")' \
      "$latest_json" >/dev/null || return 1
    jq -r '.tag_name' "$latest_json"
  elif [[ $status == 404 ]]; then
    printf '\n'
  else
    return 1
  fi
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
  curl --fail --silent --show-error --location \
    "$release_download/$base_tag/gooarchy.db" --output "$previous_dir/gooarchy.db" ||
    die "could not download the current latest repository database."
  curl --fail --silent --show-error --location \
    "$release_download/$base_tag/gooarchy.db.sig" --output "$previous_dir/gooarchy.db.sig" ||
    die "could not download the current latest database signature."
  [[ -s $previous_dir/gooarchy.db && -s $previous_dir/gooarchy.db.sig ]] ||
    die "the current release is missing its repository database or detached signature."
  GNUPGHOME=$public_home gpg --batch --verify "$previous_dir/gooarchy.db.sig" \
    "$previous_dir/gooarchy.db" >/dev/null 2>&1 || die "the current repository database signature is invalid."
  while IFS=$'\t' read -r old_name old_version old_filename; do
    [[ -n $old_name ]] || continue
    [[ $old_filename =~ ^[A-Za-z0-9][A-Za-z0-9._+:-]*$ && $old_filename != *..* ]] ||
      die "the current repository database contains an unsafe package filename."
    curl --fail --silent --show-error --location \
      "$release_download/$base_tag/$old_filename" --output "$previous_dir/$old_filename" ||
      die "could not download current package data for $old_name."
    curl --fail --silent --show-error --location \
      "$release_download/$base_tag/$old_filename.sig" --output "$previous_dir/$old_filename.sig" ||
      die "could not download the current package signature for $old_name."
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
upload_token_ref=${GOOARCHY_RELEASE_UPLOAD_TOKEN_REF:-}
[[ -n $upload_token_ref ]] ||
  die "set GOOARCHY_RELEASE_UPLOAD_TOKEN_REF to the approved repository-scoped vault token reference."
command -v op >/dev/null 2>&1 || die "the approved vault CLI is unavailable for release upload."

# The token travels only through stdin. The REST client creates a non-latest draft, uploads and
# reads every expected byte back, then publishes and promotes it in the final API operation.
op read "$upload_token_ref" | python3 "$script_dir/release-api.py" publish \
  --manifest "$manifest_file" --signatures "$snapshot/SIGNATURES.json" --assets-dir "$asset_dir" \
  --manifest-sha256 "$expected_manifest_sha256" --release-tag "$release_tag" \
  --source-commit "$source_commit" --source-tree "$source_tree" --signer-role "$signer_role" ||
  die "release upload did not complete its exact-content and latest-release checks."
