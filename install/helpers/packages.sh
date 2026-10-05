# Package helpers shared by the steps.

# Package names from a list file: one per line, # comments.
package_list() {
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"
}

# Build the package(s) in a PKGBUILD directory as this user, installing build dependencies for the
# build and removing them afterwards. Leaves the built packages in the directory.
build_package() {
  local dir=$1
  (cd "$dir" && rm -f ./*.pkg.tar.zst && makepkg --syncdeps --rmdeps --noconfirm --needed --force --cleanbuild)
}

# Install built package files. --asdeps marks them as installed for Gooarchy, so removing the
# gooarchy package later takes them along (unless something else needs them).
install_built() {
  sudo pacman -U --noconfirm --needed "$@"
}
