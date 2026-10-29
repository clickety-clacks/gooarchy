# Start check for the signed cua-driver package installed with Gooarchy.

cua_driver_install_start_check() {
  local binary=${1:-/usr/bin/cua-driver}
  local start_output= start_status=0 status_output= status_detail= start_detail=
  local attempt

  # Reload this user's unit view without starting the daemon. Other user managers load the
  # package-owned graphical-session.target.wants link when their session starts.
  timeout 3s systemctl --user daemon-reload >/dev/null 2>&1 || true

  if timeout 2s systemctl --user is-active --quiet graphical-session.target; then
    start_output=$(timeout 5s systemctl --user start cua-driver.service 2>&1) || start_status=$?
    for attempt in {1..12}; do
      status_output=$(timeout 2s "$binary" status 2>&1) && return 0
      if ((attempt < 12)); then sleep 1; fi
    done

    start_detail="systemd start exited $start_status"
    [[ -n $start_output ]] && start_detail+=" ($start_output)"
    status_detail=${status_output//$'\n'/; }
    status_detail=${status_detail:0:240}
    [[ -n $status_detail ]] || status_detail='status command timed out or returned no detail'
    report "cua-driver did not answer within the install-time check. Start result: $start_detail; last status: $status_detail. Installation will continue. Details: systemctl --user status cua-driver.service and journalctl --user -u cua-driver.service."
    return 0
  fi

  status_output=$(timeout 2s "$binary" status 2>&1) && return 0
  status_detail=${status_output//$'\n'/; }
  status_detail=${status_detail:0:240}
  [[ -n $status_detail ]] || status_detail='status command timed out or returned no detail'
  report "cua-driver did not answer during installation because no graphical session was active. The installer did not start it outside a graphical session; it will start automatically at the next graphical login. Last status: $status_detail. Details: systemctl --user status cua-driver.service and journalctl --user -u cua-driver.service."
  return 0
}
