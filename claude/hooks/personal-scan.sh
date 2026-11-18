#!/usr/bin/env bash
# Personal-material check for shared repositories (claude-work-harness, 지침서 12, 13, 14).
# Called by the global pre-commit hook. Blocks a commit in a repo under WORK_DIR when it adds
#  - an absolute personal path (/Users/<name>/..., ~/Desktop/..., temp folders), or
#  - a pointer into the personal notes vault (its folder name, "노트 보관함 work/..."), or
#  - the local-only lists: _할일/ and _발신함/목록.md (kept in the repo folder but never committed).
#   personal-scan.sh [repo]     prints findings and exits 1, or exits 0
set -u
repo="${1:-.}"
CONF="${HARNESS_CONF:-$HOME/.claude/harness.conf}"; WORK_DIR=""; NOTES_DIR=""; PERSONAL_REPOS=()
[[ -f "$CONF" ]] && source "$CONF"
top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || exit 0
# a worktree kept outside the work folder belongs to the repo its shared git folder lives in
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
main="$top"; [[ "${common##*/}" == .git ]] && main="${common%/.git}"
top="${top#/private}"; main="${main#/private}"; WORK_DIR="${WORK_DIR#/private}"   # /var and /private/var are the same place
under_work() { [[ -n "$WORK_DIR" && "$1" == "$WORK_DIR"/* ]]; }
under_work "$top" || under_work "$main" || exit 0                   # only project repos under the work folder
[[ "${top##*/}" == claude-harness || "${main##*/}" == claude-harness ]] && exit 0   # the harness itself documents these words
for r in ${PERSONAL_REPOS[@]+"${PERSONAL_REPOS[@]}"}; do
  [[ "$top" == "$r" || "$top" == "$r"/* || "$main" == "$r" || "$main" == "$r"/* ]] && exit 0
done

names=$(git -C "$repo" -c core.quotepath=off diff --cached --name-only --diff-filter=ACMR)
bad_files=$(grep -E '(^|/)_할일/|(^|/)_발신함/목록\.md$' <<<"$names" | sed 's/^/로컬 전용 목록: /')

notes_name=""; [[ -n "$NOTES_DIR" ]] && notes_name="${NOTES_DIR##*/}"
hits=$(git -C "$repo" -c core.quotepath=off diff --cached -U0 --no-color --diff-filter=ACMR -- . \
         ':(exclude)*.lock' ':(exclude)*.pbxproj' ':(exclude)*.xcscheme' ':(exclude)*.plist' |
  NOTES="$notes_name" perl -CSDA -Mutf8 -ne '
    use Encode qw(decode_utf8);
    BEGIN { our $notes = decode_utf8($ENV{NOTES} // ""); our ($file, %seen, $n) = ("") }
    if (m{^\+\+\+ b/(.*)}) { $file = $1; next }
    next unless /^\+/ && !/^\+\+\+/;
    my $l = substr($_, 1); chomp $l; my $why = "";
    # /home/<name>/ counts at the start of a path only, and not for system accounts of containers and CI
    if ($l =~ m{(/Users/[a-z][^/\s]*/|(?:^|[+\s"\x27`=(:])/home/(?!(?:node|runner|ubuntu|app|root|vscode|circleci|jenkins|gitpod|codespace)/)[a-z][^/\s]*/|~/(Desktop|Downloads|Documents)/|/private/(tmp|var)/|/var/folders/)}) { $why = "절대 경로" }
    elsif ($notes ne "" && index($l, $notes) >= 0) { $why = "개인 노트 위치" }
    elsif ($l =~ /노트 보관함[`\s]*work\//) { $why = "개인 노트 위치" }
    next unless $why;
    my $msg = "$why: $file: " . substr($l, 0, 90);
    print "$msg\n" unless $seen{$msg}++ || ++$n > 8;
  ')

all=$(printf '%s\n%s\n' "$bad_files" "$hits" | sed '/^$/d')
[[ -z "$all" ]] && exit 0
echo "$all"
exit 1
