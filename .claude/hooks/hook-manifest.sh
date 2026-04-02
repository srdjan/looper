#!/usr/bin/env bash
# .claude/hooks/hook-manifest.sh
# Shared hook manifest for installer, uninstaller, and tests.

HOOK_FILES=(
  state-utils.sh
  session-start.sh
  pre-edit-guard.sh
  post-edit-check.sh
  stop-improve.sh
  check-coverage.sh
)
