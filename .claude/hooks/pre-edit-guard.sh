#!/usr/bin/env bash
# .claude/hooks/pre-edit-guard.sh
# PreToolUse hook for Edit|MultiEdit|Write.
#
# Two responsibilities:
#   1. Block edits if iteration budget is exhausted
#   2. Inject current iteration number into Claude's context
#      via JSON output with additionalContext

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state-utils.sh"

INPUT=$(cat)
ITERATION=$(read_state '.iteration')
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // "unknown"')

# ── Gate: block edits after budget exhausted ────────────────
if is_budget_exhausted; then
  echo "Budget exhausted: $MAX_ITERATIONS iterations reached. No further edits allowed." >&2
  echo "Summarize what was accomplished and what remains." >&2
  exit 2
fi

# ── Track touched files ────────────────────────────────────-
# Deduplicate — only add if not already tracked
if ! jq -e --arg f "$FILE" '.files_touched | index($f)' "$STATE_FILE" >/dev/null; then
  append_state '.files_touched' "\"$FILE\""
fi

# ── Inject iteration context ───────────────────────────────
# additionalContext is added to Claude's context window
# so it knows which pass it's on without us telling it in stderr
jq -n \
  --arg iter "$ITERATION" \
  --arg max "$MAX_ITERATIONS" \
  --arg file "$FILE" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      additionalContext: ("Improvement pass \($iter)/\($max). Editing: \($file)")
    }
  }'

exit 0
