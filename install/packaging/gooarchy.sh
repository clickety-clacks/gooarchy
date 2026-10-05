# Gooarchy's own packages, built from this checkout: gooarchy (the session and the distro's
# commands; depends on everything above) and gooarchy-flavorings (the curated defaults).
source "$GOOARCHY_INSTALL/helpers/packages.sh"
dir=$GOOARCHY_BUILD/gooarchy-packaging
rm -rf "$dir"
mkdir -p "$dir"
cp "$GOOARCHY_PATH/packaging/arch/PKGBUILD" "$dir/"
# The PKGBUILD reads this checkout (sources, flavorings, package list) through GOOARCHY_PATH.
GOOARCHY_PATH=$GOOARCHY_PATH build_package "$dir"
# Not --needed: a rebuild from a changed checkout keeps the version number of its commit.
sudo pacman -U --noconfirm "$dir"/gooarchy-*.pkg.tar.zst
