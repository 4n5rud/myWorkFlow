#!/usr/bin/env bash
# Tests for personal-scan.sh. Paths are built from pieces so this file itself never holds a personal path.
S="${PSCAN:-$HOME/.claude/hooks/personal-scan.sh}"; pass=0; fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/work" "$T/elsewhere"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"; : > "$GIT_CONFIG_GLOBAL"   # no real global hooks
printf 'WORK_DIR="%s"\nNOTES_DIR="%s"\n' "$T/work" "$T/내 업무기록" > "$T/conf"; export HARNESS_CONF="$T/conf"
USERS="/Us""ers/someone/Desktop/a.md"; NOTE="내 업무""기록"; HM="/ho""me"

t() { # name expect(hit|clean) repo-parent setup
  local d="$2/$1"; mkdir -p "$d"; git -C "$d" init -q
  ( cd "$d" && bash -c "$4" )
  "$S" "$d" >/dev/null; local rc=$?
  if [[ $3 == hit && $rc == 1 ]] || [[ $3 == clean && $rc == 0 ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1 expect=$3 rc=$rc"; fi
}
t abs_path      "$T/work"      hit   "echo 'see $USERS' > n.md; git add n.md"
t notes_name    "$T/work"      hit   "echo '원본은 $NOTE 에 있음' > n.md; git add n.md"
t notes_pointer "$T/work"      hit   "echo '노트 보관함 \`work/프로젝트가/a.md\`' > n.md; git add n.md"
t todo_list     "$T/work"      hit   "mkdir -p _할일; echo '- [ ] a' > '_할일/할 일.md'; git add -f _할일"
t outbox_ledger "$T/work"      hit   "mkdir -p _발신함; echo a > _발신함/목록.md; git add _발신함/목록.md"
t outbox_doc_ok "$T/work"      clean "mkdir -p _발신함/2026-11-09_고객_요청서; echo a > _발신함/2026-11-09_고객_요청서/요청서.md; git add _발신함"
t relative_ok   "$T/work"      clean "echo 'see docs/a.md' > n.md; git add n.md"
t outside_work  "$T/elsewhere" clean "echo 'see $USERS' > n.md; git add n.md"
# home folders: personal ones are blocked, system accounts of containers and CI are not, a code folder named home is not
t home_personal  "$T/work"     hit   "echo 'see $HM/alice/notes.md' > n.md; git add n.md"
t home_backtick  "$T/work"     hit   "echo 'see \`$HM/alice/notes.md\`' > n.md; git add n.md"
t home_squote    "$T/work"     hit   "echo \"path='$HM/alice/x'\" > n.md; git add n.md"
t home_system    "$T/work"     clean "printf 'WORKDIR $HM/node/app\nworking-directory: $HM/runner/work\n' > Dockerfile; git add Dockerfile"
t home_codepath  "$T/work"     clean "mkdir -p lib/features/home; echo 'import lib/features/home/a.dart' > n.md; git add n.md"
# a worktree of a work repo kept outside WORK_DIR is still checked
mkdir -p "$T/work/wtbase"; git -C "$T/work/wtbase" init -q; echo a > "$T/work/wtbase/a"; git -C "$T/work/wtbase" add a
git -C "$T/work/wtbase" -c user.email=t@t -c user.name=t commit -qm init; git -C "$T/work/wtbase" worktree add -q "$T/elsewhere/wt" -b wt 2>/dev/null
( cd "$T/elsewhere/wt" && echo "see $USERS" > n.md && git add n.md ); "$S" "$T/elsewhere/wt" >/dev/null
[[ $? == 1 ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL worktree_outside_work expect=hit"; }
echo "통과 $pass / 실패 $fail"; (( fail == 0 ))
