# xdg-desktop-portal-wlr, the screen-sharing and screenshot backend Scottland selects
# (scottland-portals.conf), as Gooarchy's build from our own fork
# (packaging/arch/xdg-desktop-portal-wlr, docs/xdg-desktop-portal-wlr.md). Arch's own 0.8.4 loses
# most shared streams under Wayfire.
#
# The base repository upgrade runs first and may install Scottland, pulling Arch's
# xdg-desktop-portal-wlr as a dependency. Replace that package with this Gooarchy build before the
# later Scottland source build and user/session setup. The replacement is printed here and in the
# install log. Arch's package doesn't declare that it replaces this one, so later pacman -Syu runs
# leave Gooarchy's build in place.
# Once Gooarchy has a package repository, install the package from it instead of building it here.
source "$GOOARCHY_INSTALL/helpers/packages.sh"
name=xdg-desktop-portal-wlr-gooarchy
dir=$GOOARCHY_BUILD/$name
rm -rf "$dir"
mkdir -p "$dir"
cp "$GOOARCHY_PATH/packaging/arch/xdg-desktop-portal-wlr/"* "$dir/"
build_package "$dir"
mapfile -t files < <(built_files "$dir" "$name")

# Exact names: pacman -Q also answers for a package that only provides the name.
installed() { pacman -Qq | grep -qx "$1"; }
if installed xdg-desktop-portal-wlr; then
  echo "Replacing $(pacman -Q xdg-desktop-portal-wlr) (Arch's) with Gooarchy's build from its fork" \
       "$(basename "${files[0]}"): Arch's loses shared screens under Wayfire."
fi
# --ask=4 answers pacman's "remove the conflicting package?" with yes, so the swap is one
# transaction (the hidden --ask option is pacman's own, used for unattended conflict resolution).
sudo pacman -U --noconfirm --ask=4 --asdeps "${files[@]}"
installed "$name" && ! installed xdg-desktop-portal-wlr || {
  echo "xdg-desktop-portal-wlr: Gooarchy's build is not the one installed" >&2
  exit 1
}
record_build "$name" "$GOOARCHY_PATH" "$(git -C "$GOOARCHY_PATH" rev-parse HEAD 2>/dev/null || echo unknown)" \
  "$(pacman -Q "$name" | awk '{print $2}')"
