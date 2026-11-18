#!/usr/bin/env python3
"""저장 공간 정리 후보를 찾는다(읽기만 한다). 4n5rud-cleanup 스킬이 부른다.

후보 묶음
  1 installer   다운로드의 설치 파일(dmg, pkg)
  2 duplicate   다운로드의 중복 받은 파일("(1)", " 2" 꼴)
  3 appbuild    다운로드와 데스크탑(작업 폴더 밖)의 앱 빌드 산출물(apk, aab, ipa, 앱 빌드 zip)
  4 video       다운로드와 데스크탑의 화면 녹화와 영상(mov, mp4), 14일 넘은 것
  5 bigdata     다운로드의 큰 압축과 데이터 파일(zip, gz, json, csv 등 50MB 넘음), 30일 넘은 것
  6 mockup      작업 폴더(WORK_DIR) 저장소 안의 커밋되지 않은 목업, 캡처, 비교본(14일 넘은 것)
지우지 않는 곳: git으로 추적되는 파일, _수신함, _발신함, _비밀, _할일, 비밀값 파일, 캐시 폴더.
결과: ~/.claude/harness/cleanup/last-scan.tsv (번호, 묶음, 크기KB, 수정일, 경로)와 화면 요약.
쓰는 법: cleanup-scan.py [--days-mockup 14] [--days-video 14] [--days-data 30]
"""
import os, re, sys, subprocess, time, argparse, collections

HOME = os.path.expanduser('~')
ap = argparse.ArgumentParser()
ap.add_argument('--days-mockup', type=int, default=14)
ap.add_argument('--days-video', type=int, default=14)
ap.add_argument('--days-data', type=int, default=30)
a = ap.parse_args()

def conf_work_dir():
    p = os.path.join(HOME, '.claude/harness.conf'); w = os.path.join(HOME, 'Desktop/work')
    try:
        for line in open(p, encoding='utf-8'):
            m = re.match(r'\s*WORK_DIR="?([^"\n]+)"?', line)
            if m: w = m.group(1).replace('$HOME', HOME)
    except OSError: pass
    return w
WORK = conf_work_dir()
DL = os.path.join(HOME, 'Downloads'); DESK = os.path.join(HOME, 'Desktop')
now = time.time(); day = 86400
NEVER = re.compile(r'(^|/)(_수신함|_발신함|_비밀|_할일|\.git|node_modules|\.dart_tool|\.next|build|Pods|\.gradle|\.venv)(/|$)')
SECRET = re.compile(r'(\.env($|\.)|\.pem$|\.p12$|\.p8$|\.key$|\.keystore$|\.jks$|key\.properties$|service-account.*\.json$|GoogleService-Info\.plist$|google-services\.json$)', re.I)
rows = []
def add(group, path):
    try: st = os.stat(path)
    except OSError: return
    if SECRET.search(path): return
    rows.append((group, st.st_size // 1024, st.st_mtime, path))
def age(p):
    try: return (now - os.stat(p).st_mtime) / day
    except OSError: return 0

def walk(root, maxdepth):
    root = root.rstrip('/'); base = root.count('/')
    for d, dirs, files in os.walk(root):
        if d.count('/') - base >= maxdepth: dirs[:] = []
        dirs[:] = [x for x in dirs if not x.startswith('.') and not NEVER.search(os.path.join(d, x))]
        if os.path.abspath(d).startswith(os.path.abspath(WORK)): dirs[:] = []; continue
        for f in files:
            if not f.startswith('.'): yield os.path.join(d, f)

DUP = re.compile(r'( \(\d+\)| \d+)(\.[^.]+)?$')
for p in walk(DL, 3):
    n = os.path.basename(p); low = n.lower(); ext = low.rsplit('.', 1)[-1] if '.' in low else ''
    if os.path.dirname(p) == DL and ext in ('dmg', 'pkg'): add('installer', p); continue
    if os.path.dirname(p) == DL and DUP.search(os.path.splitext(n)[0] + os.path.splitext(n)[1]) and re.search(r' \(\d+\)\.|\(\d+\)$| \d+\.[^.]+$', n):
        base = re.sub(r' \(\d+\)(?=\.[^.]+$)| \d+(?=\.[^.]+$)', '', n)
        if base != n and os.path.exists(os.path.join(DL, base)): add('duplicate', p); continue
    if ext in ('apk', 'aab', 'ipa'): add('appbuild', p); continue
    if ext in ('mov', 'mp4', 'm4v') and age(p) > a.days_video: add('video', p); continue
    if ext in ('zip', 'gz', 'tgz', '7z', 'rar', 'json', 'csv', 'tar') and os.path.getsize(p) > 50 * 1024 * 1024 and age(p) > a.days_data: add('bigdata', p)
for p in walk(DESK, 3):
    low = p.lower(); ext = low.rsplit('.', 1)[-1] if '.' in low else ''
    if ext in ('apk', 'aab', 'ipa'): add('appbuild', p)
    elif ext in ('mov', 'mp4', 'm4v') and age(p) > a.days_video: add('video', p)

# 6. 작업 폴더 저장소의 커밋되지 않은 목업, 캡처, 비교본
MOCK_PATH = re.compile(r'(목업|mockup|mock-up|shots?|캡처|스크린샷|screenshot|비교|compare|chk_|before|after|_전|_후|시안|레퍼런스|reference)', re.I)
MOCK_EXT = ('png', 'jpg', 'jpeg', 'webp', 'gif', 'html', 'pdf', 'mp4', 'mov')
repos = set()
for d, dirs, files in os.walk(WORK):
    if d.count('/') - WORK.count('/') > 4: dirs[:] = []; continue
    if '.git' in dirs or '.git' in files:
        repos.add(d)
    dirs[:] = [x for x in dirs if x not in ('node_modules', '.git', 'build', '.dart_tool', '.next', 'Pods', '.gradle', '.venv')]
seen = set()
for r in sorted(repos):
    try:
        out = subprocess.run(['git', '-C', r, 'ls-files', '--others', '-z'], capture_output=True, timeout=60).stdout
    except Exception: continue
    for rel in out.decode('utf-8', 'ignore').split('\0'):
        if not rel: continue
        p = os.path.join(r, rel)
        if p in seen or NEVER.search(rel) or SECRET.search(rel): continue
        seen.add(p)
        ext = rel.lower().rsplit('.', 1)[-1] if '.' in rel else ''
        if ext in MOCK_EXT and MOCK_PATH.search(rel) and age(p) > a.days_mockup and os.path.isfile(p):
            add('mockup', p)

out_dir = os.path.join(HOME, '.claude/harness/cleanup'); os.makedirs(out_dir, exist_ok=True)
rows.sort(key=lambda x: (x[0], -x[1]))
with open(os.path.join(out_dir, 'last-scan.tsv'), 'w', encoding='utf-8') as f:
    for i, (g, kb, mt, p) in enumerate(rows, 1):
        f.write(f"{i}\t{g}\t{kb}\t{time.strftime('%Y-%m-%d', time.localtime(mt))}\t{p}\n")

NAME = {'installer': '1 설치 파일(다운로드)', 'duplicate': '2 중복 받은 파일(다운로드)', 'appbuild': '3 앱 빌드 산출물(apk, aab, ipa)',
        'video': '4 화면 녹화와 영상', 'bigdata': '5 큰 압축, 데이터 파일(다운로드)', 'mockup': '6 지난 목업, 캡처, 비교본(커밋 안 된 것)'}
tot = collections.defaultdict(lambda: [0, 0]); sub = collections.defaultdict(lambda: [0, 0])
for g, kb, mt, p in rows:
    tot[g][0] += kb; tot[g][1] += 1
    if g == 'mockup':
        rel = os.path.relpath(p, WORK).split('/'); key = '/'.join(rel[:2])
    else:
        key = os.path.relpath(os.path.dirname(p), HOME)
    sub[(g, key)][0] += kb; sub[(g, key)][1] += 1
for g in ['installer', 'duplicate', 'appbuild', 'video', 'bigdata', 'mockup']:
    if g not in tot: continue
    print(f"{NAME[g]}: {tot[g][0]/1048576:.1f}GB, {tot[g][1]}개")
    for (gg, k), (kb, c) in sorted(sub.items(), key=lambda x: -x[1][0]):
        if gg == g: print(f"    {kb/1024:8.0f}MB {c:4d}개  {k}")
print(f"합계: {sum(v[0] for v in tot.values())/1048576:.1f}GB, 목록: ~/.claude/harness/cleanup/last-scan.tsv")
