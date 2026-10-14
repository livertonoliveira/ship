#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT="$SCRIPT_DIR/../deps-bootstrap.sh"

pass_count=0
fail_count=0
log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

# A fake package manager that records its argv and creates node_modules.
fake_pm() {
  local dir="$1" name="$2" exit_code="${3:-0}"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/$name" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$dir/pm-calls.txt"
[ "\$CI" = "true" ] || { echo "CI not set" >&2; exit 9; }
[ "$exit_code" -eq 0 ] && mkdir -p node_modules/left-pad
exit $exit_code
EOF
  chmod +x "$dir/bin/$name"
}

run_boot() { local dir="$1"; shift; (cd "$dir" && PATH="$dir/bin:$PATH" bash "$BOOT" scratch "$@"); }

# Measured live (2026-10-14): every platform-agendx workspace of a graph
# arrived without node_modules and died on "Cannot find module 'vitest'".
test_lockfile_without_modules_installs_once() {
  local name="a pnpm lockfile and no packages → pnpm install --frozen-lockfile under CI=true, once per run"
  local d; d="$(mktemp -d)"
  fake_pm "$d" pnpm
  : > "$d/pnpm-lock.yaml"; echo '{}' > "$d/package.json"
  local out1 out2 rc=0
  out1="$(run_boot "$d")" || rc=$?
  out2="$(run_boot "$d")" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$out1" = "installed=pnpm" ] && [ "$out2" = "installed=pnpm" ] \
    && [ "$(cat "$d/pm-calls.txt")" = "install --frozen-lockfile" ] \
    && [ "$(wc -l < "$d/pm-calls.txt" | tr -d ' ')" = "1" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out1=$out1 out2=$out2 calls=$(cat "$d/pm-calls.txt" 2>/dev/null | tr '\n' '|'))"
  fi
  rm -rf "$d"
}

test_populated_modules_skip() {
  local name="node_modules with packages → skipped, no install"
  local d; d="$(mktemp -d)"
  fake_pm "$d" pnpm
  : > "$d/pnpm-lock.yaml"; mkdir -p "$d/node_modules/.cache" "$d/node_modules/react"
  local out; out="$(run_boot "$d")"
  if [ "$out" = "skipped=node_modules already populated" ] && [ ! -f "$d/pm-calls.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name (out=$out)"
  fi
  rm -rf "$d"
}

test_empty_shell_is_not_installed() {
  local name="node_modules holding only dotfiles (a runtime's empty shell) counts as not installed"
  local d; d="$(mktemp -d)"
  fake_pm "$d" npm
  : > "$d/package-lock.json"; mkdir -p "$d/node_modules/.cache"
  local out; out="$(run_boot "$d")"
  if [ "$out" = "installed=npm" ] && [ "$(cat "$d/pm-calls.txt")" = "ci" ]; then
    log_pass "$name"
  else
    log_fail "$name (out=$out calls=$(cat "$d/pm-calls.txt" 2>/dev/null))"
  fi
  rm -rf "$d"
}

test_no_lockfile_no_package_json_skips() {
  local name="a repo with no node manifest is skipped, not guessed"
  local d; d="$(mktemp -d)"
  local out; out="$(run_boot "$d")"
  if [ "$out" = "skipped=no node lockfile or package.json" ]; then log_pass "$name"; else log_fail "$name (out=$out)"; fi
  rm -rf "$d"
}

test_config_breaks_the_tie_without_a_lockfile() {
  local name="package.json without a lockfile → the config's Package Manager, written for people, picks the tool"
  local d; d="$(mktemp -d)"
  fake_pm "$d" yarn
  echo '{}' > "$d/package.json"; printf -- '- Package Manager: Yarn 3.6.4 (Berry)\n' > "$d/config.md"
  local out; out="$(run_boot "$d" --config config.md)"
  if [ "$out" = "installed=yarn" ] && [ "$(cat "$d/pm-calls.txt")" = "install --frozen-lockfile" ]; then
    log_pass "$name"
  else
    log_fail "$name (out=$out calls=$(cat "$d/pm-calls.txt" 2>/dev/null))"
  fi
  rm -rf "$d"
}

test_failed_install_is_reported_with_its_log() {
  local name="a failing install exits 1, records failed=<pm> and keeps the log; a second call does not retry"
  local d; d="$(mktemp -d)"
  fake_pm "$d" pnpm 7
  : > "$d/pnpm-lock.yaml"
  local rc=0 out; out="$(run_boot "$d")" || rc=$?
  local rc2=0; run_boot "$d" >/dev/null || rc2=$?
  if [ "$rc" -eq 1 ] && [ "$rc2" -eq 1 ] && [ "$out" = "failed=pnpm exit=7" ] \
    && [ -f "$d/scratch/deps-bootstrap.log" ] && [ "$(wc -l < "$d/pm-calls.txt" | tr -d ' ')" = "1" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc/$rc2 out=$out)"
  fi
  rm -rf "$d"
}

test_lockfile_without_modules_installs_once
test_populated_modules_skip
test_empty_shell_is_not_installed
test_no_lockfile_no_package_json_skips
test_config_breaks_the_tie_without_a_lockfile
test_failed_install_is_reported_with_its_log

echo ""
echo "${pass_count} passed, ${fail_count} failed"
[ "$fail_count" -eq 0 ]
