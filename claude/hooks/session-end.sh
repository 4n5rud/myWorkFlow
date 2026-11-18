#!/usr/bin/env bash
# SessionEnd hook (global): run worktree cleanup for the project this session worked in, in the background.
input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input"); [[ -n "$cwd" ]] || exit 0
CONF="${HARNESS_CONF:-$HOME/.claude/harness.conf}"; READONLY_REPOS=(); WORK_DIR="$HOME/Desktop/work"; GUIDES_DIR=""
[[ -f "$CONF" ]] && source "$CONF"
is_readonly() { local r; for r in "${READONLY_REPOS[@]}"; do [[ "$1" == "$r" || "$1" == "$r"/* ]] && return 0; done; return 1; }
WORK="$WORK_DIR"
[[ "$cwd" == "$WORK"/* ]] || exit 0
project="$WORK/$(cut -d/ -f1 <<<"${cwd#$WORK/}")"
[[ -d "$project" ]] && ! is_readonly "$project" || exit 0
nohup "$HOME/.claude/hooks/worktree-gc.sh" --apply "$project" >/dev/null 2>&1 &
exit 0
