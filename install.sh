#!/usr/bin/env bash
# install.sh — Install the Agentic Improvement Loop into your project.
#
# Usage:
#   ./install.sh              # install in current directory
#   ./install.sh /path/to/proj # install in target project
#
# What it does:
#   1. Copies hook scripts to .claude/hooks/
#   2. Merges hook config into .claude/settings.json (preserves existing hooks)
#   3. Creates .claude/state/ for ephemeral loop state
#   4. Makes all hooks executable
#   5. Adds .claude/state/ to .gitignore

set -euo pipefail

# ── Target directory ────────────────────────────────────────
TARGET="${1:-.}"
TARGET=$(cd "$TARGET" && pwd)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$SCRIPT_DIR/.claude/hooks"
SETTINGS_SRC="$SCRIPT_DIR/.claude/settings.json"
LOOPER_CONFIG_SRC="$SCRIPT_DIR/.claude/looper.json"
# shellcheck source=/dev/null
source "$HOOKS_SRC/hook-manifest.sh"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Agentic Improvement Loop — Installer       ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Target: $TARGET"
echo ""

# ── Preflight checks ───────────────────────────────────────-
if ! command -v jq &>/dev/null; then
  echo "  jq is required but not found."
  if command -v brew &>/dev/null; then
    echo "  Running: brew install jq"
    brew install jq
  elif command -v apt-get &>/dev/null; then
    echo "  Running: sudo apt-get install -y jq"
    sudo apt-get install -y jq
  else
    echo "  Install manually: brew install jq / apt install jq / choco install jq"
    echo "  Then re-run this script."
    exit 1
  fi
  echo "  jq installed."
fi

if [ ! -d "$HOOKS_SRC" ]; then
  echo "✗ Cannot find source hooks at $HOOKS_SRC"
  echo "  Run this script from the repo root."
  exit 1
fi

# ── Create directories ──────────────────────────────────────
echo "  Creating .claude/hooks/ and .claude/state/..."
mkdir -p "$TARGET/.claude/hooks"
mkdir -p "$TARGET/.claude/state"

# ── Copy looper.json (only if not already present) ─────────
echo "  Copying gate config..."
LOOPER_CONFIG_DEST="$TARGET/.claude/looper.json"
if [ ! -f "$LOOPER_CONFIG_DEST" ]; then
  cp "$LOOPER_CONFIG_SRC" "$LOOPER_CONFIG_DEST"
  echo "    ✓ looper.json (customize gates for your stack)"
else
  echo "    ○ looper.json already exists — not overwritten"
fi

# ── Copy hook scripts ──────────────────────────────────────-
echo "  Copying hook scripts..."
for hook in "${HOOK_FILES[@]}"; do
  if [ -f "$HOOKS_SRC/$hook" ]; then
    cp "$HOOKS_SRC/$hook" "$TARGET/.claude/hooks/$hook"
    chmod +x "$TARGET/.claude/hooks/$hook"
    echo "    ✓ $hook"
  else
    echo "    ✗ $hook not found in source — skipping"
  fi
done

# ── Merge settings.json ────────────────────────────────────-
echo "  Configuring .claude/settings.json..."
EXISTING="$TARGET/.claude/settings.json"

if [ -f "$EXISTING" ]; then
  # Merge: combine hook arrays from both files
  echo "    Found existing settings — merging hooks..."

  MERGED=$(jq -s '
    .[0] as $existing
    | .[1] as $new
    | ($existing.hooks // {}) as $existing_hooks
    | ($new.hooks // {}) as $new_hooks
    | (
        [$existing_hooks, $new_hooks]
        | map(keys)
        | add
        | unique
        | reduce .[] as $event (
            {};
            .[$event] = (($existing_hooks[$event] // []) + ($new_hooks[$event] // []))
          )
      ) as $merged_hooks
    | $existing * { hooks: $merged_hooks }
  ' "$EXISTING" "$SETTINGS_SRC")

  # Backup existing
  cp "$EXISTING" "$EXISTING.bak"
  echo "$MERGED" | jq '.' > "$EXISTING"
  echo "    ✓ Merged (backup: settings.json.bak)"
else
  cp "$SETTINGS_SRC" "$EXISTING"
  echo "    ✓ Created fresh settings.json"
fi

# ── Update .gitignore ──────────────────────────────────────-
echo "  Updating .gitignore..."
GITIGNORE="$TARGET/.gitignore"

add_to_gitignore() {
  local pattern="$1"
  if [ -f "$GITIGNORE" ]; then
    if ! grep -qF "$pattern" "$GITIGNORE"; then
      echo "$pattern" >> "$GITIGNORE"
      echo "    ✓ Added '$pattern'"
    else
      echo "    ○ '$pattern' already present"
    fi
  else
    echo "$pattern" > "$GITIGNORE"
    echo "    ✓ Created .gitignore with '$pattern'"
  fi
}

add_to_gitignore ".claude/state/"
add_to_gitignore ".claude/settings.json.bak"

# ── Verify installation ────────────────────────────────────-
echo ""
echo "  Verifying..."
ERRORS=0

for hook in "${HOOK_FILES[@]}"; do
  if [ -x "$TARGET/.claude/hooks/$hook" ]; then
    echo "    ✓ $hook is executable"
  else
    echo "    ✗ $hook missing or not executable"
    ERRORS=$((ERRORS + 1))
  fi
done

if jq empty "$TARGET/.claude/settings.json" 2>/dev/null; then
  HOOK_COUNT=$(jq '[.hooks // {} | to_entries[] | .value | length] | add // 0' "$TARGET/.claude/settings.json")
  echo "    ✓ settings.json valid ($HOOK_COUNT hook entries)"
else
  echo "    ✗ settings.json is invalid JSON"
  ERRORS=$((ERRORS + 1))
fi

# ── Done ────────────────────────────────────────────────────
echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "╔══════════════════════════════════════════════╗"
  echo "║   ✓ Installation complete!                   ║"
  echo "╠══════════════════════════════════════════════╣"
  echo "║                                              ║"
  echo "║   Start Claude Code in your project:         ║"
  echo "║     cd $TARGET"
  echo "║     claude                                   ║"
  echo "║                                              ║"
  echo "║   The improvement loop activates on new      ║"
  echo "║   sessions automatically. Give Claude a      ║"
  echo "║   task and watch it iterate until all gates  ║"
  echo "║   pass or the budget is reached.             ║"
  echo "║                                              ║"
  echo "║   Configuration (.claude/looper.json):       ║"
  echo "║     max_iterations  — loop budget            ║"
  echo "║     gates           — commands and weights   ║"
  echo "║                                              ║"
  echo "╚══════════════════════════════════════════════╝"
else
  echo "⚠ Installation completed with $ERRORS error(s)."
  echo "  Check the messages above and fix manually."
fi
echo ""
