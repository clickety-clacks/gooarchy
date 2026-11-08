# Apply supported laptop tuning and ensure Gooarchy's selected network stack after packaging.
gooarchy hw apply

if [[ ${GOOARCHY_YES:-0} == 1 ]]; then
  gooarchy network ensure --yes
else
  gooarchy network ensure
fi
