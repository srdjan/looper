#!/usr/bin/env bash
# quality-gates/lib/recommendations.sh
# Shared recommendation rules for status reporting and adaptive coaching.

set -euo pipefail

recent_sessions_json() {
  local sessions_log="$1"
  local limit="${2:-10}"
  if [ -f "$sessions_log" ]; then
    tail -n "$limit" "$sessions_log" | jq -s '.'
  else
    echo '[]'
  fi
}

add_recommendation() {
  local json="$1" id="$2" action="$3" reason="$4"
  echo "$json" | jq \
    --arg id "$id" \
    --arg action "$action" \
    --arg reason "$reason" \
    '. + [{id:$id, action:$action, reason:$reason}]'
}

recommendations_json() {
  local sessions_log="$1"
  local config_path="$2"
  local kernel_state="${3:-}"
  local current_iteration="${4:-0}"
  local max_iterations_hint="${5:-0}"
  local required_failed="${6:-0}"

  local recent_json
  recent_json=$(recent_sessions_json "$sessions_log" 10)

  local baseline_enabled max_iterations has_scope_guard files_touched
  baseline_enabled=$(jq -r '."quality-gates".baseline // false' "$config_path" 2>/dev/null || echo "false")
  max_iterations=$(jq -r '.max_iterations // 10' "$config_path" 2>/dev/null || echo "10")
  if jq -e '.packages // [] | index("scope-guard") != null' "$config_path" >/dev/null 2>&1; then
    has_scope_guard="true"
  else
    has_scope_guard="false"
  fi
  if [ -n "$kernel_state" ] && [ -f "$kernel_state" ]; then
    files_touched=$(jq -r '.files_touched | length' "$kernel_state" 2>/dev/null || echo "0")
  else
    files_touched=0
  fi

  local budget_exhausted_count complete_count avg_complete_iterations baseline_saved_total
  budget_exhausted_count=$(echo "$recent_json" | jq -r '[.[] | select(.status == "budget_exhausted")] | length')
  complete_count=$(echo "$recent_json" | jq -r '[.[] | select(.status == "complete")] | length')
  avg_complete_iterations=$(echo "$recent_json" | jq -r '
    [.[] | select(.status == "complete") | .iteration]
    | if length == 0 then 0 else (add / length) end
  ')
  baseline_saved_total=$(echo "$recent_json" | jq -r '[.[].preexisting_failures // 0] | add // 0')

  local recommendations='[]'

  if [ "$baseline_enabled" != "true" ] && { [ "$budget_exhausted_count" -ge 1 ] || { [ "$required_failed" -gt 0 ] && [ "$current_iteration" -ge 3 ]; }; }; then
    recommendations=$(add_recommendation \
      "$recommendations" \
      "enable_baseline" \
      'Consider enabling `"quality-gates".baseline`.' \
      'Recent retries or exhausted sessions suggest Looper may be spending effort on pre-existing failures.')
  fi

  if [ "$budget_exhausted_count" -ge 2 ] && [ "$max_iterations" -le 10 ]; then
    recommendations=$(add_recommendation \
      "$recommendations" \
      "increase_budget" \
      'Consider raising `max_iterations` to 12-15, or split tasks into smaller prompts.' \
      "The loop exhausted its budget $budget_exhausted_count time(s) in recent sessions.")
  fi

  if [ "$max_iterations" -gt 10 ] && [ "$complete_count" -ge 3 ] && awk "BEGIN { exit !($avg_complete_iterations <= 2.0) }"; then
    recommendations=$(add_recommendation \
      "$recommendations" \
      "lower_budget" \
      'Consider reducing `max_iterations` closer to 8-10.' \
      "Recent complete sessions average only $avg_complete_iterations iteration(s), so the current budget may be higher than needed.")
  fi

  if [ "$has_scope_guard" != "true" ] && [ "$files_touched" -ge 8 ]; then
    recommendations=$(add_recommendation \
      "$recommendations" \
      "add_scope_guard" \
      'Consider adding `scope-guard` for high-risk or tightly scoped tasks.' \
      "This session touched $files_touched files without an explicit scope package.")
  fi

  if [ "$baseline_enabled" = "true" ] && [ "$baseline_saved_total" -ge 3 ]; then
    recommendations=$(add_recommendation \
      "$recommendations" \
      "keep_baseline" \
      'Keep baseline enabled on this project.' \
      "Baseline has already saved $baseline_saved_total failure(s) across recent sessions.")
  fi

  echo "$recommendations"
}

print_recommendations_block() {
  local recommendations="$1"
  local heading="${2:-Recommendations}"
  local limit="${3:-3}"

  echo "$recommendations" | jq -r --arg heading "$heading" --argjson limit "$limit" '
    if length == 0 then
      ""
    else
      $heading + ":\n" +
      (
        .[:$limit]
        | to_entries
        | map("  " + ((.key + 1) | tostring) + ". " + .value.action + " " + .value.reason)
        | join("\n")
      )
    end
  '
}
