# Scottland's fixed release-branch selector and explicit source overrides build locally. Otherwise
# the repository package is selected in base.sh's system-upgrade transaction so its exact Wayfire
# dependency stays atomic with Arch's update.
source "$GOOARCHY_INSTALL/helpers/packages.sh"
source "$GOOARCHY_INSTALL/helpers/repository.sh"
source "$GOOARCHY_INSTALL/helpers/logging.sh"
source "$GOOARCHY_INSTALL/sources.conf"
load_repository_plan

if ((GOOARCHY_BUILD_LOCAL_SCOTTLAND)); then
  src=$GOOARCHY_BUILD/scottland
  checkout_source "$GOOARCHY_SCOTTLAND_REPO" "$GOOARCHY_SCOTTLAND_REF" "$src" \
    "$GOOARCHY_SCOTTLAND_SOURCE_KIND"

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
  if [[ -z ${GOOARCHY_SCOTTLAND_REF_KIND:-} ]]; then
    report "Building Scottland locally from the fixed release branch pin $GOOARCHY_SCOTTLAND_REF; the repository copy is skipped. Replace this with a final Scottland tag before the distro tag."
  else
    report "Building Scottland locally from $GOOARCHY_SCOTTLAND_SOURCE_KIND pin $GOOARCHY_SCOTTLAND_REF because GOOARCHY_SCOTTLAND_REF is overridden; the repository copy is skipped. To return, unset GOOARCHY_SCOTTLAND_REF and rerun install.sh."
  fi
  echo "Scottland ${rev:0:12} ($(git -C "$src" log -1 --format=%s)) for Wayfire $wayfire: scottland $version"

  build_package "$src/packaging/arch"
  mapfile -t files < <(built_files "$src/packaging/arch" scottland)
  install_built --asdeps "${files[@]}"
  record_build scottland "$GOOARCHY_SCOTTLAND_REPO" "$rev" "$version" \
    "$GOOARCHY_SCOTTLAND_SOURCE_KIND" "$GOOARCHY_SCOTTLAND_REF"
else
  package_is_repository_copy scottland || {
    echo "Gooarchy's scottland package was not installed as a signed repository copy." >&2
    exit 1
  }
  sudo pacman -D --asdeps scottland
  forget_build scottland
  echo "Scottland $(pacman -Q scottland | awk '{print $2}') from the Gooarchy repository."
fi
