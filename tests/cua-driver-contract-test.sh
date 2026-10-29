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
cat >"$tmp/release/cua-driver" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CUA_TEST_UPSTREAM_LOG"
EOF
printf '%s\n' fixture >"$tmp/release/cua-cursor-theme"
printf '%s\n' fixture >"$tmp/release/libcua_driver_sdk.so"
printf '%s\n' fixture >"$tmp/release/cua_driver_node_runtime.node"
chmod +x "$tmp/release/cua-driver" "$tmp/release/cua-cursor-theme"
printf '%s\n' fixture >"$tmp/release/wayland-helper/extension.js"
tar -czf "$tmp/src/cua-driver-rs-${pkgver}-linux-x86_64-binary.tar.gz" -C "$tmp/release" .
cp -- "$service" "$tmp/src/cua-driver.service"
cp -- "$(dirname -- "$recipe")/cua-driver-wrapper.sh" "$tmp/src/cua-driver-wrapper.sh"
printf 'MIT License\nfixture\n' >"$tmp/src/LICENSE.md"

srcdir=$tmp/src
pkgdir=$tmp/pkg
package
[[ -x $pkgdir/usr/lib/cua-driver/cua-driver-upstream ]]
[[ -x $pkgdir/usr/lib/cua-driver/cua-driver ]]
[[ $(readlink "$pkgdir/usr/bin/cua-driver") == /usr/lib/cua-driver/cua-driver ]]
[[ $(readlink "$pkgdir/usr/bin/cua-cursor-theme") == /usr/lib/cua-driver/cua-cursor-theme ]]
[[ $(readlink "$pkgdir/usr/lib/systemd/user/graphical-session.target.wants/cua-driver.service") == ../cua-driver.service ]]
cmp -- "$service" "$pkgdir/usr/lib/systemd/user/cua-driver.service"
cmp -- "$tmp/src/LICENSE.md" "$pkgdir/usr/share/licenses/cua-driver/LICENSE"

package_archive=
if command -v makepkg >/dev/null 2>&1; then
  mkdir -p "$tmp/sources" "$tmp/build" "$tmp/packages"
  (
    cd "$(dirname "$recipe")"
    SRCDEST=$tmp/sources BUILDDIR=$tmp/build PKGDEST=$tmp/packages \
      makepkg --noconfirm --force --cleanbuild --nosign
  )
  archive=$(find "$tmp/packages" -type f -name 'cua-driver-0.38.0-1-x86_64.pkg.tar.*' -print -quit)
  [[ -n $archive && -s $archive ]]
  package_archive=$archive
  bsdtar -xOf "$archive" .PKGINFO >"$tmp/pkginfo"
  grep -Fxq 'pkgname = cua-driver' "$tmp/pkginfo"
  grep -Fxq 'pkgver = 0.38.0-1' "$tmp/pkginfo"
  bsdtar -tf "$archive" | grep -Eq '(^|/)usr/lib/systemd/user/graphical-session.target.wants/cua-driver.service$'
  bsdtar -tf "$archive" | grep -Eq '(^|/)usr/lib/cua-driver/cua-driver$'
  bsdtar -tf "$archive" | grep -Eq '(^|/)usr/lib/cua-driver/cua-driver-upstream$'
  sha256sum "$archive"
else
  echo 'makepkg unavailable; unsigned archive build skipped.'
fi

bash "$repo_root/tests/cua-driver-pacman-ownership-test.sh"
bash "$repo_root/tests/cua-driver-install-start-check-test.sh"
echo 'cua-driver package layout and default repository wiring assertions passed.'
