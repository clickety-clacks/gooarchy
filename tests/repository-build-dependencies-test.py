#!/usr/bin/env python3
"""Exercise the package producer's build-dependency boundary with local command fixtures."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BUILD_RECIPE = REPO_ROOT / "packaging/repository/build-recipe.sh"


class BuildDependencyBoundaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.makepkg_log = self.root / "makepkg-build-args"
        self.pacman_log = self.root / "pacman-args"
        self.srcinfo = self.root / ".SRCINFO"
        self.srcinfo.write_text(
            "\n".join(
                [
                    "pkgbase = sample",
                    "\tdepends = gooarchy-flavorings",
                    "\tdepends = scottland=0.3.1-1",
                    "\tdepends = strata-bin",
                    "\tmakedepends = cargo",
                    "\tmakedepends = git",
                    "\tcheckdepends = bats",
                    "pkgname = sample",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        self._write_executable(
            self.bin / "makepkg",
            """#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --printsrcinfo ]]; then
  cat "$SRCINFO"
  exit 0
fi
printf '%s\\0' "$@" > "$MAKEPKG_LOG"
""",
        )
        self._write_executable(
            self.bin / "pacman",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\0' "$@" > "$PACMAN_LOG"
if [[ ${PACMAN_STATUS:-0} != 0 ]]; then
  printf '%s\\n' "${PACMAN_MISSING:-cargo}"
  exit "$PACMAN_STATUS"
fi
""",
        )
        self.env = os.environ.copy()
        self.env.update(
            {
                "PATH": f"{self.bin}:{self.env.get('PATH', '')}",
                "SRCINFO": str(self.srcinfo),
                "MAKEPKG_LOG": str(self.makepkg_log),
                "PACMAN_LOG": str(self.pacman_log),
            }
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    @staticmethod
    def _write_executable(path: Path, content: str) -> None:
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    @staticmethod
    def _nul_args(path: Path) -> list[str]:
        return path.read_bytes().decode().rstrip("\0").split("\0")

    def test_build_checks_build_tools_and_keeps_runtime_dependencies_out_of_pacman(self) -> None:
        result = subprocess.run(
            [str(BUILD_RECIPE), "--noconfirm", "--needed", "--cleanbuild"],
            cwd=self.root,
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._nul_args(self.pacman_log), ["-T", "bats", "cargo", "git"])
        self.assertEqual(
            self._nul_args(self.makepkg_log),
            ["--nodeps", "--noconfirm", "--needed", "--cleanbuild"],
        )

    def test_missing_build_tool_stops_before_package_build(self) -> None:
        self.env["PACMAN_STATUS"] = "127"
        self.env["PACMAN_MISSING"] = "cargo"
        result = subprocess.run(
            [str(BUILD_RECIPE), "--noconfirm"],
            cwd=self.root,
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing build-time dependencies", result.stderr)
        self.assertIn("cargo", result.stderr)
        self.assertFalse(self.makepkg_log.exists())

    def test_syncdeps_is_rejected_before_any_dependency_or_build_command(self) -> None:
        result = subprocess.run(
            [str(BUILD_RECIPE), "--syncdeps"],
            cwd=self.root,
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("dependency installation is disabled", result.stderr)
        self.assertFalse(self.pacman_log.exists())
        self.assertFalse(self.makepkg_log.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
