#!/usr/bin/env bash
set -euo pipefail
cat >&2 <<'MESSAGE'
The single-machine publisher is retired. Do not run this command on the package builder.
Build unsigned package archives and a database with packaging/repository/produce.sh, transfer the
immutable bundle and its manifest SHA-256, then use packaging/repository/sign-publish.sh on the
separate authorized signer.
MESSAGE
exit 2
