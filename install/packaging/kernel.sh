# Explicit opt-in only. The existing kernel stays installed and stays the default boot: linux-gooarchy
# becomes the default only after it passes the VM test and real hardware.
source "$GOOARCHY_INSTALL/helpers/logging.sh"  # report
source "$GOOARCHY_INSTALL/helpers/packages.sh"
export GOOARCHY_KERNEL_BUILD=$GOOARCHY_BUILD/linux-gooarchy
"$GOOARCHY_PATH/packaging/linux-gooarchy/build.sh"
mapfile -t files < <(built_files "$GOOARCHY_KERNEL_BUILD" linux-gooarchy linux-gooarchy-headers)
(( ${#files[@]} == 2 )) || { echo "Gooarchy kernel packages are missing" >&2; exit 1; }
install_built "${files[@]}"
version=$(pacman -Q linux-gooarchy | awk '{print $2}')
revision=$(git -C "$GOOARCHY_PATH" rev-parse HEAD)
record_build linux-gooarchy https://github.com/clickety-clacks/gooarchy "$revision" "$version"
# The build tree is about 30 GB; the packages and downloaded sources stay for the next build.
rm -rf "$GOOARCHY_KERNEL_BUILD/src"
echo "Experimental linux-gooarchy $version is installed alongside the existing kernel."

# Gooarchy leaves the bootloader as it is and only says what to do (docs/rulings.md). GRUB's menu
# has no entry for linux-gooarchy until it is regenerated, and regenerating lists linux-gooarchy
# first (it sorts ahead of linux), which makes it the default unless GRUB_TOP_LEVEL names another.
grub=/etc/default/grub
if [[ -f $grub ]] && command -v grub-mkconfig >/dev/null; then
  booted=$(sed -n 's/.*BOOT_IMAGE=\([^ ]*\).*/\1/p' /proc/cmdline)
  booted=${booted:+/boot/${booted##*/}}
  if grep -q '^GRUB_TOP_LEVEL=' "$grub"; then
    report "left $grub unchanged. It already sets $(grep '^GRUB_TOP_LEVEL=' "$grub" | tail -1), so regenerating GRUB's menu keeps that kernel first."
  elif [[ -n $booted && -f $booted && $booted != */vmlinuz-linux-gooarchy ]]; then
    report "left $grub unchanged. Regenerating GRUB's menu would make the experimental linux-gooarchy the default. To keep the kernel you booted the default, first add this line to $grub: GRUB_TOP_LEVEL=\"$booted\""
  else
    report "left $grub unchanged. Regenerating GRUB's menu would make the experimental linux-gooarchy the default. To keep your ordinary kernel the default, first add GRUB_TOP_LEVEL=\"<its image, e.g. /boot/vmlinuz-linux>\" to $grub."
  fi
  echo "GRUB's menu is unchanged. To add linux-gooarchy to it, run sudo grub-mkconfig -o /boot/grub/grub.cfg"
  echo "(or your GRUB configuration path); it appears under \"Advanced options\". Hardware validation is pending."
else
  echo "Your bootloader was not changed and has no entry for linux-gooarchy. To try it, add one for"
  echo "/boot/vmlinuz-linux-gooarchy with /boot/initramfs-linux-gooarchy.img, and keep your existing"
  echo "kernel as the default and fallback. Hardware validation is pending."
fi
