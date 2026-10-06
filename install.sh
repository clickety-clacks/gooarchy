#!/bin/bash
# Turn a fresh, minimal Arch Linux install into Gooarchy.
#
# Run it from a checkout of this repository as the user who will use the desktop (not as root;
# it asks sudo for the steps that need root):
#
#   ./install.sh               ask once, then install
#   ./install.sh --yes         don't ask (unattended)
#   ./install.sh --autologin   also log this user in on the first console at boot, without a
#                              password, straight into Scottland. Off by default: Gooarchy has no
#                              lock screen yet, so autologin leaves the machine open to anyone.
#   ./install.sh --kernel      also build and install linux-gooarchy alongside the existing
#                              kernel, which stays the default boot (on GRUB, Gooarchy sets
#                              GRUB_TOP_LEVEL so a regenerated menu keeps it first, and reports
#                              that). Experimental, opt-in only. The build takes hours and needs
#                              about 35 GB free under ~/.cache while it runs.
#
# The steps run in order from install/: preflight, packaging, user, login, post-install. Each
# step's output goes to the terminal and to this attempt's log (~/.local/state/gooarchy/install.log
# points at the latest). If a step fails, running ./install.sh again retries; packages already
# installed and the Arch upgrade are not rolled back (docs/uninstall.md).
set -eEo pipefail

GOOARCHY_PATH=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GOOARCHY_INSTALL=$GOOARCHY_PATH/install
GOOARCHY_STATE=${XDG_STATE_HOME:-$HOME/.local/state}/gooarchy
GOOARCHY_BUILD=${XDG_CACHE_HOME:-$HOME/.cache}/gooarchy/build
GOOARCHY_YES=0
GOOARCHY_AUTOLOGIN=0
GOOARCHY_KERNEL=0
export GOOARCHY_PATH GOOARCHY_INSTALL GOOARCHY_STATE GOOARCHY_BUILD

for arg in "$@"; do
  case $arg in
    --yes | -y) GOOARCHY_YES=1 ;;
    --autologin) GOOARCHY_AUTOLOGIN=1 ;;
    --kernel) GOOARCHY_KERNEL=1 ;;
    -h | --help) sed -n '2,/^set -eEo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $arg (see --help)" >&2; exit 2 ;;
  esac
done
export GOOARCHY_YES GOOARCHY_AUTOLOGIN GOOARCHY_KERNEL

source "$GOOARCHY_INSTALL/helpers/all.sh"
start_install_log

source "$GOOARCHY_INSTALL/preflight/all.sh"
source "$GOOARCHY_INSTALL/packaging/all.sh"
source "$GOOARCHY_INSTALL/user/all.sh"
source "$GOOARCHY_INSTALL/login/all.sh"
source "$GOOARCHY_INSTALL/post-install/all.sh"

stop_install_log
