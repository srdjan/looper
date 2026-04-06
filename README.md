<p align="center">
  <img src="assets/looper-logo.png" alt="Looper Logo" width="50%">
</p>

# Looper - Extensible Improvement Loop for Claude Code

Claude Code stops when it thinks it's done. Looper keeps it going until it's actually done. It's a native plugin that runs your quality checks - build, lint, tests - every time Claude says "finished," and pushes it back with the failures if anything is red. The code you get compiles, passes lint, and has green tests, because Claude kept iterating until those things were true. No external wrappers, no log scraping - it runs inside Claude Code's own hook system.

A minimal kernel dispatches hook events to packages that define every step of the loop: what to check, how to score, when to stop. The bundled `quality-gates` package reproduces the classic behavior (typecheck, lint, test, coverage gates), but you can create packages for TDD cycles, security audits, documentation verification, or anything else.

## Install

From the official Claude Code marketplace after approval:

```bash
claude plugin install looper@claude-plugins-official
```

For local development or pre-release testing:

```bash
claude --plugin-dir /path/to/looper
```

On first session start, the kernel auto-detects your tech stack (Rust, Go, Python, Deno, TypeScript+Biome, TypeScript+ESLint) and writes a `.claude/looper.json` with the matching preset. No configuration needed for common stacks. Run `/looper:looper-config` for fine-tuning.

**Requirements:** `jq`.

Bundled shell packages only need `jq`. SDK-authored packages declare their own runtime requirement in `package.json`; the current supported value is `deno`. If a configured package requires a missing runtime, Looper fails closed, prints a configuration error, and blocks edit tools until the runtime is installed or the package is removed from `.claude/looper.json`.

## Disable / Uninstall

```bash
claude plugin disable looper@claude-plugins-official    # stop hooks from firing
claude plugin uninstall looper@claude-plugins-official  # remove the plugin entirely
```

Project config (`.claude/looper.json`) and state (`.claude/state/`) are preserved. Delete them manually if no longer needed.

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

### Baseline-Aware Gating

Enable baseline capture to distinguish pre-existing failures from failures Claude introduces:

```json
{
  "quality-gates": {
    "baseline": true,
    "baseline_timeout": 60,
    "gates": [...]
  }
}
```

When `baseline` is `true`, all gates run at SessionStart before Claude makes any changes. The results are stored as a pass/fail snapshot. On each Stop evaluation, failures that match the baseline are marked as pre-existing (`~`) and do not force another iteration. Only new failures Claude introduces (`x`) cost iteration budget.

| Field | Default | Description |
|-------|---------|-------------|
| `baseline` | `false` | Enable baseline capture at session start |
| `baseline_timeout` | 60 | Per-gate timeout in seconds during baseline capture |

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

## Bundled Packages

### quality-gates

The default package. Runs typecheck, lint, test, and coverage gates after each response. Auto-detected per stack. See [Configuration](#configuration) above.

### scope-guard

Prevents Claude from editing files outside a declared scope. Uses PreToolUse to block edits to protected files in real time, and Stop (post phase) to report scope compliance.

```json
{
  "packages": ["quality-gates", "scope-guard"],
  "scope-guard": {
    "blocked": ["package-lock.json", ".env*", "*.config.js"],
    "allowed": ["src/**/*", "tests/**/*"]
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `blocked` | string[] | Glob patterns for files Claude must never edit. Edits are blocked in real time via PreToolUse. |
| `allowed` | string[] | Glob patterns for files Claude may edit. Out-of-scope edits are flagged at Stop. |

`blocked` patterns are enforced immediately: Claude's edit is denied before it happens. `allowed` patterns are checked at the end: if Claude edited files outside the allowed set, the loop continues until the violation is resolved.

scope-guard runs in the `post` phase, so it only evaluates after quality-gates passes.

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
  presets/              # stack-specific default configs
```

Convention over configuration: if `hooks/stop.sh` exists, the package handles Stop events. Missing handler = package has nothing to do for that event.

Package manifests can also declare an optional runtime requirement:

```json
{
  "name": "scope-guard",
  "version": "1.0.0",
  "description": "Prevent edits outside a declared scope",
  "runtime": "deno",
  "phase": "post"
}
```

Supported runtime values:

| Field | Type | Description |
|-------|------|-------------|
| `runtime` | string | Optional package-level runtime contract. `deno` is supported today. Missing runtimes put the kernel into `config_blocked` and block edits until fixed. |

### Multi-Package Composition

Multiple packages run in declaration order. The kernel aggregates their stop/continue votes:

- All packages must vote "done" (exit 0) for the loop to stop
- Any package voting "continue" (exit 2) forces another iteration
- A two-phase model (`core` and `post`) lets secondary checks run only after primary packages are satisfied

```json
{
  "packages": ["quality-gates", "scope-guard"],
  "quality-gates": { "gates": [...] },
  "scope-guard": { "blocked": ["package-lock.json", ".env*"], "allowed": ["src/**/*"] }
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
  "phase": "core"
}
```

- `matchers`: regex for tool name filtering. Absent = all tools.
- `phase`: `"core"` (default) or `"post"`. Post-phase packages only run after all core packages are satisfied.

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

## Session History

Each completed session appends a one-line JSON summary to `.claude/state/sessions.jsonl`. Budget-exhausted sessions are promoted to the log on the next SessionStart. Run `/looper:status` to view session history, aggregate stats, current config, and recommendation hints.

The log is local-only, gitignored, and contains: status, iterations, score, baseline savings, and timestamp. When recent history suggests a clear next move, Looper now surfaces lightweight recommendations such as enabling baseline, adjusting `max_iterations`, or adding `scope-guard`. The Stop hook also shows a short `Suggestions:` block during failing sessions when the signal is strong enough.

>
>#### Built By
> Claude & Srdjan
>

## License

MIT
