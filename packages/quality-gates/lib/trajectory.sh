#!/usr/bin/env bash
# Within-session trajectory analysis: detect plateau, oscillation, regression.

set -euo pipefail

# detect_trajectory SCORES_JSON TOTAL
# Returns JSON: {"pattern":"plateau|oscillation|regression|null","detail":"..."}
detect_trajectory() {
  local scores_json="$1"
  local total="${2:-100}"

  echo "$scores_json" | jq --argjson total "$total" '
    def regression_obj:
      {
        pattern: "regression",
        detail: ("Score dropped from " + (.[-2] | tostring) + " to " + (.[-1] | tostring) + " (peak was " + (max | tostring) + ")")
      };

    if length < 3 then
      {pattern: null, detail: null}
    else
      . as $scores |
      $scores[-3:] as $last3 |
      $scores[-1] as $current |
      ($scores | max) as $peak |

      if ($last3 | unique | length) == 1 then
        # Count consecutive equal scores from the end (stop at first mismatch)
        ([range(length - 2; -1; -1) | select($scores[.] != $current)] | if length == 0 then -1 else .[0] end) as $break_idx |
        {
          pattern: "plateau",
          detail: ("Score " + ($current | tostring) + "/" + ($total | tostring) + " unchanged for " + ((length - 1 - $break_idx) | tostring) + " passes")
        }

      elif length >= 4 then
        ([range(1; length)] | map($scores[.] - $scores[. - 1]) | .[-3:]) as $recent |
        ([range(0; ($recent | length) - 1) | select($recent[.] * $recent[. + 1] < 0)] | length) as $alt |
        if $alt == (($recent | length) - 1) and $alt >= 2 then
          {
            pattern: "oscillation",
            detail: ("Score alternating: " + ($scores[-4:] | map(tostring) | join(" -> ")))
          }
        elif $current < $peak and $current < $scores[-2] then
          $scores | regression_obj
        else
          {pattern: null, detail: null}
        end

      elif $current < $peak and $current < $scores[-2] then
        $scores | regression_obj

      else
        {pattern: null, detail: null}
      end
    end
  '
}

# trajectory_coaching SCORES_JSON TOTAL REMAINING
# Returns coaching text to stdout, or empty if no pattern / budget exhausted.
trajectory_coaching() {
  local scores_json="$1"
  local total="${2:-100}"
  local remaining="${3:-0}"

  if [ "$remaining" -le 1 ]; then
    return 0
  fi

  local result
  result=$(detect_trajectory "$scores_json" "$total")

  local pattern detail
  IFS=$'\t' read -r pattern detail < <(echo "$result" | jq -r '[(.pattern // ""), (.detail // "")] | @tsv')
  [ -z "$pattern" ] && return 0

  case "$pattern" in
    plateau)
      echo "TRAJECTORY: $detail."
      echo "  Your current approach is not working. Try a fundamentally different strategy"
      echo "  rather than repeating the same fix."
      ;;
    oscillation)
      echo "TRAJECTORY: $detail."
      echo "  Fixing one gate appears to break another. Address the failing gates together"
      echo "  rather than individually."
      ;;
    regression)
      echo "TRAJECTORY: $detail."
      echo "  Recent changes may have introduced new failures. Consider reverting the last"
      echo "  change and taking a simpler approach."
      ;;
    *)
      ;;
  esac
}
