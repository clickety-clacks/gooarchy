# Gooarchy look

`gooarchy look` uses Gooarchy's installed flavorings catalogue. `list` shows themes with both light
and dark variants; `current` reports the theme and mode chosen by the flavorings lookup; `set THEME`
stores a catalogue slug and asks flavorings to refresh; `pick` offers the same selection in a
numbered terminal prompt. Enter or `0` cancels without changing the selection.

The theme selection record is `${XDG_CONFIG_HOME:-$HOME/.config}/gooarchy/theme`, a plain-text file
whose first line is the selected slug. If it is absent, flavorings uses its default theme. A failed
refresh leaves the saved selection available for a later refresh and is reported as a failure.

`wallpaper current` reports the resolved variant, its default or saved wallpaper, and the image
acknowledged by the running wallpaper owner when available. `wallpaper list` shows supported images
in that variant. `wallpaper set NAME`, `wallpaper next` and `wallpaper pick` save a selection for the
resolved variant and request application through the existing refresh and wallpaper owner. With no
running owner, the command reports that the saved choice will apply when the owner starts. A missing
saved image falls back to that variant's first supported image.

`font current` reports the saved monospace family, Fontconfig's effective match and Ghostty's
configured/default family separately. `font list` shows installed monospace families also reported
by Ghostty; `font set FAMILY` and `font pick` save a choice for Fontconfig's generic `monospace`
family and Ghostty. Gooarchy stores its Fontconfig fragment under
`${XDG_CONFIG_HOME:-$HOME/.config}/fontconfig/conf.d/` and the derived Ghostty fragment under
`${XDG_CONFIG_HOME:-$HOME/.config}/gooarchy/`. It adds at most one marked optional include to the
user's normal Ghostty configuration and requests Ghostty's supported reload when the running session
can be identified. The tool does not install fonts, change text size or colors, or restart an
application. It reports saved configuration and reload requests separately from what an existing
window visibly renders.

Theme variants and mode resolution remain owned by Gooarchy flavorings. Wallpaper and font
operations delegate to the existing wallpaper and integration helpers; this command adds no second
resolver, wallpaper owner or font service. On Omarchy, reads explain that Omarchy owns appearance
and setters leave the configuration unchanged.
