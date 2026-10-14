#!/usr/bin/env bash
# Validate the transfer manifest and package/database behavior without signing or publishing.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if (($#)); then
  echo "Usage: tests/repository-publish-test.sh" >&2
  exit 2
fi
python3 "$script_dir/repository-transfer-test.py"
python3 "$script_dir/repository-sign-publish-test.py"
