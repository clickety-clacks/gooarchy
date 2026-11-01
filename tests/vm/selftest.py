#!/usr/bin/env python3
"""Self-test for the VM test's own machinery, without a VM: the compositor calls give up on a
silent or truncated peer instead of hanging, QMP calls do too, and the checks' predicates reject
what they should (an empty audio sink section, an unchanged volume, a blank screen region).

  tests/vm/selftest.py      exits 1 if anything fails
"""
import importlib.util
import json
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
signature_info = "Packager        : Gooarchy\nValidated By    : Signature\n"
sha256_signature_info = "Packager        : Gooarchy\nValidated By    : SHA-256 Sum Signature\n"
unsigned_info = "Packager        : Gooarchy\nValidated By    : SHA-256 Sum\n"
other_packager_info = "Packager        : Other\nValidated By    : SHA-256 Sum Signature\n"
expect("pacman signature metadata accepts Signature",
       g.package_has_repository_signature(signature_info, "Gooarchy"))
expect("pacman signature metadata accepts SHA-256 Sum Signature",
       g.package_has_repository_signature(sha256_signature_info, "Gooarchy"))
expect("pacman signature metadata rejects unsigned packages",
       not g.package_has_repository_signature(unsigned_info, "Gooarchy"))
expect("pacman signature metadata checks the expected packager",
       not g.package_has_repository_signature(other_packager_info, "Gooarchy"))
black = b"P6\n10 10\n255\n" + bytes(300)
gray = b"P6\n10 10\n255\n" + bytes([128]) * 300
noise = b"P6\n10 10\n255\n" + bytes((i * 37) % 256 for i in range(300))
expect("a black region isn't a wallpaper", not g.looks_drawn(black))
expect("a flat gray region isn't a wallpaper", not g.looks_drawn(gray))
expect("a varied region is", g.looks_drawn(noise))
expect("Sunlight no-location requires GeoClue absent, IP lookup disabled and no saved coordinates",
       g.sunlight_no_location_premise(False, False, False))
expect("Sunlight IP lookup prevents a no-location claim",
       not g.sunlight_no_location_premise(False, True, False))
expect("saved coordinates prevent a no-location claim",
       not g.sunlight_no_location_premise(False, False, True))
expect("GeoClue prevents a no-location claim",
       not g.sunlight_no_location_premise(True, False, False))
expect("Sunlight documented fallback keeps the selected mode when no location exists",
       g.sunlight_no_location_fallback(
           True, "set fallback coordinates in Settings", "prefer-light", "prefer-light"))
expect("Sunlight fallback assertion rejects a location-present mode change",
       not g.sunlight_no_location_fallback(
           False, "", "prefer-light", "prefer-dark"))
screen = {"x": 0, "y": 0, "width": 640, "height": 480}
mapped_views = [
    {"frame": {"x": 0, "y": 0, "width": 640, "height": 240}},
    {"geometry": {"x": 480, "y": 240, "width": 160, "height": 240}},
]
region = g.uncovered_wallpaper_region(screen, mapped_views, sample_size=120, step=120)
expect("wallpaper sampling finds a region outside mapped views",
       region is not None and not any(g.rectangles_overlap(
           {"x": region[0], "y": region[1], "width": region[2], "height": region[3]},
           g.view_rectangle(item)) for item in mapped_views))
expect("wallpaper positive control recognizes a picture in the uncovered sample",
       region is not None and g.looks_drawn(noise))
expect("wallpaper negative control rejects blank pixels in the uncovered sample",
       region is not None and not g.looks_drawn(black))
expect("wallpaper sampling refuses a fully covered screen",
       g.uncovered_wallpaper_region(screen, [{"frame": screen}], sample_size=120, step=120) is None)
background_view = {"layer": "background", "mapped": True, "geometry": screen}
expect("a full-output background wallpaper layer does not cover its sample",
       g.uncovered_wallpaper_region(screen, [background_view], sample_size=120, step=120) is not None)
overlay_view = {"layer": "overlay", "mapped": True, "geometry": screen}
expect("a full-output overlay remains a covering view",
       g.uncovered_wallpaper_region(screen, [overlay_view], sample_size=120, step=120) is None)
wayfire_focused_views = [{
    "id": 7,
    "app-id": "strata",
    "activated": True,
    "mapped": True,
}]
focused_view = {
    "id": 7,
    "app-id": "strata",
    "activated": True,
    "mapped": True,
}
original_all_views = g.all_views
g.all_views = lambda: wayfire_focused_views
settings_presses = []


def capture_settings_press(layout, binding):
    context = g.settings_shortcut_context(
        layout, binding, ["KEY_LEFTMETA"], g.focused_view_state())
    settings_presses.append(context)
    return context


settings_sent, settings_context = g.settings_shortcut_after_layout(
    "us", "<super> KEY_COMMA", capture_settings_press)
expect("Settings shortcut is sent after the US layout settles",
       settings_sent and len(settings_presses) == 1)
expect("Settings shortcut evidence captures binding, modifier and focus",
       settings_context == {
           "layout": "us",
           "binding_option": "command/binding_scottland_settings",
           "active_binding": "<super> KEY_COMMA",
           "modifiers_at_press": ["KEY_LEFTMETA"],
           "focused_view": focused_view,
       })
unsettled_sent, unsettled_context = g.settings_shortcut_after_layout(
    None, "<super> KEY_COMMA", capture_settings_press)
expect("Settings shortcut is not sent when the layout has not settled",
       not unsettled_sent and unsettled_context is None and len(settings_presses) == 1)
input_events = []
original_key, original_log = g.key, g.log
g.key = lambda name, down: input_events.append(("key", name, down))
g.log = lambda message: input_events.append(("log", message))
try:
    pressed_context = g.press_settings_shortcut("us", "<super> KEY_COMMA")
finally:
    g.key, g.log = original_key, original_log
    g.all_views = original_all_views
key_events = [event[1:] for event in input_events if event[0] == "key"]
context_log = next(event[1] for event in input_events if event[0] == "log")
logged_context = json.loads(context_log.split(": ", 1)[1])
meta_down = next(i for i, event in enumerate(input_events)
                 if event == ("key", "KEY_LEFTMETA", True))
log_position = next(i for i, event in enumerate(input_events) if event[0] == "log")
comma_down = next(i for i, event in enumerate(input_events)
                  if event == ("key", "KEY_COMMA", True))
expect("Settings input context is captured with Super down before comma",
       key_events == [("KEY_LEFTMETA", True), ("KEY_COMMA", True),
                      ("KEY_COMMA", False), ("KEY_LEFTMETA", False)]
       and meta_down < log_position < comma_down
       and logged_context == pressed_context
       and logged_context["binding_option"] == "command/binding_scottland_settings"
       and logged_context["active_binding"] == "<super> KEY_COMMA"
       and logged_context["modifiers_at_press"] == ["KEY_LEFTMETA"]
       and logged_context["focused_view"] == focused_view)
expect("night longitude is at local midnight", all(
    abs(((h + g.night_longitude(g.datetime(2026, 1, 1, h, 0, tzinfo=g.timezone.utc)) / 15) % 24)) < 1e-9
    for h in range(24)))
print(f"{'all passed' if not failures else f'{failures} failed'}")
sys.exit(1 if failures else 0)
