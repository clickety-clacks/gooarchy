#!/usr/bin/env python3
"""Read the package records that pacman stores in a repository database."""

from __future__ import annotations

import argparse
import sys
import tarfile
from pathlib import Path


def records(database: Path) -> list[tuple[str, str, str]]:
    found: list[tuple[str, str, str]] = []
    with tarfile.open(database, mode="r:*") as archive:
        for member in archive.getmembers():
            if not member.isfile() or Path(member.name).name != "desc":
                continue
            stream = archive.extractfile(member)
            if stream is None:
                continue
            lines = stream.read().decode("utf-8", errors="strict").splitlines()
            fields: dict[str, str] = {}
            for field in ("NAME", "VERSION", "FILENAME"):
                marker = f"%{field}%"
                try:
                    index = lines.index(marker)
                except ValueError:
                    continue
                if index + 1 < len(lines) and not lines[index + 1].startswith("%"):
                    fields[field] = lines[index + 1]
            name, version, filename = (
                fields.get("NAME", ""),
                fields.get("VERSION", ""),
                fields.get("FILENAME", ""),
            )
            if name and version and filename:
                found.append((name, version, filename))

    names = [name for name, _, _ in found]
    if len(names) != len(set(names)):
        raise ValueError(f"{database} contains more than one record for a package")
    return sorted(found)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("database", type=Path)
    args = parser.parse_args()
    try:
        for name, version, filename in records(args.database):
            if "\t" in name + version + filename or "\n" in name + version + filename:
                raise ValueError("repository database contains an invalid field")
            print(f"{name}\t{version}\t{filename}")
    except (OSError, tarfile.TarError, UnicodeError, ValueError) as error:
        print(f"read-db.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
