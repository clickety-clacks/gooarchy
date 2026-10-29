# cua-driver is a required Gooarchy package dependency; only its start check is optional.
source "$GOOARCHY_INSTALL/helpers/logging.sh"
source "$GOOARCHY_INSTALL/helpers/repository.sh"
source "$GOOARCHY_INSTALL/helpers/cua-driver.sh"

if ! package_is_repository_copy cua-driver; then
  echo "Gooarchy's cua-driver package was not installed as a signed repository copy." >&2
  exit 1
fi

cua_driver_install_start_check /usr/bin/cua-driver
