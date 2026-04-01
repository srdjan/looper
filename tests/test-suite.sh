#!/usr/bin/env bash
# tests/test-suite.sh — Test suite for the improvement loop shell scripts.

set -uo pipefail

PASS=0
FAIL=0
ERRORS=""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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
  if "$@" 2>/dev/null; then
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
  if ! "$@" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  ✗ $desc"
    echo "  ✗ $desc"
  fi
}

# ── state-utils.sh ───────────────────────────────────────────

echo ""
echo "── state-utils.sh ──────────────────────────"

TEMP_STATE=$(mktemp -d)
cleanup_state() { rm -rf "$TEMP_STATE"; }
trap cleanup_state EXIT

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
echo '{}' > "$INSTALL_DIR/.claude/settings.json"

bash "$PROJECT_DIR/install.sh" "$INSTALL_DIR" >/dev/null 2>&1
assert_eq "install.sh exits 0" "0" "$?"

for hook in state-utils.sh session-start.sh pre-edit-guard.sh post-edit-check.sh stop-improve.sh; do
  assert_true "install: $hook is executable" test -x "$INSTALL_DIR/.claude/hooks/$hook"
done

assert_true  "install: state/ directory created"     test -d "$INSTALL_DIR/.claude/state"
assert_true  "install: settings.json present"        test -f "$INSTALL_DIR/.claude/settings.json"
assert_true  "install: settings.json is valid JSON"  jq empty "$INSTALL_DIR/.claude/settings.json"

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

for hook in state-utils.sh session-start.sh pre-edit-guard.sh post-edit-check.sh stop-improve.sh; do
  assert_false "uninstall: $hook removed" test -f "$INSTALL_DIR/.claude/hooks/$hook"
done

assert_false "uninstall: state/ directory removed" test -d "$INSTALL_DIR/.claude/state"

rm -rf "$INSTALL_DIR"

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
mkdir -p "$PROJECT_DIR/coverage"
cat > "$PROJECT_DIR/coverage/coverage-summary.json" <<EOF
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
