#!/usr/bin/env python3
"""orca terminal list --json 을 stdin 으로 받아 <핸들> <busy|idle> 을 찍는다.

⚠ 이 파일이 따로 있는 이유 — 셸에서 `cmd | python3 - <<'PY'` 로 쓰면
   파이프와 heredoc 이 **둘 다 stdin 을 요구**한다. heredoc 이 이기고
   json.load(sys.stdin) 은 빈 값을 읽는다. 그러면 핸들을 영영 못 찾는데
   에러도 안 난다 — "터미널 없음, 기록만" 으로 조용히 빠진다.
   실제로 그렇게 한 번 당했다. 스크립트 파일로 두면 stdin 은 파이프 하나뿐이다.

사용: orca terminal list --json | python3 find_terminal.py <워크트리경로조각>
"""
import json
import sys
import time

frag = sys.argv[1] if len(sys.argv) > 1 else ""

try:
    payload = json.load(sys.stdin)
except Exception:
    # 🔴 "목록을 못 읽었다" 와 "그 세션이 없다" 를 같은 값으로 뭉개지 않는다.
    #    뭉개면 통로가 통째로 죽어도 "터미널 없음, 기록만" 이라는 평범한 안내로 보인다 —
    #    위의 stdin 충돌이 하루 동안 안 보인 이유가 바로 그것이다.
    print("!목록실패 -")
    sys.exit(0)

terminals = (payload.get("result") or payload).get("terminals") or []

for t in terminals:
    if frag and frag in (t.get("worktreePath") or ""):
        title = str(t.get("title") or "")
        last = t.get("lastOutputAt") or 0
        # lastOutputAt 이 없으면 age 는 None. 0 으로 두면 "아주 오래 전"이 되어 판정이 뒤집힌다.
        age = (time.time() * 1000 - last) if last else None
        # title[:1] 로 쓰면 빈 제목이 "" 가 되고 파이썬은 "" in s 를 True 로 본다 —
        # 제목 없는 세션이 전부 busy 로 잡혀 알림이 영영 안 나갔다.
        spinner = bool(title) and title[0] in "⠐⠈⠠⢀⡀⠄⠂✳✶✻✽"
        recent = age is not None and age < 15_000       # 지금 출력 중
        warm = age is not None and age < 300_000        # 5분 안에 움직였다
        # 스피너만으로는 못 믿는다 — 끝난 뒤에도 글리프가 제목에 남는다.
        print(t.get("handle", ""), "busy" if (recent or (spinner and warm)) else "idle")
        break
else:
    print("")
