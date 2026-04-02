#!/usr/bin/env bash
# .claude/hooks/state-utils.sh
# Shared state management for the improvement loop.
# Sources into other hooks — not executed directly.

STATE_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/state"
STATE_FILE="$STATE_DIR/loop-state.json"
LOOPER_CONFIG="${CLAUDE_PROJECT_DIR:-.}/.claude/looper.json"
MAX_ITERATIONS=$(jq -r '.max_iterations // 10' "$LOOPER_CONFIG" 2>/dev/null || echo 10)

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

init_state() {
  ensure_state_dir
  jq -n \
    --argjson max_iterations "$MAX_ITERATIONS" \
    '{
      iteration: 0,
      max_iterations: $max_iterations,
      scores: [],
      checks: {},
      status: "running",
      files_touched: []
    }' > "$STATE_FILE"
}

ensure_state_file() {
  if [ ! -f "$STATE_FILE" ]; then
    init_state
  fi
}

update_state() {
  local filter="$1"
  ensure_state_file

  local tmp
  tmp=$(mktemp)
  jq "$filter" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

read_state() {
  local field="$1"
  ensure_state_file
  jq -r "$field" "$STATE_FILE"
}

write_state() {
  local field="$1"
  local value="$2"
  update_state "$field = $value"
}

append_state() {
  local field="$1"
  local value="$2"
  update_state "$field += [$value]"
}

increment_iteration() {
  local current
  current=$(read_state '.iteration')
  write_state '.iteration' "$(( current + 1 ))"
  echo "$(( current + 1 ))"
}

is_budget_exhausted() {
  local current
  current=$(read_state '.iteration')
  [ "$current" -ge "$MAX_ITERATIONS" ]
}

# ── Config helpers ──────────────────────────────────────────

# Returns true if a jq-extracted value is present (not null/empty).
is_set() {
  [ -n "$1" ] && [ "$1" != "null" ]
}

resolve_config_path() {
  if [ -f "$LOOPER_CONFIG" ]; then
    echo "$LOOPER_CONFIG"
    return
  fi

  local bundled="${SCRIPT_DIR:-}/../looper.json"
  if [ -f "$bundled" ]; then
    echo "$bundled"
    return
  fi

  echo "Error: .claude/looper.json not found. Run the installer to create it." >&2
  return 1
}

load_gates_config() {
  local config_path
  config_path=$(resolve_config_path) || return 1
  jq '[.gates[] | select(.enabled != false)]' "$config_path"
}

load_config_key() {
  local key="$1"
  local config_path
  config_path=$(resolve_config_path) || return 1
  jq -r "$key" "$config_path"
}

load_checks_config() {
  local config_path
  config_path=$(resolve_config_path) || return 1
  jq '[(.checks // [])[] | select(.enabled != false)]' "$config_path"
}

# ── Pattern matching ────────────────────────────────────────

# Core glob match: one file against one pattern.
# shellcheck disable=SC2254
glob_match() {
  [[ "$1" == $2 ]]
}

# Check if a file matches any of a comma-separated set of globs.
# Matches against both basename and full path.
file_matches_pattern() {
  local file="$1"
  local patterns="$2"
  local base
  base="${file##*/}"

  local IFS=','
  for pattern in $patterns; do
    pattern="${pattern# }"
    pattern="${pattern% }"
    glob_match "$base" "$pattern" && return 0
    glob_match "$file" "$pattern" && return 0
  done
  return 1
}

# Check if any file in files_touched matches a JSON array of globs.
# Pre-extracts both arrays to avoid spawning jq inside nested loops.
files_match_patterns() {
  local patterns_json="$1"
  local files_str patterns_str

  files_str=$(read_state '.files_touched | .[]')
  patterns_str=$(echo "$patterns_json" | jq -r '.[]')

  local pattern file
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    while IFS= read -r file; do
      [ -z "$file" ] && continue
      glob_match "$file" "$pattern" && return 0
    done <<< "$files_str"
  done <<< "$patterns_str"

  return 1
}

# ── Timeout wrapper ─────────────────────────────────────────

run_with_timeout() {
  local secs="$1"
  shift
  if command -v timeout &>/dev/null; then
    timeout "$secs" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$secs" "$@"
  else
    "$@"
  fi
}
