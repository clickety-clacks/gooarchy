# Step logging: every step's output goes to the terminal and to the install log. A failing step
# stops the install and says which step failed and where the log is.

start_install_log() {
  mkdir -p "$GOOARCHY_STATE"
  : >"$GOOARCHY_INSTALL_LOG_FILE"
  GOOARCHY_START_EPOCH=$(date +%s)
  # git may not be installed yet on a fresh system; the summary names the built versions anyway.
  local rev
  rev=$(git -C "$GOOARCHY_PATH" rev-parse --short HEAD 2>/dev/null) || rev=
  log_line "=== Gooarchy install started $(date '+%Y-%m-%d %H:%M:%S')${rev:+ (checkout $rev)}"
}

stop_install_log() {
  local duration=$(($(date +%s) - GOOARCHY_START_EPOCH))
  log_line "=== Gooarchy install finished in $((duration / 60))m $((duration % 60))s"
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
  local script=$1 status=0
  log_line "--- $(date '+%H:%M:%S') ${script#"$GOOARCHY_INSTALL"/}"
  bash -eE -o pipefail -c 'source "$1"' bash "$script" </dev/null 2>&1 | tee -a "$GOOARCHY_INSTALL_LOG_FILE" ||
    status=$?
  if ((status != 0)); then
    log_line "!!! ${script#"$GOOARCHY_INSTALL"/} failed (exit $status). Full log: $GOOARCHY_INSTALL_LOG_FILE"
    exit "$status"
  fi
}
