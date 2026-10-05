# Strata, the file manager, from its AUR package (strata-bin: Strata's release build).
source "$GOOARCHY_INSTALL/helpers/packages.sh"
source "$GOOARCHY_INSTALL/sources.conf"
src=$GOOARCHY_BUILD/strata-bin
if [[ -d $src/.git ]]; then
  git -C "$src" fetch --quiet origin
else
  rm -rf "$src"
  git clone --quiet "$GOOARCHY_STRATA_AUR" "$src"
fi
git -C "$src" -c advice.detachedHead=false checkout --quiet --force "$GOOARCHY_STRATA_REF"
git -C "$src" clean -qfdx
echo "strata-bin $(sed -n 's/^pkgver=//p' "$src/PKGBUILD") (AUR $(git -C "$src" rev-parse --short HEAD))"
build_package "$src"
install_built --asdeps "$src"/strata-bin-*.pkg.tar.zst
