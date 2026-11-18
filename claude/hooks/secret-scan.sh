#!/usr/bin/env bash
# Secret scanner (claude-work-harness, 지침서 15 비밀값은 커밋도 푸시도 하지 않는다).
# Used by the Claude guard hook and by the global git hooks (pre-commit, pre-push).
#
#   secret-scan.sh staged   [repo]                 what the next commit would contain (index)
#   secret-scan.sh worktree [repo]                 tracked files changed in the work tree (commit -a, commit <paths>)
#   secret-scan.sh range    [repo] <rev args...>   every commit in a range, full history of each (push)
#   secret-scan.sh text                            text on stdin (commit message, PR body)
#   secret-scan.sh path     <file|folder>...       files on disk, e.g. material the user handed over (지침서 12)
#   secret-scan.sh mask     <file|folder>...       rewrite found values in text files as <가림> (in place)
#
# Archives (zip, tar, 7z, rar, single .gz/.bz2/.xz ...) are opened and their entries are checked by name and by content.
# An archive inside an archive is blocked by name (it is not opened a second time).
# Archives under _수신함/ or _발신함/ are blocked by name: what the user hands over is never committed as an archive.
# Prints one line per finding ("파일: 내용(가림)") and exits 1 when anything is found, 0 when clean.
# Fails closed: when git or perl fails, it prints why and exits 1 (a scan that did not run never counts as clean).
# False positives: add a regex line to ~/.claude/harness/secret-allow.txt (only the user edits that file).
set -u
mode="${1:-staged}"; shift || true
repo="."
case "$mode" in staged|worktree|range) if [[ $# -gt 0 && -d "$1" ]]; then repo="$1"; shift; fi ;; esac
ALLOW="${SECRET_ALLOW:-$HOME/.claude/harness/secret-allow.txt}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# file names that are secrets by themselves
NAME_RE='(^|/)(\.env(\.[^/]*)?|[^/]*adminsdk[^/]*\.json|[^/]*service[-_]?account[^/]*\.json|credentials?\.json|client_secret[^/]*\.json|[^/]*\.tfvars|[^/]*\.tfstate(\.backup)?|[^/]*\.(pem|p8|p12|pfx|key|keystore|jks|mobileprovision|ovpn|kdbx)|google-services\.json|GoogleService-Info\.plist|key\.properties|keystore\.properties|id_(rsa|dsa|ecdsa|ed25519)|\.npmrc|\.pypirc|\.netrc|\.htpasswd|_비밀/.*|[^/]*(password|passwd|secret|credential|private[-_]?key)[^/]*\.(txt|json|env|ya?ml|ini|conf|cfg|properties)|[^/]*(password|passwd|secret|credential)s?|(s3|aws|gcp|minio)[-_]?(config|credentials?)[^/]*\.(json|ya?ml|ini|txt)|(_수신함|_발신함)/.*\.(zip|jar|7z|rar|alz|egg|tar|tgz|gz|bz2|xz))$'
NAME_OK_RE='\.(example|sample|template|dist)$|(^|/)\.env\.(example|sample|template|dist)$|\.pub$'
ARCH_RE='\.(zip|jar|7z|rar|tar|tgz|gz|bz2|xz|tbz2?|txz)$'
NESTED_RE='!/.*\.(zip|jar|7z|rar|alz|egg|tar|tgz|gz|bz2|xz|tbz2?|txz)$'
GIT=(git -C "$repo" -c core.quotepath=off)
die() { echo "비밀값 검사를 끝내지 못해서 막았습니다: $1"; exit 1; }

# The patterns, shared by scan and mask.
PERL_CORE='
  use Encode qw(decode_utf8);
  no warnings qw(non_unicode surrogate nonchar);   # 바이너리가 섞인 diff를 읽을 때 나는 경고("non-Unicode code point")를 숨김. 검사 결과에는 영향 없음

  our @re = (
    [ "AWS 액세스 키",        qr/(?<![A-Z0-9])(AKIA|ASIA)[0-9A-Z]{16}(?![A-Z0-9])/ ],
    [ "개인 키 블록",          qr/-----BEGIN [A-Z ]*PRIVATE KEY-----/ ],
    [ "서비스 계정 개인 키",    qr/"private_key"\s*:\s*"-----BEGIN/ ],
    [ "Anthropic/OpenAI 키",  qr/(?<![A-Za-z0-9_-])sk-(ant-|proj-|live-)?[A-Za-z0-9_-]{20,}/ ],
    [ "GitHub 토큰",          qr/(?<![A-Za-z0-9_])(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})/ ],
    [ "GitLab 토큰",          qr/(?<![A-Za-z0-9_])glpat-[A-Za-z0-9_-]{20,}/ ],
    [ "Slack 토큰",           qr/(?<![A-Za-z0-9_-])xox[abprs]-[A-Za-z0-9-]{10,}/ ],
    [ "Google API 키",        qr/(?<![A-Za-z0-9_])AIza[0-9A-Za-z_-]{35}/ ],
    [ "Stripe 키",            qr/(?<![A-Za-z0-9_])(sk|rk)_live_[0-9A-Za-z]{16,}/ ],
    [ "토스페이먼츠 키",       qr/(?<![A-Za-z0-9_])(live|test)_(sk|gsk|ck)_[0-9A-Za-z]{16,}/ ],
    [ "JWT 토큰",             qr/(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/ ],
    [ "npm 토큰",             qr/_authToken\s*=\s*[^\s\$]{8,}|(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{36}/ ],
    [ "접속 문자열 비밀번호",   qr{[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s:@\$\{<]{6,}@} ],
    [ "비밀값 조각 대입",       qr/(?i)(?:secret|passw(?:or)?d(?:hash|digest)?|pwd|api[_-]?key|apikey|access[_-]?key|private[_-]?key|client[_-]?secret|auth[_-]?token|access[_-]?token|refresh[_-]?token|bearer|credential|store[_-]?password|key[_-]?password|[a-z0-9]_key)["\x27]?\s*[:=]\s*((?:(?:"[^"\n]*"|\x27[^\x27\n]*\x27)\s*\+\s*)+(?:"[^"\n]*"|\x27[^\x27\n]*\x27))/ ],
    [ "함수 인자 비밀값",       qr/(?i)(?:secret|passw(?:or)?d(?:hash|digest)?|pwd|api[_-]?key|apikey|access[_-]?key|private[_-]?key|client[_-]?secret|auth[_-]?token|access[_-]?token|refresh[_-]?token|bearer|credential|store[_-]?password|key[_-]?password|[a-z0-9]_key)["\x27]?\s*[:=]\s*([A-Za-z_][\w.]*)\(\s*(?:"([^"\s]{8,})"|\x27([^\x27\s]{8,})\x27)/ ],
    [ "비밀값 대입",           qr/(?i)(?:secret|passw(?:or)?d(?:hash|digest)?|pwd|api[_-]?key|apikey|access[_-]?key|private[_-]?key|client[_-]?secret|auth[_-]?token|access[_-]?token|refresh[_-]?token|bearer|credential|store[_-]?password|key[_-]?password|[a-z0-9]_key)["\x27]?\s*[:=]\s*(?:"([^"\s]{8,})"|\x27([^\x27\s]{8,})\x27|([A-Za-z0-9_\-\/+=.]{16,}))/ ],
  );
  our $placeholder = qr/(?i)^(?:x{3,}|\*{3,}|\.{3,}|<[^>]*>|\$\{?[A-Za-z_]|your[_-]|change[_-]?me|example|sample|dummy|placeholder|test[_-]?(?:key|secret|token|password)|redacted|가림|마스킹|null|none|undefined|true|false|process\.env|os\.environ|getenv|env\(|config\.|settings\.|\.{1,2}\/|~\/)/;
  our $filelike = qr/^[A-Za-z0-9_.\/-]+\.(txt|json|pem|key|env|ya?ml|p12|crt|cer)$/i;
  # Redis-style key names: lowercase words joined by colons, e.g. app:seen-set, lock:{id}
  our $keyname = qr/^(?:[a-z][a-z0-9_-]{0,40}|\{[^}]{1,40}\}|\$\{[^}]{1,40}\}|\*|%[sd])(?::(?:[a-z][a-z0-9_-]{0,40}|\{[^}]{1,40}\}|\$\{[^}]{1,40}\}|\*|%[sd]))+:?$/;
  sub not_secret_value { my $v = shift; return $v =~ $placeholder || $v =~ $filelike || $v =~ $keyname || $v =~ /^[a-z]+(\.[a-z]+)+$/i; }
'

# expand_archive <label> <file>: entry names go to extra_names, text entries go to $TMP/extra
extra_names=""; ax=0; : >"$TMP/extra"
expand_archive() {
  local label="$1" f="$2" d e rel
  ax=$((ax + 1)); d="$TMP/x$ax"; mkdir -p "$d"
  if (( $(wc -c <"$f") > 200 * 1024 * 1024 )); then extra_names+="$label!/(200MB가 넘어 열어 보지 못함)"$'\n'; return; fi
  if ! tar -xf "$f" -C "$d" 2>/dev/null; then
    case "$label" in
      *.zip|*.jar) unzip -qq -o "$f" -d "$d" 2>/dev/null ;;
      *.gz)  e="${label##*/}"; gzip  -dc <"$f" >"$d/${e%.gz}"  2>/dev/null ;;
      *.bz2) e="${label##*/}"; bzip2 -dc <"$f" >"$d/${e%.bz2}" 2>/dev/null ;;
      *.xz)  e="${label##*/}"; xz    -dc <"$f" >"$d/${e%.xz}"  2>/dev/null ;;
    esac
  fi
  while IFS= read -r -d '' e; do
    rel="${e#"$d"/}"
    extra_names+="$label!/$rel"$'\n'
    (( $(wc -c <"$e") <= 2 * 1024 * 1024 )) || continue
    grep -Iq . "$e" 2>/dev/null || continue
    { printf '+++ b/%s!/%s\n' "$label" "$rel"; sed 's/^/+/' "$e"; echo; } >>"$TMP/extra"
  done < <(find "$d" -type f -print0 2>/dev/null)
}

# scan_disk <label-prefix> <file>: one file on disk (path mode)
scan_disk() {
  local label="$1" f="$2"
  extra_names+="$label"$'\n'
  if [[ "$label" =~ $ARCH_RE ]]; then expand_archive "$label" "$f"; return; fi
  (( $(wc -c <"$f") <= 2 * 1024 * 1024 )) || return 0
  grep -Iq . "$f" 2>/dev/null || return 0
  { printf '+++ b/%s\n' "$label"; sed 's/^/+/' "$f"; echo; } >>"$TMP/extra"
}

if [[ "$mode" == mask ]]; then
  files=()
  for a in "$@"; do
    if [[ -d "$a" ]]; then while IFS= read -r -d '' f; do grep -Iq . "$f" 2>/dev/null && files+=("$f"); done < <(find "$a" -type f -print0)
    elif [[ -f "$a" ]]; then grep -Iq . "$a" 2>/dev/null && files+=("$a"); fi
  done
  (( ${#files[@]} )) || exit 0
  perl -CSDA -Mutf8 -e "$PERL_CORE"'
    my $total = 0;
    for my $f (@ARGV) {
      open my $in, "<:encoding(UTF-8)", $f or next; local $/; my $s = <$in>; close $in; next unless defined $s;
      my $orig = $s; my $n = 0;
      $n += ($s =~ s/-----BEGIN ([A-Z ]*)PRIVATE KEY-----.*?-----END \1PRIVATE KEY-----/<가림: 개인 키>/gs);
      my @lines = split /\n/, $s, -1;
      for my $l (@lines) {
        for my $r (@re) {
          my ($name, $rx) = @$r;
          next if $name =~ /개인 키|조각 대입|함수 인자/;
          if ($name eq "비밀값 대입") {
            my @spans;
            while ($l =~ /$rx/g) { for my $g (1 .. 3) { next unless defined $-[$g]; my $v = substr($l, $-[$g], $+[$g] - $-[$g]); last if $g == 3 && substr($l, $+[$g]) =~ /^\s*\(/; push @spans, [$-[$g], $+[$g]] unless not_secret_value($v); last } }
            for my $sp (reverse @spans) { substr($l, $sp->[0], $sp->[1] - $sp->[0]) = "<가림>"; $n++ }
          } else {
            $n += ($l =~ s/$rx/substr($&, 0, 4) . "<가림>"/ge);
          }
        }
      }
      $s = join("\n", @lines);
      next if $s eq $orig;
      open my $out, ">:encoding(UTF-8)", $f or next; print $out $s; close $out;
      print "가림 ${n}곳: $f\n"; $total += $n;
    }
    print "가린 곳 없음\n" unless $total;
  ' "${files[@]}"
  exit 0
fi

# The change goes to files, never to a variable or an env value: a big change must not be cut off or skipped.
N="$TMP/names"; P="$TMP/patch"; : >"$N"; : >"$P"
case "$mode" in
  staged)   "${GIT[@]}" diff --cached --name-only --diff-filter=ACMR >"$N" 2>"$TMP/err" || die "$(head -1 "$TMP/err")"
            "${GIT[@]}" diff --cached -U0 --no-color --diff-filter=ACMR >"$P" 2>"$TMP/err" || die "$(head -1 "$TMP/err")"
            while IFS= read -r f; do [[ -n "$f" && "$f" =~ $ARCH_RE ]] || continue
              "${GIT[@]}" cat-file blob ":$f" >"$TMP/blob" 2>/dev/null && expand_archive "$f" "$TMP/blob"; done <"$N" ;;
  worktree) "${GIT[@]}" diff --name-only --diff-filter=ACMR >"$N" 2>"$TMP/err" || die "$(head -1 "$TMP/err")"
            "${GIT[@]}" diff -U0 --no-color --diff-filter=ACMR >"$P" 2>"$TMP/err" || die "$(head -1 "$TMP/err")"
            while IFS= read -r f; do [[ -n "$f" && "$f" =~ $ARCH_RE && -f "$repo/$f" ]] || continue
              expand_archive "$f" "$repo/$f"; done <"$N" ;;
  range)    # merge commits are shown against their first parent, so a value put in by the merge itself is seen
            "${GIT[@]}" log --format= --name-only --diff-filter=ACMR --diff-merges=first-parent "$@" >"$TMP/n0" 2>"$TMP/err" || die "$(head -1 "$TMP/err")"
            sort -u "$TMP/n0" >"$N"
            "${GIT[@]}" log -p -U0 --no-color --format='commit %h' --diff-filter=ACMR --diff-merges=first-parent "$@" >"$P" 2>"$TMP/err" || die "$(head -1 "$TMP/err")"
            while IFS= read -r f; do [[ -n "$f" && "$f" =~ $ARCH_RE ]] || continue
              while IFS= read -r h; do
                "${GIT[@]}" cat-file blob "$h:$f" >"$TMP/blob" 2>/dev/null && expand_archive "$f" "$TMP/blob"
              done < <("${GIT[@]}" log --format=%H --diff-filter=ACMR --diff-merges=first-parent "$@" -- "$f" 2>/dev/null)
            done <"$N" ;;
  text)     { sed 's/^/+/'; echo; } >"$P" ;;
  path)     for a in "$@"; do
              a="${a%/}"; base="${a##*/}"
              if [[ -d "$a" ]]; then while IFS= read -r -d '' f; do scan_disk "$base/${f#"$a"/}" "$f"; done < <(find "$a" -type f -print0)
              elif [[ -f "$a" ]]; then scan_disk "$base" "$a"; fi
            done ;;
  *) echo "unknown mode: $mode" >&2; exit 2 ;;
esac
printf '%s' "$extra_names" >>"$N"; cat "$TMP/extra" >>"$P"

bad_names=$( { grep -E "$NAME_RE" "$N" | grep -vE "$NAME_OK_RE" | sed 's/^/파일 이름: /'
               grep -E "$NESTED_RE" "$N" | sed 's/^/압축 안의 압축(열어 보지 못해 막음): /'; } | sort -u)

hits=$(ALLOWFILE="$ALLOW" perl -CSDA -Mutf8 -e "$PERL_CORE"'
  my $p = do { local $/; open my $in, "<:raw", $ARGV[0] or die "patch: $!"; <$in> } // "";
  $p = decode_utf8($p);
  my @allow;
  if (open my $fh, "<:encoding(UTF-8)", $ENV{ALLOWFILE}) { while (<$fh>) { chomp; next if /^\s*(#|$)/; push @allow, qr/$_/ } }
  my ($file, $commit) = ("", ""); my %seen; my @out;
  for my $line (split /\n/, $p) {
    if ($line =~ /^commit (\S+)/) { $commit = $1; next }
    if ($line =~ m{^\+\+\+ b/(.*)}) { $file = $1; next }
    next unless $line =~ /^\+/; next if $line =~ /^\+\+\+/;
    my $body = substr($line, 1);
    for my $r (@re) {
      my ($name, $rx) = @$r;
      next unless $body =~ $rx;
      if ($name eq "비밀값 대입") { my $v = $1 // $2 // $3 // ""; next if not_secret_value($v);
        # an unquoted value followed by "(" is a function call (e.g. unusablePasswordHash()), not a literal; literals inside calls are the next rules
        next if defined $-[3] && substr($body, $+[3]) =~ /^\s*\(/; }
      if ($name eq "비밀값 조각 대입") { my $j = join("", ($1 =~ /["\x27]([^"\x27]*)["\x27]/g)); next if length($j) < 8 || not_secret_value($j); }
      if ($name eq "함수 인자 비밀값") { my ($fn, $v) = ($1, $2 // $3 // "");
        # test helpers that build or disable a password take a short label, not a password (makeTestPassword('login-wrong'))
        next if $fn =~ /(?:^|\.)(?:make\w*|unusable\w*)password\w*$/i;
        next if not_secret_value($v); }
      next if grep { $body =~ $_ } @allow;
      (my $shown = $body) =~ s/([A-Za-z0-9_\-\/+=]{6})[A-Za-z0-9_\-\/+=.]{6,}/$1…(가림)/g;
      my $where = join(" ", grep { $_ ne "" } ($commit ? "커밋 $commit" : "", $file));
      my $msg = "$name: " . ($where ne "" ? "$where: " : "") . substr($shown, 0, 100);
      push @out, $msg unless $seen{$msg}++;
      last;
    }
  }
  print join("\n", @out[0 .. ($#out < 9 ? $#out : 9)]) if @out;
' "$P") || die "내용 검사(perl)가 실패함"

all=$(printf '%s\n%s\n' "$bad_names" "$hits" | sed '/^$/d')
[[ -z "$all" ]] && exit 0
echo "$all"
exit 1
