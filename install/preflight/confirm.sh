# One question before anything changes, unless --yes.
if ((GOOARCHY_YES == 0)); then
  echo
  echo "This installs Gooarchy (Scottland on Wayfire, Ghostty, Chromium, Strata, PipeWire) for $(id -un)."
  echo "It installs packages with pacman, builds Scottland and Strata as packages, and adds"
  echo "Gooarchy's defaults. Anything it changes that you already had is reported."
  ((GOOARCHY_AUTOLOGIN)) && echo "It also logs $(id -un) in on tty1 at boot without a password (--autologin)."
  ((GOOARCHY_KERNEL)) && echo "It also builds and installs the experimental Gooarchy kernel alongside yours (--kernel), which takes hours and about 35 GB free under ~/.cache; your kernel stays the default boot."
  read -r -p "Continue? [y/N] " answer </dev/tty
  [[ $answer == [yY]* ]] || { echo "Nothing changed."; exit 1; }
fi
