#!/bin/bash
# Build linux-gooarchy (and linux-gooarchy-headers) on an x86_64 build or test host. Builds only:
# installing a kernel is a separate, deliberate step. Needs about 35 GB free in the build directory
# while it runs (the kernel build tree; less on disk under btrfs compression) and takes hours: two to
# three with two jobs in a test VM.
#
#   packaging/linux-gooarchy/build.sh      packages land in $GOOARCHY_KERNEL_BUILD (printed)
#
# The build runs in its own directory (PKGBUILD, Gooarchy's patches and attribution, flattened
# for makepkg) with a private GnuPG home holding the kernel release signers' keys from keys/pgp,
# so makepkg can check the kernel tarball's signature without touching the user's keyrings.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
dir=${GOOARCHY_KERNEL_BUILD:-${XDG_CACHE_HOME:-$HOME/.cache}/gooarchy/build/linux-gooarchy}
[[ $(uname -m) == x86_64 ]] || { echo "build.sh: linux-gooarchy is an x86_64 kernel; build it on an x86_64 host" >&2; exit 1; }
rm -rf "$dir/pkg" "$dir"/*.pkg.tar.* "$dir/gnupg"
mkdir -p "$dir"
shopt -s nullglob  # patches/ may be empty
cp "$here/PKGBUILD" "$here/NOTICE.md" "$here/LICENSE.omarchy-pkgs" "$here"/patches/*.patch "$dir/"
export GNUPGHOME=$dir/gnupg
mkdir -m700 "$GNUPGHOME"
gpg --quiet --import "$here"/keys/pgp/*.asc
cd "$dir"
makepkg --syncdeps --rmdeps --noconfirm --needed --cleanbuild --force
makepkg --packagelist
