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
