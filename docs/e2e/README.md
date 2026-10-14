# Gooarchy end-to-end runbooks

Use these runbooks on an isolated installation with the capabilities needed by the behavior being checked. Each runbook has its own setup, actions, expected observations, and cleanup; it can be run without completing another runbook first. Run [the final release pass](final-release.md) to collect all results for a distro candidate. Do not use a person's daily session for automated testing.

Record the distro commit/tag, installed package versions and source tags, compositor version, graphics mode, and evidence location once **per run**. These identify what was tested; a hostname, machine ID, particular UID, or incidental tool availability is not a product result. Save screenshots or short recordings only when they show the asserted behavior. Record each step as `PASS`, `FAIL`, `BLOCKED` (with the actual capability or access reason), or `NOT SHIPPED` (with package/source evidence). A shipped behavior cannot pass as `NOT SHIPPED`. Restore only state changed by that run and leave unrelated sessions alone.

| Runbook | Gooarchy-owned behavior and integration exercised |
| --- | --- |
| [Install, update and session](install-session.md) | repository/package selection, installer rerun, preservation of user choices, login/logout, session cleanup, default apps |
| [Windows and input](windows-input.md) | Scottland center/periphery/rail model, focus, fullscreen, ordinary windows, Xwayland, bindings and output changes |
| [Appearance and defaults](appearance.md) | Flavorings theme application, Scottland/Ghostty/GTK/wallpaper agreement, manual choice and solar transitions, user-default preservation |
| [Desktop integrations](integrations.md) | portals, screenshots/screencast, Strata folder handling, notifications/attention, audio, clipboard and packaged Gooarchy tools |

The runbooks exercise our code and the boundaries with external applications. They do not certify Chromium, Ghostty, Strata, Arch, or graphics drivers as products in their own right. For an integration, assert the Gooarchy/Scottland action and the visible result at the boundary. `tests/vm/run.sh` and the repository's focused checks can provide supporting evidence; they do not replace a runbook step they did not actually exercise.

Before a release, compare the installed feature list with this matrix and [DEFICIT.md](../../DEFICIT.md). Add a runbook assertion when a new custom feature ships. A feature deliberately absent from the candidate belongs in the release result as `NOT SHIPPED`, with its delivery item, rather than as a fabricated pass.
