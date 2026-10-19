# Helpers for identifying packages installed from the signed Gooarchy repository.

load_repository_plan() {
  local plan=$GOOARCHY_STATE/repository-plan.sh
  [[ -r $plan ]] || { echo "Gooarchy's repository selection has not been prepared." >&2; return 1; }
  # This file is written by install/packaging/repository.sh and contains only quoted values.
  source "$plan"
}

installed_package_version() {
  pacman -Q "$1" 2>/dev/null | awk '{print $2}'
}

package_is_installed() {
  # pacman -Q NAME accepts a package name or one of its Provides entries. Installer state here
  # tracks exact installed packages, so inspect the package-name list instead of resolving a
  # virtual name through Provides.
  pacman -Qq 2>/dev/null | awk -v wanted="$1" '$0 == wanted { found=1 } END { exit !found }'
}

package_is_repository_copy() {
  local package=$1 info packager validated
  info=$(pacman -Qi "$package" 2>/dev/null) || return 1
  packager=$(awk -F: '$1 ~ /^[[:space:]]*Packager[[:space:]]*$/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<<"$info")
  validated=$(awk -F: '$1 ~ /^[[:space:]]*Validated By[[:space:]]*$/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<<"$info")
  [[ $packager == "$GOOARCHY_REPOSITORY_PACKAGER" && $validated == *Signature* ]]
}

sync_package_field() {
  local package=$1 field=$2 repository=${3:-gooarchy}
  pacman -Si "$repository/$package" 2>/dev/null |
    awk -F: -v wanted="$field" '$1 ~ "^[[:space:]]*" wanted "[[:space:]]*$" {
      sub(/^[^:]*:[[:space:]]*/, ""); print; exit
    }'
}

# Gooarchy's signed archive is inspected before the later Strata AUR step builds
# strata-bin. Keep its hard dependency, but satisfy that one unversioned name
# only while pacman resolves or downloads the bootstrap archive. The `=0` value
# is a resolver placeholder; the actual package is built and installed later.
repository_gooarchy_bootstrap_filename() {
  local package_list package filename gooarchy_filename=
  package_list=$(pacman -Sp --nodeps --assume-installed strata-bin=0 \
    --print-format '%n %f' gooarchy/gooarchy) || return 1

  while read -r package filename; do
    [[ $package == gooarchy ]] || continue
    if [[ -z $filename || $filename == */* || -n $gooarchy_filename ]]; then
      echo "Pacman returned an invalid Gooarchy bootstrap package filename." >&2
      return 1
    fi
    gooarchy_filename=$filename
  done <<<"$package_list"

  if [[ -z $gooarchy_filename ]]; then
    echo "Pacman did not resolve the Gooarchy bootstrap package filename." >&2
    return 1
  fi
  printf '%s\n' "$gooarchy_filename"
}

download_repository_gooarchy_bootstrap() {
  local cache=$1
  sudo pacman -Sw --nodeps --assume-installed strata-bin=0 --noconfirm --cachedir "$cache" gooarchy/gooarchy
}

download_repository_packages() {
  local cache=$1 filename_output package filename target target_package index
  shift
  local -a package_names=() filenames=()
  REPOSITORY_PACKAGE_ARCHIVES=()

  for target in "$@"; do
    target_package=${target##*/}
    target_package=${target_package%%=*}
    if [[ -z $target_package ]]; then
      echo "Gooarchy's repository package target has no package name: $target" >&2
      return 1
    fi
    for package in "${package_names[@]}"; do
      if [[ $package == "$target_package" ]]; then
        echo "Gooarchy's repository package target is duplicated: $target_package" >&2
        return 1
      fi
    done
    package_names+=("$target_package")
    filenames+=("")
  done

  filename_output=$(pacman -Sp --nodeps --print-format '%n %f' "$@") || {
    echo "Gooarchy's repository packages could not be resolved: $*" >&2
    return 1
  }
  while read -r package filename target_package; do
    for index in "${!package_names[@]}"; do
      [[ $package == "${package_names[index]}" ]] || continue
      if [[ -z $filename || -n $target_package || $filename == */* ||
        -n ${filenames[index]} ]]; then
        echo "Pacman returned an invalid or duplicate repository package filename for $package." >&2
        return 1
      fi
      filenames[index]=$filename
    done
  done <<<"$filename_output"

  for index in "${!package_names[@]}"; do
    if [[ -z ${filenames[index]} ]]; then
      echo "Pacman did not resolve Gooarchy repository package ${package_names[index]}." >&2
      return 1
    fi
  done

  sudo pacman -Sw --nodeps --noconfirm --cachedir "$cache" "$@" || return 1
  for filename in "${filenames[@]}"; do
    if [[ ! -s $cache/$filename ]]; then
      echo "Pacman did not cache Gooarchy repository package $filename." >&2
      return 1
    fi
    REPOSITORY_PACKAGE_ARCHIVES+=("$cache/$filename")
  done
}
