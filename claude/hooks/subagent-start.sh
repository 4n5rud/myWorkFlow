#!/usr/bin/env bash
# SubagentStart hook (claude-work-harness): subagents do not receive ~/.claude/CLAUDE.md or user skills,
# so hand them the same rules. Single source: CLAUDE.md and the 4n5rud-guides SKILL.md are read as-is.
CONF="${HARNESS_CONF:-$HOME/.claude/harness.conf}"; READONLY_REPOS=(); NO_COMMIT_REPOS=()
[[ -f "$CONF" ]] && source "$CONF"
SKILL="$HOME/.claude/skills/4n5rud-guides/SKILL.md"
ro=""; for r in "${READONLY_REPOS[@]}"; do ro+="- $r 안의 파일은 고치거나 커밋하지 않는다(읽기 전용 저장소). 읽기는 괜찮다.
"; done
for r in "${NO_COMMIT_REPOS[@]}"; do ro+="- $r 에서는 커밋, 푸시, 태그, 머지, PR을 하지 않는다. 파일 수정은 괜찮다.
"; done
ctx="[사용자 전역 지침: 메인 세션과 같은 규칙]
$(cat "$HOME/.claude/CLAUDE.md" 2>/dev/null)

## 업무 지침서
코드 수정, 배포, 문서, 한국어 보고 같은 업무를 하기 전에 길잡이 파일 $SKILL 을 Read로 읽고, 그 표에 따라 지금 작업에 맞는 지침서만 골라 읽는다. 읽은 지침은 보고 첫 줄에 '읽은 지침: …'으로 밝힌다.

## 금지
${ro}- 기능, 수정, 핫픽스 같은 작업 브랜치는 커밋하고 푸시해도 된다. dev, main, prod, staging으로 푸시하거나 머지하지 않는다(검사 결과를 메인 세션에 보고하면 메인이 사용자 승인을 받는다). 커밋 메시지에 AI 서명을 넣지 않는다."
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SubagentStart",additionalContext:$c}}'
