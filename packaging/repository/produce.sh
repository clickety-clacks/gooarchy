#!/usr/bin/env bash
# Build unsigned Arch packages and an unsigned repository database for a separate signer.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || {
  echo "produce: run from a clean Gooarchy source checkout" >&2
  exit 1
}
die() { echo "produce: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'USAGE'
Usage: packaging/repository/produce.sh --output <new-transfer-directory> --all
       packaging/repository/produce.sh --output <new-transfer-directory> --flavorings-package <archive> --all
       packaging/repository/produce.sh --output <new-transfer-directory> --cua-driver-package <archive> --all
       packaging/repository/produce.sh --output <new-transfer-directory> --scottland-pair <directory> <scottland> <scottland-omarchy>
       packaging/repository/produce.sh --output <new-transfer-directory> <package> [<package> ...]

Builds package archives and an unsigned repository database only. It does not
read signing credentials, create signatures, or contact GitHub Releases. The optional
Flavorings archive is accepted only when it matches the reviewed source-input manifest.
The optional cua-driver archive is accepted only when it matches the pinned package-input manifest.
The Scottland pair directory is accepted only when both unchanged release assets match the
pinned upstream identity, metadata, dependency and release-checksum manifest.
USAGE
  exit 2
}

output_dir=
flavorings_package=
cua_driver_package=
scottland_pair_dir=
all_packages=0
requested_packages=()
while (($#)); do
  case $1 in
    --output)
      (($# >= 2)) || usage
      output_dir=$2
      shift 2
      ;;
    --all)
      all_packages=1
      shift
      ;;
    --flavorings-package)
      (($# >= 2)) || usage
      [[ -z $flavorings_package ]] || usage
      flavorings_package=$2
      shift 2
      ;;
    --cua-driver-package)
      (($# >= 2)) || usage
      [[ -z $cua_driver_package ]] || usage
      cua_driver_package=$2
      shift 2
      ;;
    --scottland-pair)
      (($# >= 2)) || usage
      [[ -z $scottland_pair_dir ]] || usage
      scottland_pair_dir=$2
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    --*) usage ;;
    *) requested_packages+=("$1"); shift ;;
  esac
done
[[ -n $output_dir ]] || usage
if ((all_packages)); then
  ((${#requested_packages[@]} == 0)) || usage
else
  ((${#requested_packages[@]} > 0)) || usage
fi

checkout_branch=$(git -C "$repo_root" branch --show-current)
[[ $checkout_branch == main ]] || die "build from Gooarchy main, not $checkout_branch."
[[ -z $(git -C "$repo_root" status --porcelain) ]] || die "the Gooarchy main checkout has uncommitted changes."
checkout_commit=$(git -C "$repo_root" rev-parse HEAD)
[[ $(uname -m) == x86_64 ]] || die "package production requires an x86_64 build machine."

fingerprint_file="$repo_root/packaging/keys/gooarchy.fingerprint"
public_key_file="$repo_root/packaging/keys/gooarchy.asc"
[[ -s $fingerprint_file && -s $public_key_file ]] || die "the public repository key and fingerprint are not configured."
if grep -q '^Placeholder:' "$fingerprint_file" "$public_key_file"; then
  die "the public repository key is still a placeholder."
fi
public_fingerprint=$(awk '/^[[:space:]]*($|#)/ { next } { gsub(/[[:space:]]/, ""); print toupper($0); exit }' "$fingerprint_file")
[[ $public_fingerprint =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]] ||
  die "the configured public fingerprint is invalid."

repo_slug=${GOOARCHY_RELEASE_REPOSITORY:-clickety-clacks/gooarchy}
[[ $repo_slug == clickety-clacks/gooarchy ]] || die "transfer protocol is configured for the Gooarchy release repository only."
release_api="https://api.github.com/repos/$repo_slug/releases/latest"
release_download="https://github.com/$repo_slug/releases/download"

work_parent=${GOOARCHY_BUILD_TMPDIR:-${TMPDIR:-/tmp}}
mkdir -p -- "$work_parent"
work_dir=$(mktemp -d "$work_parent/gooarchy-produce.XXXXXX") || die "could not create a private build workspace."
chmod 700 "$work_dir"
output_parent=$(dirname -- "$output_dir")
mkdir -p -- "$output_parent"
[[ ! -e $output_dir && ! -L $output_dir ]] || die "transfer output already exists; choose a new empty path."
transfer_tmp=$(mktemp -d "$output_parent/.gooarchy-transfer.XXXXXX") || die "could not stage the transfer bundle."
chmod 755 "$transfer_tmp"
mkdir -m 755 "$transfer_tmp/payload"
cleanup() {
  rm -rf -- "$work_dir"
  [[ -d $transfer_tmp ]] && rm -rf -- "$transfer_tmp"
}
trap cleanup EXIT

# Import only the public key. Previous packages are verified before they enter the next database.
verify_home="$work_dir/public-gnupg"
mkdir -m 700 "$verify_home"
GNUPGHOME=$verify_home gpg --batch --import "$public_key_file" >/dev/null 2>&1 ||
  die "could not load the public repository key for base-release verification."
actual_public_fingerprint=$(GNUPGHOME=$verify_home gpg --batch --with-colons --show-keys \
  --with-fingerprint "$public_key_file" 2>/dev/null | awk -F: '$1 == "fpr" { print toupper($10); exit }') ||
  die "could not read the public repository key fingerprint."
[[ $actual_public_fingerprint == "$public_fingerprint" ]] ||
  die "the public repository key does not match its configured fingerprint."

latest_json="$work_dir/latest-release.json"
http_status=$(curl --silent --show-error --output "$latest_json" --write-out '%{http_code}' "$release_api") ||
  die "could not read the public latest-release record."
base_tag=
base_database_sha256=
base_json="$work_dir/base.json"
base_records_file="$work_dir/base-records.tsv"
old_directory="$work_dir/base-assets"
mkdir -m 700 "$old_directory"
if [[ $http_status == 200 ]]; then
  jq -e '.draft == false and .prerelease == false and (.tag_name | type == "string")' \
    "$latest_json" >/dev/null || die "the public latest-release response is not a published release."
  base_tag=$(jq -r '.tag_name' "$latest_json")
  [[ $base_tag =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $base_tag != *..* ]] ||
    die "the current release has an unsafe tag name."
  curl --fail --silent --show-error --location "$release_download/$base_tag/gooarchy.db" \
    --output "$old_directory/gooarchy.db" || die "could not download the current repository database."
  curl --fail --silent --show-error --location "$release_download/$base_tag/gooarchy.db.sig" \
    --output "$old_directory/gooarchy.db.sig" || die "could not download the current repository database signature."
  GNUPGHOME=$verify_home gpg --batch --verify "$old_directory/gooarchy.db.sig" \
    "$old_directory/gooarchy.db" >/dev/null 2>&1 || die "the current repository database signature is invalid."
  base_database_sha256=$(sha256sum "$old_directory/gooarchy.db" | awk '{print $1}')
  base_records=$(python3 "$script_dir/read-db.py" "$old_directory/gooarchy.db") ||
    die "could not read the current repository database."
  printf '%s\n' "$base_records" >"$base_records_file"
  while IFS=$'\t' read -r old_name old_version old_filename; do
    [[ -n $old_name ]] || continue
    [[ $old_filename =~ ^[A-Za-z0-9][A-Za-z0-9._+:-]*$ && $old_filename != *..* ]] ||
      die "the current repository database contains an unsafe package filename."
    curl --fail --silent --show-error --location "$release_download/$base_tag/$old_filename" \
      --output "$old_directory/$old_filename" || die "could not download current package $old_filename."
    curl --fail --silent --show-error --location "$release_download/$base_tag/$old_filename.sig" \
      --output "$old_directory/$old_filename.sig" || die "could not download the signature for $old_filename."
    GNUPGHOME=$verify_home gpg --batch --verify "$old_directory/$old_filename.sig" \
      "$old_directory/$old_filename" >/dev/null 2>&1 || die "the current package signature is invalid: $old_filename."
    cp -- "$old_directory/$old_filename" "$transfer_tmp/payload/$old_filename"
  done <"$base_records_file"
elif [[ $http_status == 404 ]]; then
  printf 'No published package release exists yet.\n'
else
  die "public latest-release lookup returned HTTP $http_status."
fi

recipe_roots=()
for candidate_root in "$repo_root/packaging/arch" "$repo_root/packaging/gooarchy-flavorings" \
  "$repo_root/packaging/linux-gooarchy"; do
  [[ -d $candidate_root ]] && recipe_roots+=("$candidate_root")
done
((${#recipe_roots[@]} > 0)) || die "no Gooarchy package recipes were found."
declare -A recipe_for=()
while IFS= read -r -d '' recipe_file; do
  recipe_dir=$(dirname -- "$recipe_file")
  srcinfo=$(cd -- "$recipe_dir" && GOOARCHY_PATH="$repo_root" \
    GOOARCHY_INSTALL="$repo_root/install" makepkg --printsrcinfo) ||
    die "could not read package names from $recipe_file."
  while IFS= read -r package_name; do
    [[ -n $package_name ]] || continue
    [[ ! ${recipe_for[$package_name]+present} ]] || die "more than one recipe builds $package_name."
    recipe_for[$package_name]=$recipe_file
  done < <(sed -nE 's/^[[:space:]]*pkgname = ([^[:space:]]+)$/\1/p' <<<"$srcinfo")
done < <(find "${recipe_roots[@]}" -type f -name PKGBUILD -print0 | sort -z)
[[ ${recipe_for[scottland]+present} ]] || recipe_for[scottland]=@scottland
[[ ${recipe_for[scottland-omarchy]+present} ]] || recipe_for[scottland-omarchy]=@scottland

if ((all_packages)); then
  mapfile -t requested_packages < <(printf '%s\n' "${!recipe_for[@]}" | sort -u)
fi
declare -A selected=()
for package_name in "${requested_packages[@]}"; do
  [[ ${recipe_for[$package_name]+present} ]] || die "no package recipe is available for $package_name."
  [[ ! ${selected[$package_name]+present} ]] || die "package requested more than once: $package_name."
  selected[$package_name]=1
done
if [[ -n $flavorings_package ]]; then
  [[ ${selected[gooarchy-flavorings]+present} ]] ||
    die "--flavorings-package requires gooarchy-flavorings in the selected package set."
  [[ -f $flavorings_package && ! -L $flavorings_package ]] ||
    die "the prebuilt Flavorings input must be a regular package archive."
  [[ ${recipe_for[gooarchy-flavorings]:-} == "$repo_root/packaging/gooarchy-flavorings/PKGBUILD" ]] ||
    die "the prebuilt Flavorings input requires Gooarchy's self-contained Flavorings recipe."
fi
if [[ -n $cua_driver_package ]]; then
  [[ ${selected[cua-driver]+present} ]] ||
    die "--cua-driver-package requires cua-driver in the selected package set."
  [[ -f $cua_driver_package && ! -L $cua_driver_package ]] ||
    die "the prebuilt cua-driver input must be a regular package archive."
  [[ ${recipe_for[cua-driver]:-} == "$repo_root/packaging/arch/cua-driver/PKGBUILD" ]] ||
    die "the prebuilt cua-driver input requires Gooarchy's canonical cua-driver recipe."
fi
if [[ -n $scottland_pair_dir ]]; then
  [[ ${selected[scottland]+present} && ${selected[scottland-omarchy]+present} ]] ||
    die "--scottland-pair requires both scottland and scottland-omarchy in the selected package set."
  [[ ${recipe_for[scottland]} == @scottland && ${recipe_for[scottland-omarchy]} == @scottland ]] ||
    die "--scottland-pair requires the existing Scottland source-package mapping."
fi

required_initial=(gooarchy gooarchy-flavorings scottland xdg-desktop-portal-wlr-gooarchy \
  linux-gooarchy linux-gooarchy-headers cua-driver)
if [[ -z $base_tag ]]; then
  for required_name in "${required_initial[@]}"; do
    [[ ${selected[$required_name]+present} ]] || die "the first repository transfer must include all seven required packages; missing $required_name."
  done
elif ! awk -F '\t' '$1 == "cua-driver" { found=1 } END { exit !found }' "$base_records_file"; then
  [[ ${selected[cua-driver]+present} ]] ||
    die "the transfer must add cua-driver before Gooarchy can depend on it."
  [[ ${selected[gooarchy]+present} ]] ||
    die "the transfer must update gooarchy with cua-driver before the first cua-driver release."
fi

[[ -z ${GOOARCHY_SCOTTLAND_REF:-} && -z ${GOOARCHY_SCOTTLAND_REF_KIND:-} ]] ||
  die "package production reads the configured main Scottland pin; local ref overrides are not supported."
source "$repo_root/install/sources.conf"
scottland_repo=$GOOARCHY_SCOTTLAND_REPO
scottland_ref=$GOOARCHY_SCOTTLAND_REF
if [[ $GOOARCHY_SCOTTLAND_SOURCE_KIND == tag && $scottland_ref =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  scottland_source_label="Scottland tag:$scottland_ref"
else
  die "Gooarchy main publication requires a final Scottland version tag."
fi
if [[ ${recipe_for[gooarchy-flavorings]+present} &&
  ${recipe_for[gooarchy-flavorings]} != @scottland &&
  ${recipe_for[gooarchy-flavorings]} == "$repo_root/packaging/gooarchy-flavorings/PKGBUILD" ]]; then
  flavorings_recipe_identity=$(python3 "$script_dir/repository-protocol.py" flavorings-recipe-identity \
    --recipe "${recipe_for[gooarchy-flavorings]}") || die "gooarchy-flavorings recipe identity is invalid."
  flavorings_source_ref=$(jq -er '.source.tag' <<<"$flavorings_recipe_identity") || die "Flavorings tag is missing."
  flavorings_package_version=$(jq -er '.version' <<<"$flavorings_recipe_identity") || die "Flavorings package version is missing."
fi
flavorings_input_filename=
flavorings_source_revision=
if [[ -n $flavorings_package ]]; then
  flavorings_input_manifest=$(python3 "$script_dir/repository-protocol.py" flavorings-input-manifest-path \
    --recipe "$repo_root/packaging/gooarchy-flavorings/PKGBUILD") || die "could not select the pinned Flavorings package-input manifest."
  [[ -s $flavorings_input_manifest ]] || die "the reviewed Flavorings package-input manifest is missing."
  flavorings_input_record=$(python3 "$script_dir/repository-protocol.py" verify-flavorings-input \
    --archive "$flavorings_package" --manifest "$flavorings_input_manifest" \
    --recipe "$repo_root/packaging/gooarchy-flavorings/PKGBUILD") ||
    die "the prebuilt Flavorings package does not match the reviewed source input."
  flavorings_input_filename=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["filename"])' <<<"$flavorings_input_record")
  flavorings_source_revision=$(jq -er '.source_revision' <<<"$flavorings_input_record") ||
    die "could not record imported Flavorings provenance."
fi
cua_driver_input_filename=
cua_driver_source_revision=
if [[ -n $cua_driver_package ]]; then
  cua_driver_input_manifest=$(python3 "$script_dir/repository-protocol.py" cua-driver-input-manifest-path \
    --recipe "$repo_root/packaging/arch/cua-driver/PKGBUILD") ||
    die "could not select the canonical cua-driver package-input manifest."
  [[ -s $cua_driver_input_manifest ]] || die "the pinned cua-driver package-input manifest is missing."
  cua_driver_input_record=$(python3 "$script_dir/repository-protocol.py" verify-cua-driver-input \
    --archive "$cua_driver_package" --manifest "$cua_driver_input_manifest" \
    --recipe "$repo_root/packaging/arch/cua-driver/PKGBUILD") ||
    die "the prebuilt cua-driver package does not match the pinned package-input manifest."
  cua_driver_input_filename=$(jq -er '.filename' <<<"$cua_driver_input_record") ||
    die "could not read the verified cua-driver archive filename."
  cua_driver_source_revision=$(jq -er '.source_revision' <<<"$cua_driver_input_record") ||
    die "could not record imported cua-driver provenance."
fi

built_dir="$work_dir/built"
sources_dir="$work_dir/sources"
source_build_dir="$work_dir/build"
kernel_dir="$work_dir/kernel"
mkdir -m 700 "$built_dir" "$sources_dir" "$source_build_dir"
scottland_pair_record=
if [[ -n $scottland_pair_dir ]]; then
  scottland_pair_record=$(python3 "$script_dir/repository-protocol.py" stage-scottland-pair-input \
    --directory "$scottland_pair_dir" --output-directory "$built_dir") ||
    die "the Scottland pair does not match its exact pinned release input."
fi
makepkg_config="$work_dir/makepkg.conf"
{
  printf 'source /etc/makepkg.conf\n'
  printf 'PKGDEST=%q\n' "$built_dir"
  printf 'SRCDEST=%q\n' "$sources_dir"
  printf 'BUILDDIR=%q\n' "$source_build_dir"
  printf 'PACKAGER=%q\n' 'Gooarchy'
  printf 'SIGNPKG=%q\n' 'no'
} >"$makepkg_config"
export MAKEPKG_CONF=$makepkg_config

build_static_recipe() {
  local recipe_file=$1 recipe_dir build_dir recipe_key
  recipe_dir=$(dirname -- "$recipe_file")
  recipe_key=$(printf '%s' "$recipe_dir" | sha256sum | cut -c1-12)
  build_dir="$work_dir/recipe-$recipe_key"
  mkdir -m 700 "$build_dir"
  cp -a -- "$recipe_dir/." "$build_dir/"
  (
    cd -- "$build_dir"
    GOOARCHY_PATH="$repo_root" GOOARCHY_INSTALL="$repo_root/install" \
      PACKAGER=Gooarchy "$script_dir/build-recipe.sh" --noconfirm --needed --force --cleanbuild
  ) || die "makepkg failed for $recipe_file."
}

build_scottland() {
  local source_dir="$work_dir/scottland-source" build_dir
  git clone --quiet "$scottland_repo" "$source_dir" || die "could not fetch the pinned Scottland source."
  git -C "$source_dir" -c advice.detachedHead=false checkout --quiet --force "refs/tags/$scottland_ref" ||
    die "could not check out the requested Scottland final tag."
  git -C "$source_dir" clean -qfdx
  scottland_source_revision=$(git -C "$source_dir" rev-parse HEAD)
  build_dir="$source_dir/packaging/arch"
  [[ -s $build_dir/PKGBUILD ]] || die "the pinned Scottland source has no packaging/arch/PKGBUILD."
  wayfire_package_version=$(pacman -Si extra/wayfire | awk -F: '/^[[:space:]]*Version[[:space:]]*:/ { sub(/^[[:space:]]*/, "", $2); print $2; exit }') ||
    die "could not read the current Arch wayfire version."
  wayfire_version=${wayfire_package_version#*:}
  wayfire_version=${wayfire_version%-*}
  [[ -n $wayfire_version ]] || die "Arch's current wayfire version is missing."
  upstream_version=$(sed -n 's/^pkgver=//p' "$build_dir/PKGBUILD" | sed -n '1p')
  [[ -n $upstream_version ]] || die "Scottland's pinned PKGBUILD has no pkgver."
  revision_count=$(git -C "$source_dir" rev-list --count HEAD)
  scottland_package_version="$upstream_version.r$revision_count.g${scottland_source_revision:0:7}.wf$wayfire_version"
  sed -i -e "s/^pkgver=.*/pkgver=$scottland_package_version/" \
    -e "s/^  depends=('wayfire' /  depends=('wayfire=$wayfire_version' /" "$build_dir/PKGBUILD"
  grep -q "^pkgver=$scottland_package_version$" "$build_dir/PKGBUILD" &&
    grep -Fq "depends=('wayfire=$wayfire_version'" "$build_dir/PKGBUILD" ||
    die "Scottland's PKGBUILD changed shape; refusing to build without the exact Wayfire dependency."
  (
    cd -- "$build_dir"
    PACKAGER=Gooarchy "$script_dir/build-recipe.sh" --noconfirm --needed --force --cleanbuild
  ) || die "makepkg failed for the pinned Scottland recipe."
}

declare -A recipe_built=() package_archive=() package_version=() source_revision=() source_origin=()
for package_name in "${requested_packages[@]}"; do
  recipe_file=${recipe_for[$package_name]}
  if [[ $recipe_file == @scottland ]]; then
    if [[ -n $scottland_pair_dir ]]; then
      source_revision[$package_name]=$(jq -er --arg package "$package_name" \
        '.packages[$package].source_revision' <<<"$scottland_pair_record") ||
        die "the verified Scottland pair has no provenance record for $package_name."
      source_origin[$package_name]=upstream-release
    else
      [[ ${recipe_built[scottland]+present} ]] || build_scottland
      recipe_built[scottland]=1
      source_revision[$package_name]="$scottland_source_label (resolved $scottland_source_revision)"
      source_origin[$package_name]=source-build
    fi
  else
    if [[ $package_name == cua-driver && -n $cua_driver_package ]]; then
      python3 "$script_dir/repository-protocol.py" stage-cua-driver-input \
        --archive "$cua_driver_package" --output "$built_dir/$cua_driver_input_filename" \
        --manifest "$cua_driver_input_manifest" \
        --recipe "$repo_root/packaging/arch/cua-driver/PKGBUILD" \
        >/dev/null || die "the staged prebuilt cua-driver archive does not match its pinned input."
      recipe_built[$recipe_file]=1
      source_revision[$package_name]=$cua_driver_source_revision
      source_origin[$package_name]=prebuilt-input
    elif [[ $package_name == gooarchy-flavorings && -n $flavorings_package ]]; then
      python3 "$script_dir/repository-protocol.py" stage-flavorings-input \
        --archive "$flavorings_package" --output "$built_dir/$flavorings_input_filename" \
        --manifest "$flavorings_input_manifest" \
        --recipe "$repo_root/packaging/gooarchy-flavorings/PKGBUILD" \
        >/dev/null || die "the staged prebuilt Flavorings archive does not match its reviewed source input."
      recipe_built[$recipe_file]=1
      source_revision[$package_name]=$flavorings_source_revision
      source_origin[$package_name]=prebuilt-input
    else
      if [[ ! ${recipe_built[$recipe_file]+present} ]]; then
        recipe_dir=$(dirname -- "$recipe_file")
        if [[ $recipe_dir == "$repo_root/packaging/linux-gooarchy" && -x $recipe_dir/build.sh ]]; then
          free_kb=$(df -Pk "$work_dir" | awk 'END { print $4 }')
          ((free_kb >= 35 * 1024 * 1024)) || die "linux-gooarchy needs at least 35 GiB free in the build workspace."
          GOOARCHY_KERNEL_BUILD="$kernel_dir" GOOARCHY_REPOSITORY_BUILD=1 PACKAGER=Gooarchy \
            "$recipe_dir/build.sh" ||
            die "the pinned Gooarchy kernel build failed."
        else
          build_static_recipe "$recipe_file"
        fi
        recipe_built[$recipe_file]=1
      fi
      case $package_name in
        gooarchy-flavorings)
          if [[ $recipe_file == "$repo_root/packaging/gooarchy-flavorings/PKGBUILD" ]]; then
            flavorings_source_commit=$(jq -er '.source.commit' <<<"$flavorings_recipe_identity")
            flavorings_source_tree=$(jq -er '.source.tree' <<<"$flavorings_recipe_identity")
            flavorings_source_archive_sha256=$(jq -er '.source.archive_sha256' <<<"$flavorings_recipe_identity")
            source_revision[$package_name]="Gooarchy $checkout_commit; gooarchy-flavorings tag:$flavorings_source_ref commit:$flavorings_source_commit tree:$flavorings_source_tree source-archive-sha256:$flavorings_source_archive_sha256"
          else
            source_revision[$package_name]="Gooarchy $checkout_commit; $scottland_source_label"
          fi
          ;;
        linux-gooarchy|linux-gooarchy-headers)
          kernel_version=$(sed -n 's/^pkgver=//p' "$repo_root/packaging/linux-gooarchy/PKGBUILD" | sed -n '1p')
          omarchy_commit=$(sed -n 's/^_omarchy_commit=//p' "$repo_root/packaging/linux-gooarchy/PKGBUILD" | sed -n '1p')
          source_revision[$package_name]="Gooarchy $checkout_commit; Linux $kernel_version; Omarchy $omarchy_commit"
          ;;
        xdg-desktop-portal-wlr-gooarchy)
          portal_tag=$(sed -n 's/^_tag=//p' "$repo_root/packaging/arch/xdg-desktop-portal-wlr/PKGBUILD" | sed -n '1p')
          source_revision[$package_name]="Gooarchy $checkout_commit; portal $portal_tag"
          ;;
        *) source_revision[$package_name]="Gooarchy $checkout_commit" ;;
      esac
      source_origin[$package_name]=source-build
    fi
  fi
done

for package_path in "$built_dir"/*.pkg.tar.* "$kernel_dir"/*.pkg.tar.*; do
  [[ -f $package_path ]] || continue
  # .PKGINFO carries the full epoch:pkgver-pkgrel; pacman -Qp does not accept --print-format.
  package_info=$(python3 "$script_dir/repository-protocol.py" package-info --archive "$package_path") ||
    die "cannot read package metadata from $(basename -- "$package_path")."
  package_name=$(jq -er '.name' <<<"$package_info") ||
    die "package metadata has no valid package name: $(basename -- "$package_path")."
  [[ ${selected[$package_name]+present} ]] || continue
  [[ ! ${package_archive[$package_name]+present} ]] || die "more than one archive was built for $package_name."
  package_packager=$(jq -er '.packager' <<<"$package_info") ||
    die "$package_name has no valid packager identity."
  if [[ ${source_origin[$package_name]:-} == upstream-release ]]; then
    expected_packager=$(jq -er --arg package "$package_name" \
      '.packages[$package].packager' <<<"$scottland_pair_record") ||
      die "the Scottland input has no pinned packager identity for $package_name."
    expected_sha256=$(jq -er --arg package "$package_name" \
      '.packages[$package].sha256' <<<"$scottland_pair_record") ||
      die "the Scottland input has no pinned package hash for $package_name."
    [[ $package_packager == "$expected_packager" ]] ||
      die "$package_name packager metadata differs from the pinned upstream archive."
    [[ $(sha256sum -- "$package_path" | awk '{print $1}') == "$expected_sha256" ]] ||
      die "$package_name bytes differ from the pinned upstream archive."
  else
    [[ $package_packager == Gooarchy ]] ||
      die "$package_name does not carry the Gooarchy source-build packager identity."
  fi
  package_arch=$(jq -er '.arch' <<<"$package_info") || die "$package_name has no valid architecture."
  [[ $package_arch == any || $package_arch == x86_64 ]] || die "$package_name has unsupported architecture $package_arch."
  package_archive[$package_name]=$package_path
  package_version[$package_name]=$(jq -er '.version' <<<"$package_info") ||
    die "$package_name has no valid package version."
done
for package_name in "${requested_packages[@]}"; do
  [[ ${package_archive[$package_name]+present} ]] || die "the selected recipe did not produce $package_name."
done

accepted_packages=()
for package_name in "${requested_packages[@]}"; do
  old_version=none
  if [[ -n $base_tag ]]; then
    while IFS=$'\t' read -r old_name old_ver old_file; do
      if [[ $old_name == "$package_name" ]]; then old_version=$old_ver; break; fi
    done <"$base_records_file"
  fi
  if [[ $old_version != none ]]; then
    comparison=$(vercmp "${package_version[$package_name]}" "$old_version") || die "vercmp failed for $package_name."
    if ((comparison <= 0)); then
      if [[ -n $scottland_pair_dir &&
        ( $package_name == scottland || $package_name == scottland-omarchy ) ]]; then
        die "the pinned Scottland import must advance both pair members; $package_name is not newer than the base release."
      fi
      echo "Refused $package_name: new version ${package_version[$package_name]} is not newer than published version $old_version; source revision: ${source_revision[$package_name]}; this package remains unchanged."
      continue
    fi
  fi
  accepted_packages+=("$package_name")
done
((${#accepted_packages[@]} > 0)) || die "no package version is newer; no transfer was created."

# A package recipe may emit multiple packages. Only selected, version-advancing packages replace
# their base versions; all other base package files remain in the unsigned database.
declare -A chosen_file=() chosen_version=() chosen_source=() chosen_origin=()
for package_name in "${accepted_packages[@]}"; do
  chosen_file[$package_name]=$(basename -- "${package_archive[$package_name]}")
  chosen_version[$package_name]=${package_version[$package_name]}
  chosen_source[$package_name]=${source_revision[$package_name]}
  chosen_origin[$package_name]=${source_origin[$package_name]}
done
if [[ -n $base_tag ]]; then
  while IFS=$'\t' read -r old_name old_ver old_file; do
    [[ -n $old_name ]] || continue
    if [[ ${chosen_file[$old_name]+present} ]]; then
      rm -f -- "$transfer_tmp/payload/$old_file"
    else
      chosen_file[$old_name]=$old_file
      chosen_version[$old_name]=$old_ver
      chosen_source[$old_name]="retained from release tag:$base_tag"
      chosen_origin[$old_name]=retained-release
    fi
  done <"$base_records_file"
fi

# Build a source map that records the package origin and exact source or release revision.
source_map_file="$work_dir/source-map.json"
source_map_tsv="$work_dir/source-map.tsv"
: >"$source_map_tsv"
for package_name in "${!chosen_file[@]}"; do
  origin_kind=${chosen_origin[$package_name]}
  revision=${chosen_source[$package_name]}
  [[ $revision != *$'\t'* && $revision != *$'\n'* ]] || die "invalid source revision for $package_name."
  printf '%s\t%s\t%s\n' "$package_name" "$revision" "$origin_kind" >>"$source_map_tsv"
done
python3 - "$source_map_tsv" "$source_map_file" <<'PY'
import json
import sys
source, destination = sys.argv[1:]
entries = {}
with open(source, encoding="utf-8") as stream:
    for line in stream:
        name, revision, origin_kind = line.rstrip("\n").split("\t", 2)
        if name in entries or not origin_kind:
            raise SystemExit("invalid package source map")
        entries[name] = {"revision": revision, "origin_kind": origin_kind}
with open(destination, "w", encoding="utf-8") as stream:
    json.dump(entries, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY

all_package_paths=()
for package_name in "${!chosen_file[@]}"; do
  filename=${chosen_file[$package_name]}
  package_path="$transfer_tmp/payload/$filename"
  if [[ ! -f $package_path ]]; then
    package_path=${package_archive[$package_name]:-}
    [[ -n $package_path && -f $package_path ]] || die "missing package archive for $package_name."
    cp -- "$package_path" "$transfer_tmp/payload/$filename"
  fi
  all_package_paths+=("$transfer_tmp/payload/$filename")
done
mapfile -t all_package_paths < <(printf '%s\n' "${all_package_paths[@]}" | sort)
((${#all_package_paths[@]} > 0)) || die "no package archives are available for the repository database."

database_archive="$work_dir/gooarchy.db.tar.gz"
repo-add "$database_archive" "${all_package_paths[@]}" >/dev/null ||
  die "repo-add could not create the unsigned repository database."
[[ -s $database_archive ]] || die "repo-add produced no repository database."
cp -- "$database_archive" "$transfer_tmp/payload/gooarchy.db"

base_option=()
if [[ -n $base_tag ]]; then
  python3 "$script_dir/repository-protocol.py" base --release-tag "$base_tag" \
    --database "$old_directory/gooarchy.db" --package-dir "$old_directory" >"$base_json" ||
    die "could not record the exact base release asset set."
  base_option=(--base-json "$base_json")
fi
manifest_sha=$(python3 "$script_dir/repository-protocol.py" write --bundle "$transfer_tmp" \
  --source-root "$repo_root" --source-map "$source_map_file" \
  --fingerprint "$public_fingerprint" "${base_option[@]}") ||
  die "could not create the transfer manifest."
[[ $manifest_sha =~ ^[0-9a-f]{64}$ ]] || die "transfer manifest creation returned an invalid SHA-256."
python3 "$script_dir/repository-protocol.py" verify --bundle "$transfer_tmp" \
  --expected-manifest-sha256 "$manifest_sha" --expected-fingerprint "$public_fingerprint" >/dev/null ||
  die "the completed transfer bundle did not pass its integrity and package checks."

mv -T -- "$transfer_tmp" "$output_dir"
transfer_tmp=
printf 'Transfer bundle: %s\n' "$output_dir"
printf 'Manifest SHA-256: %s\n' "$manifest_sha"
printf 'Repository database SHA-256: %s\n' "$(sha256sum "$output_dir/payload/gooarchy.db" | awk '{print $1}')"
printf 'Packages in complete database: %s\n' "${#chosen_file[@]}"
