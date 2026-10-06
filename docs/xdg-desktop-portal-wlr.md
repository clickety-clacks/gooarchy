# xdg-desktop-portal-wlr: Gooarchy's patched build (a stopgap)

Scottland sends screen sharing and screenshot requests to xdg-desktop-portal-wlr (its
`scottland-portals.conf`). Arch's xdg-desktop-portal-wlr 0.8.4 loses most shared streams under
Wayfire: in Scottland's portal test the stream froze after one frame or the portal was
disconnected in most runs. Two small fixes remove both failures. Gooarchy builds 0.8.4 with them
as `xdg-desktop-portal-wlr-gooarchy` (`packaging/arch/xdg-desktop-portal-wlr/`) until an upstream
release contains them (Scottland ruling, 2026-10-05: fix the generic backend, get the fixes
accepted upstream, ship a patched copy only until upstream releases them).

## Status of the fixes upstream (2026-10-06)

**Proposed, not submitted, not accepted.** The two patches are local proposals by the Scottland
project. No pull request or issue carrying them exists upstream yet, so no upstream commit,
review or release contains them. Sending them is pending: the maintainer's policy on
LLM-assisted contributions applies (their author is an agent), so they go upstream in a human
contributor's own words, or as an issue a maintainer fixes.

| Patch | What it fixes | Upstream |
|---|---|---|
| 0001 screencast: keep an in-flight capture across a pause | the `duplicate_frame` protocol error and the stream frozen after its first frame | not submitted |
| 0002 screencast: don't destroy the process retry timer twice | a crash when a starved session closes | not submitted |

Upstream links, for whoever submits them and for checking a release:

- Repository: https://github.com/emersion/xdg-desktop-portal-wlr (the `v0.8` branch carries 0.8.x
  releases: https://github.com/emersion/xdg-desktop-portal-wlr/tree/v0.8)
- Contributing and the LLM policy:
  https://github.com/emersion/.github/blob/main/CONTRIBUTING.md#use-of-llms
- The cause dates from #370, "drive the Pipewire graph by ourselves" (merged, in 0.8.3):
  https://github.com/emersion/xdg-desktop-portal-wlr/pull/370
- The duplicate-frame error: #380, a guard closed unmerged by its own author
  (https://github.com/emersion/xdg-desktop-portal-wlr/pull/380), and #340, an open guard the
  maintainer said leaves damage-tracking problems
  (https://github.com/emersion/xdg-desktop-portal-wlr/pull/340).
- The retry timer 0002 fixes came with #397 (merged, in 0.8.4):
  https://github.com/emersion/xdg-desktop-portal-wlr/pull/397
- Related, not the same fix: #400, "Screen sharing stopped working in 0.8.4"
  (https://github.com/emersion/xdg-desktop-portal-wlr/issues/400), and #403, a backport of master's
  wlr-screencopy fixes for a 0.8.5 (https://github.com/emersion/xdg-desktop-portal-wlr/pull/403).
  #403 changes only the wlr-screencopy path; Wayfire 0.11 is captured through
  ext-image-copy-capture, which 0001 fixes. Whether a 0.8.5 with #403 alone works under Wayfire is
  not tested.

## Delivery

- **Gooarchy:** `install/packaging/xdg-desktop-portal-wlr.sh` builds the package from this checkout
  and installs it before Scottland, whose package depends on `xdg-desktop-portal-wlr`; this
  package provides that name, so Scottland's dependency never pulls Arch's broken one. If Arch's
  is already installed, it is replaced in the same pacman transaction and the installer says so.
  `pacman -Syu` keeps Gooarchy's build: Arch's package doesn't declare that it replaces it.
  Running `./install.sh` again rebuilds it. Screen sharing also needs a Scottland with
  `scottland-portals.conf` (Scottland's adapter-fixes work); the Scottland revision pinned in
  `install/sources.conf` predates it until that work is merged and the pin moves.
- **Scottland on Omarchy (the adapter):** not delivered yet. The adapter is built from Scottland's
  repository, and Scottland's package depends on `xdg-desktop-portal-wlr`, which pacman fills with
  Arch's 0.8.4. There is no package repository to serve the patched build from. Until there is a
  delivery decision, an Omarchy user can build this package by hand from a Gooarchy checkout
  (`cd packaging/arch/xdg-desktop-portal-wlr && makepkg -si`), answering yes when pacman asks to
  remove Arch's xdg-desktop-portal-wlr.

## Retiring it

When an upstream xdg-desktop-portal-wlr release contains both fixes (or fixes the same failures
another way, shown by Scottland's `tests/portal-test.py` against that release): remove
`packaging/arch/xdg-desktop-portal-wlr/` and `install/packaging/xdg-desktop-portal-wlr.sh`, and
have the installer replace `xdg-desktop-portal-wlr-gooarchy` with Arch's `xdg-desktop-portal-wlr`
on machines that have it. Record the accepted upstream commits and the release here first.
