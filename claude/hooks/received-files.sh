#!/usr/bin/env bash
# UserPromptSubmit hook (claude-work-harness): when the user drops files from outside the repo
# (Downloads, Desktop, temp folders...) into the prompt, remind the model to file them under
# _수신함/ and to never write absolute paths (지침서 12 받은 자료 정리).
# Conversation screenshots (paste images, screen captures) are ignored. Never blocks.
input=$(cat)
prompt=$(jq -r '.prompt // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -n "$prompt" ]] || exit 0
# system notifications (background task results, cross-session messages) are not user hand-offs
grep -qE '<task-notification>|\[SYSTEM NOTIFICATION|<cross-session-message' <<<"$prompt" && exit 0
CONF="${HARNESS_CONF:-$HOME/.claude/harness.conf}"; WORK_DIR=""
[[ -f "$CONF" ]] && source "$CONF"
top=$(git -C "${cwd:-.}" rev-parse --show-toplevel 2>/dev/null)

found=$(PROMPT="$prompt" TOP="$top" HOMEDIR="$HOME" WORKDIR="$WORK_DIR" perl -CSDA -Mutf8 -e '
  use Encode qw(decode_utf8);
  my $p = decode_utf8($ENV{PROMPT}); my $top = decode_utf8($ENV{TOP} // ""); my $home = decode_utf8($ENV{HOMEDIR}); my $work = decode_utf8($ENV{WORKDIR} // "");
  my %seen; my @out;
  # absolute or ~ paths; "\ " (escaped space from drag and drop) stays part of the path
  while ($p =~ m{((?:~|/Users/[^/\s]+|/home/[^/\s]+|/private/var/folders|/var/folders|/private/tmp|/tmp)(?:/(?:\\\s|[^\s"\x27<>|])+)+)}g) {
    my $path = $1; $path =~ s/\\(\s)/$1/g; $path =~ s/[.,)\]]+$//;
    (my $abs = $path) =~ s{^~}{$home};
    (my $na = $abs) =~ s{^/private/}{/}; (my $nt = $top) =~ s{^/private/}{/};   # /var and /private/var are the same place
    next if $nt ne "" && index($na, "$nt/") == 0;                          # already inside this repo
    next if $abs =~ m{/\.claude/|/\.claude-config\.git|/\.omc/};             # harness and tool files
    next if $abs =~ m{^(/private)?/tmp/claude-};                            # Claude scratch and task output
    (my $nw = $work) =~ s{^/private/}{/};
    next if $nw ne "" && index($na, "$nw/") == 0;                          # files of other project repos are not hand-offs
    next if $abs =~ m{orca-paste-|/(Screenshot|Screen Shot|스크린샷|화면 캡처)[^/]*$|/TemporaryItems/}i;  # chat screenshots
    next unless $abs =~ m{\.[A-Za-z0-9]{1,6}$} || -d $abs;                  # looks like a file or an existing folder
    push @out, $path unless $seen{$path}++;
  }
  print join("\n", @out[0..($#out < 4 ? $#out : 4)]) if @out;
')
[[ -n "$found" ]] || exit 0

where="이 세션의 저장소"; [[ -n "$top" ]] && where="저장소 루트(${top##*/})"
ctx="사용자가 저장소 밖의 파일을 넘겼다. 지침서 \"12 받은 자료 정리\"대로 처리한다.
- ${where}의 _수신함/<YYYY-MM-DD>_<출처>_<내용>/ 으로 복사한다(원본은 옮기거나 지우지 않는다). 출처는 카톡, 메일, 슬랙, 드라이브, 미팅, 통화, 기타 중 하나.
- 🔴 넣기 전에 보안 정보 이중 확인(지침서 12 §2 3번):
  1) 저장소 밖 임시 폴더(스크래치패드)에 복사하고, 압축 파일(zip, tar, 7z, rar)은 거기서 푼다.
  2) 1차: ~/.claude/hooks/secret-scan.sh path <임시 폴더> 로 검사한다. 걸린 값은 secret-scan.sh mask <임시 폴더> 로 <가림> 처리하고, 이름부터 비밀인 파일(.env, 키, 인증서)은 빼서 _수신함/_비밀/ 에 둔다.
  3) 2차: 다시 path 로 검사해 깨끗한지 보고, 남은 파일을 직접 훑어 계좌번호, 주민번호, 전화번호, 비밀번호 같은 개인정보와 보안 정보가 없는지 본다. 있으면 가린다.
  4) 그다음 자료 폴더로 옮긴다. 압축 파일 원본은 자료 폴더에 넣지 않고 _수신함/_비밀/ 에만 둔다(압축 파일은 _수신함, _발신함에서 커밋 금지).
- 키, 인증서, 서비스 계정 JSON, tfvars, .env, 가리기 전 원본은 _수신함/_비밀/, 50MB 넘는 파일은 _수신함/_대용량/ (둘 다 커밋 금지, .gitignore).
- _수신함/목록.md 에 한 줄 적고, 문서에는 저장소 기준 상대 경로로만 적는다. 저장소에 남는 글에는 절대 경로를 쓰지 않는다(지침서 12 §3).
- 이 작업과 함께 커밋한다(키 섞임 검사 뒤).
넘겨받은 경로:
$found"
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
