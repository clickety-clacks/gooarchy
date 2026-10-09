# Arch packages Gooarchy is made of (install/gooarchy-base.packages), installed as dependencies
# of the gooarchy package (installed last), so removing gooarchy can take them along. Packages
# already installed keep their install reason. git and base-devel build Strata and, when its pin is
# overridden, Scottland; they stay installed as the user's own.
source "$GOOARCHY_INSTALL/helpers/packages.sh"
source "$GOOARCHY_INSTALL/helpers/repository.sh"
source "$GOOARCHY_INSTALL/helpers/logging.sh"
load_repository_plan
if ((GOOARCHY_REPLACE_SCOTTLAND)); then
  repo_cache=$(mktemp -d "$GOOARCHY_BUILD/repository-package.XXXXXX")
  chmod 755 "$repo_cache"
  trap 'sudo rm -rf -- "$repo_cache"' EXIT
  download_repository_packages "$repo_cache" \
    "gooarchy/scottland=$GOOARCHY_REPOSITORY_SCOTTLAND_VERSION"
  sudo pacman -U --asdeps --noconfirm "${REPOSITORY_PACKAGE_ARCHIVES[@]}"
  sudo pacman -D --asdeps scottland
  recovery="restore the previous scottland package from the local pacman cache if available"
  if [[ $GOOARCHY_PREVIOUS_SCOTTLAND_REF_KIND == tag ||
    $GOOARCHY_PREVIOUS_SCOTTLAND_REF_KIND == branch ]] &&
    [[ $GOOARCHY_PREVIOUS_SCOTTLAND_REF =~ ^[A-Za-z0-9._/-]+$ ]]; then
    recovery="run GOOARCHY_SCOTTLAND_REF=$GOOARCHY_PREVIOUS_SCOTTLAND_REF GOOARCHY_SCOTTLAND_REF_KIND=$GOOARCHY_PREVIOUS_SCOTTLAND_REF_KIND ./install.sh"
  fi
  report "Replaced local scottland $GOOARCHY_PREVIOUS_SCOTTLAND_VERSION with Gooarchy repository scottland $(pacman -Q scottland | awk '{print $2}') because no source pin was overridden. To go back, $recovery."
  sudo rm -rf -- "$repo_cache"
  trap - EXIT
fi
upgrade=(sudo pacman -Syu --noconfirm --needed)
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
