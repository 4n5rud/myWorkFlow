#!/usr/bin/env bash
# Submodule pointer check on push to the default branch (claude-work-harness). Called by the global pre-push hook.
#   submodule-check.sh <remote> < pre-push stdin
# - In a parent repo pushing to main/master (or the remote's default branch): every submodule pointer in the pushed
#   commit must be a commit that is on that submodule's default branch. A pointer to an unmerged branch commit is
#   blocked (exit 1): the branch can be deleted and then nobody can check the parent out. A pointer that is behind
#   the submodule's default branch only warns.
#   Every path in .gitmodules is checked, inner folders included. From a worktree (empty submodule folders) the
#   submodule copy in the git folder is used. Fetching never asks for a password and gives up after 20 seconds.
# - In a submodule pushing to its default branch: reminds that the parent repo's pointer needs an update (never blocks).
set -u
remote="${1:-origin}"
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
remote_head=$(git symbolic-ref -q --short "refs/remotes/$remote/HEAD" 2>/dev/null); remote_head="${remote_head#"$remote"/}"
is_default() { local b="${1#refs/heads/}"; [[ "$b" == main || "$b" == master || ( -n "$remote_head" && "$b" == "$remote_head" ) ]]; }

# where the submodule's own git data lives: its checkout, or (from a worktree, where the folder is empty)
# the copy kept in this repo's git folder or the shared git folder
gitdir_dir=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null)
common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
# git hands pre-push GIT_DIR in worktrees and submodules; drop it so the questions below about each submodule
# reach that submodule. The current repo is reached through "-C $top" from here on.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
sub_git() { # $1=path $2=name -> prints a --git-dir value or nothing
  local c
  if [[ -e "$top/$1/.git" ]]; then git -C "$top/$1" rev-parse --path-format=absolute --git-dir 2>/dev/null; return; fi
  for c in "$gitdir_dir/modules/$2" "$common_dir/modules/$2"; do
    [[ -n "$2" && -d "$c" ]] && git --git-dir="$c" rev-parse -q --git-dir >/dev/null 2>&1 && { echo "$c"; return; }
  done
}
fetched="|"
fetch_once() { # each submodule is fetched once per push, never waits for a password, gives up after 20 seconds
  [[ "$fetched" == *"|$1|"* ]] && return; fetched+="$1|"
  GIT_TERMINAL_PROMPT=0 perl -e 'alarm 20; exec @ARGV' git --git-dir="$1" fetch -q origin </dev/null 2>/dev/null
}

rc=0; warned_parent=0
while read -r lref lsha rref rsha; do
  [[ -z "${lsha:-}" || "$lsha" =~ ^0+$ ]] && continue
  is_default "$rref" || continue

  # this repo is a submodule of a parent
  parent=$(git -C "$top" rev-parse --show-superproject-working-tree 2>/dev/null)
  if [[ -n "$parent" && $warned_parent == 0 ]]; then
    warned_parent=1
    echo "ℹ️  서브모듈의 ${rref#refs/heads/}에 올립니다. 상위 저장소(${parent##*/})가 이 커밋을 가리키도록 연결(포인터)도 갱신하세요." >&2
  fi

  # this repo has submodules: check every pointer listed in .gitmodules of the pushed commit (inner folders too)
  git -C "$top" cat-file -e "$lsha:.gitmodules" 2>/dev/null || continue
  while read -r key sp; do
    name="${key#submodule.}"; name="${name%.path}"
    mode=""; type=""; sha=""; read -r mode type sha _ < <(git -C "$top" ls-tree "$lsha" -- "$sp")
    [[ "${type:-}" == commit ]] || continue
    sgd=$(sub_git "$sp" "$name")
    if [[ -z "$sgd" ]]; then
      echo "⚠️  서브모듈 $sp 를 받아 두지 않아 연결을 확인하지 못했습니다." >&2; continue
    fi
    fetch_once "$sgd"
    # the submodule's main line: branch set in .gitmodules, then main, master, then the remote HEAD record
    cfg=$(git -C "$top" config --blob "$lsha:.gitmodules" --get "submodule.$name.branch" 2>/dev/null)
    sd=""
    for c in ${cfg:+origin/$cfg} origin/main origin/master $(git --git-dir="$sgd" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); do
      git --git-dir="$sgd" rev-parse -q --verify "$c" >/dev/null && { sd=$c; break; }
    done
    [[ -n "$sd" ]] || continue
    if ! git --git-dir="$sgd" cat-file -e "$sha^{commit}" 2>/dev/null || ! git --git-dir="$sgd" merge-base --is-ancestor "$sha" "$sd" 2>/dev/null; then
      echo "🔴 $sp 연결이 ${sd#origin/}에 없는 커밋(${sha:0:8})을 가리킵니다. 그 브랜치를 먼저 ${sd#origin/}에 합치고 연결을 다시 맞추세요." >&2
      rc=1
    else
      n=$(git --git-dir="$sgd" rev-list --count "$sha..$sd" 2>/dev/null)
      [[ "${n:-0}" -gt 0 ]] && echo "⚠️  $sp 연결이 ${sd#origin/}보다 커밋 ${n}개 뒤처져 있습니다. 의도한 게 아니면 갱신하세요." >&2
    fi
  done < <(git -C "$top" config --blob "$lsha:.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null)
done
exit $rc
