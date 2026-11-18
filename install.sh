#!/usr/bin/env bash
# claude-work-harness 설치 스크립트 (macOS, Linux)
# 여러 번 돌려도 안전하다. 바꾸기 전 파일은 ~/.claude/harness-backup/<시각>/ 에 남긴다.
#
#   bash install.sh                 설치 또는 갱신
#   bash install.sh --replace-claude-md   ~/.claude/CLAUDE.md 를 통째로 이 묶음 것으로 바꾼다(백업 후)
#   CLAUDE_HOME=/tmp/x bash install.sh    다른 위치에 시험 설치(실제 ~/.claude 를 건드리지 않음)
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
CH="${CLAUDE_HOME:-$HOME/.claude}"
HD="$CH/harness"
TS="$(date +%Y%m%d-%H%M%S)"
BK="$CH/harness-backup/$TS"
REPLACE_CLAUDE_MD=0
[[ "${1:-}" == "--replace-claude-md" ]] && REPLACE_CLAUDE_MD=1

say() { printf '\033[1m%s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "필요한 명령이 없습니다: $1"; exit 1; }; }
need jq; need git; need perl

mkdir -p "$CH" "$HD" "$BK"
backup() { [[ -e "$1" ]] && { mkdir -p "$BK/$(dirname "${1#$CH/}")"; cp -R "$1" "$BK/${1#$CH/}"; } || true; }

# 1. 설정 파일
CONF="$CH/harness.conf"
if [[ ! -f "$CONF" ]]; then
  cp "$SRC/harness.conf.example" "$CONF"
  say "설정 파일을 만들었습니다: $CONF"
  echo "경로와 이름을 고친 뒤 install.sh 를 다시 돌리세요."
  exit 0
fi
# shellcheck disable=SC1090
source "$CONF"
: "${WORK_DIR:?harness.conf에 WORK_DIR가 없습니다}" "${GUIDES_DIR:?harness.conf에 GUIDES_DIR가 없습니다}"
NOTES_DIR="${NOTES_DIR:-$HOME/Documents/노트}"

# 2. 지침서: 폴더가 없거나 비어 있으면 묶음의 guides/ 를 복사한다. 이미 있으면 건드리지 않는다.
# 2026-11-16부터 원본은 이 저장소의 guides/ 다(GUIDES_DIR가 여기를 가리키면 복사할 것이 없다). 노트 보관함 사본은 끝에서 sync-guides.sh 가 맞춘다.
# 폴더를 읽지 못하면(macOS 권한 등) 비어 있다고 보지 않는다. 읽지 못한 채 복사하면 원본을 덮어쓴다(2026-11-16 사고).
if [[ "$(cd "$GUIDES_DIR" 2>/dev/null && pwd -P)" == "$(cd "$SRC/guides" && pwd -P)" ]]; then
  say "지침서 원본은 이 저장소의 guides/ 입니다."
elif [[ -d "$GUIDES_DIR" ]] && ! ls -A "$GUIDES_DIR" >/dev/null 2>&1; then
  say "지침서 폴더를 읽을 수 없어서 건드리지 않습니다: $GUIDES_DIR"
elif [[ ! -d "$GUIDES_DIR" ]] || [[ -z "$(ls -A "$GUIDES_DIR")" ]]; then
  mkdir -p "$GUIDES_DIR"; cp -Rn "$SRC/guides/." "$GUIDES_DIR/"
  say "지침서를 복사했습니다: $GUIDES_DIR"
else
  say "지침서 폴더가 이미 있어서 그대로 둡니다: $GUIDES_DIR"
fi

# 3. 자리 채우기
render() { # $1=src $2=dst
  perl -pe '
    s/\{\{GUIDES_DIR\}\}/$ENV{R_GUIDES}/g; s/\{\{NOTES_DIR\}\}/$ENV{R_NOTES}/g;
    s/\{\{HARNESS_DIR\}\}/$ENV{R_HD}/g;   s/\{\{HOME\}\}/$ENV{R_HOME}/g;
    s/\{\{REPORT_DEPT\}\}/$ENV{R_DEPT}/g; s/\{\{REPORT_NAME\}\}/$ENV{R_NAME}/g;
    s/\{\{DAILY_HOUR\}\}/$ENV{R_HOUR}/g; s/\{\{WORK_DIR\}\}/$ENV{R_WORK}/g;
  ' "$1" > "$2"
}
export R_WORK="$WORK_DIR" R_GUIDES="$GUIDES_DIR" R_NOTES="$NOTES_DIR" R_HD="$HD" R_HOME="$HOME" \
       R_DEPT="${REPORT_DEPT:-부서}" R_NAME="${REPORT_NAME:-이름}" R_HOUR="${DAILY_HOUR:-9}"

# 4. 훅, 도구, 스킬
for d in hooks bin skills/4n5rud-guides skills/4n5rud-weekly-report skills/4n5rud-todo skills/4n5rud-new-project skills/4n5rud-plan-doc skills/4n5rud-qa skills/4n5rud-arch skills/4n5rud-cleanup; do backup "$CH/$d"; done
mkdir -p "$CH/hooks/tests" "$CH/bin" "$CH/skills"
cp "$SRC"/claude/hooks/*.sh "$CH/hooks/"; cp "$SRC"/claude/hooks/tests/*.sh "$CH/hooks/tests/"
cp "$SRC"/claude/bin/* "$CH/bin/"
chmod +x "$CH"/hooks/*.sh "$CH"/hooks/tests/*.sh "$CH"/bin/*
SKILLS=(4n5rud-guides 4n5rud-weekly-report 4n5rud-todo 4n5rud-new-project 4n5rud-plan-doc 4n5rud-qa 4n5rud-arch 4n5rud-cleanup)
for s in "${SKILLS[@]}"; do
  mkdir -p "$CH/skills/$s"; render "$SRC/claude/skills/$s/SKILL.md" "$CH/skills/$s/SKILL.md"
done
ln -sfn "$GUIDES_DIR" "$CH/skills/4n5rud-guides/guides"

# 4b. 비밀값 검사: git 전역 훅(이 사용자의 모든 저장소의 커밋과 푸시에 적용)과 허용 목록 (지침서 15)
backup "$CH/git-hooks"; rm -rf "$CH/git-hooks"; cp -R "$SRC/claude/git-hooks" "$CH/git-hooks"; chmod +x "$CH/git-hooks/_dispatch"
[[ -f "$HD/secret-allow.txt" ]] || printf '# 비밀값 검사 허용 목록 (사용자만 고친다). 진짜 비밀값이 아닌데 걸리는 줄을 가리키는 정규식을 한 줄에 하나씩 적는다.\n' > "$HD/secret-allow.txt"
if [[ -z "${CLAUDE_HOME:-}" ]]; then
  # 한글 파일 이름이 \354\240\225 꼴로 깨지지 않게(지침서 00 §11). 세션은 전역 설정을 못 바꾸므로 설치 때 한 번 넣는다.
  [[ -z "$(git config --global --get core.quotepath || true)" ]] && git config --global core.quotepath false && say "git 전역 설정 core.quotepath=false 를 넣었습니다(한글 파일 이름 깨짐 방지)."
  cur=$(git config --global --get core.hooksPath || true)
  if [[ -z "$cur" || "$cur" == "$CH/git-hooks" ]]; then
    git config --global core.hooksPath "$CH/git-hooks"; say "git 전역 훅을 켰습니다: 모든 저장소의 커밋과 푸시에서 비밀값을 검사합니다."
  else
    say "⚠ 이미 다른 git 전역 훅 경로가 있어 바꾸지 않았습니다: $cur"; echo "  비밀값 검사를 켜려면 그 경로를 정리한 뒤 다시 설치하세요."
  fi
  own=$(find "${WORK_DIR}" -maxdepth 3 -name .git -prune -print 2>/dev/null | while read -r g; do r=$(dirname "$g"); if h=$(git -C "$r" config --local --get core.hooksPath 2>/dev/null); then echo "  $r ($h)"; fi; done || true)
  [[ -n "$own" ]] && { say "⚠ 아래 저장소는 자기 훅 경로를 따로 써서 git 전역 비밀값 검사가 돌지 않습니다(Claude 훅 검사는 됩니다):"; echo "$own"; }
fi

# 4c. 설치한 파일 목록. 제거 스크립트가 이 목록대로 지우고, 다음 설치 때 원본에서 사라진 옛 파일을 지운다.
MANIFEST="$HD/installed-files.txt"
new_list=$(cd "$CH" && {
  for f in "$SRC"/claude/hooks/*.sh; do echo "hooks/${f##*/}"; done
  for f in "$SRC"/claude/hooks/tests/*.sh; do echo "hooks/tests/${f##*/}"; done
  for f in "$SRC"/claude/bin/*; do echo "bin/${f##*/}"; done
  for s in "${SKILLS[@]}"; do echo "skills/$s/SKILL.md"; done
  echo "skills/4n5rud-guides/guides"
  for f in "$SRC"/claude/git-hooks/*; do echo "git-hooks/${f##*/}"; done
} | sort -u)
if [[ -f "$MANIFEST" ]]; then
  while IFS= read -r old; do
    [[ -n "$old" && "$old" != *..* ]] || continue
    grep -qxF -- "$old" <<<"$new_list" && continue
    if [[ -e "$CH/$old" || -L "$CH/$old" ]]; then rm -f "$CH/$old"; say "원본에서 사라진 옛 파일을 지웠습니다: $old (사본: $BK)"; fi
  done < "$MANIFEST"
fi
printf '%s\n' "$new_list" > "$MANIFEST"

# 5. 주간보고 양식과 프로젝트 목록
mkdir -p "$HD/templates"
render "$SRC/templates/주간보고 양식.html" "$HD/templates/주간보고 양식.html"
render "$SRC/templates/기획서 양식.html" "$HD/templates/기획서 양식.html"
render "$SRC/templates/QA 보고서 양식.html" "$HD/templates/QA 보고서 양식.html"
mkdir -p "$HD/qa" && cp "$SRC"/claude/qa/* "$HD/qa/"
[[ -f "$HD/projects.md" ]] || cp "$SRC/projects.md.example" "$HD/projects.md"

# 6. 전역 지침 CLAUDE.md: 표시 줄 사이의 묶음 부분만 바꾼다. 사용자가 따로 쓴 내용은 그대로 둔다.
START="<!-- claude-work-harness:start -->"; END="<!-- claude-work-harness:end -->"
block="$(mktemp)"; { echo "$START"; render "$SRC/claude/CLAUDE.md" /dev/stdout; echo "$END"; } > "$block"
backup "$CH/CLAUDE.md"
if [[ $REPLACE_CLAUDE_MD == 1 || ! -f "$CH/CLAUDE.md" ]]; then
  cp "$block" "$CH/CLAUDE.md"
elif grep -qF "$START" "$CH/CLAUDE.md"; then
  B="$block" perl -0pi -e 'BEGIN{local $/; open F,"<",$ENV{B}; $b=<F>; close F} s/<!-- claude-work-harness:start -->.*?<!-- claude-work-harness:end -->\n?/$b/s' "$CH/CLAUDE.md"
else
  printf '\n' >> "$CH/CLAUDE.md"; cat "$block" >> "$CH/CLAUDE.md"
fi
rm -f "$block"

# 7. settings.json: 이 묶음의 훅 줄만 지우고 다시 넣는다. 다른 훅과 설정은 그대로 둔다.
S="$CH/settings.json"; [[ -f "$S" ]] || echo '{}' > "$S"; backup "$S"
ours='guard.sh|commit-lint.sh|skill-log.sh|session-start.sh|session-end.sh|subagent-start.sh|received-files.sh|sent-claims.sh|todo-done.sh|subagent-limit.sh|korean-reply.sh'
jq --slurpfile add "$SRC/claude/settings.hooks.json" --arg ours "$ours" --arg guides "$GUIDES_DIR" '
  def mine: ((.hooks // []) | map(.command // "") | any(test("/\\.claude/hooks/(" + $ours + ")$")));
  ((.hooks // {}) | with_entries(.value |= map(select(mine | not)))) as $kept
  | (reduce ($add[0].hooks | to_entries[]) as $e ($kept; .[$e.key] = ((.[$e.key] // []) + $e.value))) as $merged
  | .hooks = $merged
  | .attribution = $add[0].attribution
  | .permissions.allow = (((.permissions.allow // []) + ["Read(/" + $guides + "/**)"]) | unique)
' "$S" > "$S.tmp"
# 결과가 올바른 설정인지 확인한 뒤에만 바꾼다
if jq -e '(.hooks | type == "object") and (.hooks | to_entries | all(.value | type == "array"))' "$S.tmp" >/dev/null 2>&1; then
  mv "$S.tmp" "$S"
else
  rm -f "$S.tmp"; echo "settings.json 합치기에 실패해서 바꾸지 않았습니다. 백업: $BK"; exit 1
fi

# 8. 매일 예약 작업 (macOS launchd). 시험 설치(CLAUDE_HOME 지정)에서는 건너뛴다.
if [[ -z "${CLAUDE_HOME:-}" && "$(uname)" == Darwin && -n "${DAILY_HOUR:-}" ]]; then
  P="$HOME/Library/LaunchAgents/claude-work-harness.daily.plist"
  render "$SRC/launchd/claude-work-harness.daily.plist" "$P"
  launchctl bootout "gui/$(id -u)/claude-work-harness.daily" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$P" && say "매일 ${DAILY_HOUR}시 예약 작업을 등록했습니다."
fi

# 9. 설정 기록 저장소 첫 저장 (시험 설치에서는 건너뛴다)
[[ -z "${CLAUDE_HOME:-}" ]] && "$CH/bin/claude-config" save "claude-work-harness 설치 $TS" >/dev/null 2>&1 || true

# 10. 시험: 묶음마다 마지막 줄만 보이고, 실패한 묶음은 전체 출력을 보인다. 하나가 실패해도 나머지는 끝까지 돈다.
say "훅 시험"
failed=0
suite() { # $1=이름, 나머지=환경 변수와 명령
  local name="$1" out rc; shift
  out=$(env "$@" 2>&1); rc=$?
  if (( rc == 0 )); then printf '%-16s %s\n' "$name" "$(tail -1 <<<"$out")"
  else printf '\033[1m%-16s 실패\033[0m\n%s\n' "$name" "$out"; failed=$((failed + 1)); fi
}
set +e
suite guard          GUARD="$CH/hooks/guard.sh" SECRET_SCAN="$CH/hooks/secret-scan.sh" bash "$CH/hooks/tests/run.sh"
suite commit-lint    LINT="$CH/hooks/commit-lint.sh" bash "$CH/hooks/tests/commit-lint.sh"
suite received-files RECV="$CH/hooks/received-files.sh" bash "$CH/hooks/tests/received-files.sh"
suite sent-claims    SENT="$CH/hooks/sent-claims.sh" bash "$CH/hooks/tests/sent-claims.sh"
suite todo           HOOKS_DIR="$CH/hooks" bash "$CH/hooks/tests/todo.sh"
suite secret-scan    SCAN="$CH/hooks/secret-scan.sh" bash "$CH/hooks/tests/secret-scan.sh"
suite git-hooks      GITHOOKS="$CH/git-hooks" SCAN="$CH/hooks/secret-scan.sh" bash "$CH/hooks/tests/git-hooks.sh"
suite git-hooks-env  HOOKS_SRC="$CH" bash "$CH/hooks/tests/git-hooks-env.sh"
suite personal-scan  PSCAN="$CH/hooks/personal-scan.sh" bash "$CH/hooks/tests/personal-scan.sh"
suite submodule      SUBCHK="$CH/hooks/submodule-check.sh" bash "$CH/hooks/tests/submodule-check.sh"
suite korean-reply KREPLY="$CH/hooks/korean-reply.sh" bash "$CH/hooks/tests/korean-reply.sh"
suite subagent-limit SLIMIT="$CH/hooks/subagent-limit.sh" bash "$CH/hooks/tests/subagent-limit.sh"
set -e
if (( failed )); then
  say "⚠ 시험 ${failed}묶음이 실패했습니다. 위 출력을 보고 원본을 고친 뒤 다시 설치하세요. 파일은 이미 설치됐습니다."
  exit 1
fi

say "지침서 사본 맞추기"
bash "$SRC/sync-guides.sh" || true
cp "$SRC/sync-guides.sh" "$CH/bin/sync-guides.sh" 2>/dev/null && chmod +x "$CH/bin/sync-guides.sh"
printf '%s\n' "$SRC" > "$HD/harness-src"   # 매일 예약 작업이 원본 저장소를 찾는 곳

say "설치를 마쳤습니다."
echo "- 바꾸기 전 파일: $BK"
echo "- 주간보고 프로젝트 목록을 채우세요: $HD/projects.md"
echo "- 금요일 주간보고 자동 실행은 README의 \"주간보고 자동 실행\"을 보고 따로 등록합니다."
echo "- 열려 있던 Claude Code 세션은 새로 열어야 전역 지침이 적용됩니다."
