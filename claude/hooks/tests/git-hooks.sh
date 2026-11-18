#!/usr/bin/env bash
# Tests for the global git hooks (git-hooks/_dispatch): commit, message, push history, chaining to repo hooks,
# read-only and no-commit repos.
GH="${GITHOOKS:-$HOME/.claude/git-hooks}"; GH=$(cd "$GH" && pwd)
HK="$(dirname "$GH")/hooks"
export SECRET_SCAN="${SCAN:-$HK/secret-scan.sh}"
export PERSONAL_SCAN="${PSCAN:-$HK/personal-scan.sh}" SUBMODULE_CHECK="${SUBCHK:-$HK/submodule-check.sh}"
pass=0; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# hermetic git: no user or system config, so the real global hooks never run inside the tests
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
export SECRET_ALLOW="$T/allow.txt"; : > "$SECRET_ALLOW"
j() { printf '%s' "$@"; }; KEY=$(j ghp_ 0123456789abcdefghij 0123456789ABCDEF); NV=$(j --no- verify)
printf 'READONLY_REPOS=("%s")\nNO_COMMIT_REPOS=("%s")\n' "$T/ro" "$T/nc" > "$T/conf"; export HARNESS_CONF="$T/conf"
g() { git -c core.hooksPath="$GH" -c user.email=t@t -c user.name=t "$@"; }
ok() { if [[ $2 == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %-36s expect=%s got=%s\n' "$1" "$3" "$2"; fi; }
git init -q --bare "$T/remote.git"; git clone -q "$T/remote.git" "$T/r" 2>/dev/null; cd "$T/r"
printf '#!/bin/sh\necho ran > "%s/own-pre-commit"\n' "$T" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
printf '#!/bin/sh\necho ran > "%s/own-post-checkout"\n' "$T" > .git/hooks/post-checkout; chmod +x .git/hooks/post-checkout
echo a > a.txt; git add a.txt; g commit -qm "feat: 시작함" >/dev/null 2>&1; ok "clean commit"               $? 0
ok "repo pre-commit still runs"  "$( [ -f "$T/own-pre-commit" ] && echo yes)" yes
g push -q origin HEAD >/dev/null 2>&1;                       ok "clean push"                 $? 0
echo "k=$KEY" > k.txt; git add k.txt; g commit -qm "feat: 키" >/dev/null 2>&1; ok "commit with key blocked" $? 1
git reset -q k.txt; rm k.txt
echo b > b.txt; git add b.txt; g commit -qm "fix: 토큰 $KEY" >/dev/null 2>&1; ok "message with key blocked" $? 1
g commit -qm "fix: 서명

Co-Authored-By: $(j Cla ude) <noreply@$(j anth ropic).com>" >/dev/null 2>&1; ok "message with AI signature blocked" $? 1
g commit -qm "fix: 정상 메시지를 씀" >/dev/null 2>&1;       ok "clean message"              $? 0
echo a >> a.txt; git add a.txt
CLAUDECODE=1 g commit -qm "docs(자료): 회신 보관" >/dev/null 2>&1; ok "claude: bad subject blocked" $? 1
env -u CLAUDECODE git -c user.name=t -c user.email=t@t commit -qm "docs(자료): 회신 보관" >/dev/null 2>&1; ok "human: bad subject warns only" $? 0
echo "k=$KEY" > k2.txt; git add k2.txt; g commit -qm "feat: 우회" $NV >/dev/null 2>&1
git rm -q k2.txt; g commit -qm "fix: 지움" >/dev/null 2>&1
g push -q origin HEAD >/dev/null 2>&1;                       ok "push of key in history blocked" $? 1
g checkout -q -b feature/x >/dev/null 2>&1
ok "repo post-checkout still runs" "$( [ -f "$T/own-post-checkout" ] && echo yes)" yes

# remote commit unknown here (force push without fetching): fall back to every commit the remote lacks
Z=$(j 0123456789abcdef 0123456789abcdef 01234567)
git checkout -q -b clean "$(git rev-list --max-parents=0 HEAD)"; echo c > c.txt; git add c.txt; g commit -qm "feat: c" >/dev/null 2>&1
printf 'refs/heads/clean %s refs/heads/clean %s\n' "$(git rev-parse HEAD)" "$Z" | "$GH/pre-push" origin "$T/remote.git" >/dev/null 2>&1
ok "unknown remote commit, clean push" $? 0
printf 'refs/heads/feature/x %s refs/heads/feature/x %s\n' "$(git rev-parse feature/x)" "$Z" | "$GH/pre-push" origin "$T/remote.git" >/dev/null 2>&1
ok "unknown remote commit, key in history" $? 1

# the submodule check runs even when the secret scanner is missing
printf '#!/bin/sh\nexit 1\n' > "$T/subfail"; chmod +x "$T/subfail"
printf 'refs/heads/clean %s refs/heads/clean %s\n' "$(git rev-parse HEAD)" "$Z" | SECRET_SCAN="$T/none" SUBMODULE_CHECK="$T/subfail" "$GH/pre-push" origin "$T/remote.git" >/dev/null 2>&1
ok "submodule check without scanner" $? 1

# read-only and no-commit repos are refused by git itself, whatever the command looks like
mkrepo() { git init -q "$1"; echo a > "$1/a.txt"; git -C "$1" add a.txt; git -C "$1" -c user.email=t@t -c user.name=t commit -qm init; }
mkrepo "$T/ro"; mkrepo "$T/nc"
echo b >> "$T/ro/a.txt"; git -C "$T/ro" add a.txt
(cd "$T/ro" && g commit -qm "fix: x" >/dev/null 2>&1);             ok "read-only repo commit"             $? 1
(cd "$T/ro" && g commit -qm "fix: x" $NV >/dev/null 2>&1);          ok "read-only repo commit, hooks skipped" $? 1
g -C "$T/ro" commit -qm "fix: x" >/dev/null 2>&1;                   ok "read-only repo commit via -C"      $? 1
git -C "$T/ro" checkout -q -- a.txt 2>/dev/null; git -C "$T/ro" reset -q
(cd /tmp && GIT_DIR="$T/ro/.git" GIT_WORK_TREE="$T/ro" g commit -q --allow-empty -m "fix: x" >/dev/null 2>&1); ok "read-only repo commit via GIT_DIR" $? 1
git -C "$T/ro" checkout -q -b side; echo s > "$T/ro/s.txt"; git -C "$T/ro" add s.txt
git -C "$T/ro" -c core.hooksPath=/dev/null -c user.email=t@t -c user.name=t commit -qm s; git -C "$T/ro" checkout -q -
(cd "$T/ro" && g merge -q --no-ff -m "merge" side >/dev/null 2>&1); ok "read-only repo merge commit"      $? 1
git -C "$T/ro" merge --abort 2>/dev/null
echo r >> "$T/ro/a.txt"; git -C "$T/ro" -c core.hooksPath=/dev/null -c user.email=t@t -c user.name=t commit -qam r
(cd "$T/ro" && g revert --no-edit HEAD >/dev/null 2>&1); ok "read-only repo revert" "$( (( $? )) && echo blocked)" blocked
git -C "$T/ro" revert --abort 2>/dev/null
(cd "$T/ro" && g log -1 >/dev/null 2>&1 && g status >/dev/null 2>&1); ok "read-only repo reading is fine"  $? 0
git -C "$T/nc" worktree add -q "$T/nc-wt" -b wt 2>/dev/null; echo c > "$T/nc-wt/c.txt"; git -C "$T/nc-wt" add c.txt
(cd "$T/nc-wt" && g commit -qm "fix: x" >/dev/null 2>&1);           ok "no-commit repo worktree commit"   $? 1
git init -q --bare "$T/nc-remote.git"; git -C "$T/nc" remote add origin "$T/nc-remote.git"
(cd "$T/nc" && g push -q origin HEAD:refs/heads/x >/dev/null 2>&1); ok "no-commit repo push"              $? 1
echo "통과 $pass / 실패 $fail"; (( fail == 0 ))
