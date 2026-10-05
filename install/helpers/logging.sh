# Step logging. Every attempt gets its own log (~/.local/state/gooarchy/logs/install-<time>.log;
# install.log points at the latest), and package manifests from before and after it, so a failed
# attempt's evidence survives a retry. A failing step stops the install and says which step failed,
# which one last completed, and where the log is.

start_install_log() {
  GOOARCHY_ATTEMPT=$(date '+%Y%m%dT%H%M%S')
  GOOARCHY_ATTEMPT_DIR=$GOOARCHY_STATE/logs/$GOOARCHY_ATTEMPT
  GOOARCHY_INSTALL_LOG_FILE=$GOOARCHY_ATTEMPT_DIR/install.log
  export GOOARCHY_ATTEMPT_DIR GOOARCHY_INSTALL_LOG_FILE
  mkdir -p "$GOOARCHY_ATTEMPT_DIR"
  : >"$GOOARCHY_INSTALL_LOG_FILE"
  ln -sfn "logs/$GOOARCHY_ATTEMPT/install.log" "$GOOARCHY_STATE/install.log"
  GOOARCHY_START_EPOCH=$(date +%s)
  package_manifest >"$GOOARCHY_ATTEMPT_DIR/packages-before.txt"
  trap on_exit EXIT
  # git may not be installed yet on a fresh system; the summary names the built versions anyway.
  local rev
  rev=$(git -C "$GOOARCHY_PATH" rev-parse --short HEAD 2>/dev/null) || rev=
  log_line "=== Gooarchy install started $(date '+%Y-%m-%d %H:%M:%S')${rev:+ (checkout $rev)}"
  [[ -f $GOOARCHY_STATE/last-step ]] &&
    log_line "    (a previous attempt last completed $(cat "$GOOARCHY_STATE/last-step"))"
  true
}

stop_install_log() {
  local duration=$(($(date +%s) - GOOARCHY_START_EPOCH))
  echo complete >"$GOOARCHY_STATE/last-step"
  log_line "=== Gooarchy install finished in $((duration / 60))m $((duration % 60))s"
}

on_exit() {
  [[ -n ${GOOARCHY_SUDO_KEEPALIVE:-} ]] && kill "$GOOARCHY_SUDO_KEEPALIVE" 2>/dev/null
  package_manifest >"$GOOARCHY_ATTEMPT_DIR/packages-after.txt"
}

# Installed packages with version and install reason: "name version explicit|dependency".
package_manifest() {
  { pacman -Qe | sed 's/$/ explicit/'; pacman -Qd | sed 's/$/ dependency/'; } 2>/dev/null | sort
}

log_line() {
  echo "$1" | tee -a "$GOOARCHY_INSTALL_LOG_FILE"
}

# Report a change to something the user (or the system) already had, with its reason. Gooarchy
# never replaces an existing setting silently; reports also land in the state directory.
report() {
  echo "Gooarchy: $*" | tee -a "$GOOARCHY_STATE/reports.log" "$GOOARCHY_INSTALL_LOG_FILE" >&2
}

run_logged() {
  local script=$1 step=${1#"$GOOARCHY_INSTALL"/} status=0
  log_line "--- $(date '+%H:%M:%S') $step"
  if [[ ${GOOARCHY_TEST_FAIL_AT:-} == "$step" ]]; then
    # Test hook (tests/vm/run.sh): fail here, to check that a retry recovers.
    log_line "!!! $step failed on purpose (GOOARCHY_TEST_FAIL_AT)"
    status=99
  else
    bash -eE -o pipefail -c 'source "$1"' bash "$script" </dev/null 2>&1 | tee -a "$GOOARCHY_INSTALL_LOG_FILE" ||
      status=$?
  fi
  if ((status != 0)); then
    log_line "!!! $step failed (exit $status); last completed: $(cat "$GOOARCHY_STATE/last-step" 2>/dev/null || echo nothing)."
    log_line "!!! Full log: $GOOARCHY_INSTALL_LOG_FILE. Running ./install.sh again retries; docs/uninstall.md covers backing out."
    exit "$status"
  fi
  echo "$step" >"$GOOARCHY_STATE/last-step"
}
