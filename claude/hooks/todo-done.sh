#!/usr/bin/env bash
# UserPromptSubmit hook (claude-work-harness): when the user says something is done ("완료", "처리했어", "보냈어"...),
# remind the model to tick the item in the project's 할 일.md and move it to 끝낸 일.md (지침서 14). Never blocks.
input=$(cat)
prompt=$(jq -r '.prompt // empty' <<<"$input"); cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -n "$prompt" ]] || exit 0
grep -qE '<task-notification>|\[SYSTEM NOTIFICATION|<cross-session-message' <<<"$prompt" && exit 0
# a question ("됐어?") is not a report that something is done
[[ "$(printf '%s' "$prompt" | sed -e 's/[[:space:]]*$//' | tail -c 1)" == '?' ]] && exit 0
PROMPT="$prompt" perl -CSDA -Mutf8 -e 'use Encode qw(decode_utf8); my $p = decode_utf8($ENV{PROMPT});
  exit(($p =~ /(^|[\s,.])(완료(했|함|됐|요|입니다)?|처리(했|함|완료)[가-힣]*|다\s*했[가-힣]*|했어(요)?|됐어(요)?|끝났[가-힣]*|끝냈[가-힣]*|보냈[가-힣]*|발송했[가-힣]*)([\s,.!~?]|$)/) ? 0 : 1)' || exit 0
CONF="${HARNESS_CONF:-$HOME/.claude/harness.conf}"; NOTES_DIR=""
[[ -f "$CONF" ]] && source "$CONF"
source "$(dirname "$0")/lib-project.sh" 2>/dev/null || source "$HOME/.claude/hooks/lib-project.sh" 2>/dev/null
pname=$(project_name_for "$cwd" 2>/dev/null)
[[ -n "$pname" ]] || exit 0
pdocs=$(project_docs_for "$cwd" 2>/dev/null)
todo="$pdocs/_할일/할 일.md"
[[ -f "$todo" ]] || todo="$NOTES_DIR/work/$pname/할 일.md"
[[ -f "$todo" ]] || exit 0
rel="${todo#$pdocs/}"
ctx="사용자가 무엇인가를 끝냈다고 말했다. ${rel} 에서 해당 항목을 찾아 [x]로 체크하고, 그 줄을 같은 폴더 끝낸 일.md 맨 위로 옮긴다. 끝낸 날과 근거(사용자가 한 말을 짧게 인용)를 붙인다(지침서 14). 어느 항목인지 애매하면 짚어서 묻는다. 보낸 문서라면 _발신함/목록.md 상태도 \"발송됨\"으로 바꾼다(지침서 13)."
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
