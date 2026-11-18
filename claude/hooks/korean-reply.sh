#!/usr/bin/env bash
# Replies to the user are written in Korean (claude-work-harness, 2026-11-12 사용자 지시: 세션들이 보고를 영어 전문으로 보냄).
#  - UserPromptSubmit: a one-line reminder with every user message
#  - Stop: if the reply that just ended is mostly English prose, send it back once to be rewritten in Korean.
#    Code blocks, inline code, links and paths are not counted; short replies are left alone.
input=$(cat)
ev=$(jq -r '.hook_event_name // empty' <<<"$input")

if [[ "$ev" == UserPromptSubmit ]]; then
  jq -n '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:"답과 보고는 한국어로 쓴다. 영어 문장으로 보고하지 않는다. 코드, 명령, 파일 이름, 고유 명사만 원문 그대로 둔다(05 쇠맛 줄이기)."}}'
  exit 0
fi

[[ "$ev" == Stop ]] || exit 0
[[ "$(jq -r '.stop_hook_active // false' <<<"$input")" == true ]] && exit 0     # already sent back once
# Judge the reply of this turn only. The Stop input may carry it directly; otherwise read the transcript, but take only
# assistant text written after the latest user message. The final message can reach the file a moment after this hook
# starts, so wait for it briefly; if it never shows up, judge nothing (2026-11-12: reading "the last text" judged the
# previous reply, so an English reply passed and its Korean rewrite was sent back).
text=$(jq -r '.last_assistant_message // empty | if type == "string" then . else ([.content[]? | select(.type == "text") | .text] | join("\n")) end' <<<"$input" 2>/dev/null)
if [[ -z "$text" ]]; then
  tp=$(jq -r '.transcript_path // empty' <<<"$input"); [[ -f "$tp" ]] || exit 0
  for _ in 1 2 3 4 5 6 7 8; do
    text=$(tail -n 400 "$tp" | jq -rs '
      def is_user_msg: .type == "user" and ((.message.content | type) == "string" or ([.message.content[]? | select(.type == "text")] | length > 0));
      (map(is_user_msg) | rindex(true) // -1) as $u
      | [ .[($u + 1):][] | select(.type == "assistant") | [ (.message.content // [])[]? | select(.type == "text") | .text ] | join("\n") | select(length > 0) ]
      | join("\n")' 2>/dev/null)
    [[ -n "$text" ]] && break
    sleep 0.25
  done
fi
[[ -n "$text" ]] || exit 0
verdict=$(TEXT="$text" perl -CSDA -Mutf8 -e '
  use Encode qw(decode_utf8);
  my $t = decode_utf8($ENV{TEXT});
  $t =~ s/```.*?```//gs; $t =~ s/`[^`\n]*`//g; $t =~ s{https?://\S+}{}g; $t =~ s{(?:~|\.{0,2})?/[\w.\-/@]+}{}g;
  my $ko = () = $t =~ /\p{Hangul}/g; my $en = () = $t =~ /[A-Za-z]/g;
  print(($en >= 150 && $ko / ($ko + $en) < 0.25) ? "english" : "ok");
')
if [[ "$verdict" == english ]]; then
  jq -n '{decision:"block",reason:"방금 답이 영어 문장 위주로 쓰였다. 사용자는 한국어로 보고받는다. 같은 내용을 한국어로 다시 써서 답한다. 코드, 명령, 파일 이름, 고유 명사만 원문 그대로 두고, 05 쇠맛 줄이기를 따른다."}'
fi
exit 0
