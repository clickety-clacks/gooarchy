# Gooarchy Ask

Press **Super+Space** to find and open desktop apps, including installed web
apps. Type a name, then select a result with an arrow key or the pointer.
Enter opens the selected result. When no result is selected, Enter sends the
text to the agent.

App search and paste work immediately. To send prompts, open Settings with
**Ctrl+,**, choose Codex or Claude, and sign in to that harness from a terminal.
Ask can use the harness's default model and thinking level or apply the choices
made in Settings. The **Ask** and **YOLO** control switches permission modes
for the current session and saves the choice for future sessions.

Claude requires a separately installed `claude-agent-acp` on PATH. Set
`ASK_CLAUDE_ACP_COMMAND` to a JSON array of arguments if the adapter lives
elsewhere. Codex uses the packaged ACP adapter with the system Codex
executable. `ASK_CODEX_ACP_COMMAND` can select another Codex adapter.

Use **Ctrl+V** to paste text, image bytes or copied local image files. Image
prompts require a harness whose ACP adapter advertises image support.

Gooarchy Ask saves settings in `${XDG_CONFIG_HOME:-$HOME/.config}/gooarchy/ask.json`.
Change the shortcut in Scottland's `overrides.ini` under `[command]` by setting
`binding_gooarchy_ask` to another key combination or to `none`. If another
binding already uses Super+Space, it keeps the shortcut. Run `gooarchy-ask`
to open Ask directly. Omarchy-adapter sessions keep their own shortcut setup.
