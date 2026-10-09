# Rulings

Product decisions that shape Gooarchy, newest first. Each says what was decided, why, and where it
came from. Mike may overrule any of them.

## The test bed keeps tty1 autologin

2026-10-07, Mike (decision `dr_5a5cc75c`).

The Gooarchy test bed logs in automatically on tty1 with no lock screen, so anyone at its keyboard
gets a desktop. Turning that off would mean a password at the console before tests that need a
session. Mike chose "keep-autologin". The test bed keeps its `--autologin` drop-in
(`gooarchy-autologin.conf`). This covers the test bed only: the installer's defaults don't change,
and autologin stays opt-in through `--autologin`.

## Ghostty reads its theme from Scottland on Gooarchy

2026-10-07, Mike (decision `dr_f74a125b`).

Mike's Ghostty config pulls in Omarchy theme files, so on Gooarchy it would lose the theme. Mike
chose a Gooarchy-aware Ghostty over leaving it as is. In his words: "on the adapter version,
ghostty reads from omarchy. on gooarchy, that needs to read from the scottland equivalent".

## The Rust toolchain is optional in the Gooarchy package

2026-10-07, root Gooarchy product owner (Q3 in the addendum to the spirit judgment on Scottland's
source mechanism, `art_7606edcc`).

The Gooarchy package lists the Rust toolchain as an optional dependency (pacman `optdepends`), not
a hard dependency. When no toolchain is installed, `edit` and a merging `update` stop and say
"install a Rust toolchain". Package upgrades keep working without it.

Why: Mike's words make editing the exception, "so that an agent could make a change if they
absolutely needed to". A rare path does not justify about 500 MB of toolchain on every machine,
and nothing is lost without it.

## Package repository hosting (5A)

On 2026-10-06, Mike ruled `dr_99e159f0` as `A3-gooarchy-com-redirect` for
Gooarchy package repository rev 5. His words were: “gooarchy.com redirects
each file to those same GitHub Releases. Free storage, and the address is
Gooarchy's own, so storage can move later without touching any machine. It
needs a small redirect service picked later.”

The repository files live in GitHub Releases on a `clickety-clacks` repository.
The gooarchy.com address only redirects each requested file to the matching
asset; it does not cache, mirror, or store repository files. The redirect
service and DNS configuration remain a separate setup step.

## Package signing key custody (5B)

On 2026-10-06, Mike ruled `dr_0e3dd8f9` as B2 with 1Password under his
delegation. His words were: “yes do it this way. rule for me”.

1Password holds the private signing key. One build machine fetches it when it
publishes, without an interactive signing step, and the same key can be
recovered onto a replacement machine. No additional custody mechanism is part
of this ruling.
