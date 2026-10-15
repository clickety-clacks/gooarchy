# Gooarchy theme selection

`gooarchy look` uses Gooarchy's installed flavorings catalogue. `gooarchy look list` shows only
themes with both light and dark variants. `gooarchy look current` reports the theme and mode chosen
by the existing flavorings lookup. `gooarchy look set THEME` stores a catalogue slug and asks the
existing flavorings refresh to apply it. `gooarchy look pick` provides the same selection through a
numbered terminal prompt; Enter or `0` cancels without changing the selection.

The supported selection record is `${XDG_CONFIG_HOME:-$HOME/.config}/gooarchy/theme`. It is a
plain-text file whose first line is the selected theme slug. If the file is absent, flavorings uses
its default theme. The command replaces the record atomically before refresh, so a failed refresh is
reported while the selected slug remains available for a later refresh.

Theme variants, mode resolution, and per-application updates remain owned by Gooarchy flavorings
and Scottland. This command does not add another theme resolver or write application-specific
configuration. This source slice implements the catalogue theme rows only; wallpaper and font
selection need their own settled data and apply interfaces before they can be added here.
