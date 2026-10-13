#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
unset GOOARCHY_SCOTTLAND_REF GOOARCHY_SCOTTLAND_REF_KIND
source "$repo_root/install/sources.conf"

[[ $GOOARCHY_SCOTTLAND_PIN_REF == v0.3.0 ]]
[[ $GOOARCHY_SCOTTLAND_PIN_KIND == tag ]]
[[ $GOOARCHY_SCOTTLAND_SOURCE_KIND == tag ]]
[[ $GOOARCHY_SCOTTLAND_REF == "$GOOARCHY_SCOTTLAND_PIN_REF" ]]

GOOARCHY_INSTALL=$repo_root/install
GOOARCHY_KERNEL=0
packaging_steps=()
run_logged() { packaging_steps+=("${1##*/}"); }
source "$GOOARCHY_INSTALL/packaging/all.sh"

portal_index=-1
scottland_index=-1
for index in "${!packaging_steps[@]}"; do
  case ${packaging_steps[$index]} in
    xdg-desktop-portal-wlr.sh) portal_index=$index ;;
    scottland.sh) scottland_index=$index ;;
  esac
done
((portal_index >= 0 && scottland_index > portal_index)) || {
  echo "Scottland portal package must be installed before Scottland." >&2
  exit 1
}

printf 'Scottland portal provider selection checks passed.\n'
