#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/pacman" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case ${1:-} in
  -Qi)
    printf 'Name            : scottland\n'
    printf 'Version         : %s\n' "${FAKE_INSTALLED_VERSION:-0.3.4-1}"
    printf 'Packager        : %s\n' "${FAKE_PACKAGER:-Unknown Packager}"
    printf 'Validated By    : %s\n' "${FAKE_VALIDATED_BY:-Signature}"
    ;;
  -Q)
    printf 'scottland %s\n' "${FAKE_INSTALLED_VERSION:-0.3.4-1}"
    ;;
  -Si)
    case ${2:-} in
      gooarchy/scottland)
        printf 'Name            : scottland\n'
        printf 'Version         : %s\n' "${FAKE_REPOSITORY_VERSION:-0.3.4-1}"
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/bin/pacman"
PATH="$tmp/bin:$PATH"
export PATH
GOOARCHY_STATE="$tmp/state"
export GOOARCHY_STATE
source "$repo_root/install/helpers/repository.sh"

expect_wayfire_status() {
  local expected=$1 status=0
  shift
  if repository_scottland_wayfire_allowed "$@"; then
    status=0
  else
    status=$?
  fi
  if ((status != expected)); then
    echo "Wayfire policy returned $status, expected $expected" >&2
    exit 1
  fi
}

if ! package_is_repository_copy scottland; then
  echo "signed package matching the Gooarchy repository version was not recognized" >&2
  exit 1
fi
FAKE_PACKAGER='An unrelated packager'
export FAKE_PACKAGER
if ! package_is_repository_copy scottland; then
  echo "repository-copy recognition depended on the Packager field" >&2
  exit 1
fi
unset FAKE_PACKAGER
FAKE_VALIDATED_BY=None
export FAKE_VALIDATED_BY
if package_is_repository_copy scottland; then
  echo "an unvalidated package was recognized as a repository copy" >&2
  exit 1
fi
FAKE_VALIDATED_BY=Signature
FAKE_REPOSITORY_VERSION=0.3.4-2
export FAKE_VALIDATED_BY FAKE_REPOSITORY_VERSION
if package_is_repository_copy scottland; then
  echo "a different repository version was recognized as the installed copy" >&2
  exit 1
fi

arch_wayfire_package_version=
arch_wayfire_version=
if arch_wayfire_package_version=$(sync_package_field wayfire Version extra); then
  if [[ -n $arch_wayfire_package_version ]]; then
    arch_wayfire_version=${arch_wayfire_package_version#*:}
    arch_wayfire_version=${arch_wayfire_version%-*}
  fi
fi
optional_wayfire_warning=0
if [[ -z $arch_wayfire_version ]]; then optional_wayfire_warning=1; fi
[[ $optional_wayfire_warning == 1 ]]
repository_scottland_wayfire_allowed 0.3.4-1 wayfire "$arch_wayfire_version" 0
repository_scottland_wayfire_allowed 0.3.4-1 wayfire 0.13.0 0
repository_scottland_wayfire_allowed 0.3.4-1 "" "" 0
repository_scottland_wayfire_allowed 0.3.4-1 wayfire=0.11.0 0.10.0 0
repository_scottland_wayfire_allowed 0.3.3-1 wayfire=0.11.0 0.11.0 0
expect_wayfire_status 2 0.3.4-1 wayfire "" 1
expect_wayfire_status 1 0.3.3-1 wayfire=0.11.0 0.10.0 0
expect_wayfire_status 0 0.3.3-1 wayfire=0.11.0 "" 0
expect_wayfire_status 0 0.3.3-1 wayfire=0.10.0 0.10.0 0
expect_wayfire_status 0 0.3.3-1 wayfire=0.11.0 0.10.0 1
expect_wayfire_status 2 0.3.3-1 wayfire 0.13.0 0
expect_wayfire_status 2 0.3.3-1 "" 0.13.0 0
expect_wayfire_status 2 0.3.3-1 wayland 0.13.0 0

echo "repository signature/version recognition and Wayfire dependency policy passed"
