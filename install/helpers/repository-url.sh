# Accept either the full database URL or an existing Pacman Server directory override.
# Pacman appends the repository database filename and package archives to Server.
gooarchy_pacman_server() {
  local repository_url=$1
  [[ $repository_url =~ ^(https?://|file://)[^[:space:]#]+$ ]] || return 1
  if [[ $repository_url == */gooarchy.db ]]; then
    printf '%s\n' "${repository_url%/gooarchy.db}"
  else
    printf '%s\n' "${repository_url%/}"
  fi
}

gooarchy_repository_database_url() {
  local repository_url=$1
  local server
  [[ $repository_url =~ ^(https?://|file://)[^[:space:]#]+$ ]] || return 1
  if [[ $repository_url == */gooarchy.db ]]; then
    printf '%s\n' "$repository_url"
    return 0
  fi
  server=$(gooarchy_pacman_server "$repository_url") || return 1
  printf '%s/gooarchy.db\n' "${server%/}"
}
