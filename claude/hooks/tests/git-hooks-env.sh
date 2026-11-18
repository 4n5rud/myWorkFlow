#!/usr/bin/env bash
# Real git runs through the global hooks: git hands hooks GIT_DIR inside worktrees and submodules, and that must not
# make an ordinary repo look like a read-only or no-commit repo (2026-11-09: every submodule commit was refused).
H="${HOOKS_SRC:-$HOME/.claude}"; pass=0; fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf '[core]\n\thooksPath = %s\n[user]\n\temail = t@t\n\tname = t\n[protocol "file"]\n\tallow = always\n[init]\n\tdefaultBranch = main\n' "$H/git-hooks" > "$T/gitconfig"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"
export SECRET_SCAN="$H/hooks/secret-scan.sh" PERSONAL_SCAN="$H/hooks/personal-scan.sh" SUBMODULE_CHECK="$H/hooks/submodule-check.sh"
mkdir -p "$T/work"
git init -q "$T/work/readonly"; git init -q "$T/work/relay"
printf 'WORK_DIR="%s"\nREADONLY_REPOS=("%s")\nNO_COMMIT_REPOS=("%s")\n' "$T/work" "$T/work/readonly" "$T/work/relay" > "$T/conf"

ok() { if [[ $2 == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1 expect=$3 rc=$2"; cat "$T/err" 2>/dev/null; fi; }
commit() { ( cd "$1" && echo "$RANDOM" >> f && git add f && git commit -qm "docs: 시험 줄을 더함" ) 2>"$T/err"; echo $?; }

# an ordinary repo with a submodule and a worktree
export HARNESS_CONF=/dev/null
git init -q --bare "$T/sub.git"; git clone -q "$T/sub.git" "$T/subsrc" 2>/dev/null
( cd "$T/subsrc" && echo a > a && git add a && git commit -qm "docs: 첫 파일을 추가함" && git push -q origin HEAD:main ) 2>/dev/null
git init -q "$T/work/app"; ( cd "$T/work/app" && echo a > a && git add a && git commit -qm "docs: 첫 파일을 추가함" ) 2>/dev/null
( cd "$T/work/app" && git submodule add -q "$T/sub.git" sub && git commit -qm "chore: 서브모듈을 추가함" ) 2>/dev/null
git -C "$T/work/app" worktree add -q "$T/work/app-wt" -b wt 2>/dev/null
export HARNESS_CONF="$T/conf"   # rules on only after the fixture is built (its submodule address is a temp path)

ok plain_repo_commit      "$(commit "$T/work/app")"      0
ok submodule_commit       "$(commit "$T/work/app/sub")"  0
ok worktree_commit        "$(commit "$T/work/app-wt")"   0
ok readonly_still_blocked "$(commit "$T/work/readonly")" 1
ok relay_still_blocked    "$(commit "$T/work/relay")"    1
echo "통과 $pass / 실패 $fail"; (( fail == 0 ))
