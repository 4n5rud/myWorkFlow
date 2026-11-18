#!/usr/bin/env bash
# 커밋의 WBS-Progress 꼬리에서 WBS 작업별 마지막 진행도를 뽑는다(지침서 09 1-2).
#   wbs-progress.sh [저장소 경로...]   여러 저장소(상위와 서브모듈)를 함께 줄 수 있다. 없으면 지금 저장소
# 출력: 번호<TAB>진행도<TAB>마지막 커밋 날짜<TAB>커밋 제목 (번호 순)
[[ $# -eq 0 ]] && set -- .
for r in "$@"; do
  git -C "$r" log --all --format='%cs%x1f%s%x1f%(trailers:key=WBS-Progress,valueonly,separator=%x1e)' 2>/dev/null
done | awk -F'\x1f' '
  { n = split($3, v, "\x1e"); for (i = 1; i <= n; i++) { split(v[i], p, " "); id = p[1]; if (id == "") continue
      if (!(id in d) || $1 > d[id]) { d[id] = $1; g[id] = p[2]; s[id] = $2 } } }
  END { for (id in d) printf "%s\t%s\t%s\t%s\n", id, g[id], d[id], s[id] }' | sort -t. -k1,1n -k2,2n -k3,3n
