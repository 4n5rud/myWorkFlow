#!/usr/bin/env bash
# PostToolUse(Skill) hook: one line per skill use, to see which skills actually get used (⑧)
mkdir -p "$HOME/.claude/logs"
jq -r --arg t "$(date +%Y-%m-%dT%H:%M)" '[$t, (.tool_input.skill // "?"), (.cwd // "?")] | @tsv' >> "$HOME/.claude/logs/skill-usage.tsv"
exit 0
