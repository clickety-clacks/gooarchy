# Gooarchy: agent guide

Gooarchy (pronounced "goo-ah-shee") is a desktop Linux distribution built around Scottland, a spatial
desktop on Wayfire. In planning; nothing to install yet.

- **This repo is public; Scottland is private.** Don't put Scottland's internals, plans, invariants or
  notes here until Mike says Scottland is public. The distro notes live in Scottland's
  docs/distro-notes.md for now.
- **Layers:** Scottland (the desktop: mechanisms) → gooarchy-flavorings (taste: curated app widgets and
  defaults, also installed on Omarchy through Scottland's adapter) → Gooarchy (the distro: installer,
  packages, update channel, machine lifecycle). Put each change in the layer it belongs to.
- **No silent overrides:** anything that replaces a user's existing setting is reported with its reason.
- **Testing** never on osanwe (Mike's daily machine). The distro's test base is racter.
