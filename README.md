<p align="center">
  <img src="assets/looper-logo.png" alt="Looper Logo" width="50%">
</p>

# Looper - Extensible Improvement Loop for Claude Code

Looper is a package-based improvement loop for Claude Code. A minimal kernel dispatches hook events to packages that define every step of the loop: what to check, how to score, when to stop. The bundled `quality-gates` package reproduces the classic behavior (typecheck, lint, test, coverage gates), but you can create packages for TDD cycles, security audits, documentation verification, or anything else.

## Install

As a Claude Code plugin:

```bash
claude plugin add looper
```

Or for local development:

```bash
claude --plugin-dir /path/to/looper
```

On first session start, the kernel creates a default `.claude/looper.json` with the `quality-gates` package. Run `/looper:looper-config` for guided configuration.

**Requirements:** `jq`.

## Disable / Uninstall

```bash
claude plugin disable looper     # stop hooks from firing
claude plugin remove looper      # remove the plugin entirely
```

Project config (`.claude/looper.json`) and state (`.claude/state/`) are preserved. Delete them manually if no longer needed.

## Migrating from install.sh

If you previously installed via `install.sh`, run `/looper:bootstrap` after installing the plugin. It detects and cleans up old artifacts. See [docs/migration.md](docs/migration.md) for manual steps.

## Usage

```bash
claude

> implement a user avatar upload endpoint with validation

# Claude works. After each response, the kernel dispatches to package stop
# handlers. If any package is unsatisfied, Claude gets another turn with
# feedback. When all packages are satisfied (or budget is reached), Claude stops.
```

## Configuration

Edit `.claude/looper.json`:

```json
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [
      { "name": "typecheck", "command": "npx tsc --noEmit --pretty false", "weight": 30, "skip_if_missing": "tsconfig.json" },
      { "name": "lint",      "command": "npx eslint .",                     "weight": 20, "skip_if_missing": "node_modules/.bin/eslint" },
      { "name": "test",      "command": "npm test",                         "weight": 30 },
      { "name": "coverage",  "command": "$LOOPER_PKG_DIR/lib/check-coverage.sh", "weight": 20, "required": false }
    ],
    "checks": [
      { "name": "format", "command": "npx prettier --check {file}", "fix": "npx prettier --write {file}", "pattern": "*.ts,*.tsx", "skip_if_missing": "node_modules/.bin/prettier" }
    ]
  }
}
```

Top-level keys `max_iterations` and `packages` are kernel config. Everything under a package name key is that package's config.

### Gate Options

| Field | Default | Description |
|-------|---------|-------------|
| `name` | required | Gate identifier |
| `command` | required | Shell command; exits 0 = pass |
| `weight` | required | Points awarded on pass |
| `skip_if_missing` | - | File/binary path; gate skipped with full points if absent |
| `required` | `true` | If `false`, gate failure doesn't block completion |
| `run_when` | - | Array of glob patterns; gate skipped if no `files_touched` match |
| `timeout` | 300 | Seconds before the gate command is killed |
| `enabled` | `true` | Set `false` to disable without removing |

### Post-Edit Checks

| Field | Default | Description |
|-------|---------|-------------|
| `name` | required | Check identifier |
| `command` | required | Shell command; `{file}` is replaced with the edited file path |
| `fix` | - | Auto-fix command run silently after a failing check |
| `pattern` | - | Comma-separated globs; check runs only on matching files |
| `skip_if_missing` | - | File/binary path; check skipped if absent |
| `enabled` | `true` | Set `false` to disable |

### Context and Coaching

```json
{
  "quality-gates": {
    "context": [
      "This project uses Deno with Oak framework.",
      "Never modify the API contract in docs/api.md."
    ],
    "discover": {
      "test_files": "find . -name '*.test.*' | head -20",
      "runtime": "deno --version 2>/dev/null || echo 'not installed'"
    },
    "coaching": {
      "urgency_at": 3,
      "on_failure": "Fix the specific failures. Do not refactor unrelated code.",
      "on_budget_low": "Only {remaining} passes left. Fix failing gates only."
    }
  }
}
```

## Architecture

Two layers: a kernel and packages.

```
looper.json (user config)
    |
    v
  KERNEL  (loop mechanics, hook dispatch, state, circuit breakers)
    |
    v
  PACKAGES  (quality-gates, tdd-loop, security-audit, ...)
    |
    v
  Claude Code hooks  (SessionStart, PreToolUse, PostToolUse, Stop)
```

The kernel is registered via the plugin's `hooks/hooks.json`. It receives hook events from Claude Code and dispatches to package handlers. Packages define the behavior.

### Kernel

Two files: `kernel.sh` (dispatcher) and `pkg-utils.sh` (state helpers). The kernel owns:

- Iteration tracking and budget enforcement
- Circuit breakers (`stop_hook_active` re-entry guard, budget cap)
- Hook dispatch to package handlers
- Package discovery and loading
- Shared state: `files_touched`

### Packages

A package is a directory with a manifest and optional handler scripts:

```
packages/quality-gates/
  package.json          # manifest
  hooks/
    session-start.sh    # SessionStart handler
    post-tool-use.sh    # PostToolUse handler
    stop.sh             # Stop handler
  lib/                  # helper scripts
  skills/               # SKILL.md files
  defaults.json         # default config
```

Convention over configuration: if `hooks/stop.sh` exists, the package handles Stop events. Missing handler = package has nothing to do for that event.

### Multi-Package Composition

Multiple packages run in declaration order. The kernel aggregates their stop/continue votes:

- All packages must vote "done" (exit 0) for the loop to stop
- Any package voting "continue" (exit 2) forces another iteration
- A two-phase model (`core` and `post`) lets secondary checks run only after primary packages are satisfied

```json
{
  "packages": ["quality-gates", "security-audit"],
  "quality-gates": { "gates": [...] },
  "security-audit": { "scan_command": "npm audit", "phase": "post" }
}
```

### Package Discovery

Packages are resolved from three search paths (first match wins):

1. `$CLAUDE_PROJECT_DIR/.claude/packages/<name>/` (project-local override)
2. `$HOME/.claude/packages/<name>/` (user-global)
3. `$CLAUDE_PLUGIN_ROOT/packages/<name>/` (bundled with the plugin)

## Creating a Package

Minimal package (three files):

```
my-package/
  package.json
  hooks/
    stop.sh
```

`package.json`:
```json
{
  "name": "my-package",
  "version": "1.0.0",
  "description": "Verify documentation accuracy"
}
```

`hooks/stop.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
source "$LOOPER_HOOKS_DIR/pkg-utils.sh"

CMD=$(pkg_config '.verify_command // "echo ok"')
if output=$(eval "$CMD" 2>&1); then
  echo "Docs verified." >&2
  exit 0
else
  echo "Documentation issues:" >&2
  echo "$output" | tail -10 >&2
  exit 2
fi
```

### Package Manifest

```json
{
  "name": "quality-gates",
  "version": "2.0.0",
  "description": "Quality gate loop",
  "matchers": {
    "PreToolUse": "Edit|MultiEdit|Write",
    "PostToolUse": "Edit|MultiEdit|Write"
  },
  "phase": "core",
  "skills": ["skills/looper-config"]
}
```

- `matchers`: regex for tool name filtering. Absent = all tools.
- `phase`: `"core"` (default) or `"post"`. Post-phase packages only run after all core packages are satisfied.
- `skills`: skill directories to install.

### Handler Environment

Every handler receives these environment variables:

| Variable | Value |
|----------|-------|
| `LOOPER_PKG_NAME` | Package name |
| `LOOPER_PKG_DIR` | Absolute path to package directory |
| `LOOPER_PKG_STATE` | Absolute path to this package's state directory |
| `LOOPER_STATE_DIR` | Absolute path to shared state root |
| `LOOPER_HOOKS_DIR` | Absolute path to kernel hooks directory |
| `LOOPER_CONFIG` | Absolute path to looper.json |
| `LOOPER_ITERATION` | Current iteration number |
| `LOOPER_MAX_ITERATIONS` | Budget cap |
| `CLAUDE_PROJECT_DIR` | Project root |

stdin: raw hook input JSON from Claude Code.

### State Utilities

Source `$LOOPER_HOOKS_DIR/pkg-utils.sh` in your handlers:

```bash
kernel_read '.iteration'          # read kernel state (read-only)
kernel_read '.files_touched[]'

pkg_state_read '.scores'          # read own state
pkg_state_write '.last_score' '85'
pkg_state_append '.scores' '85'

pkg_read "other-pkg" '.satisfied' # read another package's state

pkg_config '.gates'               # read own config from looper.json
```

## Circuit Breakers

1. **`stop_hook_active`**: prevents infinite re-entry when Claude is pushed back on the same turn.
2. **`iteration >= max_iterations`**: hard budget cap. PreToolUse also blocks edits when exhausted.
3. **All packages satisfied**: all package stop handlers exit 0.

## Feedback Channels

| Hook | When | Channel | Claude sees |
|------|------|---------|-------------|
| SessionStart | once | stdout | loop rules, package context |
| PreToolUse | per tool | JSON additionalContext | "Pass 3/10. Editing: src/foo.ts" |
| PostToolUse | per edit | stdout | per-file lint/type errors |
| Stop | per attempt | stderr | gate results, failures, coaching |

>
>#### Built By
> Claude & Srdjan
>

## License

MIT
