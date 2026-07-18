#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYGIENE_SCRIPT="$SCRIPT_DIR/../hygiene-scan.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

pass_count=0
fail_count=0

log_pass() {
  pass_count=$((pass_count + 1))
  echo "PASS: $1"
}

log_fail() {
  fail_count=$((fail_count + 1))
  echo "FAIL: $1"
}

join() {
  local out="" part
  for part in "$@"; do out="$out$part"; done
  printf '%s' "$out"
}

new_case_dir() {
  local dir="$SCRATCH/$1"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

LAST_STATUS=0
LAST_STDOUT=""
LAST_STDERR=""

run_stdin() {
  local dir="$1" rel="$2" env_prefix="${3:-}"
  local err_file="$SCRATCH/.stderr.$$"
  set +e
  LAST_STDOUT="$(cd "$dir" && env $env_prefix printf '{"file_path":"%s"}' "$rel" | env $env_prefix bash "$HYGIENE_SCRIPT" 2>"$err_file")"
  LAST_STATUS=$?
  set -e
  LAST_STDERR="$(cat "$err_file" 2>/dev/null)"
  rm -f "$err_file"
}

run_all() {
  local dir="$1"
  set +e
  LAST_STDOUT="$(cd "$dir" && bash "$HYGIENE_SCRIPT" --all)"
  LAST_STATUS=$?
  set -e
}

assert_status() {
  local name="$1" expected="$2"
  if [ "$LAST_STATUS" -eq "$expected" ]; then
    log_pass "$name"
  else
    log_fail "$name (expected exit $expected, got $LAST_STATUS)"
  fi
}

assert_marker_exists() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    log_pass "$name"
  else
    log_fail "$name (marker not found at $path)"
  fi
}

assert_marker_absent() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    log_fail "$name (marker unexpectedly present at $path)"
  else
    log_pass "$name"
  fi
}

assert_stdout_contains() {
  local name="$1" needle="$2"
  if printf '%s' "$LAST_STDOUT" | grep -qF "$needle"; then
    log_pass "$name"
  else
    log_fail "$name (stdout did not contain: $needle)"
  fi
}

assert_stderr_contains() {
  local name="$1" needle="$2"
  if printf '%s' "$LAST_STDERR" | grep -qF "$needle"; then
    log_pass "$name"
  else
    log_fail "$name (stderr did not contain: $needle)"
  fi
}

assert_scan_status() {
  local name="$1" filename="$2" content="$3" expected="$4"
  local dir; dir="$(new_case_dir "$(echo "$name" | tr ' ' '_')")"
  printf '%s\n' "$content" > "$dir/$filename"
  run_stdin "$dir" "$filename"
  assert_status "$name" "$expected"
}

specid_req="$(join REQ - 123)"
specid_ac="$(join AC - 42)"
aws_key="$(join AKIA ABCDEFGHIJKLMNOP)"
gh_val="$(join gh p_ abcdefghijklmnopqrstuvwxyz0123456789)"
slack_val="$(join xox b- 1234567890-abcdefghijklmno)"
stripe_key="$(join sk_ live_ ABCDEFGHIJKLMNOPQRSTUVWX)"
google_key="$(join AIza SyABCDEFGHIJKLMNOPQRSTUVWXYZ1234567)"
pem_header="$(join ----- BEG IN' ' RSA' ' PRIVATE' ' KEY -----)"
jwt_seg1="$(join eyJhbGciOiJIUzI1 NiIsInR5cCI6IkpXVCJ9)"
jwt_seg2="$(join eyJzdWIiOiIx MjM0NTY3ODkwIn0)"
jwt_seg3="$(join dozjgNryP4J3jVmN Hl0w5N_XgL0n3I9PlFUP0THsR8U)"
jwt_val="$(join "$jwt_seg1" . "$jwt_seg2" . "$jwt_seg3")"
generic_key_name="$(join api Key)"
generic_literal="$(join abcdefghijklmnop qrstuvwxyz)"
kw1="$(join pass word)"
kw2="$(join sec ret)"
kw3="$(join tok en)"
placeholder_line="$(join const' ' "$kw1" ' = "<insert-' "$kw1" '-here>";')"
envvar_line="$(join const' ' "$kw3" ' = "${SOME_ENV_VAR_NAME}";')"
short_line="$(join const' ' "$kw2" ' = "short";')"
repeated_line="$(join const' ' "$kw1" ' = "' aaaaaaaaaaaaaaaa '";')"

dir="$(new_case_dir marker_specid)"
mkdir -p "$dir/.context/ship-run"
printf 'token %s present here\n' "$specid_req" > "$dir/file.txt"
run_stdin "$dir" "file.txt"
assert_status "spec-ID violation exits 2" 2
assert_marker_exists "marker touched on spec-ID violation" "$dir/.context/ship-run/.hygiene-hit"

dir="$(new_case_dir marker_secret)"
mkdir -p "$dir/.context/ship-run"
printf 'AWS_KEY=%s\n' "$aws_key" > "$dir/file.txt"
run_stdin "$dir" "file.txt"
assert_status "secret violation exits 2" 2
assert_marker_exists "marker touched on secret violation" "$dir/.context/ship-run/.hygiene-hit"
assert_stderr_contains "secret remediation hint present in stderr" "Secrets: move to an environment variable / secrets manager; rotate the credential if it was ever committed."

dir="$(new_case_dir marker_clean)"
mkdir -p "$dir/.context/ship-run"
printf 'just a normal line of text\n' > "$dir/file.txt"
run_stdin "$dir" "file.txt"
assert_status "clean file exits 0" 0
assert_marker_absent "marker untouched on clean write" "$dir/.context/ship-run/.hygiene-hit"

assert_scan_status "AWS access key pattern detected" "file.txt" "$(printf 'aws_key = "%s"' "$aws_key")" 2
assert_scan_status "GitHub token pattern detected" "file.txt" "$(printf 'token = "%s"' "$gh_val")" 2
assert_scan_status "Slack token pattern detected" "file.txt" "$(printf 'slack = "%s"' "$slack_val")" 2
assert_scan_status "Stripe live key pattern detected" "file.txt" "$(printf 'stripe = "%s"' "$stripe_key")" 2
assert_scan_status "Google API key pattern detected" "file.txt" "$(printf 'google = "%s"' "$google_key")" 2

dir="$(new_case_dir secret_pem)"
printf '%s\nMIIBogIBAAJ\n%s\n' "$pem_header" "$pem_header" > "$dir/file.txt"
run_stdin "$dir" "file.txt"
assert_status "PEM private key header detected" 2

assert_scan_status "JWT-shaped token detected" "file.txt" "jwt = $jwt_val" 2
assert_scan_status "generic secret-shaped assignment detected" "file.txt" "$(printf 'const %s = "%s";' "$generic_key_name" "$generic_literal")" 2
assert_scan_status "placeholder literal exempted from generic secret detection" "file.txt" "$placeholder_line" 0
assert_scan_status "env-var reference exempted from generic secret detection" "file.txt" "$envvar_line" 0
assert_scan_status "literal under length threshold exempted from generic secret detection" "file.txt" "$short_line" 0
assert_scan_status "repeated single-character literal exempted from generic secret detection" "file.txt" "$repeated_line" 0
assert_scan_status ".env basename excluded from secret scanning" ".env" "$(printf 'AWS_SECRET_ACCESS_KEY=%s' "$aws_key")" 0
assert_scan_status ".env.* basename excluded from secret scanning" ".env.production" "$(printf 'AWS_SECRET_ACCESS_KEY=%s' "$aws_key")" 0
assert_scan_status "secret detection fires without ship-run directory present" "file.txt" "$(printf 'aws_key = "%s"' "$aws_key")" 2

dir="$(new_case_dir all_mode_secret)"
git init -q "$dir"
printf 'aws_key = "%s"\n' "$aws_key" > "$dir/leaked.txt"
(cd "$dir" && git add leaked.txt && git -c user.email="test@example.com" -c user.name="Ship Test" commit -q -m "add fixture")
run_all "$dir"
assert_stdout_contains "--all mode catches a pre-existing committed secret" "leaked.txt"

dir="$(new_case_dir specid_with_shiprun)"
mkdir -p "$dir/.context/ship-run"
printf 'see %s for details\n' "$specid_ac" > "$dir/file.txt"
run_stdin "$dir" "file.txt"
assert_status "spec-ID detection still fires with ship-run present" 2

dir="$(new_case_dir specid_without_shiprun)"
printf 'see %s for details\n' "$specid_ac" > "$dir/file.txt"
run_stdin "$dir" "file.txt"
assert_status "spec-ID detection fires unconditionally without ship-run present" 2

dir="$(new_case_dir comment_with_shiprun)"
mkdir -p "$dir/.context/ship-run"
printf '#!/usr/bin/env bash\necho hi\n# this is a comment\n' > "$dir/notes.sh"
run_stdin "$dir" "notes.sh"
assert_status "comment detected when ship-run directory is active" 2

dir="$(new_case_dir comment_without_shiprun)"
printf '#!/usr/bin/env bash\necho hi\n# this is a comment\n' > "$dir/notes.sh"
run_stdin "$dir" "notes.sh"
assert_status "comment ignored when ship-run absent and SCAN_COMMENTS unset" 0

dir="$(new_case_dir comment_with_scan_flag)"
printf '#!/usr/bin/env bash\necho hi\n# this is a comment\n' > "$dir/notes.sh"
run_stdin "$dir" "notes.sh" "SCAN_COMMENTS=1"
assert_status "comment detected when SCAN_COMMENTS=1 is set" 2

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi

exit 0
