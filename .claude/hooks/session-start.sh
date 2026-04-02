#!/usr/bin/env bash
# .claude/hooks/session-start.sh
# SessionStart hook — stdout becomes Claude's context.
# Initializes the improvement loop state and seeds the session
# with project awareness.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state-utils.sh"

# ── Initialize fresh loop state ─────────────────────────────
init_state

# ── Load gate config ─────────────────────────────────────────
GATES=$(load_gates_config)
TOTAL=$(echo "$GATES" | jq '[.[].weight] | add')

# ── Build gate list for context injection ────────────────────
GATE_LIST=$(echo "$GATES" | jq -r '.[] | "  - \(.name)  (\(.weight)pts) \(if .required == false then "[optional]" else "[required]" end) — \(.command)"')

# ── Everything below is injected into Claude's context ──────
cat <<CONTEXT | sed "s/__MAX_ITERATIONS__/$MAX_ITERATIONS/g"
## Improvement Loop Active

You are operating inside an improvement loop (max __MAX_ITERATIONS__ passes).
After each response, a Stop hook runs the following quality gates and scores
your work out of $TOTAL points:

$GATE_LIST

Each gate passes if its command exits 0. If any gate fails, you'll receive
the failures as feedback and get another turn. Fix the specific failures
reported — don't rewrite unrelated code.

Each pass is numbered. You can see your current pass in the PreToolUse
context injection. Budget: __MAX_ITERATIONS__ passes total.
CONTEXT

# ── User-defined context lines ──────────────────────────────
# Injected from the "context" array in looper.json.
CONTEXT_LINES=$(load_config_key '.context // [] | .[]' 2>/dev/null || true)
if [ -n "$CONTEXT_LINES" ]; then
  BRANCH=$(git branch --show-current 2>/dev/null || echo 'unknown')
  GATE_COUNT=$(echo "$GATES" | jq 'length')
  echo ""
  echo "## Project Context"
  while IFS= read -r line; do
    # Simple variable substitution
    line="${line//\{max_iterations\}/$MAX_ITERATIONS}"
    line="${line//\{gate_count\}/$GATE_COUNT}"
    line="${line//\{branch\}/$BRANCH}"
    echo "$line"
  done <<< "$CONTEXT_LINES"
fi

# ── Project discovery ────────────────────────────────────────
# If "discover" is defined in looper.json, run those commands.
# Otherwise, use the default hardcoded discovery.
# Extract all key-value pairs in one jq call to avoid N+1 spawning.
DISCOVER_PAIRS=$(load_config_key '.discover // {} | to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null || true)

if [ -n "$DISCOVER_PAIRS" ]; then
  echo ""
  echo "## Project State"
  while IFS=$'\t' read -r key cmd; do
    [ -z "$key" ] && continue
    output=$(eval "$cmd" 2>/dev/null || echo "(command failed)")
    echo "$key: $output"
  done <<< "$DISCOVER_PAIRS"
else
  # Default discovery (hardcoded fallback)
  echo ""
  echo "## Project State"
  echo "Branch: $(git branch --show-current 2>/dev/null || echo 'not a git repo')"
  echo "Node: $(node --version 2>/dev/null || echo 'not installed')"
  echo ""

  if [ -f package.json ]; then
    echo "## Package Scripts"
    jq -r '.scripts // {} | to_entries[] | "  \(.key): \(.value)"' package.json 2>/dev/null || true
    echo ""
  fi

  echo "## Existing Test Files"
  find . -name '*.test.ts' -o -name '*.spec.ts' 2>/dev/null | head -20 || true
fi
