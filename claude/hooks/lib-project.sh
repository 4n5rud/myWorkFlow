#!/usr/bin/env bash
# Shared helper (claude-work-harness): map a working directory to its project name in the notes vault,
# using ~/.claude/harness/projects.md (table rows "| 이름 | `저장소 폴더` |" and list rows "- 이름 (`저장소 폴더`)").
# usage: source lib-project.sh; project_name_for "<dir>"   -> prints the name or nothing
project_name_for() {
  local dir="$1" list="${HARNESS_PROJECTS:-$HOME/.claude/harness/projects.md}"
  [[ -f "$list" && -n "$dir" ]] || return 0
  DIR="$dir" HOMEDIR="$HOME" perl -CSDA -Mutf8 -ne '
    BEGIN { use Encode qw(decode_utf8); $d = decode_utf8($ENV{DIR}); $h = decode_utf8($ENV{HOMEDIR}); $d =~ s{^/private/}{/}; }
    my ($name, $path);
    if (/^\|\s*([^|`]+?)\s*\|\s*`([^`]+)`/) { ($name, $path) = ($1, $2) }
    elsif (/^-\s*([^(`]+?)\s*\(`([^`]+)`/) { ($name, $path) = ($1, $2) }
    next unless defined $path; next if $name =~ /이름|^-+$/;
    $path =~ s{^~}{$h}; $path =~ s{/+$}{};
    if ($d eq $path || index($d, "$path/") == 0) { print $name; exit }
  ' "$list"
}

# Docs repo of the project: where _할일/, _수신함/, _발신함/ live.
# Taken from the 4th table column (or "문서 저장소: `path`" on a list row) of projects.md; defaults to the registered folder.
project_docs_for() {
  local dir="$1" list="${HARNESS_PROJECTS:-$HOME/.claude/harness/projects.md}"
  [[ -f "$list" && -n "$dir" ]] || return 0
  DIR="$dir" HOMEDIR="$HOME" perl -CSDA -Mutf8 -ne '
    BEGIN { use Encode qw(decode_utf8); $d = decode_utf8($ENV{DIR}); $h = decode_utf8($ENV{HOMEDIR}); $d =~ s{^/private/}{/}; }
    my ($path, $docs);
    if (/^\|\s*[^|`]+?\s*\|\s*`([^`]+)`[^|]*\|[^|]*\|\s*`([^`]+)`/) { ($path, $docs) = ($1, $2) }
    elsif (/^\|\s*[^|`]+?\s*\|\s*`([^`]+)`/) { ($path, $docs) = ($1, undef) }
    elsif (/^-\s*[^(`]+?\s*\(`([^`]+)`\)(?:.*?문서 저장소:\s*`([^`]+)`)?/) { ($path, $docs) = ($1, $2) }
    next unless defined $path;
    for ($path, $docs) { next unless defined; s{^~}{$h}; s{/+$}{}; }
    if ($d eq $path || index($d, "$path/") == 0) { print(defined $docs ? $docs : $path); exit }
  ' "$list"
}
