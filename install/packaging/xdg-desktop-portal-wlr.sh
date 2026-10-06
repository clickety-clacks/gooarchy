# xdg-desktop-portal-wlr, the screen-sharing and screenshot backend Scottland selects
# (scottland-portals.conf), as Gooarchy's patched build: packaging/arch/xdg-desktop-portal-wlr.
# Arch's own 0.8.4 loses most shared streams under Wayfire; the two patches are proposed upstream
# fixes, not yet in an upstream release (see that PKGBUILD).
#
# Built from this checkout and installed before Scottland, whose package depends on
# xdg-desktop-portal-wlr: this build provides it, so the dependency never pulls Arch's.
# If Arch's xdg-desktop-portal-wlr is already installed (an earlier install, or by hand), it is
# replaced in the same pacman transaction, and the replacement is printed here and in the install
# log. Arch's package doesn't declare that it replaces this one, so pacman -Syu leaves it in place.
# Retire this step and the package when an upstream release contains both fixes: drop them, and
# Arch's package takes over (docs/xdg-desktop-portal-wlr.md).
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
  echo "Replacing $(pacman -Q xdg-desktop-portal-wlr) (Arch's) with Gooarchy's patched build" \
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
