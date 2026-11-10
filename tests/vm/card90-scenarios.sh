#!/bin/bash
# WI854 post-release guest scenarios. Invoke the copy at ~/gooarchy/tests/vm/card90-scenarios.sh
# through unchanged tests/vm/run.sh ssh. Use a fresh disposable guest and GOOARCHY_VM_DIR per case.
set -Eeuo pipefail

case_name=${1:?case required}
run_id=${2:?run id required}
shift 2
[[ $run_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { echo 'invalid run id' >&2; exit 2; }
[[ ${CARD90_DISPOSABLE_GUEST:-} == yes ]] || { echo 'refusing: set CARD90_DISPOSABLE_GUEST=yes only inside the admitted disposable guest' >&2; exit 2; }
[[ $HOME == /* ]] || { echo 'HOME must be absolute' >&2; exit 2; }

evidence_mount=/var/cache/pacman/vm-test
mountpoint -q "$evidence_mount" || { echo 'scenario evidence mount is absent' >&2; exit 2; }
evidence_parent=$evidence_mount/card90-evidence
[[ ! -L $evidence_parent ]] || { echo 'scenario evidence parent must not be a symlink' >&2; exit 2; }
mkdir -p "$evidence_parent"
evidence_parent=$(realpath -- "$evidence_parent")
[[ $evidence_parent == "$evidence_mount"/card90-evidence ]] || { echo 'scenario evidence parent escaped the VM cache mount' >&2; exit 2; }
evidence=$evidence_parent/$run_id
verify_phase=0
case "$case_name" in verify-snapshot-boot|verify-update-login) verify_phase=1 ;; esac
if (( verify_phase )); then
  [[ -d $evidence && ! -L $evidence && -f $evidence/.owner && ! -L $evidence/.owner && -f $evidence/observations.txt ]] || {
    echo "verification phase requires the existing scenario evidence directory: $evidence" >&2; exit 2;
  }
  [[ $(<"$evidence/.owner") == "$run_id" ]] || { echo 'verification phase run-id ownership mismatch' >&2; exit 2; }
else
  [[ ! -e $evidence && ! -L $evidence ]] || { echo "scenario evidence already exists; refusing reuse: $evidence" >&2; exit 2; }
  mkdir -- "$evidence"
  chmod 700 "$evidence"
  printf '%s\n' "$run_id" >"$evidence/.owner"
fi

fail() {
  record "RESULT case=$case_name run_id=$run_id outcome=FAIL reason=$*"
  echo "FAIL: $*" >&2
  exit 1
}
unreached() {
  record "RESULT case=$case_name run_id=$run_id outcome=NOT_REACHED reason=$*"
  exit 3
}
pkgver() { pacman -Q -- "$1" | awk 'NR==1 {print $2}'; }
expect_pkgver() {
  local name=$1 want=$2 got
  got=$(pkgver "$name" 2>/dev/null) || unreached "$name is not installed in the expected guest baseline"
  [[ $got == "$want" ]] || unreached "$name version mismatch: expected $want, got $got"
}
pair() { printf 'wayfire=%s scottland=%s\n' "$(pkgver wayfire)" "$(pkgver scottland)"; }
record() { printf '%s\n' "$*" | tee -a "$evidence/observations.txt"; }
record "START case=$case_name run_id=$run_id source=2eaf752afd82384b1a4a947373c2cdfa0980d59c"
capture_update() {
  local outfile=$1 rc=0
  shift
  if printf 'yes\n' | "$@" >"$evidence/$outfile" 2>&1; then rc=0; else rc=$?; fi
  printf '%s\n' "$rc" >"$evidence/$outfile.exit"
  cat "$evidence/$outfile"
  return "$rc"
}
require_archives() {
  local wp=$1 wh=$2 wv=$3 sp=$4 sh=$5 sv=$6 manifest=$7 mh=$8 wpkg wpver spkg spver deps real path got
  [[ $wh =~ ^[0-9a-f]{64}$ && $sh =~ ^[0-9a-f]{64}$ && $mh =~ ^[0-9a-f]{64}$ ]] || unreached 'fixture SHA-256 inputs are malformed'
  [[ -f $wp && ! -L $wp && -f $sp && ! -L $sp ]] || unreached 'fixture pair archives must be regular files'
  [[ -f $manifest && ! -L $manifest ]] || unreached 'exact rollback fixture manifest is absent'
  for path in "$wp" "$sp" "$manifest"; do
    real=$(realpath -- "$path")
    [[ $real == "$evidence_mount"/* ]] || unreached "fixture path is outside this VM run's shared cache: $real"
  done
  got=$(sha256sum -- "$wp" | awk '{print $1}'); [[ $got == "$wh" ]] || unreached "Wayfire fixture SHA-256 mismatch: $got"
  got=$(sha256sum -- "$sp" | awk '{print $1}'); [[ $got == "$sh" ]] || unreached "Scottland fixture SHA-256 mismatch: $got"
  got=$(sha256sum -- "$manifest" | awk '{print $1}'); [[ $got == "$mh" ]] || unreached "fixture manifest SHA-256 mismatch: $got"
  grep -F "$wh" "$manifest" >/dev/null && grep -F "$sh" "$manifest" >/dev/null || unreached 'fixture manifest does not bind both archive hashes'
  grep -E 'https?://' "$manifest" >/dev/null || unreached 'fixture manifest does not identify an archive source'
  record "fixture manifest=$manifest sha256=$got"
  read -r wpkg wpver _ < <(pacman -Qp -- "$wp") || unreached "cannot read Wayfire archive metadata: $wp"
  [[ $wpkg == wayfire && $wpver == "$wv" ]] || unreached 'Wayfire fixture package/version differs from the bound inputs'
  read -r spkg spver _ < <(pacman -Qp -- "$sp") || unreached "cannot read Scottland archive metadata: $sp"
  [[ $spkg == scottland && $spver == "$sv" ]] || unreached 'Scottland fixture package/version differs from the bound inputs'
  deps=$(pacman -Qip -- "$sp" | sed -n 's/^Depends On *: *//p')
  [[ $deps == *"wayfire=$wv"* ]] || unreached "Scottland fixture does not declare exact Wayfire dependency $wv"
  record "fixture Wayfire archive=$wp source_manifest=$manifest sha256=$wh package=$wpkg version=$wpver"
  record "fixture Scottland archive=$sp source_manifest=$manifest sha256=$sh package=$spkg version=$spver dependency=$deps"
}
downgrade_pair() {
  local wp=$1 sp=$2
  local rc=0
  if sudo -n pacman -U --noconfirm -- "$wp" "$sp" >"$evidence/fixture-install.log" 2>&1; then
    cat "$evidence/fixture-install.log"
  else
    rc=$?
    cat "$evidence/fixture-install.log"
    unreached "guest fixture pair installation failed before scenario assertions (exit $rc)"
  fi
  record "fixture baseline after install: $(pair)"
}
latest_wayfire() { pacman -Si wayfire | awk -F ': *' '$1=="Version" {print $2; exit}'; }
latest_snapshot_id() {
  gooarchy boot snapshot list | awk '$2 ~ /^gooarchy-update-/ && $1 ~ /^[0-9]+$/ { if ($1 > best) best=$1 } END { if (best) print best }'
}
local_update_preflight() {
  local plan=$HOME/.local/state/gooarchy/repository-plan.sh mode fstype root_uuid store_uuid
  [[ -f $plan ]] || unreached 'saved Gooarchy repository plan is absent'
  mode=$(sed -n 's/^GOOARCHY_BUILD_LOCAL_SCOTTLAND=//p' "$plan" | tail -n1)
  record "repository plan=$plan sha256=$(sha256sum "$plan" | awk '{print $1}') local_scottland=$mode"
  [[ $mode == 1 ]] || unreached 'saved plan does not select local Scottland; this scenario requires the local rebuild path'
  fstype=$(findmnt -n -o FSTYPE --target /) || unreached 'cannot read root filesystem type'
  record "root filesystem=$fstype"
  if [[ $fstype == btrfs ]]; then
    mountpoint -q /.snapshots || unreached 'Btrfs root has no mounted /.snapshots fixture'
    root_uuid=$(findmnt -n -o UUID --target /); store_uuid=$(findmnt -n -o UUID --target /.snapshots)
    [[ -n $root_uuid && $root_uuid == "$store_uuid" ]] || unreached 'Btrfs /.snapshots is not on the root filesystem'
    btrfs subvolume show / >/dev/null 2>&1 && btrfs subvolume show /.snapshots >/dev/null 2>&1 || unreached 'required Btrfs subvolume fixture is absent'
    record 'Btrfs snapshot layout precondition: root and same-filesystem /.snapshots subvolumes present'
  else
    record "non-Btrfs update path: release-note no-snapshot behavior expected for $fstype"
  fi
}

if (( ! verify_phase )); then
  package_version=$(pkgver gooarchy 2>/dev/null) || unreached 'Gooarchy package is absent from the expected guest baseline'
  [[ $package_version == 0.0.1.r329.g2eaf752-1 ]] || unreached "wrong Gooarchy package source/version: $package_version"
  expect_pkgver scottland 0.4.1-1
  expect_pkgver scottland-omarchy 0.4.1-1
  expect_pkgver scottland-sunlight 0.4.1-1
  expect_pkgver gooarchy-flavorings 0.2.2-1
  pacman -Q gooarchy wayfire scottland scottland-omarchy scottland-sunlight gooarchy-flavorings >"$evidence/packages.txt" ||
    unreached 'one or more required package identities are absent from the guest baseline'
  scottland --version >"$evidence/scottland-runtime-version.txt" 2>&1 || unreached 'Scottland runtime version read failed'
  scottland-source --version >"$evidence/scottland-source-tool-version.txt" 2>&1 || unreached 'Scottland source-tool version read failed'
fi

case "$case_name" in
  wayfire-rollback-update)
    [[ $# == 8 ]] || unreached 'usage: wayfire-rollback-update RUN_ID WAYFIRE_ARCHIVE WAYFIRE_SHA WAYFIRE_VERSION SCOTTLAND_ARCHIVE SCOTTLAND_SHA SCOTTLAND_VERSION FIXTURE_MANIFEST MANIFEST_SHA'
    local_update_preflight
    require_archives "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
    wayfire_version=$3; scottland_version=$6
    downgrade_pair "$1" "$4"
    before=$(pair); old_wayfire=$(pkgver wayfire); target=$(latest_wayfire) || unreached 'repository Wayfire version is unavailable'
    [[ $old_wayfire == "$wayfire_version" ]] || unreached "fixture Wayfire version mismatch: expected $wayfire_version, got $old_wayfire"
    [[ -n $target && $(vercmp "$old_wayfire" "$target") -lt 0 ]] || unreached 'fixture Wayfire is not older than the current repository candidate'
    [[ $(pkgver scottland) == "$scottland_version" ]] || unreached 'fixture Scottland version did not install exactly'
    source_before=$(cat "$evidence/scottland-runtime-version.txt")
    record "update fixture result before=$before repository_wayfire=$target runtime_source_before=$(printf %q "$source_before")"
    capture_update wayfire-update.log env gooarchy update || fail 'gooarchy update failed'
    after=$(pair)
    printf '%s\n' "$after" >"$evidence/wayfire-rollback-update.expected-pair"
    [[ $(pkgver wayfire) == "$target" ]] || fail 'Wayfire did not reach the current repository version'
    source_after=$(scottland --version 2>&1)
    [[ $source_after == "$source_before" ]] || fail 'configured Scottland runtime identity changed unexpectedly'
    pgrep -u "$(id -u)" -x wayfire >/dev/null || fail 'running Wayfire session is not present after update'
    grep -q 'Gooarchy update completed' "$evidence/wayfire-update.log" || fail 'completion message missing'
    if [[ $(findmnt -n -o FSTYPE --target /) == btrfs ]]; then
      id=$(latest_snapshot_id); [[ -n $id ]] || fail 'update snapshot not listed'
      record "update snapshot id: $id"
    else
      grep -q 'No Btrfs snapshot was taken' "$evidence/wayfire-update.log" || fail 'non-Btrfs notice missing'
    fi
    record "UNPROVED: working Wayfire session after a new login; current process check only proves the pre-existing session remains present"
    record "RESULT case=wayfire-rollback-update run_id=$run_id outcome=PASS_UPDATE before=[$before] after=[$after] source_identity_unchanged=yes; post-login-session=UNPROVED"
    ;;

  rebuild-failure)
    [[ $# == 8 ]] || unreached 'usage: rebuild-failure RUN_ID WAYFIRE_ARCHIVE WAYFIRE_SHA WAYFIRE_VERSION SCOTTLAND_ARCHIVE SCOTTLAND_SHA SCOTTLAND_VERSION FIXTURE_MANIFEST MANIFEST_SHA'
    local_update_preflight
    require_archives "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
    wayfire_version=$3; scottland_version=$6
    downgrade_pair "$1" "$4"
    before=$(pair); old_wayfire=$(pkgver wayfire); target=$(latest_wayfire) || unreached 'repository Wayfire version is unavailable'
    [[ $old_wayfire == "$wayfire_version" ]] || unreached "fixture Wayfire version mismatch: expected $wayfire_version, got $old_wayfire"
    [[ $(pkgver scottland) == "$scottland_version" ]] || unreached 'fixture Scottland version did not install exactly'
    [[ -n $target && $(vercmp "$old_wayfire" "$target") -lt 0 ]] || unreached 'fixture is not older than current repository Wayfire'
    source_status=$(scottland-source status 2>&1) || unreached 'Scottland source mechanism is unavailable'
    printf '%s\n' "$source_status" >"$evidence/scottland-source-before.txt"
    rust_conf=/etc/makepkg.conf.d/rust.conf
    [[ -f $rust_conf && ! -L $rust_conf ]] || unreached 'Arch Rust makepkg configuration fixture is absent'
    cp -- "$rust_conf" "$evidence/rust.conf.before" || unreached 'could not preserve the guest Rust config in run evidence'
    rust_conf_before=$(sha256sum "$rust_conf" | awk '{print $1}')
    printf '\nRUSTFLAGS="--card90-intentional-compile-error"\n' | sudo -n tee -a "$rust_conf" >/dev/null ||
      unreached 'could not apply the guest-local compiler failure fixture'
    rust_conf_after=$(sha256sum "$rust_conf" | awk '{print $1}')
    effective_rustflags=$(bash -c 'set -e; source /etc/makepkg.conf; for fragment in /etc/makepkg.conf.d/*.conf; do [[ -f $fragment ]] || continue; source "$fragment"; done; printf %s "$RUSTFLAGS"') ||
      unreached 'could not read makepkg.conf and its drop-in fragments in load order'
    [[ $effective_rustflags == *--card90-intentional-compile-error* ]] || unreached 'makepkg did not load the guest-local compiler-failure flag'
    record "guest makepkg rust.conf sha256_before=$rust_conf_before sha256_after=$rust_conf_after effective_flag=--card90-intentional-compile-error"
    pacman_lines=$(wc -l </var/log/pacman.log)
    rc=0
    if printf 'yes\n' | env gooarchy update >"$evidence/rebuild-failure.log" 2>&1; then rc=0; else rc=$?; fi
    printf '%s\n' "$rc" >"$evidence/rebuild-failure.log.exit"
    (( rc != 0 )) || fail 'guest-local compiler failure did not fail the update'
    grep -F 'card90-intentional-compile-error' "$evidence/rebuild-failure.log" >/dev/null || fail 'update log does not show the injected flag reaching the compiler'
    grep -Ei "error:.*card90-intentional-compile-error|card90-intentional-compile-error.*error:" "$evidence/rebuild-failure.log" >/dev/null || fail 'compiler error is not attributed to the injected flag in the same diagnostic'
    grep -q 'restored the previous Wayfire and Scottland packages' "$evidence/rebuild-failure.log" || fail 'update did not report pair restoration'
    [[ $(pair) == "$before" ]] || fail "installed pair was not restored: expected [$before], got [$(pair)]"
    printf '%s\n' "$before" >"$evidence/rebuild-failure.expected-pair"
    tail -n +$((pacman_lines + 1)) /var/log/pacman.log >"$evidence/pacman-after-update-start.log"
    grep -F "upgraded wayfire ($old_wayfire -> $target)" "$evidence/pacman-after-update-start.log" >/dev/null || fail 'pacman log does not prove Wayfire changed before rebuild failure'
    if [[ $(findmnt -n -o FSTYPE --target /) == btrfs ]]; then
      id=$(latest_snapshot_id); [[ -n $id ]] || fail 'pre-update Btrfs snapshot not listed'
      printf '%s\n' "$id" >"$evidence/failure-snapshot-id"
      record "pre-update Btrfs snapshot id=$id"
    else
      grep -q 'No Btrfs snapshot was taken' "$evidence/rebuild-failure.log" || fail 'non-Btrfs notice missing'
    fi
    record "UNPROVED: machine bootability and working session after reboot; run the unchanged wrapper reboot/check/login-check phases before claiming them"
    record "RESULT case=rebuild-failure run_id=$run_id outcome=PASS_REBUILD_RECOVERY before=[$before] after=[$(pair)] compiler_cause=confirmed; post-reboot-bootability=UNPROVED"
    ;;

  missing-cache)
    [[ $# == 1 && $1 =~ ^(wayfire|scottland)$ ]] || unreached 'usage: missing-cache RUN_ID wayfire|scottland'
    local_update_preflight
    missing_pkg=$1; missing_ver=$(pkgver "$missing_pkg"); before=$(pair)
    mapfile -t caches < <(pacman-conf CacheDir)
    caches+=("$HOME/.cache/gooarchy/update-recovery" "$HOME/.cache/gooarchy/build/scottland/packaging/arch")
    found=0
    for dir in "${caches[@]}"; do
      [[ -d $dir ]] || continue
      real_dir=$(realpath -- "$dir")
      [[ $real_dir == "$evidence_mount"/* || $real_dir == "$HOME/.cache/gooarchy"/* ]] ||
        unreached "archive cache path is outside this disposable guest/run: $real_dir"
      while IFS= read -r archive; do
        read -r name version _ < <(pacman -Qp -- "$archive" 2>/dev/null) || continue
        if [[ $name == "$missing_pkg" && $version == "$missing_ver" ]]; then
          archive_sha=$(sha256sum -- "$archive" | awk '{print $1}')
          sudo -n rm -- "$archive"
          [[ ! -e $archive ]] || fail "could not remove fixture archive: $archive"
          record "removed exact archive path=$archive sha256=$archive_sha"
          found=1
        fi
      done < <(find "$dir" -maxdepth 1 -type f -name "$missing_pkg-*.pkg.tar*" ! -name '*.sig' -print 2>/dev/null)
    done
    (( found == 1 )) || unreached "no cached $missing_pkg $missing_ver archive exists to remove"
    remaining=0
    for dir in "${caches[@]}"; do
      [[ -d $dir ]] || continue
      while IFS= read -r archive; do
        read -r name version _ < <(pacman -Qp -- "$archive" 2>/dev/null) || continue
        [[ $name == "$missing_pkg" && $version == "$missing_ver" ]] && remaining=1
      done < <(find "$dir" -maxdepth 1 -type f -name "$missing_pkg-*.pkg.tar*" ! -name '*.sig' -print 2>/dev/null)
    done
    (( remaining == 0 )) || unreached "an exact $missing_pkg $missing_ver archive remains in a recovery/cache location"
    pacman_lines=$(wc -l </var/log/pacman.log)
    rc=0
    if printf 'yes\n' | gooarchy update >"$evidence/missing-cache.log" 2>&1; then rc=0; else rc=$?; fi
    printf '%s\n' "$rc" >"$evidence/missing-cache.log.exit"
    (( rc != 0 )) || fail 'update unexpectedly succeeded with the required archive absent'
    grep -F "installed $missing_pkg $missing_ver archive is missing" "$evidence/missing-cache.log" >/dev/null || fail 'missing archive and version not named'
    [[ $(pair) == "$before" ]] || fail "package pair changed before refusal: expected [$before], got [$(pair)]"
    [[ $(wc -l </var/log/pacman.log) == "$pacman_lines" ]] || fail 'pacman log changed before the missing-archive refusal'
    record "RESULT case=missing-cache run_id=$run_id outcome=PASS_REFUSAL missing=$missing_pkg@$missing_ver pair_unchanged=yes pacman_log_unchanged=yes"
    ;;

  boot-snapshot)
    if [[ $(findmnt -n -o FSTYPE --target /) != btrfs ]]; then
      unreached "guest root filesystem is $(findmnt -n -o FSTYPE --target /); Btrfs snapshot behavior is not applicable"
    fi
    mountpoint -q /.snapshots || unreached 'Btrfs fixture lacks mounted /.snapshots'
    root_uuid=$(findmnt -n -o UUID --target /); store_uuid=$(findmnt -n -o UUID --target /.snapshots)
    [[ -n $root_uuid && $root_uuid == "$store_uuid" ]] || unreached 'Btrfs /.snapshots is not on the root filesystem'
    btrfs subvolume show / >/dev/null && btrfs subvolume show /.snapshots >/dev/null || unreached 'required Btrfs subvolumes are absent'
    root_id=$(btrfs subvolume show / | awk -F: '/Subvolume ID/ {gsub(/[[:space:]]/,"",$2);print $2;exit}')
    default_id=$(btrfs subvolume get-default / | awk '/ID/ {print $2;exit}')
    [[ -n $root_id && $root_id == "$default_id" ]] || unreached 'fixture root is not using Btrfs default subvolume; restore is expected to refuse'
    if grep -E '^[[:space:]]*[^#].*[[:space:]]/[[:space:]].*subvol=' /etc/fstab >/dev/null ||
       grep -E '(^| )rootflags=[^ ]*subvol=' /proc/cmdline >/dev/null; then
      unreached 'boot configuration explicitly selects a root subvolume; release notes require restore to stop safely'
    fi
    boot_before=$(find /boot -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print $1}')
    snapshot_label="card90-$run_id"
    gooarchy boot snapshot take "$snapshot_label" >"$evidence/boot-snapshot-take.log" 2>&1 || fail 'snapshot take command failed'
    gooarchy boot snapshot list >"$evidence/boot-snapshot-list-before-restore.log" 2>&1 || fail 'snapshot list before restore failed'
    id=$(awk -v label="gooarchy-$snapshot_label" '$1 ~ /^[0-9]+$/ && $2 ~ "^" label { print $1; exit }' "$evidence/boot-snapshot-list-before-restore.log")
    [[ -n $id ]] || fail 'created snapshot is not listed'
    if ! printf 'yes\n' | gooarchy boot snapshot restore "$id" >"$evidence/boot-snapshot-restore.log" 2>&1; then fail 'snapshot restore command failed'
    fi
    grep -qi 'next boot' "$evidence/boot-snapshot-restore.log" || fail 'restore did not report next-boot selection'
    boot_after=$(find /boot -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print $1}')
    [[ $boot_before == "$boot_after" ]] || fail 'boot files changed during snapshot restore selection'
    gooarchy boot snapshot list >"$evidence/boot-snapshot-list-after-restore.log" 2>&1 || fail 'snapshot list after restore failed'
    grep -q 'gooarchy-before-restore-' "$evidence/boot-snapshot-list-after-restore.log" || fail 'restore did not create/list its safety snapshot'
    printf '%s\n' "$id" >"$evidence/snapshot-selected-id"
    record "UNPROVED: selected snapshot is running; verify only after the unchanged wrapper reboot and root subvolume ID readback"
    record "RESULT case=boot-snapshot run_id=$run_id outcome=PASS_SELECTION snapshot_id=$id next_boot_restore_selected=yes boot_file_digest_unchanged=yes; post-boot-restore=UNPROVED"
    ;;

  source-edit-rollback)
    [[ $# == 0 ]] || unreached 'usage: source-edit-rollback RUN_ID'
    before=$(scottland --version | awk '{print $NF}')
    source_status=$(scottland-source status 2>&1) || fail 'Scottland source status failed'
    printf '%s\n' "$source_status" >"$evidence/source-before.txt"
    source_member=$(scottland-source edit scottland --path 2>"$evidence/source-path.stderr") || unreached 'supported source tool cannot report the scottland member directory'
    [[ -d $source_member ]] || unreached 'reported scottland member directory is absent'
    source_root=$(git -C "$source_member" rev-parse --show-toplevel 2>"$evidence/source-root.stderr") || unreached 'could not locate the guest-local source clone from the tool member directory'
    source_root=$(realpath -- "$source_root"); source_member=$(realpath -- "$source_member")
    [[ $source_member == "$source_root"/* ]] || unreached 'reported tool member is outside the source clone'
    [[ -z $(git -C "$source_root" status --porcelain) ]] || unreached 'guest-local source working clone is not clean before the scenario'
    source_head=$(git -C "$source_root" rev-parse HEAD)
    source_file=$source_member/src/main.rs
    [[ -f $source_file ]] || unreached 'scottland tool source main.rs is absent'
    marker_text="// WI854 Card90 guest scenario $run_id"
    ! grep -Fq "$marker_text" "$source_file" || unreached 'run marker already exists in source checkout'
    printf '\n%s\n' "$marker_text" >>"$source_file"
    scottland-source edit scottland --no-editor --message "WI854 Card90 guest source edit $run_id" >"$evidence/source-edit.log" 2>&1 || fail 'supported source edit/rebuild failed'
    edited=$(scottland --version | awk '{print $NF}')
    [[ $edited != "$before" ]] || fail 'rebuilt Scottland identity did not change'
    scottland-source status >"$evidence/source-after-edit.txt" 2>&1
    scottland-source rollback scottland --to "$before" --reason "WI854 Card90 guest scenario rollback $run_id" >"$evidence/source-rollback.log" 2>&1 || fail 'supported source rollback/rebuild failed'
    after=$(scottland --version | awk '{print $NF}')
    [[ $after == "$before" ]] || fail "rollback identity mismatch: expected $before, got $after"
    scottland-source status >"$evidence/source-after-rollback.txt" 2>&1
    record "RESULT case=source-edit-rollback run_id=$run_id outcome=PASS source_head=$source_head installed=$before->$edited->$after"
    record 'Limit: this is source-mechanism/build-identity evidence; it does not prove unrelated feature behavior.'
    ;;

  verify-snapshot-boot)
    [[ $# == 0 ]] || unreached 'usage: verify-snapshot-boot RUN_ID after tests/vm/run.sh reboot'
    [[ -f $evidence/snapshot-selected-id ]] || unreached 'no earlier snapshot selection evidence exists for this run'
    id=$(<"$evidence/snapshot-selected-id")
    actual=$(btrfs subvolume show / | awk -F: '/Subvolume ID/ {gsub(/[[:space:]]/,"",$2);print $2;exit}') || fail 'could not read booted root subvolume ID'
    [[ $actual == "$id" ]] || fail "booted root subvolume $actual differs from selected snapshot $id"
    record "RESULT case=verify-snapshot-boot run_id=$run_id outcome=PASS_NEXT_BOOT_RESTORE selected_snapshot_id=$id booted_root_id=$actual"
    ;;

  verify-update-login)
    [[ $# == 1 && $1 =~ ^(wayfire-rollback-update|rebuild-failure)$ ]] || unreached 'usage: verify-update-login RUN_ID prior-case after tests/vm/run.sh reboot/check/login-check'
    case_file=$evidence/$1.expected-pair
    [[ -f $case_file ]] || unreached "expected pair record from prior case $1 is absent"
    expected=$(<"$case_file"); actual=$(pair)
    [[ $actual == "$expected" ]] || fail "post-reboot package pair differs: expected [$expected], got [$actual]"
    pgrep -u "$(id -u)" -x wayfire >/dev/null || fail 'Wayfire process is absent after reboot/login'
    record "RESULT case=verify-update-login run_id=$run_id outcome=PASS_REBOOTED_SESSION prior_case=$1 package_pair=[$actual]; visual/session check still requires unchanged wrapper check and login-check results"
    ;;

  *)
    unreached 'unknown case; choose wayfire-rollback-update, rebuild-failure, missing-cache, boot-snapshot, source-edit-rollback'
    ;;
esac
