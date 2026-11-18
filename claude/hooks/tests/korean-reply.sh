#!/usr/bin/env bash
# Tests for korean-reply.sh: a mostly English reply is sent back once, Korean replies, short ones and code are left alone.
S="${KREPLY:-$HOME/.claude/hooks/korean-reply.sh}"; pass=0; fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mk() { jq -nc --arg t "$2" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' > "$T/$1.jsonl"; }
t() { # name expect(block|pass) [active]
  local d; d=$(jq -nc --arg p "$T/$1.jsonl" --argjson a "${3:-false}" '{hook_event_name:"Stop",transcript_path:$p,stop_hook_active:$a}' | "$S" | jq -r '.decision // "pass"')
  [[ "${d:-pass}" == "$2" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1 expect=$2 got=$d"; }
}
mk en "Full code review 2 (posts, lectures, board) is done. It found two high-severity security issues, and I have assigned a fix. Two more items change existing behavior, so I need your decision before touching them. Login token can leak to an outside server."
mk ko "코드 리뷰 2차가 끝났습니다. 보안 문제 2건이 나와서 고치도록 맡겼습니다. \`fetchImage\` 함수와 \`lib/data/api_client.dart\` 파일을 고쳤고, 기존 동작이 바뀌는 2건은 결정이 필요합니다."
mk short "Done."
mk code "$(printf '%s\n' '```' 'const total = items.reduce((sum, item) => sum + item.price * item.quantity, 0); return formatCurrency(total, locale, options);' '```' '합계 계산을 고쳤습니다.')"
t en block; t ko pass; t short pass; t code pass; t en pass true
# only this turn counts: the previous reply's language must not decide (2026-11-12 one-behind bug)
um() { jq -nc --arg t "$1" '{type:"user",message:{role:"user",content:$t}}'; }
am() { jq -nc --arg t "$1" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'; }
EN=$(jq -r .message.content[0].text "$T/en.jsonl"); KO=$(jq -r .message.content[0].text "$T/ko.jsonl")
{ um "보고해"; am "$EN"; um "한국어로 말해"; am "$KO"; } > "$T/en_then_ko.jsonl"; t en_then_ko pass
{ um "보고해"; am "$KO"; um "다음"; am "$EN"; } > "$T/ko_then_en.jsonl"; t ko_then_en block
{ um "보고해"; am "$EN"; um "다음"; } > "$T/not_written_yet.jsonl"; t not_written_yet pass
u=$(echo '{"hook_event_name":"UserPromptSubmit","prompt":"x"}' | "$S" | jq -r '.hookSpecificOutput.additionalContext // ""')
[[ "$u" == *한국어* ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL prompt_reminder"; }
echo "통과 $pass / 실패 $fail"; (( fail == 0 ))
