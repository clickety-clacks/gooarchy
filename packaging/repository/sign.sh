#!/usr/bin/env bash
# Sign an immutable builder transfer; this command never uploads or publishes it.
set -euo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || {
  echo "sign: run from the clean Gooarchy source checkout used for this transfer" >&2
  exit 1
}
die() { echo "sign: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'USAGE'
Usage: packaging/repository/sign.sh --signer-role primary|backup \
       --bundle <transfer-directory> --manifest-sha256 <64-hex-digits> \
       --output <new-signed-transfer-directory>

Verifies a builder transfer, creates detached signatures for every package and
the repository database, and writes a signed transfer directory. It never calls
GitHub or publishes a release. Backup signing must be selected explicitly.
USAGE
  exit 2
}

bundle=
output_dir=
expected_manifest_sha256=
signer_role=
while (($#)); do
  case $1 in
    --signer-role)
      (($# >= 2)) || usage
      signer_role=$2
      shift 2
      ;;
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
    --output)
      (($# >= 2)) || usage
      output_dir=$2
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *) usage ;;
  esac
done
[[ $signer_role == primary || $signer_role == backup ]] || usage
[[ -n $bundle && -n $output_dir && $expected_manifest_sha256 =~ ^[0-9a-f]{64}$ ]] || usage
[[ -d $bundle && ! -L $bundle ]] || die "transfer bundle must be a regular directory."

bundle=$(realpath -- "$bundle")
output_dir=$(realpath -m -- "$output_dir")
case $output_dir in
  "$bundle"|"$bundle"/*) die "signed output must be outside the immutable builder transfer." ;;
esac
[[ ! -e $output_dir && ! -L $output_dir ]] || die "signed output already exists; choose a new path."

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

case $signer_role in
  primary) key_reference=${GOOARCHY_SIGNING_KEY_REF:-} ;;
  backup) key_reference=${GOOARCHY_BACKUP_SIGNING_KEY_REF:-} ;;
esac
[[ $key_reference == op://* ]] || die "the selected signer's 1Password key reference is not configured."

work_parent=${GOOARCHY_SIGNER_TMPDIR:-${TMPDIR:-/tmp}}
mkdir -p -- "$work_parent"
work_dir=$(mktemp -d "$work_parent/gooarchy-sign.XXXXXX") || die "could not create a private signer workspace."
chmod 700 "$work_dir"
output_parent=$(dirname -- "$output_dir")
mkdir -p -- "$output_parent"
signed_tmp=$(mktemp -d "$output_parent/.gooarchy-signed.XXXXXX") || {
  rm -rf -- "$work_dir"
  die "could not stage the signed transfer."
}
chmod 755 "$signed_tmp"
cleanup() {
  rm -rf -- "$work_dir"
  if [[ -n $signed_tmp && -d $signed_tmp ]]; then
    rm -rf -- "$signed_tmp"
  fi
}
trap cleanup EXIT

# Snapshot before validation or signing so later edits to the shared transfer path cannot alter it.
snapshot="$work_dir/transfer"
mkdir -m 700 "$snapshot" "$snapshot/payload"
cp -- "$bundle/manifest.json" "$bundle/SHA256SUMS" "$snapshot/"
shopt -s nullglob dotglob
payload_paths=("$bundle/payload"/*)
shopt -u nullglob dotglob
for path in "${payload_paths[@]}"; do
  [[ -f $path && ! -L $path ]] || die "transfer payload contains a non-regular file."
  cp -- "$path" "$snapshot/payload/$(basename -- "$path")"
done
python3 "$script_dir/repository-protocol.py" verify --bundle "$snapshot" \
  --expected-manifest-sha256 "$expected_manifest_sha256" \
  --expected-fingerprint "$public_fingerprint" >/dev/null || die "transfer verification failed."

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
  --with-fingerprint "$public_key_file" 2>/dev/null | awk -F: '$1 == "fpr" { print toupper($10); exit }')
[[ $actual_public_fingerprint == "$public_fingerprint" ]] || die "public key and configured fingerprint differ."
manifest_fingerprint=$(jq -r '.signing_fingerprint' "$manifest_file")
[[ $manifest_fingerprint == "$public_fingerprint" ]] || die "transfer bundle targets a different signing key."

signing_log="$work_dir/op-import.log"
if ! op read "$key_reference" 2>/dev/null | \
  GNUPGHOME=$signer_home gpg --batch --import >"$signing_log" 2>&1; then
  die "1Password did not provide the selected Gooarchy signing key."
fi
secret_fingerprints=$(GNUPGHOME=$signer_home gpg --batch --with-colons \
  --list-secret-keys --with-fingerprint | awk -F: '$1 == "fpr" { print toupper($10) }')
grep -Fxq "$public_fingerprint" <<<"$secret_fingerprints" ||
  die "the selected 1Password signing key does not match the committed public fingerprint."

mkdir -m 755 "$signed_tmp/payload" "$signed_tmp/signatures"
cp -- "$snapshot/manifest.json" "$snapshot/SHA256SUMS" "$signed_tmp/"
cp -- "$snapshot/payload/"* "$signed_tmp/payload/"
mapfile -t asset_names < <(jq -r '[.packages[].filename, "gooarchy.db"] | sort[]' "$manifest_file")
((${#asset_names[@]} > 0)) || die "the immutable build manifest contains no signable assets."
for filename in "${asset_names[@]}"; do
  [[ $filename =~ ^[A-Za-z0-9][A-Za-z0-9._+:-]*$ && $filename != *..* ]] ||
    die "transfer has an unsafe package filename."
  GNUPGHOME=$signer_home gpg --batch --yes --local-user "$public_fingerprint" \
    --detach-sign --output "$signed_tmp/signatures/$filename.sig" \
    "$snapshot/payload/$filename" || die "could not sign $filename."
  GNUPGHOME=$public_home gpg --batch --verify "$signed_tmp/signatures/$filename.sig" \
    "$snapshot/payload/$filename" >/dev/null 2>&1 || die "new signature did not verify for $filename."
done
python3 "$script_dir/repository-protocol.py" sign-receipt \
  --bundle "$snapshot" --signatures "$signed_tmp/signatures" \
  --expected-manifest-sha256 "$expected_manifest_sha256" \
  --fingerprint "$public_fingerprint" --signer-role "$signer_role" \
  --output "$signed_tmp/SIGNATURES.json" >/dev/null || die "could not seal the signature receipt."
python3 "$script_dir/repository-protocol.py" verify-signed --bundle "$signed_tmp" \
  --expected-manifest-sha256 "$expected_manifest_sha256" \
  --expected-fingerprint "$public_fingerprint" >/dev/null || die "signed transfer validation failed."

chmod 755 "$signed_tmp/payload" "$signed_tmp/signatures"
chmod 644 "$signed_tmp/manifest.json" "$signed_tmp/SHA256SUMS" "$signed_tmp/SIGNATURES.json"
chmod 644 "$signed_tmp/payload/"* "$signed_tmp/signatures/"*
mv -T -- "$signed_tmp" "$output_dir" || die "could not commit the complete signed transfer directory."
signed_tmp=
printf 'Signed %s package/database assets as %s; no upload was attempted.\n' \
  "${#asset_names[@]}" "$signer_role"
printf 'Transfer manifest SHA-256: %s\n' "$expected_manifest_sha256"
