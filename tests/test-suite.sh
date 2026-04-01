#!/usr/bin/env bash
# tests/test-suite.sh — Test suite for the improvement loop shell scripts.

set -uo pipefail

PASS=0
FAIL=0
ERRORS=""
HOOK_FILES=(
  state-utils.sh
  session-start.sh
  pre-edit-guard.sh
  post-edit-check.sh
  stop-improve.sh
)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COVERAGE_FILE="$PROJECT_DIR/coverage/coverage-summary.json"
COVERAGE_DIR="$(dirname "$COVERAGE_FILE")"
TEMP_STATE=""
COVERAGE_BACKUP=$(mktemp)
COVERAGE_PRESENT=0

if [ -f "$COVERAGE_FILE" ]; then
  cp "$COVERAGE_FILE" "$COVERAGE_BACKUP"
  COVERAGE_PRESENT=1
fi

cleanup() {
  if [ -n "$TEMP_STATE" ]; then
    rm -rf "$TEMP_STATE"
  fi

  if [ "$COVERAGE_PRESENT" -eq 1 ]; then
    mkdir -p "$COVERAGE_DIR"
    cp "$COVERAGE_BACKUP" "$COVERAGE_FILE"
  else
    rm -f "$COVERAGE_FILE"
    rmdir "$COVERAGE_DIR" 2>/dev/null || true
  fi

  rm -f "$COVERAGE_BACKUP"
}

trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  ✗ $desc\n    expected: $expected\n    actual:   $actual"
    echo "  ✗ $desc"
  fi
}

assert_true() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  ✗ $desc"
    echo "  ✗ $desc"
  fi
}

assert_false() {
  local desc="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  ✗ $desc"
    echo "  ✗ $desc"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -Fq "$needle"; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  ✗ $desc\n    missing: $needle"
    echo "  ✗ $desc"
  fi
}

run_stop_hook() {
  local fixture_dir="$1"
  local input_json="$2"
  local stdout_file="$3"
  local stderr_file="$4"

  (
    export CLAUDE_PROJECT_DIR="$fixture_dir"
    cd "$fixture_dir" || exit 1
    printf '%s' "$input_json" | bash "$PROJECT_DIR/.claude/hooks/stop-improve.sh" >"$stdout_file" 2>"$stderr_file"
  )
}

# ── state-utils.sh ───────────────────────────────────────────

echo ""
echo "── state-utils.sh ──────────────────────────"

TEMP_STATE=$(mktemp -d)

export CLAUDE_PROJECT_DIR="$TEMP_STATE"
# shellcheck source=/dev/null
source "$PROJECT_DIR/.claude/hooks/state-utils.sh"

init_state
assert_true  "init_state creates state file"         test -f "$TEMP_STATE/.claude/state/loop-state.json"
assert_eq    "initial iteration is 0"                "0"       "$(read_state '.iteration')"
assert_eq    "initial status is running"             "running" "$(read_state '.status')"
assert_eq    "initial scores array is empty"         "0"       "$(read_state '.scores | length')"

write_state '.status' '"complete"'
assert_eq    "write_state updates a field"           "complete" "$(read_state '.status')"

append_state '.scores' '42'
append_state '.scores' '75'
assert_eq    "append_state grows the array"          "2"  "$(read_state '.scores | length')"
assert_eq    "append_state first element correct"    "42" "$(read_state '.scores[0]')"
assert_eq    "append_state second element correct"   "75" "$(read_state '.scores[1]')"

write_state '.iteration' '0'
NEXT=$(increment_iteration)
assert_eq    "increment_iteration returns new value" "1" "$NEXT"
assert_eq    "increment_iteration persists to state" "1" "$(read_state '.iteration')"

write_state '.iteration' '5'
assert_false "is_budget_exhausted: false at iteration 5"  is_budget_exhausted

write_state '.iteration' '10'
assert_true  "is_budget_exhausted: true at iteration 10"  is_budget_exhausted

# state persists across re-source (new subshell with same file)
write_state '.status' '"persisted"'
PERSISTED=$(bash -c "
  export CLAUDE_PROJECT_DIR='$TEMP_STATE'
  source '$PROJECT_DIR/.claude/hooks/state-utils.sh'
  read_state '.status'
")
assert_eq    "state persists across subshells" "persisted" "$PERSISTED"

# ── install.sh ───────────────────────────────────────────────

echo ""
echo "── install.sh ──────────────────────────────"

INSTALL_DIR=$(mktemp -d)
mkdir -p "$INSTALL_DIR/.claude"
cat > "$INSTALL_DIR/.claude/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["keep-me"]
  }
}
EOF

bash "$PROJECT_DIR/install.sh" "$INSTALL_DIR" >/dev/null 2>&1
assert_eq "install.sh exits 0" "0" "$?"

for hook in "${HOOK_FILES[@]}"; do
  assert_true "install: $hook is executable" test -x "$INSTALL_DIR/.claude/hooks/$hook"
done

assert_true  "install: state/ directory created"     test -d "$INSTALL_DIR/.claude/state"
assert_true  "install: settings.json present"        test -f "$INSTALL_DIR/.claude/settings.json"
assert_true  "install: settings.json is valid JSON"  jq empty "$INSTALL_DIR/.claude/settings.json"
assert_true  "install: existing non-hook settings preserved" jq -e '.permissions.allow == ["keep-me"]' "$INSTALL_DIR/.claude/settings.json"

HOOK_COUNT=$(jq '[.hooks // {} | to_entries[] | .value | length] | add // 0' "$INSTALL_DIR/.claude/settings.json")
assert_true  "install: settings.json has hook entries" test "$HOOK_COUNT" -gt 0

# idempotent: second install should not fail
bash "$PROJECT_DIR/install.sh" "$INSTALL_DIR" >/dev/null 2>&1
assert_eq    "install.sh is idempotent (exits 0 on re-run)" "0" "$?"
assert_true  "install: settings.json still valid after re-run" jq empty "$INSTALL_DIR/.claude/settings.json"

# ── uninstall.sh ─────────────────────────────────────────────

echo ""
echo "── uninstall.sh ────────────────────────────"

bash "$PROJECT_DIR/uninstall.sh" "$INSTALL_DIR" >/dev/null 2>&1
assert_eq "uninstall.sh exits 0" "0" "$?"

for hook in "${HOOK_FILES[@]}"; do
  assert_false "uninstall: $hook removed" test -f "$INSTALL_DIR/.claude/hooks/$hook"
done

assert_false "uninstall: state/ directory removed" test -d "$INSTALL_DIR/.claude/state"

rm -rf "$INSTALL_DIR"

# ── stop-improve.sh ──────────────────────────────────────────

echo ""
echo "── stop-improve.sh ─────────────────────────"

make_fixture() {
  local fixture_dir
  fixture_dir=$(mktemp -d)
  mkdir -p "$fixture_dir/coverage"
  printf '%s\n' "# fixture" > "$fixture_dir/README.md"
  echo "$fixture_dir"
}

FIXTURE_BREAKER=$(make_fixture)
bash -c "
  export CLAUDE_PROJECT_DIR='$FIXTURE_BREAKER'
  source '$PROJECT_DIR/.claude/hooks/state-utils.sh'
  init_state
"
BREAKER_STDOUT=$(mktemp)
BREAKER_STDERR=$(mktemp)
run_stop_hook "$FIXTURE_BREAKER" '{"stop_hook_active":true}' "$BREAKER_STDOUT" "$BREAKER_STDERR"
assert_eq "stop hook breaker exits 0" "0" "$?"
assert_eq "stop hook breaker updates status" "breaker_tripped" "$(jq -r '.status' "$FIXTURE_BREAKER/.claude/state/loop-state.json")"
assert_contains "stop hook breaker reports re-entry" "allowing stop on re-entry" "$(cat "$BREAKER_STDERR")"
rm -rf "$FIXTURE_BREAKER" "$BREAKER_STDOUT" "$BREAKER_STDERR"

FIXTURE_BUDGET=$(make_fixture)
bash -c "
  export CLAUDE_PROJECT_DIR='$FIXTURE_BUDGET'
  source '$PROJECT_DIR/.claude/hooks/state-utils.sh'
  init_state
  write_state '.iteration' '10'
"
BUDGET_STDOUT=$(mktemp)
BUDGET_STDERR=$(mktemp)
run_stop_hook "$FIXTURE_BUDGET" '{"stop_hook_active":false}' "$BUDGET_STDOUT" "$BUDGET_STDERR"
assert_eq "stop hook budget exit is 0" "0" "$?"
assert_eq "stop hook budget updates status" "budget_exhausted" "$(jq -r '.status' "$FIXTURE_BUDGET/.claude/state/loop-state.json")"
assert_contains "stop hook budget reports exhaustion" "BUDGET REACHED" "$(cat "$BUDGET_STDERR")"
rm -rf "$FIXTURE_BUDGET" "$BUDGET_STDOUT" "$BUDGET_STDERR"

FIXTURE_COMPLETE=$(make_fixture)
cat > "$FIXTURE_COMPLETE/package.json" <<'EOF'
{
  "scripts": {
    "test": "node -e \"process.exit(0)\" --"
  }
}
EOF
cat > "$FIXTURE_COMPLETE/coverage/coverage-summary.json" <<'EOF'
{
  "total": {
    "lines": { "pct": 100 }
  }
}
EOF
bash -c "
  export CLAUDE_PROJECT_DIR='$FIXTURE_COMPLETE'
  source '$PROJECT_DIR/.claude/hooks/state-utils.sh'
  init_state
"
COMPLETE_STDOUT=$(mktemp)
COMPLETE_STDERR=$(mktemp)
run_stop_hook "$FIXTURE_COMPLETE" '{"stop_hook_active":false}' "$COMPLETE_STDOUT" "$COMPLETE_STDERR"
assert_eq "stop hook complete exit is 0" "0" "$?"
assert_eq "stop hook complete status" "complete" "$(jq -r '.status' "$FIXTURE_COMPLETE/.claude/state/loop-state.json")"
assert_eq "stop hook complete records perfect score" "100" "$(jq -r '.scores[0]' "$FIXTURE_COMPLETE/.claude/state/loop-state.json")"
assert_contains "stop hook complete reports success" "ALL GATES PASS" "$(cat "$COMPLETE_STDERR")"
rm -rf "$FIXTURE_COMPLETE" "$COMPLETE_STDOUT" "$COMPLETE_STDERR"

FIXTURE_TEST_FAIL=$(make_fixture)
cat > "$FIXTURE_TEST_FAIL/package.json" <<'EOF'
{
  "scripts": {
    "test": "node -e \"process.exit(1)\" --"
  }
}
EOF
cat > "$FIXTURE_TEST_FAIL/coverage/coverage-summary.json" <<'EOF'
{
  "total": {
    "lines": { "pct": 100 }
  }
}
EOF
bash -c "
  export CLAUDE_PROJECT_DIR='$FIXTURE_TEST_FAIL'
  source '$PROJECT_DIR/.claude/hooks/state-utils.sh'
  init_state
"
TEST_FAIL_STDOUT=$(mktemp)
TEST_FAIL_STDERR=$(mktemp)
run_stop_hook "$FIXTURE_TEST_FAIL" '{"stop_hook_active":false}' "$TEST_FAIL_STDOUT" "$TEST_FAIL_STDERR"
assert_eq "stop hook failing tests exit 2" "2" "$?"
assert_eq "stop hook failing tests increments iteration" "1" "$(jq -r '.iteration' "$FIXTURE_TEST_FAIL/.claude/state/loop-state.json")"
assert_contains "stop hook failing tests reports failure block" "Test Failures" "$(cat "$TEST_FAIL_STDERR")"
rm -rf "$FIXTURE_TEST_FAIL" "$TEST_FAIL_STDOUT" "$TEST_FAIL_STDERR"

FIXTURE_PARTIAL_COVERAGE=$(make_fixture)
cat > "$FIXTURE_PARTIAL_COVERAGE/package.json" <<'EOF'
{
  "scripts": {
    "test": "node -e \"process.exit(0)\" --"
  }
}
EOF
cat > "$FIXTURE_PARTIAL_COVERAGE/coverage/coverage-summary.json" <<'EOF'
{
  "total": {
    "lines": { "pct": 40 }
  },
  "src/example.ts": {
    "lines": { "pct": 40 }
  }
}
EOF
bash -c "
  export CLAUDE_PROJECT_DIR='$FIXTURE_PARTIAL_COVERAGE'
  source '$PROJECT_DIR/.claude/hooks/state-utils.sh'
  init_state
"
PARTIAL_STDOUT=$(mktemp)
PARTIAL_STDERR=$(mktemp)
run_stop_hook "$FIXTURE_PARTIAL_COVERAGE" '{"stop_hook_active":false}' "$PARTIAL_STDOUT" "$PARTIAL_STDERR"
assert_eq "stop hook partial coverage exit 2" "2" "$?"
assert_eq "stop hook partial coverage score" "90" "$(jq -r '.scores[0]' "$FIXTURE_PARTIAL_COVERAGE/.claude/state/loop-state.json")"
assert_contains "stop hook partial coverage reports uncovered files" "src/example.ts: 40%" "$(cat "$PARTIAL_STDERR")"
rm -rf "$FIXTURE_PARTIAL_COVERAGE" "$PARTIAL_STDOUT" "$PARTIAL_STDERR"

# ── Summary ──────────────────────────────────────────────────

TOTAL=$((PASS + FAIL))
echo ""
echo "══════════════════════════════════════════"
printf "  %d/%d passed\n" "$PASS" "$TOTAL"
echo "══════════════════════════════════════════"

if [ -n "$ERRORS" ]; then
  echo ""
  echo "Failures:"
  echo -e "$ERRORS"
fi

# ── Coverage summary (test pass rate as proxy) ───────────────

PCT=$(awk "BEGIN { printf \"%.1f\", ($PASS / ($TOTAL > 0 ? $TOTAL : 1)) * 100 }")
mkdir -p "$COVERAGE_DIR"
cat > "$COVERAGE_FILE" <<EOF
{
  "total": {
    "lines":      { "total": $TOTAL, "covered": $PASS, "skipped": 0, "pct": $PCT },
    "statements": { "total": $TOTAL, "covered": $PASS, "skipped": 0, "pct": $PCT },
    "functions":  { "total": $TOTAL, "covered": $PASS, "skipped": 0, "pct": $PCT },
    "branches":   { "total": $TOTAL, "covered": $PASS, "skipped": 0, "pct": $PCT }
  }
}
EOF

[ "$FAIL" -eq 0 ]
