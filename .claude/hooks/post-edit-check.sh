#!/usr/bin/env bash
# .claude/hooks/post-edit-check.sh
# PostToolUse hook for Edit|MultiEdit|Write.
#
# Runs fast, per-file checks immediately after each edit.
# stdout feeds back to Claude as context — lint/format issues
# get self-corrected on the next edit without waiting for Stop.
#
# Checks are configured via the "checks" array in looper.json.
# If no "checks" config exists, falls back to hardcoded TypeScript checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state-utils.sh"

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

[ -z "$FILE" ] && exit 0

# ── Config-driven checks ──────────────────────────────────
CHECKS=$(load_checks_config 2>/dev/null || echo '[]')
CHECK_COUNT=$(echo "$CHECKS" | jq 'length')

if [ "$CHECK_COUNT" -gt 0 ]; then
  ISSUES=""

  while IFS=$'\t' read -r name cmd fix_cmd pattern skip_if; do
    # Skip if file doesn't match pattern
    if is_set "$pattern" && ! file_matches_pattern "$FILE" "$pattern"; then
      continue
    fi

    # Skip if required binary/file is missing
    if is_set "$skip_if" && [ ! -e "$skip_if" ]; then
      continue
    fi

    # Substitute {file} placeholder
    local_cmd="${cmd//\{file\}/$FILE}"

    if ! check_out=$(eval "$local_cmd" 2>&1); then
      ERROR_LINES=$(echo "$check_out" | grep -cE '(error|warning|Error|Warning)' || echo "0")
      ISSUES="${ISSUES}\n-- $name: $FILE has issues ($ERROR_LINES diagnostics)"
      echo "$check_out" | grep -E '(error|warning|Error|Warning)' | head -5 || true

      # Run fix command if provided
      if is_set "$fix_cmd"; then
        local_fix="${fix_cmd//\{file\}/$FILE}"
        eval "$local_fix" 2>/dev/null || true
      fi
    fi
  done < <(echo "$CHECKS" | jq -r '.[] | [.name, .command, (.fix // "null"), (.pattern // "null"), (.skip_if_missing // "null")] | @tsv')

  if [ -n "$ISSUES" ]; then
    echo ""
    echo "-- Post-edit check: $FILE --"
    echo -e "$ISSUES"
    echo "Fix these before moving on."
  else
    echo "ok $FILE: all checks clean"
  fi

  exit 0
fi

# ── Fallback: hardcoded TypeScript checks ──────────────────
# Used when no "checks" config exists in looper.json.
# This fallback will be removed in a future version.

# Only check TypeScript files
if ! echo "$FILE" | grep -qE '\.(ts|tsx)$'; then
  exit 0
fi

ISSUES=""

# Format check
if command -v npx &>/dev/null && [ -f node_modules/.bin/prettier ]; then
  if ! npx prettier --check "$FILE" 2>/dev/null; then
    ISSUES="${ISSUES}\n-- Formatting: $FILE is not formatted. Run prettier."
    npx prettier --write "$FILE" 2>/dev/null || true
  fi
fi

# Single-file lint
if command -v npx &>/dev/null && [ -f node_modules/.bin/eslint ]; then
  LINT_OUT=$(npx eslint "$FILE" 2>&1 || true)
  if echo "$LINT_OUT" | grep -qE '(error|warning)'; then
    ERROR_COUNT=$(echo "$LINT_OUT" | grep -c 'error' || echo "0")
    WARN_COUNT=$(echo "$LINT_OUT" | grep -c 'warning' || echo "0")
    ISSUES="${ISSUES}\n-- Lint: $FILE has $ERROR_COUNT errors, $WARN_COUNT warnings"
    echo "$LINT_OUT" | grep -E '(error|warning)' | head -5
  fi
fi

# Syntax check
if command -v npx &>/dev/null && [ -f tsconfig.json ]; then
  SYNTAX_OUT=$(npx tsc --noEmit --pretty false "$FILE" 2>&1 || true)
  if [ -n "$SYNTAX_OUT" ]; then
    SYNTAX_ERRORS=$(echo "$SYNTAX_OUT" | grep -c 'error TS' || echo "0")
    if [ "$SYNTAX_ERRORS" -gt 0 ]; then
      ISSUES="${ISSUES}\n-- Type errors in $FILE: $SYNTAX_ERRORS errors"
      echo "$SYNTAX_OUT" | grep 'error TS' | head -5
    fi
  fi
fi

if [ -n "$ISSUES" ]; then
  echo ""
  echo "-- Post-edit check: $FILE --"
  echo -e "$ISSUES"
  echo "Fix these before moving on."
else
  echo "ok $FILE: format, lint, syntax all clean"
fi

exit 0
