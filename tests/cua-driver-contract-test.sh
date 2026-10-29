#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe=$repo_root/packaging/arch/cua-driver/PKGBUILD
service=$repo_root/packaging/arch/cua-driver/cua-driver.service

source "$recipe"
[[ $pkgname == cua-driver ]]
[[ $pkgver == 0.38.0 ]]
[[ ${license[*]} == MIT ]]
[[ ${source[0]} == *"cua-driver-rs-${pkgver}-linux-x86_64-binary.tar.gz"* ]]
[[ ${sha256sums[0]} == 31ab9709dd91ce73677e49b9f3e75c6f0d3e4d9625c286c9e58262bfbea698dd ]]
[[ ${sha256sums[1]} == c0779290c1d4783169aa3dbfb55feb505e563ef8a004bbf55298ceffcfbda8d9 ]]
grep -Fq "'cua-driver'" "$repo_root/packaging/arch/PKGBUILD"
grep -Fq 'cua-driver;' "$repo_root/install/packaging/repository.sh"
grep -Fq 'required_initial=' "$repo_root/packaging/repository/produce.sh"
grep -Fq 'selected[cua-driver]' "$repo_root/packaging/repository/produce.sh"
grep -Fq 'run_logged "$GOOARCHY_INSTALL/packaging/cua-driver.sh"' "$repo_root/install/packaging/all.sh"
grep -Fq 'package_is_repository_copy cua-driver' "$repo_root/install/packaging/cua-driver.sh"
grep -Fq 'cua-driver' "$repo_root/install/post-install/summary.sh"
grep -Fq 'timeout 3s systemctl --user daemon-reload' "$repo_root/install/helpers/cua-driver.sh"
grep -Fq 'timeout 2s systemctl --user is-active --quiet graphical-session.target' "$repo_root/install/helpers/cua-driver.sh"
grep -Fq 'timeout 5s systemctl --user start cua-driver.service' "$repo_root/install/helpers/cua-driver.sh"
grep -Fq 'timeout 2s "$binary" status' "$repo_root/install/helpers/cua-driver.sh"
grep -Fq 'for attempt in {1..12}' "$repo_root/install/helpers/cua-driver.sh"
((3 + 2 + 5 + 12 * 2 + 11 <= 60))

grep -Fq 'After=graphical-session.target' "$service"
grep -Fq 'PartOf=graphical-session.target' "$service"
grep -Fq 'ExecStart=/usr/bin/cua-driver serve' "$service"
if grep -Eq 'CUA_DRIVER_RS_ENABLE_WAYLAND|Environment=' "$service"; then
  echo 'the service overrides an upstream display or backend default' >&2
  exit 1
fi

# Exercise the package function with a small upstream-shaped archive.
if [[ -n ${POOL_RUN_ID:-} ]]; then
  tmp_parent=$PWD/scratch/$POOL_RUN_ID
  mkdir -p "$tmp_parent"
  tmp=$(mktemp -d "$tmp_parent/run.XXXXXX")
else
  tmp=$(mktemp -d)
fi
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/src" "$tmp/release/wayland-helper"
printf '%s\n' fixture >"$tmp/release/cua-driver"
printf '%s\n' fixture >"$tmp/release/cua-cursor-theme"
printf '%s\n' fixture >"$tmp/release/libcua_driver_sdk.so"
printf '%s\n' fixture >"$tmp/release/cua_driver_node_runtime.node"
chmod +x "$tmp/release/cua-driver" "$tmp/release/cua-cursor-theme"
printf '%s\n' fixture >"$tmp/release/wayland-helper/extension.js"
tar -czf "$tmp/src/cua-driver-rs-${pkgver}-linux-x86_64-binary.tar.gz" -C "$tmp/release" .
cp -- "$service" "$tmp/src/cua-driver.service"
printf 'MIT License\nfixture\n' >"$tmp/src/LICENSE.md"

srcdir=$tmp/src
pkgdir=$tmp/pkg
package
[[ -x $pkgdir/usr/lib/cua-driver/cua-driver ]]
[[ $(readlink "$pkgdir/usr/bin/cua-driver") == /usr/lib/cua-driver/cua-driver ]]
[[ $(readlink "$pkgdir/usr/bin/cua-cursor-theme") == /usr/lib/cua-driver/cua-cursor-theme ]]
[[ $(readlink "$pkgdir/usr/lib/systemd/user/graphical-session.target.wants/cua-driver.service") == ../cua-driver.service ]]
cmp -- "$service" "$pkgdir/usr/lib/systemd/user/cua-driver.service"
cmp -- "$tmp/src/LICENSE.md" "$pkgdir/usr/share/licenses/cua-driver/LICENSE"

if command -v makepkg >/dev/null 2>&1; then
  mkdir -p "$tmp/sources" "$tmp/build" "$tmp/packages"
  (
    cd "$(dirname "$recipe")"
    SRCDEST=$tmp/sources BUILDDIR=$tmp/build PKGDEST=$tmp/packages \
      makepkg --noconfirm --force --cleanbuild --nosign
  )
  archive=$(find "$tmp/packages" -type f -name 'cua-driver-0.38.0-1-x86_64.pkg.tar.*' -print -quit)
  [[ -n $archive && -s $archive ]]
  bsdtar -xOf "$archive" .PKGINFO >"$tmp/pkginfo"
  grep -Fxq 'pkgname = cua-driver' "$tmp/pkginfo"
  grep -Fxq 'pkgver = 0.38.0-1' "$tmp/pkginfo"
  bsdtar -tf "$archive" | grep -Eq '(^|/)usr/lib/systemd/user/graphical-session.target.wants/cua-driver.service$'
  sha256sum "$archive"
else
  echo 'makepkg unavailable; unsigned archive build skipped.'
fi

# Mock only the user service manager and driver status calls. A failed check must be
# informational to the installer, while a console install must not start the daemon.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
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
  '--user start cua-driver.service') printf '%s\n' "$CUA_TEST_START_OUTPUT" >&2; exit "$CUA_TEST_START_STATUS" ;;
  *) echo "unexpected systemctl command: $*" >&2; exit 90 ;;
esac
EOF
cat >"$tmp/bin/cua-driver" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == status ]] || exit 91
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
EOF
cat >"$tmp/bin/pacman" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == -Q ]] || exit 93
shift
for package in "$@"; do printf '%s 1-1\n' "$package"; done
EOF
chmod +x "$tmp/bin/timeout" "$tmp/bin/sleep" "$tmp/bin/systemctl" "$tmp/bin/cua-driver" "$tmp/bin/pacman"

export PATH="$tmp/bin:$PATH"
export GOOARCHY_INSTALL=$repo_root/install
export GOOARCHY_STATE=$tmp/state
export GOOARCHY_INSTALL_LOG_FILE=$tmp/install.log
export CUA_TEST_SYSTEMCTL_LOG=$tmp/systemctl.log
export CUA_TEST_STATUS_COUNT=$tmp/status-count
mkdir -p "$GOOARCHY_STATE"
touch "$GOOARCHY_STATE/builds.tsv"

run_check() {
  local label=$1
  export CUA_TEST_SYSTEMCTL_LOG=$tmp/$label-systemctl.log
  export CUA_TEST_STATUS_COUNT=$tmp/$label-status-count
  export GOOARCHY_STATE=$tmp/$label-state
  export GOOARCHY_INSTALL_LOG_FILE=$tmp/$label-install.log
  mkdir -p "$GOOARCHY_STATE"
  : >"$GOOARCHY_STATE/builds.tsv"
  : >"$CUA_TEST_SYSTEMCTL_LOG"
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
run_check ready
grep -Fq 'later installer step ran' "$tmp/ready-output"
! grep -Fq 'Gooarchy:' "$tmp/ready-output"
grep -Fq -- '--user start cua-driver.service' "$tmp/ready-systemctl.log"

export CUA_TEST_START_STATUS=1
export CUA_TEST_START_OUTPUT='start request failed'
export CUA_TEST_STATUS_MODE=fail
run_check failure
grep -Fq 'later installer step ran' "$tmp/failure-output"
grep -Fq 'Gooarchy: cua-driver did not answer' "$tmp/failure-output"
grep -Fq 'start request failed' "$tmp/failure-output"
grep -Fq 'daemon socket unavailable' "$tmp/failure-output"
grep -Fq 'Installation will continue' "$tmp/failure-output"
grep -Fq 'cua-driver did not answer' "$tmp/failure-install.log"
grep -Fq 'cua-driver did not answer' "$tmp/failure-state/reports.log"

cat >"$GOOARCHY_STATE/builds.tsv" <<'EOF'
EOF
summary=$(GOOARCHY_STATE="$GOOARCHY_STATE" bash "$repo_root/install/post-install/summary.sh")
grep -Fq 'cua-driver 1-1' <<<"$summary"
grep -Fq 'Install notes' <<<"$summary"
grep -Fq 'cua-driver did not answer' <<<"$summary"

export CUA_TEST_GRAPHICAL=no
export CUA_TEST_START_STATUS=0
export CUA_TEST_START_OUTPUT=
export CUA_TEST_STATUS_MODE=fail
run_check console
grep -Fq 'later installer step ran' "$tmp/console-output"
grep -Fq 'no graphical session was active' "$tmp/console-output"
if grep -Fq -- '--user start cua-driver.service' "$tmp/console-systemctl.log"; then
  echo 'the console check started cua-driver outside its graphical session' >&2
  exit 1
fi

echo 'cua-driver package layout, default dependency, session lifecycle and nonfatal start-check assertions passed.'
