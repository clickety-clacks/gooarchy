#!/usr/bin/env python3
"""Witness pacman inside payload extraction, then reset a disposable NVIDIA VM."""

import argparse
import ctypes
import glob
import json
import os
import select
import signal
import struct
import sys
import termios
import time

IN_CLOSE_WRITE = 0x00000008
IN_CREATE = 0x00000100
IN_MOVED_TO = 0x00000080
IN_ISDIR = 0x40000000
IN_Q_OVERFLOW = 0x00004000
WATCH_MASK = IN_CLOSE_WRITE | IN_CREATE | IN_MOVED_TO
EVENT = struct.Struct("iIII")


def serial(line):
    fd = os.open("/dev/ttyS0", os.O_WRONLY | os.O_NOCTTY)
    try:
        os.write(fd, (line + "\r\n").encode("utf-8", "backslashreplace"))
        termios.tcdrain(fd)
    finally:
        os.close(fd)


def watch(fd, path, watched):
    path = os.path.abspath(path)
    if path in watched or not os.path.isdir(path):
        return
    wd = add_watch(fd, os.fsencode(path), WATCH_MASK)
    if wd < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), path)
    watched[path] = wd
    watched[wd] = path


def serial_json(kind, **fields):
    payload = json.dumps(fields, sort_keys=True, separators=(",", ":"))
    serial(f"GOOARCHY_NVIDIA_PACMAN_{kind} {payload}")


def process_state(pid):
    with open(f"/proc/{pid}/stat", encoding="ascii") as stream:
        stat = stream.read()
    end = stat.rfind(")")
    if end < 0:
        raise RuntimeError("cannot parse pacman process state")
    fields = stat[end + 1 :].split()
    return fields[0] if fields else ""


def stopped_state(pid):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        try:
            if process_state(pid) in {"T", "t"}:
                return True
        except FileNotFoundError:
            return False
        time.sleep(0.01)
    return False


def package_local_dirs(package):
    return sorted(glob.glob(f"/var/lib/pacman/local/{package}-*"))


def cached_file_count(path_list):
    with open(path_list, encoding="utf-8") as stream:
        files = [line.rstrip("\n") for line in stream if line.strip()]
    return sum(os.path.lexists(path) for path in files), len(files)


def local_dir_entries(path):
    try:
        return sorted(os.listdir(path))
    except OSError:
        return []


def validate_witness(pid, package, trigger, present_before, package_version, path_list, archive):
    state = process_state(pid)
    db_dirs = package_local_dirs(package)
    reason = ""
    if state not in {"T", "t"}:
        reason = "pacman-not-stopped"
    elif trigger in present_before or not os.path.lexists(trigger):
        reason = "payload-path-not-new"
    elif len(db_dirs) != 1:
        reason = "package-local-directory-not-unique"
    else:
        local_dir = db_dirs[0]
        if os.path.lexists(os.path.join(local_dir, "desc")) or os.path.lexists(
            os.path.join(local_dir, "files")
        ):
            reason = "package-registration-started"
        else:
            local_dir = db_dirs[0]
    if reason:
        return None, reason

    local_dir = db_dirs[0]
    existing, total = cached_file_count(path_list)
    evidence = {
        "package": package,
        "package_version": package_version,
        "cached_archive": archive,
        "pid": pid,
        "process_state": state,
        "local_dir": local_dir,
        "local_dir_entries": local_dir_entries(local_dir),
        "desc": "absent",
        "files": "absent",
        "trigger_path": trigger,
        "trigger_was_absent_before": trigger not in present_before,
        "trigger_exists_while_stopped": os.path.lexists(trigger),
        "cached_package_files_present": existing,
        "cached_package_files_total": total,
    }
    return evidence, ""


libc = ctypes.CDLL(None, use_errno=True)
init1 = libc.inotify_init1
init1.argtypes = [ctypes.c_int]
init1.restype = ctypes.c_int
add_watch = libc.inotify_add_watch
add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
add_watch.restype = ctypes.c_int


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--path-list", required=True)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--pacman-pid-file", required=True)
    parser.add_argument("--status-file", required=True)
    parser.add_argument("--package", default="nvidia-utils")
    parser.add_argument("--package-version", required=True)
    parser.add_argument("--archive", required=True)
    parser.add_argument("--trigger-path", required=True)
    args = parser.parse_args()

    with open(args.path_list, encoding="utf-8") as stream:
        payload_paths = [line.rstrip("\n") for line in stream if line.strip()]
    if not payload_paths or any(not os.path.isabs(path) for path in payload_paths):
        raise SystemExit("package payload path list is empty or invalid")
    payload_paths = [os.path.abspath(path) for path in payload_paths if not path.endswith("/")]
    targets = {os.path.abspath(args.trigger_path)}
    if not targets.issubset(set(payload_paths)):
        raise SystemExit("the selected trigger path is absent from the cached package file list")
    trigger = next(iter(targets))
    present_before = {path for path in payload_paths if os.path.lexists(path)}
    db_dirs_before = package_local_dirs(args.package)
    if trigger in present_before or db_dirs_before:
        serial_json(
            "UNEXERCISED",
            reason="fixture-precondition-failed",
            package=args.package,
            package_local_dirs=db_dirs_before,
            trigger_path=trigger,
            trigger_present_before=trigger in present_before,
        )
        with open(args.status_file, "w", encoding="ascii") as stream:
            stream.write("unexercised\tfixture-precondition-failed\n")
        return 2

    fd = init1(os.O_CLOEXEC)
    if fd < 0:
        raise OSError(ctypes.get_errno(), "inotify_init1 failed")

    watched = {}
    try:
        for target in targets:
            parent = os.path.dirname(target)
            missing = []
            while not os.path.isdir(parent):
                missing.append(parent)
                next_parent = os.path.dirname(parent)
                if next_parent == parent:
                    raise RuntimeError(f"no existing watch ancestor for {target}")
                parent = next_parent
            watch(fd, parent, watched)
            for created_dir in reversed(missing):
                watch(fd, created_dir, watched)

        serial_json(
            "WATCHER_ARMED",
            package=args.package,
            package_version=args.package_version,
            trigger_path=trigger,
            trigger_present_before=False,
            package_local_dirs_before=[],
        )
        with open(args.ready_file, "w", encoding="ascii") as stream:
            stream.write("ready\n")

        while True:
            select.select([fd], [], [])
            block = os.read(fd, 65536)
            offset = 0
            while offset + EVENT.size <= len(block):
                wd, mask, _cookie, name_len = EVENT.unpack_from(block, offset)
                offset += EVENT.size
                raw_name = block[offset : offset + name_len].split(b"\0", 1)[0]
                offset += name_len
                if mask & IN_Q_OVERFLOW:
                    serial("GOOARCHY_NVIDIA_PACMAN_WATCHER failed=queue-overflow")
                    return 2
                parent = watched.get(wd)
                if parent is None:
                    continue
                path = os.path.abspath(os.path.join(parent, os.fsdecode(raw_name)))
                if mask & IN_ISDIR:
                    if any(target.startswith(path + os.sep) for target in targets):
                        watch(fd, path, watched)
                        for target in targets:
                            if (
                                target.startswith(path + os.sep)
                                and target not in present_before
                                and os.path.lexists(target)
                            ):
                                path = target
                                break
                if path not in targets:
                    continue

                try:
                    with open(args.pacman_pid_file, encoding="ascii") as stream:
                        pacman_pid = int(stream.read().strip())
                    os.kill(pacman_pid, signal.SIGSTOP)
                    if not stopped_state(pacman_pid):
                        raise RuntimeError("pacman did not enter stopped state")
                    evidence, reason = validate_witness(
                        pacman_pid,
                        args.package,
                        path,
                        present_before,
                        args.package_version,
                        args.path_list,
                        args.archive,
                    )
                except (OSError, ValueError, RuntimeError) as exc:
                    evidence, reason = None, f"witness-error:{type(exc).__name__}"

                if evidence is None:
                    serial_json(
                        "UNEXERCISED",
                        reason=reason,
                        package=args.package,
                        package_version=args.package_version,
                        pid=locals().get("pacman_pid"),
                        trigger_path=path,
                    )
                    with open(args.status_file, "w", encoding="ascii") as stream:
                        stream.write(f"unexercised\t{reason}\n")
                    try:
                        os.kill(pacman_pid, signal.SIGCONT)
                    except (NameError, ProcessLookupError):
                        pass
                    return 2

                try:
                    serial_json("WITNESS", **evidence)
                    serial_json("RESET", trigger_path=path, method="sysrq-b-no-sync")
                    with open("/proc/sysrq-trigger", "wb", buffering=0) as trigger_file:
                        trigger_file.write(b"b")
                except OSError as exc:
                    try:
                        os.kill(pacman_pid, signal.SIGCONT)
                    except ProcessLookupError:
                        pass
                    serial_json(
                        "UNEXERCISED",
                        reason="reset-request-failed",
                        package=args.package,
                        pid=pacman_pid,
                        trigger_path=path,
                        error=type(exc).__name__,
                    )
                    with open(args.status_file, "w", encoding="ascii") as stream:
                        stream.write("unexercised\treset-request-failed\n")
                    return 2
                return 0
    finally:
        os.close(fd)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError) as exc:
        try:
            serial(f"GOOARCHY_NVIDIA_PACMAN_WATCHER failed={type(exc).__name__}:{exc}")
        except OSError:
            pass
        print(f"NVIDIA pacman payload watcher failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
