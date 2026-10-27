#!/usr/bin/env python3
"""Bridge QEMU guestfwd streams to the loopback cloud-init seed server."""

import os
import select
import socket
import sys


def write_all(fd, data):
    view = memoryview(data)
    while view:
        count = os.write(fd, view)
        if count <= 0:
            raise OSError("short write to guest stream")
        view = view[count:]


def main():
    if len(sys.argv) != 2:
        print("usage: seed-http-bridge.py PORT", file=sys.stderr)
        return 2

    try:
        port = int(sys.argv[1])
        if not 1 <= port <= 65535:
            raise ValueError
    except ValueError:
        print("seed HTTP port is invalid", file=sys.stderr)
        return 2

    try:
        upstream = socket.create_connection(("127.0.0.1", port), timeout=10)
    except OSError as error:
        print(f"seed HTTP server is unavailable: {error}", file=sys.stderr)
        return 1

    upstream.settimeout(None)
    stdin_open = True
    try:
        while True:
            readers = [upstream]
            if stdin_open:
                readers.append(sys.stdin.fileno())
            readable, _, _ = select.select(readers, [], [])

            if stdin_open and sys.stdin.fileno() in readable:
                request = os.read(sys.stdin.fileno(), 65536)
                if request:
                    upstream.sendall(request)
                else:
                    stdin_open = False
                    try:
                        upstream.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass

            if upstream in readable:
                response = upstream.recv(65536)
                if not response:
                    return 0
                write_all(sys.stdout.fileno(), response)
    except (BrokenPipeError, ConnectionResetError):
        return 0
    except OSError as error:
        print(f"seed HTTP bridge failed: {error}", file=sys.stderr)
        return 1
    finally:
        upstream.close()


if __name__ == "__main__":
    raise SystemExit(main())
