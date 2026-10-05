# Ask for the sudo password once and keep it fresh while the install runs.
sudo -v
while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
GOOARCHY_SUDO_KEEPALIVE=$!
trap 'kill "$GOOARCHY_SUDO_KEEPALIVE" 2>/dev/null' EXIT
