#!/usr/bin/env bash
# PreToolUse guard (claude-work-harness)
#  1. read-only repos (READONLY_REPOS): no edit, no file writes, no git changes. Reading is fine.
#  2. protected branches (PROTECTED_BRANCHES_RE): push and merge ask every time. Work branches are free.
#  3. commit / push content checks: AI attribution, credentials, local-only mock data and settings, personal material
#  4. builds must not use local-only mock settings
#  5. harness files (hook scripts, git hooks, settings.json, harness.conf, ~/.gitconfig, secret allowlist) and the
#     git hooks themselves are never changed or skipped by Claude. Reading them is fine.
# A shell command is split into pieces at ; && || | & ( ) and new lines, and each piece is judged on its own words.
# Quoted text is one word, so words inside a commit message are data, not options. Here-documents are data, except
# when they feed a shell or an interpreter. cd, pushd and subshells are followed, so the directory of each piece is
# known. The git hooks (git-hooks/_dispatch) check commits and pushes again, whatever the command looked like.
# Settings: ${HARNESS_CONF:-~/.claude/harness.conf}. Shell identifiers stay ASCII.

input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input"); [[ -n "$cwd" ]] || cwd=$PWD

READONLY_REPOS=(); FREE_PUSH_REPOS=(); NO_COMMIT_REPOS=()
# FREE_BRANCHES_BY_REPO=("<project folder>=<branch>[,<branch>]"): in that project (its submodules and worktrees kept
# elsewhere included) merging into and pushing to these protected branches does not ask (2026-11-13: one project's dev)
FREE_BRANCHES_BY_REPO=()
MOCK_ALLOW_PATHS_RE=''
PROTECTED_BRANCHES_RE='^(dev|develop|main|master|prod|production|staging|stg)$'
CONF="${HARNESS_CONF:-$HOME/.claude/harness.conf}"
[[ -f "$CONF" ]] && source "$CONF"
RO_MSG="읽기 전용으로 지정된 저장소입니다(harness.conf의 READONLY_REPOS). 안의 파일을 만들거나 고치거나 지우지 않고, git으로 바꾸지도 않습니다. 읽기는 괜찮습니다. 산출물은 프로젝트 폴더에 만드세요."
PROT_MSG="훅 스크립트, git 전역 훅, settings.json, harness.conf, ~/.gitconfig, 비밀값 허용 목록은 사용자만 고칩니다(지침서 15). 읽기는 괜찮습니다. 바꿔야 할 일이 있으면 사용자에게 알리고 사용자가 정하게 하세요."
BYPASS_MSG="비밀값 검사를 건너뛰거나 끄는 명령이라 막았습니다(--no-verify, commit -n, 훅 경로 바꾸기, git 설정을 바꿔서 전역 훅 피하기). 이 검사는 어떤 경우에도 끄지 않습니다(지침서 15). 걸린 값이 진짜 비밀값이 아니면 사용자에게 알리세요."
GQ=(git -c core.quotepath=off)

decide() { # $1=deny|ask  $2=reason
  jq -n --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

# norm <path> <base>: absolute path in NP. ~ and $HOME are expanded, . and .. are folded, symlinks are not resolved,
# /private/var and /private/tmp are written as /var and /tmp (the same place on macOS).
norm() {
  local p="$1" b="${2:-$cwd}" part IFS=/
  local out=()
  case "$p" in
    '~') p="$HOME" ;;        '~/'*) p="$HOME/${p#??}" ;;
    '$HOME') p="$HOME" ;;    '$HOME/'*) p="$HOME/${p#??????}" ;;
    '${HOME}') p="$HOME" ;;  '${HOME}/'*) p="$HOME/${p#????????}" ;;
  esac
  [[ "$p" == /* ]] || p="$b/$p"
  set -f
  for part in $p; do
    case "$part" in
      ''|.) ;;
      ..) [[ ${#out[@]} -gt 0 ]] && unset "out[$((${#out[@]} - 1))]" ;;
      *) out[${#out[@]}]="$part" ;;
    esac
  done
  set +f
  NP="/${out[*]}"
  case "$NP" in /private/var|/private/var/*|/private/tmp|/private/tmp/*) NP="${NP#/private}" ;; esac
}
is_under() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }

RO_N=(); for r in ${READONLY_REPOS[@]+"${READONLY_REPOS[@]}"}; do norm "$r" /; RO_N+=("$NP"); done
NC_N=(); for r in ${NO_COMMIT_REPOS[@]+"${NO_COMMIT_REPOS[@]}"}; do norm "$r" /; NC_N+=("$NP"); done
FREE_N=(); for r in ${FREE_PUSH_REPOS[@]+"${FREE_PUSH_REPOS[@]}"}; do norm "$r" /; FREE_N+=("$NP"); done
PROT_N=()
for r in "$HOME/.claude/hooks" "$HOME/.claude/git-hooks" "$HOME/.claude/settings.json" "$HOME/.claude/harness.conf" \
         "$HOME/.claude/harness/secret-allow.txt" "$HOME/.gitconfig" "$HOME/.config/git/config" "$CONF"; do
  norm "$r" /; PROT_N+=("$NP")
done

ro_hit() { # $1=path $2=1 when the path may be a parent folder of the repo (rm, mv)
  local r; for r in ${RO_N[@]+"${RO_N[@]}"}; do
    is_under "$1" "$r" && return 0; [[ "${2:-0}" == 1 ]] && is_under "$r" "$1" && return 0
  done; return 1; }
prot_hit() { # $1=path $2=1 when the path may be a parent folder (rm, mv, rsync)
  local p; for p in "${PROT_N[@]}"; do
    is_under "$1" "$p" && return 0; [[ "${2:-0}" == 1 ]] && is_under "$p" "$1" && return 0
  done; return 1; }
write_target() { # $1=raw path $2=anc flag: a file the command writes, moves or deletes
  [[ -n "$1" ]] || return 0
  norm "$1" "$cur"
  prot_hit "$NP" "${2:-0}" && decide deny "$PROT_MSG"
  ro_hit "$NP" "${2:-0}" && decide deny "$RO_MSG"
  return 0
}

# 1. file tools
case "$tool" in
  Edit|Write|NotebookEdit|MultiEdit)
    path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
    [[ -n "$path" ]] || exit 0
    norm "$path" "$cwd"
    ro_hit "$NP" && decide deny "$RO_MSG"
    prot_hit "$NP" && decide deny "$PROT_MSG"
    exit 0 ;;
  Bash) ;;
  *) exit 0 ;;
esac

cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
[[ -n "$cmd" ]] || exit 0

# --- split the command into pieces -------------------------------------------------------------------------------
# Output: words separated by NUL, a piece ends with \x1e. Special words: \x01( and \x01) open and close a subshell,
# \x02<path> is a file written by a redirection, \x03<text> is a here-document body. The last record is \x1dOK.
read -r -d '' TOKENIZER <<'PERL'
use strict; use warnings;
my @SH = qw(bash sh zsh dash ksh);
sub dq_scan;
sub parse {
  my ($s, $i, $until) = @_;
  my $n = length $s;
  my (@segs, @pending); my $cur = []; my $tok = ""; my ($has, $redir, $drop, $depth) = (0, 0, 0, 0);
  my $endtok = sub {
    if ($has) {
      if ($drop) { $drop = 0 } elsif ($redir) { push @$cur, "\x02$tok"; $redir = 0 } else { push @$cur, $tok }
    }
    $tok = ""; $has = 0;
  };
  my $endseg = sub { $endtok->(); push @segs, $cur if @$cur; $cur = []; };
  my $sub = sub { my ($j, $inner) = parse($s, $_[0], ")"); push @segs, ["\x01("], @$inner, ["\x01)"]; return $j; };
  while ($i < $n) {
    my $c = substr($s, $i, 1);
    if ($c eq "\\") { my $d = substr($s, $i + 1, 1); $i += 2; next if $d eq "\n"; $tok .= $d; $has = 1; next }
    if ($c eq "'") { my $j = index($s, "'", $i + 1); $j = $n if $j < 0; $tok .= substr($s, $i + 1, $j - $i - 1); $has = 1; $i = $j + 1; next }
    if ($c eq '"') { $i = dq_scan($s, $i + 1, \$tok, \@segs); $has = 1; next }
    if ($c eq '`') {
      my $j = $i + 1; while ($j < $n && substr($s, $j, 1) ne '`') { $j++ if substr($s, $j, 1) eq "\\"; $j++ }
      my $inner = substr($s, $i + 1, $j - $i - 1); my (undef, $ss) = parse($inner, 0, undef);
      push @segs, ["\x01("], @$ss, ["\x01)"]; $tok .= "`$inner`"; $has = 1; $i = $j + 1; next;
    }
    if ($c eq '$') {
      my $d = substr($s, $i + 1, 1);
      if ($d eq '(') { my $j = $sub->($i + 2); $tok .= substr($s, $i, $j - $i); $has = 1; $i = $j; next }
      if ($d eq '{') { my $j = index($s, '}', $i + 2); $j = $n - 1 if $j < 0; $tok .= substr($s, $i, $j - $i + 1); $has = 1; $i = $j + 1; next }
      if ($d eq "'") {
        my $j = $i + 2; my $v = "";
        while ($j < $n && substr($s, $j, 1) ne "'") { if (substr($s, $j, 1) eq "\\") { $v .= substr($s, $j, 2); $j += 2; next } $v .= substr($s, $j, 1); $j++ }
        $tok .= $v; $has = 1; $i = $j + 1; next;
      }
      $tok .= $c; $has = 1; $i++; next;
    }
    if ($c eq ' ' || $c eq "\t") { $endtok->(); $i++; next }
    if ($c eq "\n") {
      $endseg->(); $i++;
      for my $h (@pending) {
        my ($delim, $strip, $ref) = @$h; my $body = "";
        while ($i < $n) {
          my $e = index($s, "\n", $i); $e = $n if $e < 0;
          my $line = substr($s, $i, $e - $i); $i = $e + 1;
          (my $cmp = $line) =~ s/^\t+// if $strip; $cmp = $line unless $strip;
          last if $cmp eq $delim; $body .= "$line\n";
        }
        push @$ref, "\x03$body";
      }
      @pending = (); next;
    }
    if ($c eq '#' && !$has) { my $e = index($s, "\n", $i); $i = $e < 0 ? $n : $e; next }
    if ($c eq ';' || $c eq '&' || $c eq '|') {
      if ($c eq '&' && substr($s, $i + 1, 1) eq '>') { $endtok->(); $i += 2; $i++ if substr($s, $i, 1) eq '>'; $redir = 1; next }
      $endseg->(); $i++; $i++ if $i < $n && substr($s, $i, 1) =~ /[;&|]/; next;
    }
    if ($c eq '(') {
      if ($has) { $tok .= $c; $i++; next }
      $endseg->(); $depth++; push @segs, ["\x01("]; $i++; next;
    }
    if ($c eq ')') {
      $endseg->();
      if ($depth == 0) { return ($i + 1, \@segs) if defined $until; $i++; next }
      $depth--; push @segs, ["\x01)"]; $i++; next;
    }
    if ($c eq '>' || $c eq '<') {
      if ($has && !$redir && $tok =~ /^\d+$/) { $tok = ""; $has = 0 } else { $endtok->() }
      $i++; my $d = substr($s, $i, 1);
      if ($d eq '(') { $i = $sub->($i + 1); next }
      if ($c eq '>') {
        $i++ if $d eq '>' || $d eq '|';
        if (substr($s, $i, 1) eq '&') { $i++; $i++ while $i < $n && substr($s, $i, 1) =~ /[0-9-]/; next }
        $redir = 1; next;
      }
      if ($d eq '<') {
        $i++;
        if (substr($s, $i, 1) eq '<') { $i++; $drop = 1; next }
        my $strip = 0; if (substr($s, $i, 1) eq '-') { $strip = 1; $i++ }
        $i++ while $i < $n && substr($s, $i, 1) =~ /[ \t]/;
        my $w = "";
        while ($i < $n && substr($s, $i, 1) !~ /[\s;&|<>()]/) {
          my $ch = substr($s, $i, 1);
          if ($ch eq "'" || $ch eq '"') { my $j = index($s, $ch, $i + 1); $j = $n if $j < 0; $w .= substr($s, $i + 1, $j - $i - 1); $i = $j + 1; next }
          if ($ch eq "\\") { $w .= substr($s, $i + 1, 1); $i += 2; next }
          $w .= $ch; $i++;
        }
        push @pending, [$w, $strip, $cur]; next;
      }
      if ($d eq '&') { $i++; $i++ while $i < $n && substr($s, $i, 1) =~ /[0-9-]/; next }
      $drop = 1; next;
    }
    $tok .= $c; $has = 1; $i++;
  }
  $endseg->();
  return ($i, \@segs);
}
sub dq_scan {
  my ($s, $i, $tr, $segs) = @_; my $n = length $s;
  while ($i < $n) {
    my $c = substr($s, $i, 1);
    return $i + 1 if $c eq '"';
    if ($c eq "\\") { my $d = substr($s, $i + 1, 1); if ($d =~ /[\$`"\\\n]/) { $$tr .= $d unless $d eq "\n"; $i += 2; next } $$tr .= $c; $i++; next }
    if ($c eq '$' && substr($s, $i + 1, 1) eq '(') {
      my ($j, $inner) = parse($s, $i + 2, ")"); push @$segs, ["\x01("], @$inner, ["\x01)"]; $$tr .= substr($s, $i, $j - $i); $i = $j; next;
    }
    if ($c eq '`') {
      my $j = $i + 1; while ($j < $n && substr($s, $j, 1) ne '`') { $j++ if substr($s, $j, 1) eq "\\"; $j++ }
      my $inner = substr($s, $i + 1, $j - $i - 1); my (undef, $ss) = parse($inner, 0, undef);
      push @$segs, ["\x01("], @$ss, ["\x01)"]; $$tr .= "`$inner`"; $i = $j + 1; next;
    }
    $$tr .= $c; $i++;
  }
  return $n;
}
my %KW = map { $_ => 1 } ("{", "}", "!", "then", "do", "else", "elif", "if", "while", "until", "time", "fi", "done", "esac");
my %WRAP = map { $_ => 1 } qw(env command builtin exec nohup sudo doas nice time timeout gtimeout xargs);
sub expand {
  my ($segs, $lvl) = @_; my @res;
  for my $seg (@$segs) {
    my @w = @$seg;
    shift @w while @w && $KW{$w[0]};
    next unless @w;
    push @res, [@w];
    next if $lvl > 4;
    my $k = 0;
    while ($k < @w) {
      my $b = $w[$k]; $b =~ s{.*/}{};
      if ($w[$k] =~ /^[A-Za-z_][A-Za-z0-9_]*=/ || $WRAP{$b} || ($k > 0 && $w[$k] =~ /^-/)) { $k++; next }
      last;
    }
    next unless $k < @w;
    (my $c0 = $w[$k]) =~ s{.*/}{};
    my @rest = grep { !/^[\x02\x03]/ } @w[$k + 1 .. $#w];
    my @body = map { substr($_, 1) } grep { /^\x03/ } @w;
    my @more;
    if (grep { $_ eq $c0 } @SH) {
      my $script;
      for my $x (0 .. $#rest) { if ($rest[$x] =~ /^-[a-zA-Z]*c[a-zA-Z]*$/) { $script = $rest[$x + 1]; last } }
      $script = $body[0] if !defined $script && @body && !grep { !/^-/ } @rest;
      if (defined $script) { my (undef, $ss) = parse($script, 0, undef); push @more, @$ss }
    } elsif ($c0 eq "eval" && @rest) {
      my (undef, $ss) = parse(join(" ", @rest), 0, undef); push @more, @$ss;
    }
    push @res, ["\x01("], @{ expand(\@more, $lvl + 1) }, ["\x01)"] if @more;
  }
  return \@res;
}
my (undef, $segs) = parse($ENV{CMD} // "", 0, undef);
for my $seg (@{ expand($segs, 0) }) { print map({ "$_\0" } @$seg), "\x1e\0" }
print "\x1dOK\0";
PERL

TOK=(); SS=(); SN=(); k=0; s0=0; tok_ok=0
while IFS= read -r -d '' w; do
  if [[ "$w" == $'\x1e' ]]; then SS+=("$s0"); SN+=($((k - s0))); s0=$k; continue; fi
  if [[ "$w" == $'\x1dOK' ]]; then tok_ok=1; continue; fi
  TOK[k]="$w"; k=$((k + 1))
done < <(CMD="$cmd" perl -e "$TOKENIZER" 2>/dev/null)
(( tok_ok )) || decide deny "명령을 조각으로 나누지 못해서 막았습니다(guard.sh). 명령을 더 단순하게 나눠서 다시 실행하세요."

# --- state carried from piece to piece ----------------------------------------------------------------------------
cur="$cwd"; DSTACK=()
env_bypass=0; exp_gitdir=""
BR_DIR=""; BR_NAME=""
COMMIT_DIRS=(); COMMIT_ALL=(); COMMIT_MSGF=()
PUSH_DIRS=(); PUSH_BRS=(); PUSH_ARGS=()
MERGE_DIRS=(); MERGE_BRS=(); MERGE_KINDS=()
is_pr=0; is_text=0
BYPASS_ENV_RE='^(GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM|GIT_CONFIG_COUNT|GIT_CONFIG_KEY_[0-9]+|GIT_CONFIG_VALUE_[0-9]+|GIT_CONFIG_PARAMETERS|GIT_CONFIG|HOME|XDG_CONFIG_HOME)='

# common git folder of a repo, cached per listed repo
RO_C=(); NC_C=()
common_of() { git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null; }
repo_common() { # $1=dir $2=git dir -> RC
  RC=""
  if [[ -n "$2" ]]; then RC=$(git --git-dir="$2" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  elif [[ -d "$1" ]]; then RC=$(common_of "$1"); fi
  if [[ -n "$RC" ]]; then norm "$RC" /; RC=$NP; fi
}
policy_hit() { # $1=ro|nc $2=dir $3=git dir -> HIT_NAME
  local i r c roots
  if [[ "$1" == ro ]]; then roots=(${RO_N[@]+"${RO_N[@]}"}); else roots=(${NC_N[@]+"${NC_N[@]}"}); fi
  (( ${#roots[@]} )) || return 1
  for i in "${!roots[@]}"; do
    r="${roots[i]}"
    if is_under "$2" "$r" || { [[ -n "$3" ]] && is_under "$3" "$r"; }; then HIT_NAME="${r##*/}"; return 0; fi
  done
  repo_common "$2" "$3"; [[ -n "$RC" ]] || return 1
  for i in "${!roots[@]}"; do
    r="${roots[i]}"
    if [[ "$1" == ro ]]; then c="${RO_C[i]:-}"; [[ -n "$c" ]] || { c=$(common_of "$r"); [[ -n "$c" ]] && { norm "$c" /; c=$NP; }; RO_C[i]="${c:--}"; }
    else c="${NC_C[i]:-}"; [[ -n "$c" ]] || { c=$(common_of "$r"); [[ -n "$c" ]] && { norm "$c" /; c=$NP; }; NC_C[i]="${c:--}"; }; fi
    [[ "$c" != - && "$c" == "$RC" ]] && { HIT_NAME="${r##*/}"; return 0; }
  done
  return 1
}
nc_deny() { decide deny "${1}은 커밋과 푸시를 하지 않는 저장소입니다(harness.conf의 NO_COMMIT_REPOS). 파일은 고쳐도 되지만 커밋, 푸시, 태그, 머지, PR은 하지 않습니다. 바뀐 내용을 사용자에게 보고하고, 반영은 사용자가 직접 합니다."; }
branch_at() { # $1=dir -> BR (follows a checkout or switch earlier in the same command)
  if [[ -n "$BR_DIR" && "$1" == "$BR_DIR" ]]; then BR="$BR_NAME"; else BR=$(git -C "$1" branch --show-current 2>/dev/null); fi
}
ci_match() { # $1=text $2=glob, case-insensitive
  local r; shopt -s nocasematch; [[ "$1" == $2 ]]; r=$?; shopt -u nocasematch; return $r; }

# interpreter code (python -c, node -e, a here-document fed to python ...) that writes a harness file or a read-only repo
code_check() {
  local c="$1" r
  grep -qE 'write|append|unlink|remove|rename|rmtree|rmSync|rmdir|copy|move|truncate|chmod|symlink|replace|open[[:space:]]*\([^,)]*,[[:space:]]*['"'"'"][^'"'"'"]*[wax+]|>' <<<"$c" || return 0
  grep -qE '\.claude/(hooks|git-hooks|settings\.json|harness\.conf|harness/secret-allow\.txt)|\.gitconfig|\.config/git/config' <<<"$c" && decide deny "$PROT_MSG"
  for r in ${RO_N[@]+"${RO_N[@]}"}; do
    [[ "$c" == *"$r"* || "$c" == *"/${r%/*}"/"${r##*/}"* || "$c" == *"${r#"${r%/*/*}"/}"* ]] && decide deny "$RO_MSG"
  done
  return 0
}

# git config: writing core.hooksPath (any case) or include paths, or any global or system setting, is refused
config_check() { # A=(args after "config") $1=dir
  local t pos=() wflag=0 rflag=0 scope="" file="" nextfile=0
  case "${A[0]:-}" in
    get|list) rflag=1 ;;
    set|unset|rename-section|remove-section|edit|replace-all) wflag=1 ;;
  esac
  for t in ${A[@]+"${A[@]}"}; do
    if (( nextfile )); then file="$t"; nextfile=0; continue; fi
    case "$t" in
      get|list|set|unset|rename-section|remove-section|edit|replace-all) [[ ${#pos[@]} -eq 0 && $wflag$rflag != 00 ]] && continue; pos+=("$t") ;;
      --global|--system) scope=g ;;
      --file=*) file="${t#--file=}" ;;
      --file|-f) nextfile=1 ;;
      --get|--get-all|--get-regexp|--get-urlmatch|--list|-l|--show-origin|--show-scope|--get-color|--get-colorbool|--name-only) rflag=1 ;;
      --unset|--unset-all|--add|--replace-all|--rename-section|--remove-section|--edit|-e) wflag=1 ;;
      -*) ;;
      *) pos+=("$t") ;;
    esac
  done
  local write=0
  if (( wflag )) || { (( ! rflag )) && (( ${#pos[@]} >= 2 )); }; then write=1; fi
  (( write )) || return 0
  local key="${pos[0]:-}"
  if ci_match "$key" 'core.hookspath' || ci_match "$key" 'include.*' || ci_match "$key" 'includeif.*'; then decide deny "$BYPASS_MSG"; fi
  [[ "$scope" == g ]] && decide deny "$PROT_MSG"
  if [[ -n "$file" ]]; then norm "$file" "$1"; prot_hit "$NP" && decide deny "$PROT_MSG"; fi
  CONFIG_WRITE=1
}

git_is_write() { # $1=subcommand, A=(args) -> 0 when it changes the repo
  local t
  case "$1" in
    add|commit|push|rm|mv|reset|checkout|switch|rebase|merge|cherry-pick|restore|apply|pull|clean|revert|am|notes|update-ref|update-index|commit-tree|replace|filter-branch|filter-repo|gc|prune|submodule|mergetool|read-tree|init|sparse-checkout) return 0 ;;
    stash) [[ "${A[0]:-}" == list || "${A[0]:-}" == show ]] && return 1; return 0 ;;
    worktree) [[ "${A[0]:-}" == list ]] && return 1; return 0 ;;
    remote) case "${A[0]:-}" in add|remove|rm|rename|set-url|set-head|prune|set-branches) return 0 ;; esac; return 1 ;;
    config) (( CONFIG_WRITE )) && return 0; return 1 ;;
    tag|branch)
      local pos=0 list=0 mod=0
      for t in ${A[@]+"${A[@]}"}; do
        case "$t" in
          -l|--list|-v|--verify|-a|-r|--all|--remotes|--contains|--merged|--no-merged|--points-at|--show-current|--format=*|--sort=*|-vv) [[ "$t" == -a && "$1" == tag ]] && mod=1 || list=1 ;;
          -d|-D|-m|-M|-c|-C|-f|--delete|--move|--copy|--force|-u|--set-upstream-to=*|--unset-upstream|--edit-description|-s|--sign|--annotate) mod=1 ;;
          -*) ;;
          *) pos=1 ;;
        esac
      done
      (( mod )) && return 0
      (( pos && ! list )) && return 0
      return 1 ;;
  esac
  return 1
}

join_args() { local IFS=$'\x1f'; JOINED="${A[*]:-}"; }
git_seg() { # W=(git ...) ENVN=(NAME=value ...)
  local gdir="$cur" gitdir="" keys="" j=1 n=${#W[@]} sub="" t e
  while (( j < n )); do
    t="${W[j]}"
    case "$t" in
      -C) norm "${W[j+1]:-}" "$gdir"; gdir=$NP; j=$((j + 2)) ;;
      -c) keys+=" ${W[j+1]%%=*}"; j=$((j + 2)) ;;
      --config-env=*) t="${t#--config-env=}"; keys+=" ${t%%=*}"; j=$((j + 1)) ;;
      --config-env) keys+=" ${W[j+1]%%=*}"; j=$((j + 2)) ;;
      --git-dir=*) norm "${t#--git-dir=}" "$gdir"; gitdir=$NP; j=$((j + 1)) ;;
      --git-dir) norm "${W[j+1]:-}" "$gdir"; gitdir=$NP; j=$((j + 2)) ;;
      --work-tree=*) norm "${t#--work-tree=}" "$gdir"; gdir=$NP; j=$((j + 1)) ;;
      --work-tree) norm "${W[j+1]:-}" "$gdir"; gdir=$NP; j=$((j + 2)) ;;
      --namespace|--super-prefix) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) sub="$t"; break ;;
    esac
  done
  for e in ${ENVN[@]+"${ENVN[@]}"}; do
    case "$e" in
      GIT_DIR=*) norm "${e#GIT_DIR=}" "$gdir"; gitdir=$NP ;;
      GIT_WORK_TREE=*) norm "${e#GIT_WORK_TREE=}" "$gdir"; gdir=$NP ;;
    esac
  done
  [[ -z "$gitdir" && -n "$exp_gitdir" ]] && gitdir="$exp_gitdir"
  A=("${W[@]:j+1}")

  # the hooks path never changes, in any letter case and however it is given
  for t in $keys; do ci_match "$t" 'core.hookspath' && decide deny "$BYPASS_MSG"; done

  local hookcmd=0
  case "$sub" in commit|push|merge|am|rebase|cherry-pick|revert|pull) hookcmd=1 ;; esac
  if (( hookcmd )); then
    (( env_bypass || env_clear )) && decide deny "$BYPASS_MSG"
    for e in ${ENVN[@]+"${ENVN[@]}"}; do [[ "$e" =~ $BYPASS_ENV_RE ]] && decide deny "$BYPASS_MSG"; done
    for t in ${A[@]+"${A[@]}"}; do
      [[ "$t" == -- ]] && break
      [[ "$t" =~ ^--no-ver(i(fy?)?)?$ ]] && decide deny "$BYPASS_MSG"
    done
  fi

  local all=0 msgf="" skip=0 c x
  if [[ "$sub" == commit ]]; then
    for t in ${A[@]+"${A[@]}"}; do
      if (( skip == 2 )); then msgf="$t"; skip=0; continue; fi
      if (( skip )); then skip=0; continue; fi
      case "$t" in
        --) all=1; break ;;
        -F|--file) skip=2 ;;
        --file=*) msgf="${t#--file=}" ;;
        -m|-C|-c|-t|--message|--author|--date|--template|--reuse-message|--reedit-message|--fixup|--squash|--trailer|--cleanup|--pathspec-from-file) skip=1 ;;
        --all|--include|--only) all=1 ;;
        --*) ;;
        -*)
          for (( x = 1; x < ${#t}; x++ )); do
            c="${t:x:1}"
            case "$c" in
              n) decide deny "$BYPASS_MSG" ;;
              a|i|o) all=1 ;;
              F) [[ $x -eq $((${#t} - 1)) ]] && skip=2 || msgf="${t:x+1}"; break ;;
              m|C|c|t) [[ $x -eq $((${#t} - 1)) ]] && skip=1; break ;;
            esac
          done ;;
        *) all=1 ;;
      esac
    done
  fi

  CONFIG_WRITE=0
  [[ "$sub" == config ]] && config_check "$gdir"

  # read-only and no-commit repos
  if git_is_write "$sub"; then
    policy_hit ro "$gdir" "$gitdir" && decide deny "$RO_MSG"
  fi
  case "$sub" in
    commit|push|merge|rebase|cherry-pick|revert|am) policy_hit nc "$gdir" "$gitdir" && nc_deny "$HIT_NAME" ;;
    tag) git_is_write tag && policy_hit nc "$gdir" "$gitdir" && nc_deny "$HIT_NAME" ;;
  esac

  # remember what the later checks need
  case "$sub" in
    commit) COMMIT_DIRS+=("$gdir"); COMMIT_ALL+=("$all"); [[ -n "$msgf" ]] && { norm "$msgf" "$cur"; msgf=$NP; }; COMMIT_MSGF+=("${msgf:--}") ;;
    push) branch_at "$gdir"; PUSH_DIRS+=("$gdir"); PUSH_BRS+=("$BR"); join_args; PUSH_ARGS+=("$JOINED") ;;
    merge) branch_at "$gdir"; MERGE_DIRS+=("$gdir"); MERGE_BRS+=("$BR"); MERGE_KINDS+=(git) ;;
    checkout|switch)
      local name="" known=0 next=0
      for t in ${A[@]+"${A[@]}"}; do
        if (( next )); then name="$t"; known=1; break; fi
        case "$t" in
          --) break ;;
          -b|-B|-c|-C|--orphan) next=1 ;;
          -*) ;;
          *) name="$t"; break ;;
        esac
      done
      if [[ -n "$name" ]] && { (( known )) || [[ "$name" =~ $PROTECTED_BRANCHES_RE ]] \
           || git -C "$gdir" rev-parse -q --verify "refs/heads/$name" >/dev/null 2>&1 \
           || git -C "$gdir" rev-parse -q --verify "refs/remotes/origin/$name" >/dev/null 2>&1; }; then
        BR_DIR="$gdir"; BR_NAME="$name"
      fi ;;
  esac
}

# document tool that commits and pushes with the git hooks turned off (tools/doc-cli.mjs):
# the files it is given are scanned for secrets first. The project folder itself (a git repo) is not.
doc_seg() { # $1=index of cli.mjs in W
  local SCAN="${SECRET_SCAN:-$HOME/.claude/hooks/secret-scan.sh}" t f list=() out
  [[ -x "$SCAN" ]] || return 0
  for t in "${W[@]:$1+1}"; do
    norm "$t" "$cur"
    if [[ -f "$NP" ]]; then
      list+=("$NP")
      if [[ "$NP" == *.json ]]; then
        f=$(jq -r 'if type == "object" then (.file // empty) else empty end' "$NP" 2>/dev/null)
        if [[ -n "$f" ]]; then norm "$f" "$cur"; [[ -e "$NP" ]] && list+=("$NP"); fi
      fi
    elif [[ -d "$NP" && ! -e "$NP/.git" ]]; then
      list+=("$NP")
    fi
  done
  (( ${#list[@]} )) || return 0
  out=$("$SCAN" path "${list[@]}") || decide deny "문서정리 도구는 git 훅을 끄고 커밋과 푸시를 하므로, 넘기는 파일을 먼저 검사했고 비밀값으로 보이는 것이 있어서 막았습니다(지침서 15). 값을 지우거나 가린 뒤 다시 하세요. 진짜 비밀값이 아니면 사용자에게 알리세요.
$out"
}

# --- judge each piece ---------------------------------------------------------------------------------------------
for (( si = 0; si < ${#SS[@]}; si++ )); do
  SEG=("${TOK[@]:${SS[si]}:${SN[si]}}")
  if [[ "${SEG[0]}" == $'\x01(' ]]; then DSTACK+=("$cur"); continue; fi
  if [[ "${SEG[0]}" == $'\x01)' ]]; then
    if (( ${#DSTACK[@]} )); then cur="${DSTACK[${#DSTACK[@]}-1]}"; unset "DSTACK[$((${#DSTACK[@]} - 1))]"; fi
    continue
  fi
  W=(); BODY=(); ENVN=(); env_clear=0
  for w in "${SEG[@]}"; do
    case "$w" in
      $'\x02'*) write_target "${w#?}" 0 ;;
      $'\x03'*) BODY+=("${w#?}") ;;
      *) W+=("$w") ;;
    esac
  done
  while (( ${#W[@]} )) && [[ "${W[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do ENVN+=("${W[0]}"); W=("${W[@]:1}"); done
  if (( ${#W[@]} == 0 )); then   # plain assignment in the shell: lasts for the later pieces
    for e in ${ENVN[@]+"${ENVN[@]}"}; do
      [[ "$e" =~ $BYPASS_ENV_RE ]] && env_bypass=1
      [[ "$e" == GIT_DIR=* ]] && { norm "${e#GIT_DIR=}" "$cur"; exp_gitdir=$NP; }
    done
    continue
  fi
  # wrappers that run another command
  while (( ${#W[@]} )); do
    case "${W[0]##*/}" in
      env)
        W=("${W[@]:1}")
        while (( ${#W[@]} )); do
          case "${W[0]}" in
            -i|--ignore-environment|-) env_clear=1; W=("${W[@]:1}") ;;
            -u|--unset|-C|--chdir|-S) W=("${W[@]:2}") ;;
            -*) W=("${W[@]:1}") ;;
            *=*) ENVN+=("${W[0]}"); W=("${W[@]:1}") ;;
            *) break ;;
          esac
        done ;;
      command|builtin|exec|nohup|time|sudo|doas)
        W=("${W[@]:1}"); while (( ${#W[@]} )) && [[ "${W[0]}" == -* ]]; do W=("${W[@]:1}"); done ;;
      nice) W=("${W[@]:1}"); [[ "${W[0]:-}" == -n ]] && W=("${W[@]:2}"); [[ "${W[0]:-}" == -[0-9]* ]] && W=("${W[@]:1}") ;;
      timeout|gtimeout) W=("${W[@]:1}"); while (( ${#W[@]} )) && [[ "${W[0]}" == -* ]]; do W=("${W[@]:1}"); done; W=("${W[@]:1}") ;;
      *) break ;;
    esac
  done
  (( ${#W[@]} )) || continue
  c0="${W[0]##*/}"
  ARGS=("${W[@]:1}")
  NONOPT=(); for w in ${ARGS[@]+"${ARGS[@]}"}; do [[ "$w" == -* ]] || NONOPT+=("$w"); done

  for (( wi = 0; wi < ${#W[@]}; wi++ )); do
    [[ "${W[wi]}" == *tools/doc-cli.mjs ]] && { doc_seg "$wi"; break; }
  done

  case "$c0" in
    cd|pushd)
      t="${NONOPT[0]:-$HOME}"
      if [[ "$t" != - ]]; then norm "$t" "$cur"; cur=$NP; fi ;;
    export|declare|typeset|readonly|local)
      for w in ${NONOPT[@]+"${NONOPT[@]}"}; do
        [[ "$w" =~ $BYPASS_ENV_RE ]] && env_bypass=1
        [[ "$w" == GIT_DIR=* ]] && { norm "${w#GIT_DIR=}" "$cur"; exp_gitdir=$NP; }
      done ;;
    git) git_seg ;;
    gh)
      if [[ "${W[1]:-}" == pr && ( "${W[2]:-}" == create || "${W[2]:-}" == merge ) ]]; then
        policy_hit nc "$cur" "" && nc_deny "$HIT_NAME"
        [[ "${W[2]}" == create ]] && is_pr=1
        [[ "${W[2]}" == merge ]] && { MERGE_DIRS+=("$cur"); MERGE_BRS+=(""); MERGE_KINDS+=(gh); }
      fi
      if [[ "${W[1]:-}" == api ]]; then
        for w in ${ARGS[@]+"${ARGS[@]}"}; do
          [[ "$w" =~ (^|/)pulls/[0-9]+/merge$|/merges$ ]] && { MERGE_DIRS+=("$cur"); MERGE_BRS+=(""); MERGE_KINDS+=(gh); break; }
        done
      fi
      [[ "${W[1]:-}" == issue || "${W[1]:-}" == release || "${W[1]:-}" == pr ]] && is_text=1 ;;
    glab)
      if [[ "${W[1]:-}" == mr && ( "${W[2]:-}" == create || "${W[2]:-}" == merge ) ]]; then
        policy_hit nc "$cur" "" && nc_deny "$HIT_NAME"
        [[ "${W[2]}" == merge ]] && { MERGE_DIRS+=("$cur"); MERGE_BRS+=(""); MERGE_KINDS+=(glab); }
      fi ;;
    rm|rmdir|unlink|shred|chmod|chown|chgrp|chflags)
      for w in ${NONOPT[@]+"${NONOPT[@]}"}; do write_target "$w" 1; done ;;
    touch|mkdir|truncate|tee|ed|ex)
      for w in ${NONOPT[@]+"${NONOPT[@]}"}; do write_target "$w" 0; done ;;
    sed|gsed)
      inplace=0
      for w in ${ARGS[@]+"${ARGS[@]}"}; do [[ "$w" == --in-place* || "$w" =~ ^-[a-zA-Z]*i ]] && inplace=1; done
      if (( inplace )); then for w in ${NONOPT[@]+"${NONOPT[@]}"}; do write_target "$w" 0; done; fi ;;
    perl|ruby)
      inplace=0; code=""; skip=0; files=()
      for w in ${ARGS[@]+"${ARGS[@]}"}; do
        if (( skip )); then code+="$w"$'\n'; skip=0; continue; fi
        case "$w" in
          -e|-E) skip=1 ;;
          -*) [[ "$w" =~ ^-[a-zA-Z]*i ]] && inplace=1; [[ "$w" =~ ^-[a-zA-Z]*[eE]$ ]] && skip=1 ;;
          *) files+=("$w") ;;
        esac
      done
      if (( inplace )); then for w in ${files[@]+"${files[@]}"}; do write_target "$w" 0; done; fi
      code_check "$code${BODY[*]:-}" ;;
    python|python2|python3|python3.*|node|nodejs|deno|bun|php|osascript)
      code=""; skip=0
      for w in ${ARGS[@]+"${ARGS[@]}"}; do
        if (( skip )); then code+="$w"$'\n'; skip=0; continue; fi
        case "$w" in -c|-e|--eval|-p|--print|-r|-E) skip=1 ;; esac
      done
      code_check "$code${BODY[*]:-}" ;;
    cp|mv|install|ln|rsync|scp|ditto|gcp|gmv)
      if (( ${#NONOPT[@]} >= 2 )); then
        last=$(( ${#NONOPT[@]} - 1 )); dest="${NONOPT[last]}"
        norm "$dest" "$cur"; D=$NP
        dest_dir=0; [[ "$dest" == */ || -d "$D" ]] && dest_dir=1
        for (( x = 0; x < last; x++ )); do
          src="${NONOPT[x]}"
          if [[ "$c0" == mv || "$c0" == gmv ]]; then write_target "$src" 1; fi
          if (( dest_dir )); then
            s2="${src%/}"; write_target "$D/${s2##*/}" 0
            [[ "$src" == */ || "$c0" == rsync ]] && write_target "$D" 1
          else
            write_target "$D" 0
          fi
        done
      fi ;;
    dd)
      for w in ${ARGS[@]+"${ARGS[@]}"}; do [[ "$w" == of=* ]] && write_target "${w#of=}" 0; done ;;
  esac
done

# 3d. builds must not use local-only mock settings
build_re='(flutter[[:space:]]+build|fvm[[:space:]]+flutter[[:space:]]+build|gradlew[^|;&]*(assemble|bundle)|xcodebuild|fastlane|eas[[:space:]]+build|(npm|pnpm|yarn)[[:space:]]+(run[[:space:]]+)?build|next[[:space:]]+build|vite[[:space:]]+build|docker[[:space:]]+build)'
if [[ "$cmd" =~ $build_re ]] && grep -qiE '(USE_?MOCK|MOCK_?MODE|ENABLE_?MOCK|MOCK_?DATA)=(true|1|on|yes)|dart_defines/(local|mock)[^[:space:]]*\.json|mock-data|목업|\.env\.local|LOCAL[-_]ONLY' <<<"$cmd"; then
  decide deny "빌드 명령에 로컬 전용 목업 설정이 들어 있어서 막았습니다. 목업 데이터와 로컬 전용 설정은 빌드에 쓰지 않습니다. 스테이징이나 운영용 설정 파일로 다시 빌드하세요. 로컬에서 화면만 확인하려면 빌드 대신 개발 실행(flutter run 등)을 쓰세요."
fi

(( ${#COMMIT_DIRS[@]} || ${#PUSH_DIRS[@]} || ${#MERGE_DIRS[@]} || is_pr || is_text )) || exit 0
is_repo() { [[ -d "$1" ]] && git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }

# 3a. AI attribution (00 세션 공통 지침 §8)
SIGN_RE='Co-Authored-By:.*(Claude|anthropic)|Generated with \[?Claude'
sign_deny() { decide deny "커밋과 PR에는 AI 서명이나 co-author 표기를 넣지 않습니다(00 세션 공통 지침 §8). 해당 줄을 빼고 다시 실행하세요."; }
if (( ${#COMMIT_DIRS[@]} || is_pr )); then
  grep -qiE "$SIGN_RE" <<<"$cmd" && sign_deny
  for f in ${COMMIT_MSGF[@]+"${COMMIT_MSGF[@]}"}; do [[ "$f" != - && -f "$f" ]] && grep -v '^#' "$f" | grep -qiE "$SIGN_RE" && sign_deny; done
fi

# 3b. secrets never go into a commit, a push, a commit message or a PR body (지침서 15). Shared scanner with the git hooks.
SCAN="${SECRET_SCAN:-$HOME/.claude/hooks/secret-scan.sh}"
secret_block() { decide deny "비밀값으로 보이는 것이 있어서 막았습니다(지침서 15, 어떤 경우에도 커밋과 푸시 금지). 값을 지우고 .env나 비밀 관리로 옮기세요. 이미 원격에 올라간 값이면 재발급을 요청하세요. 진짜 비밀값이 아니면 사용자에게 알리세요(허용 목록은 사용자만 고칩니다).
$1"; }
push_revs_of() { # $1=dir, PA=(push args) -> REVS
  local t pos=() skip=0 src
  REVS=()
  for t in ${PA[@]+"${PA[@]}"}; do
    if (( skip )); then skip=0; continue; fi
    case "$t" in
      --all|--mirror|--tags|--branches) REVS=(--branches --tags); return ;;
      -o|--push-option|--repo|--receive-pack|--exec) skip=1 ;;
      -*) ;;
      *) pos+=("$t") ;;
    esac
  done
  for t in ${pos[@]+"${pos[@]:1}"}; do
    src="${t#+}"; src="${src%%:*}"
    [[ -n "$src" ]] && git -C "$1" rev-parse -q --verify "$src^{commit}" >/dev/null 2>&1 && REVS+=("$src")
  done
  (( ${#REVS[@]} )) || REVS=(HEAD)
}
if [[ -x "$SCAN" ]]; then
  for (( i = 0; i < ${#COMMIT_DIRS[@]}; i++ )); do
    d="${COMMIT_DIRS[i]}"; is_repo "$d" || continue
    out=$("$SCAN" staged "$d") || secret_block "$out"
    if (( COMMIT_ALL[i] )); then out=$("$SCAN" worktree "$d") || secret_block "$out"; fi
  done
  for (( i = 0; i < ${#PUSH_DIRS[@]}; i++ )); do
    d="${PUSH_DIRS[i]}"; is_repo "$d" || continue
    IFS=$'\x1f' read -r -a PA <<<"${PUSH_ARGS[i]}"
    # the git pre-push hook checks the exact refs again, so a parse miss here is still caught there
    push_revs_of "$d"
    out=$("$SCAN" range "$d" "${REVS[@]}" --not --remotes) || secret_block "$out"
  done
  if (( ${#COMMIT_DIRS[@]} || is_pr || is_text )); then
    out=$(printf '%s' "$cmd" | "$SCAN" text) || secret_block "$out"
    for f in ${COMMIT_MSGF[@]+"${COMMIT_MSGF[@]}"}; do [[ "$f" != - && -f "$f" ]] && { out=$("$SCAN" text < "$f") || secret_block "$out"; }; done
  fi
fi

# 3f. personal material in shared repos (the same check as the git pre-commit hook)
PSCAN="${PERSONAL_SCAN:-$HOME/.claude/hooks/personal-scan.sh}"
if [[ -x "$PSCAN" ]]; then
  for d in ${COMMIT_DIRS[@]+"${COMMIT_DIRS[@]}"}; do
    is_repo "$d" || continue
    out=$("$PSCAN" "$d") || decide deny "공용 저장소에 개인 자료가 들어가서 막았습니다(지침서 12, 13, 14). 절대 경로는 저장소 기준 상대 경로로, 개인 노트 위치는 빼고 내용만 적으세요. 할 일 목록과 발신함 목록은 커밋하지 않습니다.
$out"
  done
fi

# 3c. local-only mock data and mock settings never go into a commit or a push (memory: mock-json-testing)
# 3e. no personal absolute paths in commits (지침서 12 받은 자료 정리)
mock_check() { # $1=files $2=diff $3=where
  local bad_files bad_lines plus
  bad_files=$(grep -iE '(^|/)(mock-data|mocks?|__mocks__|local-only)/|(^|/)[^/]*(mock|목업)[^/]*\.json$|(^|/)\.env\.local$|(^|/)dart_defines/(local|mock)[^/]*\.json$' <<<"$1" \
              | grep -viE '(^|/)(test|tests|__tests__|spec|integration_test)/' \
              | { if [[ -n "$MOCK_ALLOW_PATHS_RE" ]]; then grep -viE "$MOCK_ALLOW_PATHS_RE"; else cat; fi; } | head -5)
  plus=$(grep -E '^\+' <<<"$2" | grep -vE '^\+\+\+')
  bad_lines=$( { grep -iE '(USE_?MOCK|MOCK_?MODE|ENABLE_?MOCK|MOCK_?DATA|useMock|mockMode|enableMock)[^=:]{0,3}[=:][[:space:]]*["'"'"']?(true|1|on|yes)\b' <<<"$plus"
                 # marker convention: uppercase LOCAL-ONLY anywhere, or "로컬 전용" written as a code comment
                 grep -E 'LOCAL[-_]ONLY|(//|#|/\*|<!--|--)[[:space:]]*\[?로컬[[:space:]]*전용' <<<"$plus"; } | head -5 | cut -c1-100)
  if [[ -n "$bad_files$bad_lines" ]]; then
    decide deny "${3}에 로컬 전용 목업 데이터나 목업 설정이 들어 있어서 막았습니다. 목업 파일과 목업을 켜는 설정, 로컬 전용 표시가 붙은 줄은 커밋, 푸시, 빌드에 넣지 않습니다. 스테이징에서 빼고(git restore --staged), 이미 커밋했다면 그 커밋에서 빼세요.
${bad_files}${bad_files:+
}${bad_lines}"
  fi
}
for (( i = 0; i < ${#COMMIT_DIRS[@]}; i++ )); do
  d="${COMMIT_DIRS[i]}"; is_repo "$d" || continue
  # removed files are not added content (--diff-filter=ACMR)
  if (( COMMIT_ALL[i] )); then
    files=$( { "${GQ[@]}" -C "$d" diff --cached --name-only --diff-filter=ACMR; "${GQ[@]}" -C "$d" diff --name-only --diff-filter=ACMR; } 2>/dev/null)
    added=$("${GQ[@]}" -C "$d" diff HEAD -U0 --diff-filter=ACMR 2>/dev/null)
  else
    files=$("${GQ[@]}" -C "$d" diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
    added=$("${GQ[@]}" -C "$d" diff --cached -U0 --diff-filter=ACMR 2>/dev/null)
  fi
  mock_check "$files" "$added" "커밋"
  # /home/<name>/ counts at the start of a path only (line start, space, quote, backtick, =, (, :), and not for the
  # system accounts of containers and CI. A code folder named home (features/home/) is not a personal path.
  abs_lines=$(grep -E '^\+' <<<"$added" | grep -vE '^\+\+\+' \
              | perl -ne 'print if m{/Users/[A-Za-z0-9._-]+/|(?:^|[+\s"\x27`=(:])/home/(?!(?:node|runner|ubuntu|app|root|vscode|circleci|jenkins|gitpod|codespace)/)[a-z][a-z0-9._-]*/|[A-Za-z]:\\\\Users\\\\|/private/var/folders/|/var/folders/[a-z0-9_]{2}/}' \
              | head -5 | cut -c1-110)
  if [[ -n "$abs_lines" ]]; then
    decide deny "새로 추가한 줄에 개인 절대 경로가 있어서 막았습니다. 다른 사람이 저장소를 받으면 열리지 않습니다. 저장소 기준 상대 경로로 바꾸고, 저장소 밖 파일은 _수신함/ 으로 복사한 뒤 그 경로를 쓰세요(지침서 12 받은 자료 정리).
$abs_lines"
  fi
done
for (( i = 0; i < ${#PUSH_DIRS[@]}; i++ )); do
  d="${PUSH_DIRS[i]}"; is_repo "$d" || continue
  IFS=$'\x1f' read -r -a PA <<<"${PUSH_ARGS[i]}"
  push_revs_of "$d"; [[ "${REVS[0]}" == --branches ]] && REVS=(HEAD)
  # what each sent branch adds over its upstream (or origin's default branch)
  for rev in "${REVS[@]}"; do
    base=$(git -C "$d" rev-parse -q --verify "$rev@{u}" 2>/dev/null || git -C "$d" rev-parse -q --verify origin/HEAD 2>/dev/null)
    [[ -n "$base" ]] || continue
    files=$("${GQ[@]}" -C "$d" diff --name-only --diff-filter=ACMR "$base...$rev" 2>/dev/null)
    added=$("${GQ[@]}" -C "$d" diff -U0 --diff-filter=ACMR "$base...$rev" 2>/dev/null)
    mock_check "$files" "$added" "푸시할 커밋"
  done
done

# 2. branch rule (user, 2026-11-04):
#    - feature, fix, hotfix and other work branches: commit and push freely
#    - dev, main, prod, staging (and their usual aliases): no push and no merge without the user.
#      Ask every time; the review result must be shown to the user first.
free_repo() { local r; for r in ${FREE_N[@]+"${FREE_N[@]}"}; do is_under "$1" "$r" && return 0; done; return 1; }
free_branch() { # $1=repo dir $2=branch: listed as free for that project in FREE_BRANCHES_BY_REPO
  [[ -n "$2" ]] || return 1
  local e dir list main c; main=""
  c=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && { norm "${c%/.git}" /; main="$NP"; }
  norm "$1" /; local here="$NP"
  for e in ${FREE_BRANCHES_BY_REPO[@]+"${FREE_BRANCHES_BY_REPO[@]}"}; do
    dir="${e%=*}"; list=",${e##*=},"; norm "$dir" /; dir="$NP"
    { is_under "$here" "$dir" || { [[ -n "$main" ]] && is_under "$main" "$dir"; }; } || continue
    [[ "$list" == *",$2,"* ]] && return 0
  done
  return 1
}
# 승인 창에 보일 설명. 사용자가 이 글만 읽고 예, 아니오를 고를 수 있게 무엇이 어디로 가는지 실제 값으로 쓴다.
repo_name() { local c; c=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); c="${c%/.git}"; echo "${c##*/}"; }
commit_lines() { # $1=dir $2=range  -> 커밋 목록(최대 8개)과 바뀐 파일 요약
  local n list stat
  n=$(git -C "$1" rev-list --count "$2" 2>/dev/null) || { echo "  (커밋 목록을 읽지 못했습니다)"; return; }
  # 커밋마다 제목과, 본문이 있으면 첫 두 줄(왜, 무엇을 바꿨는지)
  list=$(git -C "$1" log --format='%h%x1f%s%x1f%b%x1e' -n 8 "$2" 2>/dev/null | perl -CSDA -0x1e -ne '
    chomp; my ($h,$s,$b) = split /\x1f/, $_, 3; next unless defined $s; $h =~ s/^\s+//;
    print "  - $h $s\n";
    my @l = grep { /\S/ && !/^(refs #|Co-Authored-By)/i } split /\n/, ($b // "");
    print "      $_\n" for map { substr($_, 0, 100) } @l[0 .. ($#l < 1 ? $#l : 1)];')
  local files; files=$(git -C "$1" diff --numstat --no-renames "${2%%..*}...${2##*..}" 2>/dev/null | awk -F'\t' '
    { a=($1=="-")?"줄 수를 셀 수 없는 파일":"+"$1; d=($2=="-")?"":" -"$2; f[NR]="  - "$3"  ("a d")"
      n=split($3, p, "/"); top=(n>1)?p[1]"/":"(맨 위)"; c[top]++; if ($1!="-") { ad[top]+=$1; de[top]+=$2 } } END {
      if (NR<=12) { for (i=1;i<=NR;i++) print f[i] }
      else { print "99999999\t  (파일이 " NR "개라 맨 위 폴더별로 묶음)"; for (k in c) printf "%08d\t  - %s  파일 %d개 (+%d -%d)\n", c[k], k, c[k], ad[k], de[k] } }' | sort -r | sed 's/^[0-9]*\t//' | head -15)
  stat=$(git -C "$1" diff --shortstat "${2%%..*}...${2##*..}" 2>/dev/null | sed 's/^ *//')
  local behind; behind=$(git -C "$1" rev-list --count "${2##*..}..${2%%..*}" 2>/dev/null)
  echo "${3:-올라가는} 커밋 ${n}개:"; echo "$list"; (( n > 8 )) && echo "  … 외 $(( n - 8 ))개"
  [[ -n "$stat" ]] && echo "바뀌는 양: $stat"
  [[ -n "$files" ]] && { echo "바뀐 파일:"; echo "$files"; }
  [[ -z "${3:-}" && -n "$behind" && "$behind" != 0 ]] && echo "주의: 받는 쪽에 이쪽에 없는 커밋이 ${behind}개 있습니다(먼저 받아 와야 할 수 있음)."
  return 0
}
push_card() { # $1=dir $2=remote $3=src $4=target
  local rr="refs/remotes/$2/$4" body
  if git -C "$1" rev-parse -q --verify "$rr" >/dev/null; then body=$(commit_lines "$1" "$rr..${3:-HEAD}")
  else body="원격에 아직 없는 $4 브랜치를 새로 만듭니다."; fi
  printf '%s\n' "[확인 필요] 보호 브랜치로 푸시" \
    "저장소: $(repo_name "$1")" \
    "무엇을: ${3:-지금 브랜치}의 커밋을 원격($2)의 $4 브랜치에 바로 올립니다." \
    "$body" "" \
    "예: 원격 $4에 바로 반영됩니다. 팀원과 배포가 이 내용을 받게 됩니다." \
    "아니오: 아무것도 올라가지 않고, Claude가 이유를 묻거나 다른 방법을 찾습니다." \
    "고르는 기준: 이 변경의 리뷰와 테스트 결과를 대화에서 먼저 봤으면 예, 못 봤거나 처음 듣는 커밋이 있으면 아니오."
}
merge_card() { # $1=dir $2=current branch $3=kind
  local where what
  local src body=""
  if [[ "$3" == git ]]; then
    src=$(printf '%s' "$cmd" | perl -ne 'if (/\bmerge\b(.*)/) { my @a = grep { !/^-/ } split /\s+/, $1; for (@a) { s/[;&|].*//; } @a = grep { length } @a; print $a[-1] if @a }')
    where="지금 브랜치 ${2:-?}"; what="${src:-다른 브랜치}의 커밋을 ${2:-?}에 합칩니다."
    [[ -n "$src" ]] && body=$(commit_lines "$1" "HEAD..$src" "들어오는")
  else where="원격 저장소의 PR"; what="원격에서 PR을 합칩니다(되돌리려면 되돌리기 커밋이 필요합니다)."; fi
  printf '%s\n' "[확인 필요] 머지" \
    "저장소: $(repo_name "$1")" \
    "어디에: $where" \
    "무엇을: $what" \
    "실행할 명령: $(printf '%s' "$cmd" | tr '\n' ' ' | cut -c1-160)" ${body:+"$body"} "" \
    "예: 합쳐집니다. 보호 브랜치면 이어서 푸시나 배포에 쓰입니다." \
    "아니오: 합치지 않고, Claude가 이유를 묻거나 다른 방법을 찾습니다." \
    "고르는 기준: 합칠 커밋 목록과 리뷰, 테스트 결과를 대화에서 먼저 봤으면 예, 아니면 아니오."
}

for (( i = 0; i < ${#PUSH_DIRS[@]}; i++ )); do
  d="${PUSH_DIRS[i]}"; free_repo "$d" && continue
  IFS=$'\x1f' read -r -a PA <<<"${PUSH_ARGS[i]}"
  br="${PUSH_BRS[i]}"
  # targets: refspecs after the remote; none given -> the current branch and its upstream; --all/--mirror -> protected
  pos=(); skip=0; all=0
  for t in ${PA[@]+"${PA[@]}"}; do
    if (( skip )); then skip=0; continue; fi
    case "$t" in
      --all|--mirror|--branches) all=1 ;;
      -o|--push-option|--repo|--receive-pack|--exec) skip=1 ;;
      -*) ;;
      *) pos+=("$t") ;;
    esac
  done
  targets=()
  if (( all )); then targets=(main)
  elif (( ${#pos[@]} >= 2 )); then
    for ref in "${pos[@]:1}"; do ref=${ref#+}; ref=${ref##*:}; ref=${ref#refs/heads/}; [[ "$ref" == HEAD ]] && ref=$br; targets+=("$ref"); done
  else
    targets=("$br")
    up=$(git -C "$d" rev-parse --abbrev-ref "${br:-HEAD}@{upstream}" 2>/dev/null); [[ -n "$up" ]] && targets+=("${up#*/}")
  fi
  for t in ${targets[@]+"${targets[@]}"}; do
    if [[ "$t" =~ $PROTECTED_BRANCHES_RE ]] && ! free_branch "$d" "$t"; then
      remote="${pos[0]:-origin}"; src="$br"
      for ref in "${pos[@]:1}"; do r2=${ref#+}; [[ "$r2" == *:* ]] && { [[ "${r2##*:}" == "$t" || "${r2##*:}" == "refs/heads/$t" ]] && src="${r2%%:*}"; }; done
      [[ "$src" == HEAD || -z "$src" ]] && src="$br"
      decide ask "$(push_card "$d" "$remote" "$src" "$t")"
    fi
  done
done
for (( i = 0; i < ${#MERGE_DIRS[@]}; i++ )); do
  d="${MERGE_DIRS[i]}"; free_repo "$d" && continue
  [[ "${MERGE_KINDS[i]}" == git ]] && free_branch "$d" "${MERGE_BRS[i]}" && continue
  if [[ "${MERGE_KINDS[i]}" != git || "${MERGE_BRS[i]}" =~ $PROTECTED_BRANCHES_RE ]]; then
    decide ask "$(merge_card "$d" "${MERGE_BRS[i]}" "${MERGE_KINDS[i]}")"
  fi
done
exit 0
