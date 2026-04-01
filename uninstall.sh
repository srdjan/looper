#!/usr/bin/env bash
# uninstall.sh — Remove the Agentic Improvement Loop from your project.
#
# Usage:
#   ./uninstall.sh              # uninstall from current directory
#   ./uninstall.sh /path/to/proj

set -euo pipefail

TARGET="${1:-.}"
TARGET=$(cd "$TARGET" && pwd)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/.claude/hooks/hook-manifest.sh"

echo ""
echo "  Removing Agentic Improvement Loop from: $TARGET"
echo ""

# ── Remove hook scripts ────────────────────────────────────-
for hook in "${HOOK_FILES[@]}"; do
  FILE="$TARGET/.claude/hooks/$hook"
  if [ -f "$FILE" ]; then
    rm "$FILE"
    echo "  ✓ Removed hooks/$hook"
  fi
done

# ── Remove state directory ─────────────────────────────────-
if [ -d "$TARGET/.claude/state" ]; then
  rm -rf "$TARGET/.claude/state"
  echo "  ✓ Removed state/"
fi

# ── Clean settings.json ────────────────────────────────────-
SETTINGS="$TARGET/.claude/settings.json"
if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
  # Remove hook entries that reference our scripts
  CLEANED=$(jq '
    .hooks |= (
      if . then
        to_entries | map(
          .value |= map(
            select(
              (.hooks | not) or
              (.hooks | map(.command // "" | test("(session-start|pre-edit-guard|post-edit-check|stop-improve|state-utils)")) | any | not)
            )
          )
        ) | map(select(.value | length > 0)) | from_entries
      else .
      end
    )
  ' "$SETTINGS")
  echo "$CLEANED" | jq '.' > "$SETTINGS"
  echo "  ✓ Cleaned settings.json"
fi

# ── Restore backup if settings are now empty ────────────────
if [ -f "$SETTINGS" ]; then
  REMAINING=$(jq '.hooks | length' "$SETTINGS" 2>/dev/null || echo "0")
  if [ "$REMAINING" -eq 0 ] && [ -f "$SETTINGS.bak" ]; then
    mv "$SETTINGS.bak" "$SETTINGS"
    echo "  ✓ Restored settings.json from backup"
  fi
fi

echo ""
echo "  Done. Improvement loop removed."
echo ""
