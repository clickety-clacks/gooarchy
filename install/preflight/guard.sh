# Gooarchy installs onto plain Arch Linux, as a normal user with sudo.
abort() { echo "Gooarchy can't install here: $*" >&2; exit 1; }

[[ -f /etc/arch-release ]] || abort "this isn't Arch Linux."
[[ $(uname -m) == x86_64 ]] || abort "Scottland is packaged for x86_64 only (this is $(uname -m))."
((EUID != 0)) || abort "run it as the user who will use the desktop, not as root."
command -v sudo >/dev/null || abort "sudo isn't installed (pacman -S sudo, and add this user to wheel)."
command -v pacman >/dev/null || abort "pacman is missing."
# Gooarchy starts clean on plain Arch. On Omarchy, Scottland has its own adapter instead.
[[ ! -d /usr/share/omarchy ]] || abort "this is an Omarchy system; Scottland's Omarchy adapter is the way to run it there."

# Files Gooarchy's packages own that a system might already have from someone's hand.
for file in /etc/tmux.conf; do
  if [[ -e $file ]] && ! pacman -Qqo "$file" >/dev/null 2>&1; then
    abort "$file already exists and Gooarchy's packages install their own. Move it aside (or into ~/.tmux.conf, which still applies after Gooarchy's) and run the installer again."
  fi
done

if systemctl is-enabled --quiet display-manager.service 2>/dev/null; then
  echo "Note: a display manager is enabled ($(readlink -f /etc/systemd/system/display-manager.service | xargs basename)). Gooarchy starts Scottland from a console login on tty1, which the display manager may own; choose Scottland in its session menu instead (Gooarchy installs a Scottland session entry)."
fi

echo "Installing Gooarchy for $USER on $(. /etc/os-release && echo "$PRETTY_NAME"), kernel $(uname -r)."
