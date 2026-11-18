#!/usr/bin/env bash
# SessionStart hook (global). Prints context for the model as JSON additionalContext.
#  4. how far this checkout is behind its upstream (00 세션 공통 지침 §1)
#  5. after a compaction: re-read guides and update the handoff note (00 §8)
#  7. warn when a guide file is missing from the 4n5rud-guides routing table
#  +  start worktree cleanup for this project in the background (10 자동 장치 §3)
# Shell identifiers stay ASCII (00 §10).

input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input"); [[ -n "$cwd" ]] || cwd=$PWD
source=$(jq -r '.source // "startup"' <<<"$input")
CONF="${HARNESS_CONF:-$HOME/.claude/harness.conf}"; READONLY_REPOS=(); WORK_DIR="$HOME/Desktop/work"; GUIDES_DIR=""
[[ -f "$CONF" ]] && source "$CONF"
is_readonly() { local r; for r in "${READONLY_REPOS[@]}"; do [[ "$1" == "$r" || "$1" == "$r"/* ]] && return 0; done; return 1; }
WORK="$WORK_DIR"
GUIDES="$GUIDES_DIR"
SKILL="$HOME/.claude/skills/4n5rud-guides/SKILL.md"
msgs=()

# read-only repos: no fetch, no cleanup
is_readonly "$cwd" && exit 0

# 4. behind / ahead of upstream
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # fetch at most once per 10 minutes per repository; otherwise use the last fetched state
  common=$(cd "$cwd" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  hash() { if command -v shasum >/dev/null; then shasum; else sha1sum; fi; }
  stamp="$HOME/.claude/state/fetch/$(printf '%s' "$common" | hash | cut -c1-16)"
  mkdir -p "$(dirname "$stamp")"
  if [[ -z "$(find "$stamp" -mmin -10 2>/dev/null)" ]]; then
    GIT_TERMINAL_PROMPT=0 perl -e 'alarm 8; exec @ARGV' git -C "$cwd" fetch -q origin 2>/dev/null && touch "$stamp"
  fi
  up=$(git -C "$cwd" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
  if [[ -n "$up" ]]; then
    read -r behind ahead < <(git -C "$cwd" rev-list --left-right --count "$up...HEAD" 2>/dev/null)
    if [[ "${behind:-0}" -gt 0 ]]; then
      msgs+=("이 체크아웃은 $up 보다 ${behind}커밋 뒤처져 있다(앞선 커밋 ${ahead:-0}개). 작업 전에 최신으로 맞출지 판단한다(00 세션 공통 지침 §1).")
    fi
  else
    branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
    msgs+=("현재 브랜치(${branch:-detached HEAD})에 추적 대상(upstream)이 없어 뒤처짐을 확인하지 못했다. 필요하면 origin과 직접 비교한다(00 §1).")
  fi
fi

# 8. project to-do list in the notes vault (지침서 14 할 일과 끝낸 일)
source "$(dirname "$0")/lib-project.sh" 2>/dev/null || source "$HOME/.claude/hooks/lib-project.sh" 2>/dev/null
pname=$(project_name_for "$cwd" 2>/dev/null)
pdocs=$(project_docs_for "$cwd" 2>/dev/null)
# 7a. a parent repo with submodules works on its default branch only; branches are cut in the submodules (2026-11-09)
ptop=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
if [[ -n "$ptop" && -f "$ptop/.gitmodules" ]]; then
  pb=$(git -C "$ptop" branch --show-current 2>/dev/null)
  # default branch: the remote HEAD record when it is main or master, otherwise main, then master
  pdef=$(git -C "$ptop" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); pdef="${pdef#origin/}"
  [[ "$pdef" == main || "$pdef" == master ]] || pdef=""
  [[ -n "$pdef" ]] || for c in main master; do git -C "$ptop" rev-parse -q --verify "refs/remotes/origin/$c" >/dev/null && { pdef=$c; break; }; done
  if [[ -n "$pdef" && -n "$pb" && "$pb" != "$pdef" ]]; then
    msgs+=("이 저장소는 서브모듈을 묶는 상위 저장소인데 지금 ${pdef}가 아닌 ${pb} 브랜치에 있다. 상위 저장소는 기본 브랜치(${pdef})에서만 작업하고, 기능 브랜치는 서브모듈에서 나눈다(00 세션 공통 지침). 이미 진행 중인 브랜치는 끝내고 합치되, 새 작업은 ${pdef}에서 한다.")
  fi
fi

# 7b. the to-do list and the outgoing ledger are local only (gitignored, 2026-11-09). A pull of the commit
# that stopped tracking them deletes them from older checkouts, so keep a copy and put it back when missing.
if [[ -n "$pname" && -n "$pdocs" ]]; then
  restored=()
  for rel in "_할일/할 일.md" "_할일/끝낸 일.md" "_발신함/목록.md"; do
    src="$pdocs/$rel"; bak="$HOME/.claude/harness/local-lists/$pname/$rel"
    if [[ -f "$src" ]]; then mkdir -p "$(dirname "$bak")" && cp -p "$src" "$bak" 2>/dev/null
    elif [[ -f "$bak" ]]; then mkdir -p "$(dirname "$src")" && cp -p "$bak" "$src" && restored+=("$rel"); fi
  done
  (( ${#restored[@]} )) && msgs+=("로컬 전용 목록이 사라져 있어 보관본으로 되살렸다: ${restored[*]} (원격을 받으면서 지워진 것으로 보인다. 이 파일들은 커밋하지 않는다, 지침서 13, 14)")
fi
if [[ -n "$pname" ]]; then
  todo="$pdocs/_할일/할 일.md"
  [[ -f "$todo" || -z "${NOTES_DIR:-}" ]] || { [[ -f "$NOTES_DIR/work/$pname/할 일.md" ]] && todo="$NOTES_DIR/work/$pname/할 일.md"; }
  if [[ -f "$todo" ]]; then
    open_n=$(grep -cE '^[[:space:]]*- \[ \]' "$todo")
    if (( open_n > 0 )); then
      top_items=$(grep -E '^[[:space:]]*- \[ \]' "$todo" | head -5 | sed -E 's/^[[:space:]]*- \[ \][[:space:]]*//' | cut -c1-60 | paste -sd ',' -)
      msgs+=("이 프로젝트(${pname})의 할 일이 ${open_n}개 남아 있다(${todo#$pdocs/}). 시작 전에 읽고, 끝낸 것은 체크해서 끝낸 일.md로 옮긴다(지침서 14). 위쪽 항목: ${top_items}")
    fi
  else
    msgs+=("이 프로젝트(${pname})에는 아직 할 일 목록이 없다. 문서 저장소의 _할일/ 에 할 일.md 와 끝낸 일.md 를 지침서 14 형식으로 만들고, 남은 일이 생기면 거기에 적는다.")
  fi
fi

# 6. outgoing documents not confirmed as sent by the user (지침서 13 보낼 문서와 발송 상태)
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
# the project's docs repo first (where _할일/ lives too), then this repo, then the project folder
for ledger in "${pdocs:+$pdocs/_발신함/목록.md}" "$top/_발신함/목록.md" "$WORK/$(cut -d/ -f1 <<<"${cwd#$WORK/}")/_발신함/목록.md"; do
  [[ -n "$ledger" && -f "$ledger" ]] || continue
  pending=$(grep -E '^\|' "$ledger" | grep -E '\|[[:space:]]*(초안|검토 요청)[[:space:]]*\|' | awk -F'|' '{gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); print $3" "$4}' | head -5)
  if [[ -n "$pending" ]]; then
    n=$(grep -cE '\|[[:space:]]*(초안|검토 요청)[[:space:]]*\|' "$ledger")
    msgs+=("발송 확인이 안 된 보낼 문서가 ${n}건 있다(_발신함/목록.md). 이 문서들을 \"전달함, 회신 대기\"로 쓰지 말고, 이번 보고에서 사용자에게 보냈는지 묻는다(지침서 13): $(tr '\n' ',' <<<"$pending" | sed 's/,$//')")
  fi
  break
done

# 5. after compaction
if [[ "$source" == "compact" ]]; then
  msgs+=("대화가 방금 압축되었다. 지금 작업에 필요한 지침서 절만 다시 읽고(4n5rud-guides), 인계 문서가 있으면 오늘 한 일과 막힌 것(맥락)을 갱신하고, 남은 일은 할 일.md에 적는다(00 §8).")
fi

# 7. guide files missing from the routing table
if [[ -d "$GUIDES" && -f "$SKILL" ]]; then
  missing=()
  for f in "$GUIDES"/*.md; do
    b=$(basename "$f")
    grep -qF "$b" "$SKILL" || missing+=("$b")
  done
  if (( ${#missing[@]} )); then
    msgs+=("4n5rud-guides 길잡이 표에 없는 지침서가 있다: ${missing[*]}. 사용자에게 알리고, 허락받으면 표에 추가한다.")
  fi
fi

# worktree cleanup for this project, in the background (never blocks the session)
if [[ "$cwd" == "$WORK"/* ]]; then
  project="$WORK/$(cut -d/ -f1 <<<"${cwd#$WORK/}")"
  if [[ -d "$project" ]] && ! is_readonly "$project"; then
    nohup "$HOME/.claude/hooks/worktree-gc.sh" --apply "$project" >/dev/null 2>&1 &
  fi
fi

(( ${#msgs[@]} )) || exit 0
ctx=$(printf -- '- %s\n' "${msgs[@]}")
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
