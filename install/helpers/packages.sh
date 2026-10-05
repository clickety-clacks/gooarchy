# Package helpers shared by the steps.

# Package names from a list file: one per line, # comments.
package_list() {
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"
}

# Build the package(s) in a PKGBUILD directory as this user, installing build dependencies for the
# build and removing them afterwards.
build_package() {
  local dir=$1
  (cd "$dir" && makepkg --syncdeps --rmdeps --noconfirm --needed --force --cleanbuild)
}

# The built file of each named package, as makepkg reports it (respects PKGDEST and PKGEXT).
# Only exact names: a split or debug package of the same recipe (e.g. scottland-omarchy,
# strata-bin-debug) is never picked up by accident.
built_files() {
  local dir=$1 name file base
  shift
  for name in "$@"; do
    file=
    while read -r candidate; do
      base=$(basename "$candidate")
      # <name>-<pkgver>-<pkgrel>-<arch>.pkg.tar.*: strip the last three dash-separated fields.
      [[ ${base%-*-*-*} == "$name" ]] && file=$candidate
    done < <(cd "$dir" && makepkg --packagelist)
    [[ -n $file && -f $file ]] || { echo "no built package $name in $dir" >&2; return 1; }
    echo "$file"
  done
}

# Install built package files. Not --needed: a rebuild (another source revision, or the same one
# against a newer Wayfire) must replace what's installed even when the version string is equal.
install_built() {
  sudo pacman -U --noconfirm "$@"
}

# A cached checkout of REPO at REF in DIR: re-cloned when the cache points somewhere else (an
# override of the repository URL), fetched otherwise, then checked out clean.
checkout_source() {
  local repo=$1 ref=$2 dir=$3
  if [[ -d $dir/.git && $(git -C "$dir" remote get-url origin 2>/dev/null) != "$repo" ]]; then
    echo "The cached checkout in $dir came from $(git -C "$dir" remote get-url origin); cloning $repo instead."
    rm -rf "$dir"
  fi
  if [[ -d $dir/.git ]]; then
    git -C "$dir" fetch --quiet origin
  else
    rm -rf "$dir"
    git clone --quiet "$repo" "$dir"
  fi
  git -C "$dir" -c advice.detachedHead=false checkout --quiet --force "$ref"
  git -C "$dir" clean -qfdx
}

# Record what was built and installed (name, source, revision, package version) in
# ~/.local/state/gooarchy/builds.tsv, one line per package, newest wins.
record_build() {
  local file=$GOOARCHY_STATE/builds.tsv
  touch "$file"
  { grep -v "^$1	" "$file" || true; printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(date -Iseconds)"; } >"$file.new"
  mv "$file.new" "$file"
}
