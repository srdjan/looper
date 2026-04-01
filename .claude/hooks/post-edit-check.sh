#!/usr/bin/env bash
# .claude/hooks/post-edit-check.sh
# PostToolUse hook for Edit|MultiEdit|Write.
#
# Runs fast, per-file checks immediately after each edit.
# stdout feeds back to Claude as context — lint/format issues
# get self-corrected on the next edit without waiting for Stop.

set -euo pipefail

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

# Only check TypeScript files
if ! echo "$FILE" | grep -qE '\.(ts|tsx)$'; then
  exit 0
fi

ISSUES=""

# ── Format check (don't fix — just report) ──────────────────
if command -v npx &>/dev/null && [ -f node_modules/.bin/prettier ]; then
  if ! npx prettier --check "$FILE" 2>/dev/null; then
    ISSUES="${ISSUES}\n⚠ Formatting: $FILE is not formatted. Run prettier."
    # Auto-fix silently so the next check passes
    npx prettier --write "$FILE" 2>/dev/null || true
  fi
fi

# ── Single-file lint (fast) ─────────────────────────────────
if command -v npx &>/dev/null && [ -f node_modules/.bin/eslint ]; then
  LINT_OUT=$(npx eslint "$FILE" 2>&1 || true)
  if echo "$LINT_OUT" | grep -qE '(error|warning)'; then
    ERROR_COUNT=$(echo "$LINT_OUT" | grep -c 'error' || echo "0")
    WARN_COUNT=$(echo "$LINT_OUT" | grep -c 'warning' || echo "0")
    ISSUES="${ISSUES}\n⚠ Lint: $FILE has $ERROR_COUNT errors, $WARN_COUNT warnings"
    # Show first 5 issues for targeted fixing
    echo "$LINT_OUT" | grep -E '(error|warning)' | head -5
  fi
fi

# ── Syntax check (instant — no full typecheck) ──────────────
if command -v npx &>/dev/null && [ -f tsconfig.json ]; then
  SYNTAX_OUT=$(npx tsc --noEmit --pretty false "$FILE" 2>&1 || true)
  if [ -n "$SYNTAX_OUT" ]; then
    SYNTAX_ERRORS=$(echo "$SYNTAX_OUT" | grep -c 'error TS' || echo "0")
    if [ "$SYNTAX_ERRORS" -gt 0 ]; then
      ISSUES="${ISSUES}\n⚠ Type errors in $FILE: $SYNTAX_ERRORS errors"
      echo "$SYNTAX_OUT" | grep 'error TS' | head -5
    fi
  fi
fi

# ── Report ──────────────────────────────────────────────────
if [ -n "$ISSUES" ]; then
  echo ""
  echo "── Post-edit check: $FILE ──"
  echo -e "$ISSUES"
  echo "Fix these before moving on."
else
  echo "✓ $FILE: format, lint, syntax all clean"
fi

exit 0
