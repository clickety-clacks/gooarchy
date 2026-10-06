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

# GRUB's menu has no entry for it until its configuration is regenerated, and regenerating puts
# linux-gooarchy first (it sorts ahead of linux), which makes it the default. GRUB_TOP_LEVEL
# (GRUB 2.12) keeps the kernel this system booted first instead.
grub=/etc/default/grub
if [[ -f $grub ]] && command -v grub-mkconfig >/dev/null; then
  booted=$(sed -n 's/.*BOOT_IMAGE=\([^ ]*\).*/\1/p' /proc/cmdline)
  booted=${booted:+/boot/${booted##*/}}
  if grep -q '^GRUB_TOP_LEVEL=' "$grub"; then
    echo "$grub already sets $(grep '^GRUB_TOP_LEVEL=' "$grub" | tail -1); Gooarchy left it as it is."
  elif [[ -n $booted && -f $booted && $booted != */vmlinuz-linux-gooarchy ]]; then
    printf '\n# Added by Gooarchy (install.sh --kernel): keep %s the default kernel.\nGRUB_TOP_LEVEL="%s"\n' \
      "$booted" "$booted" | sudo tee -a "$grub" >/dev/null
    report "set GRUB_TOP_LEVEL=\"$booted\" in $grub, so that regenerating GRUB's menu keeps the kernel you booted as the default rather than the experimental linux-gooarchy. Remove those lines to undo."
  else
    echo "Warning: regenerating GRUB's menu now would make linux-gooarchy the default. Set GRUB_TOP_LEVEL in $grub to your ordinary kernel's image (e.g. /boot/vmlinuz-linux) first." >&2
  fi
  echo "GRUB's menu itself is unchanged. To add linux-gooarchy to it, run sudo grub-mkconfig -o /boot/grub/grub.cfg"
  echo "(or your GRUB configuration path); it appears under \"Advanced options\". Hardware validation is pending."
else
  echo "Your bootloader was not changed and has no entry for linux-gooarchy. To try it, add one for"
  echo "/boot/vmlinuz-linux-gooarchy with /boot/initramfs-linux-gooarchy.img, and keep your existing"
  echo "kernel as the default and fallback. Hardware validation is pending."
fi
