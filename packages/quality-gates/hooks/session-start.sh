#!/usr/bin/env bash
# quality-gates/hooks/session-start.sh
# Injects gate list, custom context, and project discovery into Claude's session.

set -euo pipefail
source "$LOOPER_HOOKS_DIR/pkg-utils.sh"
source "$LOOPER_PKG_DIR/lib/provenance.sh"

# ── Promote incomplete session from previous run ───────
SESSION_CURRENT="$LOOPER_STATE_DIR/session-current.json"
SESSIONS_LOG="$LOOPER_STATE_DIR/sessions.jsonl"
if [ -f "$SESSION_CURRENT" ]; then
  jq '.status = "budget_exhausted"' "$SESSION_CURRENT" >> "$SESSIONS_LOG" 2>/dev/null || true
  rm -f "$SESSION_CURRENT"
fi

pkg_state_write '.scores' '[]'
pkg_state_write '.checks' '{}'
pkg_state_write '.satisfied' 'false'
pkg_state_write '.baseline' 'null'
pkg_state_write '.current_pass_files' '[]'
ensure_session_id > /dev/null

GATES=$(pkg_config '.gates // [] | [.[] | select(.enabled != false)]')
TOTAL=$(echo "$GATES" | jq '[.[].weight] | add // 0')
GATE_LIST=$(echo "$GATES" | jq -r '.[] | "  - \(.name)  (\(.weight)pts) \(if .required == false then "[optional]" else "[required]" end) - \(.command)"')

# ── Baseline capture ───────────────────────────────────
BASELINE_ENABLED=$(pkg_config '.baseline // false' 2>/dev/null || echo "false")
BASELINE_TIMEOUT=$(pkg_config '.baseline_timeout // 60' 2>/dev/null || echo "60")

if [ "$BASELINE_ENABLED" = "true" ]; then
  BASELINE_PAIRS=""
  BASELINE_FAILURES=""

  while IFS=$'\t' read -r name cmd skip_if gate_timeout; do
    is_set "$gate_timeout" || gate_timeout="$BASELINE_TIMEOUT"

    if is_set "$skip_if" && [ ! -e "$skip_if" ]; then
      BASELINE_PAIRS="${BASELINE_PAIRS:+${BASELINE_PAIRS},}\"$name\":\"skip\""
      continue
    fi

    if run_with_timeout "$gate_timeout" bash -c "$cmd" >/dev/null 2>&1; then
      BASELINE_PAIRS="${BASELINE_PAIRS:+${BASELINE_PAIRS},}\"$name\":\"pass\""
    else
      BASELINE_PAIRS="${BASELINE_PAIRS:+${BASELINE_PAIRS},}\"$name\":\"fail\""
      BASELINE_FAILURES="${BASELINE_FAILURES}  ~ $name (pre-existing failure)\n"
    fi
  done < <(echo "$GATES" | jq -r '.[] | [.name, .command, (.skip_if_missing // "null"), (.timeout // "null" | tostring)] | @tsv')

  pkg_state_write '.baseline' "{${BASELINE_PAIRS}}"
fi

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

if [ "$BASELINE_ENABLED" = "true" ] && [ -n "$BASELINE_FAILURES" ]; then
  cat <<BASELINE

## Pre-Existing Failures (Baseline)

The following gates were already failing before you started. These will NOT
block you or cost iteration budget. Focus only on failures you introduce.

$(echo -e "$BASELINE_FAILURES")
BASELINE
fi

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
