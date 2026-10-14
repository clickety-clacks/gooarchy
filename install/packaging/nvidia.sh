# Install Arch's current open NVIDIA driver only when sysfs reports a supported display function.
# This step runs after packaging/base.sh has completed Arch's supported full upgrade.
source "$GOOARCHY_INSTALL/helpers/packages.sh"

NV_OWNED_CONFIG=/etc/mkinitcpio.conf.d/gooarchy-nvidia.conf
NV_MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
NV_KERNELS=()
NV_REPLACED_PACKAGES=()
declare -A NV_PKGBASE=()
declare -A NV_IMAGE_MODULE_SET=()
NV_CONFIG_DYNAMIC=0
NV_USER_CONFIG_SOURCE_FILES=()
NV_CONFIG_SOURCE_FILES=()
declare -A NV_CONFIG_SOURCE_SEEN=()
declare -A NV_CONFIG_PROBE_MODULE_SET=()
NV_CONFIG_PROBE_ERROR=
declare -A NV_PACKAGE_HOOK_FAILURES=()
NV_IMAGE_BACKUP_IMAGES=()
NV_IMAGE_BACKUP_FILES=()
NV_IMAGE_BACKUP_DIRS=()
NV_IMAGE_BACKUP_PRESENT=()

nvidia_fail() {
  report "$*"
  exit 1
}

nvidia_report() {
  report "$*"
}

nvidia_refuse_if_pacman_lock_exists() {
  local lock=/var/lib/pacman/db.lck
  [[ -e $lock || -L $lock ]] || return 0
  nvidia_fail "pacman's database lock is present at $lock. If pacman was interrupted, this is a stale db.lck; Gooarchy left it untouched and made no NVIDIA package, configuration, module, or image change. Confirm no package manager is active, remove the stale lock with sudo rm -f $lock, reinstall the named driver pair with sudo pacman -S nvidia-open-dkms nvidia-utils, then rerun ./install.sh to converge kernel headers and images."
}

nvidia_detect_devices() {
  local path vendor class device boot row
  if [[ ${GOOARCHY_TEST_NVIDIA_DEVICES+x} ]]; then
    # Test-only PCI display-function rows, one per line: vendor,class,device,boot_vga.
    # tests/vm is the only caller; the variable is unset in ordinary installs and reads no real
    # hardware data.
    while IFS= read -r row; do
      [[ -n $row ]] || continue
      row=${row//,/ }
      read -r vendor class device boot <<<"$row"
      [[ -n ${vendor:-} && -n ${class:-} && -n ${device:-} ]] || continue
      boot=${boot:-0}
      printf '%s %s %s %s\n' "$vendor" "$class" "$device" "$boot"
    done <<<"$GOOARCHY_TEST_NVIDIA_DEVICES"
    return
  fi

  for path in /sys/bus/pci/devices/*; do
    [[ -r $path/vendor && -r $path/class && -r $path/device ]] || continue
    vendor=$(<"$path/vendor")
    class=$(<"$path/class")
    [[ $class == 0x03* ]] || continue
    device=$(<"$path/device")
    boot=0
    [[ -r $path/boot_vga ]] && boot=$(<"$path/boot_vga")
    printf '%s %s %s %s\n' "$vendor" "$class" "$device" "$boot"
  done
}

nvidia_collect_devices() {
  local vendor class device boot
  NV_SUPPORTED=()
  NV_LEGACY=()
  NV_BUILTIN=0
  NV_BUILTIN_BOOT=0
  NV_NVIDIA_BOOT=0
  while read -r vendor class device boot; do
    [[ -n ${vendor:-} && -n ${class:-} && -n ${device:-} && $class == 0x03* ]] || continue
    if [[ $vendor == 0x10de ]]; then
      device=${device#0x}
      device=${device,,}
      if [[ $device =~ ^[0-9a-f]{4}$ ]] && ((16#$device >= 0x1e00)); then
        NV_SUPPORTED+=("10de:$device")
      else
        NV_LEGACY+=("10de:$device")
      fi
      [[ $boot == 1 ]] && NV_NVIDIA_BOOT=1
    else
      NV_BUILTIN=1
      [[ $boot == 1 ]] && NV_BUILTIN_BOOT=1
    fi
  done < <(nvidia_detect_devices)
  # A false boot_vga check on the final device leaves the loop body with status 1. Keep
  # set -e callers from treating a normal non-boot NVIDIA device as a failed discovery.
  return 0
}

nvidia_list() {
  local item first=1
  for item in "$@"; do
    ((first)) || printf ', '
    printf '%s' "$item"
    first=0
  done
}

nvidia_pacman_version() {
  local output
  output=$(pacman -Q "$1" 2>/dev/null) || return 1
  printf '%s\n' "${output#* }"
}

nvidia_sync_version() {
  local output
  output=$(LC_ALL=C pacman -Si "$1" 2>/dev/null) || return 1
  awk '
    /^[[:space:]]*Version[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/[[:space:]]+$/, "")
      if (length) { print; found=1; exit }
    }
    END { if (!found) exit 1 }
  ' <<<"$output"
}

nvidia_sync_installed_size_kb() {
  local output
  output=$(LC_ALL=C pacman -Si "$1" 2>/dev/null) || return 1
  awk -F: '
    $1 ~ /^[[:space:]]*Installed Size[[:space:]]*$/ {
      value=$2
      sub(/^[[:space:]]+/, "", value)
      split(value, part, /[[:space:]]+/)
      amount=part[1]+0
      unit=part[2]
      if (unit ~ /^KiB/) print int(amount)
      else if (unit ~ /^MiB/) print int(amount*1024)
      else if (unit ~ /^GiB/) print int(amount*1024*1024)
      else if (unit ~ /^B/) print int(amount/1024)
      exit
    }
  ' <<<"$output"
}

nvidia_module_version_from_package() {
  local version=$1
  version=${version#*:}
  printf '%s\n' "${version%-*}"
}

nvidia_driver_module_files() {
  find "$1" -type f \
    \( -name 'nvidia.ko*' -o -name 'nvidia_modeset.ko*' -o -name 'nvidia_uvm.ko*' -o -name 'nvidia_drm.ko*' \
       -o -name 'nvidia-modeset.ko*' -o -name 'nvidia-uvm.ko*' -o -name 'nvidia-drm.ko*' \) \
    -print0
}

nvidia_is_known_package() {
  case $1 in
    nvidia-utils | nvidia-open-dkms | nvidia-open | nvidia-open-lts) return 0 ;;
    *) return 1 ;;
  esac
}

nvidia_find_foreign_driver_packages() {
  local name version info file owner_line owner_version foreign=()
  while read -r name version; do
    nvidia_is_known_package "$name" && continue
    if [[ $name == *nvidia*dkms ]]; then
      foreign+=("$name $version")
    fi
  done < <(pacman -Q)

  # Also catch a differently named package that advertises the NVIDIA module provider.
  # pacman -Qi lists all installed package metadata in one read; continuation lines are kept
  # with the Provides field until the next field begins.
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    version=$(nvidia_pacman_version "$name" 2>/dev/null || true)
    nvidia_is_known_package "$name" && continue
    if [[ ! " ${foreign[*]} " == *"$name "* ]]; then
      foreign+=("$name $version")
    fi
  done < <(LC_ALL=C pacman -Qi 2>/dev/null | awk '
    function finish() { if (name != "" && provides ~ /(^|[[:space:]])NVIDIA-MODULE([=[:space:]]|$)/) print name }
    /^Name[[:space:]]*:/ { finish(); name=$3; provides=""; in_provides=0; next }
    /^[[:alpha:]][[:alnum:] _-]*[[:space:]]*:/ { in_provides = ($1 ~ /^Provides/); if (in_provides) provides=provides " " $0; next }
    in_provides { provides=provides " " $0 }
    END { finish() }
  ')

  # A prebuilt package may install its module without advertising the DKMS provider. Use pacman's
  # ownership record to distinguish those packages from modules generated by DKMS.
  while IFS= read -r -d '' file; do
    owner_line=$(LC_ALL=C pacman -Qo "$file" 2>/dev/null || true)
    owner=$(sed -n 's/.* is owned by \([^ ]*\) .*/\1/p' <<<"$owner_line")
    [[ -n $owner ]] || continue
    nvidia_is_known_package "$owner" && continue
    owner_version=$(nvidia_pacman_version "$owner" 2>/dev/null || true)
    if [[ ! " ${foreign[*]} " == *"$owner "* ]]; then
      foreign+=("$owner ${owner_version:-unknown}")
    fi
  done < <(nvidia_driver_module_files /usr/lib/modules 2>/dev/null)

  if ((${#foreign[@]})); then
    printf '%s\n' "${foreign[@]}"
  fi
}

nvidia_find_existing_nvidia_packages() {
  NV_EXISTING_PACKAGES=()
  NV_EXISTING_VERSIONS=()
  local name version
  for name in nvidia-utils nvidia-open-dkms nvidia-open nvidia-open-lts; do
    if version=$(nvidia_pacman_version "$name"); then
      NV_EXISTING_PACKAGES+=("$name")
      NV_EXISTING_VERSIONS+=("$name $version")
    fi
  done
}

nvidia_check_repo_versions() {
  local name installed available utils_version
  local -a mismatches=()
  nvidia_find_existing_nvidia_packages
  utils_version=$(nvidia_sync_version extra/nvidia-utils 2>/dev/null || true)
  for name in "${NV_EXISTING_PACKAGES[@]}"; do
    installed=$(nvidia_pacman_version "$name") || continue
    available=$(nvidia_sync_version "extra/$name") || {
      mismatches+=("$name $installed (not carried by current repositories)")
      continue
    }
    if [[ $installed != "$available" ]]; then
      mismatches+=("$name $installed (repository $available)")
    fi
    if [[ $name != nvidia-utils && -n $utils_version && $installed != "$utils_version" ]]; then
      mismatches+=("$name $installed (driver version $utils_version)")
    fi
  done
  if ((${#mismatches[@]})); then
    nvidia_report "left the existing NVIDIA driver unchanged because installed package versions do not match Arch's repositories: $(nvidia_list "${mismatches[@]}")."
    return 1
  fi
  return 0
}

nvidia_collect_kernels() {
  local dir kernel pkgbase
  NV_KERNELS=()
  NV_PKGBASE=()
  for dir in /usr/lib/modules/*; do
    [[ -d $dir && -f $dir/pkgbase ]] || continue
    kernel=${dir##*/}
    pkgbase=$(<"$dir/pkgbase")
    [[ -n $kernel && -n $pkgbase ]] || continue
    NV_KERNELS+=("$kernel")
    NV_PKGBASE[$kernel]=$pkgbase
  done
}

nvidia_kernel_has_headers() {
  local kernel=$1 pkgbase=${NV_PKGBASE[$1]} kernel_package_version headers installed
  kernel_package_version=$(nvidia_pacman_version "$pkgbase" 2>/dev/null || true)
  [[ -n $kernel_package_version ]] || return 1
  headers=$pkgbase-headers
  installed=$(nvidia_pacman_version "$headers" 2>/dev/null || true)
  [[ $installed == "$kernel_package_version" ]]
}

nvidia_kernel_is_covered() {
  local kernel=$1 expected=$2 module version
  nvidia_kernel_has_headers "$kernel" || return 1
  for module in "${NV_MODULES[@]}"; do
    version=$(modinfo -k "$kernel" -F version "$module" 2>/dev/null || true)
    [[ $version == "$expected" ]] || return 1
  done
  return 0
}

nvidia_headers_target() {
  local kernel=$1 pkgbase=${NV_PKGBASE[$1]} kernel_version headers repo_version repo
  kernel_version=$(nvidia_pacman_version "$pkgbase" 2>/dev/null || true)
  [[ -n $kernel_version ]] || return 1
  headers=$pkgbase-headers
  if [[ $pkgbase == linux-gooarchy ]]; then
    return 1
  fi
  for repo in core extra; do
    repo_version=$(nvidia_sync_version "$repo/$headers" 2>/dev/null || true)
    if [[ $repo_version == "$kernel_version" ]]; then
      printf '%s=%s\n' "$repo/$headers" "$kernel_version"
      return 0
    fi
  done
  return 1
}

nvidia_read_assignment() {
  local file=$1 key=$2 line lhs value= matches=0 appended=0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == *\#* ]] && line=${line%%\#*}
    [[ $line == *=* ]] || continue
    lhs=${line%%=*}
    lhs=${lhs#"${lhs%%[![:space:]]*}"}
    lhs=${lhs%"${lhs##*[![:space:]]}"}
    if [[ $lhs == "$key+" ]]; then
      appended=1
      continue
    fi
    [[ $lhs == "$key" ]] || continue
    ((matches += 1))
    value=${line#*=}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    value=${value#\"}; value=${value%\"}
    value=${value#\'}; value=${value%\'}
  done <"$file"
  if ((appended || matches > 1)); then
    printf '%s\n' __GOOARCHY_UNRESOLVED_ASSIGNMENT__
  elif ((matches == 1)); then
    printf '%s\n' "$value"
  fi
  return 0
}

nvidia_preset_files() {
  local file
  for file in /etc/mkinitcpio.d/*.preset; do
    [[ -f $file ]] && printf '%s\n' "$file"
  done
}

nvidia_preset_entries() {
  local file=$1 line body= tail token entry found=0 reading=0 closed=0 invalid=0 operator
  local -a tokens=()
  local -A seen=()
  NV_PRESET_ENTRIES=()
  NV_PRESET_ENTRIES_UNRESOLVED=0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%\#*}
    if ((reading == 0)); then
      if [[ $line =~ ^[[:space:]]*PRESETS[[:space:]]*(\+?=) ]]; then
        operator=${BASH_REMATCH[1]}
        ((found += 1))
        if [[ $operator != '=' || $found > 1 ]]; then invalid=1; break; fi
        body=${line#*=}
        reading=1
      else
        continue
      fi
    else
      body+=" $line"
    fi
    if ((reading)) && [[ $body == *')'* ]]; then
      closed=1
      reading=0
      tail=${body#*)}
      tail=${tail#"${tail%%[![:space:]]*}"}
      [[ -z $tail ]] || { invalid=1; break; }
    fi
  done <"$file"
  if ((invalid || found != 1 || closed == 0 || reading)); then
    NV_PRESET_ENTRIES_UNRESOLVED=1
    return 1
  fi
  body=${body#"${body%%[![:space:]]*}"}
  [[ ${body:0:1} == '(' ]] || { NV_PRESET_ENTRIES_UNRESOLVED=1; return 1; }
  body=${body:1}
  body=${body%)}
  [[ $body != *'$'* && $body != *'`'* && $body != *';'* && $body != *'('* && $body != *')'* ]] || {
    NV_PRESET_ENTRIES_UNRESOLVED=1
    return 1
  }
  read -r -a tokens <<<"$body"
  for token in "${tokens[@]}"; do
    case $token in
      \'*\') entry=${token:1:${#token}-2} ;;
      \"*\") entry=${token:1:${#token}-2} ;;
      *) entry=$token ;;
    esac
    [[ $entry =~ ^[[:alnum:]_.+-]+$ ]] || { NV_PRESET_ENTRIES=(); NV_PRESET_ENTRIES_UNRESOLVED=1; return 1; }
    [[ ! ${seen[$entry]:-} ]] || { NV_PRESET_ENTRIES=(); NV_PRESET_ENTRIES_UNRESOLVED=1; return 1; }
    seen[$entry]=1
    NV_PRESET_ENTRIES+=("$entry")
  done
  ((${#NV_PRESET_ENTRIES[@]} > 0)) || { NV_PRESET_ENTRIES_UNRESOLVED=1; return 1; }
  return 0
}

nvidia_preset_images() {
  local file=$1 entry suffix key value config image entry_image_count
  NV_IMAGES=()
  NV_IMAGE_ENTRIES=()
  NV_IMAGE_KEYS=()
  NV_IMAGE_CONFIGS=()
  NV_IMAGES_UNRESOLVED=0
  if ! nvidia_preset_entries "$file"; then NV_IMAGES_UNRESOLVED=1; return; fi
  local -A seen_images=()
  for entry in "${NV_PRESET_ENTRIES[@]}"; do
    entry_image_count=0
    config=$(nvidia_preset_config "$file" "$entry")
    [[ $config != __GOOARCHY_UNRESOLVED_CONFIG__ ]] || { NV_IMAGES_UNRESOLVED=1; continue; }
    for suffix in image uki; do
      key=${entry}_${suffix}
      value=$(nvidia_read_assignment "$file" "$key")
      if [[ $value == __GOOARCHY_UNRESOLVED_ASSIGNMENT__ ]]; then
        NV_IMAGES_UNRESOLVED=1
        continue
      fi
      [[ -n $value ]] || continue
      if [[ $value == *'$'* || $value == *'`'* ]]; then
        NV_IMAGES_UNRESOLVED=1
        continue
      fi
      image=$value
      if [[ ${seen_images[$image]:-} ]]; then
        NV_IMAGES_UNRESOLVED=1
        continue
      fi
      seen_images[$image]=1
      NV_IMAGES+=("$image")
      NV_IMAGE_ENTRIES+=("$entry")
      NV_IMAGE_KEYS+=("$key")
      NV_IMAGE_CONFIGS+=("$config")
      ((entry_image_count += 1))
    done
    ((entry_image_count > 0)) || NV_IMAGES_UNRESOLVED=1
  done
  ((${#NV_IMAGES[@]} > 0)) || NV_IMAGES_UNRESOLVED=1
}

nvidia_preset_config() {
  local file=$1 entry=${2:-${1##*/}} name config opts option_scan option_config=
  entry=${entry%.preset}
  name=${entry}_config
  config=$(nvidia_read_assignment "$file" "$name")
  if [[ $config == __GOOARCHY_UNRESOLVED_ASSIGNMENT__ ]]; then
    printf '%s\n' __GOOARCHY_UNRESOLVED_CONFIG__
    return 0
  fi
  [[ -n $config ]] || config=$(nvidia_read_assignment "$file" ALL_config)
  if [[ $config == __GOOARCHY_UNRESOLVED_ASSIGNMENT__ ]]; then
    printf '%s\n' __GOOARCHY_UNRESOLVED_CONFIG__
    return 0
  fi
  opts=$(nvidia_read_assignment "$file" "${entry}_options")
  if [[ $opts == __GOOARCHY_UNRESOLVED_ASSIGNMENT__ ]]; then
    printf '%s\n' __GOOARCHY_UNRESOLVED_CONFIG__
    return 0
  fi
  [[ -n $opts ]] || opts=$(nvidia_read_assignment "$file" ALL_options)
  if [[ $opts == __GOOARCHY_UNRESOLVED_ASSIGNMENT__ ]]; then
    printf '%s\n' __GOOARCHY_UNRESOLVED_CONFIG__
    return 0
  fi
  if [[ $config == *'$'* || $config == *'`'* || $opts == *'$'* || $opts == *'`'* ||
        ( $opts == *'('* && $opts != *')'* ) ]]; then
    printf '%s\n' __GOOARCHY_UNRESOLVED_CONFIG__
    return 0
  fi
  option_scan=${opts//[()]/ }
  option_scan=${option_scan//\"/}
  option_scan=${option_scan//\'/}
  if [[ $option_scan =~ (^|[[:space:]])(--config=|-c=)([^[:space:]]+) ]]; then
    option_config=${BASH_REMATCH[3]}
  elif [[ $option_scan =~ (^|[[:space:]])(-c|--config)[[:space:]]+([^[:space:]]+) ]]; then
    option_config=${BASH_REMATCH[3]}
  elif [[ $option_scan =~ (^|[[:space:]])(-c|--config)([[:space:]]|$) ]]; then
    printf '%s\n' __GOOARCHY_UNRESOLVED_CONFIG__
    return 0
  fi
  [[ -z $option_config ]] || config=$option_config
  printf '%s\n' "$config"
}

nvidia_config_module_text() {
  local file=${1:-} line text= active=0
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%\#*}
    line=${line//\"/}
    line=${line//\'/}
    if ((active)); then
      text+=" $line"
      if [[ $line == *')'* ]]; then printf '%s\n' "$text"; text=; active=0; fi
      continue
    fi
    if [[ $line =~ (^|[[:space:]])MODULES[[:space:]]*\+?= ]]; then
      text=$line
      if [[ $line != *')'* ]]; then active=1; else printf '%s\n' "$text"; text=; fi
    fi
  done <"$file"
  [[ -n $text ]] && printf '%s\n' "$text"
}

nvidia_config_has_all_modules() {
  local -a config_files=() tokens=()
  local file line assignment value token module append active
  local -A present=()
  NV_CONFIG_DYNAMIC=0
  if (($#)); then
    config_files=("$@")
  else
    config_files=(/etc/mkinitcpio.conf /etc/mkinitcpio.conf.d/*.conf)
  fi
  for file in "${config_files[@]}"; do
    [[ -f $file ]] || continue
    assignment=
    active=0
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line%%#*}
      if ((active)); then
        assignment+=" $line"
        [[ $line == *')'* ]] || continue
      else
        if [[ ! $line =~ ^[[:space:]]*MODULES[[:space:]]*([+])?[[:space:]]*= ]]; then
          if [[ $line =~ (^|[[:space:]])MODULES([[:space:]]|\+?=) ||
                $line =~ ^[[:space:]]*(source|\.)[[:space:]]+ ]]; then
            NV_CONFIG_DYNAMIC=1
            return 1
          fi
          continue
        fi
        assignment=$line
        if [[ $line != *')'* ]]; then active=1; continue; fi
      fi
      [[ $assignment =~ ^[[:space:]]*MODULES[[:space:]]*([+])?[[:space:]]*= ]] || return 1
      append=${BASH_REMATCH[1]:-}
      value=${assignment#*=}
      value=${value#*[(]}
      value=${value%%[)]*}
      if [[ $value == *'$'* || $value == *'`'* ]]; then
        NV_CONFIG_DYNAMIC=1
        return 1
      fi
      value=${value//\"/}
      value=${value//\'/}
      if [[ -z $append ]]; then present=(); fi
      read -r -a tokens <<<"$value"
      for token in "${tokens[@]}"; do
        token=${token%[?]}
        case $token in
          nvidia | nvidia_modeset | nvidia_uvm | nvidia_drm) present[$token]=1 ;;
        esac
      done
      assignment=
      active=0
    done <"$file"
    ((active == 0)) || return 1
  done
  for module in "${NV_MODULES[@]}"; do
    [[ ${present[$module]:-} ]] || return 1
  done
  return 0
}

nvidia_user_config_has_all_modules() {
  local file
  local -a config_files=()
  NV_CONFIG_DYNAMIC=0
  for file in /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d/*.conf; do
    if [[ $file == "$NV_OWNED_CONFIG" ]] && nvidia_owned_config_is_valid; then continue; fi
    [[ -f $file ]] && config_files+=("$file")
  done
  (( ${#config_files[@]} > 0 )) || return 1
  nvidia_config_has_all_modules "${config_files[@]}"
}

nvidia_effective_user_config_files() {
  local preset=$1 entry=$2 file config
  NV_EFFECTIVE_CONFIG_FILES=()
  config=$(nvidia_preset_config "$preset" "$entry")
  [[ $config != __GOOARCHY_UNRESOLVED_CONFIG__ ]] || return 1
  if [[ -n $config ]]; then
    if [[ $config == "$NV_OWNED_CONFIG" ]] && nvidia_owned_config_is_valid; then return; fi
    NV_EFFECTIVE_CONFIG_FILES=("$config")
    return
  fi
  NV_EFFECTIVE_CONFIG_FILES=(/etc/mkinitcpio.conf)
  for file in /etc/mkinitcpio.conf.d/*.conf; do
    [[ -f $file ]] || continue
    if [[ $file == "$NV_OWNED_CONFIG" ]] && nvidia_owned_config_is_valid; then continue; fi
    NV_EFFECTIVE_CONFIG_FILES+=("$file")
  done
}

nvidia_collect_config_source_files() {
  local file=$1 depth=${2:-0} line target
  ((depth < 16)) || return 0
  [[ -f $file && ! ${NV_CONFIG_SOURCE_SEEN[$file]:-} ]] || return 0
  NV_CONFIG_SOURCE_SEEN[$file]=1
  NV_CONFIG_SOURCE_FILES+=("$file")
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    [[ $line =~ ^[[:space:]]*(source|\.)[[:space:]]+(.+)$ ]] || continue
    target=${BASH_REMATCH[2]}
    target=${target#\"}; target=${target%\"}
    target=${target#\'}; target=${target%\'}
    # Resolve only absolute literal includes. Never evaluate user shell or guess a dynamic path.
    [[ $target =~ ^/[[:alnum:]_./+-]+$ ]] || continue
    nvidia_collect_config_source_files "$target" "$((depth + 1))"
  done <"$file"
}

nvidia_user_config_source_files() {
  local preset=$1 entry=$2 file found=0
  NV_USER_CONFIG_SOURCE_FILES=()
  NV_CONFIG_SOURCE_FILES=()
  NV_CONFIG_SOURCE_SEEN=()
  nvidia_effective_user_config_files "$preset" "$entry" || return 1
  for file in "${NV_EFFECTIVE_CONFIG_FILES[@]}"; do
    nvidia_collect_config_source_files "$file"
  done
  for file in "${NV_CONFIG_SOURCE_FILES[@]}"; do
    if awk '{ sub(/[[:space:]]*#.*/, ""); if ($0 ~ /^[[:space:]]*MODULES[[:space:]]*[+]?[[:space:]]*=/) found=1 } END { exit !found }' "$file"; then
      NV_USER_CONFIG_SOURCE_FILES+=("$file")
      found=1
    fi
  done
  if ((found == 0)); then
    NV_USER_CONFIG_SOURCE_FILES=("${NV_EFFECTIVE_CONFIG_FILES[@]}")
  fi
  ((${#NV_USER_CONFIG_SOURCE_FILES[@]} > 0))
}

nvidia_literal_config_module_set() {
  # A failed throwaway build must not hide a static user partial effect already present in a
  # listable image. Parse only literal MODULES arrays here; never evaluate user shell.
  local preset=$1 entry=$2 file line append value token
  local -a tokens=()
  NV_CONFIG_PROBE_MODULE_SET=()
  nvidia_user_config_source_files "$preset" "$entry" || return 2
  for file in "${NV_USER_CONFIG_SOURCE_FILES[@]}"; do
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line%%#*}
      [[ -n ${line//[[:space:]]/} ]] || continue
      [[ $line =~ ^[[:space:]]*(source|\.)[[:space:]]+ ]] && return 2
      if [[ $line =~ ^[[:space:]]*MODULES[[:space:]]*(\+)?[[:space:]]*=[[:space:]]*\(([^()]*)\)[[:space:]]*$ ]]; then
        append=${BASH_REMATCH[1]:-}
        value=${BASH_REMATCH[2]}
        [[ $value != *'$'* && $value != *'`'* && $value != *';'* ]] || return 2
        value=${value//\"/}
        value=${value//\'/}
        [[ -n $append ]] || NV_CONFIG_PROBE_MODULE_SET=()
        read -r -a tokens <<<"$value"
        for token in "${tokens[@]}"; do
          token=${token%\?}
          [[ $token =~ ^[[:alnum:]_-]+$ ]] || return 2
          case $token in
            nvidia | nvidia_modeset | nvidia_uvm | nvidia_drm)
              NV_CONFIG_PROBE_MODULE_SET[$token]=1
              ;;
          esac
        done
      elif [[ $line =~ (^|[[:space:]])MODULES([[:space:]]|\+?=) ]]; then
        return 2
      fi
    done <"$file"
  done
  ((${#NV_CONFIG_PROBE_MODULE_SET[@]} > 0))
}

nvidia_missing_nvidia_module_from_error_line() {
  local line=$1 module
  [[ $line == *"ERROR: module not found: '"* ]] || return 1
  module=${line#*"ERROR: module not found: '"}
  module=${module%%\'*}
  [[ -n $module && $module != *[![:alnum:]_-]* ]] || return 1
  module=${module//-/_}
  [[ $module == nvidia* ]] || return 1
  printf '%s\n' "$module"
}

nvidia_record_package_hook_errors() {
  local output_file=$1 line preset current_kernel kernel module existing
  NV_PACKAGE_HOOK_FAILURES=()
  preset=
  current_kernel=
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == *"Building image from preset:"* ]] &&
       [[ $line =~ /mkinitcpio\.d/([[:alnum:]_.+-]+)\.preset ]]; then
      preset=${BASH_REMATCH[1]}
      current_kernel=
      for kernel in "${NV_KERNELS[@]}"; do
        if [[ ${NV_PKGBASE[$kernel]} == "$preset" ]]; then
          current_kernel=$kernel
          break
        fi
      done
      continue
    fi
    [[ $line == *ERROR:* ]] || continue
    if [[ -z $current_kernel ]]; then
      existing=${NV_PACKAGE_HOOK_FAILURES[unknown]:-}
      NV_PACKAGE_HOOK_FAILURES[unknown]="${existing:+$existing; }$line"
      continue
    fi
    module=$(nvidia_missing_nvidia_module_from_error_line "$line" 2>/dev/null || true)
    if [[ -n $module ]] && ! nvidia_kernel_is_covered "$current_kernel" "$NV_DRIVER_MODULE_VERSION"; then
      # The owned drop-in's kernel guard is false for an uncovered kernel, so removing that file
      # has the same module effect for this preset; the user's missing-module error is unchanged.
      continue
    fi
    existing=${NV_PACKAGE_HOOK_FAILURES[$current_kernel]:-}
    NV_PACKAGE_HOOK_FAILURES[$current_kernel]="${existing:+$existing; }$line"
  done <"$output_file"
  return 0
}

nvidia_run_pacman_transaction() {
  local output rc kernel failure image
  local -a invalid_images=()
  output=$(mktemp "${TMPDIR:-/var/tmp}/gooarchy-nvidia-pacman.XXXXXXXX") || return 1
  if command -v mkinitcpio >/dev/null 2>&1; then
    if ! nvidia_preserve_preset_images; then
      rm -f "$output"
      nvidia_fail "could not preserve the active initramfs images before pacman; no NVIDIA package transaction was started."
    fi
  fi
  if "$@" >"$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  cat "$output"
  nvidia_record_package_hook_errors "$output"
  # Pacman's hooks can return success while leaving a preset image unusable. Keep the
  # pre-transaction copies until every active output has passed the same image checks used
  # by the later kernel verification paths.
  if ((rc == 0)) && ((${#NV_REPLACED_PACKAGES[@]})); then
    nvidia_report "replaced ${NV_REPLACED_PACKAGES[*]} with nvidia-open-dkms (the same NVIDIA driver, built for every installed kernel). To undo, run sudo pacman -S ${NV_REPLACED_PACKAGES[*]}."
  fi
  for kernel in "${NV_KERNELS[@]}"; do
    if nvidia_test_failure "pacman-hook:$kernel"; then
      NV_PACKAGE_HOOK_FAILURES[$kernel]="Gooarchy test hook simulated a mkinitcpio failure before that preset wrote an image"
    fi
  done
  rm -f "$output"
  if ((${#NV_IMAGE_BACKUP_IMAGES[@]})); then
    if ((rc != 0)) || ((${#NV_PACKAGE_HOOK_FAILURES[@]})); then
      if ! nvidia_restore_preset_images; then
        nvidia_fail "pacman did not complete cleanly and Gooarchy could not restore every pre-transaction image. The preserved copies remain in their .gooarchy-nvidia-preserve directories; restore them before booting another kernel."
      fi
    else
      for image in "${NV_IMAGE_BACKUP_IMAGES[@]}"; do
        if ! nvidia_image_listable "$image"; then
          invalid_images+=("$image: absent or unlistable")
        elif ! nvidia_image_module_state "$image" "$NV_DRIVER_MODULE_VERSION"; then
          invalid_images+=("$image: ${NV_IMAGE_ERROR:-inconsistent NVIDIA modules or firmware}")
        fi
      done
      if ((${#invalid_images[@]})); then
        if ! nvidia_restore_preset_images; then
          nvidia_fail "the NVIDIA package transaction completed, but its hooks left one or more initramfs images invalid and Gooarchy could not restore every pre-transaction image. The preserved copies remain in their .gooarchy-nvidia-preserve directories; restore them before booting another kernel."
        fi
        for image in "${invalid_images[@]}"; do
          nvidia_report "pacman's post-transaction hook left initramfs image $image; Gooarchy restored its pre-transaction image where one existed. Repair the hook output before booting this kernel, then rerun."
        done
        nvidia_fail "the NVIDIA package transaction completed, but one or more initramfs images were absent, unlistable, or inconsistent with the driver and firmware; Gooarchy restored their pre-transaction state where available. Repair the image state before booting another kernel, then rerun."
      fi
      nvidia_discard_preset_image_backups || nvidia_fail "the NVIDIA package transaction completed, but temporary image-preservation copies could not be removed. Inspect the .gooarchy-nvidia-preserve directories."
    fi
  fi
  if ((${#NV_PACKAGE_HOOK_FAILURES[@]})); then
    for kernel in "${NV_KERNELS[@]}"; do
      failure=${NV_PACKAGE_HOOK_FAILURES[$kernel]:-}
      [[ -n $failure ]] || continue
      nvidia_kernel_user_partial_state "$kernel" "$NV_DRIVER_MODULE_VERSION"
      if ((NV_USER_PARTIAL || NV_USER_PARTIAL_UNKNOWN)); then
        nvidia_report_uncovered_kernel "$kernel" \
          "pacman's post-transaction mkinitcpio hook reported an image-generation error: $failure"
      else
        nvidia_report_direct_config_hook_failure "$kernel"
      fi
      nvidia_report "pacman's post-transaction mkinitcpio hook reported an image-generation error for ${NV_PKGBASE[$kernel]} kernel $kernel: $failure. The step checked or repaired the image state where possible; resolve it and rerun."
    done
    nvidia_report_other_user_partial_kernels "__package_hook_failures__"
    if [[ -n ${NV_PACKAGE_HOOK_FAILURES[unknown]:-} ]]; then
      nvidia_report "pacman's post-transaction mkinitcpio hook reported an image-generation error for an unknown kernel: ${NV_PACKAGE_HOOK_FAILURES[unknown]}. Gooarchy restored the images from before the transaction; resolve the hook error and rerun."
    fi
    nvidia_fail "pacman's post-transaction mkinitcpio hook reported an image-generation error for one or more installed kernels. Gooarchy checked or restored the affected images where possible; resolve every reported hook error and rerun."
  fi
  return "$rc"
}

nvidia_only_missing_nvidia_errors() {
  local output_file=$1 line module errors=0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == *ERROR:* ]] || continue
    module=$(nvidia_missing_nvidia_module_from_error_line "$line") || return 1
    [[ $module == nvidia* ]] || return 1
    ((errors += 1))
  done <"$output_file"
  ((errors > 0))
}

nvidia_image_listable() {
  local image=$1
  sudo test -f "$image" && sudo lsinitcpio "$image" >/dev/null 2>&1
}

nvidia_image_module_state() {
  local image=$1 expected=$2 tmp file version name module firmware
  NV_IMAGE_HAS_NVIDIA=0
  NV_IMAGE_HAS_ALL=0
  NV_IMAGE_ERROR=
  NV_IMAGE_MODULE_SET=()
  tmp=$(mktemp -d "${TMPDIR:-/var/tmp}/gooarchy-nvidia-image.XXXXXXXX") || {
    NV_IMAGE_ERROR="could not create a temporary inspection directory"
    return 1
  }
  if ! (cd "$tmp" && sudo lsinitcpio -x "$image" >/dev/null 2>&1); then
    sudo rm -rf "$tmp"
    NV_IMAGE_ERROR="image could not be listed or extracted"
    return 1
  fi
  local -A present=()
  while IFS= read -r -d '' file; do
    name=${file##*/}
    name=${name%.ko*}
    name=${name//-/_}
    [[ $name == nvidia* ]] || continue
    NV_IMAGE_HAS_NVIDIA=1
    NV_IMAGE_MODULE_SET[$name]=1
    version=$(sudo modinfo -F version "$file" 2>/dev/null || true)
    if [[ -z $version || $version != "$expected" ]]; then
      NV_IMAGE_ERROR="${file#"$tmp"/} has module version ${version:-unknown}, expected $expected"
    fi
    present[$name]=1
    if [[ $name == nvidia ]]; then
      while IFS= read -r firmware; do
        [[ -n $firmware ]] || continue
        local firmware_path
        firmware_path=$(sudo find "$tmp" -type f \
          \( -path "*/firmware/$firmware" -o -path "*/firmware/$firmware.zst" -o -path "*/firmware/$firmware.xz" \) \
          -print -quit)
        if [[ -z $firmware_path ]]; then
          NV_IMAGE_ERROR="${file#"$tmp"/} requires firmware $firmware that is absent from the image"
        fi
      done < <(sudo modinfo -F firmware "$file" 2>/dev/null || true)
    fi
    done < <(sudo find "$tmp" -type f \
      \( -name 'nvidia.ko*' -o -name 'nvidia_modeset.ko*' -o -name 'nvidia_uvm.ko*' -o -name 'nvidia_drm.ko*' \
         -o -name 'nvidia-modeset.ko*' -o -name 'nvidia-uvm.ko*' -o -name 'nvidia-drm.ko*' \) \
      -print0)
  if [[ ${present[nvidia]:-} && ${present[nvidia_modeset]:-} && ${present[nvidia_uvm]:-} && ${present[nvidia_drm]:-} ]]; then
    NV_IMAGE_HAS_ALL=1
  fi
  sudo rm -rf "$tmp"
  [[ -z $NV_IMAGE_ERROR ]]
}

nvidia_probe_config_modules() {
  local preset=$1 kernel=$2 expected=$3 allow_missing=${4:-0} entry=${5:-${1##*/}} config image_status=0 module
  local -a args=(sudo mkinitcpio -k "$kernel" -g)
  local image log
  entry=${entry%.preset}
  NV_CONFIG_PROBE_MODULE_SET=()
  NV_CONFIG_PROBE_ERROR=
  config=$(nvidia_preset_config "$preset" "$entry")
  [[ $config != __GOOARCHY_UNRESOLVED_CONFIG__ ]] || {
    NV_CONFIG_PROBE_ERROR="could not resolve the literal configuration for ${entry} in ${preset##*/}"
    return 2
  }
  image=$(mktemp "${TMPDIR:-/var/tmp}/gooarchy-nvidia-config-probe.XXXXXXXX") || {
    NV_CONFIG_PROBE_ERROR="could not create a temporary mkinitcpio image for $kernel"
    return 2
  }
  rm -f "$image"
  log=$(mktemp "${TMPDIR:-/var/tmp}/gooarchy-nvidia-config-probe.XXXXXXXX") || {
    sudo rm -f "$image"
    NV_CONFIG_PROBE_ERROR="could not capture mkinitcpio output for $kernel"
    return 2
  }
  args+=("$image")
  [[ -z $config ]] || args+=(-c "$config")
  if "${args[@]}" >"$log" 2>&1; then
    image_status=0
  else
    image_status=$?
  fi
  cat "$log"
  if ((image_status != 0)) && ! { ((allow_missing)) && nvidia_only_missing_nvidia_errors "$log"; }; then
    NV_CONFIG_PROBE_ERROR="mkinitcpio reported an error while evaluating $preset for $kernel"
    rm -f "$log"
    sudo rm -f "$image"
    return 2
  fi
  rm -f "$log"
  if ! nvidia_image_listable "$image"; then
    sudo rm -f "$image"
    NV_CONFIG_PROBE_ERROR="mkinitcpio did not produce a listable throwaway image for $kernel from ${config:-/etc/mkinitcpio.conf}"
    return 2
  fi
  nvidia_image_module_state "$image" "$expected" || true
  for module in "${!NV_IMAGE_MODULE_SET[@]}"; do
    NV_CONFIG_PROBE_MODULE_SET[$module]=1
  done
  sudo rm -f "$image"
  return 0
}

nvidia_probe_config_has_all_modules() {
  local preset=$1 kernel=$2 expected=$3 entry=${4:-${1##*/}}
  entry=${entry%.preset}
  nvidia_probe_config_modules "$preset" "$kernel" "$expected" 0 "$entry" || return 2
  [[ ${NV_CONFIG_PROBE_MODULE_SET[nvidia]:-} &&
     ${NV_CONFIG_PROBE_MODULE_SET[nvidia_modeset]:-} &&
     ${NV_CONFIG_PROBE_MODULE_SET[nvidia_uvm]:-} &&
     ${NV_CONFIG_PROBE_MODULE_SET[nvidia_drm]:-} ]]
}

nvidia_kernel_module_state() {
  local kernel=$1 expected=$2 module version file
  NV_KERNEL_MODULES=0
  NV_KERNEL_HAS_ALL=1
  NV_KERNEL_ERROR=
  for module in "${NV_MODULES[@]}"; do
    version=$(modinfo -k "$kernel" -F version "$module" 2>/dev/null || true)
    if [[ -n $version ]]; then
      ((NV_KERNEL_MODULES += 1))
      [[ $version == "$expected" ]] || NV_KERNEL_ERROR="$module in /usr/lib/modules/$kernel is $version, expected $expected"
    else
      NV_KERNEL_HAS_ALL=0
    fi
  done
  while IFS= read -r -d '' file; do
    version=$(modinfo -F version "$file" 2>/dev/null || true)
    [[ -n $version && $version == "$expected" ]] || NV_KERNEL_ERROR="${file#/usr/lib/modules/$kernel/} is ${version:-unreadable}, expected $expected"
  done < <(nvidia_driver_module_files "/usr/lib/modules/$kernel" 2>/dev/null)
  [[ -z $NV_KERNEL_ERROR ]]
}

nvidia_collect_kernel_presets() {
  local kernel=$1 preset base
  NV_KERNEL_PRESETS=()
  for preset in $(nvidia_preset_files); do
    base=${preset##*/}; base=${base%.preset}
    [[ $base == "${NV_PKGBASE[$kernel]}" ]] && NV_KERNEL_PRESETS+=("$preset")
  done
  return 0
}

nvidia_space_check() {
  local only_kernel=${1:-} context=${2:-} only_preset=${3:-} preset image parent filesystem bytes need_kb available_kb kernel
  local -A required=() available=()
  local -a presets=()
  if nvidia_test_failure "space"; then
    nvidia_fail "not enough free space to keep the existing initramfs images intact while writing NVIDIA images (GOOARCHY_TEST_NVIDIA_FAIL=space). No image or NVIDIA package was changed. Free space and rerun."
  fi
  if [[ -n $only_preset ]]; then
    presets=("$only_preset")
  elif [[ -n $only_kernel ]]; then
    nvidia_collect_kernel_presets "$only_kernel"
    presets=("${NV_KERNEL_PRESETS[@]}")
  else
    mapfile -t presets < <(nvidia_preset_files)
  fi
  for preset in "${presets[@]}"; do
    nvidia_preset_images "$preset"
    ((NV_IMAGES_UNRESOLVED == 0)) || nvidia_fail "could not resolve every image path in ${preset##*/} before an NVIDIA package or initramfs change."
    ((${#NV_IMAGES[@]} > 0)) || nvidia_fail "could not find an image path in ${preset##*/} before an NVIDIA package or initramfs change."
    for image in "${NV_IMAGES[@]}"; do
      parent=$(dirname "$image")
      while [[ ! -d $parent && $parent != / ]]; do parent=$(dirname "$parent"); done
      filesystem=$(LC_ALL=C df -Pk "$parent" 2>/dev/null | awk 'NR == 2 { print $1 }')
      available_kb=$(LC_ALL=C df -Pk "$parent" 2>/dev/null | awk 'NR == 2 { print $4 }')
      [[ -n $filesystem && $available_kb =~ ^[0-9]+$ ]] || nvidia_fail "could not check free space for initramfs image $image before changing NVIDIA packages."
      if sudo test -f "$image"; then
        bytes=$(sudo stat -c %s -- "$image")
        # Keep the old complete image while mkinitcpio writes its replacement. The extra
        # driver-package allowance covers the modules and firmware added to the archive.
        need_kb=$(((bytes + 1023) / 1024 + ${NV_IMAGE_GROWTH_KB:-131072} + 16 * 1024))
      else
        need_kb=$((${NV_IMAGE_GROWTH_KB:-131072} + 16 * 1024))
      fi
      required[$filesystem]=$(( ${required[$filesystem]:-0} + need_kb ))
      available[$filesystem]=$available_kb
    done
  done
  for filesystem in "${!required[@]}"; do
    if (( ${available[$filesystem]} < ${required[$filesystem]} )); then
      if [[ $context == stale ]]; then
        local stale_error=$NV_BASELINE_ERROR
        nvidia_stale_recovery_text "$only_kernel" "${NV_DRIVER_MODULE_VERSION:-unknown}"
        nvidia_fail "not enough free space to repair the inherited NVIDIA baseline for ${NV_PKGBASE[$only_kernel]} kernel $only_kernel: $stale_error. The images need about $((required[$filesystem] / 1024)) MiB beside their current contents; $filesystem has $((available[$filesystem] / 1024)) MiB free.${NV_STALE_PARTIAL_NOTE} ${NV_STALE_RECOVERY} Free space and rerun."
      fi
      nvidia_fail "not enough free space to keep the existing initramfs images intact while writing NVIDIA images on $filesystem: need about $((required[$filesystem] / 1024)) MiB, have $((available[$filesystem] / 1024)) MiB. Free space and rerun."
    fi
  done
}

nvidia_discard_preset_image_backups() {
  local backup_dir
  for backup_dir in "${NV_IMAGE_BACKUP_DIRS[@]}"; do
    [[ -n $backup_dir ]] || continue
    sudo rm -rf -- "$backup_dir" || return 1
  done
  NV_IMAGE_BACKUP_IMAGES=()
  NV_IMAGE_BACKUP_FILES=()
  NV_IMAGE_BACKUP_DIRS=()
  NV_IMAGE_BACKUP_PRESENT=()
  return 0
}

nvidia_preserve_preset_images() {
  local preset image parent backup_dir backup_file idx
  local -A seen=()
  local -a presets=()
  if ((${#NV_IMAGE_BACKUP_IMAGES[@]})); then return 1; fi
  if (($#)); then
    presets=("$@")
  else
    mapfile -t presets < <(nvidia_preset_files)
  fi
  for preset in "${presets[@]}"; do
    nvidia_preset_images "$preset"
    ((NV_IMAGES_UNRESOLVED == 0)) || { nvidia_discard_preset_image_backups || true; return 1; }
    for image in "${NV_IMAGES[@]}"; do
      [[ ${seen[$image]:-} ]] && continue
      seen[$image]=1
      NV_IMAGE_BACKUP_IMAGES+=("$image")
      if sudo test -e "$image" || sudo test -L "$image"; then
        parent=$(dirname "$image")
        backup_dir=$(sudo mktemp -d "$parent/.gooarchy-nvidia-preserve.XXXXXXXX") || {
          nvidia_discard_preset_image_backups || true
          return 1
        }
        backup_file=$backup_dir/${image##*/}
        if ! sudo cp -a -- "$image" "$backup_file"; then
          sudo rm -rf -- "$backup_dir" || true
          nvidia_discard_preset_image_backups || true
          return 1
        fi
        NV_IMAGE_BACKUP_FILES+=("$backup_file")
        NV_IMAGE_BACKUP_DIRS+=("$backup_dir")
        NV_IMAGE_BACKUP_PRESENT+=(1)
      else
        NV_IMAGE_BACKUP_FILES+=("")
        NV_IMAGE_BACKUP_DIRS+=("")
        NV_IMAGE_BACKUP_PRESENT+=(0)
      fi
    done
  done
  return 0
}

nvidia_restore_preset_images() {
  local idx image backup_file backup_dir failed=0
  for idx in "${!NV_IMAGE_BACKUP_IMAGES[@]}"; do
    image=${NV_IMAGE_BACKUP_IMAGES[$idx]}
    if [[ ${NV_IMAGE_BACKUP_PRESENT[$idx]} == 1 ]]; then
      backup_file=${NV_IMAGE_BACKUP_FILES[$idx]}
      backup_dir=${NV_IMAGE_BACKUP_DIRS[$idx]}
      if ! sudo mv -f -- "$backup_file" "$image"; then failed=1; continue; fi
      [[ -d $backup_dir ]] || failed=1
    elif sudo test -e "$image" || sudo test -L "$image"; then
      sudo rm -f -- "$image" || failed=1
    fi
  done
  ((failed == 0)) || return 1
  nvidia_discard_preset_image_backups
}

nvidia_regenerate_kernel_images() {
  local kernel=$1 context=${2:-} only_preset=${3:-} expected=${4:-${NV_DRIVER_MODULE_VERSION:-unknown}} requested
  local preset status output preset_wrapper entry failed_by_test uncovered=0 image idx
  local -a presets=() entries=() requested_entries=()
  local -A requested_seen=()
  if (($# > 4)); then requested_entries=("${@:5}"); fi
  if [[ -n $only_preset ]]; then
    presets=("$only_preset")
  else
    nvidia_collect_kernel_presets "$kernel"
    presets=("${NV_KERNEL_PRESETS[@]}")
  fi
  ((${#presets[@]})) || return 2
  nvidia_kernel_is_covered "$kernel" "$expected" || uncovered=1
  nvidia_space_check "$kernel" "$context" "$only_preset"
  for preset in "${presets[@]}"; do
    nvidia_preset_images "$preset"
    if ((NV_IMAGES_UNRESOLVED)); then
      nvidia_report "could not resolve active image entries in ${preset##*/} before regeneration."
      return 98
    fi
    entries=("${NV_PRESET_ENTRIES[@]}")
    if ((${#requested_entries[@]})); then
      [[ -n $only_preset ]] || { nvidia_report "selected-entry regeneration requires one named preset."; return 98; }
      local -A active_entries=()
      local -a selected_entries=()
      for entry in "${entries[@]}"; do active_entries[$entry]=1; done
      for requested in "${requested_entries[@]}"; do
        [[ ${active_entries[$requested]:-} ]] || {
          nvidia_report "requested regeneration entry $requested is not active in ${preset##*/}."
          return 98
        }
        [[ ! ${requested_seen[$requested]:-} ]] || {
          nvidia_report "requested regeneration entry $requested was duplicated."
          return 98
        }
        requested_seen[$requested]=1
        selected_entries+=("$requested")
      done
      entries=("${selected_entries[@]}")
    fi
    nvidia_preserve_preset_images "$preset" || {
      nvidia_report "could not preserve the active images in ${preset##*/} before regeneration."
      return 98
    }
    for entry in "${entries[@]}"; do
      status=0
      failed_by_test=0
      output=$(mktemp "${TMPDIR:-/var/tmp}/gooarchy-nvidia-mkinitcpio.XXXXXXXX") || {
        nvidia_restore_preset_images || nvidia_fail "could not capture mkinitcpio output or restore active images in ${preset##*/}."
        return 1
      }
      preset_wrapper=$(mktemp "${TMPDIR:-/var/tmp}/gooarchy-nvidia-preset.XXXXXXXX") || {
        rm -f "$output"
        nvidia_restore_preset_images || nvidia_fail "could not prepare an active-entry preset or restore images in ${preset##*/}."
        return 1
      }
      if ! printf 'source %q\nPRESETS=(%q)\n' "$preset" "$entry" >"$preset_wrapper"; then
        rm -f "$output" "$preset_wrapper"
        nvidia_restore_preset_images || nvidia_fail "could not write an active-entry preset or restore images in ${preset##*/}."
        return 1
      fi
      if nvidia_test_failure "mkinitcpio:${kernel}" ||
         nvidia_test_failure "mkinitcpio-pkgbase:${NV_PKGBASE[$kernel]}"; then
        status=99
        failed_by_test=1
        printf 'Gooarchy test hook failed mkinitcpio for %s entry %s\n' "$kernel" "$entry" >"$output"
      else
        sudo mkinitcpio -p "$preset_wrapper" >"$output" 2>&1 || status=$?
      fi
      cat "$output"
      if ((status != 0)); then
        if ((uncovered && !failed_by_test)) && nvidia_only_missing_nvidia_errors "$output"; then
          nvidia_report "mkinitcpio reported only missing NVIDIA modules requested by the user's configuration for uncovered kernel $kernel; the owned drop-in adds no modules for this kernel, and its image still must pass the version, firmware and listability checks."
          rm -f "$output" "$preset_wrapper"
          continue
        fi
        rm -f "$output" "$preset_wrapper"
        nvidia_restore_preset_images || nvidia_fail "mkinitcpio failed for active entry $entry in ${preset##*/} and Gooarchy could not restore its pre-run image copies. The preserved copies remain in .gooarchy-nvidia-preserve directories."
        return "$status"
      fi
      rm -f "$output" "$preset_wrapper"
    done
    nvidia_preset_images "$preset"
    if ((NV_IMAGES_UNRESOLVED)); then
      nvidia_restore_preset_images || nvidia_fail "mkinitcpio left unresolved active image paths in $preset and Gooarchy could not restore its pre-run copies."
      return 98
    fi
    for idx in "${!NV_IMAGES[@]}"; do
      image=${NV_IMAGES[$idx]}
      if ! nvidia_image_listable "$image" || ! nvidia_image_module_state "$image" "$expected"; then
        nvidia_restore_preset_images || nvidia_fail "mkinitcpio left $image absent, unlistable or inconsistent and Gooarchy could not restore its pre-run copy."
        return 98
      fi
    done
    nvidia_discard_preset_image_backups || nvidia_fail "mkinitcpio completed for $preset, but its temporary image backups could not be removed."
  done
  return 0
}

nvidia_test_failure() {
  local failures=,${GOOARCHY_TEST_NVIDIA_FAIL:-},
  [[ $failures == *,$1,* ]]
}

nvidia_baseline_kernel_state() {
  local kernel=$1 expected=$2 preset image preset_bad
  local -A bad_presets=()
  NV_BASELINE_BAD_PRESETS=()
  NV_BASELINE_ERROR=
  nvidia_kernel_module_state "$kernel" "$expected" || NV_BASELINE_ERROR=$NV_KERNEL_ERROR
  nvidia_collect_kernel_presets "$kernel"
  for preset in "${NV_KERNEL_PRESETS[@]}"; do
    preset_bad=0
    nvidia_preset_images "$preset"
    if ((NV_IMAGES_UNRESOLVED)) || ((${#NV_IMAGES[@]} == 0)); then
      NV_BASELINE_ERROR="could not resolve every image path in ${preset##*/}"
      bad_presets[$preset]=1
      continue
    fi
    for image in "${NV_IMAGES[@]}"; do
      if ! sudo test -e "$image"; then
        NV_BASELINE_ERROR="image $image is missing"
        bad_presets[$preset]=1
        continue
      fi
      if ! nvidia_image_listable "$image"; then
        NV_BASELINE_ERROR="image $image is absent or cannot be listed"
        bad_presets[$preset]=1
        continue
      fi
      if ! nvidia_image_module_state "$image" "$expected"; then
        NV_BASELINE_ERROR="image $image: ${NV_IMAGE_ERROR:-inconsistent NVIDIA modules}"
        preset_bad=1
      fi
    done
    ((preset_bad)) && bad_presets[$preset]=1
  done
  NV_BASELINE_BAD_PRESETS=("${!bad_presets[@]}")
}

nvidia_kernel_user_partial_state() {
  local kernel=$1 expected=$2 preset image file module entry idx matches probe_state
  local -A seen_files=()
  local -A image_modules=()
  local -A probe_states=()
  local -a source_files=()
  NV_USER_PARTIAL=0
  NV_USER_PARTIAL_UNKNOWN=0
  NV_USER_PARTIAL_FILE=
  nvidia_kernel_is_covered "$kernel" "$expected" && return 0
  nvidia_collect_kernel_presets "$kernel"
  for preset in "${NV_KERNEL_PRESETS[@]}"; do
    nvidia_preset_images "$preset"
    if ((NV_IMAGES_UNRESOLVED)) || ((${#NV_IMAGES[@]} == 0)); then
      NV_USER_PARTIAL_UNKNOWN=1
      continue
    fi
    probe_states=()
    for idx in "${!NV_IMAGES[@]}"; do
      image=${NV_IMAGES[$idx]}
      entry=${NV_IMAGE_ENTRIES[$idx]}
      if ! nvidia_image_listable "$image"; then
        NV_USER_PARTIAL_UNKNOWN=1
        continue
      fi
      nvidia_image_module_state "$image" "$expected" || true
      ((NV_IMAGE_HAS_NVIDIA)) || continue
      image_modules=()
      for module in "${!NV_IMAGE_MODULE_SET[@]}"; do
        image_modules[$module]=1
      done
      probe_state=${probe_states[$entry]:-0}
      if ((probe_state == 0)); then
        if nvidia_probe_config_modules "$preset" "$kernel" "$expected" 1 "$entry"; then
          probe_state=1
        else
          probe_state=2
          if nvidia_literal_config_module_set "$preset" "$entry"; then
            for module in "${!NV_CONFIG_PROBE_MODULE_SET[@]}"; do
              if [[ ${image_modules[$module]:-} ]]; then
                probe_state=1
                break
              fi
            done
          fi
          ((probe_state == 1)) || NV_USER_PARTIAL_UNKNOWN=1
        fi
        probe_states[$entry]=$probe_state
      fi
      ((probe_state == 1)) || continue
      matches=0
      for module in "${!image_modules[@]}"; do
        [[ ${NV_CONFIG_PROBE_MODULE_SET[$module]:-} ]] && { matches=1; break; }
      done
      ((matches)) || continue
      NV_USER_PARTIAL=1
      nvidia_user_config_source_files "$preset" "$entry" || true
      for file in "${NV_USER_CONFIG_SOURCE_FILES[@]}"; do
        [[ ${seen_files[$file]:-} ]] && continue
        seen_files[$file]=1
        source_files+=("$file")
      done
    done
  done
  if ((NV_USER_PARTIAL_UNKNOWN)); then
    for preset in "${NV_KERNEL_PRESETS[@]}"; do
      nvidia_preset_images "$preset"
      ((NV_IMAGES_UNRESOLVED == 0)) || continue
      for entry in "${NV_PRESET_ENTRIES[@]}"; do
        nvidia_user_config_source_files "$preset" "$entry" || continue
        for file in "${NV_USER_CONFIG_SOURCE_FILES[@]}"; do
          [[ ${seen_files[$file]:-} ]] && continue
          seen_files[$file]=1
          source_files+=("$file")
        done
      done
    done
  fi
  if ((${#source_files[@]})); then
    NV_USER_PARTIAL_FILE=$(nvidia_list "${source_files[@]}")
  fi
  return 0
}

nvidia_sound_fallback_kernels() {
  local excluded=$1 expected=$2 kernel
  NV_SOUND_FALLBACKS=()
  for kernel in "${NV_KERNELS[@]}"; do
    [[ $kernel == "$excluded" ]] && continue
    nvidia_collect_kernel_presets "$kernel"
    ((${#NV_KERNEL_PRESETS[@]})) || continue
    nvidia_baseline_kernel_state "$kernel" "$expected"
    [[ -z $NV_BASELINE_ERROR ]] || continue
    nvidia_kernel_user_partial_state "$kernel" "$expected"
    ((NV_USER_PARTIAL == 0 && NV_USER_PARTIAL_UNKNOWN == 0)) || continue
    NV_SOUND_FALLBACKS+=("${NV_PKGBASE[$kernel]} ($kernel)")
  done
  return 0
}

nvidia_stale_recovery_text() {
  local kernel=$1 expected=$2 fallbacks
  nvidia_kernel_user_partial_state "$kernel" "$expected"
  NV_STALE_PARTIAL_NOTE=
  if ((NV_USER_PARTIAL)); then
    NV_STALE_PARTIAL_NOTE=" The stale kernel is a user partial kernel because ${NV_USER_PARTIAL_FILE} places NVIDIA modules in its images; Gooarchy makes no desktop promise for it."
  elif ((NV_USER_PARTIAL_UNKNOWN)); then
    NV_STALE_PARTIAL_NOTE=" The effective user NVIDIA module set for this kernel could not be classified safely, so it is not listed as a sound fallback."
  fi
  nvidia_sound_fallback_kernels "$kernel" "$expected"
  if ((${#NV_SOUND_FALLBACKS[@]})); then
    fallbacks=$(nvidia_list "${NV_SOUND_FALLBACKS[@]}")
    NV_STALE_RECOVERY="Recovery: boot one of these other sound, non-user-partial kernels: $fallbacks, or boot Arch install media and run mkinitcpio -P inside the installed system."
  else
    NV_STALE_RECOVERY="No other sound, non-user-partial kernel was found. Recovery: boot Arch install media and run mkinitcpio -P inside the installed system."
  fi
}

nvidia_repair_stale_baseline() {
  local kernel=$1 expected=$2 build_status=0 preset
  nvidia_baseline_kernel_state "$kernel" "$expected"
  [[ -z $NV_BASELINE_ERROR ]] && return 0
  nvidia_report "found an NVIDIA image baseline out of step for ${NV_PKGBASE[$kernel]} kernel $kernel: $NV_BASELINE_ERROR; attempting to repair it before changing NVIDIA packages."

  nvidia_kernel_module_state "$kernel" "$expected" || true
  if [[ -n $NV_KERNEL_ERROR ]] || ((!NV_KERNEL_HAS_ALL)); then
    if pacman -Q nvidia-open-dkms >/dev/null 2>&1 && nvidia_kernel_has_headers "$kernel"; then
      if nvidia_test_failure "dkms:$kernel"; then
        build_status=99
      else
        sudo dkms autoinstall -k "$kernel" || build_status=$?
      fi
      nvidia_kernel_module_state "$kernel" "$expected" || true
      [[ -z $NV_KERNEL_ERROR ]] || return 1
    fi
  fi

  nvidia_baseline_kernel_state "$kernel" "$expected"
  for preset in "${NV_BASELINE_BAD_PRESETS[@]}"; do
    nvidia_regenerate_kernel_images "$kernel" stale "$preset" "$expected" || return 1
  done
  nvidia_baseline_kernel_state "$kernel" "$expected"
  [[ -z $NV_BASELINE_ERROR ]]
}

nvidia_config_has_nouveau() {
  local file text
  for file in /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d/*.conf; do
    [[ -f $file ]] || continue
    text=$(nvidia_config_module_text "$file")
    text=${text//[()]/ }
    [[ $text =~ (^|[[:space:]])nouveau[?]?([[:space:]]|$) ]] && return 0
  done
  for file in /etc/modprobe.d/*.conf; do
    [[ -f $file ]] || continue
    if awk '!/^[[:space:]]*#/ && /^[[:space:]]*(install|softdep)[[:space:]]+nouveau([[:space:]]|$)/ { found=1 } END { exit !found }' "$file"; then
      return 0
    fi
  done
  return 1
}

nvidia_report_suspend_overrides() {
  local file
  for file in /etc/modprobe.d/*.conf; do
    [[ -f $file ]] || continue
    awk '
      { sub(/[[:space:]]*#.*/, "") }
      /^[[:space:]]*$/ { next }
      /^[[:space:]]*options[[:space:]]+nvidia([[:space:]]|$).*NVreg_UseKernelSuspendNotifiers[[:space:]]*=[[:space:]]*0/ { found=1 }
      /^[[:space:]]*options[[:space:]]+nvidia([[:space:]]|$).*NVreg_PreserveVideoMemoryAllocations[[:space:]]*=[[:space:]]*1/ { found=1 }
      END { exit !found }
    ' "$file" && nvidia_report "left the user's NVIDIA suspend configuration in $file unchanged; kernel suspend notifiers or video-memory preservation are user-configured, and Gooarchy does not change the NVIDIA sleep services."
  done
  return 0
}

nvidia_owned_config_version() {
  local file=$1
  [[ -f $file ]] || return 1
  grep -Fxq '# Gooarchy NVIDIA early KMS modules; managed by the Gooarchy installer.' "$file" || return 1
  sed -n "s/^GOOARCHY_NVIDIA_MODULE_VERSION='\([^']*\)'$/\1/p" "$file" | head -n 1
}

nvidia_owned_config_content() {
  cat <<EOF
# Gooarchy NVIDIA early KMS modules; managed by the Gooarchy installer.
GOOARCHY_NVIDIA_MODULE_VERSION='$1'
GOOARCHY_NVIDIA_PKGBASE=
GOOARCHY_NVIDIA_KERNEL_PACKAGE=
GOOARCHY_NVIDIA_HEADERS_PACKAGE=
if [[ -n \${KERNELVERSION:-} && -r "/usr/lib/modules/\${KERNELVERSION:-}/pkgbase" ]]; then
  GOOARCHY_NVIDIA_PKGBASE=\$(<"/usr/lib/modules/\${KERNELVERSION:-}/pkgbase")
  if [[ -n \$GOOARCHY_NVIDIA_PKGBASE ]]; then
    GOOARCHY_NVIDIA_KERNEL_PACKAGE=\$(pacman -Q "\$GOOARCHY_NVIDIA_PKGBASE" 2>/dev/null || true)
    GOOARCHY_NVIDIA_HEADERS_PACKAGE=\$(pacman -Q "\$GOOARCHY_NVIDIA_PKGBASE-headers" 2>/dev/null || true)
  fi
fi
GOOARCHY_NVIDIA_TREE_MATCHES=0
if [[ -n \${KERNELVERSION:-} ]]; then
  GOOARCHY_NVIDIA_TREE_MATCHES=1
  while IFS= read -r -d '' GOOARCHY_NVIDIA_MODULE_FILE; do
    GOOARCHY_NVIDIA_TREE_MODULE_VERSION=\$(modinfo -F version "\$GOOARCHY_NVIDIA_MODULE_FILE" 2>/dev/null || true)
    if [[ \$GOOARCHY_NVIDIA_TREE_MODULE_VERSION != \$GOOARCHY_NVIDIA_MODULE_VERSION ]]; then
      GOOARCHY_NVIDIA_TREE_MATCHES=0
      break
    fi
  done < <(find "/usr/lib/modules/\${KERNELVERSION:-}" -type f \\
    \\( -name 'nvidia.ko*' -o -name 'nvidia_modeset.ko*' -o -name 'nvidia_uvm.ko*' -o -name 'nvidia_drm.ko*' \\
       -o -name 'nvidia-modeset.ko*' -o -name 'nvidia-uvm.ko*' -o -name 'nvidia-drm.ko*' \\) -print0 2>/dev/null)
fi
if [[ -n \${GOOARCHY_NVIDIA_KERNEL_PACKAGE#* } ]] &&
   [[ \${GOOARCHY_NVIDIA_KERNEL_PACKAGE#* } == \${GOOARCHY_NVIDIA_HEADERS_PACKAGE#* } ]] &&
   [[ \$GOOARCHY_NVIDIA_TREE_MATCHES == 1 ]] &&
   [[ \$(modinfo -k "\${KERNELVERSION:-}" -F version nvidia 2>/dev/null || true) == \$GOOARCHY_NVIDIA_MODULE_VERSION ]] &&
   [[ \$(modinfo -k "\${KERNELVERSION:-}" -F version nvidia_modeset 2>/dev/null || true) == \$GOOARCHY_NVIDIA_MODULE_VERSION ]] &&
   [[ \$(modinfo -k "\${KERNELVERSION:-}" -F version nvidia_uvm 2>/dev/null || true) == \$GOOARCHY_NVIDIA_MODULE_VERSION ]] &&
   [[ \$(modinfo -k "\${KERNELVERSION:-}" -F version nvidia_drm 2>/dev/null || true) == \$GOOARCHY_NVIDIA_MODULE_VERSION ]]; then
  MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
fi
EOF
}

nvidia_owned_config_is_valid() {
  local version content expected_hash actual_hash
  version=$(nvidia_owned_config_version "$NV_OWNED_CONFIG" 2>/dev/null) || return 1
  content=$(nvidia_owned_config_content "$version")
  expected_hash=$(printf '%s\n' "$content" | sha256sum | awk '{print $1}')
  actual_hash=$(sha256sum "$NV_OWNED_CONFIG" 2>/dev/null | awk '{print $1}')
  [[ -n $actual_hash && $actual_hash == "$expected_hash" ]]
}

nvidia_any_covered_kernel() {
  local expected=$1 kernel
  for kernel in "${NV_KERNELS[@]}"; do
    if nvidia_kernel_is_covered "$kernel" "$expected"; then
      printf '%s\n' "$kernel"
      return 0
    fi
  done
  return 1
}

nvidia_covered_kernel_for_preset() {
  local preset=$1 expected=$2 kernel base=${1##*/}
  base=${base%.preset}
  for kernel in "${NV_KERNELS[@]}"; do
    [[ ${NV_PKGBASE[$kernel]} == "$base" ]] || continue
    if nvidia_kernel_is_covered "$kernel" "$expected"; then
      printf '%s\n' "$kernel"
      return 0
    fi
  done
  return 1
}

nvidia_preset_has_all_modules() {
  local preset=$1 entry=$2 kernel=$3 expected=$4 config status owned_version
  config=$(nvidia_preset_config "$preset" "$entry")
  [[ $config != __GOOARCHY_UNRESOLVED_CONFIG__ ]] || return 2
  if [[ -n $config ]]; then
    if [[ $config == "$NV_OWNED_CONFIG" ]] && nvidia_owned_config_is_valid; then
      owned_version=$(nvidia_owned_config_version "$NV_OWNED_CONFIG" 2>/dev/null || true)
      [[ $owned_version == "$expected" ]] && nvidia_kernel_is_covered "$kernel" "$expected" && return 0
      return 1
    fi
    nvidia_config_has_all_modules "$config" && return 0
  else
    owned_version=$(nvidia_owned_config_version "$NV_OWNED_CONFIG" 2>/dev/null || true)
    if ((NV_OWNED_CONFIG_VALID)) && [[ $owned_version == "$expected" ]] && nvidia_kernel_is_covered "$kernel" "$expected"; then
      return 0
    fi
    nvidia_user_config_has_all_modules && return 0
  fi
  ((NV_CONFIG_DYNAMIC)) || return 1
  if nvidia_probe_config_has_all_modules "$preset" "$kernel" "$expected" "$entry"; then
    return 0
  else
    status=$?
  fi
  return "$status"
}

nvidia_set_early_kms_config() {
  local module_version=$1 existing_version tmp preset config old_content expected_hash actual_hash idx entry
  local probe_kernel probe_status probe_error
  NV_OWNED_CONFIG_VALID=0
  if ! command -v mkinitcpio >/dev/null 2>&1; then
    for preset in $(nvidia_preset_files); do
      nvidia_preset_images "$preset"
      if ((NV_IMAGES_UNRESOLVED)); then
        nvidia_report "could not resolve the active images and configurations in ${preset##*/}; mkinitcpio is unavailable and early KMS was not set up."
        continue
      fi
      for idx in "${!NV_IMAGES[@]}"; do
        entry=${NV_IMAGE_ENTRIES[$idx]}
        config=${NV_IMAGE_CONFIGS[$idx]:-/etc/mkinitcpio.conf}
        [[ -n $config ]] || config=/etc/mkinitcpio.conf
        nvidia_report "the ${entry} image in ${preset##*/} uses $config, but mkinitcpio is unavailable; its image and configuration were left unchanged and NVIDIA early KMS was not set up."
      done
    done
    return 0
  fi
  existing_version=$(nvidia_owned_config_version "$NV_OWNED_CONFIG" 2>/dev/null || true)
  if [[ -e $NV_OWNED_CONFIG && -z $existing_version ]]; then
    nvidia_report "left $NV_OWNED_CONFIG unchanged because it already exists with content Gooarchy did not write; early KMS is not set up by Gooarchy for presets that use it."
    return 2
  fi
  if [[ -n $existing_version ]]; then
    old_content=$(nvidia_owned_config_content "$existing_version")
    expected_hash=$(printf '%s\n' "$old_content" | sha256sum | awk '{print $1}')
    actual_hash=$(sha256sum "$NV_OWNED_CONFIG" | awk '{print $1}')
    if [[ $actual_hash != "$expected_hash" ]]; then
      nvidia_report "left $NV_OWNED_CONFIG unchanged because its content does not match Gooarchy's prior file; early KMS is not set up by Gooarchy."
      return 2
    fi
    NV_OWNED_CONFIG_VALID=1
  fi

  local need_config=0
  for preset in $(nvidia_preset_files); do
    nvidia_preset_images "$preset"
    ((NV_IMAGES_UNRESOLVED == 0)) || nvidia_fail "could not resolve active images and configurations in ${preset##*/}; no NVIDIA configuration was changed."
    for idx in "${!NV_IMAGES[@]}"; do
      entry=${NV_IMAGE_ENTRIES[$idx]}
      config=${NV_IMAGE_CONFIGS[$idx]}
      if [[ -z $config ]]; then
        if ((NV_OWNED_CONFIG_VALID)) && [[ $existing_version == "$module_version" ]] && nvidia_any_covered_kernel "$module_version" >/dev/null; then
          continue
        elif nvidia_user_config_has_all_modules; then
          continue
        elif ((NV_CONFIG_DYNAMIC)); then
          probe_kernel=$(nvidia_any_covered_kernel "$module_version" || true)
          # An uncovered-only installation has no safe kernel on which to evaluate the user's
          # dynamic list. Leave it alone; a later run can decide when a kernel becomes covered.
          [[ -n $probe_kernel ]] || continue
          if nvidia_probe_config_has_all_modules "$preset" "$probe_kernel" "$module_version" "$entry"; then
            continue
          else
            probe_status=$?
            if ((probe_status != 1)); then
              probe_error=${NV_CONFIG_PROBE_ERROR:-}
              [[ -n $probe_error ]] || probe_error="could not determine whether the dynamic mkinitcpio MODULES configuration already supplies all four NVIDIA modules"
              nvidia_fail "$probe_error; the configuration and images were left unchanged. Inspect mkinitcpio, then rerun."
            fi
            need_config=1
          fi
        else
          need_config=1
        fi
      elif [[ $config == "$NV_OWNED_CONFIG" ]] && nvidia_owned_config_is_valid; then
        if [[ $existing_version == "$module_version" ]]; then continue; fi
        need_config=1
      elif [[ -f $config ]]; then
        if nvidia_config_has_all_modules "$config"; then
          continue
        elif ((NV_CONFIG_DYNAMIC)); then
          probe_kernel=$(nvidia_covered_kernel_for_preset "$preset" "$module_version" || true)
          [[ -n $probe_kernel ]] || {
            nvidia_report "the ${entry} image in ${preset##*/} reads $config directly; no covered kernel is available to inspect its dynamic MODULES effect, so its configuration and image were left unchanged."
            continue
          }
          if nvidia_probe_config_has_all_modules "$preset" "$probe_kernel" "$module_version" "$entry"; then
            continue
          else
            probe_status=$?
            if ((probe_status == 2)); then
              nvidia_report "${NV_CONFIG_PROBE_ERROR:-could not inspect the dynamic configuration used by ${entry} in ${preset##*/}}; left $config and its image unchanged and did not set up NVIDIA early KMS for that image."
            else
              nvidia_report "the ${entry} image in ${preset##*/} reads $config directly, so NVIDIA was not added to its initramfs (the driver still loads later in boot). To load it early, add nvidia nvidia_modeset nvidia_uvm nvidia_drm to that file, then run sudo mkinitcpio -P."
            fi
          fi
        else
          # This image bypasses drop-ins. Its chosen config and image stay untouched.
          nvidia_report "the ${entry} image in ${preset##*/} reads $config directly, so NVIDIA was not added to its initramfs (the driver still loads later in boot). To load it early, add nvidia nvidia_modeset nvidia_uvm nvidia_drm to that file, then run sudo mkinitcpio -P."
        fi
      else
        if nvidia_user_config_has_all_modules; then
          continue
        fi
        nvidia_report "the ${entry} image in ${preset##*/} selects $config, which is unavailable for inspection; NVIDIA was not added to its initramfs."
      fi
    done
  done
  ((need_config)) || return 0
  [[ $existing_version == "$module_version" ]] && return 0

  sudo mkdir -p "$(dirname "$NV_OWNED_CONFIG")" || nvidia_fail "could not create the mkinitcpio drop-in directory."
  tmp=$(sudo mktemp "$(dirname "$NV_OWNED_CONFIG")/.gooarchy-nvidia.XXXXXXXX") || nvidia_fail "could not prepare the owned NVIDIA mkinitcpio drop-in."
  nvidia_owned_config_content "$module_version" | sudo tee "$tmp" >/dev/null || {
    sudo rm -f "$tmp"
    nvidia_fail "could not write the owned NVIDIA mkinitcpio drop-in."
  }
  sudo chmod 0644 "$tmp" || { sudo rm -f "$tmp"; nvidia_fail "could not set permissions on the owned NVIDIA mkinitcpio drop-in."; }
  if [[ -e $NV_OWNED_CONFIG ]]; then
    sudo mv "$tmp" "$NV_OWNED_CONFIG" || { sudo rm -f "$tmp"; nvidia_fail "could not update the owned NVIDIA mkinitcpio drop-in."; }
    nvidia_report "updated $NV_OWNED_CONFIG for NVIDIA driver module version $module_version."
  else
    sudo mv "$tmp" "$NV_OWNED_CONFIG" || { sudo rm -f "$tmp"; nvidia_fail "could not add the owned NVIDIA mkinitcpio drop-in."; }
    nvidia_report "added $NV_OWNED_CONFIG for NVIDIA early KMS; remove this file and run sudo mkinitcpio -P to undo."
  fi
  NV_OWNED_CONFIG_VALID=1
}

nvidia_report_uncovered_kernel() {
  local kernel=$1 reason=$2 log=/var/lib/dkms/nvidia/${NV_DRIVER_MODULE_VERSION:-unknown}/build/make.log
  local undo= source_detail=${NV_USER_PARTIAL_FILE:-the effective mkinitcpio configuration}
  if ((${#NV_REPLACED_PACKAGES[@]})); then
    undo=" The replaced prebuilt driver can be restored with sudo pacman -S ${NV_REPLACED_PACKAGES[*]}."
  fi
  if [[ $reason == *DKMS* ]]; then
    [[ -f $log ]] || log+=" (not found)"
    reason+=". DKMS build log: $log"
  fi
  if (( ${NV_USER_PARTIAL:-0} )); then
    nvidia_report "${NV_PKGBASE[$kernel]} kernel $kernel is an uncovered user partial kernel: $reason. Its images contain NVIDIA modules produced by the user's mkinitcpio configuration in $NV_USER_PARTIAL_FILE, which install.sh left unchanged. Gooarchy does not promise this kernel reaches the desktop. Fix: remove the NVIDIA module settings from those files and run sudo mkinitcpio -P, or rerun install.sh once this kernel can be covered; its module versions, firmware and image consistency remain checked.${undo}"
  elif (( ${NV_USER_PARTIAL_UNKNOWN:-0} )); then
    nvidia_report "${NV_PKGBASE[$kernel]} kernel $kernel is uncovered: $reason. Gooarchy could not classify the NVIDIA module effect in its initramfs using $source_detail; inspect it and remove any NVIDIA module settings if the kernel should reach the desktop. A8 fallback on real NVIDIA hardware is UNEXERCISED.${undo}"
  else
    nvidia_report "${NV_PKGBASE[$kernel]} kernel $kernel is uncovered: $reason. Its images contain no user-configured NVIDIA modules; A8 fallback on real NVIDIA hardware is UNEXERCISED.${undo}"
  fi
}

nvidia_report_partial_failure_if_present() {
  local kernel=$1 expected=$2 reason=$3
  nvidia_kernel_user_partial_state "$kernel" "$expected"
  if ((NV_USER_PARTIAL)); then
    nvidia_report_uncovered_kernel "$kernel" "$reason"
  fi
}

nvidia_ensure_uncovered_images() {
  local kernel=$1 reason=$2 preset image config preset_early_kms r11_preset needs_regeneration=0 idx entry entry_key selected_entry_text
  local -a regenerate_presets=() selected_entries=()
  local -A regenerate_seen=() regenerate_entry_seen=() regenerate_entry_list=()
  nvidia_collect_kernel_presets "$kernel"
  if ((${#NV_KERNEL_PRESETS[@]} == 0)); then
    NV_USER_PARTIAL=0
    NV_USER_PARTIAL_FILE=
    nvidia_report_uncovered_kernel "$kernel" "$reason"
    return 0
  fi
  for preset in "${NV_KERNEL_PRESETS[@]}"; do
    nvidia_preset_images "$preset"
    if ((NV_IMAGES_UNRESOLVED)) || ((${#NV_IMAGES[@]} == 0)); then
      nvidia_report "could not resolve the active image paths and configurations in ${preset##*/}; its outputs were left unchanged. Repair the user's preset, then rerun."
      nvidia_report_partial_failure_if_present "$kernel" "$NV_DRIVER_MODULE_VERSION" "$reason; image paths in ${preset##*/} are unresolved or absent"
      return 1
    fi
    for idx in "${!NV_IMAGES[@]}"; do
      image=${NV_IMAGES[$idx]}
      entry=${NV_IMAGE_ENTRIES[$idx]}
      config=${NV_IMAGE_CONFIGS[$idx]}
      if nvidia_preset_has_all_modules "$preset" "$entry" "$kernel" "$NV_DRIVER_MODULE_VERSION"; then
        preset_early_kms=1
      else
        preset_early_kms=0
      fi
      if ((preset_early_kms == 0)) && [[ -n $config ]]; then r11_preset=1; else r11_preset=0; fi
      if ! nvidia_image_listable "$image"; then
        if ((r11_preset)); then
          nvidia_report "image $image for active ${entry} in ${preset##*/} uses $config, bypasses Gooarchy's drop-in, and is absent or cannot be listed; the step left it unchanged. Repair the user's preset image, then rerun."
          nvidia_report_partial_failure_if_present "$kernel" "$NV_DRIVER_MODULE_VERSION" "$reason; image $image is absent or cannot be listed"
          return 1
        fi
        needs_regeneration=1
        if [[ ! ${regenerate_seen[$preset]:-} ]]; then
          regenerate_seen[$preset]=1
          regenerate_presets+=("$preset")
        fi
        entry_key="$preset|$entry"
        if [[ ! ${regenerate_entry_seen[$entry_key]:-} ]]; then
          regenerate_entry_seen[$entry_key]=1
          regenerate_entry_list[$preset]+="${regenerate_entry_list[$preset]:+ }$entry"
        fi
        continue
      fi
      if ! nvidia_image_module_state "$image" "$NV_DRIVER_MODULE_VERSION"; then
        needs_regeneration=1
        if ((r11_preset)); then
          nvidia_report "image $image for active ${entry} in ${preset##*/} uses $config and has an NVIDIA module version or firmware mismatch; the step left this direct-config image unchanged. Repair the user's preset image, then rerun."
          nvidia_report_partial_failure_if_present "$kernel" "$NV_DRIVER_MODULE_VERSION" "$reason; image $image has a version or firmware mismatch"
          return 1
        fi
        if [[ ! ${regenerate_seen[$preset]:-} ]]; then
          regenerate_seen[$preset]=1
          regenerate_presets+=("$preset")
        fi
        entry_key="$preset|$entry"
        if [[ ! ${regenerate_entry_seen[$entry_key]:-} ]]; then
          regenerate_entry_seen[$entry_key]=1
          regenerate_entry_list[$preset]+="${regenerate_entry_list[$preset]:+ }$entry"
        fi
      fi
    done
  done
  if ((needs_regeneration)); then
    command -v mkinitcpio >/dev/null 2>&1 || {
      nvidia_report "uncovered kernel $kernel needs regenerated NVIDIA images, but mkinitcpio is unavailable; the user configuration and images were left unchanged."
      return 1
    }
    for preset in "${regenerate_presets[@]}"; do
      selected_entry_text=${regenerate_entry_list[$preset]:-}
      selected_entries=()
      read -r -a selected_entries <<<"$selected_entry_text"
      if ((${#selected_entries[@]} == 0)); then
        nvidia_report "no active preset entries were selected for uncovered-image repair in ${preset##*/}."
        return 1
      fi
      if ! nvidia_regenerate_kernel_images "$kernel" uncovered "$preset" "$NV_DRIVER_MODULE_VERSION" "${selected_entries[@]}"; then
        nvidia_report_partial_failure_if_present "$kernel" "$NV_DRIVER_MODULE_VERSION" "$reason"
        return 1
      fi
    done
  fi
  for preset in "${NV_KERNEL_PRESETS[@]}"; do
    nvidia_preset_images "$preset"
    if ((NV_IMAGES_UNRESOLVED)) || ((${#NV_IMAGES[@]} == 0)); then
      nvidia_report_partial_failure_if_present "$kernel" "$NV_DRIVER_MODULE_VERSION" "$reason; image paths in ${preset##*/} became unresolved or absent"
      return 1
    fi
    for idx in "${!NV_IMAGES[@]}"; do
      image=${NV_IMAGES[$idx]}
      if ! nvidia_image_listable "$image"; then
        nvidia_report_partial_failure_if_present "$kernel" "$NV_DRIVER_MODULE_VERSION" "$reason"
        return 1
      fi
      if ! nvidia_image_module_state "$image" "$NV_DRIVER_MODULE_VERSION"; then
        nvidia_report_partial_failure_if_present "$kernel" "$NV_DRIVER_MODULE_VERSION" "$reason"
        return 1
      fi
    done
  done
  nvidia_kernel_user_partial_state "$kernel" "$NV_DRIVER_MODULE_VERSION"
  nvidia_report_uncovered_kernel "$kernel" "$reason"
  return 0
}

nvidia_report_other_user_partial_kernels() {
  local failed_kernel=$1 kernel reason partial partial_file
  for kernel in "${NV_KERNELS[@]}"; do
    if [[ $failed_kernel == __package_hook_failures__ ]]; then
      [[ -n ${NV_PACKAGE_HOOK_FAILURES[$kernel]:-} ]] && continue
    else
      [[ $kernel == "$failed_kernel" ]] && continue
    fi
    nvidia_kernel_user_partial_state "$kernel" "$NV_DRIVER_MODULE_VERSION"
    ((NV_USER_PARTIAL)) || continue
    partial=1
    partial_file=$NV_USER_PARTIAL_FILE
    if ! nvidia_kernel_has_headers "$kernel"; then
      reason="no matching ${NV_PKGBASE[$kernel]}-headers package is installed"
    else
      nvidia_kernel_module_state "$kernel" "$NV_DRIVER_MODULE_VERSION" || true
      if [[ -n $NV_KERNEL_ERROR ]]; then
        reason="$NV_KERNEL_ERROR; DKMS did not cover the kernel"
      else
        reason="DKMS did not build all four modules"
      fi
    fi
    if ! nvidia_ensure_uncovered_images "$kernel" "$reason"; then
      NV_USER_PARTIAL=$partial
      NV_USER_PARTIAL_FILE=$partial_file
      nvidia_report_uncovered_kernel "$kernel" "$reason"
      nvidia_report "could not confirm consistent, listable NVIDIA images for user partial kernel $kernel while another kernel's image generation failed."
    fi
  done
  return 0
}

nvidia_report_direct_config_hook_failure() {
  local kernel=$1 pkgbase=${NV_PKGBASE[$1]:-} preset entry config reason idx
  local -A reported_entries=()
  [[ -n $pkgbase ]] || return 0
  preset=/etc/mkinitcpio.d/$pkgbase.preset
  [[ -f $preset ]] || return 0
  nvidia_preset_images "$preset"
  ((NV_IMAGES_UNRESOLVED == 0)) || return 0
  for idx in "${!NV_IMAGES[@]}"; do
    entry=${NV_IMAGE_ENTRIES[$idx]}
    [[ ! ${reported_entries[$entry]:-} ]] || continue
    reported_entries[$entry]=1
    config=${NV_IMAGE_CONFIGS[$idx]}
    [[ -n $config && $config != __GOOARCHY_UNRESOLVED_CONFIG__ &&
       $config != "$NV_OWNED_CONFIG" && -f $config ]] || continue
    nvidia_config_has_all_modules "$config" && continue
    if ((NV_CONFIG_DYNAMIC)); then
      reason="its dynamic MODULES effect could not be determined"
    else
      reason="its literal MODULES value does not contain all four NVIDIA modules"
    fi
    nvidia_report "the ${entry} image in ${preset##*/} reads $config directly; $reason. Gooarchy left that named config and the prior image unchanged after the package hook failure. To load NVIDIA early, add nvidia nvidia_modeset nvidia_uvm nvidia_drm to that file, then run sudo mkinitcpio -P."
  done
}

nvidia_fail_if_package_hook_failed() {
  local kernel=$1 failure=${NV_PACKAGE_HOOK_FAILURES[$1]:-}
  [[ -n $failure ]] || return 0
  nvidia_kernel_user_partial_state "$kernel" "$NV_DRIVER_MODULE_VERSION"
  if ((NV_USER_PARTIAL || NV_USER_PARTIAL_UNKNOWN)); then
    nvidia_report_uncovered_kernel "$kernel" \
      "pacman's post-transaction mkinitcpio hook reported an image-generation error: $failure"
  else
    nvidia_report_direct_config_hook_failure "$kernel"
  fi
  nvidia_report_other_user_partial_kernels "$kernel"
  nvidia_fail "pacman's post-transaction mkinitcpio hook reported an image-generation error for ${NV_PKGBASE[$kernel]} kernel $kernel: $failure. The step checked or repaired the image state where possible, but the hook error remains a failure; resolve it and rerun."
}

nvidia_install() {
  nvidia_collect_devices
  if ((${#NV_SUPPORTED[@]} == 0 && ${#NV_LEGACY[@]} == 0)); then
    echo 'NVIDIA: no NVIDIA display function found; no NVIDIA changes made.'
    return 0
  fi
  if ((${#NV_SUPPORTED[@]} == 0)); then
    echo "NVIDIA: legacy-only device(s) $(nvidia_list "${NV_LEGACY[@]}"); leaving them on the desktop fallback."
    nvidia_report "left legacy NVIDIA GPU(s) $(nvidia_list "${NV_LEGACY[@]}") without a driver: Arch's current NVIDIA driver supports Turing (GTX 16 / RTX 20) and newer; the desktop uses the plainer fallback."
    return 0
  fi
  if ((${#NV_LEGACY[@]})); then
    nvidia_report "left legacy NVIDIA GPU(s) $(nvidia_list "${NV_LEGACY[@]}") without a driver: Arch's current NVIDIA driver supports Turing (GTX 16 / RTX 20) and newer; the desktop uses the plainer fallback on those devices."
  fi
  if ((NV_BUILTIN_BOOT)); then
    echo "NVIDIA: supported display function(s) $(nvidia_list "${NV_SUPPORTED[@]}"); the built-in GPU is the boot GPU, so Gooarchy leaves render selection to the desktop."
  else
    echo "NVIDIA: supported display function(s) $(nvidia_list "${NV_SUPPORTED[@]}"); setting up Arch's open driver."
  fi

  local foreign
  foreign=$(nvidia_find_foreign_driver_packages)
  if [[ -n $foreign ]]; then
    nvidia_report "left the NVIDIA driver as configured because foreign NVIDIA driver package(s) are installed: ${foreign//$'\n'/, }."
    return 0
  fi
  nvidia_check_repo_versions || return 0
  if ((${#NV_EXISTING_PACKAGES[@]})) && ! pacman -Q nvidia-utils >/dev/null 2>&1; then
    nvidia_report "left the existing NVIDIA driver unchanged because $(nvidia_list "${NV_EXISTING_VERSIONS[@]}") is installed without its matching nvidia-utils package. Repair that package set from Arch's repositories, then rerun."
    return 0
  fi

  nvidia_refuse_if_pacman_lock_exists

  nvidia_collect_kernels
  local utils_version installed_utils module_version kernel pkgbase headers_target kernel_package_version
  local -a header_targets=() driver_targets=() replacement_packages=() nonexplicit_headers=()
  local has_prebuilt=0 package
  utils_version=$(nvidia_sync_version extra/nvidia-utils) || nvidia_fail "Arch's extra repository does not currently provide nvidia-utils; no NVIDIA package was changed."
  local dkms_package_version utils_growth dkms_growth
  dkms_package_version=$(nvidia_sync_version extra/nvidia-open-dkms) || nvidia_fail "Arch's extra repository does not currently provide nvidia-open-dkms; no NVIDIA package was changed."
  [[ $dkms_package_version == "$utils_version" ]] || nvidia_fail "Arch's repositories currently carry nvidia-open-dkms $dkms_package_version and nvidia-utils $utils_version; no NVIDIA package was changed because the driver packages do not match."
  utils_growth=$(nvidia_sync_installed_size_kb extra/nvidia-utils || true)
  dkms_growth=$(nvidia_sync_installed_size_kb extra/nvidia-open-dkms || true)
  NV_IMAGE_GROWTH_KB=$(( ${utils_growth:-0} + ${dkms_growth:-0} ))
  ((NV_IMAGE_GROWTH_KB >= 131072)) || NV_IMAGE_GROWTH_KB=131072
  NV_DRIVER_MODULE_VERSION=$(nvidia_module_version_from_package "$utils_version")
  installed_utils=$(nvidia_pacman_version nvidia-utils 2>/dev/null || true)

  # A stale inherited baseline is repaired or refused before any package or owned-file mutation.
  if ((${#NV_EXISTING_PACKAGES[@]})); then
    module_version=$(nvidia_module_version_from_package "$installed_utils")
    for kernel in "${NV_KERNELS[@]}"; do
      nvidia_baseline_kernel_state "$kernel" "$module_version"
      if [[ -n $NV_BASELINE_ERROR ]]; then
        stale_error=$NV_BASELINE_ERROR
        if ! nvidia_repair_stale_baseline "$kernel" "$module_version"; then
          nvidia_stale_recovery_text "$kernel" "$module_version"
          nvidia_fail "${NV_PKGBASE[$kernel]} kernel $kernel may not reach the desktop because its inherited NVIDIA baseline is stale: $stale_error.${NV_STALE_PARTIAL_NOTE} ${NV_STALE_RECOVERY} The step made no NVIDIA package or owned-file change."
        fi
      fi
    done
  fi

  for kernel in "${NV_KERNELS[@]}"; do
    pkgbase=${NV_PKGBASE[$kernel]}
    if nvidia_kernel_has_headers "$kernel"; then continue; fi
    if headers_target=$(nvidia_headers_target "$kernel"); then
      header_targets+=("$headers_target")
      package=${headers_target%%=*}
      package=${package##*/}
      if pacman -Q "$package" >/dev/null 2>&1 && ! pacman -Qe "$package" >/dev/null 2>&1; then
        nonexplicit_headers+=("$package")
      fi
    fi
  done

  [[ -n $installed_utils ]] || driver_targets+=("extra/nvidia-utils=$utils_version")
  if ! pacman -Q nvidia-open-dkms >/dev/null 2>&1; then
    driver_targets+=("extra/nvidia-open-dkms=$dkms_package_version")
  fi
  if nvidia_test_failure "pacman:force-transaction" && pacman -Q nvidia-open-dkms >/dev/null 2>&1; then
    driver_targets+=("extra/nvidia-open-dkms=$dkms_package_version")
  fi
  for package in nvidia-open nvidia-open-lts; do
    if pacman -Q "$package" >/dev/null 2>&1; then
      has_prebuilt=1
      replacement_packages+=("$package")
    fi
  done
  NV_REPLACED_PACKAGES=("${replacement_packages[@]}")

  local -a all_targets=()
  all_targets+=("${driver_targets[@]}" "${header_targets[@]}")
  if ((${#all_targets[@]})); then
    if command -v mkinitcpio >/dev/null 2>&1; then nvidia_space_check; fi
    if nvidia_test_failure "pacman:before-commit"; then
      nvidia_fail "the NVIDIA package transaction failed before commit (GOOARCHY_TEST_NVIDIA_FAIL); no NVIDIA package, owned file, or image was changed."
    fi
    local -a pacman_args=(sudo pacman -S --asexplicit)
    nvidia_test_failure "pacman:force-transaction" || pacman_args+=(--needed)
    local prompt_input
    if ((has_prebuilt)); then
      pacman_args+=(--confirm)
      prompt_input=$(printf 'y\n%.0s' {1..8})
      if ! nvidia_run_pacman_transaction "${pacman_args[@]}" "${all_targets[@]}" <<<"$prompt_input"; then
        if pacman -Q nvidia-open >/dev/null 2>&1 || pacman -Q nvidia-open-lts >/dev/null 2>&1; then
          nvidia_fail "could not replace ${replacement_packages[*]} with nvidia-open-dkms before pacman committed the transaction; the prebuilt driver is still installed and no intended NVIDIA change was committed. Rerun after resolving the pacman refusal."
        fi
        nvidia_fail "the NVIDIA package transaction failed after pacman had begun changing packages. The installed state is left as pacman reported; inspect the install log and rerun before booting another kernel. To undo the prebuilt replacement, run sudo pacman -S ${replacement_packages[*]}."
      fi
    else
      pacman_args+=(--noconfirm)
      if ! nvidia_run_pacman_transaction "${pacman_args[@]}" "${all_targets[@]}"; then
        nvidia_fail "the NVIDIA package transaction failed before it could complete; no further NVIDIA configuration or image change was attempted. Rerun after resolving the pacman failure."
      fi
    fi
    for package in "${nonexplicit_headers[@]}"; do
      sudo pacman -D --asdeps "$package" || nvidia_fail "could not restore the dependency install reason for $package after the package transaction; the driver state is unchanged, but inspect pacman and rerun."
    done
  fi

  if nvidia_test_failure "interrupt:after-commit"; then
    nvidia_fail "Gooarchy VM test interrupted the NVIDIA step after the package transaction committed and before step-owned image generation. Rerun install.sh to finish setup."
  fi

  NV_DRIVER_MODULE_VERSION=$(nvidia_module_version_from_package "$utils_version")

  if nvidia_config_has_nouveau; then
    nvidia_report "the user's configuration explicitly loads nouveau; Gooarchy left it unchanged, so the NVIDIA driver cannot take the GPU while that configuration remains."
  fi
  nvidia_report_suspend_overrides
  if grep -RHE '^[[:space:]]*options[[:space:]]+nvidia_drm([[:space:]]|$).*modeset[[:space:]]*=[[:space:]]*0' /etc/modprobe.d 2>/dev/null; then
    nvidia_report "the user's nvidia_drm modeset setting is off; Gooarchy left it unchanged. The installed driver default enables modeset when no override is present."
  fi
  if [[ -r /sys/module/nvidia_drm/parameters/modeset && $(</sys/module/nvidia_drm/parameters/modeset) == N ]]; then
    nvidia_report "nvidia_drm is currently loaded with modeset disabled; Gooarchy did not change the user's module configuration."
  fi

  local expected build_status image_status preset config covered stale_error uncovered_reason idx entry
  nvidia_set_early_kms_config "$NV_DRIVER_MODULE_VERSION" || true
  for kernel in "${NV_KERNELS[@]}"; do
    expected=$NV_DRIVER_MODULE_VERSION
    if ! nvidia_kernel_has_headers "$kernel"; then
      if [[ ${NV_PKGBASE[$kernel]} == linux-gooarchy ]]; then
        kernel_package_version=$(nvidia_pacman_version "${NV_PKGBASE[$kernel]}" 2>/dev/null || true)
        uncovered_reason="matching ${NV_PKGBASE[$kernel]}-headers ${kernel_package_version:+$kernel_package_version }is missing; rerun ./install.sh --kernel to rebuild it with headers"
      else
        uncovered_reason="no installed or official-repository ${NV_PKGBASE[$kernel]}-headers package matches the installed kernel version"
      fi
      nvidia_ensure_uncovered_images "$kernel" "$uncovered_reason" || nvidia_fail "could not ensure consistent, listable images for uncovered ${NV_PKGBASE[$kernel]} kernel $kernel while preserving the user's effective NVIDIA module set. No package or user configuration was changed by this recovery attempt."
      nvidia_fail_if_package_hook_failed "$kernel"
      continue
    fi
    nvidia_kernel_module_state "$kernel" "$expected" || true
    if ((!NV_KERNEL_HAS_ALL)) || [[ -n $NV_KERNEL_ERROR ]]; then
      build_status=0
      if nvidia_test_failure "dkms:$kernel"; then
        build_status=99
      elif sudo dkms autoinstall -k "$kernel"; then
        build_status=0
      else
        build_status=$?
      fi
      nvidia_kernel_module_state "$kernel" "$expected" || true
      if ((!NV_KERNEL_HAS_ALL)) || [[ -n $NV_KERNEL_ERROR ]]; then
        if [[ -n $NV_KERNEL_ERROR ]]; then
          uncovered_reason="${NV_KERNEL_ERROR}; DKMS returned status $build_status"
        else
          uncovered_reason="DKMS did not build all four modules (status $build_status)"
        fi
        nvidia_ensure_uncovered_images "$kernel" "$uncovered_reason" || nvidia_fail "could not ensure consistent, listable images for uncovered ${NV_PKGBASE[$kernel]} kernel $kernel while preserving the user's effective NVIDIA module set. Inspect the DKMS build log and mkinitcpio output, then repair before relying on this kernel."
        nvidia_fail_if_package_hook_failed "$kernel"
        continue
      fi
    fi

    # Kernels with a preset using the default config get the owned drop-in. Custom configs are
    # untouched and reported by nvidia_set_early_kms_config.
    nvidia_collect_kernel_presets "$kernel"
    if ((${#NV_KERNEL_PRESETS[@]})); then
      if ! command -v mkinitcpio >/dev/null 2>&1; then
        for preset in "${NV_KERNEL_PRESETS[@]}"; do
          nvidia_preset_images "$preset"
          ((NV_IMAGES_UNRESOLVED == 0)) && ((${#NV_IMAGES[@]} > 0)) || {
            nvidia_report_other_user_partial_kernels "$kernel"
            nvidia_fail "could not resolve every image in ${preset##*/}; no NVIDIA image was changed."
          }
          for image in "${NV_IMAGES[@]}"; do
            nvidia_image_listable "$image" || {
              nvidia_report_other_user_partial_kernels "$kernel"
              nvidia_fail "image $image for ${NV_PKGBASE[$kernel]} kernel $kernel is absent or cannot be listed."
            }
            nvidia_image_module_state "$image" "$expected" || {
              nvidia_report_other_user_partial_kernels "$kernel"
              nvidia_fail "image $image for ${NV_PKGBASE[$kernel]} kernel $kernel has an NVIDIA module or firmware version out of step."
            }
          done
        done
        nvidia_fail_if_package_hook_failed "$kernel"
        continue
      fi
      local regenerate=0 preset_early_kms r11_preset entry_key selected_entry_text
      local -a regenerate_presets=() selected_entries=()
      local -A regenerate_seen=() regenerate_entry_seen=() regenerate_entry_list=()
      for preset in "${NV_KERNEL_PRESETS[@]}"; do
        nvidia_preset_images "$preset"
        if ((${#NV_IMAGES[@]} == 0)) || ((NV_IMAGES_UNRESOLVED)); then
          nvidia_fail "could not resolve every image path in ${preset##*/}; the NVIDIA image state cannot be verified."
        fi
        for idx in "${!NV_IMAGES[@]}"; do
          image=${NV_IMAGES[$idx]}
          entry=${NV_IMAGE_ENTRIES[$idx]}
          config=${NV_IMAGE_CONFIGS[$idx]}
          if nvidia_preset_has_all_modules "$preset" "$entry" "$kernel" "$expected"; then
            preset_early_kms=1
          else
            preset_early_kms=0
          fi
          if ((preset_early_kms == 0)) && [[ -n $config ]]; then
            # R11 leaves an image that bypasses drop-ins to the user. It still must remain
            # consistent and listable; only the R15a stale-baseline path may repair it.
            r11_preset=1
          else
            r11_preset=0
          fi
          if ! nvidia_image_listable "$image"; then
            if ((r11_preset)); then
              nvidia_fail_if_package_hook_failed "$kernel"
              nvidia_fail "image $image for active ${entry} entry in ${preset##*/} is absent or cannot be listed; its direct configuration $config bypasses Gooarchy's drop-in and the step did not regenerate it. Repair the user's preset image, then rerun."
            fi
            regenerate=1
            if [[ ! ${regenerate_seen[$preset]:-} ]]; then
              regenerate_seen[$preset]=1
              regenerate_presets+=("$preset")
            fi
            entry_key="$preset|$entry"
            if [[ ! ${regenerate_entry_seen[$entry_key]:-} ]]; then
              regenerate_entry_seen[$entry_key]=1
              regenerate_entry_list[$preset]+="${regenerate_entry_list[$preset]:+ }$entry"
            fi
            continue
          fi
          if ! nvidia_image_module_state "$image" "$expected"; then
            if ((r11_preset)); then
              nvidia_fail_if_package_hook_failed "$kernel"
              nvidia_fail "image $image for active ${entry} entry in ${preset##*/} has an NVIDIA module version or firmware mismatch; its direct configuration $config bypasses Gooarchy's drop-in and the step did not regenerate it. Repair the user's preset image, then rerun."
            fi
            regenerate=1
            if [[ ! ${regenerate_seen[$preset]:-} ]]; then
              regenerate_seen[$preset]=1
              regenerate_presets+=("$preset")
            fi
            entry_key="$preset|$entry"
            if [[ ! ${regenerate_entry_seen[$entry_key]:-} ]]; then
              regenerate_entry_seen[$entry_key]=1
              regenerate_entry_list[$preset]+="${regenerate_entry_list[$preset]:+ }$entry"
            fi
          elif ((preset_early_kms)) && ((NV_IMAGE_HAS_ALL == 0)); then
            regenerate=1
            if [[ ! ${regenerate_seen[$preset]:-} ]]; then
              regenerate_seen[$preset]=1
              regenerate_presets+=("$preset")
            fi
            entry_key="$preset|$entry"
            if [[ ! ${regenerate_entry_seen[$entry_key]:-} ]]; then
              regenerate_entry_seen[$entry_key]=1
              regenerate_entry_list[$preset]+="${regenerate_entry_list[$preset]:+ }$entry"
            fi
          fi
        done
      done
      if ((regenerate)); then
        for preset in "${regenerate_presets[@]}"; do
          selected_entry_text=${regenerate_entry_list[$preset]:-}
          selected_entries=()
          read -r -a selected_entries <<<"$selected_entry_text"
          if ((${#selected_entries[@]} == 0)); then
            nvidia_fail "no active preset entries were selected for early-KMS regeneration in ${preset##*/}."
          fi
          if ! nvidia_regenerate_kernel_images "$kernel" "" "$preset" "$expected" "${selected_entries[@]}"; then
            nvidia_report_other_user_partial_kernels "$kernel"
            nvidia_fail "mkinitcpio failed while generating early-KMS images for ${NV_PKGBASE[$kernel]} kernel $kernel using ${preset##*/}; the NVIDIA package is installed. Read the step log, restore a complete image, then rerun."
          fi
        done
        for preset in "${NV_KERNEL_PRESETS[@]}"; do
          nvidia_preset_images "$preset"
          ((NV_IMAGES_UNRESOLVED == 0)) && ((${#NV_IMAGES[@]} > 0)) || {
            nvidia_report_other_user_partial_kernels "$kernel"
            nvidia_fail "could not resolve every image path in ${preset##*/} after regeneration."
          }
          for idx in "${!NV_IMAGES[@]}"; do
            image=${NV_IMAGES[$idx]}
            entry=${NV_IMAGE_ENTRIES[$idx]}
            if nvidia_preset_has_all_modules "$preset" "$entry" "$kernel" "$expected"; then preset_early_kms=1; else preset_early_kms=0; fi
            nvidia_image_listable "$image" || {
              nvidia_report_other_user_partial_kernels "$kernel"
              nvidia_fail "mkinitcpio left ${image} absent or unreadable for ${NV_PKGBASE[$kernel]} kernel $kernel."
            }
            nvidia_image_module_state "$image" "$expected" || {
              nvidia_report_other_user_partial_kernels "$kernel"
              nvidia_fail "mkinitcpio left ${image} with an NVIDIA module or firmware version out of step for ${NV_PKGBASE[$kernel]} kernel $kernel."
            }
            if ((preset_early_kms)) && ((NV_IMAGE_HAS_ALL == 0)); then
              nvidia_report_other_user_partial_kernels "$kernel"
              nvidia_fail "mkinitcpio did not place all four NVIDIA modules in ${image} for covered ${NV_PKGBASE[$kernel]} kernel $kernel."
            fi
          done
        done
      else
        echo "NVIDIA: already set up for ${NV_PKGBASE[$kernel]} kernel $kernel."
      fi
    else
      nvidia_report "${NV_PKGBASE[$kernel]} kernel $kernel has no mkinitcpio preset; the driver is covered and loads later from the root file system, but Gooarchy did not set up early KMS."
    fi
    nvidia_fail_if_package_hook_failed "$kernel"
  done
  if [[ -n ${NV_PACKAGE_HOOK_FAILURES[unknown]:-} ]]; then
    nvidia_fail "pacman's post-transaction mkinitcpio hook reported an error that could not be matched to an installed kernel preset: ${NV_PACKAGE_HOOK_FAILURES[unknown]}. Inspect the hook output and rerun."
  fi
}

nvidia_install
