#!/usr/bin/env python3
"""Run test commands delivered through a shared virtio filesystem."""

import os
import pwd
import subprocess
import sys
import time
from pathlib import Path

ARCH_HOME = pwd.getpwnam("arch").pw_dir


def write_status(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(f"{value}\n", encoding="ascii")
    os.replace(temporary, path)


def process_request(request, responses):
    response = responses / request.name
    response.mkdir(mode=0o777, exist_ok=True)
    command_path = request / "command"
    try:
        command = command_path.read_text(encoding="utf-8")
        input_path = request / "stdin"
        source = open(input_path, "rb") if input_path.exists() else open(os.devnull, "rb")
        with source:
            if (request / "async").exists():
                subprocess.Popen(
                    ["/bin/bash", "-c", command],
                    cwd=ARCH_HOME,
                    stdin=source,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
                status = 0
            else:
                with open(response / "stdout", "wb") as stdout, open(
                    response / "stderr", "wb"
                ) as stderr:
                    result = subprocess.run(
                        ["/bin/bash", "-c", command],
                        cwd=ARCH_HOME,
                        stdin=source,
                        stdout=stdout,
                        stderr=stderr,
                        check=False,
                    )
                status = result.returncode if result.returncode >= 0 else 128 - result.returncode
    except Exception as error:  # keep the host-side caller from waiting forever
        (response / "stdout").write_bytes(b"")
        (response / "stderr").write_text(
            f"guest command channel error: {type(error).__name__}: {error}\n",
            encoding="utf-8",
        )
        status = 255
    write_status(response / "status", status)


def main():
    if len(sys.argv) != 2:
        return 2
    root = Path(sys.argv[1])
    requests = root / "requests"
    responses = root / "responses"
    requests.mkdir(exist_ok=True)
    responses.mkdir(exist_ok=True)
    os.umask(0o022)
    (root / "ready").touch()

    while True:
        found = False
        for request in sorted(requests.iterdir()):
            marker = request / "ready"
            if not request.is_dir() or not marker.is_file():
                continue
            marker.unlink(missing_ok=True)
            found = True
            process_request(request, responses)
        if not found:
            time.sleep(0.2)


if __name__ == "__main__":
    raise SystemExit(main())
