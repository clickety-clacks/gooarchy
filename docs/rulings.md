# Product decisions

Decisions that shape Gooarchy, newest first. These entries describe product behavior, design
choices and the limits of the evidence behind them.

## The test environment keeps tty1 autologin

2026-10-07.

The dedicated Gooarchy test environment logs in automatically on tty1 with no lock screen, so
session-dependent checks reach a desktop without a console password. This applies only to that
environment: the installer's defaults do not change, and autologin remains opt-in through
`--autologin` and the `gooarchy-autologin.conf` drop-in.

## Ghostty reads its Gooarchy theme from Scottland

2026-10-07.

The Gooarchy Ghostty configuration reads its theme from Scottland rather than Omarchy's theme
files. This keeps Ghostty aligned with the theme used by the Gooarchy desktop.

## The Rust toolchain is optional in the Gooarchy package

2026-10-07.

The Gooarchy package lists the Rust toolchain as an optional dependency (`optdepends`), not a hard
dependency. When no toolchain is installed, `edit` and a merging `update` stop and say to install a
Rust toolchain. Package upgrades keep working without it.

Why: ordinary upgrades do not need a compiler. Keeping the roughly 500 MB toolchain optional avoids
installing it on every system for an uncommon editing path.

## Package repository hosting

2026-10-06.

The intended Gooarchy package-repository address is `gooarchy.com`. It redirects each requested
file to the matching asset in Gooarchy's GitHub Releases; the domain does not cache, mirror or store
the package files. The redirect service and DNS configuration remain separate setup steps. This
describes the selected design and does not claim that the redirect is live.

## Package signing-key custody

2026-10-06; workflow updated 2026-10-14.

The selected signing-key custody design uses 1Password for the private key. This records the
intended custody model; it does not establish that a production key has been provisioned.

The package builder produces unsigned packages and an unsigned repository database. The primary
signer and uploader are separate from that build operation. If the primary signer is unavailable, a
separately authorized backup signer may be selected explicitly; signing authority does not grant
release-upload permission. Each signer validates the same immutable build manifest and key
fingerprint, then creates detached signatures for every package and the database. A separately
qualified uploader validates the signed transfer and advances `latest` only after its complete
asset set is read back and verified. Normal package building has no signing or release-upload
credential.

## The kernel opt-in leaves the bootloader alone

2026-10-07.

A regenerated GRUB menu lists `linux-gooarchy` first and boots it by default. The
`./install.sh --kernel` opt-in does not edit the bootloader configuration. On GRUB, the installer
reports which `GRUB_TOP_LEVEL` line keeps the stock kernel as the default; the user decides whether
to add it.
