#!/usr/bin/env bash
# quality-gates/hooks/pre-tool-use.sh
# Tracks files edited during the current pass for provenance feedback.

set -euo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')

if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
  exit 0
fi

source "$LOOPER_HOOKS_DIR/pkg-utils.sh"

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
if [ -n "$FILE" ]; then
  {
    STATE_FILE=$(_ensure_pkg_state)
    tmp=$(mktemp)
    jq --arg file "$FILE" \
      '.current_pass_files = ((.current_pass_files // []) | if index($file) then . else . + [$file] end)' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  } || true
fi

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
