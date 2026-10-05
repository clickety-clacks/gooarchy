# Arch packages Gooarchy is made of (install/gooarchy-base.packages), installed as dependencies
# of the gooarchy package (installed last), so removing gooarchy can take them along. Packages
# already installed keep their install reason. git and base-devel build Scottland and Strata and
# stay installed as the user's own.
source "$GOOARCHY_INSTALL/helpers/packages.sh"
sudo pacman -Syu --noconfirm --needed git base-devel
mapfile -t packages < <(package_list "$GOOARCHY_INSTALL/gooarchy-base.packages")
sudo pacman -S --noconfirm --needed --asdeps "${packages[@]}"
