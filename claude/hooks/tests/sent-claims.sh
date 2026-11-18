#!/usr/bin/env bash
# Tests for sent-claims.sh (warn-only). Checks whether a reminder appears.
H="${SENT:-$HOME/.claude/hooks/sent-claims.sh}"; pass=0; fail=0
w() { jq -n --arg f "$1" --arg c "$2" '{tool_name:"Write",tool_input:{file_path:$f,content:$c}}' | $H | jq -r '.hookSpecificOutput.additionalContext // empty'; }
e() { jq -n --arg f "$1" --arg c "$2" '{tool_name:"Edit",tool_input:{file_path:$f,old_string:"x",new_string:$c}}' | $H | jq -r '.hookSpecificOutput.additionalContext // empty'; }
t() { out=$($1 "$3" "$4"); if [[ $2 == warn && -n "$out" ]] || [[ $2 == quiet && -z "$out" ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %-34s expect=%s\n%s\n' "$5" "$2" "$out"; fi; }
t w warn  /p/docs/인계.md   "- 발주사에 확인 요청서 전달함, 회신 대기"            "sent and waiting"
t e warn  /p/주간목표.md    "- [x] 디자이너에게 아이콘 요청 보냈습니다"           "edit says sent"
t w warn  /p/r.html         "<li>확인 요청 10건 발송 완료</li>"                   "html sent"
t w quiet /p/docs/인계.md   "- 확인 요청서 작성 완료(발송 전)"                    "not sent wording"
t w quiet /p/docs/a.md      "- 발주사 요청서: 발송 보류"                          "on hold"
t w quiet /p/src/app.ts     "// 전달함 flag for queue"                           "code file ignored"
t w quiet /p/docs/a.md      "화면 구성을 정리함"                                  "unrelated text"
# work products are not made in the session's temporary folder (2026-11-13)
SP="/private/tmp/claude-501/-Users-x/abc/scratchpad"
d() { jq -n --arg f "$1" '{tool_name:"Write",tool_input:{file_path:$f,content:"x"}}' | $H | jq -r '.hookSpecificOutput.permissionDecision // empty'; }
dt() { out=$(d "$2"); [[ "${out:-allow}" == "$1" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3 expect=$1 got=$out"; }; }
dt deny  "$SP/설계서.html"           "html in temp folder"
dt deny  "$SP/보고서.pdf"            "pdf in temp folder"
dt allow "$SP/qa-spec.json"          "tool spec in temp folder"
dt allow "/p/_작업/설계서.html"      "html in project _작업"
t w warn  "$SP/정리.md"     "화면 구성을 정리함"                                  "note in temp folder"
echo "통과 $pass / 실패 $fail"; (( fail == 0 ))
