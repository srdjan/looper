# Migrating from install.sh to Plugin

If you previously installed looper using `install.sh`, follow these steps to switch to the plugin distribution.

## Why Migrate

The plugin distribution replaces the shell installer with Claude Code's native plugin lifecycle. You get one-command install/update/disable, marketplace discovery, and no more manual file copying or settings.json merging.

## Prerequisites

- Claude Code with plugin support
- The looper plugin loaded from either:
  - the official marketplace after approval: `claude plugin install looper@claude-plugins-official`
  - local development checkout: `claude --plugin-dir /path/to/looper`

## Migration Steps

### 1. Install the Plugin

From the official marketplace after approval:

```
claude plugin install looper@claude-plugins-official
```

Or for local development:

```
claude --plugin-dir /path/to/looper
```

### 2. Remove Old Hook Wiring

Edit `.claude/settings.json` and remove all hook entries where the command references `kernel.sh`. These are typically under `SessionStart`, `PreToolUse`, `PostToolUse`, and `Stop`. The plugin's `hooks/hooks.json` now handles registration.

If your settings.json only contained looper hooks, you can delete the `hooks` key entirely.

### 3. Remove Copied Kernel Files

```bash
rm -f .claude/hooks/kernel.sh .claude/hooks/pkg-utils.sh
```

If `.claude/hooks/` is now empty, remove it:

```bash
rmdir .claude/hooks/ 2>/dev/null
```

### 4. Remove Copied Packages (Optional)

If you have NOT customized the package handler scripts:

```bash
rm -rf .claude/packages/quality-gates/
```

If you HAVE customized handlers (edited `stop.sh`, `session-start.sh`, etc.), keep them. The kernel uses a priority chain for package resolution: project-local packages in `.claude/packages/` take precedence over the plugin-bundled versions. Your customizations will continue to work.

### 5. Remove Copied Skills

```bash
rm -rf skills/looper-config/
```

The skill is now provided by the plugin as `/looper:looper-config`.

### 6. Keep Config and State

Do NOT delete:

- `.claude/looper.json` - your project configuration, used as-is
- `.claude/state/` - runtime state, preserved across the migration

## Automated Migration

Run `/looper:bootstrap` after installing the plugin. It detects old artifacts and walks you through cleanup interactively.

## Verifying

After migration, start a new Claude Code session. You should see the "Improvement Loop Active" message on session start, same as before. If you see it twice (from both old hooks and plugin), the old settings.json entries were not fully cleaned up.
