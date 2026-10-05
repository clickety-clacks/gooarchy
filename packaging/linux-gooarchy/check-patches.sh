#!/bin/bash
# Check that linux-gooarchy's sources and patch series are sound, without building: download the
# kernel release and check its signature and checksum, check out Omarchy's package at the pinned
# commit and check its patch signatures, then apply Omarchy's patches in their order and
# Gooarchy's after them, exactly as the PKGBUILD's prepare() does (patch --fuzz=0). Runs on any
# Linux machine with git, curl, gpg, xz and patch (it doesn't need x86_64). Work directory:
# $GOOARCHY_KERNEL_CHECK (default ~/.cache/gooarchy/kernel-check); exits 1 on any failure.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
work=${GOOARCHY_KERNEL_CHECK:-${XDG_CACHE_HOME:-$HOME/.cache}/gooarchy/kernel-check}
eval "$(sed -n '/^# --- pinned by bump.py/,/^# --- end of pinned block/p' "$here/PKGBUILD")"
[[ $pkgver != *rc* ]] || { echo "check-patches.sh doesn't handle release candidates yet" >&2; exit 1; }
src=linux-$pkgver
major=${pkgver%%.*}
mkdir -p "$work"
cd "$work"
export GNUPGHOME=$work/gnupg
rm -rf "$GNUPGHOME" && mkdir -m700 "$GNUPGHOME"
gpg --quiet --import "$here"/keys/pgp/*.asc

echo "== kernel $pkgver"
[[ -f $src.tar.xz ]] || curl -fsSL -o "$src.tar.xz" "https://cdn.kernel.org/pub/linux/kernel/v$major.x/$src.tar.xz"
curl -fsSL -o "$src.tar.sign" "https://cdn.kernel.org/pub/linux/kernel/v$major.x/$src.tar.sign"
echo "${_kernel_sha256sums[0]}  $src.tar.xz" | sha256sum -c --quiet
xz -dc "$src.tar.xz" | gpg --quiet --verify "$src.tar.sign" - 2>&1 | grep -E "Good signature|BAD" || true
xz -dc "$src.tar.xz" | gpg --quiet --verify "$src.tar.sign" - 2>/dev/null

echo "== Omarchy's package at $_omarchy_commit"
[[ -d omarchy-pkgs/.git ]] || git clone --quiet https://github.com/omacom/omarchy-pkgs.git omarchy-pkgs
git -C omarchy-pkgs fetch --quiet origin
git -C omarchy-pkgs -c advice.detachedHead=false checkout --quiet --force "$_omarchy_commit"
omarchy=omarchy-pkgs/pkgbuilds/linux-omarchy
theirs=$(sed -n 's/^pkgver=//p' "$omarchy/PKGBUILD")-$(sed -n 's/^pkgrel=//p' "$omarchy/PKGBUILD")
[[ $theirs == "$pkgver-$_omarchy_pkgrel" ]] || { echo "Omarchy's package is $theirs, ours says $pkgver-$_omarchy_pkgrel" >&2; exit 1; }
mapfile -t ours_omarchy < <(grep -oE '^  [0-9]{4}-[^ {]+\.patch' "$omarchy/PKGBUILD" | sed 's/^  //')
listed=$(printf '%s\n' "${ours_omarchy[@]}" | sort)
present=$(cd "$omarchy" && ls *.patch | sort)
[[ $listed == "$present" ]] || { echo "Omarchy's patch files and PKGBUILD list differ:"; diff <(echo "$listed") <(echo "$present"); exit 1; }
keyring=$work/omarchy-keyring.gpg
rm -f "$keyring"
for key in "$omarchy"/keys/pgp/*.asc; do gpg --dearmor <"$key" >>"$keyring"; done
for p in "${ours_omarchy[@]}"; do
  gpgv --quiet --keyring "$keyring" "$omarchy/$p.sig" "$omarchy/$p" 2>/dev/null || { echo "bad signature: $p" >&2; exit 1; }
done
echo "${#ours_omarchy[@]} Omarchy patches, all signatures good"

echo "== applying"
rm -rf "$src"
tar -xJf "$src.tar.xz"
for p in "${ours_omarchy[@]}"; do
  patch -d "$src" -Np1 --fuzz=0 --quiet <"$omarchy/$p" || { echo "Omarchy's $p doesn't apply" >&2; exit 1; }
done
echo "Omarchy's patches apply"
for p in "${_gooarchy_patches[@]}"; do
  out=$(patch -d "$src" -Np1 --fuzz=0 <"$here/patches/$p") || { echo "$out"; echo "Gooarchy's $p doesn't apply" >&2; exit 1; }
  echo "Gooarchy's $p applies:"
  echo "$out" | sed 's/^/  /'
done
echo "== all good: linux-gooarchy $pkgver-$_omarchy_pkgrel.$_gooarchy_rel"
