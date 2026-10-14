#!/usr/bin/env bash
set -euo pipefail
cat >&2 <<'MESSAGE'
The single-machine publisher is retired. Do not run this command on the package builder.
Build unsigned package archives and a database with packaging/repository/produce.sh. Sign the
immutable bundle with packaging/repository/sign.sh, then use the separately qualified
packaging/repository/upload.sh uploader. Signing does not authorize upload.
MESSAGE
exit 2
