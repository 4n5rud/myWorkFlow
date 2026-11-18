#!/usr/bin/env bash
# Tests for secret-scan.sh. Fake secrets are built from pieces so this file itself never looks like a secret.
S="${SCAN:-$HOME/.claude/hooks/secret-scan.sh}"; pass=0; fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SECRET_ALLOW="$T/allow.txt"; : > "$SECRET_ALLOW"
# hermetic git: no user or system config, so the real global hooks never run inside the tests
# and git behaves as on a fresh machine (core.quotepath=true)
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
j() { printf '%s' "$@"; }   # join pieces

# fake values (pieces joined at run time)
AWS=$(j AKIA ABCDEFGHIJ KLMNOP)
ANT=$(j sk- ant-api03- AbCdEfGhIjKlMnOpQrSt Uv)
GH=$(j ghp_ 0123456789abcdefghij 0123456789ABCDEF)
GOOG=$(j AIza Sy0123456789abcdefghijklmnopq rstuvw)
TOSS=$(j live_ sk_ 0123456789abcdef GH)
JWT=$(j eyJ hbGciOiJIUzI1NiJ9 . eyJ zdWIiOiIxMjM0NTY3ODkwIn0 . SflKxwRJSMeKKF2QT4fwpMeJf36P)
PEM=$(j "-----BEGIN " "RSA PRIVATE" " KEY-----")
DBURL=$(j postgres:// app : S3cretPassw0rd @db.internal:5432/app)
KAKAO=$(j KAKAO_NATIVE_ APP_ KEY= 0123 4567 89ab cdef 0123 4567 89ab cdef)
STORE=$(j store Password= Hunter2 Hunter2)
PWLINE=$(j pass word= Xk29fjQ0 pLmn38aZ)

t() { # name expect(hit|clean) mode setup-fn
  local d="$T/$1"; mkdir -p "$d"; git -C "$d" init -q; git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo base > "$d/README.md"; git -C "$d" add README.md; git -C "$d" commit -qm init --no-verify; git -C "$d" tag base
  ( cd "$d" && bash -c "$4" )
  local out rc
  case "$3" in
    staged)   out=$("$S" staged "$d"); rc=$? ;;
    worktree) out=$("$S" worktree "$d"); rc=$? ;;
    range)    out=$("$S" range "$d" base..HEAD); rc=$? ;;
  esac
  if [[ $2 == hit && $rc == 1 ]] || [[ $2 == clean && $rc == 0 ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %-38s expect=%s rc=%s\n%s\n' "$1" "$2" "$rc" "$out"; fi
}
tt() { # text mode
  local out rc; out=$(printf '%s' "$3" | "$S" text); rc=$?
  if [[ $2 == hit && $rc == 1 ]] || [[ $2 == clean && $rc == 0 ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %-38s expect=%s rc=%s\n%s\n' "$1" "$2" "$rc" "$out"; fi
}

# content patterns (staged)
t aws_key          hit   staged "eval echo 'aws_id = $AWS' > c.txt; git add c.txt"
t anthropic_key    hit   staged "eval echo 'KEY=$ANT' > .cfg; git add .cfg"
t github_token     hit   staged "eval echo 'token: $GH' > ci.yml; git add ci.yml"
t google_key       hit   staged "eval echo 'const k = \"$GOOG\"' > k.ts; git add k.ts"
t toss_key         hit   staged "eval echo 'TOSS=$TOSS' > p.env.txt; git add p.env.txt"
t jwt              hit   staged "eval echo 'auth: $JWT' > a.md; git add a.md"
t pem_block        hit   staged "eval echo '$PEM' > k.txt; git add k.txt"
t db_url_password  hit   staged "eval echo 'DATABASE_URL=$DBURL' > d.txt; git add d.txt"
t kakao_app_key    hit   staged "eval echo $KAKAO > g.properties; git add g.properties"
t android_signing  hit   staged "eval echo $STORE > key.properties; git add -f key.properties"
# file names
t dotenv_forced    hit   staged "echo A=1 > .env; git add -f .env"
t service_account  hit   staged "echo '{}' > my-firebase-adminsdk-x.json; git add my-firebase-adminsdk-x.json"
t tfvars           hit   staged "echo x=1 > prod.tfvars; git add prod.tfvars"
t secret_folder    hit   staged "mkdir -p _수신함/_비밀; echo a > _수신함/_비밀/a.txt; git add -f _수신함/_비밀/a.txt"
t ssh_private      hit   staged "echo a > id_ed25519; git add id_ed25519"
t password_txt     hit   staged "mkdir -p keys; echo a > keys/postgres-password.txt; git add keys/postgres-password.txt"
t s3_config        hit   staged "echo '{}' > s3-config.json; git add s3-config.json"
t secret_noext     hit   staged "echo a > admin_secret; git add admin_secret"
t password_doc_ok  clean staged "echo a > password-policy.md; echo b > reset_password.ts; git add password-policy.md reset_password.ts"
# allowed
t env_example      clean staged "printf 'API_KEY=\nSECRET=your-secret-here\n' > .env.example; git add .env.example"
t placeholders     clean staged "printf 'password: \${DB_PASSWORD}\napi_key: <발급받은 키>\ntoken = process.env.TOKEN\n' > c.yml; git add c.yml"
t public_key       clean staged "echo ssh-ed25519 AAAA > id_ed25519.pub; git add id_ed25519.pub"
t file_reference   clean staged "printf -- '--from-file=password=./postgres-password.txt\\nkey_file = secrets/prod-signing.pem\\n' > s.sh; git add s.sh"
t real_pw_assign   hit   staged "eval echo $PWLINE > p.cfg; git add p.cfg"
t plain_code       clean staged "printf 'const passwordLabel = \"비밀번호\";\nfunction getApiKey() { return config.apiKey }\n' > a.ts; git add a.ts"
# work tree (commit -a, commit <path>)
t worktree_change  hit   worktree "eval echo 'x=$AWS' >> README.md"
# history in a push range: added then removed is still in history
t added_then_gone  hit   range "eval echo 'k=$GH' > t.txt; git add t.txt; git commit -qm add --no-verify; git rm -q t.txt; git commit -qm rm --no-verify"
# allowlist (user only)
t allow_listed     clean staged "eval echo 'demo_key = $AWS' > d.txt; git add d.txt; echo 'demo_key = AKIA' > \"$SECRET_ALLOW\""
: > "$SECRET_ALLOW"
# archives: opened and checked inside; any archive under _수신함/ or _발신함/ is blocked by name
t zip_with_env     hit   staged "mkdir -p b; echo A=1 > b/.env; echo hi > b/r.txt; zip -qr out.zip b; rm -rf b; git add out.zip"
t zip_with_key     hit   staged "mkdir -p b; eval echo 'token: $GH' > b/ci.yml; zip -qr out.zip b; rm -rf b; git add out.zip"
t zip_clean        clean staged "mkdir -p b; echo hello > b/r.txt; zip -qr out.zip b; rm -rf b; git add out.zip"
t tgz_with_key     hit   staged "mkdir -p b; eval echo 'k=$AWS' > b/c.txt; tar -czf out.tgz b; rm -rf b; git add out.tgz"
t inbox_archive    hit   staged "mkdir -p b _수신함/2026-11-09_메일_자료; echo hello > b/r.txt; zip -qr _수신함/2026-11-09_메일_자료/a.zip b; rm -rf b; git add _수신함"
t zip_in_history   hit   range "mkdir -p b; eval echo 'k=$GH' > b/t.txt; zip -qr o.zip b; rm -rf b; git add o.zip; git commit -qm add --no-verify; git rm -q o.zip; git commit -qm rm --no-verify"
# path mode (material the user hands over) and mask mode
P="$T/hand"; mkdir -p "$P/in"; printf 'API_KEY=%s\n' "$GOOG" > "$P/in/a.txt"; printf '%s\nMIIEow\n-----END RSA PRIVATE KEY-----\n' "$PEM" > "$P/in/k.txt"; echo "그냥 문서" > "$P/in/b.md"
"$S" path "$P/in" >/dev/null; [[ $? == 1 ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL path_finds_key"; }
"$S" mask "$P/in" >/dev/null; o=$("$S" path "$P/in"); [[ $? == 0 ]] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL mask_then_clean\n%s\n' "$o"; }
grep -q '그냥 문서' "$P/in/b.md" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL mask_keeps_plain"; }
# Redis key names are not secrets; a real value in a *_KEY variable still is
t redis_key_names  clean staged "printf \"SEEN_SET_KEY = 'app:seen-set'\\nRETRY_LOCK_KEY = 'app:retry-lock'\\nLOCK_KEY = \\\"lock:\\\${id}\\\"\\n\" > k.ts; git add k.ts"
t real_value_key   hit   staged "eval echo \"SERVICE_ACCOUNT_KEY = '$GOOG'\" > p.ts; git add p.ts"
# large change: a key at the end of a 1.3MB file is still found (the change used to be passed in an env variable)
t big_file_key     hit   staged "head -c 1300000 /dev/zero | tr '\\0' a | fold -w 100 > big.txt; eval echo 'k=$GH' >> big.txt; git add big.txt"
t big_file_clean   clean staged "head -c 1300000 /dev/zero | tr '\\0' a | fold -w 100 > big.txt; git add big.txt"
# Korean paths with git's default core.quotepath=true
t inbox_archive_ko hit   staged "mkdir -p b '_수신함/자료 묶음'; echo hello > b/r.txt; zip -qr '_수신함/자료 묶음/a.zip' b; rm -rf b; git add _수신함"
t dotenv_ko_folder hit   staged "mkdir -p 설정; echo A=1 > 설정/.env; git add -f 설정/.env"
# archive inside an archive is blocked by name; a single .gz is opened
t nested_archive   hit   staged "mkdir -p b c; echo hi > b/r.txt; zip -qr c/in.zip b; zip -qr out.zip c; rm -rf b c; git add out.zip"
t single_gz_key    hit   staged "eval echo 'k=$GH' > n.txt; gzip n.txt; git add n.txt.gz"
# a value put in by a merge commit itself (merge diffs are hidden from plain git log -p)
t merge_commit_key hit   range "git checkout -qb side; echo s > s.txt; git add s.txt; git commit -qm s; git checkout -q -; git merge -q --no-ff --no-commit side >/dev/null; eval echo 'k=$GH' > m.txt; git add m.txt; git commit -qm merge"
# git failure fails closed: an unknown revision blocks instead of passing
o=$("$S" range "$T/aws_key" 0123456789abcdef0123456789abcdef01234567..HEAD 2>&1); [[ $? == 1 ]] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL unknown_rev_fails_closed\n%s\n' "$o"; }
# password fields: a call that makes the password unusable is fine; literals, joined pieces, literal call args are not
tt unusable_call    clean "password: unusablePasswordHash(),"
tt unusable_hash    clean "passwordHash: unusablePasswordHash(),"
tt make_test_pw     clean "password: makeTestPassword('x'),"
tt make_pw_label    clean "const WRONG_PASSWORD = makeTestPassword('login-wrong');"
tt unusable_label   clean "passwordHash: unusablePasswordHash('deleted-link'),"
tt joined_pieces    hit   "$(j pass "word: '" Xk29fjQ0 "' + '" pLmn38aZ "',")"
tt literal_in_call  hit   "$(j pass "wordHash: makeHash('" Xk29fjQ0 pLmn38aZ "'),")"
tt short_pieces     clean "password: 'ab' + 'cd',"
# text (commit message, PR body)
tt message_key    hit   "fix: 키 교체 $ANT"
tt message_plain   clean "fix(app): 마감일이 지나면 범위를 숨김"
echo "통과 $pass / 실패 $fail"; (( fail == 0 ))
