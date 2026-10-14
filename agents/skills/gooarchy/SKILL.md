---
name: gooarchy
description: Operate, customize, or build Gooarchy, the Arch distribution built around Scottland. Use for Gooarchy installation, packages, session defaults, updates, and source changes; use the separate Scottland skill for compositor settings and widgets.
---

# Gooarchy

Gooarchy is the distribution layer around Scottland. Its package, installer, repository selection,
session startup, and update tooling live in the [Gooarchy source repository](https://github.com/clickety-clacks/gooarchy).
Scottland owns the compositor and its settings; read the installed `scottland` skill before changing
window, input, or widget behavior. The Omarchy adapter is a different product and is not part of a
Gooarchy install.

## Install and update

Read the repository README and `install.sh --help` for the current install command and options.
Run `./install.sh` from a checkout as the desktop user, not root. Rerun it to retry a failed install
or update; inspect `~/.local/state/gooarchy/install.log` and its package manifests after a failure.
An install may already have changed packages before it stopped. The installer records source and
package identity, and a dirty or different checkout can build local packages instead of using the
signed repository copies. Check its report before assuming which source is running.

The repository URL and signing key must be configured before its package route can work. Do not
replace the installer trust checks with an unsigned source or invent a package pin. The current
limitations and missing features are in `DEFICIT.md`; the uninstall and recovery steps are in
`docs/uninstall.md`.

## Customize and build

Use Scottland Settings or `~/.config/scottland/overrides.ini` for compositor preferences; follow
the `scottland` skill. Gooarchy's package and installer source are in `packaging/` and `install/`,
its session files in `session/`, and its Rust system tools in `system-tools/`. A local package build
reads its checkout; `/usr/share/gooarchy/build-info` records the built source revision and whether
it included uncommitted changes. The Rust toolchain is optional for normal package upgrades but
needed to rebuild edited system tools. Verify the behavior affected by a source change before
using the documented package or release route.
