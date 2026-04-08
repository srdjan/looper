#!/usr/bin/env bash
# uninstall.sh - Remove Looper for Claude Code
set -euo pipefail

INSTALL_DIR="${LOOPER_INSTALL_DIR:-$HOME/.claude/plugins/looper}"

info()  { printf '  %s\n' "$*"; }
ok()    { printf '  v %s\n' "$*"; }

echo ""
echo "Looper uninstaller"
echo "=================="
echo ""

# ── Remove plugin directory ────────────────────────────
if [ -d "$INSTALL_DIR" ]; then
  rm -rf "$INSTALL_DIR"
  ok "Removed $INSTALL_DIR"
else
  info "No install found at $INSTALL_DIR"
fi

# ── Offer to clean project state ──────────────────────
if [ -f ".claude/looper.json" ] || [ -d ".claude/state" ]; then
  echo ""
  info "Found looper files in the current directory:"
  [ -f ".claude/looper.json" ] && info "  .claude/looper.json"
  [ -d ".claude/state" ]       && info "  .claude/state/"
  echo ""
  printf '  Remove these? [y/N] '
  read -r answer </dev/tty 2>/dev/null || answer="n"
  if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    rm -f ".claude/looper.json"
    rm -rf ".claude/state"
    ok "Project state cleaned"
  else
    info "Kept project state"
  fi
fi

echo ""
echo "Looper uninstalled."
echo ""
