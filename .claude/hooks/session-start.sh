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
GATE_LIST=$(echo "$GATES" | jq -r '.[] | "  - \(.name)  (\(.weight)pts) — \(.command)"')

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

# ── Dynamic project context ─────────────────────────────────
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
