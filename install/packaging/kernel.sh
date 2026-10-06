# Explicit opt-in only. Keep the existing kernel and all bootloader settings intact.
source "$GOOARCHY_INSTALL/helpers/packages.sh"
export GOOARCHY_KERNEL_BUILD=$GOOARCHY_BUILD/linux-gooarchy
"$GOOARCHY_PATH/packaging/linux-gooarchy/build.sh"
mapfile -t files < <(built_files "$GOOARCHY_KERNEL_BUILD" linux-gooarchy linux-gooarchy-headers)
(( ${#files[@]} == 2 )) || { echo "Gooarchy kernel packages are missing" >&2; exit 1; }
install_built "${files[@]}"
version=$(pacman -Q linux-gooarchy | awk '{print $2}')
revision=$(git -C "$GOOARCHY_PATH" rev-parse HEAD)
record_build linux-gooarchy https://github.com/clickety-clacks/gooarchy "$revision" "$version"
echo "Experimental linux-gooarchy $version is installed alongside the existing kernel."
echo "Bootloader configuration and its default are unchanged. Choose this kernel explicitly"
echo "using your bootloader; keep the existing kernel as your fallback. Hardware validation is pending."
