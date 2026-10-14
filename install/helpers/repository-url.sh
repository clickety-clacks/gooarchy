# Resolve the full repository database URL into the Pacman Server directory.
# Pacman appends the repository database filename and package archives to Server.
gooarchy_pacman_server() {
  local database_url=$1
  [[ $database_url =~ ^(https?://|file://)[^[:space:]#]+/gooarchy\.db$ ]] || return 1
  printf '%s\n' "${database_url%/gooarchy.db}"
}
