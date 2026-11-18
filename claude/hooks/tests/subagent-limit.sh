#!/usr/bin/env bash
# Tests for subagent-limit.sh: the cap holds while workers are active, and a worker that went quiet (stopped by a usage
# limit or an error, no stop event) stops holding a seat.
S="${SLIMIT:-$HOME/.claude/hooks/subagent-limit.sh}"; pass=0; fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SUBAGENT_STATE_DIR="$T/state" CLAUDE_PROJECTS_DIR="$T/projects" HARNESS_CONF=/dev/null
ev() { jq -nc --arg e "$1" --arg s "$2" --arg a "${3:-}" '{hook_event_name:$e,session_id:$s,agent_id:$a,tool_name:"Agent"}' | "$S"; }
want() { local d; d=$(ev PreToolUse "$2" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'); d=${d:-allow}; [[ "$d" == "$3" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1 expect=$3 got=$d"; }; }
tr() { mkdir -p "$T/projects/p/$1/subagents"; : > "$T/projects/p/$1/subagents/agent-$2.jsonl"; }
old() { touch -t "$(date -v-40M +%Y%m%d%H%M.%S)" "$@"; }

for a in a1 a2 a3 a4; do ev SubagentStart s1 "$a"; done
want four_fresh s1 deny
ev SubagentStop s1 a2; want three_after_stop s1 allow
want other_session s2 allow
# two workers stopped by a usage limit: notes are old and their transcripts went quiet -> they free their seats
for a in b1 b2 b3 b4; do ev SubagentStart s3 "$a"; tr s3 "$a"; done
old "$T/state/s3/b1" "$T/state/s3/b2" "$T/projects/p/s3/subagents/agent-b1.jsonl" "$T/projects/p/s3/subagents/agent-b2.jsonl"
want quiet_workers_free_seats s3 allow
[[ ! -e "$T/state/s3/b1" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL quiet_note_removed"; }
# an old note whose worker is still writing keeps its seat
for a in c1 c2 c3 c4; do ev SubagentStart s4 "$a"; tr s4 "$a"; done
old "$T/state/s4/c1" "$T/state/s4/c2" "$T/state/s4/c3" "$T/state/s4/c4"
want long_running_still_count s4 deny
# a project with its own cap (SUBAGENT_LIMIT_BY_DIR): 4 running is fine there, 10 is not; other folders keep 4
mkdir -p "$T/work/big/sub" "$T/work/small"
printf 'SUBAGENT_LIMIT_BY_DIR=("%s=10")\n' "$T/work/big" > "$T/conf"
evc() { jq -nc --arg e "$1" --arg s "$2" --arg a "${3:-}" --arg c "$4" '{hook_event_name:$e,session_id:$s,agent_id:$a,cwd:$c,tool_name:"Agent"}' | HARNESS_CONF="$T/conf" "$S"; }
wantc() { local d; d=$(evc PreToolUse "$2" "" "$3" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'); d=${d:-allow}; [[ "$d" == "$4" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1 expect=$4 got=$d"; }; }
for i in 1 2 3 4; do evc SubagentStart s5 "d$i" "$T/work/big/sub"; done
wantc big_project_four_ok s5 "$T/work/big/sub" allow
for i in 5 6 7 8 9 10; do evc SubagentStart s5 "d$i" "$T/work/big"; done
wantc big_project_ten_full s5 "$T/work/big" deny
for i in 1 2 3 4; do evc SubagentStart s6 "e$i" "$T/work/small"; done
wantc other_project_keeps_four s6 "$T/work/small" deny
echo "통과 $pass / 실패 $fail"; (( fail == 0 ))
