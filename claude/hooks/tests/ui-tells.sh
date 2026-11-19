#!/usr/bin/env bash
# Tests for ui-tells.py (screen copy and decoration counter, guide 21). Checks per-rule counts on small fixtures.
U="${UI_TELLS:-$HOME/.claude/bin/ui-tells.py}"; pass=0; fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/ko" "$T/dart" "$T/clean" "$T/skip/__tests__"

cat > "$T/ko/Home.tsx" <<'EOF'
export function Home({ isNew }) {
  return (<div>
    <p className="text-xs uppercase tracking-widest">OVERVIEW</p>
    <p>아래 버튼을 눌러 시작하세요</p>
    <p>이 카드는 이번 달 매출을 보여 줍니다 (실시간 반영)</p>
    <h2>막대 그래프로 본 월별 매출</h2>
    <p>각 막대는 한 달을 나타냅니다. 마우스를 올리면 값이 보입니다.</p>
    <span className="badge">신규</span>
    <p>앗! 불러오지 못했어요</p>
  </div>);
}
EOF
cat > "$T/dart/home.dart" <<'EOF'
// 이 화면은 홈을 보여 줍니다 (주석이라 세지 않음)
final term = code.substring(2, 4) == '01' ? '1' : '2';
final shadow = BoxShadow(shadowColor: Color(0x26000000));
Text('🚀 시작하기'),
EOF
printf "debugPrint('📤 Request — body');\n" > "$T/dart/app_logger.dart"
cat > "$T/clean/Members.tsx" <<'EOF'
export function Members({ rows }) {
  return (<section><h1>구성원</h1>
    <label htmlFor="q">이름</label><input id="q" placeholder="홍길동" />
    <button aria-label="구성원 추가"><PlusIcon /></button>
    {rows.map((r) => <p key={r.id}>{r.name}</p>)}</section>);
}
EOF
printf '<p>🚀 시작</p>\n' > "$T/skip/__tests__/a.tsx"; printf '<p>🚀 시작</p>\n' > "$T/skip/b.test.tsx"

# n <name> <target> <rule> <expected count>
n() { local got; got=$(python3 -I "$U" "$2" | python3 -I -c 'import json,sys; d=json.load(sys.stdin)[sys.argv[1]]; print(d if isinstance(d, int) else d["count"])' "$3")
  if [[ "$got" == "$4" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: $3 expect=$4 got=$got"; fi; }
n eyebrow          "$T/ko"    "U1 eyebrow" 1
n botsplain_ko     "$T/ko"    "U4 설명 문구(한국어)" 3
n design_note_ko   "$T/ko"    "U5 설계 메모(한국어)" 1
n badge_ko         "$T/ko"    "U9 badge word" 1
n chart_title_ko   "$T/ko"    "U12 그래프 종류 제목(한국어)" 1
n reading_ko       "$T/ko"    "U13 읽는 법 안내(한국어)" 1
n dart_emoji       "$T/dart"  "U11 emoji" 1
n dart_no_number   "$T/dart"  "U2 decorative numbering" 0
n dart_no_chart    "$T/dart"  "U15 chart scaffolding" 0
n dart_comment     "$T/dart"  "U4 설명 문구(한국어)" 0
n logger_skipped   "$T/dart"  "unslop 13 em dash" 0
n clean_screen     "$T/clean" "total" 0
n tests_skipped    "$T/skip"  "total" 0
echo "통과 $pass / 실패 $fail"; (( fail == 0 ))
