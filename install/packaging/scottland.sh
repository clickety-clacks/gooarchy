# Scottland, built from its repository with its own PKGBUILD into the scottland package (D1: the
# desktop's files come from a package). Its PKGBUILD also builds scottland-omarchy, the Omarchy
# adapter; Gooarchy doesn't install that.
source "$GOOARCHY_INSTALL/helpers/packages.sh"
source "$GOOARCHY_INSTALL/sources.conf"
src=$GOOARCHY_BUILD/scottland
if [[ -d $src/.git ]]; then
  git -C "$src" fetch --quiet origin
else
  rm -rf "$src"
  git clone --quiet "$GOOARCHY_SCOTTLAND_REPO" "$src"
fi
git -C "$src" -c advice.detachedHead=false checkout --quiet --force "$GOOARCHY_SCOTTLAND_REF"
git -C "$src" clean -qfdx
echo "Scottland $(git -C "$src" rev-parse --short HEAD): $(git -C "$src" log -1 --format=%s)"
build_package "$src/packaging/arch"
install_built --asdeps "$src"/packaging/arch/scottland-[0-9]*.pkg.tar.zst
