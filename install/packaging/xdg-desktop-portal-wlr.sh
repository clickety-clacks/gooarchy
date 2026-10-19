# xdg-desktop-portal-wlr, the screen-sharing and screenshot backend Scottland selects
# (scottland-portals.conf), is consumed from Gooarchy's signed package repository. The repository
# setup step already refreshed signed metadata and required this package to be available.
source "$GOOARCHY_INSTALL/helpers/repository.sh"
source "$GOOARCHY_INSTALL/helpers/packages.sh"
source "$GOOARCHY_INSTALL/helpers/logging.sh"
load_repository_plan

name=xdg-desktop-portal-wlr-gooarchy
arch_name=xdg-desktop-portal-wlr
repo_version=$(sync_package_field "$name" Version)
[[ -n $repo_version ]] || {
  echo "Gooarchy's signed repository has no version for $name." >&2
  exit 1
}

previous_gooarchy_installed=${GOOARCHY_PREVIOUS_PORTAL_INSTALLED:-0}
previous_gooarchy_repository_copy=${GOOARCHY_PREVIOUS_PORTAL_REPOSITORY_COPY:-0}
previous_gooarchy_version=${GOOARCHY_PREVIOUS_PORTAL_VERSION:-}
previous_arch_installed=${GOOARCHY_PREVIOUS_ARCH_PORTAL_INSTALLED:-0}
previous_arch_version=${GOOARCHY_PREVIOUS_ARCH_PORTAL_VERSION:-}
current_gooarchy_repository_copy=0
current_gooarchy_version=
current_arch_installed=0
current_arch_version=
if package_is_installed "$name"; then
  current_gooarchy_version=$(installed_package_version "$name")
  package_is_repository_copy "$name" && current_gooarchy_repository_copy=1
fi
if package_is_installed "$arch_name"; then
  current_arch_installed=1
  current_arch_version=$(installed_package_version "$arch_name")
fi

# An exact signed repository copy is already current. This makes ordinary install.sh reruns
# idempotent after pacman -Syu has applied any newer repository version.
if ((current_gooarchy_repository_copy)) &&
  [[ $current_gooarchy_version == "$repo_version" ]] && ((current_arch_installed == 0)); then
  forget_build "$name"
  if ((previous_arch_installed)); then
    recovery="run sudo pacman -S $arch_name to restore Arch's package (that will replace Gooarchy's provider)"
    report "Replaced Arch $arch_name $previous_arch_version with signed Gooarchy $name $current_gooarchy_version because Gooarchy's signed repository supplies the maintained Wayfire screen-sharing backend and lets pacman -Syu update it with Gooarchy. To go back, $recovery."
  elif ((previous_gooarchy_installed)) && ((previous_gooarchy_repository_copy == 0)); then
    recovery="reinstall the previous $name $previous_gooarchy_version archive from /var/cache/pacman/pkg if it is still available"
    report "Replaced local $name $previous_gooarchy_version with signed Gooarchy $name $current_gooarchy_version because Gooarchy's signed repository supplies the maintained Wayfire screen-sharing backend and lets pacman -Syu update it with Gooarchy. To go back, $recovery."
  elif ((previous_gooarchy_installed)) && [[ $previous_gooarchy_version != "$current_gooarchy_version" ]]; then
    recovery="reinstall the previous $name $previous_gooarchy_version archive from /var/cache/pacman/pkg if it is still available"
    report "Updated signed Gooarchy $name from $previous_gooarchy_version to $current_gooarchy_version through the repository upgrade. To go back, $recovery."
  else
    echo "$name $repo_version is already installed from Gooarchy's signed repository."
  fi
  exit 0
fi

mkdir -p "$GOOARCHY_BUILD"
repo_cache=$(mktemp -d /tmp/gooarchy-portal-package.XXXXXX)
chmod 755 "$repo_cache"
trap 'sudo rm -rf -- "$repo_cache"' EXIT
download_repository_packages "$repo_cache" "gooarchy/$name=$repo_version" || {
  echo "Gooarchy's signed repository package $name $repo_version could not be downloaded." >&2
  exit 1
}

# The archive was resolved from the signed Gooarchy repository and downloaded by pacman. Installing
# that exact archive also replaces Arch's conflicting package in the same transaction.
sudo pacman -U --noconfirm --ask=4 --asdeps "${REPOSITORY_PACKAGE_ARCHIVES[@]}"
sudo rm -rf -- "$repo_cache"
trap - EXIT

installed_version=$(installed_package_version "$name")
[[ $installed_version == "$repo_version" ]] && package_is_repository_copy "$name" || {
  echo "$name: the installed package is not the signed Gooarchy repository version $repo_version." >&2
  exit 1
}
if package_is_installed "$arch_name"; then
  echo "$arch_name: Arch's package remains installed beside Gooarchy's provider." >&2
  exit 1
fi

forget_build "$name"
reason="Gooarchy's signed repository supplies the maintained Wayfire screen-sharing backend and lets pacman -Syu update it with the rest of Gooarchy"
if ((previous_arch_installed || current_arch_installed)); then
  [[ -n $previous_arch_version ]] || previous_arch_version=$current_arch_version
  recovery="run sudo pacman -S $arch_name to restore Arch's package (that will replace Gooarchy's provider)"
  report "Replaced Arch $arch_name $previous_arch_version with signed Gooarchy $name $installed_version because $reason. To go back, $recovery."
elif ((previous_gooarchy_installed)); then
  recovery="reinstall the previous $name $previous_gooarchy_version archive from /var/cache/pacman/pkg if it is still available"
  case $previous_gooarchy_repository_copy in
    1) origin='Gooarchy repository' ;;
    0) origin='local package' ;;
  esac
  report "Replaced $origin $name $previous_gooarchy_version with signed Gooarchy $name $installed_version because $reason. To go back, $recovery."
else
  report "Installed signed Gooarchy $name $installed_version from the configured repository; $reason"
fi
