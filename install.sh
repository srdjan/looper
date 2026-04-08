#!/usr/bin/env bash
# install.sh - Install Looper for Claude Code
# Usage: curl -fsSL https://raw.githubusercontent.com/srdjan/looper/main/install.sh | bash
set -euo pipefail

# Flip to 1 when the marketplace listing is live
LOOPER_MARKETPLACE="${LOOPER_MARKETPLACE:-0}"
INSTALL_DIR="${LOOPER_INSTALL_DIR:-$HOME/.claude/plugins/looper}"
REPO_URL="https://github.com/srdjan/looper.git"

info()  { printf '  %s\n' "$*"; }
fail()  { printf '  ERROR: %s\n' "$*" >&2; exit 1; }
ok()    { printf '  v %s\n' "$*"; }

echo ""
echo "Looper installer"
echo "================"
echo ""

# ── Dependency checks ──────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required but not installed.
    macOS:         brew install jq
    Debian/Ubuntu: sudo apt install jq
    Fedora:        sudo dnf install jq"
fi
ok "jq found ($(jq --version 2>&1))"

if ! command -v claude >/dev/null 2>&1; then
  fail "claude is required but not installed.
    Install Claude Code: https://docs.anthropic.com/en/docs/claude-code"
fi
ok "claude found"

# ── Marketplace path ───────────────────────────────────
if [ "$LOOPER_MARKETPLACE" = "1" ]; then
  info "Installing from the official marketplace..."
  claude plugin install looper@claude-plugins-official
  ok "Looper installed via marketplace"
  echo ""
  info "Start claude in any project to begin."
  info "Run /looper:bootstrap to verify your setup."
  exit 0
fi

# ── Git clone path ─────────────────────────────────────
if ! command -v git >/dev/null 2>&1; then
  fail "git is required for source install but not found."
fi

if [ -d "$INSTALL_DIR/.git" ]; then
  info "Existing install found at $INSTALL_DIR, updating..."
  git -C "$INSTALL_DIR" pull --ff-only --quiet
  ok "Updated to latest"
else
  info "Cloning looper to $INSTALL_DIR..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --quiet "$REPO_URL" "$INSTALL_DIR"
  ok "Cloned to $INSTALL_DIR"
fi

echo ""
echo "Looper installed."
echo ""
echo "To use it, start Claude Code with:"
echo "  claude --plugin-dir $INSTALL_DIR"
echo ""
echo "Or add an alias to your shell profile:"
echo "  alias claude-looper='claude --plugin-dir $INSTALL_DIR'"
echo ""
echo "Inside a session, run /looper:bootstrap to verify your setup."
echo ""
