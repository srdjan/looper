#!/usr/bin/env bash
# .claude/hooks/stop-improve.sh
# Stop hook — the improvement loop driver.
#
# This is where the loop lives. When Claude finishes responding:
#   1. Check circuit breakers (stop_hook_active, budget)
#   2. Load gate config from .claude/looper.json
#   3. Run each gate: pass if exit 0, fail otherwise
#   4. Score the run (sum of passing gate weights)
#   5. If perfect: exit 0 → Claude stops
#   6. If imperfect: record score, write targeted feedback,
#      increment iteration, exit 2 → Claude gets another turn
#
# Exit codes:
#   0 = let Claude stop (all gates pass, budget hit, or breaker)
#   2 = push Claude back into agentic loop with feedback
#
# Gate config: .claude/looper.json
# Each gate: { "name": "...", "command": "...", "weight": N, "skip_if_missing": "..." }
# A gate passes if its command exits 0. skip_if_missing awards full points
# when the specified file/binary is absent (gate not applicable).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state-utils.sh"

INPUT=$(cat)

append_gate_result() {
  local symbol="$1" name="$2" detail="$3" awarded="$4" available="$5"
  GATE_RESULTS="${GATE_RESULTS}  ${symbol} ${name}: ${detail} (${awarded}/${available})\n"
}

append_failure_block() {
  local heading="$1" body="$2"
  FAILURES="${FAILURES}\n── ${heading} ──\n${body}\n"
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
# LOAD GATE CONFIG
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Export LOOPER_HOOKS_DIR so gate commands in looper.json can
# reference helper scripts via $LOOPER_HOOKS_DIR/script.sh
export LOOPER_HOOKS_DIR="$SCRIPT_DIR"

GATES=$(load_gates_config)
TOTAL=$(echo "$GATES" | jq '[.[].weight] | add')

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# QUALITY GATES
# Each gate: run command → pass if exit 0 → accumulate weight
# Fields: name, command, weight, skip_if_missing, required (default true),
#         run_when (glob patterns), timeout (seconds, default 300)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SCORE=0
FAILURES=""
GATE_RESULTS=""
CHECKS_PAIRS=""  # accumulates "name":true/false pairs for state
REQUIRED_FAILED=0  # count of required gates that failed

while IFS=$'\t' read -r name cmd weight skip_if is_required run_when_json gate_timeout; do
  echo "⏳ [Pass $CURRENT_PASS/$MAX_ITERATIONS] Running $name..." >&2

  is_set "$is_required" || is_required="true"
  is_set "$gate_timeout" || gate_timeout=300

  # skip_if_missing: gate not applicable to this project — award full points
  if is_set "$skip_if" && [ ! -e "$skip_if" ]; then
    SCORE=$((SCORE + weight))
    append_gate_result "○" "$name" "skipped — $skip_if not found" "$weight" "$weight"
    CHECKS_PAIRS="${CHECKS_PAIRS:+${CHECKS_PAIRS},}\"$name\":true"
    continue
  fi

  # run_when: skip gate if no touched files match the patterns
  if is_set "$run_when_json"; then
    if ! files_match_patterns "$run_when_json"; then
      SCORE=$((SCORE + weight))
      append_gate_result "○" "$name" "skipped — no matching files changed" "$weight" "$weight"
      CHECKS_PAIRS="${CHECKS_PAIRS:+${CHECKS_PAIRS},}\"$name\":true"
      continue
    fi
  fi

  # Run the gate command with timeout
  if gate_out=$(run_with_timeout "$gate_timeout" bash -c "$cmd" 2>&1); then
    SCORE=$((SCORE + weight))
    append_gate_result "✓" "$name" "pass" "$weight" "$weight"
    CHECKS_PAIRS="${CHECKS_PAIRS:+${CHECKS_PAIRS},}\"$name\":true"
  else
    exit_code=$?
    if [ "$exit_code" -eq 124 ]; then
      # timeout(1) returns 124 when the command times out
      append_gate_result "✗" "$name" "timed out (${gate_timeout}s)" "0" "$weight"
      append_failure_block "$name" "Command timed out after ${gate_timeout} seconds"
    else
      append_gate_result "✗" "$name" "failed" "0" "$weight"
      append_failure_block "$name" "$(echo "$gate_out" | tail -20)"
    fi
    CHECKS_PAIRS="${CHECKS_PAIRS:+${CHECKS_PAIRS},}\"$name\":false"
    if [ "$is_required" = "true" ]; then
      REQUIRED_FAILED=$((REQUIRED_FAILED + 1))
    fi
  fi
done < <(echo "$GATES" | jq -r '.[] | [.name, .command, (.weight | tostring), (.skip_if_missing // "null"), (if .required == false then "false" else "true" end), (if .run_when then (.run_when | tojson) else "null" end), (.timeout // "null" | tostring)] | @tsv')

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SCORE & DECIDE
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Record scores and per-gate results
append_state '.scores' "$SCORE"
write_state '.checks' "{${CHECKS_PAIRS}}"

# ── All required gates pass: done! ──────────────────────────
# Complete when: all required gates passed (REQUIRED_FAILED == 0).
# If optional gates failed, report them but still exit 0.
if [ "$REQUIRED_FAILED" -eq 0 ]; then
  write_state '.status' '"complete"'

  SCORES=$(read_state '.scores')
  echo "" >&2
  echo "══════════════════════════════════════════════" >&2
  if [ "$SCORE" -eq "$TOTAL" ]; then
    echo "  IMPROVEMENT LOOP COMPLETE — ALL GATES PASS" >&2
  else
    echo "  IMPROVEMENT LOOP COMPLETE — REQUIRED GATES PASS" >&2
    echo "  (Optional gates had failures — see below)" >&2
  fi
  echo "  Score: $SCORE/$TOTAL on pass $CURRENT_PASS" >&2
  echo "  Score history: $SCORES" >&2
  echo "──────────────────────────────────────────────" >&2
  echo -e "$GATE_RESULTS" >&2
  echo "══════════════════════════════════════════════" >&2

  if [ -n "$FAILURES" ] && [ "$SCORE" -lt "$TOTAL" ]; then
    echo "" >&2
    echo "Optional gate failures (non-blocking):" >&2
    echo -e "$FAILURES" >&2
  fi

  exit 0
fi

# ── Required gate(s) failed: increment and loop ────────────
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

# Load all coaching config in one jq call
IFS=$'\t' read -r COACHING_FAILURE COACHING_URGENCY COACHING_BUDGET < <(
  load_config_key '[.coaching.on_failure // "null", (.coaching.urgency_at // 5 | tostring), .coaching.on_budget_low // "null"] | @tsv' 2>/dev/null || echo "null	5	null"
)

if [ -n "$FAILURES" ]; then
  if is_set "$COACHING_FAILURE"; then
    echo "$COACHING_FAILURE" >&2
  else
    echo "FIX THESE SPECIFIC ISSUES:" >&2
  fi
  echo -e "$FAILURES" >&2
fi

# Coaching: progressive urgency
REMAINING=$((MAX_ITERATIONS - NEXT))

if [ "$REMAINING" -le 2 ]; then
  if is_set "$COACHING_BUDGET"; then
    echo "" >&2
    echo "${COACHING_BUDGET//\{remaining\}/$REMAINING}" >&2
  else
    echo "" >&2
    echo "Only $REMAINING passes remaining. Focus on failing gates only." >&2
    echo "  Do NOT refactor or add features - just fix what's broken." >&2
  fi
elif [ "$REMAINING" -le "$COACHING_URGENCY" ]; then
  echo "" >&2
  echo "Budget: $REMAINING passes remaining. Be targeted." >&2
fi

echo "══════════════════════════════════════════════" >&2

# EXIT 2 → Claude gets another turn
exit 2
