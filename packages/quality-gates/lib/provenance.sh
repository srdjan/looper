#!/usr/bin/env bash
# quality-gates/lib/provenance.sh
# Pass-level provenance capture and feedback rendering for quality-gates.

set -euo pipefail

pass_trace_log_path() {
  echo "${1:-$LOOPER_PKG_STATE}/passes.jsonl"
}

current_pass_files_json() {
  pkg_state_read '.current_pass_files // []' 2>/dev/null || echo '[]'
}

ensure_session_id() {
  local session_id
  session_id=$(pkg_state_read '.session_id // ""' 2>/dev/null || echo "")
  if [ -n "$session_id" ] && [ "$session_id" != "null" ]; then
    echo "$session_id"
    return 0
  fi

  session_id="qg-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  pkg_state_write '.session_id' "\"$session_id\""
  echo "$session_id"
}

append_pass_trace() {
  local trace_log="$1"
  local row_json="$2"
  printf '%s\n' "$row_json" >> "$trace_log"
}

reset_current_pass_files() {
  pkg_state_write '.current_pass_files' '[]'
}

latest_trace_context() {
  local trace_log="$1"
  [ -f "$trace_log" ] || return 0
  tail -n 1 "$trace_log" | jq -r '[(.session_id // ""), (.pass // 0 | tostring)] | @tsv'
}

render_provenance_block() {
  local trace_log="$1"
  local session_id="$2"
  local current_pass="$3"
  local heading="${4:-PROVENANCE}"
  local limit="${5:-0}"

  [ -f "$trace_log" ] || return 0

  jq -sr \
    --arg sid "$session_id" \
    --argjson current "$current_pass" \
    --arg heading "$heading" \
    --argjson limit "$limit" '
    def is_red: . == "fail" or . == "timeout";
    def safe_files($row):
      ($row.files // [])
      | map(select(type == "string"))
      | unique;
    def files_for_window($rows; $start; $end):
      (
        $rows
        | map(select(.pass >= $start and .pass <= $end) | safe_files(.))
        | add
        | if . == null then [] else . end
        | unique
      );

    [ .[] | select(.session_id == $sid) ] as $rows
    | ($rows | map(select(.pass == $current)) | last) as $current_row
    | if $current_row == null then
        ""
      else
        (
          ($current_row.gates // {})
          | to_entries
          | map(select((.value.status // "unknown") | is_red))
          | map(
              .key as $gate
              | ($current_row.gates[$gate].status // "unknown") as $current_status
              | ($rows | map(select(.pass < $current)) | last) as $prev_row
              | (($prev_row.gates[$gate].status // "unknown")) as $prev_status
              | if $prev_status == "pass" then
                  {
                    group_pass: $current,
                    gate: $gate,
                    kind: "introduced",
                    files: safe_files($current_row)
                  }
                else
                  ([ $rows[] | { pass, status: (.gates[$gate].status // "unknown") } ]) as $timeline
                  | ($timeline | map(select(.pass < $current and .status == "pass")) | last | .pass // 0) as $last_pass
                  | ([ $timeline[] | select(.pass > $last_pass and .pass <= $current and (.status | is_red)) ]) as $red_window
                  | if ($red_window | length) >= 2 and ($red_window | last | .pass) == $current then
                      {
                        group_pass: ($red_window[0].pass),
                        gate: $gate,
                        kind: "persistent",
                        files: files_for_window($rows; $last_pass + 1; $current)
                      }
                    else
                      empty
                    end
                end
            )
        ) as $items
        | if ($items | length) == 0 then
            ""
          else
            (
              $items
              | sort_by(.group_pass, .gate)
              | group_by(.group_pass)
              | map(
                  . as $group
                  | ($group[0].group_pass) as $pass
                  | ($group[0].kind) as $kind
                  | ($group | map(.gate) | unique) as $gates
                  | ($group | map(.files) | add // [] | unique) as $files
                  | if $kind == "introduced" then
                      "  - Pass \($pass) introduced " + ($gates | join(", ")) + "." +
                      (
                        if ($files | length) > 0 then
                          " Files changed on this pass: " + ($files | join(", ")) + "."
                        else
                          " No edited files were captured on that pass."
                        end
                      )
                    else
                      "  - Pass \($pass) is the first failing pass for " + ($gates | join(", ")) + "." +
                      (
                        if ($files | length) > 0 then
                          " Files changed since the last green pass: " + ($files | join(", ")) + "."
                        else
                          " No edited files were captured since the last green pass."
                        end
                      )
                    end
                )
            ) as $lines
            | (if $limit > 0 then $lines[:$limit] else $lines end) as $limited
            | if ($limited | length) == 0 then
                ""
              else
                $heading + ":\n" + ($limited | join("\n"))
              end
          end
      end
  ' "$trace_log"
}
