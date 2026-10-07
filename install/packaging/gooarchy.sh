# Gooarchy and its flavorings come from the repository when this clean checkout matches the
# repository package's recorded source commit. A different or dirty checkout builds both from the
# recipes of record in this checkout, including the separate flavorings recipe when it exists.
source "$GOOARCHY_INSTALL/helpers/packages.sh"
source "$GOOARCHY_INSTALL/helpers/repository.sh"
source "$GOOARCHY_INSTALL/helpers/logging.sh"
load_repository_plan

if ((GOOARCHY_BUILD_LOCAL_GOOARCHY)); then
  checkout_commit=$(git -C "$GOOARCHY_PATH" rev-parse HEAD)
  report "Building gooarchy and gooarchy-flavorings locally from checkout $checkout_commit because it is dirty or differs from repository source $GOOARCHY_REPOSITORY_SOURCE_COMMIT; repository copies are skipped. To return, use a clean checkout at the repository source commit and rerun install.sh."

  flavorings_recipe=$GOOARCHY_PATH/packaging/gooarchy-flavorings/PKGBUILD
  flavorings_source=$GOOARCHY_PATH
  flavorings_ref=$checkout_commit
  if [[ -f $flavorings_recipe ]]; then
    flavorings_source=$(sed -n 's/^url="\(.*\)"$/\1/p' "$flavorings_recipe")
    flavorings_ref=$(sed -n 's/^_commit=//p' "$flavorings_recipe")
    [[ -n $flavorings_source && $flavorings_ref =~ ^[[:xdigit:]]{40}$ ]] || {
      echo "The distro's gooarchy-flavorings recipe has no valid source URL and commit for the build report." >&2
      exit 1
    }
  fi

  dir=$GOOARCHY_BUILD/gooarchy-packaging
  rm -rf -- "$dir"
  mkdir -p "$dir"
  cp "$GOOARCHY_PATH/packaging/arch/PKGBUILD" "$dir/"
  GOOARCHY_PATH=$GOOARCHY_PATH build_package "$dir"

  if [[ -f $flavorings_recipe ]]; then
    mapfile -t files < <(built_files "$dir" gooarchy)
    flavorings_dir=$GOOARCHY_BUILD/gooarchy-flavorings-packaging
    rm -rf -- "$flavorings_dir"
    mkdir -p "$flavorings_dir"
    cp -a "${flavorings_recipe%/PKGBUILD}/." "$flavorings_dir/"
    build_package "$flavorings_dir"
    mapfile -t flavorings_files < <(built_files "$flavorings_dir" gooarchy-flavorings)
    files+=("${flavorings_files[@]}")
  else
    mapfile -t files < <(built_files "$dir" gooarchy gooarchy-flavorings)
  fi

  install_built "${files[@]}"
  record_build gooarchy "$GOOARCHY_PATH" "$checkout_commit" \
    "$(pacman -Q gooarchy | awk '{print $2}')"
  record_build gooarchy-flavorings "$flavorings_source" "$flavorings_ref" \
    "$(pacman -Q gooarchy-flavorings | awk '{print $2}')"
else
  targets=()
  replacement_reports=()
  previous_gooarchy_commit=$GOOARCHY_PREVIOUS_GOOARCHY_SOURCE_COMMIT
  for package in gooarchy gooarchy-flavorings; do
    previous_installed=0
    previous_repository_copy=0
    previous_version=
    case $package in
      gooarchy)
        previous_installed=$GOOARCHY_PREVIOUS_GOOARCHY_INSTALLED
        previous_repository_copy=$GOOARCHY_PREVIOUS_GOOARCHY_REPOSITORY_COPY
        previous_version=$GOOARCHY_PREVIOUS_GOOARCHY_VERSION
        ;;
      gooarchy-flavorings)
        previous_installed=$GOOARCHY_PREVIOUS_FLAVORINGS_INSTALLED
        previous_repository_copy=$GOOARCHY_PREVIOUS_FLAVORINGS_REPOSITORY_COPY
        previous_version=$GOOARCHY_PREVIOUS_FLAVORINGS_VERSION
        ;;
    esac
    if package_is_repository_copy "$package"; then
      if ((previous_installed && previous_repository_copy == 0)); then
        recovery="restore the previous local checkout and its changes, then rerun install.sh"
        replacement_reports+=("Replaced local $package $previous_version with Gooarchy repository $package $(installed_package_version "$package") because checkout $GOOARCHY_REPOSITORY_SOURCE_COMMIT matches the published source. To go back, $recovery.")
      fi
    else
      repo_version=$(sync_package_field "$package" Version)
      [[ -n $repo_version ]] || {
        echo "Gooarchy repository metadata has no version for $package." >&2
        exit 1
      }
      targets+=("gooarchy/$package=$repo_version")
      if package_is_installed "$package"; then
        old_version=$(installed_package_version "$package")
        recovery="restore the previous local checkout and its changes, then rerun install.sh"
        if [[ -n $previous_gooarchy_commit ]]; then
          recovery="restore a checkout based on $previous_gooarchy_commit with its prior local changes, then rerun install.sh"
        fi
        replacement_reports+=("Replaced local $package $old_version with Gooarchy repository $package $repo_version because checkout $GOOARCHY_REPOSITORY_SOURCE_COMMIT matches the published source. To go back, $recovery.")
      fi
    fi
  done

  if ((${#targets[@]})); then
    repo_cache=$(mktemp -d "$GOOARCHY_BUILD/repository-package.XXXXXX")
    chmod 755 "$repo_cache"
    trap 'sudo rm -rf -- "$repo_cache"' EXIT
    download_repository_packages "$repo_cache" "${targets[@]}"
    sudo pacman -U --noconfirm "${REPOSITORY_PACKAGE_ARCHIVES[@]}"
    sudo rm -rf -- "$repo_cache"
    trap - EXIT
  fi
  for package in gooarchy gooarchy-flavorings; do
    package_is_repository_copy "$package" || {
      echo "Gooarchy's $package package was not installed as a signed repository copy." >&2
      exit 1
    }
  done
  for replacement_report in "${replacement_reports[@]}"; do report "$replacement_report"; done
  forget_build gooarchy
  forget_build gooarchy-flavorings
  echo "gooarchy and gooarchy-flavorings are installed from the Gooarchy repository."
fi
