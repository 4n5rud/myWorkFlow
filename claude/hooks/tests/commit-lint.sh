#!/usr/bin/env bash
# Tests for ~/.claude/hooks/commit-lint.sh  (warn-only: checks whether a warning appears)
L="${LINT:-$HOME/.claude/hooks/commit-lint.sh}"; pass=0; fail=0
export COMMIT_MSG_CHECK="${COMMIT_MSG_CHECK:-$(cd "$(dirname "$0")/.." && pwd)/commit-msg-check.sh}"
cd "$(mktemp -d)" && git init -q .   # 기록 없는 빈 저장소: 범위 목록 검사 없음
w() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | $L | jq -r '.hookSpecificOutput.additionalContext // empty'; }
t() { # name expect(warn|ok) command [must-contain]
  out=$(w "$3")
  if [[ $2 == ok && -z "$out" ]] || [[ $2 == warn && -n "$out" && "$out" == *"${4:-}"* ]]; then pass=$((pass+1))
  else fail=$((fail+1)); printf 'FAIL %-34s expect=%s\n%s\n' "$1" "$2" "$out"; fi; }
t "good conventional"        ok   'git commit -m "fix(app): 마감일이 지나면 예상 금액 범위를 숨김"'
t "good with refs footer"    ok   'git commit -m "feat(api): 신청 때 예상 금액 범위를 저장함

refs #132"'
t "good team prefix"         ok   'git commit -m "[REFACTOR]: 모르는 시간대가 들어오면 경고 로그를 남김"'
t "good heredoc"             ok   "git commit -m \"\$(cat <<'EOF'
chore(submodule): 설문 문항을 반영한 app 커밋을 가리킴
EOF
)\""
t "not 음슴체"               warn 'git commit -m "fix(app): 예상 금액 범위를 숨긴다"' "음슴체"
t "issue number in subject"  warn 'git commit -m "fix(app): 예상 금액 표기를 고침(#132)"' "refs"
t "middle dot"               warn 'git commit -m "fix(app): 범위 숨김·막대 숨김"' "가운뎃점"
t "no prefix"                warn 'git commit -m "예상 금액 범위를 숨김"' "접두사"
t "too long"                 warn 'git commit -m "fix(app): 마감일이 지난 항목의 상세 화면과 목록 화면 양쪽에서 예상 금액 범위와 막대를 모두 숨기도록 바꿈"' "김"
t "comma list"               warn 'git commit -m "fix(app): 범위를 숨김, 막대를 숨김, 문구를 고침"' "한 가지"
t "merge commit skipped"     ok   'git commit -m "Merge branch dev into feature/x"'
t "not a commit"             ok   'git log -3'
t "korean scope"             warn 'git commit -m "docs(자료): 회신을 보관함"' "영어 소문자"
t "upper scope"              warn 'git commit -m "fix(Install): 설치 순서를 고침"' "영어 소문자"
t "unknown type"             warn 'git commit -m "트래킹: 배지를 비교함"' "종류"
t "vague subject"            warn 'git commit -m "fix(app): 리뷰 수정함"' "어떻게"
t "english subject"          warn 'git commit -m "fix(app): hide price range"' "한국어"
# WBS 번호가 필요한 프로젝트(번호 목록 파일이 있을 때)
WF=$(mktemp); printf '# 시험\n1.1.1\n1.2\nT0.1\n' > "$WF"; export COMMIT_WBS_FILE="$WF"
t "wbs ok"                   ok   'git commit -m "feat(app): 참여 기록을 남김 [WBS : 1.1.1]" -m "WBS-Progress: 1.1.1 60%"'
t "wbs two ids"              ok   'git commit -m "docs: 설계서에 회신을 반영함 [WBS: 1.2, T0.1]" -m "WBS-Progress: 1.2 100%
WBS-Progress: T0.1 30%"'
t "wbs progress missing"     warn 'git commit -m "feat(app): 참여 기록을 남김 [WBS : 1.1.1]"' "진행도 꼬리"
t "wbs progress one missing" warn 'git commit -m "docs: 설계서에 회신을 반영함 [WBS : 1.2, T0.1]" -m "WBS-Progress: 1.2 100%"' "T0.1"
t "wbs progress bad"         warn 'git commit -m "feat(app): 참여 기록을 남김 [WBS : 1.1.1]" -m "WBS-Progress: 1.1.1 절반"' "모양"
t "wbs progress over 100"    warn 'git commit -m "feat(app): 참여 기록을 남김 [WBS : 1.1.1]" -m "WBS-Progress: 1.1.1 150%"' "모양"
t "wbs progress extra id"    warn 'git commit -m "feat(app): 참여 기록을 남김 [WBS : 1.1.1]" -m "WBS-Progress: 1.1.1 50%
WBS-Progress: 1.2 10%"' "제목에 없음"
t "wbs missing"              warn 'git commit -m "docs: 설계서에 회신을 반영함"' "WBS 작업"
t "wbs unknown id"           warn 'git commit -m "docs: 설계서에 회신을 반영함 [WBS : 9.9]"' "없는 번호"
t "wbs bad shape"            warn 'git commit -m "docs: 설계서에 회신을 반영함 [WBS-1.2]"' "모양"
t "wbs merge needs id"       warn 'git commit -m "merge: feat/record (참여 기록 화면)"' "WBS 작업"
unset COMMIT_WBS_FILE; rm -f "$WF"
echo "통과 $pass / 실패 $fail"; (( fail == 0 ))
