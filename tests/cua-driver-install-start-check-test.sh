#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
while [[ ${1:-} == --* ]]; do shift; done
shift
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
    printf '%s\n' "$$" >"$CUA_TEST_CONSOLE_PID_FILE"
    printf '%s\n' "$$" >"$5"
    touch "$CUA_TEST_CONSOLE_STATE"
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

echo 'cua-driver graphical and transient console start checks warn and continue on failure; console daemon is stopped before return.'
