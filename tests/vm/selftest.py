#!/usr/bin/env python3
"""Self-test for the VM test's own machinery, without a VM: the compositor calls give up on a
silent or truncated peer instead of hanging, QMP calls do too, and the checks' predicates reject
what they should (an empty audio sink section, an unchanged volume, a blank screen region).

  tests/vm/selftest.py      exits 1 if anything fails
"""
import importlib.util
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("guest_check", os.path.join(here, "guest-check.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
failures = 0


def expect(name, ok, detail=""):
    global failures
    failures += 0 if ok else 1
    print(f"{'PASS' if ok else 'FAIL'} {name}{': ' + str(detail) if detail else ''}")


def fake_peer(path, behavior):
    server = socket.socket(socket.AF_UNIX)
    server.bind(path)
    server.listen(1)

    def serve():
        conn, _ = server.accept()
        conn.recv(65536)
        if behavior == "truncated":
            conn.sendall(struct.pack("<I", 100) + b'{"res')
            conn.close()
        elif behavior == "huge":
            conn.sendall(struct.pack("<I", 1 << 30))
            conn.close()
        elif behavior == "silent":
            time.sleep(5)
            conn.close()
        elif behavior == "qmp-silent":
            time.sleep(5)
            conn.close()
    threading.Thread(target=serve, daemon=True).start()
    return server


with tempfile.TemporaryDirectory() as tmp:
    g.IPC_TIMEOUT = 1
    for behavior, error in (("silent", OSError), ("truncated", ConnectionError), ("huge", ConnectionError)):
        path = os.path.join(tmp, behavior)
        fake_peer(path, behavior)
        start = time.monotonic()
        try:
            g.ipc("scottland/layout-state", path=path)
            raised = None
        except Exception as e:
            raised = e
        took = time.monotonic() - start
        expect(f"ipc gives up on a {behavior} compositor", isinstance(raised, error) and took < 3,
               f"{type(raised).__name__} after {took:.1f}s")

    path = os.path.join(tmp, "qmp")
    fake_peer(path, "qmp-silent")
    start = time.monotonic()
    r = subprocess.run([sys.executable, os.path.join(here, "qmp.py"), path, "query-status"],
                       env={**os.environ, "QMP_TIMEOUT": "1"}, capture_output=True, text=True)
    expect("qmp.py gives up on a silent QEMU", r.returncode == 2 and time.monotonic() - start < 4, r.stdout.strip())

expect("volume parsing", g.volume_of("Volume: 0.40") == 0.40 and g.volume_of("Volume: 0.45 [MUTED]") == 0.45
       and g.volume_of("no sink") is None)
expect("an unchanged volume isn't a raise", not (g.volume_of("Volume: 0.40") < g.volume_of("Volume: 0.40")))
expect("an empty sink section isn't a sink", not g.sink_present(1, "") and not g.sink_present(0, "Audio\n Sinks:\n"))
expect("a described node is a sink", g.sink_present(0, ' * node.name = "alsa_output.pci"'))
black = b"P6\n10 10\n255\n" + bytes(300)
gray = b"P6\n10 10\n255\n" + bytes([128]) * 300
noise = b"P6\n10 10\n255\n" + bytes((i * 37) % 256 for i in range(300))
expect("a black region isn't a wallpaper", not g.looks_drawn(black))
expect("a flat gray region isn't a wallpaper", not g.looks_drawn(gray))
expect("a varied region is", g.looks_drawn(noise))
expect("night longitude is at local midnight", all(
    abs(((h + g.night_longitude(g.datetime(2026, 1, 1, h, 0, tzinfo=g.timezone.utc)) / 15) % 24)) < 1e-9
    for h in range(24)))
print(f"{'all passed' if not failures else f'{failures} failed'}")
sys.exit(1 if failures else 0)
