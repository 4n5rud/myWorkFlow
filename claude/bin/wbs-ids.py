#!/usr/bin/env python3
"""프로젝트 WBS 파일에서 작업 번호 목록을 뽑아 커밋 검사용 목록을 만든다.

  wbs-ids.py                 ~/.claude/harness/commit-wbs/sources.tsv 의 모든 프로젝트를 다시 뽑음
  wbs-ids.py <프로젝트 폴더>  그 프로젝트만
sources.tsv: 한 줄에 "<WORK_DIR 아래 프로젝트 폴더 이름>\t<WBS 파일 경로>" (경로는 그 프로젝트 폴더 기준 또는 ~ 시작)
결과: ~/.claude/harness/commit-wbs/<프로젝트 폴더>.txt (한 줄에 번호 하나, 맨 위 주석에 출처와 날짜)
이 파일이 있는 프로젝트의 저장소에서는 모든 커밋 제목 끝에 [WBS : 번호]가 있어야 한다(지침서 09).
CSV는 "작업ID"나 "ID", "번호" 열을, HTML과 MD, TXT는 칸이나 줄 머리에 홀로 있는 "숫자.숫자(.숫자)" 꼴을 번호로 본다(앞에 영문 대문자 하나가 붙은 T0.1 꼴도 번호).
"""
import os, re, sys, csv, html, time

HOME = os.path.expanduser('~'); D = os.path.join(HOME, '.claude/harness/commit-wbs')
def work_dir():
    w = os.path.join(HOME, 'Desktop/work')
    try:
        for line in open(os.path.join(HOME, '.claude/harness.conf'), encoding='utf-8'):
            m = re.match(r'\s*WORK_DIR="?([^"\n]+)"?', line)
            if m: w = m.group(1).replace('$HOME', HOME)
    except OSError: pass
    return w
ID = re.compile(r'^[A-Z]?\d+(\.\d+)+$')
DATE = re.compile(r'^(19|20)\d\d\.\d\d?\.\d\d?$')
def extract(path):
    ext = path.lower().rsplit('.', 1)[-1]
    raw = open(path, encoding='utf-8', errors='ignore').read()
    ids = []
    if ext == 'csv':
        rows = list(csv.reader(raw.splitlines()))
        head = rows[0] if rows else []
        col = next((i for i, h in enumerate(head) if h.strip() in ('작업ID', 'ID', '번호', 'WBS', 'WBS ID', 'No')), None)
        for r in rows[1:]:
            cells = [r[col]] if col is not None and col < len(r) else r
            ids += [c.strip() for c in cells if ID.match(c.strip())]
    else:
        text = html.unescape(re.sub(r'<[^>]+>', '\n', raw)) if ext in ('html', 'htm') else raw
        for line in text.splitlines():
            for cell in re.split(r'\||\t', line):
                c = cell.strip().strip('*').strip()
                c = re.sub(r'^#+\s*', '', c)
                m = re.match(r'^([A-Z]?\d+(?:\.\d+)+)(?=\s|$)', c)
                if m and not DATE.match(m.group(1)): ids.append(m.group(1))
    seen = []; [seen.append(i) for i in ids if i not in seen]
    return seen

os.makedirs(D, exist_ok=True); src = os.path.join(D, 'sources.tsv')
if not os.path.exists(src): sys.exit(f'{src} 가 없습니다. "<프로젝트 폴더>\\t<WBS 파일>" 줄을 적어 주세요.')
only = sys.argv[1] if len(sys.argv) > 1 else None
W = work_dir()
for line in open(src, encoding='utf-8'):
    if not line.strip() or line.startswith('#'): continue
    proj, rel = [x.strip() for x in line.split('\t', 1)]
    if only and proj != only: continue
    path = os.path.expanduser(rel) if rel.startswith('~') else os.path.join(W, proj, rel)
    if not os.path.exists(path): print(f'⚠ {proj}: WBS 파일이 없습니다: {rel}'); continue
    ids = extract(path)
    with open(os.path.join(D, f'{proj}.txt'), 'w', encoding='utf-8') as f:
        f.write(f'# {proj} WBS 번호 {len(ids)}개, 출처 {rel}, 뽑은 날 {time.strftime("%Y-%m-%d")}\n' + '\n'.join(ids) + '\n')
    print(f'{proj}: 번호 {len(ids)}개 ({", ".join(ids[:4])} … {ids[-1] if ids else ""})')
