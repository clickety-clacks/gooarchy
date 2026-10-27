#!/usr/bin/env python3
"""Serve cloud-init NoCloud files over QEMU guestfwd stdin/stdout, without host sockets."""

import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


def read_request(stream):
    line = stream.readline()
    if not line:
        return None
    parts = line.decode("iso-8859-1").strip().split()
    if len(parts) != 3:
        return None
    method, target, _version = parts
    while True:
        line = stream.readline()
        if line in (b"\r\n", b"\n", b""):
            break
    return method, target


def respond(status, reason, body, method):
    headers = (
        f"HTTP/1.0 {status} {reason}\r\n"
        "Content-Type: text/plain\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("ascii")
    output = sys.stdout.buffer
    output.write(headers)
    if method != "HEAD":
        output.write(body)
    output.flush()


def main():
    if len(sys.argv) != 2:
        print("usage: seed-http-response.py SEED_DIR", file=sys.stderr)
        return 2

    request = read_request(sys.stdin.buffer)
    if request is None:
        return 0
    method, target = request
    if method not in ("GET", "HEAD"):
        respond(405, "Method Not Allowed", b"", method)
        return 0

    try:
        name = unquote(urlsplit(target).path).lstrip("/")
    except ValueError:
        respond(400, "Bad Request", b"", method)
        return 0

    if name == "":
        body = b"meta-data\nuser-data\n"
        respond(200, "OK", body, method)
        return 0

    if name not in {"meta-data", "user-data", "vendor-data", "network-config"}:
        respond(404, "Not Found", b"", method)
        return 0

    try:
        body = (Path(sys.argv[1]) / name).read_bytes()
    except FileNotFoundError:
        respond(404, "Not Found", b"", method)
        return 0
    except OSError as error:
        print(f"could not read seed file: {error}", file=sys.stderr)
        respond(500, "Internal Server Error", b"", method)
        return 1

    respond(200, "OK", body, method)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
