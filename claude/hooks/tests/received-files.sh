#!/usr/bin/env bash
# Tests for received-files.sh (UserPromptSubmit reminder). Checks whether a reminder appears.
H="${RECV:-$HOME/.claude/hooks/received-files.sh}"; pass=0; fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; git -C "$T" init -q; mkdir -p "$T/docs"
r() { jq -n --arg p "$1" --arg c "$T" '{prompt:$p,cwd:$c}' | $H | jq -r '.hookSpecificOutput.additionalContext // empty'; }
t() { out=$(r "$3"); if [[ $2 == remind && -n "$out" ]] || [[ $2 == quiet && -z "$out" ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %-32s expect=%s\n%s\n' "$1" "$2" "$out"; fi; }
t "downloads file"            remind "이거 반영해줘 /Users/someone/Downloads/요청사항_예시.xlsx"
t "drag and drop with space"  remind "/Users/someone/Downloads/참고\ 이미지.png 이 화면처럼"
t "tilde downloads"           remind "~/Downloads/자료_예시.csv 확인"
t "temp folder file"          remind "/var/folders/ab/xyz/T/카톡_대화.txt"
t "chat screenshot paste"     quiet  "[Image: source: /var/folders/97/x/T/orca-paste-1793-abc.png] 이거 뭐야"
t "screen capture"            quiet  "/Users/someone/Desktop/스크린샷 2026-11-06.png"
t "file inside this repo"     quiet  "$T/docs/a.md 고쳐줘"
t "no path"                   quiet  "주간보고 만들어줘"
t "folder that does not exist" quiet "/Users/someone/Downloads/없는폴더"
t "task notification"         quiet  "<task-notification> /private/tmp/claude-501/x/tasks/a.output /Users/someone/Desktop/work/project-a/next-env.d.ts </task-notification>"
t "system notification"       quiet  "[SYSTEM NOTIFICATION - NOT USER INPUT] /Users/someone/Downloads/a.csv"
t "claude scratch file"       quiet  "/private/tmp/claude-501/abc/scratchpad/out.txt 봐줘"
WORK_REPO="$HOME/Desktop/work/some-repo/a.md"
t "file in another work repo" quiet  "$WORK_REPO 참고"
echo "통과 $pass / 실패 $fail"; (( fail == 0 ))
