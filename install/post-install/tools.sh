# Apply supported laptop tuning and ensure Gooarchy's selected network stack after packaging.
gooarchy hw apply

network_args=()
if [[ ${GOOARCHY_YES:-0} == 1 ]]; then
  network_args+=(--yes)
fi
# Network setup reports its own failure details. A missing radio or an unavailable
# service must not prevent the rest of the desktop installation from finishing.
if gooarchy network ensure "${network_args[@]}"; then
  :
else
  network_status=$?
  echo "Warning: Gooarchy network setup did not complete (exit $network_status); continuing installation. Review the errors above and run 'gooarchy network status'. After resolving them, retry 'gooarchy network ensure'. Existing network configuration was not replaced." >&2
fi
