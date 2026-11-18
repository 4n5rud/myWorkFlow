#!/usr/bin/env bash
# PreToolUse(Bash) hook: 커밋 명령을 치기 전에 제목을 지침서 09 규칙으로 미리 알려 준다(경고만).
# 규칙은 commit-msg-check.sh 한 곳에 있고, 실제로 막는 것은 전역 git 훅의 commit-msg 단계다.
input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
[[ "$cmd" =~ git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+commit([[:space:]]|$) ]] || exit 0
[[ "$cmd" =~ --amend[[:space:]]+--no-edit ]] && exit 0
CHK="${COMMIT_MSG_CHECK:-$HOME/.claude/hooks/commit-msg-check.sh}"
[[ -x "$CHK" ]] || exit 0

msg=$(CMD="$cmd" perl -CSDA -Mutf8 -e '
  use Encode qw(decode_utf8); my $c = decode_utf8($ENV{CMD});
  if ($c =~ /-m\s+"\$\(cat\s+<<-?\s*[\x27"]?(\w+)[\x27"]?\s*\n(.*?)\n\s*\1\b/s) { print $2; exit }   # heredoc
  my @parts;   # -m 을 여러 번 쓰면 문단으로 이어 붙인다(git 과 같음)
  while ($c =~ /-m\s+(?:"((?:[^"\\]|\\.)*)"|\x27([^\x27]*)\x27|(\S+))/gs) { push @parts, defined $1 ? $1 : defined $2 ? $2 : $3 }
  print join("\n\n", @parts) if @parts;')
[[ -n "$msg" ]] || exit 0

dir=$(pwd)
[[ "$cmd" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]] && dir="${BASH_REMATCH[1]/#\~/$HOME}"
dir="${dir//\"/}"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$msg" > "$tmp"
out=$(cd "$dir" 2>/dev/null && "$CHK" "$tmp" 2>&1) && [[ -z "$out" ]] && exit 0
[[ -n "$out" ]] || exit 0
ctx="커밋 메시지가 지침서 09 커밋 메시지 규칙과 다릅니다. Claude 세션의 커밋은 git 훅이 막으니, 제목을 고친 뒤 커밋하세요.
$out"
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
