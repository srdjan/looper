#!/usr/bin/env bash
# quality-gates/hooks/stop.sh
# Runs quality gates, scores the result, reports pass/fail.
# Exit 0 = all required gates pass. Exit 2 = required gate failed.

set -euo pipefail
source "$LOOPER_HOOKS_DIR/pkg-utils.sh"

CURRENT_PASS=$((LOOPER_ITERATION + 1))

append_gate_result() {
  local symbol="$1" name="$2" detail="$3" awarded="$4" available="$5"
  GATE_RESULTS="${GATE_RESULTS}  ${symbol} ${name}: ${detail} (${awarded}/${available})\n"
}

append_failure_block() {
  local heading="$1" body="$2"
  FAILURES="${FAILURES}\n-- ${heading} --\n${body}\n"
}

append_preexisting_block() {
  local heading="$1" body="$2"
  PREEXISTING="${PREEXISTING}\n-- ${heading} --\n${body}\n"
}

export LOOPER_HOOKS_DIR

GATES=$(pkg_config '.gates // [] | [.[] | select(.enabled != false)]')
TOTAL=$(echo "$GATES" | jq '[.[].weight] | add // 0')

# Read baseline if captured at SessionStart
BASELINE_JSON=$(pkg_state_read '.baseline // "null"')
has_baseline() {
  [ "$BASELINE_JSON" != "null" ] && [ "$BASELINE_JSON" != "" ]
}
baseline_status() {
  local gate_name="$1"
  if has_baseline; then
    echo "$BASELINE_JSON" | jq -r --arg n "$gate_name" '.[$n] // "unknown"'
  else
    echo "unknown"
  fi
}

SCORE=0
FAILURES=""
PREEXISTING=""
GATE_RESULTS=""
CHECKS_PAIRS=""
REQUIRED_FAILED=0

while IFS=$'\t' read -r name cmd weight skip_if is_required run_when_json gate_timeout; do
  echo "  [Pass $CURRENT_PASS/$LOOPER_MAX_ITERATIONS] Running $name..." >&2

  is_set "$is_required" || is_required="true"
  is_set "$gate_timeout" || gate_timeout=300

  if is_set "$skip_if" && [ ! -e "$skip_if" ]; then
    SCORE=$((SCORE + weight))
    append_gate_result "o" "$name" "skipped - $skip_if not found" "$weight" "$weight"
    CHECKS_PAIRS="${CHECKS_PAIRS:+${CHECKS_PAIRS},}\"$name\":true"
    continue
  fi

  if is_set "$run_when_json"; then
    if ! files_match_patterns "$run_when_json"; then
      SCORE=$((SCORE + weight))
      append_gate_result "o" "$name" "skipped - no matching files changed" "$weight" "$weight"
      CHECKS_PAIRS="${CHECKS_PAIRS:+${CHECKS_PAIRS},}\"$name\":true"
      continue
    fi
  fi

  if gate_out=$(run_with_timeout "$gate_timeout" bash -c "$cmd" 2>&1); then
    SCORE=$((SCORE + weight))
    append_gate_result "v" "$name" "pass" "$weight" "$weight"
    CHECKS_PAIRS="${CHECKS_PAIRS:+${CHECKS_PAIRS},}\"$name\":true"
  else
    exit_code=$?
    bl_status=$(baseline_status "$name")

    if [ "$bl_status" = "fail" ]; then
      # Pre-existing failure: don't count toward required failures, award no points
      if [ "$exit_code" -eq 124 ]; then
        append_gate_result "~" "$name" "pre-existing (timed out)" "0" "$weight"
      else
        append_gate_result "~" "$name" "pre-existing" "0" "$weight"
      fi
      append_preexisting_block "$name" "$(echo "$gate_out" | tail -10)"
      CHECKS_PAIRS="${CHECKS_PAIRS:+${CHECKS_PAIRS},}\"$name\":false"
    else
      # New failure or no baseline: count normally
      if [ "$exit_code" -eq 124 ]; then
        append_gate_result "x" "$name" "timed out (${gate_timeout}s)" "0" "$weight"
        append_failure_block "$name" "Command timed out after ${gate_timeout} seconds"
      else
        append_gate_result "x" "$name" "failed" "0" "$weight"
        append_failure_block "$name" "$(echo "$gate_out" | tail -20)"
      fi
      CHECKS_PAIRS="${CHECKS_PAIRS:+${CHECKS_PAIRS},}\"$name\":false"
      if [ "$is_required" = "true" ]; then
        REQUIRED_FAILED=$((REQUIRED_FAILED + 1))
      fi
    fi
  fi
done < <(echo "$GATES" | jq -r '.[] | [.name, .command, (.weight | tostring), (.skip_if_missing // "null"), (if .required == false then "false" else "true" end), (if .run_when then (.run_when | tojson) else "null" end), (.timeout // "null" | tostring)] | @tsv')

pkg_state_append '.scores' "$SCORE"
pkg_state_write '.checks' "{${CHECKS_PAIRS}}"

# ── Session summary ───────────────────────────────────
SESSIONS_LOG="$LOOPER_STATE_DIR/sessions.jsonl"
SESSION_CURRENT="$LOOPER_STATE_DIR/session-current.json"

# Count pre-existing vs introduced failures
PREEXISTING_COUNT=0
INTRODUCED_COUNT=0
if has_baseline; then
  PREEXISTING_COUNT=$(echo -e "$GATE_RESULTS" | grep -c '^ *~' || true)
fi
INTRODUCED_COUNT=$REQUIRED_FAILED

write_session_summary() {
  local status="$1"
  local scores
  scores=$(pkg_state_read '.scores')
  jq -n --arg s "$status" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson iter "$CURRENT_PASS" \
    --argjson max "$LOOPER_MAX_ITERATIONS" \
    --argjson score "$SCORE" \
    --argjson total "$TOTAL" \
    --argjson req_failed "$INTRODUCED_COUNT" \
    --argjson preexisting "$PREEXISTING_COUNT" \
    --argjson scores "$scores" \
    '{status:$s,timestamp:$ts,iteration:$iter,max_iterations:$max,score:$score,total:$total,introduced_failures:$req_failed,preexisting_failures:$preexisting,score_history:$scores}'
}

# Always write current session state (overwritten each stop)
write_session_summary "in_progress" > "$SESSION_CURRENT"

if [ "$REQUIRED_FAILED" -eq 0 ]; then
  pkg_state_write '.satisfied' 'true'

  SCORES=$(pkg_state_read '.scores')
  echo "" >&2
  echo "══════════════════════════════════════════════" >&2
  if [ "$SCORE" -eq "$TOTAL" ]; then
    echo "  QUALITY GATES - ALL PASS" >&2
  else
    echo "  QUALITY GATES - REQUIRED GATES PASS" >&2
    echo "  (Optional gates had failures - see below)" >&2
  fi
  echo "  Score: $SCORE/$TOTAL on pass $CURRENT_PASS" >&2
  echo "  Score history: $SCORES" >&2
  echo "----------------------------------------------" >&2
  echo -e "$GATE_RESULTS" >&2
  echo "══════════════════════════════════════════════" >&2

  if [ -n "$FAILURES" ] && [ "$SCORE" -lt "$TOTAL" ]; then
    echo "" >&2
    echo "Optional gate failures (non-blocking):" >&2
    echo -e "$FAILURES" >&2
  fi

  if [ -n "$PREEXISTING" ]; then
    echo "" >&2
    echo "Pre-existing failures (not your responsibility):" >&2
    echo -e "$PREEXISTING" >&2
  fi

  # Append completed session summary
  write_session_summary "complete" >> "$SESSIONS_LOG"
  rm -f "$SESSION_CURRENT"

  exit 0
fi

SCORES=$(pkg_state_read '.scores')

echo "" >&2
echo "══════════════════════════════════════════════" >&2
echo "  QUALITY GATES - PASS $CURRENT_PASS/$LOOPER_MAX_ITERATIONS" >&2
echo "  Score: $SCORE/$TOTAL" >&2
echo "  History: $SCORES" >&2
echo "----------------------------------------------" >&2
echo -e "$GATE_RESULTS" >&2
echo "----------------------------------------------" >&2

# Legend for baseline-aware symbols
if has_baseline; then
  echo "  v = pass  x = failed (you)  ~ = pre-existing  o = skipped" >&2
  echo "----------------------------------------------" >&2
fi

# Coaching
IFS=$'\t' read -r COACHING_FAILURE COACHING_URGENCY COACHING_BUDGET < <(
  pkg_config ' | [.coaching.on_failure // "null", (.coaching.urgency_at // 5 | tostring), .coaching.on_budget_low // "null"] | @tsv' 2>/dev/null || echo "null	5	null"
)

if [ -n "$FAILURES" ]; then
  if is_set "$COACHING_FAILURE"; then
    echo "$COACHING_FAILURE" >&2
  else
    echo "FIX THESE SPECIFIC ISSUES:" >&2
  fi
  echo -e "$FAILURES" >&2
fi

if [ -n "$PREEXISTING" ]; then
  echo "" >&2
  echo "Pre-existing failures (not blocking - do NOT fix these):" >&2
  echo -e "$PREEXISTING" >&2
fi

REMAINING=$((LOOPER_MAX_ITERATIONS - CURRENT_PASS))

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

exit 2
