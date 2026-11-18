#!/usr/bin/env bash
# Remove linked git worktrees that are provably finished (10 자동 장치 §3).
#
# usage: worktree-gc.sh [--apply] [--no-fetch] <project-root>...
#   default is dry-run (report only). --apply actually runs `git worktree remove`.
#
# A worktree is removed only when ALL of these hold:
#   1. it is a linked worktree (.git file pointing into .../worktrees/), not a main checkout or submodule
#   2. its folder name is not a permanent one (dev, stg, prod, main, master, rel-*)
#   3. HEAD is not detached-without-branch AND the commit exists on a remote branch
#   4. HEAD is already merged into origin/dev, origin/main or origin/master
#      (ancestor, or every commit has a patch-equivalent there)
#   5. no modified, staged or untracked files
#   6. ignored files are only regenerable build/dependency output or key files copied from dev
#   7. no running process has its working directory inside it
#   8. untouched for at least GRACE_MIN minutes
# Anything else is reported as "kept" with the reason. Nothing is ever force-removed.

set -u
APPLY=0; FETCH=1; ROOTS=()
for a in "$@"; do
  case "$a" in --apply) APPLY=1 ;; --no-fetch) FETCH=0 ;; *) ROOTS+=("$a") ;; esac
done
GRACE_MIN=${GRACE_MIN:-60}
LOG="$HOME/.claude/logs/worktree-gc.log"; mkdir -p "$(dirname "$LOG")"
CONF="${HARNESS_CONF:-$HOME/.claude/harness.conf}"; READONLY_REPOS=()
[[ -f "$CONF" ]] && source "$CONF"
is_readonly() { local r; for r in ${READONLY_REPOS[@]+"${READONLY_REPOS[@]}"}; do [[ "$1" == "$r" || "$1" == "$r"/* ]] && return 0; done; return 1; }

PERMANENT_RE='^(dev|stg|prod|main|master|rel-.*)$'
# ignored paths that tools rebuild, so they are safe to lose
SAFE_IGNORED_RE='(^|/)(node_modules|build|dist|\.next|\.turbo|\.dart_tool|\.gradle|Pods|\.omc|coverage|\.idea|\.cxx|DerivedData|\.expo|\.cache|\.pub-cache|\.flutter-plugins[^/]*|\.packages|.*\.iml|Generated\.xcconfig|flutter_export_environment\.sh|GeneratedPluginRegistrant\.[a-z]+|ephemeral|generated|__pycache__|\.pytest_cache|next-env\.d\.ts|.*\.tsbuildinfo|\.DS_Store)(/|$)|^android/app/src/main/java/$'
# ignored paths that are copied in from the sibling dev worktree (keys, env). Safe only if identical to dev's copy.
COPIED_RE='(^|/)(\.env(\.[^/]+)?|local\.properties|key\.properties|keystore/?|dart_defines/?|Local\.xcconfig)$'

# echo the ignored paths that would be lost for real (not rebuilt, not identical to dev)
unsafe_ignored() { # $1=worktree
  local wt=$1 dev rel
  dev="$(dirname "$wt")/dev"
  git -C "$wt" status --porcelain --ignored 2>/dev/null | sed -n 's/^!! //p' | grep -vE "$SAFE_IGNORED_RE" |
  while IFS= read -r rel; do
    if [[ "$rel" =~ $COPIED_RE && -e "$dev/${rel%/}" ]] && diff -rq "$wt/${rel%/}" "$dev/${rel%/}" >/dev/null 2>&1; then
      continue
    fi
    echo "$rel"
  done
}

ts() { date '+%Y-%m-%d %H:%M'; }
busy_cwds=$(lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')

removed=0; kept=0
report() { # status path reason
  printf '%-8s %s  (%s)\n' "$1" "$2" "$3"
  [[ $APPLY == 1 ]] && printf '%s %-8s %s  (%s)\n' "$(ts)" "$1" "$2" "$3" >> "$LOG"
}

for root in ${ROOTS[@]+"${ROOTS[@]}"}; do
  is_readonly "$root" && continue
  [[ -d "$root" ]] || continue
  fetched=""
  while IFS= read -r gitfile; do
    wt=${gitfile%/.git}
    is_readonly "$wt" && continue
    grep -q '/worktrees/' "$gitfile" 2>/dev/null || continue            # 1
    name=$(basename "$wt")
    if [[ "$name" =~ $PERMANENT_RE ]]; then continue; fi                 # 2 (silently skip permanent)

    common=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) || { report kept "$wt" "git 저장소로 읽히지 않음"; kept=$((kept+1)); continue; }
    if [[ $FETCH == 1 && "$fetched" != *"|$common|"* ]]; then
      GIT_TERMINAL_PROMPT=0 perl -e 'alarm 30; exec @ARGV' git -C "$wt" fetch -q --prune origin 2>/dev/null
      fetched+="|$common|"
    fi

    branch=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)
    if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then                       # 5
      report kept "$wt" "수정 중이거나 커밋 안 한 파일이 있음"; kept=$((kept+1)); continue
    fi
    if [[ -z "$(git -C "$wt" branch -r --contains HEAD 2>/dev/null)" ]]; then                # 3
      report kept "$wt" "커밋이 원격에 없음(푸시 안 됨)"; kept=$((kept+1)); continue
    fi
    merged_into=""
    for base in origin/dev origin/main origin/master; do                                      # 4
      git -C "$wt" rev-parse -q --verify "$base" >/dev/null || continue
      if git -C "$wt" merge-base --is-ancestor HEAD "$base" 2>/dev/null \
         || ! git -C "$wt" cherry "$base" HEAD 2>/dev/null | grep -q '^+'; then
        merged_into=$base; break
      fi
    done
    if [[ -z "$merged_into" ]]; then
      report kept "$wt" "아직 dev, main에 합쳐지지 않음${branch:+ (브랜치 $branch)}"; kept=$((kept+1)); continue
    fi
    bad_ignored=$(unsafe_ignored "$wt" | head -3)
    if [[ -n "$bad_ignored" ]]; then                                                          # 6
      report kept "$wt" "합쳐졌지만 git 밖 파일이 있음: $(tr '\n' ' ' <<<"$bad_ignored")"; kept=$((kept+1)); continue
    fi
    if grep -qxF -e "$wt" <<<"$busy_cwds" || grep -q "^$wt/" <<<"$busy_cwds"; then          # 7
      report kept "$wt" "합쳐졌지만 지금 이 폴더에서 돌고 있는 프로그램이 있음"; kept=$((kept+1)); continue
    fi
    if [[ -n "$(find "$wt" -maxdepth 3 -not -path '*/node_modules/*' -not -path '*/.git' -newermt "-${GRACE_MIN} minutes" -print -quit 2>/dev/null)" ]]; then  # 8
      report kept "$wt" "합쳐졌지만 ${GRACE_MIN}분 안에 고친 흔적이 있음"; kept=$((kept+1)); continue
    fi

    size=$(du -sh "$wt" 2>/dev/null | cut -f1)
    if [[ $APPLY == 1 ]]; then
      if git -C "$wt" worktree remove "$wt" 2>/dev/null; then
        report removed "$wt" "$merged_into 에 합쳐짐, $size 확보"; removed=$((removed+1))
      else
        report kept "$wt" "git worktree remove 가 거절함"; kept=$((kept+1))
      fi
    else
      report would "$wt" "$merged_into 에 합쳐짐, 지우면 $size 확보"; removed=$((removed+1))
    fi
  done < <(find "$root" -maxdepth 5 -name node_modules -prune -o -name .git -type f -print 2>/dev/null)
  [[ $APPLY == 1 ]] && git -C "$root" worktree prune 2>/dev/null
done

echo "---"
if [[ $APPLY == 1 ]]; then echo "삭제 ${removed}개, 남김 ${kept}개"; else echo "지울 대상 ${removed}개, 남길 것 ${kept}개 (미리보기, 아무것도 지우지 않음)"; fi
