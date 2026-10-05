# One question before anything changes, unless --yes.
if ((GOOARCHY_YES == 0)); then
  echo
  echo "This installs Gooarchy (Scottland on Wayfire, Ghostty, Chromium, Strata, PipeWire) for $USER."
  echo "It installs packages with pacman, builds Scottland and Strata as packages, and adds"
  echo "Gooarchy's defaults. Anything it changes that you already had is reported."
  ((GOOARCHY_AUTOLOGIN)) && echo "It also logs $USER in on tty1 at boot without a password (--autologin)."
  read -r -p "Continue? [y/N] " answer </dev/tty
  [[ $answer == [yY]* ]] || { echo "Nothing changed."; exit 1; }
fi
