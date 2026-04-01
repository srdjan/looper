#!/usr/bin/env bash
# .claude/hooks/state-utils.sh
# Shared state management for the improvement loop.
# Sources into other hooks — not executed directly.

STATE_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/state"
STATE_FILE="$STATE_DIR/loop-state.json"
MAX_ITERATIONS=10

# ── Ensure state directory exists ───────────────────────────
ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

# ── Initialize fresh state ──────────────────────────────────
init_state() {
  ensure_state_dir
  jq -n \
    --argjson max_iterations "$MAX_ITERATIONS" \
    '{
      iteration: 0,
      max_iterations: $max_iterations,
      scores: [],
      checks: {
        typecheck: null,
        lint: null,
        test: null,
        coverage: null
      },
      status: "running",
      files_touched: []
    }' > "$STATE_FILE"
}

# ── Ensure state file exists ─────────────────────────────────
ensure_state_file() {
  if [ ! -f "$STATE_FILE" ]; then
    init_state
  fi
}

# ── Apply a jq update atomically ─────────────────────────────
update_state() {
  local filter="$1"
  ensure_state_file

  local tmp
  tmp=$(mktemp)
  jq "$filter" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ── Read a field from state ─────────────────────────────────
read_state() {
  local field="$1"
  ensure_state_file
  jq -r "$field" "$STATE_FILE"
}

# ── Write a field to state ──────────────────────────────────
write_state() {
  local field="$1"
  local value="$2"
  update_state "$field = $value"
}

# ── Append to an array field ────────────────────────────────
append_state() {
  local field="$1"
  local value="$2"
  update_state "$field += [$value]"
}

# ── Increment iteration counter ─────────────────────────────
increment_iteration() {
  local current
  current=$(read_state '.iteration')
  write_state '.iteration' "$(( current + 1 ))"
  echo "$(( current + 1 ))"
}

# ── Check if budget is exhausted ────────────────────────────
is_budget_exhausted() {
  local current
  current=$(read_state '.iteration')
  [ "$current" -ge "$MAX_ITERATIONS" ]
}
