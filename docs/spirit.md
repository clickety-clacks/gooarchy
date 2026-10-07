# What Gooarchy is for

This is the product's spirit: the problem it answers, what it should achieve, what it isn't, and
the stances that decide close calls. It covers the whole product: Scottland, the Gooarchy distro,
gooarchy-flavorings and Scottland's Omarchy adapter. Where a part's own docs say more, they win for
that part. Scottland's [tenets](https://github.com/clickety-clacks/scottland/blob/main/docs/tenets.md)
say what the desktop itself is for, and this document doesn't repeat them.

## The problem

Desktops manage windows. Mike wants one that manages attention. Scottland and Gooarchy are, in his
words, "really what scottland and goomarchy are all about, attention, from the visual center to the
periphery, to items not even on the desktop trying to get invited onto it."

He describes it as attention regimes. The center of the screen holds what is foremost in your mind.
The periphery and widgets hold what matters less right now. Everything not on the desktop is in "the
ether": a website you closed is still out there, and anything in the ether can ask for your
attention and be promoted to a higher regime. The desktop is a small window you use to pull in the
things that have your attention.

The idea is Scott Jenson's spatial "working memory" concept, and Scott gave Mike the go-ahead to
build it. Scottland is that desktop, built on Wayfire, with no workspaces.

A desktop alone doesn't reach people. Gooarchy is the distribution built around it, so someone can
install a whole system where Scottland is the desktop. People who already run Omarchy should be able
to try Scottland without giving up their setup.

## Outcomes

1. **Scottland is Mike's daily desktop.** Work that is ready reaches his machine often, rather than
   waiting on edge cases that can come later.
2. **Scottland works for everyone, on more than one distro.** "our distro will need to install it so
   it needs to work for everyone." Scottland's core knows nothing about Omarchy. People should be
   able to install it natively on top of another distro, such as Ubuntu.
3. **Omarchy users can install Scottland and keep their environment.** The adapter leaves their
   setup intact except where Scottland replaces it: window position and scaling, and workspaces.
   On the adapter, Omarchy is still involved. Switching between the two desktops closes all
   windows, and the switcher warns about that.
4. **Gooarchy is its own distro, where Scottland stands alone.** It is patterned after Omarchy but
   starts clean on plain Arch. Nothing is borrowed to fill a gap: with no bar yet, it has no bar.
   What's missing is written down in [DEFICIT.md](../DEFICIT.md) from using the built system, so
   the deficit is clearly defined. Gooarchy will have its own bar and notifications.
5. **Gooarchy has its own taste.** gooarchy-flavorings decides which app widgets and app defaults
   ship, "i.e., i want to use MY ghostty widget vs. someone else's so it's my taste", and the
   Watercolor Dream themes in light and dark. Flavorings install on both Gooarchy and Omarchy.
   Omarchy defines no widgets, so on Omarchy flavorings mostly add to what is there. They override
   an Omarchy setting only where that gives a better core Gooarchy experience.
6. **System tools are Gooarchy's own, readable and tracked.** Omarchy's scripts are a source for
   what Gooarchy might be missing; Gooarchy writes its own, and takes one as is only where that
   simply works. Its system tools are Rust, one binary per subsystem. Their sources ship with them
   and are tracked in git from the base, so any change shows against what was installed and is
   easy to roll back. Changing one is possible but takes some ceremony; it isn't casual script
   editing.

## Non-goals

- **Copying Omarchy.** Omarchy is the pattern and a list of things users might miss, not something
  to reproduce feature by feature. DEFICIT.md lists what users lack; it isn't a promise to copy.
- **Filling gaps with borrowed parts.** A missing piece stays missing, and listed, until Gooarchy
  has its own.
- **Anything Mike didn't ask for.** Features "that do not fit within the spirit of the feature" are
  dangerous to the product, however reasonable they look. Build what was asked.

## Quality stances

- **Mike's words are the spec.** A ruling he made outranks an inference about what he would want.
  Rulings are recorded in Scottland's [docs/rulings.md](https://github.com/clickety-clacks/scottland/blob/main/docs/rulings.md).
- **No silent overrides.** Anything that replaces a user's existing setting is reported with its
  reason.
- **Each change goes in its layer.** Scottland defines mechanisms; flavorings curate what ships;
  Gooarchy installs and keeps the machine.
- **Never test on a daily machine.** Testing happens on the designated test machines, never on the
  machine someone works on.
- **Changes are visible and reversible.** What changed against the base can be seen and undone.

## Sources

Mike's words from building Scottland and Gooarchy, including his rulings in Scottland's
docs/rulings.md and docs/distro-notes.md. Quotes are his, with spelling kept.
