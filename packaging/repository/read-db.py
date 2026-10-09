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
            if Path(member.name).name != "desc":
                continue
            if not member.isfile():
                raise ValueError(f"{member.name} is not a package record file")
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError(f"could not read {member.name} from {database}")
            lines = stream.read().decode("utf-8", errors="strict").splitlines()
            fields: dict[str, str] = {}
            for field in ("NAME", "VERSION", "FILENAME"):
                marker = f"%{field}%"
                matches = [index for index, line in enumerate(lines) if line == marker]
                if len(matches) != 1:
                    raise ValueError(
                        f"{member.name} must contain exactly one {marker} field"
                    )
                index = matches[0]
                if (
                    index + 1 >= len(lines)
                    or not lines[index + 1]
                    or lines[index + 1].startswith("%")
                ):
                    raise ValueError(f"{member.name} has no value for {marker}")
                fields[field] = lines[index + 1]
            name, version, filename = (
                fields["NAME"],
                fields["VERSION"],
                fields["FILENAME"],
            )
            found.append((name, version, filename))

    names = [name for name, _, _ in found]
    if not names:
        raise ValueError(f"{database} contains no package records")
    if len(names) != len(set(names)):
        raise ValueError(f"{database} contains more than one record for a package")
    return sorted(found)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("database", type=Path)
    args = parser.parse_args()
    try:
        for name, version, filename in records(args.database):
            if any(
                ord(character) < 32 or ord(character) == 127
                for character in name + version + filename
            ):
                raise ValueError("repository database contains an invalid field")
            print(f"{name}\t{version}\t{filename}")
    except (OSError, tarfile.TarError, UnicodeError, ValueError) as error:
        print(f"read-db.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
