# Logging in on tty1 starts Scottland (/etc/profile.d/gooarchy-session.sh, from the gooarchy
# package): no display manager. With --autologin, getty also logs this user in on tty1 at boot.
dropin=/etc/systemd/system/getty@tty1.service.d/gooarchy-autologin.conf
if ((GOOARCHY_AUTOLOGIN)); then
  sudo install -Dm644 /dev/stdin "$dropin" <<CONF
# Written by Gooarchy's installer (--autologin): log $USER in on tty1 at boot without a password;
# /etc/profile.d/gooarchy-session.sh then starts Scottland. Delete this file to turn it off.
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USER --noreset --noclear - \${TERM}
CONF
  sudo systemctl daemon-reload
  echo "tty1 logs $USER in at boot ($dropin)."
elif [[ -f $dropin ]]; then
  echo "Kept the existing autologin setting in $dropin."
else
  echo "Log in on tty1 to start Scottland."
fi
