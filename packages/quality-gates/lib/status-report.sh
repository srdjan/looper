#!/usr/bin/env bash
# quality-gates/lib/status-report.sh
# Render Looper status, aggregates, and recommendations for the current project.

set -euo pipefail

ROOT="${1:-.}"
STATE_DIR="$ROOT/.claude/state"
SESSIONS_LOG="$STATE_DIR/sessions.jsonl"
SESSION_CURRENT="$STATE_DIR/session-current.json"
CONFIG="$ROOT/.claude/looper.json"
KERNEL_STATE="$STATE_DIR/kernel.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/recommendations.sh"
source "$SCRIPT_DIR/provenance.sh"

print_runtime_block() {
  local kernel_state="$1"
  [ -f "$kernel_state" ] || return 0
  if ! jq -e '.status == "config_blocked" and (.missing_runtimes | length > 0)' "$kernel_state" >/dev/null 2>&1; then
    return 0
  fi

  echo "Runtime Block:"
  jq -r '
    .missing_runtimes[]
    | "  - " + .package + ": requires runtime " + .runtime + " (command: " + .command + ")"
  ' "$kernel_state"
  echo "  Fix: install the missing runtime or remove the package from .claude/looper.json."
}

RUNTIME_BLOCK=$(print_runtime_block "$KERNEL_STATE")

if [ ! -f "$SESSIONS_LOG" ]; then
  echo "No session history yet. Sessions are recorded after the first loop completes."
  if [ -n "$RUNTIME_BLOCK" ]; then
    echo ""
    echo "$RUNTIME_BLOCK"
  fi
  exit 0
fi

SESSION_COUNT=$(wc -l < "$SESSIONS_LOG" | tr -d ' ')

echo "Session History (last ${SESSION_COUNT} sessions):"
echo ""
printf "  %-2s %-17s %-7s %-10s %-10s %s\n" "#" "Status" "Iters" "Score" "Baseline" "Timestamp"
tail -n 10 "$SESSIONS_LOG" | jq -sr '
  to_entries[]
  | "  \(.key + 1)\t\(.value.status)\t\(.value.iteration)/\(.value.max_iterations)\t\(.value.score)/\(.value.total)\t" +
    (if (.value.preexisting_failures // 0) > 0 then "\(.value.preexisting_failures) saved" else "-" end) +
    "\t\(.value.timestamp)"
' | while IFS=$'\t' read -r idx status iters score baseline timestamp; do
  printf "  %-2s %-17s %-7s %-10s %-10s %s\n" "$idx" "$status" "$iters" "$score" "$baseline" "$timestamp"
done

echo ""
echo "Summary:"
jq -sr '
  def pct(n; d): if d == 0 then 0 else ((n * 100 / d) | floor) end;
  . as $rows
  | $rows | length as $total
  | [$rows[] | select(.status == "complete")] | length as $complete
  | [$rows[] | select(.status == "budget_exhausted")] | length as $budget
  | ([$rows[].iteration] | if length == 0 then 0 else (add / length) end) as $avg
  | ([$rows[].preexisting_failures // 0] | add // 0) as $saved
  | [
      "  Total sessions: \($total)",
      "  Completed: \($complete) (\(pct($complete; $total))%)",
      "  Budget exhausted: \($budget) (\(pct($budget; $total))%)",
      "  Average iterations: \($avg)",
      "  Iterations saved by baseline: \($saved)"
    ] | .[]
' "$SESSIONS_LOG"

if [ -f "$SESSION_CURRENT" ]; then
  echo ""
  echo "Current session (in progress):"
  jq -r '
    [
      "  Iteration: \(.iteration)/\(.max_iterations)",
      "  Score: \(.score)/\(.total)",
      "  Introduced failures: \(.introduced_failures)",
      "  Pre-existing failures: \(.preexisting_failures)"
    ] | .[]
  ' "$SESSION_CURRENT"
fi

if [ -f "$CONFIG" ]; then
  echo ""
  echo "Config:"
  jq -r '
    [
      "  Max iterations: \(.max_iterations // 10)",
      "  Packages: \((.packages // []) | join(", "))",
      "  Baseline: " + (if ."quality-gates".baseline == true then "enabled" else "disabled" end),
      "  Gates: \((."quality-gates".gates // []) | map(.name) | join(", "))"
    ] | .[]
  ' "$CONFIG"

  RECOMMENDATIONS=$(recommendations_json "$SESSIONS_LOG" "$CONFIG" "$KERNEL_STATE" 0 0 0)
  RECOMMENDATION_BLOCK=$(print_recommendations_block "$RECOMMENDATIONS" "Recommendations" 3)
  if [ -n "$RECOMMENDATION_BLOCK" ]; then
    echo ""
    echo "$RECOMMENDATION_BLOCK"
  fi
fi

TRACE_LOG=$(pass_trace_log_path "$STATE_DIR/quality-gates")
IFS=$'\t' read -r TRACE_SESSION_ID TRACE_PASS < <(latest_trace_context "$TRACE_LOG" || true)
if [ -n "${TRACE_SESSION_ID:-}" ] && [ -n "${TRACE_PASS:-}" ] && [ "$TRACE_PASS" != "0" ]; then
  PROVENANCE_BLOCK=$(render_provenance_block "$TRACE_LOG" "$TRACE_SESSION_ID" "$TRACE_PASS" "Failure Introduction Points" 3)
  if [ -n "$PROVENANCE_BLOCK" ]; then
    echo ""
    echo "$PROVENANCE_BLOCK"
  fi
fi

if [ -n "$RUNTIME_BLOCK" ]; then
  echo ""
  echo "$RUNTIME_BLOCK"
fi
