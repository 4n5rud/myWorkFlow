#!/usr/bin/env bash
# Subagent cap (claude-work-harness, 2026-11-12 사용자 지시: 메모리 부담이 커서 세션마다 서브에이전트는 한 번에 4명까지).
# One script for three hook events:
#  - SubagentStart: note that a subagent of this session is running
#  - SubagentStop:  remove the note
#  - PreToolUse on Agent/Task: refuse a new subagent while the cap is reached, so the session hands out work in turns
# The cap is SUBAGENT_LIMIT in harness.conf (default 4). A note counts only while its worker shows activity (see below),
# so a lost stop event never blocks the session; notes older than 3 hours are removed regardless.
input=$(cat)
ev=$(jq -r '.hook_event_name // empty' <<<"$input")
sid=$(jq -r '.session_id // empty' <<<"$input"); [[ -n "$sid" ]] || exit 0
aid=$(jq -r '.agent_id // empty' <<<"$input")
CONF="${HARNESS_CONF:-$HOME/.claude/harness.conf}"; SUBAGENT_LIMIT=4; SUBAGENT_LIMIT_BY_DIR=()
[[ -f "$CONF" ]] && source "$CONF" 2>/dev/null
# per-project cap: SUBAGENT_LIMIT_BY_DIR=("<project folder>=<number>"), matched on the session folder or, for a
# worktree kept elsewhere, on the repo its shared git folder belongs to
cwd=$(jq -r '.cwd // empty' <<<"$input")
if [[ -n "$cwd" ]]; then
  main=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); main="${main%/.git}"
  for e in ${SUBAGENT_LIMIT_BY_DIR[@]+"${SUBAGENT_LIMIT_BY_DIR[@]}"}; do
    dir="${e%=*}"; num="${e##*=}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    if [[ "$cwd" == "$dir" || "$cwd" == "$dir"/* || ( -n "$main" && ( "$main" == "$dir" || "$main" == "$dir"/* ) ) ]]; then SUBAGENT_LIMIT=$num; break; fi
  done
fi
D="${SUBAGENT_STATE_DIR:-$HOME/.claude/harness/agents}/${sid//[^A-Za-z0-9_-]/_}"
mkdir -p "$D" 2>/dev/null
find "$D" -type f -mmin +180 -delete 2>/dev/null

case "$ev" in
  SubagentStart) [[ -n "$aid" ]] && : > "$D/${aid//[^A-Za-z0-9_-]/_}" ;;
  SubagentStop)  [[ -n "$aid" ]] && rm -f "$D/${aid//[^A-Za-z0-9_-]/_}" ;;
  PreToolUse)
    # count only workers that are really working: noted in the last 10 minutes, or their own transcript was written in
    # the last 15 minutes. A worker stopped by a usage limit or an error never sends a stop event; its transcript goes
    # quiet, so it stops counting on its own (2026-11-12, two such workers held two seats for an hour).
    n=0
    while IFS= read -r m; do
      a="${m##*/}"
      if [[ -n "$(find "$m" -mmin -10 2>/dev/null)" ]]; then n=$((n+1)); continue; fi
      tr=$(ls "${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"/*/"$sid"/subagents/agent-"$a".jsonl 2>/dev/null | head -1)
      if [[ -n "$tr" && -n "$(find "$tr" -mmin -15 2>/dev/null)" ]]; then n=$((n+1)); else rm -f "$m"; fi
    done < <(find "$D" -type f 2>/dev/null)
    if (( n >= SUBAGENT_LIMIT )); then
      jq -n --arg r "지금 서브에이전트 ${n}명이 일하고 있어서 새로 띄우지 않았습니다(한 번에 ${SUBAGENT_LIMIT}명까지, 메모리 부담 때문). 일을 줄이지 말고 순서를 정해 두었다가, 하나가 끝났다는 알림이 오면 다음 일을 맡기세요. 그동안 메인 세션은 끝난 결과를 검수하거나 다음 배정을 준비합니다." \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    fi ;;
esac
exit 0
