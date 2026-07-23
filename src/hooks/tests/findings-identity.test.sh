#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDENTITY_SCRIPT="$SCRIPT_DIR/../findings-identity.sh"

pass_count=0
fail_count=0
log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

test_markdown_findings_extracted() {
  local name="markdown findings become <phase>|<sev>|<file>|<slug> with the :line suffix stripped"
  local dir out
  dir="$(mktemp -d)"
  cat > "$dir/review-findings.md" <<'EOF'
# Code Review Findings

## Findings

### [MEDIUM] Duplicated pre-lock query
- **Principle:** DRY
- **File:** src/use-case.ts:42

### [LOW] Log level too high
- **Principle:** CLEAN
- **File:** src/logger.ts:10-14
EOF
  out="$(bash "$IDENTITY_SCRIPT" "$dir")"
  rm -rf "$dir"
  if printf '%s\n' "$out" | grep -qx 'review|medium|src/use-case.ts|duplicated-pre-lock-query' \
    && printf '%s\n' "$out" | grep -qx 'review|low|src/logger.ts|log-level-too-high'; then
    log_pass "$name"
  else
    log_fail "$name (got: $out)"
  fi
}

test_line_shift_yields_same_identity() {
  local name="the same finding on a shifted line keeps one stable identity across rounds"
  local dir a b
  dir="$(mktemp -d)"
  printf '### [MEDIUM] Missing guard\n- **File:** src/x.ts:42\n' > "$dir/review-findings.md"
  a="$(bash "$IDENTITY_SCRIPT" "$dir")"
  printf '### [MEDIUM] Missing guard\n- **File:** src/x.ts:57\n' > "$dir/review-findings.md"
  b="$(bash "$IDENTITY_SCRIPT" "$dir")"
  rm -rf "$dir"
  if [ "$a" = "$b" ] && [ -n "$a" ]; then log_pass "$name"; else log_fail "$name ('$a' vs '$b')"; fi
}

test_json_findings_and_escalations() {
  local name="JSON findings parse; drift escalations (no severity) are excluded"
  local dir out
  dir="$(mktemp -d)"
  cat > "$dir/security-findings.json" <<'EOF'
[{"severity":"high","category":"AUTHZ","filePath":"src/user.ts","line":9,"title":"IDOR"}]
EOF
  cat > "$dir/drift-findings.json" <<'EOF'
{"findings":[{"severity":"medium","category":"ORPHAN","file":"src/z.ts:99","title":"Orphan file"}],
 "escalations":[{"requirementId":"appointment-flow","confidence":9,"file":"src/y.ts","decision":"Match"}],
 "summary":{"critical":0,"high":1,"medium":1,"low":0,"gate":"FAIL"}}
EOF
  out="$(bash "$IDENTITY_SCRIPT" "$dir")"
  rm -rf "$dir"
  if printf '%s\n' "$out" | grep -qx 'security|high|src/user.ts|authz-idor' \
    && printf '%s\n' "$out" | grep -qx 'analyze|medium|src/z.ts|orphan-orphan-file' \
    && ! printf '%s\n' "$out" | grep -q 'src/y.ts'; then
    log_pass "$name"
  else
    log_fail "$name (got: $out)"
  fi
}

test_empty_scratch_exits_zero() {
  local name="a scratch dir with no findings files emits nothing and exits 0"
  local dir out rc=0
  dir="$(mktemp -d)"
  out="$(bash "$IDENTITY_SCRIPT" "$dir")" || rc=$?
  rm -rf "$dir"
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then log_pass "$name"; else log_fail "$name (rc=$rc out='$out')"; fi
}

test_markdown_findings_extracted
test_line_shift_yields_same_identity
test_json_findings_and_escalations
test_empty_scratch_exits_zero

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
