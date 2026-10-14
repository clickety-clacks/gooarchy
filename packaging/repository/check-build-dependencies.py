#!/usr/bin/env python3
"""Check only the build-time dependencies emitted by makepkg --printsrcinfo."""

from __future__ import annotations

import subprocess
import sys


BUILD_DEPENDENCY_FIELDS = {"makedepends", "checkdepends"}


def main() -> int:
    dependencies = set()
    for line in sys.stdin:
        key, separator, value = line.partition("=")
        if not separator or key.strip() not in BUILD_DEPENDENCY_FIELDS:
            continue
        dependency = value.strip()
        if dependency:
            dependencies.add(dependency)

    if not dependencies:
        return 0

    command = ["pacman", "-T", *sorted(dependencies)]
    try:
        result = subprocess.run(command, check=False, text=True, capture_output=True)
    except OSError as error:
        print(f"build dependency check could not run pacman -T: {error}", file=sys.stderr)
        return 1

    if result.returncode == 0:
        return 0

    missing = result.stdout.strip()
    if result.returncode == 127 and missing:
        print(
            "missing build-time dependencies (makedepends/checkdepends only): "
            + ", ".join(missing.splitlines()),
            file=sys.stderr,
        )
        return 1

    detail = result.stderr.strip() or missing or f"exit {result.returncode}"
    print(f"pacman -T could not verify build-time dependencies: {detail}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
