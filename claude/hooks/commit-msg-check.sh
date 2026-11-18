#!/usr/bin/env bash
# 커밋 메시지 검사 (지침서 09 커밋 메시지 규칙). 규칙은 이 파일 한 곳에만 둔다.
#   commit-msg-check.sh <메시지 파일>   문제가 있으면 이유를 stderr에 쓰고 1로 끝난다(경고는 0으로 끝남)
# 부르는 곳: 전역 git 훅 _dispatch 의 commit-msg(Claude 세션이면 막고, 사람이 친 커밋이면 경고만),
#            commit-lint.sh(커밋 명령을 치기 전에 미리 알려 줌)
# 범위 목록: 저장소 맨 위 .commit-scopes 가 있으면 그 목록만, 없으면 이 저장소가 최근 커밋에서 두 번 이상 쓴 범위.
msg_file="${1:?메시지 파일이 필요합니다}"
top=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
history=$(git log --all -n 500 --no-merges --format=%s 2>/dev/null || true)
# 범위 목록 파일: 저장소의 .commit-scopes, 없으면 이 Mac의 ~/.claude/harness/commit-scopes/<저장소 폴더 이름>(저장소를 건드리지 않고 정할 때)
scopes_file=""
for f in "$top/.commit-scopes" "$HOME/.claude/harness/commit-scopes/${top##*/}"; do [[ -f "$f" ]] && { scopes_file="$f"; break; }; done
# WBS 번호 목록: WORK_DIR 아래 프로젝트 폴더마다 ~/.claude/harness/commit-wbs/<프로젝트 폴더>.txt (wbs-ids.py 가 만듦).
# 목록이 있는 프로젝트의 저장소(서브모듈, 다른 곳에 만든 작업 폴더 포함)는 모든 커밋 제목 끝에 [WBS : 번호]가 필요하다.
wbs_file="${COMMIT_WBS_FILE:-}"
if [[ -z "$wbs_file" ]]; then
  WORK_DIR="$HOME/Desktop/work"; CONF="${HARNESS_CONF:-$HOME/.claude/harness.conf}"
  [[ -f "$CONF" ]] && eval "$(grep -E '^WORK_DIR=' "$CONF" 2>/dev/null)"
  wd=$(cd "$WORK_DIR" 2>/dev/null && pwd -P)
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); common=$(cd "${common:-.}" 2>/dev/null && pwd -P)
  sup=$(git rev-parse --show-superproject-working-tree 2>/dev/null)
  for p in "$(cd "$top" && pwd -P)" "$common" "$sup"; do
    [[ -n "$wd" && -n "$p" && "$p" == "$wd"/* ]] || continue
    proj="${p#"$wd"/}"; proj="${proj%%/*}"
    [[ -f "$HOME/.claude/harness/commit-wbs/$proj.txt" ]] && { wbs_file="$HOME/.claude/harness/commit-wbs/$proj.txt"; break; }
  done
fi

prev_progress=""
[[ -n "$wbs_file" ]] && prev_progress=$(git log -n 300 --format='%(trailers:key=WBS-Progress)' 2>/dev/null | grep -v '^$' || true)

MSG_FILE="$msg_file" HIST="$history" SCOPES_FILE="$scopes_file" WBS_FILE="$wbs_file" PREV_PROGRESS="$prev_progress" perl -CSDA -Mutf8 -e '
use strict; use warnings; use Encode qw(decode_utf8);
open my $fh, "<:encoding(UTF-8)", $ENV{MSG_FILE} or exit 0;
my @lines = grep { !/^#/ } <$fh>; close $fh;
my ($subj) = grep { /\S/ } @lines; exit 0 unless defined $subj;
chomp $subj; $subj =~ s/\s+$//;
exit 0 if $subj =~ /^(fixup! |squash! |amend! )/;

# WBS 번호: 제목 끝의 [WBS : 1.1.1] 꼴(여러 개는 쉼표). 떼어 낸 뒤 나머지 규칙을 검사한다.
my $full = $subj; my @wbs_err; my @ids;
my $ID = qr/[A-Z]?\d+(?:\.\d+)+/;
if ($subj =~ s/\s*\[\s*WBS\s*:\s*($ID(?:\s*,\s*$ID)*)\s*\]$//) { @ids = split /\s*,\s*/, $1; }
elsif ($full =~ /\[\s*WBS/i) { push @wbs_err, "WBS 표기 모양이 틀림. 제목 끝에 [WBS : 1.1.1] 꼴로 씀(여러 개는 [WBS : 1.1.1, 1.2.3])"; }
if ($ENV{WBS_FILE}) {
  open my $w, "<:encoding(UTF-8)", $ENV{WBS_FILE}; my %valid;
  for (<$w>) { next if /^#/; s/\s+//g; $valid{$_} = 1 if length } close $w;
  if (!@ids && !@wbs_err) {
    push @wbs_err, "이 프로젝트는 모든 커밋이 WBS 작업 하나에 속해야 함. 제목 끝에 [WBS : 번호]를 붙임(서브모듈 포인터, 머지, 문서 커밋도 마찬가지). 번호 목록: $ENV{WBS_FILE}";
  } elsif (%valid) {
    my @bad = grep { !$valid{$_} } @ids;
    push @wbs_err, "WBS에 없는 번호: " . join(", ", @bad) . ". 번호를 확인하거나, WBS가 바뀌었으면 사용자에게 알리고 목록을 다시 뽑음(python3 ~/.claude/bin/wbs-ids.py)" if @bad;
  }
  # 진행도 꼬리: 제목의 번호마다 "WBS-Progress: <번호> <0~100>%" 한 줄
  if (@ids) {
    my %prog; my @badline;
    for (@lines) {
      next unless /^WBS-Progress\s*:/i;
      if (/^WBS-Progress:\s*($ID)\s+(\d{1,3})%\s*$/) { if ($2 > 100) { push @badline, $_ } else { $prog{$1} = $2 } }
      else { chomp; push @badline, $_ }
    }
    push @wbs_err, "진행도 줄 모양이 틀림: " . join(" / ", @badline) . ". \"WBS-Progress: 1.1.1 60%\" 꼴(0~100 정수와 %)" if @badline;
    my %in = map { $_ => 1 } @ids;
    my @miss = grep { !exists $prog{$_} } @ids;
    my @extra = grep { !$in{$_} } keys %prog;
    push @wbs_err, "제목의 WBS 번호마다 진행도 꼬리가 필요함(빠진 번호: " . join(", ", @miss) . "). 본문 맨 아래에 \"WBS-Progress: <번호> <0~100>%\" 줄을 번호마다 씀" if @miss;
    push @wbs_err, "진행도 줄의 번호가 제목에 없음: " . join(", ", @extra) if @extra;
    # 지난 커밋보다 진행도가 내려가면 경고만(되돌리는 일이 있을 수 있음)
    my %last;
    for (split /\n/, decode_utf8($ENV{PREV_PROGRESS} // "")) { $last{$1} //= $2 if /^WBS-Progress:\s*($ID)\s+(\d{1,3})%/ }
    our @wbs_warn = map { "WBS $_ 진행도가 지난 커밋($last{$_}%)보다 내려감($prog{$_}%). 이유가 있으면 본문에 적음" } grep { exists $last{$_} && $prog{$_} < $last{$_} } keys %prog;
  }
}
if ($subj =~ /^(Merge |merge: |Revert ")/) {   # 머지와 되돌리기 문구는 WBS만 본다
  if (@wbs_err) { print STDERR "제목: $full\n"; print STDERR "- $_\n" for @wbs_err; exit 1 }
  exit 0;
}

my @hist = split /\n/, decode_utf8($ENV{HIST} // "");
my %std = map { $_ => 1 } qw(feat fix refactor style perf test docs chore revert merge build ci);
my (%type_n, %scope_n, $conv, $hangul);
for (@hist) {
  if (/^([a-z]+)(?:\(([^)]+)\))?!?:\s/) { $type_n{$1}++; $scope_n{$2}++ if defined $2; $conv++ }
  $hangul++ if /\p{Hangul}/;
}
my @err = @wbs_err; our @wbs_warn; my @warn = @wbs_warn;

# 팀 관례 접두사([REFACTOR]: 꼴)는 종류와 범위 검사를 하지 않는다
my $team = $subj =~ /^\[[A-Z]+\]:\s/;
my ($type, $scope, $body);
if ($team) { ($body = $subj) =~ s/^\[[A-Z]+\]:\s*//; }
elsif ($subj =~ /^([^\s:(]+)(?:\(([^)]*)\))?(!)?:\s*(.*)$/) {
  ($type, $scope, $body) = ($1, $2, $4);
  my %ok = (%std, map { $_ => 1 } grep { $type_n{$_} >= 3 } keys %type_n);   # 저장소가 꾸준히 쓰는 접두사(ops: 등)
  push @err, "종류 \"$type\"는 쓰지 않음. feat, fix, refactor, style, perf, test, docs, chore, revert, build, ci 가운데 고름" unless $ok{$type};
  if (defined $scope) {
    if ($scope !~ /^[a-z][a-z0-9-]*$/) {
      push @err, "범위 \"$scope\"는 영어 소문자 한 낱말로 씀(하이픈 허용). 한글, 대문자, 띄어쓰기, 쉼표는 쓰지 않음";
    } else {
      my %allowed; my $src;
      if ($ENV{SCOPES_FILE}) {
        open my $s, "<:encoding(UTF-8)", $ENV{SCOPES_FILE};
        for (<$s>) { s/#.*//; s/\s+//g; $allowed{$_} = 1 if length } close $s; $src = "범위 목록 파일";
      } elsif (keys(%scope_n) && ($conv // 0) >= 30) {
        %allowed = map { $_ => 1 } grep { $scope_n{$_} >= 2 && /^[a-z][a-z0-9-]*$/ } keys %scope_n; $src = "이 저장소의 최근 커밋";
      }
      # 같은 뜻의 이름이 둘이면(단수와 복수, 줄임말) 더 많이 쓴 쪽만 허용
      my %alias = (be => "backend", fe => "frontend", err => "errors", cfg => "config", doc => "docs", deps => "deps");
      my @twins = grep { $_ ne $scope && ($scope_n{$_} // 0) > ($scope_n{$scope} // 0) }
                  ("${scope}s", ($scope =~ /^(.+)s$/ ? $1 : ()), ($alias{$scope} // ()), (grep { ($alias{$_} // "") eq $scope } keys %alias));
      if (@twins && !$ENV{SCOPES_FILE}) {
        push @err, "범위 \"$scope\" 대신 이 저장소에서 더 많이 쓴 \"$twins[0]\"를 씀(같은 뜻의 이름을 둘로 쓰지 않음)";
      } elsif ($src && !$allowed{$scope}) {
        my @top = (sort { $scope_n{$b} <=> $scope_n{$a} } grep { $allowed{$_} } keys %allowed)[0..11];
        @top = grep { defined } @top; @top = sort keys %allowed unless @top;
        push @err, "범위 \"$scope\"는 ${src}에 없는 새 범위임. 있는 범위에서 고르거나(" . join(", ", @top) . ") 범위를 빼고 씀. 정말 새 영역이면 사용자에게 묻고 범위 목록 파일(저장소의 .commit-scopes 또는 ~/.claude/harness/commit-scopes/<저장소 폴더 이름>)에 먼저 적음";
      }
    }
  }
} else {
  push @err, "접두사가 없음. <종류>(<범위>): <한 문장> 꼴로 씀";
  $body = $subj;
}
$body //= "";

push @err, "가운뎃점, 엠대시, 꺾쇠 괄호, 겹화살괄호, 화살표는 쓰지 않음" if $subj =~ /[·—–「」『』«»→←⇒]/;
push @err, "이슈 번호는 제목에 넣지 않고 맨 아래 꼬리에 refs #번호로 붙임" if $subj =~ /#\d+/;
push @err, "끝에 마침표를 붙이지 않음" if $body =~ /[.。]$/;
push @err, "쉼표로 여러 변경을 이었음. 한 커밋에 한 가지만 담고 나머지는 커밋을 나눔" if ($body =~ tr/,//) >= 2;
my $n = length $body;
if ($n > 60) { push @err, "제목이 너무 김(${n}자). 40자 안팎으로 줄이거나 커밋을 나눔" }
elsif ($n > 50) { push @warn, "제목이 김(${n}자). 40자 안팎을 권함" }
my $korean_repo = !@hist || ($hangul // 0) * 2 >= @hist;
if ($korean_repo && $body ne "") {
  my $last = substr($body, -1); my $o = ord $last;
  my $jong = ($o - 0xAC00) % 28;   # 16: ㅁ(함, 음, 임, 됨), 10: ㄻ(만듦, 줆처럼 ㄹ 받침 용언)
  my $ends_m = ($o >= 0xAC00 && $o <= 0xD7A3 && ($jong == 16 || $jong == 10));
  push @err, "한국어 문장으로 씀" unless $body =~ /\p{Hangul}/;
  push @err, "음슴체로 끝냄(~함, ~음, ~임, ~됨). 예: 숨김, 고침, 더함, 바꿈" if $body =~ /\p{Hangul}/ && !$ends_m;
  push @err, "무엇이 어떻게 달라졌는지 씀. \"수정함\", \"정리함\", \"반영함\", \"개선함\"만으로 끝내지 않음"
    if $body =~ /^\S{0,8}\s?(리뷰\s?)?(수정|정리|반영|개선|변경|업데이트|작업)(함|됨)$/;
}
if (@err || @warn) {
  print STDERR "제목: $full\n";
  print STDERR "- $_\n" for @err, @warn;
}
exit(@err ? 1 : 0);
'
