#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
printf 'timeout %s\n' "$*" >>"$CUA_TEST_DRIVER_LOG"
while [[ ${1:-} == --* ]]; do shift; done
if [[ ${1:-} =~ ^[0-9]+(ms|s|m|h)$ ]]; then shift; fi
if [[ $CUA_TEST_CONSOLE_SERVE_MODE == unresponsive \
  && ${1:-} == */cua-driver && ${2:-} == serve ]]; then
  # Simulate the timeout quickly while preserving its requested arguments in the log.
  "$@" &
  timed_pid=$!
  ready=0
  for ((attempt = 0; attempt < 100; attempt++)); do
    if [[ -s $CUA_TEST_CONSOLE_PID_FILE && -e $CUA_TEST_CONSOLE_STATE ]] \
      && [[ $(cat "$CUA_TEST_CONSOLE_PID_FILE") == "$timed_pid" ]]; then
      ready=1
      break
    fi
    if ! kill -0 "$timed_pid" 2>/dev/null; then
      wait "$timed_pid"
      exit $?
    fi
    /bin/sleep 0.01
  done
  if (( !ready )); then
    kill -TERM "$timed_pid" 2>/dev/null || true
    wait "$timed_pid" || true
    printf '%s\n' 'temporary console daemon did not signal readiness' >>"$CUA_TEST_DRIVER_LOG"
    exit 125
  fi
  /bin/sleep 0.05
  if kill -0 "$timed_pid" 2>/dev/null; then
    kill -TERM "$timed_pid" 2>/dev/null || true
    wait "$timed_pid" || true
    printf '%s\n' 'simulated timeout exit 124' >>"$CUA_TEST_DRIVER_LOG"
    exit 124
  fi
  wait "$timed_pid"
  exit $?
fi
exec "$@"
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CUA_TEST_SYSTEMCTL_LOG"
case "$*" in
  '--user daemon-reload') exit 0 ;;
  '--user is-active --quiet graphical-session.target') [[ $CUA_TEST_GRAPHICAL == yes ]] ;;
  '--user start cua-driver.service')
    printf '%s\n' "$CUA_TEST_START_OUTPUT" >&2
    exit "$CUA_TEST_START_STATUS"
    ;;
  *) echo "unexpected systemctl command: $*" >&2; exit 90 ;;
esac
EOF
cat >"$tmp/bin/cua-driver" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CUA_TEST_DRIVER_LOG"
case ${1:-} in
  serve)
    if [[ ${2:-} != --socket || ${4:-} != --pid-file ]] \
      || [[ $(dirname -- "${3:-/}") != "$(dirname -- "${5:-/}")" ]] \
      || [[ $(basename -- "${5:-}") != daemon.pid ]]; then
      exit 94
    fi
    if [[ $CUA_TEST_CONSOLE_SERVE_MODE == fail ]]; then
      echo 'console serve failed' >&2
      exit 1
    fi
    if [[ $CUA_TEST_CONSOLE_SERVE_MODE == unresponsive ]]; then
      trap 'rm -f -- "$CUA_TEST_CONSOLE_STATE"; exit 143' TERM
    fi
    printf '%s\n' "$$" >"$CUA_TEST_CONSOLE_PID_FILE"
    printf '%s\n' "$$" >"$5"
    touch "$CUA_TEST_CONSOLE_STATE"
    if [[ $CUA_TEST_CONSOLE_SERVE_MODE == unresponsive ]]; then
      while :; do :; done
    fi
    while [[ -e $CUA_TEST_CONSOLE_STATE ]]; do /bin/sleep 0.01; done
    ;;
  stop)
    rm -f -- "$CUA_TEST_CONSOLE_STATE"
    ;;
  status)
    if [[ ${2:-} == --socket ]]; then
      if [[ ${4:-} != --pid-file ]] \
        || [[ $(dirname -- "${3:-/}") != "$(dirname -- "${5:-/}")" ]] \
        || [[ $(basename -- "${5:-}") != daemon.pid ]]; then
        exit 95
      fi
      if [[ -e $CUA_TEST_CONSOLE_STATE ]]; then
        if [[ $CUA_TEST_CONSOLE_SERVE_MODE == unresponsive ]]; then exit 1; fi
        echo 'daemon running'
        exit 0
      fi
      echo 'daemon socket unavailable' >&2
      exit 1
    fi
    count=$(cat "$CUA_TEST_STATUS_COUNT" 2>/dev/null || printf '0')
    count=$((count + 1))
    printf '%s\n' "$count" >"$CUA_TEST_STATUS_COUNT"
    case $CUA_TEST_STATUS_MODE in
      ready-second)
        if ((count < 2)); then echo 'daemon not ready' >&2; exit 1; fi
        echo 'daemon running'
        ;;
      fail)
        echo 'daemon socket unavailable' >&2
        exit 1
        ;;
      unresponsive)
        exit 1
        ;;
      *) exit 92 ;;
    esac
    ;;
  *) exit 91 ;;
esac
EOF
cat >"$tmp/bin/pacman" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == -Q ]] || exit 93
shift
for package in "$@"; do printf '%s 1-1\n' "$package"; done
EOF
chmod +x "$tmp/bin/timeout" "$tmp/bin/sleep" "$tmp/bin/systemctl" \
  "$tmp/bin/cua-driver" "$tmp/bin/pacman"

export PATH="$tmp/bin:$PATH"
export GOOARCHY_INSTALL=$repo_root/install
export CUA_TEST_SYSTEMCTL_LOG=$tmp/systemctl.log
export CUA_TEST_DRIVER_LOG=$tmp/driver.log
export GOOARCHY_INSTALL_LOG_FILE=$tmp/install.log
export GOOARCHY_STATE=$tmp/state
export HOME=$tmp/home
mkdir -p "$GOOARCHY_STATE"
mkdir -p "$HOME/.cache/cua-driver"
printf '%s\n' 'unrelated-daemon-pid' >"$HOME/.cache/cua-driver/cua-driver.pid"
touch "$GOOARCHY_STATE/builds.tsv"

run_check() {
  local label=$1
  export CUA_TEST_SYSTEMCTL_LOG=$tmp/$label-systemctl.log
  export CUA_TEST_DRIVER_LOG=$tmp/$label-driver.log
  export CUA_TEST_STATUS_COUNT=$tmp/$label-status-count
  export CUA_TEST_CONSOLE_STATE=$tmp/$label-daemon-state
  export CUA_TEST_CONSOLE_PID_FILE=$tmp/$label-daemon-pid
  export GOOARCHY_STATE=$tmp/$label-state
  export GOOARCHY_INSTALL_LOG_FILE=$tmp/$label-install.log
  mkdir -p "$GOOARCHY_STATE"
  : >"$GOOARCHY_STATE/builds.tsv"
  : >"$CUA_TEST_SYSTEMCTL_LOG"
  : >"$CUA_TEST_DRIVER_LOG"
  bash -eE -o pipefail -c '
    source "$GOOARCHY_INSTALL/helpers/logging.sh"
    source "$GOOARCHY_INSTALL/helpers/cua-driver.sh"
    cua_driver_install_start_check "$1"
    printf "later installer step ran\n"
  ' bash "$tmp/bin/cua-driver" >"$tmp/$label-output" 2>&1
}

export CUA_TEST_GRAPHICAL=yes
export CUA_TEST_START_STATUS=0
export CUA_TEST_START_OUTPUT=
export CUA_TEST_STATUS_MODE=ready-second
export CUA_TEST_CONSOLE_SERVE_MODE=success
run_check graphical-success
grep -Fq 'later installer step ran' "$tmp/graphical-success-output"
! grep -Fq 'Gooarchy:' "$tmp/graphical-success-output"
grep -Fq -- '--user start cua-driver.service' "$tmp/graphical-success-systemctl.log"

export CUA_TEST_START_STATUS=1
export CUA_TEST_START_OUTPUT='start request failed'
export CUA_TEST_STATUS_MODE=fail
run_check graphical-failure
grep -Fq 'later installer step ran' "$tmp/graphical-failure-output"
grep -Fq 'Gooarchy: cua-driver did not answer' "$tmp/graphical-failure-output"
grep -Fq 'start request failed' "$tmp/graphical-failure-output"
grep -Fq 'daemon socket unavailable' "$tmp/graphical-failure-output"
grep -Fq 'Installation will continue' "$tmp/graphical-failure-output"
grep -Fq 'cua-driver did not answer' "$tmp/graphical-failure-install.log"
grep -Fq 'cua-driver did not answer' "$tmp/graphical-failure-state/reports.log"

summary=$(GOOARCHY_STATE="$GOOARCHY_STATE" bash "$repo_root/install/post-install/summary.sh")
grep -Fq 'cua-driver 1-1' <<<"$summary"
grep -Fq 'Install notes' <<<"$summary"
grep -Fq 'cua-driver did not answer' <<<"$summary"

export CUA_TEST_GRAPHICAL=no
export CUA_TEST_START_STATUS=0
export CUA_TEST_START_OUTPUT=
export CUA_TEST_STATUS_MODE=fail
export CUA_TEST_CONSOLE_SERVE_MODE=success
run_check console-success
grep -Fq 'later installer step ran' "$tmp/console-success-output"
! grep -Fq 'Gooarchy:' "$tmp/console-success-output"
grep -Fq 'serve --socket ' "$tmp/console-success-driver.log"
grep -Fq 'stop --socket ' "$tmp/console-success-driver.log"
if grep -Fq -- '--user start cua-driver.service' "$tmp/console-success-systemctl.log"; then
  echo 'console check started the graphical-session service' >&2
  exit 1
fi
[[ ! -e $tmp/console-success-daemon-state ]]
console_pid=$(cat "$tmp/console-success-daemon-pid")
if kill -0 "$console_pid" 2>/dev/null; then
  echo 'console check left its temporary daemon process running' >&2
  exit 1
fi
[[ $(cat "$HOME/.cache/cua-driver/cua-driver.pid") == unrelated-daemon-pid ]]

export CUA_TEST_CONSOLE_SERVE_MODE=fail
run_check console-failure
grep -Fq 'later installer step ran' "$tmp/console-failure-output"
grep -Fq 'Gooarchy: cua-driver did not answer' "$tmp/console-failure-output"
grep -Fq 'console serve failed' "$tmp/console-failure-output"
grep -Fq 'daemon socket unavailable' "$tmp/console-failure-output"
grep -Fq 'Installation will continue' "$tmp/console-failure-output"
if grep -Fq -- '--user start cua-driver.service' "$tmp/console-failure-systemctl.log"; then
  echo 'console failure check started the graphical-session service' >&2
  exit 1
fi
[[ ! -e $tmp/console-failure-daemon-state ]]

export CUA_TEST_CONSOLE_SERVE_MODE=unresponsive
export CUA_TEST_STATUS_MODE=unresponsive
run_check console-unresponsive
grep -Fq 'later installer step ran' "$tmp/console-unresponsive-output"
grep -Fq 'Gooarchy: cua-driver did not answer' "$tmp/console-unresponsive-output"
grep -Fq 'serve exited 124 without output' "$tmp/console-unresponsive-output"
grep -Fq 'Installation will continue' "$tmp/console-unresponsive-output"
grep -Fq -- 'timeout --signal=TERM --kill-after=1s 40s ' "$tmp/console-unresponsive-driver.log"
grep -Fq 'simulated timeout exit 124' "$tmp/console-unresponsive-driver.log"
console_pid=$(cat "$tmp/console-unresponsive-daemon-pid")
if kill -0 "$console_pid" 2>/dev/null; then
  echo 'unresponsive console check left its temporary daemon process running' >&2
  exit 1
fi
[[ ! -e $tmp/console-unresponsive-daemon-state ]]
console_socket=$(sed -n 's/^serve --socket \([^ ]*\) --pid-file .*/\1/p' "$tmp/console-unresponsive-driver.log")
if [[ -z $console_socket || -e ${console_socket%/daemon.sock} ]]; then
  echo 'unresponsive console check left its temporary runtime directory behind' >&2
  exit 1
fi

echo 'cua-driver startup failures warn and continue; transient console daemons are stopped after readiness and terminated with their temporary files after timeout.'
