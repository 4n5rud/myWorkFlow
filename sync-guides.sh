#!/usr/bin/env bash
# 지침서 원본(이 저장소의 guides/, harness.conf 의 GUIDES_DIR)을 노트 보관함 사본(NOTES_GUIDES_DIR)으로 한쪽으로만 복사한다.
# 2026-11-16부터 원본은 이 저장소다. 노트 보관함(옵시디언) 폴더는 macOS 개인정보 보호 때문에 세션이 못 읽는 일이 잦아서다.
#  - 사본 쪽에서 고친 것으로 보이는 파일(내용이 다르고, 원본의 마지막 커밋보다 사본이 더 새것)은 덮어쓰지 않고 알린다.
#    그 내용은 저장소 원본에 옮겨 커밋한 뒤 다시 돌린다.
#  - 사본 폴더를 읽거나 쓸 수 없으면 아무것도 지우지 않고 알리기만 한다.
#  - 원본에 특정 프로젝트 이름(private-terms.txt)이나 개인 절대 경로가 섞였으면 알린다(복사는 함).
# 쓰는 곳: install.sh 끝, 매일 예약 작업(daily.sh). 손으로 돌려도 된다: bash sync-guides.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
CONF="${HARNESS_CONF:-$HOME/.claude/harness.conf}"
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && source "$CONF"
GUIDES_DIR="${GUIDES_DIR:-$SRC/guides}"
NOTES_GUIDES_DIR="${NOTES_GUIDES_DIR:-}"
TERMS="$HOME/.claude/harness/private-terms.txt"

# 1. 원본 검사(알림만)
hits=""
[[ -f "$TERMS" ]] && hits=$(grep -rnF -f <(grep -v '^[[:space:]]*$' "$TERMS") "$GUIDES_DIR" --include='*.md' 2>/dev/null | sed "s#$GUIDES_DIR/##" | cut -c1-140 || true)
abs=$(grep -rnE "/Users/[^/<]+|/home/[^/<]+" "$GUIDES_DIR" --include='*.md' 2>/dev/null | sed "s#$GUIDES_DIR/##" | cut -c1-140 || true)
[[ -n "$hits" ]] && { echo "⚠ 지침서에 특정 프로젝트 이름으로 보이는 줄이 있습니다(익명화하세요):"; echo "$hits" | head -10; }
[[ -n "$abs" ]] && { echo "⚠ 지침서에 개인 절대 경로가 있습니다:"; echo "$abs" | head -10; }

# 2. 사본으로 복사
if [[ -z "$NOTES_GUIDES_DIR" ]]; then echo "노트 보관함 사본 위치(NOTES_GUIDES_DIR)가 없어 복사는 건너뜁니다."; exit 0; fi
if [[ "$(cd "$NOTES_GUIDES_DIR" 2>/dev/null && pwd -P)" == "$(cd "$GUIDES_DIR" && pwd -P)" ]]; then echo "원본과 사본 위치가 같아 복사하지 않습니다."; exit 0; fi
mkdir -p "$NOTES_GUIDES_DIR" 2>/dev/null
copied=0; same=0; skipped=(); failed=(); unreadable=()
# 학습 노트(learning/)도 노트 보관함 학습/ 으로 같은 방식으로 맞춘다
LEARN_SRC="$SRC/learning"; LEARN_DST="${NOTES_LEARNING_DIR:-${NOTES_DIR:+$NOTES_DIR/학습}}"
pairs=("$GUIDES_DIR|$NOTES_GUIDES_DIR|guides")
[[ -d "$LEARN_SRC" && -n "$LEARN_DST" ]] && pairs+=("$LEARN_SRC|$LEARN_DST|learning")
for pair in "${pairs[@]}"; do
from="${pair%%|*}"; rest="${pair#*|}"; to="${rest%%|*}"; gitdir="${rest#*|}"
mkdir -p "$to" 2>/dev/null
while IFS= read -r -d '' f; do
  rel="${f#"$from"/}"; dst="$to/$rel"
  if [[ -e "$dst" ]] && cmp -s "$f" "$dst" 2>/dev/null; then same=$((same+1)); continue; fi
  if [[ -e "$dst" ]]; then
    # 실제로 읽을 수 있을 때만 비교한다. macOS 개인정보 보호가 막으면 권한 비트와 상관없이 못 읽는다.
    if ! head -c1 "$dst" >/dev/null 2>&1; then unreadable+=("$rel"); continue; fi
    if ! cmp -s "$f" "$dst" 2>/dev/null; then
      committed=$(git -C "$SRC" log -1 --format=%ct -- "$gitdir/$rel" 2>/dev/null); committed=${committed:-0}
      dmt=$(stat -f %m "$dst" 2>/dev/null || echo 0)
      if (( dmt > committed + 60 )) && [[ -z "$(git -C "$SRC" status --porcelain -- "$gitdir/$rel" 2>/dev/null)" ]]; then
        skipped+=("$rel"); continue      # 사본이 원본 커밋보다 새것: 옵시디언에서 고친 것으로 보고 지키기
      fi
    fi
  fi
  mkdir -p "$(dirname "$dst")" 2>/dev/null
  if cp "$f" "$dst" 2>/dev/null; then copied=$((copied+1)); else failed+=("$rel"); fi
done < <(find "$from" -type f \( -name '*.md' -o -path '*/도구/*' \) ! -name '.*' -print0)
done

echo "지침서와 학습 노트 사본 동기화: 복사 ${copied}개, 이미 같음 ${same}개"
if (( ${#skipped[@]} )); then
  echo "⚠ 노트 보관함에서 고친 것으로 보여 덮어쓰지 않은 파일(내용을 저장소 원본에 옮겨 커밋한 뒤 다시 돌리세요):"
  printf '  - %s\n' "${skipped[@]}"
fi
if (( ${#unreadable[@]} )); then
  echo "⚠ 권한 때문에 사본을 읽지 못해 비교도 복사도 하지 않은 파일 ${#unreadable[@]}개(원본에는 영향 없음. 터미널에서 bash sync-guides.sh 를 돌리면 맞춰짐):"
  printf '  - %s\n' "${unreadable[@]}"
fi
if (( ${#failed[@]} )); then
  echo "⚠ 권한 때문에 복사하지 못한 파일(시스템 설정의 개인정보 보호에서 이 앱의 폴더 접근을 켜거나, 터미널에서 직접 돌리세요):"
  printf '  - %s\n' "${failed[@]}"
fi
exit 0
