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
  pacman -Qq "$1" >/dev/null 2>&1
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

download_repository_packages() {
  local cache=$1 filename_output filename
  shift
  local -a filenames=()
  REPOSITORY_PACKAGE_ARCHIVES=()
  filename_output=$(pacman -Sp --nodeps --print-format '%f' "$@") || {
    echo "Gooarchy's repository packages could not be resolved: $*" >&2
    return 1
  }
  mapfile -t filenames <<<"$filename_output"
  if ((${#filenames[@]} != $#)); then
    echo "Gooarchy's repository returned an unexpected package list for: $*" >&2
    return 1
  fi
  for filename in "${filenames[@]}"; do
    if [[ -z $filename || $filename == */* ]]; then
      echo "Pacman returned an invalid repository package filename for: $*" >&2
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
