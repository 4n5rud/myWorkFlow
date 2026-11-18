#!/usr/bin/env bash
# Daily job (launchd, 09:00). Shell identifiers stay ASCII (00 세션 공통 지침 §10).
#  1. worktree cleanup for every project under WORK_DIR (10 자동 장치 §3)
#  2. save ~/.claude settings to the local history repo if anything changed
#  3. count skill use in the last 24 hours
#  4. write ~/.claude/logs/daily-summary.md and show one macOS notification
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
CONF="${HARNESS_CONF:-$HOME/.claude/harness.conf}"; READONLY_REPOS=(); WORK_DIR="$HOME/Desktop/work"; GUIDES_DIR=""
[[ -f "$CONF" ]] && source "$CONF"
is_readonly() { local r; for r in "${READONLY_REPOS[@]}"; do [[ "$1" == "$r" || "$1" == "$r"/* ]] && return 0; done; return 1; }
WORK="$WORK_DIR"; LOGS="$HOME/.claude/logs"; mkdir -p "$LOGS"
OUT="$LOGS/daily-summary.md"; [[ "${DRY:-0}" == 1 ]] && OUT="$LOGS/daily-summary.preview.md"; GC_LOG="$LOGS/worktree-gc.log"
today=$(date '+%Y-%m-%d'); since=$(date -v-1d '+%Y-%m-%dT%H:%M')

# 1. worktree cleanup (read-only repos are skipped, also inside worktree-gc.sh)
projects=()
for d in "$WORK"/*/; do
  d=${d%/}; is_readonly "$d" && continue; projects+=("$d")
done
# DRY=1 bash daily.sh  -> preview only: no deletion, no save, no notification
if [[ "${DRY:-0}" == 1 ]]; then
  gc_out=$("$HOME/.claude/hooks/worktree-gc.sh" "${projects[@]}" 2>&1 | sed 's/^would  /removed/')
else
  gc_out=$("$HOME/.claude/hooks/worktree-gc.sh" --apply "${projects[@]}" 2>&1)
fi
printf '%s\n--- %s\n%s\n' "$(date '+%F %T')" "${#projects[@]} projects" "$gc_out" > "$LOGS/daily-gc-last.log"   # raw result, for diagnosis
removed=$(grep -c '^removed' <<<"$gc_out"); kept=$(grep -c '^kept' <<<"$gc_out")

# 2. settings history
cfg="변경 없음"
if [[ "${DRY:-0}" == 1 ]]; then cfg="미리보기라 저장 안 함"
elif [[ -n "$("$HOME/.claude/bin/claude-config" status --porcelain 2>/dev/null)" ]] \
   || [[ -n "$(cd "$HOME/.claude" && ls projects/*/memory/*.md 2>/dev/null | "$HOME/.claude/bin/claude-config" ls-files --others --exclude-standard --stdin 2>/dev/null | head -1)" ]]; then
  "$HOME/.claude/bin/claude-config" save "자동 저장 $today" >/dev/null 2>&1 && cfg="저장함"
fi

# 3. skill use in the last 24 hours
skills=$(awk -F'\t' -v s="$since" '$1 >= s {print $2}' "$LOGS/skill-usage.tsv" 2>/dev/null | sort | uniq -c | sort -rn)
wg=$(awk '$2=="4n5rud-guides"{print $1}' <<<"$skills"); wg=${wg:-0}

# 3b. guide copy in the notes vault (source is the harness repo guides/, sync-guides.sh)
sync_out=""
if [[ "${DRY:-0}" != 1 && -f "$HOME/.claude/harness/harness-src" ]]; then
  src=$(cat "$HOME/.claude/harness/harness-src"); [[ -f "$src/sync-guides.sh" ]] && sync_out=$(bash "$src/sync-guides.sh" 2>&1)
fi

# 4. summary
{
  echo "# 일일 요약 $today"
  echo
  echo "## 작업 폴더 정리"
  echo "- 지운 폴더 ${removed}개, 남긴 폴더 ${kept}개"
  grep '^removed' <<<"$gc_out" | sed "s#$WORK/##; s/^removed */- 지움: /"
  echo
  echo "### 남긴 이유별 개수"
  grep '^kept' <<<"$gc_out" | grep -oE '\(([^()]|\([^)]*\))*\)$' | sed -E 's/ \(브랜치 [^)]*\)//; s/: .*/)/' | sort | uniq -c | sort -rn | sed 's/^ */- /'
  echo
  echo "## 설정 기록"
  echo "- $cfg (claude-config log 로 확인)"
  echo
  echo "## 지침서 사본 (노트 보관함)"
  if [[ -n "$sync_out" ]]; then sed 's/^/- /' <<<"$sync_out"; else echo "- 건너뜀"; fi
  echo
  echo "## 최근 24시간 스킬 사용"
  if [[ -n "$skills" ]]; then sed 's/^ *\([0-9]*\) \(.*\)/- \2: \1번/' <<<"$skills"; else echo "- 기록 없음"; fi
} > "$OUT"

msg="작업 폴더 ${removed}개 정리, 지침서 길잡이 ${wg}번 사용, 설정 ${cfg}"
[[ "${DRY:-0}" == 1 ]] && { echo "$msg"; exit 0; }
[[ "$(uname)" == Darwin ]] && osascript -e "display notification \"$msg\" with title \"Claude 일일 요약\" subtitle \"자세히: ~/.claude/logs/daily-summary.md\"" 2>/dev/null
exit 0
