# One question before anything changes, unless --yes.
if ((GOOARCHY_YES == 0)); then
  echo
  echo "This installs Gooarchy (Scottland on Wayfire, Ghostty, Chromium, Strata, PipeWire) for $(id -un)."
  echo "It configures and trusts Gooarchy's signed package repository, installs packages with pacman, and builds Strata."
  echo "Scottland is built locally only when its source pin is overridden. Existing settings it changes are reported."
  ((GOOARCHY_AUTOLOGIN)) && echo "It also logs $(id -un) in on tty1 at boot without a password (--autologin)."
  ((GOOARCHY_KERNEL)) && echo "It also builds and installs the experimental Gooarchy kernel alongside yours (--kernel), which takes hours and about 35 GB free under ~/.cache; your kernel stays the default boot."
  read -r -p "Continue? [y/N] " answer </dev/tty
  [[ $answer == [yY]* ]] || { echo "Nothing changed."; exit 1; }
fi
