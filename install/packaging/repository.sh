# Prepare the signed Gooarchy repository before any package is installed or upgraded.
source "$GOOARCHY_INSTALL/helpers/logging.sh"
source "$GOOARCHY_INSTALL/helpers/repository.sh"

fail_repository() {
  echo "Gooarchy can't install here: $*" >&2
  exit 1
}

scottland_override=0
[[ -n ${GOOARCHY_SCOTTLAND_REF:-} ]] && scottland_override=1
source "$GOOARCHY_INSTALL/sources.conf"

repository_url=${GOOARCHY_REPOSITORY_URL%/}
[[ $repository_url =~ ^(https?://|file://)[^[:space:]#]+$ ]] ||
  fail_repository "the Gooarchy repository address must be a URL using https://, http:// or file://, without spaces or fragments."

fingerprint_file=$GOOARCHY_PATH/packaging/keys/gooarchy.fingerprint
key_file=$GOOARCHY_PATH/packaging/keys/gooarchy.asc
fingerprint=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$fingerprint_file" | sed -n '/./{p;q;}')
[[ $fingerprint =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]] ||
  fail_repository "the Gooarchy signing key is not configured yet; packaging/keys/gooarchy.fingerprint is still a placeholder."
[[ -s $key_file ]] || fail_repository "the committed Gooarchy public key is missing at $key_file."
if grep -q '^Placeholder:' "$key_file"; then
  fail_repository "the Gooarchy public signing key is still a placeholder; signing-key custody is not configured."
fi

actual_fingerprint=$(gpg --batch --show-keys --with-colons --with-fingerprint "$key_file" 2>/dev/null |
  awk -F: '$1 == "fpr" {print toupper($10); exit}') ||
  fail_repository "the committed Gooarchy public key at $key_file could not be read."
[[ -n $actual_fingerprint ]] || fail_repository "the committed Gooarchy public key at $key_file contains no public key."
[[ ${actual_fingerprint^^} == ${fingerprint^^} ]] ||
  fail_repository "the Gooarchy public key fingerprint is $actual_fingerprint, but the checkout commits $fingerprint; pacman.conf was not changed."

pacman_conf=/etc/pacman.conf
section_count=$(grep -Ec '^\[gooarchy\][[:space:]]*(#.*)?$' "$pacman_conf" || true)
if ((section_count > 1)); then
  fail_repository "multiple [gooarchy] sections exist in /etc/pacman.conf; keep only the Gooarchy installer section before running install.sh."
fi
managed_section_count=$(awk '
  $0 == "# Gooarchy installer repository" { marker = 1; next }
  /^\[gooarchy\][[:space:]]*(#.*)?$/ {
    if (marker) count++
    marker = 0
    next
  }
  /^\[[^]]+\][[:space:]]*(#.*)?$/ { marker = 0; next }
  /^[[:space:]]*$/ { next }
  { marker = 0 }
  END { print count + 0 }
' "$pacman_conf")
if ((section_count > 0 && managed_section_count != section_count)); then
  fail_repository "[gooarchy] already exists in /etc/pacman.conf; remove or rename that user-managed section before running install.sh."
fi

# A key substitution must be rejected before either trusting it or touching pacman.conf.
sudo pacman-key --add "$key_file"
sudo pacman-key --lsign-key "$fingerprint"
report "Trusted Gooarchy repository key $fingerprint. To undo: sudo pacman-key --delete $fingerprint."

config_tmp=$(mktemp)
root_config_tmp=/etc/.pacman.conf.gooarchy.$$
trap 'rm -f -- "$config_tmp"; sudo rm -f -- "$root_config_tmp"' EXIT
awk -v url="$repository_url" '
  $0 == "# Gooarchy installer repository" { marker_pending = 1; next }
  /^\[gooarchy\][[:space:]]*(#.*)?$/ { marker_pending = 0; in_repo = 1; next }
  /^\[[^]]+\][[:space:]]*(#.*)?$/ {
    in_repo = 0
    if (marker_pending) { print "# Gooarchy installer repository"; marker_pending = 0 }
  }
  in_repo { next }
  {
    if (marker_pending) { print "# Gooarchy installer repository"; marker_pending = 0 }
    print
  }
  END {
    if (marker_pending) print "# Gooarchy installer repository"
    print ""
    print "# Gooarchy installer repository"
    print "[gooarchy]"
    print "SigLevel = PackageRequired DatabaseOptional"
    print "Server = " url
  }
' "$pacman_conf" >"$config_tmp"

old_server=$(awk '
  /^\[gooarchy\][[:space:]]*(#.*)?$/ { in_repo = 1; next }
  /^\[[^]]+\][[:space:]]*(#.*)?$/ { in_repo = 0 }
  in_repo && /^[[:space:]]*Server[[:space:]]*=/ {
    sub(/^[[:space:]]*Server[[:space:]]*=[[:space:]]*/, "")
    print
    exit
  }
' "$pacman_conf")
if ! cmp -s "$config_tmp" "$pacman_conf"; then
  sudo install -o root -g root -m 0644 "$config_tmp" "$root_config_tmp"
  sudo mv -f -- "$root_config_tmp" "$pacman_conf"
  report "Added [gooarchy] at $repository_url with package signatures required. To undo: remove the [gooarchy] section from /etc/pacman.conf."
  if [[ -n $old_server && $old_server != "$repository_url" ]]; then
    report "Updated the installer-managed [gooarchy] Server from $old_server to $repository_url."
  fi
else
  report "[gooarchy] already points at $repository_url with package signatures required."
fi
rm -f -- "$config_tmp"
config_tmp=
trap - EXIT

refresh_conf=$(mktemp)
cat >"$refresh_conf" <<EOF
[options]
Architecture = auto
SigLevel = Required TrustedOnly

[gooarchy]
SigLevel = PackageRequired DatabaseOptional
Server = $repository_url
EOF
trap 'rm -f -- "$refresh_conf"' EXIT
if ! sudo pacman --config "$refresh_conf" -Syy --noconfirm; then
  fail_repository "the Gooarchy repository at $repository_url could not be reached during pacman database refresh; no package was installed or built."
fi
if ! sudo pacman -Syy --noconfirm; then
  if ! sudo pacman --config "$refresh_conf" -Syy --noconfirm; then
    fail_repository "the Gooarchy repository at $repository_url could not be reached during pacman database refresh; no package was installed or built."
  fi
  rm -f -- "$refresh_conf"
  trap - EXIT
  fail_repository "Arch package databases could not be refreshed; no package was installed or built."
fi
rm -f -- "$refresh_conf"
trap - EXIT

for package in gooarchy gooarchy-flavorings scottland; do
  sync_package_field "$package" Version >/dev/null ||
    fail_repository "the Gooarchy repository at $repository_url did not provide $package after refresh; no package was installed or built."
done

repo_scottland_version=$(sync_package_field scottland Version)
repo_scottland_depends=$(pacman -Si gooarchy/scottland 2>/dev/null | awk '
  /^Depends On[[:space:]]*:/ {
    in_depends = 1
    sub(/^[^:]*:[[:space:]]*/, "")
    depends = $0
    next
  }
  /^[^[:space:]].*:/ { in_depends = 0 }
  in_depends { depends = depends " " $0 }
  END { print depends }
')
repo_wayfire_version=$(sed -nE 's/.*(^|[[:space:]])wayfire=([^[:space:]]+).*/\2/p' <<<"$repo_scottland_depends")
[[ -n $repo_wayfire_version ]] ||
  fail_repository "the repository's scottland package does not declare its exact wayfire dependency."
arch_wayfire_package_version=$(sync_package_field wayfire Version extra)
[[ -n $arch_wayfire_package_version ]] || fail_repository "Arch's wayfire package is unavailable after repository refresh."
arch_wayfire_version=${arch_wayfire_package_version#*:}
arch_wayfire_version=${arch_wayfire_version%-*}

if ((scottland_override == 0)) && [[ $repo_wayfire_version != "$arch_wayfire_version" ]]; then
  fail_repository "repository scottland requires wayfire=$repo_wayfire_version, while Arch serves wayfire=$arch_wayfire_version. Publish a new Scottland first; to build one deliberately, set GOOARCHY_SCOTTLAND_REF and rerun install.sh. No package was installed or upgraded."
fi

mkdir -p "$GOOARCHY_BUILD"
repo_cache=$(mktemp -d "$GOOARCHY_BUILD/repository-package.XXXXXX")
chmod 755 "$repo_cache"
trap 'sudo rm -rf -- "$repo_cache"' EXIT
repo_filename=$(pacman -Sp --nodeps --print-format '%f' gooarchy/gooarchy | sed -n '1p')
[[ -n $repo_filename && $repo_filename != */* ]] ||
  fail_repository "pacman could not resolve the repository's gooarchy package at $repository_url."
if ! sudo pacman -Sw --nodeps --noconfirm --cachedir "$repo_cache" gooarchy/gooarchy; then
  fail_repository "the gooarchy package could not be downloaded from $repository_url; no package was installed or built."
fi
repo_archive=$repo_cache/$repo_filename
[[ -s $repo_archive ]] || fail_repository "pacman did not cache the repository's gooarchy package from $repository_url."
repo_source_commit=$(sudo bsdtar -xOf "$repo_archive" usr/share/gooarchy/build-info |
  sed -nE 's/^checkout ([[:xdigit:]]{40})$/\1/p' | sed -n '1p')
[[ $repo_source_commit =~ ^[[:xdigit:]]{40}$ ]] ||
  fail_repository "the repository's gooarchy package at $repository_url has no valid source commit in build-info."
sudo rm -rf -- "$repo_cache"
trap - EXIT

checkout_commit=$(git -C "$GOOARCHY_PATH" rev-parse HEAD 2>/dev/null || true)
[[ $checkout_commit =~ ^[[:xdigit:]]{40}$ ]] || fail_repository "the installer checkout has no readable Git commit."
checkout_dirty=0
[[ -n $(git -C "$GOOARCHY_PATH" status --porcelain 2>/dev/null) ]] && checkout_dirty=1
local_gooarchy=0
if ((checkout_dirty)) || [[ $checkout_commit != "$repo_source_commit" ]]; then
  local_gooarchy=1
fi

local_scottland=$scottland_override
replace_scottland=0
previous_scottland_version=
previous_scottland_ref=
if package_is_installed scottland; then
  previous_scottland_version=$(installed_package_version scottland)
  if [[ -r $GOOARCHY_STATE/builds.tsv ]]; then
    previous_scottland_ref=$(awk -F '\t' '$1 == "scottland" { ref = $3 } END { print ref }' "$GOOARCHY_STATE/builds.tsv")
  fi
  if ((local_scottland == 0)) && ! package_is_repository_copy scottland; then
    replace_scottland=1
  fi
fi

scottland_target=
if ((local_scottland == 0)); then scottland_target=gooarchy/scottland; fi

# Save the pre-upgrade Gooarchy package state. pacman -Syu runs before the final source selection
# and can itself replace a local package with a newer repository copy.
previous_gooarchy_installed=0
previous_gooarchy_repository_copy=0
previous_gooarchy_version=
previous_flavorings_installed=0
previous_flavorings_repository_copy=0
previous_flavorings_version=
previous_gooarchy_source_commit=
if package_is_installed gooarchy; then
  previous_gooarchy_installed=1
  previous_gooarchy_version=$(installed_package_version gooarchy)
  package_is_repository_copy gooarchy && previous_gooarchy_repository_copy=1
  if [[ -r /usr/share/gooarchy/build-info ]]; then
    previous_gooarchy_source_commit=$(sed -nE \
      's/^checkout ([[:xdigit:]]{40})( with uncommitted changes)?$/\1/p' \
      /usr/share/gooarchy/build-info | sed -n '1p')
  fi
fi
if package_is_installed gooarchy-flavorings; then
  previous_flavorings_installed=1
  previous_flavorings_version=$(installed_package_version gooarchy-flavorings)
  package_is_repository_copy gooarchy-flavorings && previous_flavorings_repository_copy=1
fi

plan_tmp=$GOOARCHY_STATE/repository-plan.sh.$$
{
  printf 'GOOARCHY_REPOSITORY_URL=%q\n' "$repository_url"
  printf 'GOOARCHY_REPOSITORY_PACKAGER=%q\n' "$GOOARCHY_REPOSITORY_PACKAGER"
  printf 'GOOARCHY_REPOSITORY_FINGERPRINT=%q\n' "$fingerprint"
  printf 'GOOARCHY_REPOSITORY_SOURCE_COMMIT=%q\n' "$repo_source_commit"
  printf 'GOOARCHY_REPOSITORY_SCOTTLAND_VERSION=%q\n' "$repo_scottland_version"
  printf 'GOOARCHY_REPOSITORY_WAYFIRE_VERSION=%q\n' "$repo_wayfire_version"
  printf 'GOOARCHY_ARCH_WAYFIRE_VERSION=%q\n' "$arch_wayfire_version"
  printf 'GOOARCHY_BUILD_LOCAL_GOOARCHY=%q\n' "$local_gooarchy"
  printf 'GOOARCHY_BUILD_LOCAL_SCOTTLAND=%q\n' "$local_scottland"
  printf 'GOOARCHY_REPLACE_SCOTTLAND=%q\n' "$replace_scottland"
  printf 'GOOARCHY_PREVIOUS_SCOTTLAND_VERSION=%q\n' "$previous_scottland_version"
  printf 'GOOARCHY_PREVIOUS_SCOTTLAND_REF=%q\n' "$previous_scottland_ref"
  printf 'GOOARCHY_SCOTTLAND_TARGET=%q\n' "$scottland_target"
  printf 'GOOARCHY_PREVIOUS_GOOARCHY_INSTALLED=%q\n' "$previous_gooarchy_installed"
  printf 'GOOARCHY_PREVIOUS_GOOARCHY_REPOSITORY_COPY=%q\n' "$previous_gooarchy_repository_copy"
  printf 'GOOARCHY_PREVIOUS_GOOARCHY_VERSION=%q\n' "$previous_gooarchy_version"
  printf 'GOOARCHY_PREVIOUS_FLAVORINGS_INSTALLED=%q\n' "$previous_flavorings_installed"
  printf 'GOOARCHY_PREVIOUS_FLAVORINGS_REPOSITORY_COPY=%q\n' "$previous_flavorings_repository_copy"
  printf 'GOOARCHY_PREVIOUS_FLAVORINGS_VERSION=%q\n' "$previous_flavorings_version"
  printf 'GOOARCHY_PREVIOUS_GOOARCHY_SOURCE_COMMIT=%q\n' "$previous_gooarchy_source_commit"
} >"$plan_tmp"
mv -f -- "$plan_tmp" "$GOOARCHY_STATE/repository-plan.sh"

if ((local_gooarchy)); then
  if ((checkout_dirty)); then
    report "The checkout has uncommitted changes, so gooarchy and gooarchy-flavorings will be built locally instead of using the repository copies."
  else
    report "Checkout commit $checkout_commit differs from the repository gooarchy source commit $repo_source_commit, so gooarchy and gooarchy-flavorings will be built locally."
  fi
fi
if ((local_scottland)); then
  report "GOOARCHY_SCOTTLAND_REF is overridden; Scottland will be built locally and the repository copy will be skipped."
fi
