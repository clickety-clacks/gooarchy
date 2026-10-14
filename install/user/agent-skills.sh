#!/bin/bash
# Packages are installed before this step. Link their skills for the current user now; the
# packaged Scottland autostart hook repeats the links for later logins and newly added harnesses.
scottland_skill=/usr/share/scottland/agents/skills/scottland/SKILL.md
gooarchy_skill=/usr/share/gooarchy/agents/skills/gooarchy/SKILL.md
[[ -f $scottland_skill && -f $gooarchy_skill ]] || {
  echo "The installed Scottland and Gooarchy packages must both provide their agent skills." >&2
  exit 1
}
mkdir -p "$HOME/.agents"
bash "$GOOARCHY_PATH/session/03-link-gooarchy-agent-skills"
