---
description: Bootstrap looper configuration
allowed-tools: Bash(jq:*), Bash(rm:*), Bash(test:*), Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# Looper Bootstrap

This command bootstraps a fresh project with looper configuration.

## Steps

1. Check if `.claude/looper.json` exists
2. If it exists: tell the user their config is already in place, and suggest `/looper:looper-config` to customize it
3. If it does not exist: the kernel's ensure_config will create a default on next session start. Offer to run `/looper:looper-config` for guided configuration instead of using defaults.
