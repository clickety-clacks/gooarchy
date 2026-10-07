# Rulings

Product decisions that shape Gooarchy, newest first. Each says what was decided, why, and where it
came from. Mike may overrule any of them.

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
