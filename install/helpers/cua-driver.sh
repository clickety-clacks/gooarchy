# Start check for the signed cua-driver package installed with Gooarchy.

cua_driver_console_start_check() {
  local binary=$1 temp_dir socket serve_log server_pid
  local serve_status=0 status_output= status_detail= serve_detail=
  local answer_status=1 stop_status=0 stop_output= final_status=0 final_output=
  local retry_stop_status=0 retry_stop_output= attempt

  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/gooarchy-cua-driver.XXXXXX") || {
    report 'cua-driver console start check could not create a temporary runtime directory. Installation will continue.'
    return 0
  }
  socket=$temp_dir/daemon.sock
  serve_log=$temp_dir/serve.log

  # Use a private socket so the check cannot attach to a pre-existing user daemon. The
  # timeout bounds and cleans up this foreground server even if status or stop fails.
  timeout --signal=TERM --kill-after=1s 40s "$binary" serve --socket "$socket" \
    >"$serve_log" 2>&1 &
  server_pid=$!

  for attempt in {1..12}; do
    status_output=$(timeout 2s "$binary" status --socket "$socket" 2>&1) && {
      answer_status=0
      break
    }
    if ! kill -0 "$server_pid" 2>/dev/null; then break; fi
    if ((attempt < 12)); then sleep 1; fi
  done

  if ((answer_status == 0)); then
    stop_output=$(timeout 3s "$binary" stop --socket "$socket" 2>&1) || stop_status=$?
  fi
  wait "$server_pid" || serve_status=$?

  final_output=$(timeout 2s "$binary" status --socket "$socket" 2>&1) || final_status=$?
  if ((final_status == 0)); then
    retry_stop_output=$(timeout 3s "$binary" stop --socket "$socket" 2>&1) || retry_stop_status=$?
    final_output=$(timeout 2s "$binary" status --socket "$socket" 2>&1) || final_status=$?
  fi

  serve_detail=$(<"$serve_log")
  serve_detail=${serve_detail//$'\n'/; }
  serve_detail=${serve_detail:0:240}
  [[ -n $serve_detail ]] || serve_detail="serve exited $serve_status without output"
  status_detail=${status_output//$'\n'/; }
  status_detail=${status_detail:0:240}
  [[ -n $status_detail ]] || status_detail='status command timed out or returned no detail'

  if ((answer_status != 0)); then
    report "cua-driver did not answer in the console install-time start check. Temporary serve result: $serve_detail; last status: $status_detail. Installation will continue. Details: systemctl --user status cua-driver.service and journalctl --user -u cua-driver.service."
  fi
  if ((final_status == 0)); then
    local cleanup_detail=${final_output//$'\n'/; }
    [[ -n $stop_output ]] && cleanup_detail+="; first stop: ${stop_output//$'\n'/; }"
    [[ -n $retry_stop_output ]] && cleanup_detail+="; retry stop: ${retry_stop_output//$'\n'/; }"
    cleanup_detail=${cleanup_detail:0:240}
    report "cua-driver answered during the console start check but did not stop cleanly after two stop attempts (first exit $stop_status, retry exit $retry_stop_status). It may remain active. Installation will continue. Details: $cleanup_detail; systemctl --user status cua-driver.service and journalctl --user -u cua-driver.service."
  fi

  rm -rf -- "$temp_dir"
  return 0
}

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

  cua_driver_console_start_check "$binary"
}
