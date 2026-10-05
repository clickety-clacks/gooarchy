# Gooarchy: logging in on the first console (tty1) starts the Scottland desktop. There is no
# display manager. To get a plain console login on tty1 instead, create
# ~/.config/gooarchy/no-session (or set GOOARCHY_NO_SESSION=1); other consoles never start it.
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ] && [ -z "${GOOARCHY_NO_SESSION:-}" ] &&
   [ "$(tty 2>/dev/null)" = /dev/tty1 ] && command -v start-scottland >/dev/null 2>&1 &&
   [ ! -e "${XDG_CONFIG_HOME:-$HOME/.config}/gooarchy/no-session" ]; then
  start-scottland
  gooarchy_status=$?
  # Logging out of Scottland (Super+Shift+Escape) ends the console login too.
  if [ "$gooarchy_status" -eq 0 ] || [ "$gooarchy_status" -eq 143 ]; then
    exit 0
  fi
  # A crash leaves a shell here rather than looping back into a broken session.
  echo "Scottland stopped (exit status $gooarchy_status). Its log: ~/.local/state/scottland/wayfire.log"
  echo "Type start-scottland to start it again, or exit to log out."
  unset gooarchy_status
fi
