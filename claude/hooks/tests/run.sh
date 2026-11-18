#!/usr/bin/env bash
# Regression tests for guard.sh (claude-work-harness). Self-contained: builds a fake read-only repo,
# a fake personal repo and its own harness.conf in a temp dir, so it runs the same on any machine.
# usage: bash ~/.claude/hooks/tests/run.sh      (prints failures and a summary; exit 1 on failure)

G="${GUARD:-$HOME/.claude/hooks/guard.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/work/ro-docs" "$T/work/personal-tool" "$T/work/other-project"
SH="$T/work/ro-docs"            # stands in for a read-only company repo
FREE="$T/work/personal-tool"    # stands in for a personal repo exempt from branch rules
cat > "$T/harness.conf" <<EOF
WORK_DIR="$T/work"
READONLY_REPOS=("$SH")
FREE_PUSH_REPOS=("$FREE")
NO_COMMIT_REPOS=("$T/work/relay")
MOCK_ALLOW_PATHS_RE='(^|/)src/mocks/'
FREE_BRANCHES_BY_REPO=("$T/work/devfree=dev")
EOF
export HARNESS_CONF="$T/harness.conf"
# hermetic git: no user or system config, so the real global hooks never run inside the tests
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
export SECRET_SCAN="${SECRET_SCAN:-$(dirname "$G")/secret-scan.sh}" PERSONAL_SCAN="${PERSONAL_SCAN:-$(dirname "$G")/personal-scan.sh}"
gitq() { git -c user.email=t@t -c user.name=t "$@" -q; }

# fixtures
mk() { mkdir -p "$T/$1" && git -C "$T/$1" init -q && echo ok > "$T/$1/a.txt" && git -C "$T/$1" add a.txt && gitq -C "$T/$1" commit -m init; }
mk plain
mk secret;   printf 'const api_%s = "%s"\n' key abcd1234efgh5678 > "$T/secret/k.js"; git -C "$T/secret" add k.js
mk mockfile; mkdir -p "$T/mockfile/mock-data"; echo '{}' > "$T/mockfile/mock-data/home.json"; git -C "$T/mockfile" add .
mk mockset;  printf 'USE_MOCK=true\n' > "$T/mockset/app.env"; git -C "$T/mockset" add app.env
mk marker;   printf 'const url = "http://10.0.2.2"; // 로컬 전용\n' > "$T/marker/c.dart"; git -C "$T/marker" add c.dart
mk docword;  printf '이 도구는 로컬 전용으로 쓴다.\n' > "$T/docword/d.md"; git -C "$T/docword" add d.md
mk skword;   printf -- '- [x](ask-before-changing-existing-behavior.md)\n' > "$T/skword/i.md"; git -C "$T/skword" add i.md
ANTK="sk-""ant-api03-""AbCdEfGhIjKlMnOpQrStUvWx"; GHK="ghp_""0123456789abcdefghij""0123456789ABCDEF"
mk realkey;  printf 'KEY=%s\n' "$ANTK" > "$T/realkey/k.env"; git -C "$T/realkey" add k.env
mk abspath;  printf '자료: /Users/someone/Downloads/요청.xlsx\n' > "$T/abspath/n.md"; git -C "$T/abspath" add n.md
mk relpath;  printf '자료: _수신함/2026-11-06_카톡_요청/요청.xlsx\n예시 경로 표기: /Users/<이름>/\n' > "$T/relpath/n.md"; git -C "$T/relpath" add n.md
mk keyfile;  printf '{}' > "$T/keyfile/app-firebase-adminsdk-x.json"; git -C "$T/keyfile" add .
mk envex;    printf 'API_URL=\n' > "$T/envex/.env.example"; git -C "$T/envex" add .env.example
mk relaybase; mv "$T/relaybase" "$T/work/relay"; git -C "$T/work/relay" worktree add -q "$T/relay-wt" -b feature/x 2>/dev/null
mk testmock; mkdir -p "$T/testmock/test/mocks"; echo '{}' > "$T/testmock/test/mocks/a.json"; git -C "$T/testmock" add .
mk allowmock; mkdir -p "$T/allowmock/src/mocks"; echo 'export {}' > "$T/allowmock/src/mocks/handlers.ts"; git -C "$T/allowmock" add .
mk otherpkgmock; mkdir -p "$T/otherpkgmock/pkg/mocks"; echo '{}' > "$T/otherpkgmock/pkg/mocks/a.json"; git -C "$T/otherpkgmock" add .
# a repo with an upstream, and an unpushed commit that contains a mock setting
git init -q --bare "$T/remote.git"; git clone -q "$T/remote.git" "$T/pushmock" 2>/dev/null
echo ok > "$T/pushmock/a.txt"; git -C "$T/pushmock" add a.txt; gitq -C "$T/pushmock" commit -m init; git -C "$T/pushmock" push -q origin HEAD 2>/dev/null
git -C "$T/pushmock" branch -q --set-upstream-to=origin/"$(git -C "$T/pushmock" branch --show-current)" 2>/dev/null
printf 'MOCK_MODE=on\n' > "$T/pushmock/m.env"; git -C "$T/pushmock" add m.env; gitq -C "$T/pushmock" commit -m mock

pass=0; fail=0
run() { # tool json -> decision
  out=$($G <<<"$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null); echo "${out:-pass}"; }
bash_j() { jq -n --arg c "$1" --arg d "${2:-/tmp}" --arg s "${3:-TESTX}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:$s}'; }
file_j() { jq -n --arg t "$1" --arg f "$2" '{tool_name:$t,tool_input:{file_path:$f},cwd:"/tmp"}'; }
t() { # name expected json
  got=$(run "$3")
  if [[ "$got" == "$2" ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %-40s expect=%s got=%s\n' "$1" "$2" "$got"; fi; }

# read-only repo: reading allowed, changes blocked
t "ro repo Read"                 pass "$(file_j Read  "$SH/README.md")"
t "ro repo Edit"                 deny "$(file_j Edit  "$SH/a.md")"
t "ro repo Write"                deny "$(file_j Write "$SH/new.md")"
t "other folder Read"              pass "$(file_j Read  "$T/work/other-project/a.md")"
t "other folder Edit"              pass "$(file_j Edit  "$T/work/other-project/a.md")"
t "ro repo cat"                  pass "$(bash_j "cat $SH/README.md 2>/dev/null")"
t "ro repo redirect"             deny "$(bash_j "echo x > $SH/x.md")"
t "ro repo quoted redirect"      deny "$(bash_j "echo x > \"$SH/a b.md\"")"
t "ro repo rm"                   deny "$(bash_j "rm $SH/a.md")"
t "ro repo cp out"               pass "$(bash_j "cp $SH/a.md ./a.md")"
t "git status inside ro repo"    pass "$(bash_j "git status" "$SH")"
t "git add inside ro repo"       deny "$(bash_j "git add ." "$SH")"
t "ro repo cp into"              deny "$(bash_j "cp ./a.md $SH/")"
t "git -C ro repo commit"        deny "$(bash_j "git -C $SH commit -m x")"
t "file named like the ro repo"    pass "$(bash_j "printf x >> $T/notes/ro-docs-readonly.md")"
t "ls work folder"                 pass "$(bash_j "ls $T/work")"

# commit: no question, but content checks
t "plain commit"                   pass "$(bash_j "git commit -m fix" "$T/plain")"
t "AI attribution commit"          deny "$(bash_j "git commit -m \"fix

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\"" "$T/plain")"
t "staged credential"              deny "$(bash_j "cd $T/secret && git commit -m add")"
t "word ask-before-... not a key"   pass "$(bash_j "git commit -m i" "$T/skword")"
t "real-looking sk-ant key"        deny "$(bash_j "git commit -m k" "$T/realkey")"
t "staged mock-data file"          deny "$(bash_j "git commit -m m" "$T/mockfile")"
t "staged USE_MOCK=true"           deny "$(bash_j "git commit -m m" "$T/mockset")"
t "staged // 로컬 전용 marker"       deny "$(bash_j "git commit -m m" "$T/marker")"
t "doc text mentioning 로컬 전용"    pass "$(bash_j "git commit -m d" "$T/docword")"
t "mock json under test/"          pass "$(bash_j "git commit -m t" "$T/testmock")"
t "allowed src/mocks (conf)"      pass "$(bash_j "git commit -m t" "$T/allowmock")"
t "mocks/ outside allow pattern"   deny "$(bash_j "git commit -m t" "$T/otherpkgmock")"
t "absolute path in added line"   deny "$(bash_j "git commit -m n" "$T/abspath")"
t "relative path and placeholder" pass "$(bash_j "git commit -m n" "$T/relpath")"
t "credential json staged"         deny "$(bash_j "git commit -m k" "$T/keyfile")"
t ".env.example is fine"           pass "$(bash_j "git commit -m e" "$T/envex")"
t "no-commit repo: commit"       deny "$(bash_j "git commit -m x" "$T/work/relay")"
t "no-commit repo: push"         deny "$(bash_j "git push origin feature/x" "$T/work/relay")"
t "no-commit repo: worktree"     deny "$(bash_j "git commit -m x" "$T/relay-wt")"
t "no-commit repo: git -C"       deny "$(bash_j "git -C $T/work/relay tag v1")"
t "no-commit repo: status ok"    pass "$(bash_j "git status" "$T/work/relay")"
t "no-commit repo: add ok"       pass "$(bash_j "git add a.txt" "$T/work/relay")"
t "no-commit repo: edit ok"      pass "$(file_j Edit "$T/work/relay/a.txt")"
t "git -c option before commit"   deny "$(bash_j "git -c user.name=t commit -m k" "$T/realkey")"
t "--no-verify blocked"           deny "$(bash_j "git commit --no-verify -m x" "$T/plain")"
t "commit -n blocked"             deny "$(bash_j "git commit -nm x" "$T/plain")"
t "push -n dry run is fine"       pass "$(bash_j "git push -n origin fix/x" "$T/plain")"
t "change core.hooksPath"         deny "$(bash_j "git config --global core.hooksPath /tmp/x")"
t "read core.hooksPath"           pass "$(bash_j "git config --get core.hooksPath")"
t "edit secret allowlist"         deny "$(file_j Write "$HOME/.claude/harness/secret-allow.txt")"
t "commit message with key"       deny "$(bash_j "git commit -m \"fix: $GHK\"" "$T/plain")"
t "gh pr body with key"           deny "$(bash_j "gh pr create --title x --body \"token $GHK\"" "$T/feat")"
t "git log"                        pass "$(bash_j "git log -3" "$T/plain")"

# branch rule: work branches push freely; dev/main/prod/staging push and merges ask every time
mk feat; git -C "$T/feat" checkout -q -b feature/login
git -C "$T/plain" checkout -q -B main
t "push feature branch (current)"  pass "$(bash_j "git push -u origin feature/login" "$T/feat")"
t "push current feature, no args"  pass "$(bash_j "git push" "$T/feat")"
t "push fix branch"                pass "$(bash_j "git push origin fix/crash" "$T/plain")"
t "push hotfix HEAD:hotfix/x"      pass "$(bash_j "git push origin HEAD:hotfix/x" "$T/feat")"
t "push while on main, no args"    ask  "$(bash_j "git push" "$T/plain")"
t "push origin dev"                ask  "$(bash_j "git push origin dev" "$T/feat")"
t "push HEAD:main from feature"    ask  "$(bash_j "git push origin HEAD:main" "$T/feat")"
t "push origin staging"            ask  "$(bash_j "git push origin staging" "$T/feat")"
t "push origin prod (force)"       ask  "$(bash_j "git push -f origin prod" "$T/feat")"
t "push --all"                     ask  "$(bash_j "git push --all origin" "$T/feat")"
t "commit+push feature"            pass "$(bash_j "git commit -m c && git push" "$T/feat")"
t "gh pr create (allowed)"         pass "$(bash_j "gh pr create --title x --body y" "$T/feat")"
t "merge dev into feature"         pass "$(bash_j "git merge origin/dev" "$T/feat")"
t "merge while on main"            ask  "$(bash_j "git merge feature/login" "$T/plain")"
# one project may merge into and push to dev freely (FREE_BRANCHES_BY_REPO); its main and other projects still ask
mkdir -p "$T/work/devfree"; git -C "$T/work/devfree" init -q; echo a > "$T/work/devfree/a"; git -C "$T/work/devfree" add a
gitq -C "$T/work/devfree" commit -m init; git -C "$T/work/devfree" checkout -q -b dev
git -C "$T/work/devfree" worktree add -q "$T/devfree-wt" dev 2>/dev/null || git -C "$T/work/devfree" worktree add -q --detach "$T/devfree-wt" 2>/dev/null
t "free dev: merge on dev"         pass "$(bash_j "git merge feature/x" "$T/work/devfree")"
t "free dev: push origin dev"      pass "$(bash_j "git push origin dev" "$T/work/devfree")"
t "free dev: push origin main"     ask  "$(bash_j "git push origin main" "$T/work/devfree")"
t "free dev: worktree elsewhere"   pass "$(bash_j "git push origin HEAD:dev" "$T/devfree-wt")"
t "other project: push origin dev" ask  "$(bash_j "git push origin dev" "$T/plain")"
t "gh pr merge"                    ask  "$(bash_j "gh pr merge 12 --squash" "$T/feat")"
t "personal repo push main"        pass "$(bash_j "git push origin main" "$FREE")"
t "push of a commit with mock"     deny "$(bash_j "git push" "$T/pushmock")"
printf 'k=%s\n' "$GHK" > "$T/pushmock/k.txt"; git -C "$T/pushmock" add k.txt; git -C "$T/pushmock" -c user.email=t@t -c user.name=t commit -qm k --no-verify
t "push of history with key"      deny "$(bash_j "git push origin HEAD:feature/k" "$T/pushmock")"
# an unpushed local side branch with a key must not block pushing a different, clean branch
git init -q --bare "$T/remote2.git"; git clone -q "$T/remote2.git" "$T/pushside" 2>/dev/null
git -C "$T/pushside" checkout -q -b feature/clean; echo ok > "$T/pushside/a.txt"; git -C "$T/pushside" add a.txt; gitq -C "$T/pushside" commit -m init
git -C "$T/pushside" push -q -u origin feature/clean 2>/dev/null
git -C "$T/pushside" checkout -q -b backup/old; printf 'k=%s\n' "$GHK" > "$T/pushside/k.txt"; git -C "$T/pushside" add k.txt; git -C "$T/pushside" -c user.email=t@t -c user.name=t commit -qm k --no-verify
git -C "$T/pushside" checkout -q feature/clean; echo more >> "$T/pushside/a.txt"; gitq -C "$T/pushside" commit -am more
t "push clean branch, key on other" pass "$(bash_j "git push" "$T/pushside")"
t "push the branch with the key"    deny "$(bash_j "git push origin backup/old" "$T/pushside")"
t "push --all with key elsewhere"   deny "$(bash_j "git push --all origin" "$T/pushside")"

# builds must not use local mock settings
t "release build"                  pass "$(bash_j "fvm flutter build apk --release --dart-define-from-file=dart_defines/prod.json")"
t "build with local defines"       deny "$(bash_j "flutter build apk --dart-define-from-file=dart_defines/local.json")"
t "build with USE_MOCK=true"       deny "$(bash_j "flutter build ios --dart-define=USE_MOCK=true")"
t "dev run with mock is fine"      pass "$(bash_j "flutter run --dart-define=USE_MOCK=true")"
t "npm build with .env.local"      deny "$(bash_j "cp .env.local .env && npm run build")"

# --- each piece of a command is judged on its own (split at ; && || | and new lines); quoted text is data ---
j() { printf '%s' "$@"; }; NV=$(j --no- verify); HP=$(j core. hooksPath); HM=$(j /ho me)
CH="$HOME/.claude"
# a reading command in front no longer lets a write through
t "read then append allowlist"      deny "$(bash_j "cat /tmp/x >> $CH/harness/secret-allow.txt")"
t "config get then set hooks path"  deny "$(bash_j "git config --get user.name; git config --global $HP /dev/null")"
# protected files: hook scripts, git hooks, settings.json, harness.conf, ~/.gitconfig
t "sed -i on a hook script"         deny "$(bash_j "sed -i '' 's/exit 1/exit 0/' ~/.claude/hooks/secret-scan.sh")"
t "redirect over guard.sh"          deny "$(bash_j "echo 'exit 0' > ~/.claude/hooks/guard.sh")"
t "cp over settings.json"           deny "$(bash_j "cp /tmp/s.json \$HOME/.claude/settings.json")"
t "rm the git hooks folder"         deny "$(bash_j "rm -rf ~/.claude/git-hooks")"
t "tee into ~/.gitconfig"           deny "$(bash_j "echo x | tee -a ~/.gitconfig")"
t "perl -i on harness.conf"         deny "$(bash_j "perl -pi -e 's/a/b/' $CH/harness.conf")"
t "python writes a hook"            deny "$(bash_j "python3 -c \"open('$CH/hooks/guard.sh','w').write('')\"")"
t "mv away a hook"                  deny "$(bash_j "mv $CH/hooks/guard.sh /tmp/g")"
t "git config --global write"       deny "$(bash_j "git config --global user.name x")"
t "local hooks path write"          deny "$(bash_j "git config $HP .githooks" "$T/plain")"
t "Edit a hook script"              deny "$(file_j Edit "$CH/hooks/guard.sh")"
t "Write settings.json"             deny "$(file_j Write "$CH/settings.json")"
t "Edit harness.conf"               deny "$(file_j Edit "$CH/harness.conf")"
t "Write ~/.gitconfig"              deny "$(file_j Write "$HOME/.gitconfig")"
t "read a hook script"              pass "$(bash_j "cat ~/.claude/hooks/guard.sh | head -3")"
t "grep settings.json"              pass "$(bash_j "grep -n hooks ~/.claude/settings.json")"
t "copy the dispatcher out"         pass "$(bash_j "cp ~/.claude/git-hooks/_dispatch /tmp/d")"
t "local git config write is fine"  pass "$(bash_j "git config user.email a@b" "$T/plain")"
# skipping git hooks in other ways
t "hooks path key in lower case"    deny "$(bash_j "git -c core.hookspath=/dev/null commit -m x" "$T/plain")"
t "GIT_CONFIG_GLOBAL on commit"     deny "$(bash_j "GIT_CONFIG_GLOBAL=/dev/null git commit -m x" "$T/plain")"
t "HOME= on commit"                 deny "$(bash_j "HOME=/tmp git commit -m x" "$T/plain")"
t "GIT_CONFIG_COUNT on commit"      deny "$(bash_j "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hookspath GIT_CONFIG_VALUE_0=/dev/null git commit -m x" "$T/plain")"
t "exported config, then push"      deny "$(bash_j "export GIT_CONFIG_GLOBAL=/dev/null; git push origin fix/x" "$T/plain")"
t "env wrapper on push"             deny "$(bash_j "env GIT_CONFIG_GLOBAL=/dev/null git push origin fix/x" "$T/plain")"
t "skip flag given in quotes"       deny "$(bash_j "git commit \"$NV\" -m x" "$T/plain")"
t "skip flag in bash -c"            deny "$(bash_j "bash -c 'git commit $NV -m x'" "$T/plain")"
# words inside quotes and other pieces are not mistaken for skipping
t "-n inside a commit message"      pass "$(bash_j "git commit -m 'fix(cli): -n 옵션을 고침'" "$T/plain")"
t "skip flag named in a message"    pass "$(bash_j "git commit -m \"docs: $NV 금지를 적음\"" "$T/plain")"
t "grep -rn on the next line"       pass "$(bash_j "git commit -m x
grep -rn foo ." "$T/plain")"
t "grep for the skip flag"          pass "$(bash_j "grep -rn -- $NV docs/")"
# every push piece is checked, and a checkout before a merge moves the target
t "push word in message, then main" ask  "$(bash_j "git commit -m 'chore: push 설정 바꿈' && git push origin main" "$T/feat")"
t "push folder name, then main"     ask  "$(bash_j "ls push-tool; git push origin main" "$T/feat")"
t "checkout main, then merge"       ask  "$(bash_j "git checkout main && git merge feature/x" "$T/feat")"
t "switch feature, then merge"      pass "$(bash_j "git switch -c feature/y && git merge origin/dev" "$T/plain")"
t "gh api pull merge"               ask  "$(bash_j "gh api -X PUT repos/o/r/pulls/3/merge" "$T/feat")"
# read-only repo, however the command reaches it
t "ro: subshell cd then commit"     deny "$(bash_j "(cd $SH && git commit -m x)")"
t "ro: cd in a later piece"         deny "$(bash_j "ls; cd $SH && git add a")"
t "ro: relative cd"                 deny "$(bash_j "cd ro-docs && git commit -m x" "$T/work")"
t "ro: revert"                      deny "$(bash_j "git revert HEAD" "$SH")"
t "ro: am"                          deny "$(bash_j "git am x.patch" "$SH")"
t "ro: branch -D"                   deny "$(bash_j "git branch -D x" "$SH")"
t "ro: --git-dir"                   deny "$(bash_j "git --git-dir=$SH/.git commit -m x")"
t "ro: GIT_DIR"                     deny "$(bash_j "GIT_DIR=$SH/.git git commit -m x")"
t "ro: relative redirect"           deny "$(bash_j "echo x > ro-docs/a" "$T/work")"
t "ro: perl -pi"                    deny "$(bash_j "perl -pi -e 's/a/b/' $SH/a")"
t "ro: python write"                deny "$(bash_j "python3 -c \"open('$SH/a','w').write('x')\"")"
t "ro: rsync into"                  deny "$(bash_j "rsync -a ./x/ $SH/")"
t "ro: git branch list is fine"     pass "$(bash_j "git branch -a" "$SH")"
# no-commit repo, same
t "relay: cd in a later piece"      deny "$(bash_j "ls; cd $T/work/relay && git commit -m x")"
t "relay: subshell push"            deny "$(bash_j "(cd $T/work/relay && git push)")"
# commit content checks
mk mockrm; mkdir -p "$T/mockrm/mock-data"; echo '{}' > "$T/mockrm/mock-data/a.json"; git -C "$T/mockrm" add .; gitq -C "$T/mockrm" commit -m m; git -C "$T/mockrm" rm -q mock-data/a.json
t "removing a mock file is fine"    pass "$(bash_j "git commit -m rm" "$T/mockrm")"
mk homesys; printf 'WORKDIR %s/node/app\nworking-directory: %s/runner/work\n' "$HM" "$HM" > "$T/homesys/Dockerfile"; git -C "$T/homesys" add .
t "container home path is fine"     pass "$(bash_j "git commit -m d" "$T/homesys")"
mk homecode; mkdir -p "$T/homecode/lib/features/home"; echo 'import "lib/features/home/a.dart";' > "$T/homecode/a.dart"; git -C "$T/homecode" add .
t "code folder named home is fine"  pass "$(bash_j "git commit -m d" "$T/homecode")"
mk homeuser; printf 'see %s/alice/notes.md\n' "$HM" > "$T/homeuser/n.md"; git -C "$T/homeuser" add .
t "personal home path blocked"      deny "$(bash_j "git commit -m d" "$T/homeuser")"
mk hometick; printf 'see `%s/alice/notes.md`\n' "$HM" > "$T/hometick/n.md"; git -C "$T/hometick" add .
t "home path after backtick"        deny "$(bash_j "git commit -m d" "$T/hometick")"
t "AI signature, other name"        deny "$(bash_j "git commit -m \"fix

Co-Authored-By: AI Assistant <noreply@anthropic.com>\"" "$T/plain")"
printf 'fix\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' > "$T/msg.txt"
t "AI signature in -F file"         deny "$(bash_j "git commit -F $T/msg.txt" "$T/plain")"
# push mock check follows the branch that is sent
git -C "$T/pushside" checkout -q -b feature/mock origin/feature/clean; printf 'USE_MOCK=true\n' > "$T/pushside/m.env"
git -C "$T/pushside" add m.env; gitq -C "$T/pushside" commit -m mock; git -C "$T/pushside" checkout -q feature/clean
t "push a clean branch, mock elsewhere" pass "$(bash_j "git push origin feature/clean" "$T/pushside")"
t "push the branch with the mock"   deny "$(bash_j "git push origin feature/mock" "$T/pushside")"
# no refspec: the upstream branch is the target, even under another local name
git -C "$T/pushside" push -q origin feature/clean:main 2>/dev/null; git -C "$T/pushside" fetch -q origin 2>/dev/null
git -C "$T/pushside" checkout -q -b feature/track --track origin/main 2>/dev/null
t "push to an upstream named main"  ask  "$(bash_j "git push" "$T/pushside")"
git -C "$T/pushside" checkout -q feature/clean
# document tool that commits and pushes with git hooks off: the files it is given are scanned first
mkdir -p "$T/dh/tools"; : > "$T/dh/tools/doc-cli.mjs"; git -C "$T/dh" init -q
printf 'token: %s\n' "$GHK" > "$T/dh/keyed.txt"; echo "그냥 문서" > "$T/dh/plain.txt"
printf '{"executionId":"a1","file":"%s"}\n' "$T/dh/keyed.txt" > "$T/dh/req-key.json"
printf '{"executionId":"a2","file":"%s"}\n' "$T/dh/plain.txt" > "$T/dh/req-ok.json"
t "doc tool with a keyed file"      deny "$(bash_j "node tools/doc-cli.mjs register . req-key.json" "$T/dh")"
t "doc tool with a clean file"      pass "$(bash_j "node tools/doc-cli.mjs register . req-ok.json" "$T/dh")"

echo "통과 $pass / 실패 $fail"
(( fail == 0 ))
