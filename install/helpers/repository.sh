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
