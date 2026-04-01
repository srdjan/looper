#!/usr/bin/env bash
# .claude/hooks/state-utils.sh
# Shared state management for the improvement loop.
# Sources into other hooks — not executed directly.

set -euo pipefail

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
  cat > "$STATE_FILE" <<'EOF'
{
  "iteration": 0,
  "max_iterations": 10,
  "scores": [],
  "checks": {
    "typecheck": null,
    "lint": null,
    "test": null,
    "coverage": null
  },
  "status": "running",
  "files_touched": []
}
EOF
}

# ── Read a field from state ─────────────────────────────────
read_state() {
  local field="$1"
  if [ ! -f "$STATE_FILE" ]; then
    init_state
  fi
  jq -r "$field" "$STATE_FILE"
}

# ── Write a field to state ──────────────────────────────────
write_state() {
  local field="$1"
  local value="$2"
  if [ ! -f "$STATE_FILE" ]; then
    init_state
  fi
  local tmp
  tmp=$(mktemp)
  jq "$field = $value" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ── Append to an array field ────────────────────────────────
append_state() {
  local field="$1"
  local value="$2"
  if [ ! -f "$STATE_FILE" ]; then
    init_state
  fi
  local tmp
  tmp=$(mktemp)
  jq "$field += [$value]" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
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
