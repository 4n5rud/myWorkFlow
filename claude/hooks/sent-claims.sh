#!/usr/bin/env bash
# PreToolUse(Edit|Write|MultiEdit) hook (claude-work-harness): when a document is about to say that something
# was sent ("전달함", "발송함", "회신 대기"...), remind the model that only the user sends, and that "sent"
# needs the user's own confirmation (지침서 13 보낼 문서와 발송 상태). Warn only, never blocks.
input=$(cat)
path=$(jq -r '.tool_input.file_path // empty' <<<"$input")

# Work products never live in the session's temporary folder (2026-11-13 사용자 지시: 세션이 끊기면 사라지고, 중간에
#들어가 보기 어렵다). Documents to hand over (html, pdf, office files) are refused there; notes and drafts get a reminder.
# They go to the project's _작업/ (outgoing documents to _발신함/). Scripts, specs and screenshots for a tool run may
# stay in the temporary folder.
if [[ "$path" =~ ^(/private)?/tmp/claude-[^/]+/.*/scratchpad/ || "$path" =~ ^(/private)?/var/folders/.*/claude- ]]; then
  where="프로젝트 문서 저장소의 _작업/ (보낼 문서는 _발신함/<날짜>_<받는 곳>_<내용>/)"
  if [[ "$path" =~ \.(html?|pdf|docx|xlsx|pptx|hwp|key|numbers|pages)$ ]]; then
    jq -n --arg r "작업 산출물(보고서, 설계서, 목업, 요청서 같은 HTML, PDF, 문서 파일)은 세션 임시 폴더에 만들지 않는다. 세션이 끊기면 사라지고 사용자가 중간에 열어 볼 수 없다. ${where}에 만든다. 보내기 전 초안이어도 여기에 둔다. 그 저장소가 _작업/을 커밋하거나 자동으로 올리는 곳이면 .gitignore에 _작업/을 넣어 원격에 올라가지 않게 한다." \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
  fi
  if [[ "$path" =~ \.(md|markdown|txt|csv)$ ]]; then
    jq -n --arg c "이 파일이 사용자가 볼 초안이나 정리 문서라면 세션 임시 폴더가 아니라 ${where}에 둔다. 도구를 돌리려고 잠깐 쓰는 파일이면 그대로 둬도 된다." \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
    exit 0
  fi
fi

# documents only (code, config and logs are not checked)
[[ "$path" =~ \.(md|markdown|txt|html?|csv|json)$ ]] || exit 0
[[ "$path" =~ /\.claude/ ]] && exit 0
text=$(jq -r '[.tool_input.content, .tool_input.new_string, (.tool_input.edits // [] | .[]?.new_string)] | map(select(. != null)) | join("\n")' <<<"$input")
[[ -n "$text" ]] || exit 0

hits=$(TEXT="$text" perl -CSDA -Mutf8 -e '
  use Encode qw(decode_utf8); my $t = decode_utf8($ENV{TEXT}); my %s; my @o;
  my $re = qr/(회신\s*대기|회신을\s*기다|답변\s*대기|답을\s*기다|전달\s*(했|함|완료|드렸)|발송\s*(했|함|완료)|보냈(습니다|음|어요|다)|송부\s*(했|함|완료)|요청\s*드렸|요청드림|문의\s*(했|드렸|함)|공유\s*(드렸|했음))/;
  for my $line (split /\n/, $t) {
    next unless $line =~ $re;
    next if $line =~ /발송\s*전|보내지\s*않|미발송|발송\s*확인\s*전|발송\s*보류|쓰지\s*않는\s*말/;   # already says not sent
    my $l = substr($line, 0, 90); push @o, $l unless $s{$l}++;
  }
  print join("\n", @o[0..($#o < 2 ? $#o : 2)]) if @o;
')
[[ -n "$hits" ]] || exit 0
ctx="문서에 \"보냈다\"는 뜻의 표현이 들어간다. Claude는 아무것도 보내지 않고, 보내는 사람은 사용자다(지침서 13 보낼 문서와 발송 상태).
- 사용자가 이 대화에서 직접 \"보냈다\"고 말한 문서만 \"전달함, 발송함, 회신 대기\"로 쓴다. 그 경우 _발신함/목록.md 에 발송 날짜, 채널, 사용자 답변이 적혀 있어야 한다.
- 확인하지 않았으면 \"작성 완료(발송 전)\"로 고쳐 쓰고, 보고 끝에 \"보내셨나요? 언제, 어디로 보내셨나요?\"를 묻는다.
해당 줄:
$hits"
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
