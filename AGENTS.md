# Gooarchy: agent guide

Gooarchy (pronounced "goo-ah-shee") is a desktop Linux distribution built around Scottland, a spatial
desktop on Wayfire. In planning; nothing to install yet.

- **Scottland** is at [clickety-clacks/scottland](https://github.com/clickety-clacks/scottland); the
  distro notes live in its docs/distro-notes.md for now.
- **Layers:** Scottland (the desktop: mechanisms) → gooarchy-flavorings (curated app widgets and
  defaults, also installed on Omarchy through Scottland's adapter) → Gooarchy (the distro: installer,
  packages, update channel, machine lifecycle). Put each change in the layer it belongs to.
- **No silent overrides:** anything that replaces a user's existing setting is reported with its reason.
- **Testing** uses an isolated machine with the capabilities the behavior needs and an authorized
  test window, never anyone's daily-use machine. A hostname is not a product-acceptance condition.
- **End-to-end behavior:** use [the independent runbooks](docs/e2e/README.md) for installed Gooarchy,
  Flavorings and Scottland behavior; collect them with [the final release pass](docs/e2e/final-release.md).
  The attended display-zones and Adapter B checks are release-time prompts for an operator, not gates on
  unrelated source work.

## Branches and releases (2026-10-08)

Every contributor working in this repository follows this.

- `main` is what the next Gooarchy install gets. It pins Scottland and gooarchy-flavorings by **tag**
  (never a branch or untagged commit), and the kernel and portal versions in their pin files.
- Releases are date tags (`2026.10.1`, `2026.10.2`, ...). The package repository builds from tags.
- When a distro release has to be tested ahead of time against an unreleased Scottland, open a release
  branch named for it (`2026.11`), cut from `main`, that pins Scottland's next release *branch* for
  testing; it is repinned to the Scottland tag before the distro tag is made. Merge `main` into it
  whenever `main` changes.
- Experiments are opt-in flags on `main` (as `install.sh --kernel` is), never long-lived branches.
  Feature branches are short-lived and deleted after merge.
- A PR lands only on a target branch tip it was tested against, after independent review. Once the
  repository's merge queue is enabled, use it; until then, update to the target tip and rerun the
  required checks immediately before merging.
- Acceptance for distro behavior (install, boot, kernel, drivers, compositor rendering) requires
  the relevant real hardware or session capabilities; a disposable VM or headless run establishes
  only the behavior it actually exercises.
- Shipping: tag, rehearse that exact tag on capable isolated hardware, then report the tag and its
  contents in product terms.

## Privacy of developer networks (2026-10-04)

- Never reveal the internal topology or identifiers of any developer's network in this repository: no
  host names, IP addresses, tailnet or domain names, user names, device names, paths under a developer's
  home, or network diagrams. That covers code, docs, comments, commit messages, test fixtures and logs.
  Use neutral placeholders ("the test machine", `example-host`).
- If any component needs to reach a machine (a hub, a build host, a mirror, a remote agent), the address is
  a configurable field that is set at install time, never a constant in the code and never a default that
  points at a real developer machine.

## Starting clean

Gooarchy is patterned after Omarchy but built clean on plain Arch. Nothing is borrowed to fill a gap: if
Gooarchy has no bar yet, it has no bar. What is missing is listed in DEFICIT.md, from the built system.

