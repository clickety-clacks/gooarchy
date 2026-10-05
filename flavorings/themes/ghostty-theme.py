#!/usr/bin/env python3
"""Write a Ghostty theme from a theme's colors.toml (the Omarchy/Aether color names).

  ghostty-theme.py colors.toml > theme
"""
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    c = tomllib.load(f)
lines = [
    f"background = {c['background']}",
    f"foreground = {c['foreground']}",
    f"cursor-color = {c['bright_foreground']}",
    f"selection-background = {c['selection']}",
    f"selection-foreground = {c['selection_foreground']}",
]
palette = ["background", "red", "green", "yellow", "blue", "magenta", "cyan", "foreground",
           "muted", "bright_red", "bright_green", "bright_yellow", "bright_blue", "bright_magenta",
           "bright_cyan", "bright_foreground"]
lines += [f"palette = {i}={c[name]}" for i, name in enumerate(palette)]
print("\n".join(lines))
