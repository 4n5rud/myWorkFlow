#!/usr/bin/env bash
# Tests for submodule-check.sh: builds a parent repo with one submodule on local bare remotes.
S="${SUBCHK:-$HOME/.claude/hooks/submodule-check.sh}"; pass=0; fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
g() { git -c user.email=t@t -c user.name=t -c protocol.file.allow=always "$@"; }
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null   # no global hooks while building the fixture

g init -q --bare -b main "$T/sub.git"; g init -q --bare -b main "$T/parent.git"
g clone -q "$T/sub.git" "$T/sub" 2>/dev/null
echo a > "$T/sub/a"; g -C "$T/sub" add a; g -C "$T/sub" commit -qm A; g -C "$T/sub" push -q origin HEAD:main
A=$(g -C "$T/sub" rev-parse HEAD)
g -C "$T/sub" checkout -q -b feat; echo b > "$T/sub/b"; g -C "$T/sub" add b; g -C "$T/sub" commit -qm B; g -C "$T/sub" push -q origin feat
B=$(g -C "$T/sub" rev-parse HEAD)
g clone -q "$T/parent.git" "$T/parent" 2>/dev/null
g -C "$T/parent" submodule add -q "$T/sub.git" sub 2>/dev/null; g -C "$T/parent/sub" checkout -q "$A"
g -C "$T/parent" add -A; g -C "$T/parent" commit -qm "pointer A"; P_A=$(g -C "$T/parent" rev-parse HEAD)
g -C "$T/parent/sub" fetch -q origin; g -C "$T/parent/sub" checkout -q "$B"
g -C "$T/parent" add sub; g -C "$T/parent" commit -qm "pointer B"; P_B=$(g -C "$T/parent" rev-parse HEAD)

t() { # name expect(0|1) dir stdin
  ( cd "$3" && printf '%s\n' "$4" | "$S" origin ) 2>"$T/err"; local rc=$?
  if [[ $rc == "$2" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1 expect=$2 rc=$rc"; cat "$T/err"; fi
}
Z=0000000000000000000000000000000000000000
t pointer_on_main      0 "$T/parent" "refs/heads/main $P_A refs/heads/main $Z"
t pointer_unmerged     1 "$T/parent" "refs/heads/main $P_B refs/heads/main $Z"
t feature_branch_free  0 "$T/parent" "refs/heads/x $P_B refs/heads/feature/x $Z"
# submodule main moves ahead: pointer A is behind, warn only
g -C "$T/sub" checkout -q main; echo c > "$T/sub/c"; g -C "$T/sub" add c; g -C "$T/sub" commit -qm C; g -C "$T/sub" push -q origin HEAD:main
t pointer_behind_warns 0 "$T/parent" "refs/heads/main $P_A refs/heads/main $Z"
grep -q '뒤처져' "$T/err" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL behind_message"; }
# inside the submodule checkout of the parent: pushing main reminds about the parent pointer
t submodule_reminds    0 "$T/parent/sub" "refs/heads/main $A refs/heads/main $Z"
grep -q '상위 저장소' "$T/err" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL reminder_message"; }
# a submodule in an inner folder is checked too
g -C "$T/parent" checkout -q "$P_A" 2>/dev/null; g -C "$T/parent" checkout -q -b nest 2>/dev/null
g -C "$T/parent" submodule update -q 2>/dev/null
g -C "$T/parent" submodule add -q "$T/sub.git" libs/inner 2>/dev/null; g -C "$T/parent/libs/inner" checkout -q "$B"
g -C "$T/parent" add -A; g -C "$T/parent" commit -qm "inner pointer B"; P_N=$(g -C "$T/parent" rev-parse HEAD)
t inner_folder_unmerged 1 "$T/parent" "refs/heads/main $P_N refs/heads/main $Z"
# from a worktree the submodule folder is empty: the copy in the shared git folder is used
g -C "$T/parent" worktree add -q "$T/pwt" "$P_B" 2>/dev/null
t worktree_unmerged     1 "$T/pwt" "refs/heads/main $P_B refs/heads/main $Z"
t worktree_on_main      0 "$T/pwt" "refs/heads/main $P_A refs/heads/main $Z"
echo "통과 $pass / 실패 $fail"; (( fail == 0 ))
