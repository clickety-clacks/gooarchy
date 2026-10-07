# Gooarchy's own packages: gooarchy (the session and the distro's commands; depends on everything
# above), built from this checkout, and gooarchy-flavorings (the curated defaults), built from the
# gooarchy-flavorings repository at the commit pinned in packaging/gooarchy-flavorings/PKGBUILD.
# The gooarchy build is a local one: its PKGBUILD reads this checkout (GOOARCHY_PATH) directly, and
# records the checkout's revision (and whether it had uncommitted changes) in
# /usr/share/gooarchy/build-info. Both are installed together, since each needs the other's version.
source "$GOOARCHY_INSTALL/helpers/packages.sh"
flavorings=$GOOARCHY_BUILD/gooarchy-flavorings
dir=$GOOARCHY_BUILD/gooarchy-packaging
rm -rf "$flavorings" "$dir"
mkdir -p "$flavorings" "$dir"
cp "$GOOARCHY_PATH/packaging/gooarchy-flavorings/PKGBUILD" "$flavorings/"
cp "$GOOARCHY_PATH/packaging/arch/PKGBUILD" "$dir/"
build_package "$flavorings"
GOOARCHY_PATH=$GOOARCHY_PATH build_package "$dir"
mapfile -t files < <(built_files "$flavorings" gooarchy-flavorings; built_files "$dir" gooarchy)
install_built "${files[@]}"
record_build gooarchy-flavorings "$(sed -n 's/^url="\(.*\)"$/\1/p' "$flavorings/PKGBUILD")" \
  "$(sed -n 's/^_commit=//p' "$flavorings/PKGBUILD")" "$(pacman -Q gooarchy-flavorings | awk '{print $2}')"
record_build gooarchy "$GOOARCHY_PATH" "$(git -C "$GOOARCHY_PATH" rev-parse HEAD 2>/dev/null || echo unknown)" \
  "$(pacman -Q gooarchy | awk '{print $2}')"
