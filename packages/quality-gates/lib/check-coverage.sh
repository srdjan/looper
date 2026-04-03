#!/usr/bin/env bash
# .claude/hooks/check-coverage.sh
# Default coverage gate for the improvement loop.
# Reads coverage/coverage-summary.json (Jest/nyc format) and exits
# non-zero if line coverage is below 80%.
#
# Replace this command in .claude/looper.json to use a different
# coverage tool (e.g. "pytest --cov=src --cov-fail-under=80").

set -euo pipefail

COVERAGE_FILE="coverage/coverage-summary.json"
TARGET=80

if [ ! -f "$COVERAGE_FILE" ]; then
  echo "No coverage data found. Run tests with --coverage flag." >&2
  exit 1
fi

LINE_COV=$(jq -r '.total.lines.pct // 0' "$COVERAGE_FILE")

if ! awk -v c="$LINE_COV" -v t="$TARGET" 'BEGIN { exit !(c >= t) }'; then
  echo "Coverage ${LINE_COV}% is below ${TARGET}% target." >&2
  jq -r '
    to_entries[]
    | select(.key != "total")
    | select(.value.lines.pct < '"$TARGET"')
    | "\(.key): \(.value.lines.pct)%"
  ' "$COVERAGE_FILE" 2>/dev/null | head -5 >&2
  exit 1
fi

echo "Coverage: ${LINE_COV}%"
