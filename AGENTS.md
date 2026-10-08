# Gooarchy: agent guide

Gooarchy (pronounced "goo-ah-shee") is a desktop Linux distribution built around Scottland, a spatial
desktop on Wayfire. In planning; nothing to install yet.

- **Scottland** is at [clickety-clacks/scottland](https://github.com/clickety-clacks/scottland); the
  distro notes live in its docs/distro-notes.md for now.
- **Layers:** Scottland (the desktop: mechanisms) → gooarchy-flavorings (curated app widgets and
  defaults, also installed on Omarchy through Scottland's adapter) → Gooarchy (the distro: installer,
  packages, update channel, machine lifecycle). Put each change in the layer it belongs to.
- **No silent overrides:** anything that replaces a user's existing setting is reported with its reason.
- **Testing** happens only on the designated test machines (see the private environment docs), never on
  anyone's daily machine.

## Branches and releases (Mike, 2026-10-08)

Every agent working in this repository follows this.

- `main` is what the next Gooarchy install gets. It pins Scottland and gooarchy-flavorings by **tag**
  (never a branch or untagged commit), and the kernel and portal versions in their pin files.
- Releases are date tags (`2026.10.1`, `2026.10.2`, ...). The package repository builds from tags.
- When a distro release has to be tested ahead of time against an unreleased Scottland, open a release
  branch named for it (`2026.11`), cut from `main`, that pins Scottland's next release *branch* for
  testing; it is repinned to the Scottland tag before the distro tag is made. Merge `main` into it
  whenever `main` changes.
- Experiments are opt-in flags on `main` (as `install.sh --kernel` is), never long-lived branches.
  Feature branches are short-lived and deleted after merge.
- A PR lands only on a target branch tip it was tested against (merge queue once the Gooarchy PDO sets it
  up; until then, update to the tip and rerun the checks right before merging), after review by the other
  harness.
- Acceptance for distro behavior (install, boot, kernel, drivers, compositor rendering) is on racter, real
  NVIDIA hardware. A disposable VM or headless run on plumbus is a fixture, never distro acceptance.
- Shipping: tag, rehearse that exact tag on racter, then tell Mike the tag and its contents in product
  terms. osanwe is never a test host.

## Privacy of developer networks (Mike, 2026-10-04)

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

