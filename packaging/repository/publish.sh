#!/usr/bin/env bash
# Build and publish a Gooarchy pacman repository snapshot as one GitHub Release.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || {
  echo "publish: run this command from a clean Gooarchy checkout on main" >&2
  exit 1
}
die() { echo "publish: $*" >&2; exit 1; }

checkout_branch=$(git -C "$repo_root" branch --show-current)
[[ $checkout_branch == main ]] || die "publish from Gooarchy main, not $checkout_branch."
[[ -z $(git -C "$repo_root" status --porcelain) ]] || die "the Gooarchy main checkout has uncommitted changes."
checkout_commit=$(git -C "$repo_root" rev-parse HEAD)

[[ $(uname -m) == x86_64 ]] || die "the publisher requires an x86_64 build machine."
[[ -r /etc/os-release ]] || die "cannot identify the build operating system."
source /etc/os-release
[[ ${ID:-} == arch ]] || die "the publisher requires Arch Linux (ID=arch)."

for command_name in bsdtar df gpg gh git jq makepkg op pacman python3 repo-add sha256sum sort vercmp; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name."
done

usage() {
  cat >&2 <<'USAGE'
Usage: packaging/repository/publish.sh --all
       packaging/repository/publish.sh <package> [<package> ...]

Run from a clean Gooarchy main checkout on the x86_64 Arch build machine.
USAGE
  exit 2
}

all_packages=0
requested_packages=()
if (($# == 1)) && [[ $1 == --all ]]; then
  all_packages=1
elif (($# > 0)); then
  requested_packages=("$@")
else
  usage
fi

# Recipes under these roots are discovered from their PKGBUILD metadata, so a new recipe can be
# published without changing a client URL, key, or repository configuration.
recipe_roots=()
for candidate_root in "$repo_root/packaging/arch" "$repo_root/packaging/gooarchy-flavorings" \
  "$repo_root/packaging/linux-gooarchy"; do
  [[ -d $candidate_root ]] && recipe_roots+=("$candidate_root")
done
((${#recipe_roots[@]} > 0)) || die "no Gooarchy package recipe directories were found."

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

# Scottland is built from its pinned source repository; its recipe is carried by that pin.
if [[ ! ${recipe_for[scottland]+present} ]]; then
  recipe_for[scottland]=@scottland
fi

if ((all_packages)); then
  mapfile -t requested_packages < <(printf '%s\n' "${!recipe_for[@]}" | sort -u)
fi

declare -A selected=()
for package_name in "${requested_packages[@]}"; do
  [[ ${recipe_for[$package_name]+present} ]] || die "no package recipe is available for $package_name."
  [[ ! ${selected[$package_name]+present} ]] || die "package requested more than once: $package_name."
  selected[$package_name]=1
done

required_initial=(gooarchy gooarchy-flavorings scottland xdg-desktop-portal-wlr-gooarchy \
  linux-gooarchy linux-gooarchy-headers)

read_db="$script_dir/read-db.py"
fingerprint_file="$repo_root/packaging/keys/gooarchy.fingerprint"
public_key_file="$repo_root/packaging/keys/gooarchy.asc"
[[ -s $fingerprint_file ]] || die "the committed signing fingerprint is missing; publication is not configured yet."
[[ -s $public_key_file ]] || die "the committed public signing key is missing; publication is not configured yet."
if grep -q '^Placeholder:' "$fingerprint_file" "$public_key_file"; then
  die "the committed Gooarchy key is still a placeholder; wait for the approved key setup."
fi
public_fingerprint=$(awk '/^[[:space:]]*($|#)/ { next } { gsub(/[[:space:]]/, ""); print toupper($0); exit }' "$fingerprint_file")
[[ $public_fingerprint =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]] ||
  die "packaging/keys/gooarchy.fingerprint must contain one OpenPGP fingerprint."
actual_public_fingerprint=$(gpg --batch --show-keys --with-colons --with-fingerprint \
  "$public_key_file" 2>/dev/null | awk -F: '$1 == "fpr" { print toupper($10); exit }') ||
  die "the committed public signing key could not be read."
[[ $actual_public_fingerprint == "$public_fingerprint" ]] ||
  die "the committed public key fingerprint does not match packaging/keys/gooarchy.fingerprint."

release_repo_slug=${GOOARCHY_RELEASE_REPOSITORY:-clickety-clacks/gooarchy}
release_list=$(gh release list --repo "$release_repo_slug" --limit 1000 --exclude-drafts \
  --exclude-pre-releases --json tagName,isLatest) || die "could not read GitHub Releases for $release_repo_slug."
latest_tag=$(jq -r '[.[] | select(.isLatest == true)][0].tagName // ""' <<<"$release_list")

work_parent=${GOOARCHY_PUBLISH_TMPDIR:-${TMPDIR:-/tmp}}
mkdir -p -- "$work_parent"
work_dir=$(mktemp -d "$work_parent/gooarchy-publish.XXXXXX") || die "could not create a private publish workspace."
chmod 700 "$work_dir"
trap 'rm -rf -- "$work_dir"' EXIT
mkdir -m 700 "$work_dir/assets" "$work_dir/built" "$work_dir/sources" \
  "$work_dir/build" "$work_dir/gnupg"
gpg --homedir "$work_dir/gnupg" --batch --import "$public_key_file" >/dev/null 2>&1 ||
  die "could not load the committed Gooarchy public key into the private publish workspace."

makepkg_config="$work_dir/makepkg.conf"
{
  printf 'source /etc/makepkg.conf\n'
  printf 'PKGDEST=%q\n' "$work_dir/built"
  printf 'SRCDEST=%q\n' "$work_dir/sources"
  printf 'BUILDDIR=%q\n' "$work_dir/build"
  printf 'PACKAGER=%q\n' 'Gooarchy'
  printf 'SIGNPKG=%q\n' 'no'
} >"$makepkg_config"
export MAKEPKG_CONF=$makepkg_config

previous_dir="$work_dir/previous"
mkdir -m 700 "$previous_dir"
declare -A old_version=() old_filename=() release_assets=()
if [[ -n $latest_tag ]]; then
  gh release download "$latest_tag" --repo "$release_repo_slug" --dir "$previous_dir" ||
    die "could not download assets from the current latest release."
  previous_database="$previous_dir/gooarchy.db"
  [[ -s $previous_database ]] || die "the latest release has no gooarchy.db database asset."
  [[ -s $previous_database.sig ]] || die "the latest release has no signature for gooarchy.db."
  gpg --homedir "$work_dir/gnupg" --batch --verify "$previous_database.sig" \
    "$previous_database" >/dev/null 2>&1 ||
    die "the latest repository database signature is invalid."
  previous_records=$(python3 "$read_db" "$previous_database") ||
    die "could not read the current Gooarchy package database."
  while IFS=$'\t' read -r old_name old_ver old_file; do
    [[ -n $old_name ]] || continue
    [[ $old_file != */* && $old_file =~ ^[A-Za-z0-9._+:-]+$ && $old_file != .* && $old_file != *. ]] ||
      die "the current repository database contains an unsafe package filename."
    [[ -s $previous_dir/$old_file ]] || die "the latest release is missing $old_file listed in its database."
    [[ -s $previous_dir/$old_file.sig ]] || die "the latest release is missing the signature for $old_file."
    old_version[$old_name]=$old_ver
    old_filename[$old_name]=$old_file
    cp -- "$previous_dir/$old_file" "$work_dir/assets/$old_file"
    cp -- "$previous_dir/$old_file.sig" "$work_dir/assets/$old_file.sig"
    release_assets[$old_file]=$work_dir/assets/$old_file
    release_assets[$old_file.sig]=$work_dir/assets/$old_file.sig
  done <<<"$previous_records"
  cp -- "$previous_database" "$work_dir/gooarchy.db.tar.gz"
  cp -- "$previous_database.sig" "$work_dir/gooarchy.db.tar.gz.sig"
else
  for required_name in "${required_initial[@]}"; do
    [[ ${selected[$required_name]+present} ]] ||
      die "the first repository publish must include all six rev 5 packages; missing $required_name."
  done
fi

source "$repo_root/install/sources.conf"
scottland_repo=${GOOARCHY_SCOTTLAND_REPO:-https://github.com/clickety-clacks/scottland.git}
scottland_ref=${GOOARCHY_SCOTTLAND_REF:-}
[[ -n $scottland_ref ]] || die "install/sources.conf has no pinned Scottland revision."

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
      PACKAGER=Gooarchy makepkg --syncdeps --rmdeps --noconfirm --needed --force --cleanbuild
  ) || die "makepkg failed for $recipe_file."
}

build_scottland() {
  local source_dir="$work_dir/scottland-source" build_dir="$work_dir/scottland-recipe"
  git clone --quiet "$scottland_repo" "$source_dir" || die "could not fetch the pinned Scottland source."
  git -C "$source_dir" -c advice.detachedHead=false checkout --quiet --force "$scottland_ref" ||
    die "could not check out the requested Scottland revision."
  git -C "$source_dir" clean -qfdx
  scottland_source_revision=$(git -C "$source_dir" rev-parse HEAD)
  mkdir -m 700 "$build_dir"
  cp -a -- "$source_dir/packaging/arch/." "$build_dir/"
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
    die "Scottland's PKGBUILD changed shape; refusing to publish without the exact wayfire dependency."
  (
    cd -- "$build_dir"
    PACKAGER=Gooarchy makepkg --syncdeps --rmdeps --noconfirm --needed --force --cleanbuild
  ) || die "makepkg failed for the pinned Scottland recipe."
}

declare -A recipe_built=() package_archive=() package_version=() source_revision=()
for package_name in "${requested_packages[@]}"; do
  recipe_file=${recipe_for[$package_name]}
  if [[ $recipe_file == @scottland ]]; then
    [[ ${recipe_built[scottland]+present} ]] || build_scottland
    recipe_built[scottland]=1
    source_revision[$package_name]=$scottland_source_revision
  else
    if [[ ! ${recipe_built[$recipe_file]+present} ]]; then
      recipe_dir=$(dirname -- "$recipe_file")
      if [[ $recipe_dir == "$repo_root/packaging/linux-gooarchy" && -x $recipe_dir/build.sh ]]; then
        free_kb=$(df -Pk "$work_dir" | awk 'END { print $4 }')
        ((free_kb >= 35 * 1024 * 1024)) || die "linux-gooarchy needs at least 35 GiB free in the publish workspace."
        GOOARCHY_KERNEL_BUILD="$work_dir/kernel" PACKAGER=Gooarchy \
          "$recipe_dir/build.sh" || die "the pinned Gooarchy kernel build failed."
      else
        build_static_recipe "$recipe_file"
      fi
      recipe_built[$recipe_file]=1
    fi
      case $package_name in
      gooarchy-flavorings)
        if [[ $recipe_file == "$repo_root/packaging/gooarchy-flavorings/PKGBUILD" ]]; then
          flavorings_source_revision=$(sed -n 's/^_commit=//p' "$recipe_file" | sed -n '1p')
          [[ $flavorings_source_revision =~ ^[[:xdigit:]]{40}$ ]] ||
            die "the flavorings recipe has no full pinned source commit."
          source_revision[$package_name]="Gooarchy $checkout_commit; gooarchy-flavorings $flavorings_source_revision"
        else
          source_revision[$package_name]="Gooarchy $checkout_commit; Scottland themes $scottland_ref"
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
  fi
done

for package_path in "$work_dir/built"/*.pkg.tar.* "$work_dir/kernel"/*.pkg.tar.*; do
  [[ -f $package_path ]] || continue
  pkginfo=$(bsdtar -xOf "$package_path" .PKGINFO 2>/dev/null) ||
    die "cannot read package metadata from $(basename -- "$package_path")."
  package_name=$(awk -F ' = ' '$1 == "pkgname" { print $2; exit }' <<<"$pkginfo")
  [[ ${selected[$package_name]+present} ]] || continue
  [[ ! ${package_archive[$package_name]+present} ]] || die "more than one archive was built for $package_name."
  [[ $(awk -F ' = ' '$1 == "packager" { print $2; exit }' <<<"$pkginfo") == Gooarchy ]] ||
    die "$package_name does not carry the Gooarchy packager identity."
  package_arch=$(awk -F ' = ' '$1 == "arch" { print $2; exit }' <<<"$pkginfo")
  [[ $package_arch == any || $package_arch == x86_64 ]] || die "$package_name has unsupported architecture $package_arch."
  package_archive[$package_name]=$package_path
  package_version[$package_name]=$(pacman -Qp --print-format '%v' "$package_path") ||
    die "pacman could not read the version of $package_name."
done

for package_name in "${requested_packages[@]}"; do
  [[ ${package_archive[$package_name]+present} ]] || die "the selected recipe did not produce $package_name."
done

accepted_packages=()
refused_packages=()
declare -A refused=()
for package_name in "${requested_packages[@]}"; do
  previous_version=${old_version[$package_name]:-none}
  if [[ $previous_version != none ]]; then
    comparison=$(vercmp "${package_version[$package_name]}" "$previous_version") ||
      die "vercmp failed for $package_name."
    if ((comparison <= 0)); then
      echo "Refused $package_name: new version ${package_version[$package_name]} is not newer than published version $previous_version; source revision: ${source_revision[$package_name]:-Gooarchy $checkout_commit}; this package remains unchanged."
      refused_packages+=("$package_name")
      refused[$package_name]=1
      continue
    fi
  fi
  accepted_packages+=("$package_name")
done
((${#accepted_packages[@]} > 0)) || die "no package version is newer; no release was created."

key_reference=${GOOARCHY_SIGNING_KEY_REF:-}
[[ $key_reference == op://* ]] || die "GOOARCHY_SIGNING_KEY_REF must point to the approved 1Password signing-key item."
if ! op read "$key_reference" 2>/dev/null | \
  gpg --homedir "$work_dir/gnupg" --batch --import >/dev/null 2>&1; then
  die "1Password did not provide the configured Gooarchy signing key."
fi
secret_fingerprint=$(gpg --homedir "$work_dir/gnupg" --batch --with-colons \
  --list-secret-keys --with-fingerprint | awk -F: '$1 == "fpr" { print toupper($10); exit }')
[[ $secret_fingerprint == "$public_fingerprint" ]] ||
  die "the 1Password signing key does not match the committed Gooarchy fingerprint."
export GNUPGHOME="$work_dir/gnupg"

add_release_asset() {
  local source_path=$1 asset_name
  asset_name=$(basename -- "$source_path")
  [[ $asset_name =~ ^[A-Za-z0-9._+:-]+$ && $asset_name != .* && $asset_name != *. ]] ||
    die "asset filename cannot be used unchanged in GitHub Releases: $asset_name."
  if [[ ${release_assets[$asset_name]+present} ]]; then
    cmp -s -- "$source_path" "$work_dir/assets/$asset_name" || die "conflicting release assets are named $asset_name."
    return
  fi
  cp -- "$source_path" "$work_dir/assets/$asset_name"
  release_assets[$asset_name]=$work_dir/assets/$asset_name
}

new_package_paths=()
for package_name in "${accepted_packages[@]}"; do
  package_path=${package_archive[$package_name]}
  package_basename=$(basename -- "$package_path")
  [[ $package_basename =~ ^[A-Za-z0-9._+:-]+$ && $package_basename != .* && $package_basename != *. ]] ||
    die "package filename cannot be used unchanged in GitHub Releases: $package_basename."
  gpg --homedir "$work_dir/gnupg" --batch --yes --local-user "$public_fingerprint" \
    --detach-sign --output "$package_path.sig" "$package_path" || die "could not sign $package_basename."
  add_release_asset "$package_path"
  add_release_asset "$package_path.sig"
  new_package_paths+=("$package_path")
done

database_archive="$work_dir/gooarchy.db.tar.gz"
repo_add_arguments=(--sign --key "$public_fingerprint" --include-sigs)
if [[ -n $latest_tag ]]; then
  repo_add_arguments+=(--verify)
fi
repo-add "${repo_add_arguments[@]}" "$database_archive" "${new_package_paths[@]}" ||
  die "repo-add could not create the next Gooarchy database."

database_asset="$work_dir/assets/gooarchy.db"
database_signature_asset="$work_dir/assets/gooarchy.db.sig"
cp -- "$database_archive" "$database_asset"
cp -- "$database_archive.sig" "$database_signature_asset"

declare -A new_version=()
while IFS=$'\t' read -r db_name db_version db_filename; do
  [[ -n $db_name ]] || continue
  [[ $db_filename != */* && $db_filename =~ ^[A-Za-z0-9._+:-]+$ && $db_filename != .* && $db_filename != *. ]] ||
    die "repo-add produced an unsafe package filename for $db_name."
  [[ -s $work_dir/assets/$db_filename && -s $work_dir/assets/$db_filename.sig ]] ||
    die "the next database lists $db_filename without both its package and detached signature."
  new_version[$db_name]=$db_version
done < <(python3 "$read_db" "$database_archive")

for old_name in "${!old_version[@]}"; do
  [[ ${new_version[$old_name]+present} ]] || die "the next database would remove previously published package $old_name."
  if [[ ${refused[$old_name]+present} || ! ${selected[$old_name]+present} ]]; then
    [[ ${new_version[$old_name]} == "${old_version[$old_name]}" ]] ||
      die "an unchanged $old_name package changed in the next database."
  fi
done
if [[ -z $latest_tag ]]; then
  for required_name in "${required_initial[@]}"; do
    [[ ${new_version[$required_name]+present} ]] || die "the first database does not contain required package $required_name."
  done
fi

asset_names=()
for asset_name in "${!release_assets[@]}"; do
  asset_names+=("$asset_name")
done
mapfile -t asset_names < <(printf '%s\n' "${asset_names[@]}" | sort)
asset_paths=()
for asset_name in "${asset_names[@]}"; do
  asset_paths+=("${release_assets[$asset_name]}")
done
# The new database and its signature are last in the draft's ordered upload list.
asset_paths+=("$database_signature_asset" "$database_asset")
asset_names+=(gooarchy.db.sig gooarchy.db)

release_nonce=${work_dir##*.}
release_tag="gooarchy-repo-${checkout_commit:0:12}-$(date -u +%Y%m%dT%H%M%SZ)-$release_nonce"
gh release create "$release_tag" "${asset_paths[@]}" --repo "$release_repo_slug" \
  --target "$checkout_commit" --draft --latest=false \
  --title "Gooarchy package repository $release_tag" \
  --notes "Repository snapshot built from Gooarchy main $checkout_commit." ||
  die "GitHub could not create the unpublished repository snapshot draft."

actual_asset_names=$(gh release view "$release_tag" --repo "$release_repo_slug" --json assets \
  --jq '.assets[].name' | sort) || die "could not verify the assets in the unpublished release draft."
expected_asset_names=$(printf '%s\n' "${asset_names[@]}" | sort)
if [[ $actual_asset_names != "$expected_asset_names" ]]; then
  die "GitHub changed a release asset filename; draft $release_tag remains unpublished because A3 requires exact package filenames."
fi

gh release edit "$release_tag" --repo "$release_repo_slug" --draft=false --latest ||
  die "the complete release draft could not be marked latest; the previous repository remains the supported address."

for package_name in "${accepted_packages[@]}"; do
  previous_version=${old_version[$package_name]:-none}
  printf 'Published %s version %s (replaced %s); source revision: %s.\n' \
    "$package_name" "${package_version[$package_name]}" "$previous_version" \
    "${source_revision[$package_name]:-Gooarchy $checkout_commit}"
done
printf 'Published release %s as latest.\n' "$release_tag"
