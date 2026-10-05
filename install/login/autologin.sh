# Logging in on tty1 starts Scottland (/etc/profile.d/gooarchy-session.sh, from the gooarchy
# package): no display manager. With --autologin, getty also logs this user in on tty1 at boot.
# Running the installer again without --autologin leaves an existing autologin setting alone;
# docs/uninstall.md says how to remove it.
source "$GOOARCHY_INSTALL/helpers/logging.sh"  # report
dropin=/etc/systemd/system/getty@tty1.service.d/gooarchy-autologin.conf
user=$(id -un)
if ((GOOARCHY_AUTOLOGIN)); then
  new=$(mktemp)
  cat >"$new" <<CONF
# Written by Gooarchy's installer (--autologin): log $user in on tty1 at boot without a password;
# /etc/profile.d/gooarchy-session.sh then starts Scottland. Delete this file to turn it off.
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $user --noreset --noclear - \${TERM}
CONF
  if [[ -f $dropin ]] && ! cmp -s "$new" "$dropin"; then
    previous=$(sed -n 's/.*--autologin \([^ ]*\).*/\1/p' "$dropin")
    report "replaced the tty1 autologin setting in $dropin (it logged in ${previous:-someone else}); --autologin asked for $user."
  fi
  sudo install -Dm644 "$new" "$dropin"
  rm -f "$new"
  sudo systemctl daemon-reload
  echo "tty1 logs $user in at boot ($dropin)."
elif [[ -f $dropin ]]; then
  echo "Kept the existing autologin setting in $dropin (remove that file to turn it off)."
else
  echo "Log in on tty1 to start Scottland."
fi
