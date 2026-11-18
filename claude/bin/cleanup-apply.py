#!/usr/bin/env python3
"""cleanup-scan.py 가 만든 목록에서 고른 것만 지운다. 4n5rud-cleanup 스킬이 사용자 확인을 받은 뒤 부른다.

쓰는 법:
  cleanup-apply.py --groups installer,duplicate          묶음 단위
  cleanup-apply.py --ids 3,7,12-20                       번호 단위
  cleanup-apply.py --groups appbuild --keep-latest       앱마다 가장 최근 산출물 하나는 남김
  --trash (기본): 휴지통으로 옮김(되살릴 수 있음, 휴지통을 비워야 공간이 생김)
  --rm: 바로 지움(되살릴 수 없음)
  --dry: 무엇을 지울지만 보여 줌
지우기 직전에 다시 확인: 파일이 아직 있고, 목록의 크기와 같고, git으로 추적되지 않는지.
"""
import os, sys, re, time, shutil, argparse, subprocess, collections

HOME = os.path.expanduser('~'); LIST = os.path.join(HOME, '.claude/harness/cleanup/last-scan.tsv')
ap = argparse.ArgumentParser()
ap.add_argument('--groups', default=''); ap.add_argument('--ids', default='')
ap.add_argument('--keep-latest', action='store_true'); ap.add_argument('--rm', action='store_true'); ap.add_argument('--dry', action='store_true')
a = ap.parse_args()
rows = [l.rstrip('\n').split('\t') for l in open(LIST, encoding='utf-8') if l.strip()]
if time.time() - os.stat(LIST).st_mtime > 6 * 3600: sys.exit('목록이 6시간 넘게 지났습니다. cleanup-scan.py 를 다시 돌리세요.')
ids = set()
for part in filter(None, a.ids.split(',')):
    if '-' in part: x, y = part.split('-'); ids.update(range(int(x), int(y) + 1))
    else: ids.add(int(part))
groups = set(filter(None, a.groups.split(',')))
pick = [r for r in rows if int(r[0]) in ids or r[1] in groups]
if a.keep_latest:
    def app_key(p):
        n = os.path.basename(p).lower()
        n = re.sub(r'[\s_\-(]*v?\d+([.\-+_()]\d+)*[)\s]*', '-', n)
        return (os.path.dirname(os.path.dirname(p)) if 'builds' in p else os.path.dirname(p), re.sub(r'-+', '-', n))
    newest = {}
    for r in pick:
        if r[1] != 'appbuild': continue
        k = app_key(r[4]); t = os.path.getmtime(r[4]) if os.path.exists(r[4]) else 0
        if k not in newest or t > newest[k][0]: newest[k] = (t, r[0])
    keep = {v[1] for v in newest.values()}; pick = [r for r in pick if r[0] not in keep]

def tracked(p):
    d = os.path.dirname(p)
    try:
        r = subprocess.run(['git', '-C', d, 'ls-files', '--error-unmatch', os.path.basename(p)], capture_output=True, timeout=20)
        return r.returncode == 0
    except Exception: return False

freed = 0; done = 0; skipped = []
TRASH = os.path.join(HOME, '.Trash')
for no, g, kb, day, p in pick:
    if not os.path.isfile(p): skipped.append((p, '없음')); continue
    if abs(os.path.getsize(p) // 1024 - int(kb)) > 1: skipped.append((p, '크기가 바뀜')); continue
    if tracked(p): skipped.append((p, 'git으로 추적됨')); continue
    if a.dry: print(f"[지울 예정] {int(kb)/1024:.0f}MB  {p}"); freed += int(kb); done += 1; continue
    try:
        if a.rm: os.remove(p)
        else:
            dst = os.path.join(TRASH, os.path.basename(p))
            if os.path.exists(dst): dst = os.path.join(TRASH, f"{time.strftime('%H%M%S')}_{os.path.basename(p)}")
            shutil.move(p, dst)
        freed += int(kb); done += 1
    except OSError as e: skipped.append((p, str(e)))
how = '지울 예정' if a.dry else ('지움' if a.rm else '휴지통으로 옮김')
print(f"{how}: {done}개, {freed/1048576:.2f}GB")
for p, why in skipped[:20]: print(f"  건너뜀({why}): {p}")
if not a.rm and not a.dry and done: print("휴지통을 비워야 공간이 생깁니다.")
