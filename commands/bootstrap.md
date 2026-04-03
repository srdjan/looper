---
description: Bootstrap looper configuration or migrate from install.sh
allowed-tools: Bash(jq:*), Bash(rm:*), Bash(test:*), Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# Looper Bootstrap

This command handles two scenarios: migrating from the old install.sh-based setup, and bootstrapping a fresh project.

## Step 1: Detect Old Installation

Check for artifacts left by the old `install.sh`:

1. Check if `.claude/hooks/kernel.sh` exists (copied kernel - old install)
2. Check if `.claude/settings.json` contains hook commands referencing `kernel.sh`
3. Check if `.claude/packages/quality-gates/` exists (copied package)
4. Check if `skills/looper-config/` exists at project root (copied skill)

If ANY of these exist, proceed to Step 2 (migration). Otherwise, skip to Step 3 (fresh setup).

## Step 2: Migrate from install.sh

Explain to the user that old install.sh artifacts were detected and the plugin now handles hook registration and package bundling. Walk through cleanup:

1. **Remove old hook wiring**: Read `.claude/settings.json` and remove any hook entries where the command contains `kernel.sh`. Use jq to filter them out. If the hooks object becomes empty after removal, remove the hooks key entirely. Preserve all other settings.

2. **Remove copied kernel files**: Delete `.claude/hooks/kernel.sh` and `.claude/hooks/pkg-utils.sh`. If `.claude/hooks/` is empty afterward, remove the directory.

3. **Handle copied packages**: Check `.claude/packages/quality-gates/`. Ask the user if they customized any package handler scripts. If not customized, delete `.claude/packages/quality-gates/`. If customized, explain that the local copy will act as a project-level override of the plugin-bundled version (this is supported by design).

4. **Remove copied skills**: Delete `skills/looper-config/` at project root if it exists (now provided by the plugin as `/looper:looper-config`).

5. **Keep config and state**: Confirm that `.claude/looper.json` and `.claude/state/` are preserved as-is. No changes needed.

6. Report: "Migration complete. The looper plugin now handles hook registration and package distribution. Your looper.json config is unchanged."

## Step 3: Fresh Setup

If no old artifacts are detected:

1. Check if `.claude/looper.json` exists
2. If it exists: tell the user their config is already in place, and suggest `/looper:looper-config` to customize it
3. If it does not exist: the kernel's ensure_config will create a default on next session start. Offer to run `/looper:looper-config` for guided configuration instead of using defaults.
