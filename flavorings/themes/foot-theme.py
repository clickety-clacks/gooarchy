#!/usr/bin/env python3
"""Write Gooarchy's foot configuration from a light and a dark theme's colors.toml (the
Omarchy/Aether color names): font, bell, and Watercolor Dream as foot's [colors-light] and
[colors-dark].

  foot-theme.py light/colors.toml dark/colors.toml > foot.ini
"""
import sys
import tomllib

PALETTE = ["background", "red", "green", "yellow", "blue", "magenta", "cyan", "foreground",
           "muted", "bright_red", "bright_green", "bright_yellow", "bright_blue", "bright_magenta",
           "bright_cyan", "bright_foreground"]


def colors(path):
    with open(path, "rb") as f:
        c = tomllib.load(f)
    hexa = lambda name: c[name].lstrip("#").lower()
    lines = [f"foreground={hexa('foreground')}", f"background={hexa('background')}",
             f"selection-foreground={hexa('selection_foreground')}", f"selection-background={hexa('selection')}",
             f"cursor={hexa('background')} {hexa('bright_foreground')}"]
    lines += [f"regular{i}={hexa(name)}" for i, name in enumerate(PALETTE[:8])]
    lines += [f"bright{i}={hexa(name)}" for i, name in enumerate(PALETTE[8:])]
    return "\n".join(lines)


print(f"""# Gooarchy flavorings for foot, included from ~/.config/foot/foot.ini (settings there, after the
# include, win). Generated from the Watercolor Dream themes.

[main]
font=JetBrainsMono Nerd Font Mono:size=11
# Light or dark to start with: kept current by the session (gooarchy-follow-scheme), which also
# switches open windows when the desktop's mode changes.
include=~/.local/state/gooarchy/foot-theme.ini

[bell]
# A bell in a window you're not using asks the compositor for attention (XDG activation), which
# Scottland shows as attention; Ghostty does this by default, foot only when asked.
urgent=yes

[colors-light]
{colors(sys.argv[1])}

[colors-dark]
{colors(sys.argv[2])}""")
