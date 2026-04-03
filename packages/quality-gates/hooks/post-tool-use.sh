#!/usr/bin/env bash
# quality-gates/hooks/post-tool-use.sh
# Runs fast, per-file checks immediately after each edit.

set -euo pipefail
source "$LOOPER_HOOKS_DIR/pkg-utils.sh"

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

[ -z "$FILE" ] && exit 0

CHECKS=$(pkg_config '.checks // [] | [.[] | select(.enabled != false)]' 2>/dev/null || echo '[]')
[ "$CHECKS" = "[]" ] && exit 0

ISSUES=""

while IFS=$'\t' read -r name cmd fix_cmd pattern skip_if; do
  if is_set "$pattern" && ! file_matches_pattern "$FILE" "$pattern"; then
    continue
  fi

  if is_set "$skip_if" && [ ! -e "$skip_if" ]; then
    continue
  fi

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
