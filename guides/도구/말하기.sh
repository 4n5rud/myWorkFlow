#!/usr/bin/env bash
# 세션끼리 사람을 거치지 않고 주고받는 통로. (이식용 — 세션 이름은 세션.conf 에 둔다)
#
#   ./말하기.sh <받는쪽> "<내용>" [문서경로]
#   ./말하기.sh be "계약 올렸습니다" docs/_작업/전달_....md
#   ./말하기.sh all "개발 DB 시드 재실행합니다 (5분)"
#
# 한 번에 셋을 한다. 1) 기록(append), 2) 알림, 3) 넘긴 문서가 있으면 origin 에서 보이는지 확인.
#
# ⚠ 변수명은 ASCII 만 쓴다. bash 는 한글 식별자를 못 받고, `bash -n` 으로도 안 잡히며
#   실행할 때 command not found 로 터진다.
# ⚠ 같은 이유로 변수 뒤에 한글·기호가 바로 붙으면 중괄호로 감싼다. "$FROM→$target" 는
#   화살표 첫 바이트를 변수명에 붙여 먹어 unbound variable 로 터진다. "${FROM}→${target}".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/세션.conf"

[ -f "$CONF" ] || { echo "세션.conf 가 없다. 세션.conf.example 을 복사해서 채운다." >&2; exit 1; }

# 🔴 **데이터는 저장소 밖 한 곳에 둔다.**
#    저장소 안에 두면 워크트리마다 사본이 생겨 세션끼리 서로의 글을 못 본다 —
#    통로가 아니라 벽이 된다. 도구(스크립트)만 저장소가 나른다.
SHARE_DIR="${SESSION_SHARE_DIR:-$HOME/.$(basename "$(cd "$SCRIPT_DIR/.." && pwd)")/공유}"
mkdir -p "$SHARE_DIR"
LOG_FILE="$SHARE_DIR/대화.jsonl"
[ -f "$LOG_FILE" ] || : > "$LOG_FILE"

# 세션.conf 형식:  <이름>=<워크트리 경로 조각>
#   기획=workspaces/foo/기획
#   be=workspaces/foo/be
#   main=Desktop/work/foo
session_path() {
  awk -F= -v k="$1" '$1==k {print $2; found=1} END {if (!found) print ""}' "$CONF" | head -1
}
all_sessions() { awk -F= '!/^#/ && NF==2 {print $1}' "$CONF"; }

usage() {
  echo "사용법: $0 <받는쪽> \"<내용>\" [문서경로]" >&2
  echo "  받는쪽: $(all_sessions | tr '\n' ' ')| all" >&2
  exit 1
}

[ $# -ge 2 ] || usage
TO="$1"; MSG="$2"; DOC="${3:-}"

# 보내는 쪽은 현재 경로로 추정한다
FROM="unknown"
while IFS='=' read -r name frag; do
  case "$name" in ''|\#*) continue ;; esac
  case "$PWD" in *"$frag"*) FROM="$name"; break ;; esac
done < "$CONF"

# ── 1. 기록 (append — 여러 세션이 동시에 써도 안 깨진다) ──────────────────
python3 - "$LOG_FILE" "$FROM" "$TO" "$MSG" "$DOC" <<'PY'
import json, sys, datetime, io
log, frm, to, msg, doc = sys.argv[1:6]
row = {"at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
       "from": frm, "to": to, "msg": msg}
if doc:
    row["doc"] = doc
with io.open(log, "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
PY
echo "기록: $LOG_FILE"

# ── 2. 알림 ────────────────────────────────────────────────────────────
# ⚠ 상대가 작업 중이면 보내지 않는다. 작업 중인 에이전트에 끼어들면 그 작업이 흐트러진다.
#
# 🔴 아래는 orca 기준이다. 다른 하네스를 쓰면 `list_terminals` 와 `send_text` 두
#    함수만 바꾸면 된다. 그 외에는 도구 의존이 없다.
list_terminals() { orca terminal list --json 2>/dev/null; }
send_text() { orca terminal send --terminal "$1" --text "$2" --enter --json >/dev/null 2>&1; }

notify_one() {
  local target="$1" frag handle busy
  frag="$(session_path "$target")"
  if [ -z "$frag" ]; then echo "  ? 모르는 세션: $target" >&2; return 0; fi

  # ⚠ 해석기를 heredoc 으로 인라인하지 않는다 — 파이프와 heredoc 이 둘 다 stdin 을
  #   요구해 json 을 못 읽고, **에러 없이** "터미널 없음" 으로 조용히 빠진다.
  read -r handle busy < <(list_terminals | python3 "$SCRIPT_DIR/find_terminal.py" "$frag") || true

  # 🔴 "목록을 못 읽었다" 와 "그 세션이 없다" 를 갈라서 보여준다.
  #    뭉개면 통로가 통째로 죽어도 평범한 안내로 보인다.
  if [ "${handle:-}" = "!목록실패" ]; then
    echo "  ! $target — 터미널 목록 조회 실패. 통로가 죽었을 수 있다, 기록만" >&2; return 0
  fi
  if [ -z "${handle:-}" ]; then echo "  · $target — 터미널 없음, 기록만"; return 0; fi
  if [ "${busy:-}" = "busy" ]; then echo "  · $target — 작업 중, 기록만 (알림 생략)"; return 0; fi

  local text="[${FROM}→${target}] ${MSG}"
  [ -n "$DOC" ] && text="${text}  (${DOC})"
  if send_text "$handle" "$text"; then
    echo "  ✓ $target 알림 전송"
  else
    echo "  ! $target 전송 실패 — 기록은 남았다"
  fi
}

echo "알림:"
if [ "$TO" = "all" ]; then
  for s in $(all_sessions); do [ "$s" != "$FROM" ] && notify_one "$s"; done
else
  notify_one "$TO"
fi

# ── 3. 넘긴 문서가 상대에게 정말 보이나 ─────────────────────────────────
# 🔴 묻는 것은 "추적되나" 가 아니라 **"origin 에 있나"** 다. 커밋만 하고 안 밀면
#    상대에게는 그대로 없다 — 안 밀린 것이 바로 그 실패 모양이다.
# 🔴 서브모듈 안의 파일은 **부모의 ls-files 로는 영영 안 보인다.** 그것을 "커밋 안 됨"
#    으로 읽으면 밀어 놓고도 매번 경고가 뜬다. 첫 조각이 서브모듈이면 그 안에서 확인한다.
BRANCH="${SESSION_MAIN_BRANCH:-main}"
doc_visible() {
  local doc="$1" root="$SCRIPT_DIR/.." top="${1%%/*}" rest="${1#*/}"
  if [ "$top" != "$doc" ] && [ -e "$root/$top/.git" ]; then
    git -C "$root/$top" cat-file -e "origin/$BRANCH:$rest" 2>/dev/null && return 0
    return 1
  fi
  git -C "$root" cat-file -e "origin/$BRANCH:$doc" 2>/dev/null
}

if [ -n "$DOC" ]; then
  if doc_visible "$DOC"; then
    echo "  ✓ ${DOC} — origin/${BRANCH} 에서 보인다"
  else
    echo
    echo "  ⚠ ${DOC} 은 origin/${BRANCH} 에 없다 — 상대 워크트리에서 안 보인다."
    echo "    푸시하거나, 아직 내 쪽에만 있다는 사실을 함께 알린다."
  fi
fi
