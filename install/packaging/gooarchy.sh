# Gooarchy's own packages, built from this checkout: gooarchy (the session and the distro's
# commands; depends on everything above) and gooarchy-flavorings (the curated defaults).
# A local build: the PKGBUILD reads this checkout (GOOARCHY_PATH) directly, and records the
# checkout's revision (and whether it had uncommitted changes) in /usr/share/gooarchy/build-info.
source "$GOOARCHY_INSTALL/helpers/packages.sh"
dir=$GOOARCHY_BUILD/gooarchy-packaging
rm -rf "$dir"
mkdir -p "$dir"
cp "$GOOARCHY_PATH/packaging/arch/PKGBUILD" "$dir/"
GOOARCHY_PATH=$GOOARCHY_PATH build_package "$dir"
mapfile -t files < <(built_files "$dir" gooarchy gooarchy-flavorings)
install_built "${files[@]}"
record_build gooarchy "$GOOARCHY_PATH" "$(git -C "$GOOARCHY_PATH" rev-parse HEAD 2>/dev/null || echo unknown)" \
  "$(pacman -Q gooarchy | awk '{print $2}')"
