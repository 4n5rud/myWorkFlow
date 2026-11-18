#!/usr/bin/env bash
# Tests for lib-project.sh, todo-done.sh and the to-do part of session-start.sh (temp vault, temp project list)
HD="${HOOKS_DIR:-$HOME/.claude/hooks}"; HD=$(cd "$HD" && pwd); pass=0; fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# temp HOME: the hooks keep copies under ~/.claude/harness/local-lists/, never touch the real ones
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
mkdir -p "$T/work/alpha/sub" "$T/work/alpha/docs-repo/_할일" "$T/work/beta" "$T/work/gamma" "$T/notes/work/알파" "$T/notes/work/베타" "$T/notes/work/감마"
git -C "$T/work/alpha" init -q
cat > "$T/projects.md" <<P
| 노트 보관함의 프로젝트 이름 | 저장소 폴더 | WBS 위치 | 문서 저장소 |
|---|---|---|---|
| 알파 | \`$T/work/alpha\` | 없음 | \`$T/work/alpha/docs-repo\` |
| 감마 | \`$T/work/gamma\` | 없음 | |
## 제외 프로젝트
- 베타 (\`$T/work/beta\`): 제외
P
printf 'WORK_DIR="%s"\nNOTES_DIR="%s"\nGUIDES_DIR="%s"\n' "$T/work" "$T/notes" "$T/notes/g" > "$T/harness.conf"
export HARNESS_CONF="$T/harness.conf" HARNESS_PROJECTS="$T/projects.md"
printf '# 할 일\n## 세션이 처리할 것\n- [ ] 결제 키 연결\n- [x] 끝난 것\n## 사용자 확인 기다림\n- [ ] 요청서 발송 여부\n' > "$T/work/alpha/docs-repo/_할일/할 일.md"
printf '# 할 일\n- [ ] 노트에만 있는 일\n' > "$T/notes/work/감마/할 일.md"
source "$HD/lib-project.sh"
chk() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %-30s expect=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
has() { if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %-30s missing=[%s]\n%s\n' "$1" "$3" "$2"; fi; }
none() { if [[ -z "$2" ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %-30s expect empty\n%s\n' "$1" "$2"; fi; }
chk "map repo root"        "$(project_name_for "$T/work/alpha")"      "알파"
chk "map sub folder"       "$(project_name_for "$T/work/alpha/sub")"  "알파"
chk "map excluded list"    "$(project_name_for "$T/work/beta")"       "베타"
chk "unknown folder"       "$(project_name_for "$T/elsewhere")"       ""
chk "docs repo column"     "$(project_docs_for "$T/work/alpha/sub")"  "$T/work/alpha/docs-repo"
chk "docs repo default"    "$(project_docs_for "$T/work/gamma")"      "$T/work/gamma"
ss() { jq -n --arg c "$1" '{cwd:$c,source:"startup"}' | "$HD/session-start.sh" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
has  "start: open count"    "$(ss "$T/work/alpha")" "할 일이 2개"
has  "start: no list yet"   "$(ss "$T/work/beta")"  "아직 할 일 목록이 없다"
has  "start: repo path shown" "$(ss "$T/work/alpha")" "_할일/할 일.md"
has  "start: notes fallback" "$(ss "$T/work/gamma")" "할 일이 1개"
td() { jq -n --arg p "$1" --arg c "$2" '{prompt:$p,cwd:$c}' | "$HD/todo-done.sh" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
has  "done: 완료"           "$(td "결제 키 연결 완료" "$T/work/alpha")" "끝낸 일.md"
has  "done: 보냈어"         "$(td "요청서 어제 카톡으로 보냈어" "$T/work/alpha/sub")" "끝낸 일.md"
none "not done: question"  "$(td "이거 어떻게 해야 해?" "$T/work/alpha")"
none "not done: no list"   "$(td "완료" "$T/work/beta")"
none "system notification" "$(td "[SYSTEM NOTIFICATION] 완료" "$T/work/alpha")"
none "not done: 됐어?"      "$(td "결제 키 연결 됐어?" "$T/work/alpha")"
has  "local copy in temp HOME" "$(ls "$HOME/.claude/harness/local-lists/알파/_할일/" 2>/dev/null)" "할 일.md"
# outgoing ledger lives in the docs repo column, also when the session opens in another folder of the project
mkdir -p "$T/work/alpha/docs-repo/_발신함"
printf '| 날짜 | 받는 곳 | 문서 | 상태 |\n|---|---|---|---|\n| 2026-11-09 | 고객 | 요청서 | 초안 |\n' > "$T/work/alpha/docs-repo/_발신함/목록.md"
has  "start: ledger in docs repo" "$(ss "$T/work/alpha/sub")" "발송 확인이 안 된"
# parent repo with submodules: the remote HEAD record (master) is the default branch, so master gives no warning
mkdir -p "$T/work/delta"; git -C "$T/work/delta" init -q; : > "$T/work/delta/.gitmodules"
git -C "$T/work/delta" add .gitmodules; git -C "$T/work/delta" -c user.email=t@t -c user.name=t commit -qm init
git -C "$T/work/delta" branch -qM master
git -C "$T/work/delta" update-ref refs/remotes/origin/main HEAD; git -C "$T/work/delta" update-ref refs/remotes/origin/master HEAD
git -C "$T/work/delta" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
none "start: origin HEAD is master" "$(ss "$T/work/delta" | grep '상위 저장소')"
# worktree-gc with an empty READONLY_REPOS list (bash 3.2, set -u)
printf 'READONLY_REPOS=()\n' > "$T/gc.conf"
out=$(HARNESS_CONF="$T/gc.conf" /bin/bash "$HD/worktree-gc.sh" --no-fetch "$T/work/beta" 2>&1)
has  "worktree-gc empty list"  "$out" "미리보기"
echo "통과 $pass / 실패 $fail"; (( fail == 0 ))
