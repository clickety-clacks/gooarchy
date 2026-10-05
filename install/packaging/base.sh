# Arch packages Gooarchy is made of (install/gooarchy-base.packages), installed as dependencies
# of the gooarchy package (installed last), so removing gooarchy can take them along. Packages
# already installed keep their install reason. git and base-devel build Scottland and Strata and
# stay installed as the user's own.
source "$GOOARCHY_INSTALL/helpers/packages.sh"
upgrade=(sudo pacman -Syu --noconfirm --needed)
if pacman -Q scottland >/dev/null 2>&1; then
  # The installed Scottland depends on the exact Wayfire it was built for. If Arch has a newer
  # Wayfire, let this upgrade through: the next step rebuilds Scottland for it.
  upgrade+=(--nodeps)
  echo "Scottland is installed ($(pacman -Q scottland | awk '{print $2}')); upgrading Arch, then rebuilding it."
fi
"${upgrade[@]}" git base-devel
mapfile -t packages < <(package_list "$GOOARCHY_INSTALL/gooarchy-base.packages")
sudo pacman -S --noconfirm --needed --asdeps "${packages[@]}"
