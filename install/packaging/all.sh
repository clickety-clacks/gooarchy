run_logged "$GOOARCHY_INSTALL/packaging/repository.sh"
run_logged "$GOOARCHY_INSTALL/packaging/base.sh"
run_logged "$GOOARCHY_INSTALL/packaging/xdg-desktop-portal-wlr.sh"
run_logged "$GOOARCHY_INSTALL/packaging/scottland.sh"
run_logged "$GOOARCHY_INSTALL/packaging/strata.sh"
run_logged "$GOOARCHY_INSTALL/packaging/gooarchy.sh"
if ((GOOARCHY_KERNEL)); then
  run_logged "$GOOARCHY_INSTALL/packaging/kernel.sh"
fi
