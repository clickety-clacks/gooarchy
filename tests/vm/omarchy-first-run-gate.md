# Omarchy first-run screen gate

`omarchy_first_run_gate.py` classifies one QMP screenshot of Omarchy 4.5.0-3's
first-run setup screen. It is read-only: it does not start QEMU, contact QMP,
send guest input, or authorize a follow-on action. A separate assignment must
specify any next input.

The gate uses a human-attended full-frame review because the retained evidence
does not establish a pinned offline OCR method. Review the current PNG at its
native resolution. Bind the review to that file's SHA-256 and panel digest. If
any text or foreground state is uncertain, or the image and diagnostics
disagree, record the uncertainty and stop.

## Invocation

```sh
python3 tests/vm/omarchy_first_run_gate.py \
  --png capture.png \
  --capture-json capture.json \
  --review-json review.json
```

The program prints one JSON result. Exit `0` means the evidence matches the
screen definition and prints `ACCEPT_FIRST_RUN_SCREEN`; exit `42` means
`STOP_UNKNOWN`, with reason codes. Neither result sends input. In particular,
`ACCEPT_FIRST_RUN_SCREEN` identifies only the current screen; it is not
permission to press a key or start another step.

## Capture record

`capture.json` records the run facts used by the gate:

```json
{
  "image_sha256": "dcb401aabf1b01bf3c983a1b048bcd0ac7d66e4f5a755acd9452bf66e18cd5c4",
  "image_size_bytes": 4182376448,
  "boot_helper_commit": "69f9a702975766a9dd9d5e39101c203c6a963885",
  "boot_helper_sha256": "fc2becf1d3f3441ab45e972ca4904b5808800e819a1a0308bc4bc74424388382",
  "qemu_version": "QEMU emulator version 8.2.2",
  "qemu_img_version": "qemu-img version 8.2.2",
  "qmp_running": true,
  "capture_method": "qmp-screendump",
  "screendump_count": 1,
  "run_isolation": {
    "base_image_read_only": true,
    "copy_on_write_overlay": true,
    "run_owned_overlay": true,
    "run_owned_scratch": true,
    "qemu_confined_to_current_run": true
  },
  "network": {
    "recorded": true,
    "qemu_network_flags": []
  }
}
```

The gate checks these supplied fields; it does not independently inspect the
QEMU process or prove that a capture manifest is truthful. An empty network
flag list is reported as `qemu_default_user_mode_network_possible_guest_state_unverified`.
It does not mean networking is disabled. Explicit `-nic none` is reported as
the QEMU NIC being disabled, while actual guest network state remains
unverified. Pass the exact tokenized QEMU network arguments in the list, not a
single space-joined string. Network is recorded as run context and does not
affect screen classification.

If you need the panel digest before writing the attended record, an incomplete
review record returns `STOP_UNKNOWN` and includes the computed digest in its
JSON output. Use that value only to bind the later attended review; the
incomplete result must not be treated as acceptance.

## Attended review record

`review.json` must bind to both the exact PNG bytes and the computed diagnostic
panel digest:

```json
{
  "method": "human-attended-full-frame",
  "capture_sha256": "<sha256 of capture.png>",
  "panel_rgb_sha256": "<digest printed from the same decoded PNG>",
  "uncertain": false,
  "full_frame_reviewed": true,
  "exactly_four_setup_cards": true,
  "cards_ordered": true,
  "cards_non_overlapping": true,
  "cards_inside_right_panel": true,
  "no_unassigned_card_text": true,
  "no_unexpected_foreground_surface": true,
  "no_terminal_or_login_prompt": true,
  "no_modal_error_menu_overlap_or_extra_dialog": true,
  "wallpaper_does_not_obscure_cards": true,
  "pixel_diagnostic_reviewed": true,
  "no_semantic_disagreement": true,
  "recognition_unambiguous": true,
  "cards": [
    {
      "title": "Update System",
      "body": ["Click to update the system."],
      "bounds": [895, 31, 1275, 95],
      "border_complete": true,
      "text_unambiguous": true,
      "text_associated": true,
      "no_extra_text": true
    },
    {
      "title": "Set your default agent",
      "body": ["Let your favorite agent help with Omarchy."],
      "bounds": [895, 106, 1275, 170],
      "border_complete": true,
      "text_unambiguous": true,
      "text_associated": true,
      "no_extra_text": true
    },
    {
      "title": "Setup Git",
      "body": ["Identification for code commits."],
      "bounds": [895, 181, 1275, 245],
      "border_complete": true,
      "text_unambiguous": true,
      "text_associated": true,
      "no_extra_text": true
    },
    {
      "title": "Learn Keybindings",
      "body": ["Super + K for cheatsheet.", "Super + Space for Omarchy Menu."],
      "bounds": [895, 256, 1275, 334],
      "border_complete": true,
      "text_unambiguous": true,
      "text_associated": true,
      "no_extra_text": true
    }
  ]
}
```

Include all four cards in the exact order. Required text is:

1. `Update System` — `Click to update the system.`
2. `Set your default agent` — `Let your favorite agent help with Omarchy.`
3. `Setup Git` — `Identification for code commits.`
4. `Learn Keybindings` — `Super + K for cheatsheet.` and `Super + Space for Omarchy Menu.`

Card bounds use half-open coordinates and allow a two-pixel tolerance around
the reviewed reference geometry. The gate still requires four complete,
ordered, non-overlapping right-panel cards with exact text and unambiguous
card association. The panel digest covers `[895,30)-[1279,335)` and is retained
only as diagnostic provenance; it is not compared to a fixed allowlist and
cannot override the semantic review.

The three reviewed same-image frames all showed the positive setup screen, but
their panel digests differed (`7d5bce07…`, `f2fbb347…`, and `e1b3fe75…`). This
is why the gate binds the review to the current digest without treating a
particular digest as screen identity.

Every missing, malformed, mismatched or uncertain capture/review fact returns
`STOP_UNKNOWN`. That includes changed or unreadable card text, missing or extra
cards, an incomplete border, unexpected foreground UI, a panel-digest binding
mismatch, invalid PNG data, image/runtime identity mismatch, QMP not running,
or unproved run isolation. No currently retained negative/unknown screenshot
exists for the pinned image; synthetic state cases in `selftest.py` exercise
the stop logic but are not evidence of an observed negative guest screen.
