# Strata, the file manager, from its AUR package (strata-bin: Strata's release build).
source "$GOOARCHY_INSTALL/helpers/packages.sh"
source "$GOOARCHY_INSTALL/sources.conf"
src=$GOOARCHY_BUILD/strata-bin
checkout_source "$GOOARCHY_STRATA_AUR" "$GOOARCHY_STRATA_REF" "$src"
rev=$(git -C "$src" rev-parse HEAD)
echo "strata-bin $(sed -n 's/^pkgver=//p' "$src/PKGBUILD") (AUR ${rev:0:12})"
build_package "$src"
# Exactly strata-bin: makepkg may also produce strata-bin-debug, which nothing needs.
mapfile -t files < <(built_files "$src" strata-bin)
install_built --asdeps "${files[@]}"
record_build strata-bin "$GOOARCHY_STRATA_AUR" "$rev" "$(pacman -Q strata-bin | awk '{print $2}')"
