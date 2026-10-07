# Arch packages Gooarchy is made of (install/gooarchy-base.packages), installed as dependencies
# of the gooarchy package (installed last), so removing gooarchy can take them along. Packages
# already installed keep their install reason. git and base-devel build Strata and, when its pin is
# overridden, Scottland; they stay installed as the user's own.
source "$GOOARCHY_INSTALL/helpers/packages.sh"
source "$GOOARCHY_INSTALL/helpers/repository.sh"
load_repository_plan
upgrade=(sudo pacman -Syu --noconfirm)
if ((GOOARCHY_REPLACE_SCOTTLAND == 0)); then upgrade+=(--needed); fi
if pacman -Q scottland >/dev/null 2>&1; then
  if ((GOOARCHY_BUILD_LOCAL_SCOTTLAND)); then
    # An explicit pin override opts into a local rebuild after the Arch upgrade.
    upgrade+=(--nodeps)
    echo "Scottland is installed ($(pacman -Q scottland | awk '{print $2}')); the pin is overridden, so Arch upgrades before the local rebuild."
  else
    echo "Scottland is installed ($(pacman -Q scottland | awk '{print $2}')); upgrading it with Arch in one pacman transaction."
  fi
fi
packages=(git base-devel)
if [[ -n $GOOARCHY_SCOTTLAND_TARGET ]]; then packages+=("$GOOARCHY_SCOTTLAND_TARGET"); fi
"${upgrade[@]}" "${packages[@]}"
if [[ -n $GOOARCHY_SCOTTLAND_TARGET ]]; then sudo pacman -D --asdeps scottland; fi
mapfile -t packages < <(package_list "$GOOARCHY_INSTALL/gooarchy-base.packages")
sudo pacman -S --noconfirm --needed --asdeps "${packages[@]}"
