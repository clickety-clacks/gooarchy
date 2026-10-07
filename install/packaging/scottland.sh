# Scottland, built from its repository with its own PKGBUILD into the scottland package (D1: the
# desktop's files come from a package), and scottland-sunlight, its standalone day/night theme
# package (Mike dr_0e88648d, docs/rulings.md): same pkgbase, same build, installed by default.
# Its PKGBUILD also builds scottland-omarchy, the Omarchy adapter; Gooarchy doesn't install that.
#
# Scottland's PKGBUILD has a fixed version (0.1.0-1), and its plugin is built against one Wayfire
# ABI. So the build copy gets a version that names what was built: the Scottland revision and the
# Wayfire it was compiled for (e.g. 0.1.0.r441.gf325ab1.wf0.11.0), and a dependency on exactly that
# Wayfire version. A rebuild is always installed (not --needed), and when Arch moves Wayfire on,
# pacman -Syu stops with "wayfire=... required by scottland" instead of breaking the session; running
# ./install.sh again rebuilds Scottland for the new Wayfire (see install/packaging/base.sh).
source "$GOOARCHY_INSTALL/helpers/packages.sh"
source "$GOOARCHY_INSTALL/sources.conf"
src=$GOOARCHY_BUILD/scottland
checkout_source "$GOOARCHY_SCOTTLAND_REPO" "$GOOARCHY_SCOTTLAND_REF" "$src"

rev=$(git -C "$src" rev-parse HEAD)
count=$(git -C "$src" rev-list --count HEAD)
wayfire=$(pacman -Q wayfire | awk '{print $2}')
wayfire=${wayfire#*:}
wayfire=${wayfire%-*}
pkgbuild=$src/packaging/arch/PKGBUILD
upstream=$(sed -n 's/^pkgver=//p' "$pkgbuild")
version="$upstream.r$count.g${rev:0:7}.wf$wayfire"
sed -i -e "s/^pkgver=.*/pkgver=$version/" \
       -e "s/^\(  depends=('wayfire'\) /  depends=('wayfire=$wayfire' /" "$pkgbuild"
grep -q "^pkgver=$version\$" "$pkgbuild" && grep -q "depends=('wayfire=$wayfire'" "$pkgbuild" || {
  echo "Scottland's PKGBUILD has changed shape; can't set the build identity" >&2
  exit 1
}
echo "Scottland ${rev:0:12} ($(git -C "$src" log -1 --format=%s)) for Wayfire $wayfire: scottland $version"

build_package "$src/packaging/arch"
mapfile -t files < <(built_files "$src/packaging/arch" scottland scottland-sunlight)
install_built --asdeps "${files[@]}"
record_build scottland "$GOOARCHY_SCOTTLAND_REPO" "$rev" "$version"
record_build scottland-sunlight "$GOOARCHY_SCOTTLAND_REPO" "$rev" "$version"
