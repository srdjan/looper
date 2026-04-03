#!/usr/bin/env bash
# quality-gates/hooks/session-start.sh
# Injects gate list, custom context, and project discovery into Claude's session.

set -euo pipefail
source "$LOOPER_HOOKS_DIR/pkg-utils.sh"

pkg_state_write '.scores' '[]'
pkg_state_write '.checks' '{}'
pkg_state_write '.satisfied' 'false'

GATES=$(pkg_config '.gates // [] | [.[] | select(.enabled != false)]')
TOTAL=$(echo "$GATES" | jq '[.[].weight] | add // 0')
GATE_LIST=$(echo "$GATES" | jq -r '.[] | "  - \(.name)  (\(.weight)pts) \(if .required == false then "[optional]" else "[required]" end) - \(.command)"')

cat <<CONTEXT
## Quality Gates

After each response, the Stop hook runs the following quality gates and scores
your work out of $TOTAL points:

$GATE_LIST

Each gate passes if its command exits 0. If any required gate fails, you'll
receive the failures as feedback and get another turn. Fix the specific failures
reported - don't rewrite unrelated code.

Budget: $LOOPER_MAX_ITERATIONS passes total.
CONTEXT

CONTEXT_LINES=$(pkg_config '.context // [] | .[]' 2>/dev/null || true)
if [ -n "$CONTEXT_LINES" ]; then
  BRANCH=$(git branch --show-current 2>/dev/null || echo 'unknown')
  GATE_COUNT=$(echo "$GATES" | jq 'length')
  echo ""
  echo "## Project Context"
  while IFS= read -r line; do
    line="${line//\{max_iterations\}/$LOOPER_MAX_ITERATIONS}"
    line="${line//\{gate_count\}/$GATE_COUNT}"
    line="${line//\{branch\}/$BRANCH}"
    echo "$line"
  done <<< "$CONTEXT_LINES"
fi

DISCOVER_PAIRS=$(pkg_config '.discover // {} | to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null || true)

if [ -n "$DISCOVER_PAIRS" ]; then
  echo ""
  echo "## Project State"
  while IFS=$'\t' read -r key cmd; do
    [ -z "$key" ] && continue
    output=$(eval "$cmd" 2>/dev/null || echo "(command failed)")
    echo "$key: $output"
  done <<< "$DISCOVER_PAIRS"
else
  echo ""
  echo "## Project State"
  echo "Branch: $(git branch --show-current 2>/dev/null || echo 'not a git repo')"
  echo "Node: $(node --version 2>/dev/null || echo 'not installed')"

  if [ -f package.json ]; then
    echo ""
    echo "## Package Scripts"
    jq -r '.scripts // {} | to_entries[] | "  \(.key): \(.value)"' package.json 2>/dev/null || true
  fi
fi
