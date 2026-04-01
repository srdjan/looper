#!/usr/bin/env bash
# .claude/hooks/stop-improve.sh
# Stop hook — the improvement loop driver.
#
# This is where the loop lives. When Claude finishes responding:
#   1. Check circuit breakers (stop_hook_active, budget)
#   2. Run four quality gates: typecheck, lint, test, coverage
#   3. Score the run (0-100)
#   4. If perfect: exit 0 → Claude stops
#   5. If imperfect: record score, write targeted feedback,
#      increment iteration, exit 2 → Claude gets another turn
#
# Exit codes:
#   0 = let Claude stop (all gates pass, budget hit, or breaker)
#   2 = push Claude back into agentic loop with feedback

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state-utils.sh"

INPUT=$(cat)

append_gate_result() {
  local symbol="$1"
  local name="$2"
  local detail="$3"
  local awarded="$4"
  local available="$5"
  GATE_RESULTS="${GATE_RESULTS}  ${symbol} ${name}: ${detail} (${awarded}/${available})\n"
}

append_failure_block() {
  local heading="$1"
  local body="$2"
  FAILURES="${FAILURES}\n── ${heading} ──\n${body}\n"
}

coverage_meets_target() {
  local line_cov="$1"
  awk -v line_cov="$line_cov" 'BEGIN { exit !(line_cov >= 80) }'
}

coverage_partial_score() {
  local line_cov="$1"
  awk -v line_cov="$line_cov" 'BEGIN { printf "%d", int((line_cov * 20) / 80) }'
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CIRCUIT BREAKER 1: stop_hook_active
# If Claude was already sent back once by this hook and is
# trying to stop again on the same turn, let it go.
# Without this: infinite loop.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_ACTIVE" = "true" ]; then
  write_state '.status' '"breaker_tripped"'
  echo "Stop hook breaker: allowing stop on re-entry." >&2
  exit 0
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CIRCUIT BREAKER 2: iteration budget
# Hard cap at MAX_ITERATIONS regardless of quality.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ITERATION=$(read_state '.iteration')
CURRENT_PASS=$((ITERATION + 1))
if [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
  write_state '.status' '"budget_exhausted"'

  # Final summary
  SCORES=$(read_state '.scores')
  echo "" >&2
  echo "══════════════════════════════════════════════" >&2
  echo "  IMPROVEMENT LOOP COMPLETE — BUDGET REACHED" >&2
  echo "  Iterations: $ITERATION/$MAX_ITERATIONS" >&2
  echo "  Score history: $SCORES" >&2
  echo "══════════════════════════════════════════════" >&2
  echo "" >&2
  echo "Summarize: what was accomplished, what remains unfixed." >&2
  exit 0
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# QUALITY GATES
# Each gate: run check → capture pass/fail → accumulate score
# Score weights: typecheck=30, lint=20, test=30, coverage=20
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SCORE=0
TOTAL=100
FAILURES=""
GATE_RESULTS=""

# ── Gate 1: TypeScript compilation (30 points) ──────────────
echo "⏳ [Pass $CURRENT_PASS/$MAX_ITERATIONS] Running typecheck..." >&2
if [ -f tsconfig.json ]; then
  TC_OUT=$(npx tsc --noEmit --pretty false 2>&1 || true)
  TC_ERRORS=$(echo "$TC_OUT" | grep -c 'error TS' || echo "0")
  if [ "$TC_ERRORS" -eq 0 ]; then
    SCORE=$((SCORE + 30))
    append_gate_result "✓" "typecheck" "pass" "30" "30"
  else
    append_gate_result "✗" "typecheck" "$TC_ERRORS errors" "0" "30"
    append_failure_block "TypeCheck Failures" "$(echo "$TC_OUT" | grep 'error TS' | head -10)"
  fi
else
  # No tsconfig — skip, award points
  SCORE=$((SCORE + 30))
  append_gate_result "○" "typecheck" "skipped — no tsconfig.json" "30" "30"
fi

# ── Gate 2: Lint (20 points) ────────────────────────────────
echo "⏳ [Pass $CURRENT_PASS/$MAX_ITERATIONS] Running lint..." >&2
if [ -f node_modules/.bin/eslint ]; then
  LINT_OUT=$(npx eslint . --ext .ts,.tsx --format compact 2>&1 || true)
  LINT_ERRORS=$(echo "$LINT_OUT" | grep -c ': Error -' || echo "0")
  if [ "$LINT_ERRORS" -eq 0 ]; then
    SCORE=$((SCORE + 20))
    append_gate_result "✓" "lint" "pass" "20" "20"
  else
    append_gate_result "✗" "lint" "$LINT_ERRORS errors" "0" "20"
    append_failure_block "Lint Failures" "$(echo "$LINT_OUT" | grep ': Error -' | head -10)"
  fi
else
  SCORE=$((SCORE + 20))
  append_gate_result "○" "lint" "skipped — eslint not installed" "20" "20"
fi

# ── Gate 3: Tests (30 points) ───────────────────────────────
echo "⏳ [Pass $CURRENT_PASS/$MAX_ITERATIONS] Running tests..." >&2
if jq -e '.scripts.test' package.json &>/dev/null 2>&1; then
  if TEST_OUT=$(npm test -- --reporter=dot 2>&1); then
    TEST_EXIT=0
  else
    TEST_EXIT=$?
  fi

  # Try to extract pass/fail counts from common test runners
  TESTS_FAILED=$(printf '%s\n' "$TEST_OUT" | grep -E -c '(FAIL|✗|✘|×|failed)' || true)

  if [ "$TEST_EXIT" -eq 0 ] && [ "$TESTS_FAILED" -eq 0 ]; then
    SCORE=$((SCORE + 30))
    append_gate_result "✓" "test" "pass" "30" "30"
  else
    append_gate_result "✗" "test" "failures detected" "0" "30"
    append_failure_block "Test Failures" "$(echo "$TEST_OUT" | tail -20)"
  fi
else
  append_gate_result "○" "test" "skipped — no test script" "0" "30"
  append_failure_block "Missing Tests" "No test script found in package.json. Add tests."
fi

# ── Gate 4: Coverage (20 points) ────────────────────────────
echo "⏳ [Pass $CURRENT_PASS/$MAX_ITERATIONS] Checking coverage..." >&2
COVERAGE_FILE="coverage/coverage-summary.json"
if [ -f "$COVERAGE_FILE" ]; then
  LINE_COV=$(jq -r '.total.lines.pct // 0' "$COVERAGE_FILE" 2>/dev/null || echo "0")
  # Scale: 80%+ = full marks, below = proportional
  if coverage_meets_target "$LINE_COV"; then
    SCORE=$((SCORE + 20))
    append_gate_result "✓" "coverage" "${LINE_COV}%" "20" "20"
  else
    # Proportional score: (coverage/80) * 20
    PARTIAL=$(coverage_partial_score "$LINE_COV")
    SCORE=$((SCORE + PARTIAL))
    append_gate_result "△" "coverage" "${LINE_COV}% — need 80%+" "$PARTIAL" "20"
    COVERAGE_FAILURE="Line coverage: ${LINE_COV}%. Target: 80%.\n"
    # Show uncovered files
    if command -v jq &>/dev/null; then
      UNCOVERED=$(jq -r 'to_entries[]
        | select(.key != "total")
        | select(.value.lines.pct < 80)
        | "\(.key): \(.value.lines.pct)%"' "$COVERAGE_FILE" 2>/dev/null | head -5 || true)
      if [ -n "$UNCOVERED" ]; then
        COVERAGE_FAILURE="${COVERAGE_FAILURE}Uncovered files:\n$UNCOVERED"
      fi
    fi
    append_failure_block "Coverage Gap" "$COVERAGE_FAILURE"
  fi
else
  append_gate_result "○" "coverage" "no coverage data — run tests with --coverage" "0" "20"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SCORE & DECIDE
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Record score
append_state '.scores' "$SCORE"
write_state ".checks.typecheck" "$(echo "$GATE_RESULTS" | grep -q '✓ typecheck' && echo true || echo false)"
write_state ".checks.lint" "$(echo "$GATE_RESULTS" | grep -q '✓ lint' && echo true || echo false)"
write_state ".checks.test" "$(echo "$GATE_RESULTS" | grep -q '✓ test' && echo true || echo false)"

# ── Perfect score: done! ────────────────────────────────────
if [ "$SCORE" -eq "$TOTAL" ]; then
  write_state '.status' '"complete"'

  SCORES=$(read_state '.scores')
  echo "" >&2
  echo "══════════════════════════════════════════════" >&2
  echo "  IMPROVEMENT LOOP COMPLETE — ALL GATES PASS" >&2
  echo "  Score: $SCORE/$TOTAL on pass $CURRENT_PASS" >&2
  echo "  Score history: $SCORES" >&2
  echo "══════════════════════════════════════════════" >&2
  exit 0
fi

# ── Imperfect: increment and loop ───────────────────────────
NEXT=$(increment_iteration)
SCORES=$(read_state '.scores')

echo "" >&2
echo "══════════════════════════════════════════════" >&2
echo "  IMPROVEMENT PASS $NEXT/$MAX_ITERATIONS" >&2
echo "  Score: $SCORE/$TOTAL" >&2
echo "  History: $SCORES" >&2
echo "──────────────────────────────────────────────" >&2
echo -e "$GATE_RESULTS" >&2
echo "──────────────────────────────────────────────" >&2

if [ -n "$FAILURES" ]; then
  echo "FIX THESE SPECIFIC ISSUES:" >&2
  echo -e "$FAILURES" >&2
fi

# Coaching: progressive urgency
REMAINING=$((MAX_ITERATIONS - NEXT))
if [ "$REMAINING" -le 2 ]; then
  echo "" >&2
  echo "⚠ Only $REMAINING passes remaining. Focus on failing gates only." >&2
  echo "  Do NOT refactor or add features — just fix what's broken." >&2
elif [ "$REMAINING" -le 5 ]; then
  echo "" >&2
  echo "Budget: $REMAINING passes remaining. Be targeted." >&2
fi

echo "══════════════════════════════════════════════" >&2

# EXIT 2 → Claude gets another turn
exit 2
