# What was installed and what to do next.
echo
echo "Gooarchy is installed:"
pacman -Q gooarchy gooarchy-flavorings scottland strata-bin wayfire quickshell ghostty chromium | sed 's/^/  /'
echo "Built from (also in $GOOARCHY_STATE/builds.tsv):"
cut -f1,3 "$GOOARCHY_STATE/builds.tsv" | sed 's/\t/ /; s/^/  /'
if [[ -s $GOOARCHY_STATE/reports.log ]]; then
  echo
  echo "Settings Gooarchy changed or left alone (also in $GOOARCHY_STATE/reports.log):"
  sed 's/^/  /' "$GOOARCHY_STATE/reports.log"
fi
echo
echo "Next: reboot, or log in on tty1, to start Scottland. Super+Enter opens a terminal."
echo "If Arch's Wayfire moves ahead of published Scottland, pacman -Syu stops until a matching Scottland is published."
echo "With GOOARCHY_SCOTTLAND_REF overridden, ./install.sh builds Scottland locally for Arch's Wayfire."
echo "What Gooarchy doesn't have yet is listed in DEFICIT.md."
