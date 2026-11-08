#!/usr/bin/env python3
"""Fail-closed, read-only gate for Omarchy 4.5.0-3's initial setup screen.

This command validates run and capture evidence plus a structured, human-attended
full-frame review. It does not recognize pixels semantically and never sends
guest input. ACCEPT_FIRST_RUN_SCREEN is only a screen classification; a
separate run instruction must authorize any next action.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any


EXPECTED_IMAGE_SHA256 = "dcb401aabf1b01bf3c983a1b048bcd0ac7d66e4f5a755acd9452bf66e18cd5c4"
EXPECTED_IMAGE_BYTES = 4_182_376_448
EXPECTED_HELPER_COMMIT = "69f9a702975766a9dd9d5e39101c203c6a963885"
EXPECTED_HELPER_SHA256 = "fc2becf1d3f3441ab45e972ca4904b5808800e819a1a0308bc4bc74424388382"
EXPECTED_QEMU_VERSION = "8.2.2"
EXPECTED_WIDTH = 1280
EXPECTED_HEIGHT = 800
# Preserve the former panel ROI as diagnostic provenance only. The reviewed
# v2 rule does not allow this digest to decide screen identity by itself.
PANEL_BOUNDS = (895, 30, 1279, 335)

# Bounds use half-open coordinates. The two-pixel tolerance covers the
# one-pixel reference-edge correction from the attended frame review without
# learning a new layout from a failed capture.
CARD_SPECS = (
    {
        "title": "Update System",
        "body": ("Click to update the system.",),
        "bounds": (895, 31, 1275, 95),
    },
    {
        "title": "Set your default agent",
        "body": ("Let your favorite agent help with Omarchy.",),
        "bounds": (895, 106, 1275, 170),
    },
    {
        "title": "Setup Git",
        "body": ("Identification for code commits.",),
        "bounds": (895, 181, 1275, 245),
    },
    {
        "title": "Learn Keybindings",
        "body": ("Super + K for cheatsheet.", "Super + Space for Omarchy Menu."),
        "bounds": (895, 256, 1275, 334),
    },
)
BOUNDS_TOLERANCE = 2

ISOLATION_CHECKS = (
    "base_image_read_only",
    "copy_on_write_overlay",
    "run_owned_overlay",
    "run_owned_scratch",
    "qemu_confined_to_current_run",
)
REVIEW_CHECKS = (
    "full_frame_reviewed",
    "exactly_four_setup_cards",
    "cards_ordered",
    "cards_non_overlapping",
    "cards_inside_right_panel",
    "no_unassigned_card_text",
    "no_unexpected_foreground_surface",
    "no_terminal_or_login_prompt",
    "no_modal_error_menu_overlap_or_extra_dialog",
    "wallpaper_does_not_obscure_cards",
    "pixel_diagnostic_reviewed",
    "no_semantic_disagreement",
    "recognition_unambiguous",
)
CARD_CHECKS = (
    "border_complete",
    "text_unambiguous",
    "text_associated",
    "no_extra_text",
)


class EvidenceError(ValueError):
    """The PNG cannot be safely decoded as the required RGB8 frame."""


@dataclass(frozen=True)
class PngInfo:
    width: int
    height: int
    pixel_format: str
    decoded_rgb_sha256: str
    panel_rgb_sha256: str


def _paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def decode_png_rgb8(data: bytes) -> PngInfo:
    """Validate and decode a non-interlaced, 8-bit RGB PNG using stdlib only."""
    if not isinstance(data, bytes) or not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise EvidenceError("png_signature_invalid")

    position = 8
    width = height = bit_depth = color_type = None
    compressed = bytearray()
    seen_ihdr = False
    seen_idat = False
    idat_closed = False
    seen_iend = False

    while position < len(data):
        if position + 12 > len(data):
            raise EvidenceError("png_chunk_truncated")
        length = struct.unpack_from(">I", data, position)[0]
        kind = data[position + 4 : position + 8]
        payload_start = position + 8
        payload_end = payload_start + length
        chunk_end = payload_end + 4
        if chunk_end > len(data):
            raise EvidenceError("png_chunk_truncated")
        payload = data[payload_start:payload_end]
        expected_crc = struct.unpack_from(">I", data, payload_end)[0]
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != expected_crc:
            raise EvidenceError("png_chunk_crc_invalid")

        if not seen_ihdr:
            if kind != b"IHDR" or length != 13:
                raise EvidenceError("png_ihdr_missing_or_misordered")
            width, height, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            if compression != 0 or filter_method != 0 or interlace != 0:
                raise EvidenceError("png_encoding_unsupported")
            seen_ihdr = True
        elif kind == b"IHDR":
            raise EvidenceError("png_duplicate_ihdr")
        elif kind == b"IDAT":
            if idat_closed:
                raise EvidenceError("png_idat_not_contiguous")
            seen_idat = True
            compressed.extend(payload)
        elif kind == b"tRNS":
            # The gate requires fully opaque RGB8 pixels. Do not silently
            # discard transparency metadata while converting the frame.
            raise EvidenceError("png_transparency_unsupported")
        elif kind == b"IEND":
            if length != 0 or not seen_idat:
                raise EvidenceError("png_iend_invalid")
            seen_iend = True
            position = chunk_end
            break
        else:
            if seen_idat:
                idat_closed = True
            # Unknown critical chunks could change pixel interpretation.
            if kind and not (kind[0] & 0x20):
                raise EvidenceError("png_critical_chunk_unsupported")
        if kind != b"IDAT" and seen_idat:
            idat_closed = True
        position = chunk_end

    if not seen_ihdr or not seen_iend or position != len(data):
        raise EvidenceError("png_incomplete_or_trailing_data")
    if bit_depth != 8 or color_type != 2:
        raise EvidenceError("png_not_rgb8")
    if width != EXPECTED_WIDTH or height != EXPECTED_HEIGHT:
        raise EvidenceError("png_resolution_mismatch")

    bytes_per_pixel = 3
    stride = width * bytes_per_pixel
    expected_raw_size = height * (stride + 1)
    inflater = zlib.decompressobj()
    raw = inflater.decompress(bytes(compressed), expected_raw_size + 1)
    if inflater.unconsumed_tail or inflater.unused_data or not inflater.eof:
        raise EvidenceError("png_zlib_stream_invalid")
    if len(raw) != expected_raw_size:
        raise EvidenceError("png_decoded_size_mismatch")

    decoded = bytearray()
    panel = bytearray()
    previous = bytearray(stride)
    offset = 0
    panel_x1, panel_y1, panel_x2, panel_y2 = PANEL_BOUNDS
    for row_index in range(height):
        filter_type = raw[offset]
        filtered = raw[offset + 1 : offset + 1 + stride]
        offset += stride + 1
        if filter_type > 4:
            raise EvidenceError("png_filter_invalid")
        current = bytearray(stride)
        for index, value in enumerate(filtered):
            left = current[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            above = previous[index]
            upper_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            else:
                predictor = _paeth(left, above, upper_left)
            current[index] = (value + predictor) & 0xFF
        decoded.extend(current)
        if panel_y1 <= row_index < panel_y2:
            panel.extend(current[panel_x1 * bytes_per_pixel : panel_x2 * bytes_per_pixel])
        previous = current

    return PngInfo(
        width=width,
        height=height,
        pixel_format="RGB8",
        decoded_rgb_sha256=hashlib.sha256(decoded).hexdigest(),
        panel_rgb_sha256=hashlib.sha256(panel).hexdigest(),
    )


def network_context(network: Any) -> str:
    """Describe recorded QEMU network flags without claiming guest state."""
    if not isinstance(network, dict) or network.get("recorded") is not True:
        return "network_configuration_unrecorded"
    flags = network.get("qemu_network_flags")
    if not isinstance(flags, list) or any(not isinstance(flag, str) for flag in flags):
        return "network_configuration_unrecorded"

    pairs = set(zip(flags, flags[1:]))
    if (
        "-nic=none" in flags
        or ("-nic", "none") in pairs
        or ("-net", "none") in pairs
        or ("-netdev", "none") in pairs
    ):
        return "qemu_nic_explicitly_disabled_guest_state_unverified"
    explicit_network = any(
        flag in {"-nic", "-net", "-netdev"}
        or flag.startswith(("-nic=", "-net=", "-netdev="))
        or (flag == "-device" and index + 1 < len(flags) and "netdev=" in flags[index + 1])
        or (flag == "-device" and index + 1 < len(flags) and flags[index + 1] in {"e1000", "e1000e", "virtio-net-pci"})
        for index, flag in enumerate(flags)
    )
    if "-nodefaults" in flags and not explicit_network:
        return "qemu_default_devices_disabled_guest_state_unverified"
    if not flags:
        return "qemu_default_user_mode_network_possible_guest_state_unverified"
    return "qemu_network_flags_explicit_guest_state_unverified"


def _normalize_text(value: str) -> str:
    if not isinstance(value, str):
        return ""
    return " ".join(value.split())


def _all_true(mapping: Any, names: tuple[str, ...]) -> bool:
    return isinstance(mapping, dict) and all(mapping.get(name) is True for name in names)


def _version_is_pinned(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    match = re.search(r"(?<![A-Za-z0-9.])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9.])", value)
    return bool(match and match.group(1) == EXPECTED_QEMU_VERSION)


def _boxes_overlap(left: tuple[int, int, int, int], right: tuple[int, int, int, int]) -> bool:
    return not (left[2] <= right[0] or right[2] <= left[0] or left[3] <= right[1] or right[3] <= left[1])


def _check_cards(review: Any, reasons: list[str]) -> None:
    if not isinstance(review, dict):
        reasons.append("review_missing")
        return
    cards = review.get("cards")
    if not isinstance(cards, list) or len(cards) != len(CARD_SPECS):
        reasons.append("card_count_mismatch")
        return

    checked_boxes: list[tuple[int, int, int, int]] = []
    for index, (card, spec) in enumerate(zip(cards, CARD_SPECS), start=1):
        if not isinstance(card, dict):
            reasons.append(f"card_{index}_invalid")
            continue
        if _normalize_text(card.get("title", "")) != spec["title"]:
            reasons.append(f"card_{index}_title_mismatch")
        body = card.get("body")
        if not isinstance(body, list) or any(not isinstance(line, str) for line in body):
            reasons.append(f"card_{index}_body_invalid")
        elif tuple(_normalize_text(line) for line in body) != spec["body"]:
            reasons.append(f"card_{index}_body_mismatch")
        if not _all_true(card, CARD_CHECKS):
            reasons.append(f"card_{index}_review_incomplete")

        bounds = card.get("bounds")
        if (
            not isinstance(bounds, list)
            or len(bounds) != 4
            or any(type(value) is not int for value in bounds)
        ):
            reasons.append(f"card_{index}_bounds_invalid")
            continue
        box = tuple(bounds)
        x1, y1, x2, y2 = box
        if not (640 <= x1 < x2 <= EXPECTED_WIDTH and 0 <= y1 < y2 <= EXPECTED_HEIGHT):
            reasons.append(f"card_{index}_outside_display_or_right_panel")
            continue
        if any(abs(actual - expected) > BOUNDS_TOLERANCE for actual, expected in zip(box, spec["bounds"])):
            reasons.append(f"card_{index}_bounds_mismatch")
        checked_boxes.append(box)

    if len(checked_boxes) == len(CARD_SPECS):
        for previous, current in zip(checked_boxes, checked_boxes[1:]):
            if current[1] < previous[1]:
                reasons.append("cards_not_ordered_top_to_bottom")
                break
        for left_index, left in enumerate(checked_boxes):
            if any(_boxes_overlap(left, right) for right in checked_boxes[left_index + 1 :]):
                reasons.append("card_bounds_overlap")
                break


def evaluate_parsed(
    capture: Any,
    png: PngInfo | None,
    frame_sha256: str | None,
    review: Any,
    png_error: str | None = None,
) -> dict[str, Any]:
    """Return a screen-only decision; every missing or conflicting fact stops."""
    reasons: list[str] = []
    network = capture.get("network") if isinstance(capture, dict) else None
    network_label = network_context(network)

    if not isinstance(capture, dict):
        reasons.append("capture_metadata_missing")
    else:
        if capture.get("image_sha256") != EXPECTED_IMAGE_SHA256:
            reasons.append("image_identity_mismatch")
        if type(capture.get("image_size_bytes")) is not int or capture.get("image_size_bytes") != EXPECTED_IMAGE_BYTES:
            reasons.append("image_size_mismatch")
        if capture.get("boot_helper_commit") != EXPECTED_HELPER_COMMIT:
            reasons.append("boot_helper_commit_mismatch")
        if capture.get("boot_helper_sha256") != EXPECTED_HELPER_SHA256:
            reasons.append("boot_helper_sha256_mismatch")
        if not _version_is_pinned(capture.get("qemu_version")):
            reasons.append("qemu_version_mismatch")
        if not _version_is_pinned(capture.get("qemu_img_version")):
            reasons.append("qemu_img_version_mismatch")
        if capture.get("qmp_running") is not True:
            reasons.append("qmp_not_running")
        if capture.get("capture_method") != "qmp-screendump":
            reasons.append("capture_method_mismatch")
        if type(capture.get("screendump_count")) is not int or capture.get("screendump_count") != 1:
            reasons.append("screendump_count_mismatch")
        if not _all_true(capture.get("run_isolation"), ISOLATION_CHECKS):
            reasons.append("run_isolation_unproved")
        if network_label == "network_configuration_unrecorded":
            reasons.append("network_configuration_unrecorded")

    if png_error is not None:
        reasons.append(png_error)
    elif png is None:
        reasons.append("png_decode_unavailable")
    else:
        if png.width != EXPECTED_WIDTH or png.height != EXPECTED_HEIGHT:
            reasons.append("png_resolution_mismatch")
        if png.pixel_format != "RGB8":
            reasons.append("png_pixel_format_mismatch")

    if not isinstance(frame_sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", frame_sha256):
        reasons.append("frame_sha256_missing_or_invalid")

    if not isinstance(review, dict):
        reasons.append("review_missing")
    else:
        if review.get("method") != "human-attended-full-frame":
            reasons.append("review_method_unsupported")
        if review.get("capture_sha256") != frame_sha256:
            reasons.append("review_capture_binding_mismatch")
        if png is not None and review.get("panel_rgb_sha256") != png.panel_rgb_sha256:
            reasons.append("panel_digest_binding_mismatch")
        if review.get("uncertain") is not False:
            reasons.append("review_uncertain_or_unknown")
        if not _all_true(review, REVIEW_CHECKS):
            reasons.append("full_frame_review_incomplete_or_conflicting")
        _check_cards(review, reasons)

    reasons = list(dict.fromkeys(reasons))
    decision = "STOP_UNKNOWN" if reasons else "ACCEPT_FIRST_RUN_SCREEN"
    network_flags = (
        network.get("qemu_network_flags")
        if isinstance(network, dict)
        and network.get("recorded") is True
        and isinstance(network.get("qemu_network_flags"), list)
        and all(isinstance(flag, str) for flag in network.get("qemu_network_flags"))
        else None
    )
    return {
        "decision": decision,
        "reason_codes": reasons,
        "frame_sha256": frame_sha256,
        "decoded_rgb_sha256": png.decoded_rgb_sha256 if png is not None else None,
        "panel_rgb_sha256": png.panel_rgb_sha256 if png is not None else None,
        "qemu_network_flags": network_flags,
        "network_context": network_label,
        "input_authorized": False,
        "next_action_authorized": False,
    }


def evaluate(capture: Any, png_bytes: bytes, review: Any) -> dict[str, Any]:
    frame_sha256 = hashlib.sha256(png_bytes).hexdigest() if isinstance(png_bytes, bytes) else None
    try:
        png = decode_png_rgb8(png_bytes)
    except (EvidenceError, zlib.error, struct.error, OverflowError):
        return evaluate_parsed(capture, None, frame_sha256, review, "png_decode_or_validation_failed")
    return evaluate_parsed(capture, png, frame_sha256, review)


def _load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Classify a captured Omarchy first-run screen from pinned run evidence and a human full-frame review. No guest input is sent."
    )
    parser.add_argument("--png", required=True, type=Path, help="one QMP screendump PNG")
    parser.add_argument("--capture-json", required=True, type=Path, help="run identity and isolation facts")
    parser.add_argument("--review-json", required=True, type=Path, help="human-attended review bound to this PNG hash")
    args = parser.parse_args(argv)

    try:
        result = evaluate(_load_json(args.capture_json), args.png.read_bytes(), _load_json(args.review_json))
    except (OSError, UnicodeError, json.JSONDecodeError):
        result = evaluate_parsed(None, None, None, None, "gate_input_unreadable_or_invalid")
    print(json.dumps(result, sort_keys=True))
    return 0 if result["decision"] == "ACCEPT_FIRST_RUN_SCREEN" else 42


if __name__ == "__main__":
    raise SystemExit(main())
