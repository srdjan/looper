# The Looper Guide

A practical guide to getting quality gates running in your Claude Code projects.

---

## 1. What Looper Does

When Claude finishes a task, it stops. Looper intercepts that stop and asks: did the code actually pass your quality checks? If not, Claude gets another turn with the failure output as feedback. This repeats until all required gates pass or a budget is reached.

The effect is that Claude self-corrects. You ask for a feature, and the delivered code compiles, passes lint, and has green tests, because Claude kept iterating until those things were true.

Looper is a Claude Code plugin. It uses four hooks (SessionStart, PreToolUse, PostToolUse, Stop) to inject context, track edits, give per-file feedback, and evaluate quality gates. All behavior is defined by a single config file per project.

---

## 2. Installation

Install from the official marketplace after approval:

```bash
claude plugin install looper@claude-plugins-official
```

For local development or pre-release testing (running from a git clone):

```bash
claude --plugin-dir /path/to/looper
```

You need `jq` installed. On macOS: `brew install jq`. On Debian/Ubuntu: `apt install jq`.

Start Claude Code in any project and the plugin auto-detects your tech stack on the first session. It looks for marker files (Cargo.toml, go.mod, pyproject.toml, deno.json, tsconfig.json) and writes a `.claude/looper.json` with the matching preset: appropriate gates, checks, and tool commands for your stack. No configuration required for Rust, Go, Python, Deno, or TypeScript projects. Run `/looper:looper-config` to customize further.

---

## 3. Your First Run

```bash
cd your-project
claude
```

Prompt Claude with something that changes code:

```
add input validation to the user registration endpoint
```

Here is what happens behind the scenes:

1. **SessionStart** fires. The kernel initializes state and tells Claude about the active gates, their weights, and the iteration budget.

2. Claude works. Each file edit passes through **PreToolUse** (which tracks touched files and injects the pass counter) and **PostToolUse** (which runs fast per-file checks like prettier and eslint on the edited file).

3. Claude finishes and tries to stop. The **Stop** hook runs every gate command. If all required gates exit 0, the loop ends. If any required gate fails, the kernel sends the failure output back to Claude and increments the iteration counter.

4. Claude reads the failures and fixes them. Steps 2-3 repeat.

5. The loop ends when all required gates pass, the iteration budget is hit, or Claude re-enters the Stop hook on the same turn (a circuit breaker that prevents infinite loops).

---

## 4. Configuration

All config lives in `.claude/looper.json`. The kernel reads two top-level keys: `max_iterations` and `packages`. Everything under a package name key belongs to that package.

```json
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [...],
    "checks": [...],
    "context": [...],
    "coaching": {...}
  }
}
```

Run `/looper:looper-config` for guided setup. It detects your stack and proposes gates.

### 4.1 Gates

Gates are commands that run at the Stop hook. Each gate has a name, a command, and a weight. The command exits 0 to pass.

```json
{
  "gates": [
    { "name": "typecheck", "command": "npx tsc --noEmit --pretty false", "weight": 30, "skip_if_missing": "tsconfig.json" },
    { "name": "lint",      "command": "npx eslint .",                     "weight": 20, "skip_if_missing": "node_modules/.bin/eslint" },
    { "name": "test",      "command": "npm test",                         "weight": 30 },
    { "name": "coverage",  "command": "$LOOPER_PKG_DIR/lib/check-coverage.sh", "weight": 20, "required": false }
  ]
}
```

Gate options:

- **skip_if_missing**: a file or binary path. If absent, the gate is skipped and gets full points. This makes configs portable across projects where not every tool is installed.
- **required**: defaults to `true`. Set `false` for gates whose failure should not block completion. Coverage is a good candidate.
- **run_when**: an array of glob patterns. The gate only runs if at least one file in `files_touched` matches. Useful for skipping typecheck when only markdown was edited.
- **timeout**: seconds before the command is killed. Defaults to 300.
- **enabled**: set `false` to disable without removing the gate from config.

Weights are informational. They show up in the score output so Claude can prioritize. The loop stops when all required gates pass, regardless of score.

### 4.2 Post-Edit Checks

Checks run on individual files after each edit, before the Stop hook. They give Claude fast feedback without waiting for the full gate evaluation.

```json
{
  "checks": [
    { "name": "format",    "command": "npx prettier --check {file}", "fix": "npx prettier --write {file}", "pattern": "*.ts,*.tsx", "skip_if_missing": "node_modules/.bin/prettier" },
    { "name": "lint",      "command": "npx eslint {file}",           "pattern": "*.ts,*.tsx", "skip_if_missing": "node_modules/.bin/eslint" }
  ]
}
```

`{file}` is replaced with the edited file path. The `fix` command runs silently when the check fails. Prettier format violations get auto-fixed this way, so Claude never has to manually fix formatting.

`pattern` is a comma-separated list of globs. The check only runs on matching files.

### 4.3 Context Injection

Tell Claude things it needs to know about the project:

```json
{
  "context": [
    "This project uses Deno with Oak framework.",
    "Never modify the API contract in docs/api.md.",
    "Run tests with: deno test --allow-all"
  ]
}
```

These lines are injected into Claude's session at startup. You can use `{max_iterations}`, `{gate_count}`, and `{branch}` as placeholders.

### 4.4 Project Discovery

Run commands at session start and inject their output as context:

```json
{
  "discover": {
    "test_files": "find . -name '*.test.*' | head -20",
    "runtime": "deno --version 2>/dev/null || echo 'not installed'"
  }
}
```

If `discover` is omitted, the package falls back to showing the git branch, node version, and package.json scripts.

### 4.5 Coaching

Customize the feedback Claude receives when gates fail:

```json
{
  "coaching": {
    "urgency_at": 3,
    "on_failure": "Fix the specific failures. Do not refactor unrelated code.",
    "on_budget_low": "Only {remaining} passes left. Fix failing gates only."
  }
}
```

- **urgency_at**: when remaining passes drop to this number, the kernel starts showing budget warnings.
- **on_failure**: replaces the default "FIX THESE SPECIFIC ISSUES" heading.
- **on_budget_low**: replaces the default low-budget message. `{remaining}` is the passes left.

---

## 5. Reading the Output

The Stop hook writes to stderr. A typical evaluation looks like this:

```
  [Pass 1/10] Running typecheck...
  [Pass 1/10] Running lint...
  [Pass 1/10] Running test...
  [Pass 1/10] Running coverage...

  ══════════════════════════════════════════════
    QUALITY GATES - PASS 1/10
    Score: 80/100
    History: [80]
  ----------------------------------------------
    v typecheck: pass (30/30)
    v lint: pass (20/20)
    v test: pass (30/30)
    x coverage: failed (0/20)
  ----------------------------------------------
```

Symbols:

- `v` passed, full points
- `x` failed, zero points
- `o` skipped (full points awarded). Reasons: `skip_if_missing` file absent, `run_when` patterns did not match, or gate disabled.

When all required gates pass, you see `ALL PASS` or `REQUIRED GATES PASS` (if optional gates failed but required ones all passed).

When the budget runs out: `IMPROVEMENT LOOP COMPLETE - BUDGET REACHED`.

The PreToolUse hook injects a line like `Improvement pass 3/10. Editing: src/api.ts` into Claude's context on every file edit.

---

## 6. Stack Recipes

### TypeScript + ESLint + Prettier + Jest

The default config. Works out of the box for most Node/TypeScript projects.

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
      { "name": "format",    "command": "npx prettier --check {file}", "fix": "npx prettier --write {file}", "pattern": "*.ts,*.tsx,*.js,*.jsx", "skip_if_missing": "node_modules/.bin/prettier" },
      { "name": "lint",      "command": "npx eslint {file}",           "pattern": "*.ts,*.tsx,*.js,*.jsx", "skip_if_missing": "node_modules/.bin/eslint" }
    ]
  }
}
```

### Deno

Deno has built-in tools for everything. No `skip_if_missing` needed.

```json
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [
      { "name": "check", "command": "deno check .",    "weight": 30 },
      { "name": "lint",  "command": "deno lint",        "weight": 20 },
      { "name": "test",  "command": "deno test",        "weight": 30 },
      { "name": "fmt",   "command": "deno fmt --check",  "weight": 20, "required": false }
    ],
    "checks": [
      { "name": "fmt",   "command": "deno fmt --check {file}", "fix": "deno fmt {file}", "pattern": "*.ts,*.tsx" },
      { "name": "lint",  "command": "deno lint {file}",        "pattern": "*.ts,*.tsx" }
    ]
  }
}
```

### Python + mypy + ruff + pytest

```json
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [
      { "name": "typecheck", "command": "python -m mypy src/",  "weight": 30, "skip_if_missing": "mypy.ini" },
      { "name": "lint",      "command": "ruff check .",          "weight": 20, "skip_if_missing": "ruff.toml" },
      { "name": "test",      "command": "python -m pytest -q",   "weight": 30 },
      { "name": "format",    "command": "ruff format --check .", "weight": 20, "skip_if_missing": "ruff.toml", "required": false }
    ],
    "checks": [
      { "name": "format", "command": "ruff format --check {file}", "fix": "ruff format {file}", "pattern": "*.py", "skip_if_missing": "ruff.toml" },
      { "name": "lint",   "command": "ruff check {file}",          "pattern": "*.py", "skip_if_missing": "ruff.toml" }
    ]
  }
}
```

If `pyproject.toml` contains `[tool.ruff]`, use `pyproject.toml` for `skip_if_missing` instead of `ruff.toml`.

### Go

```json
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [
      { "name": "build", "command": "go build ./...",        "weight": 30 },
      { "name": "vet",   "command": "go vet ./...",          "weight": 20 },
      { "name": "test",  "command": "go test ./...",         "weight": 30 },
      { "name": "lint",  "command": "golangci-lint run",     "weight": 20, "skip_if_missing": ".golangci.yml", "required": false }
    ],
    "checks": [
      { "name": "format", "command": "test -z \"$(gofmt -l {file})\"", "fix": "gofmt -w {file}", "pattern": "*.go" }
    ]
  }
}
```

`gofmt -l` always exits 0, so it needs the `test -z` wrapper.

### Rust

```json
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [
      { "name": "check",  "command": "cargo check",                    "weight": 30 },
      { "name": "clippy", "command": "cargo clippy -- -D warnings",    "weight": 20 },
      { "name": "test",   "command": "cargo test",                     "weight": 30 },
      { "name": "fmt",    "command": "cargo fmt -- --check",           "weight": 20, "required": false }
    ],
    "checks": [
      { "name": "fmt", "command": "cargo fmt -- --check", "fix": "cargo fmt", "pattern": "*.rs" }
    ]
  }
}
```

`cargo clippy` is too slow for per-file checks. Use it as a gate only.

### Minimal (test-only)

When you only have a test command and nothing else:

```json
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [
      { "name": "test", "command": "npm test", "weight": 100 }
    ]
  }
}
```

---

## 7. How the Loop Works

Four hooks, one kernel, one or more packages.

### SessionStart

Fires once when a new Claude Code session starts. The kernel initializes its state file (`.claude/state/kernel.json`) and dispatches to each active package's `session-start.sh`. The quality-gates package uses this to print the gate list and inject context.

Everything written to stdout during SessionStart becomes part of Claude's initial context.

### PreToolUse

Fires before every tool invocation (Edit, Write, Bash, etc.). The kernel checks the iteration budget. If exhausted, it blocks the tool with exit code 2. Otherwise, it tracks the file being edited and injects the pass counter.

The quality-gates package filters to Edit, MultiEdit, and Write tools only (via the `matchers` field in its manifest). Other tool types pass through untouched.

### PostToolUse

Fires after every tool invocation. The quality-gates package runs configured checks on the edited file and reports issues to stdout, which Claude sees immediately. Auto-fix commands run silently.

### Stop

The main loop driver. Fires when Claude finishes a response.

The kernel checks two circuit breakers first: the `stop_hook_active` re-entry guard and the iteration budget. If neither trips, it dispatches to package stop handlers in two phases.

**Core phase** runs first. The quality-gates package evaluates every configured gate, records scores, and votes continue (exit 2) or done (exit 0) based on whether all required gates passed.

**Post phase** runs only if all core packages voted done. This is where you put secondary checks (like a security audit) that should not run until the primary quality bar is met.

If any package in either phase votes continue, the kernel increments the iteration counter and exits 2. Claude gets another turn.

### State Files

The kernel writes to `.claude/state/kernel.json`:

```json
{
  "iteration": 3,
  "max_iterations": 10,
  "status": "running",
  "files_touched": ["src/api.ts", "src/api.test.ts"]
}
```

Each package writes to `.claude/state/<package-name>/state.json`. The quality-gates package tracks scores, per-gate results, and a satisfaction flag.

State is gitignored and resets on each new session.

---

## 8. Writing Custom Packages

A package is a directory with a `package.json` manifest and handler scripts. The kernel discovers packages by name from `looper.json` and looks for handler scripts by convention.

### Minimal Package

```
my-package/
  package.json
  hooks/
    stop.sh
```

**package.json:**

```json
{
  "name": "my-package",
  "version": "1.0.0",
  "description": "Verify documentation is up to date"
}
```

**hooks/stop.sh:**

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

Place the package in any of the search paths:

1. `$CLAUDE_PROJECT_DIR/.claude/packages/my-package/` for a single project
2. `$HOME/.claude/packages/my-package/` for all your projects
3. Inside the plugin's `packages/` directory to bundle it

Add it to your config:

```json
{
  "packages": ["quality-gates", "my-package"],
  "my-package": {
    "verify_command": "bash scripts/check-docs.sh"
  }
}
```

### Available Handlers

| File | Event | When It Runs |
|------|-------|--------------|
| `hooks/session-start.sh` | SessionStart | Once per new session |
| `hooks/pre-tool-use.sh` | PreToolUse | Before each tool invocation |
| `hooks/post-tool-use.sh` | PostToolUse | After each tool invocation |
| `hooks/stop.sh` | Stop | When Claude finishes a response |

Missing handlers are fine. If your package only needs a stop handler, only create `hooks/stop.sh`.

### Handler Protocol

Handlers receive hook input JSON on stdin and environment variables from the kernel.

**Exit codes:**

- `0` from a stop handler means "I am satisfied, the loop can end"
- `2` from a stop handler means "keep going, I need more work"
- `0` from a pre-tool-use handler means "allow the tool"
- `2` from a pre-tool-use handler means "block the tool"

**Output:**

- SessionStart: stdout becomes Claude's context
- PostToolUse: stdout becomes Claude's context
- Stop: stderr becomes Claude's context (stdout is ignored)
- PreToolUse: return JSON with `hookSpecificOutput.additionalContext`

### Environment Variables

Every handler receives:

| Variable | Contents |
|----------|----------|
| `LOOPER_PKG_NAME` | Package name |
| `LOOPER_PKG_DIR` | Absolute path to the package directory |
| `LOOPER_PKG_STATE` | Absolute path to this package's state directory |
| `LOOPER_STATE_DIR` | Shared state root |
| `LOOPER_HOOKS_DIR` | Kernel directory (where pkg-utils.sh lives) |
| `LOOPER_CONFIG` | Absolute path to looper.json |
| `LOOPER_ITERATION` | Current iteration number (0-indexed) |
| `LOOPER_MAX_ITERATIONS` | Budget cap |
| `CLAUDE_PROJECT_DIR` | Project root |

### State Utilities

Source `$LOOPER_HOOKS_DIR/pkg-utils.sh` in your handlers to get these functions:

```bash
# Read kernel state (read-only)
kernel_read '.iteration'
kernel_read '.files_touched[]'

# Read/write your own package state
pkg_state_read '.scores'
pkg_state_write '.last_score' '85'
pkg_state_append '.scores' '85'

# Read another package's state (read-only)
pkg_read "quality-gates" '.satisfied'

# Read your config from looper.json
pkg_config '.verify_command'

# Pattern matching
file_matches_pattern "src/app.ts" "*.ts,*.tsx"
files_match_patterns '["src/**/*.ts"]'

# Timeout wrapper (uses timeout or gtimeout)
run_with_timeout 30 bash -c "npm test"
```

### Manifest Options

```json
{
  "name": "my-package",
  "version": "1.0.0",
  "description": "What this package does",
  "matchers": {
    "PreToolUse": "Edit|MultiEdit|Write",
    "PostToolUse": "Edit|MultiEdit|Write"
  },
  "phase": "core"
}
```

- **matchers**: regex patterns filtering which tools trigger PreToolUse and PostToolUse handlers. Without matchers, your handlers fire on every tool invocation.
- **phase**: `"core"` (default) or `"post"`. Post-phase stop handlers only run after all core packages are satisfied.

---

## 9. Multi-Package Composition

You can run multiple packages in the same loop. Each package evaluates independently and votes on whether to continue.

The bundled `scope-guard` package is a natural companion to `quality-gates`. It prevents Claude from editing files outside a declared scope:

```json
{
  "max_iterations": 15,
  "packages": ["quality-gates", "scope-guard"],
  "quality-gates": {
    "gates": [...]
  },
  "scope-guard": {
    "blocked": ["package-lock.json", ".env*"],
    "allowed": ["src/**/*", "tests/**/*"]
  }
}
```

`blocked` patterns are enforced immediately via PreToolUse: Claude's edit is denied before it happens. `allowed` patterns are checked at the Stop hook: if Claude edited files outside the allowed set, the loop continues until the violation is resolved.

Rules:

- All packages must vote done for the loop to end.
- Any single package voting continue forces another iteration.
- Packages run in array order within the same phase.
- Core-phase packages run first. If any core package votes continue, post-phase packages are skipped entirely.

The two-phase model prevents wasted work. scope-guard runs in the `post` phase, so it only evaluates after quality-gates passes. There is no point checking scope compliance if the code does not compile.

### Overriding a Bundled Package

The kernel resolves packages by searching three paths in order:

1. `$CLAUDE_PROJECT_DIR/.claude/packages/<name>/`
2. `$HOME/.claude/packages/<name>/`
3. `$CLAUDE_PLUGIN_ROOT/packages/<name>/` (bundled)

To customize the bundled quality-gates package for one project, copy it:

```bash
mkdir -p .claude/packages
cp -r "$(claude plugin root looper)/packages/quality-gates" .claude/packages/
```

Edit the local copy. The kernel will use it instead of the bundled version.

---

## 10. Baseline-Aware Gating

Most real codebases have pre-existing issues: a flaky test, a lint rule nobody fixed, a type error in a file Claude will never touch. Without baseline awareness, Claude spends iteration budget trying to fix problems it did not create.

Enable baseline capture to solve this:

```json
{
  "quality-gates": {
    "baseline": true,
    "gates": [...]
  }
}
```

When `baseline` is `true`, all gate commands run at SessionStart before Claude makes any changes. The pass/fail result per gate is stored as a snapshot. On each Stop evaluation, the stop handler compares current results against the baseline:

- A gate that was already failing at baseline and is still failing is marked `~` (pre-existing). It does not force another iteration and does not cost budget.
- A gate that was passing at baseline but now fails is marked `x` (introduced). Claude must fix it.
- When no baseline is captured (the default), all failures count normally.

Claude's session context includes a "Pre-Existing Failures" section when baseline failures are detected, so it knows which gates to ignore from the start.

The Stop report includes a legend when baseline is active:

```
v = pass  x = failed (you)  ~ = pre-existing  o = skipped
```

Pre-existing failures appear in a separate section labeled "not blocking" so Claude has context but does not try to fix them.

An optional `baseline_timeout` (default 60 seconds) controls the per-gate time limit during baseline capture. Set it lower if your gates are fast and you want SessionStart to complete quickly:

```json
{
  "quality-gates": {
    "baseline": true,
    "baseline_timeout": 30,
    "gates": [...]
  }
}
```

---

## 11. Troubleshooting

### Budget exhausted before gates pass

You will see: `IMPROVEMENT LOOP COMPLETE - BUDGET REACHED`.

Check `.claude/state/kernel.json` for the score history and files touched. Common causes:

- The test suite has pre-existing failures unrelated to Claude's work. Enable `"baseline": true` to let Claude ignore these, or fix them before starting the session.
- The task is too broad. Break it into smaller pieces.
- A gate command is flaky (passes sometimes, fails sometimes). Add `required: false` or fix the flakiness.

Increase `max_iterations` if the task genuinely needs more passes.

### A gate keeps failing with the same error

Claude might be stuck in a loop, applying the same fix and getting the same failure. This happens when the error message is ambiguous or when Claude cannot see enough context.

Add a `context` line explaining the fix:

```json
{
  "context": [
    "The mypy error on line 42 is caused by a missing type stub. Install it with: pip install types-requests"
  ]
}
```

Or increase the failure output. The stop handler shows the last 20 lines of gate output. If the relevant error is above that window, the gate command itself might need adjustment (pipe through `tail -50` or filter for the relevant lines).

### Post-edit checks are too slow

Checks run on every file edit. If a check takes more than a second, it slows down Claude's editing flow.

Move slow checks from `checks` (per-file, PostToolUse) to `gates` (per-stop-evaluation, Stop). Gates run less frequently and have a configurable timeout.

### The loop does not start

Verify the plugin is enabled:

```bash
claude plugin list
```

Check that `jq` is installed:

```bash
jq --version
```

If the session starts without the "Improvement Loop Active" message, the hooks are not firing. Verify with:

```bash
claude plugin info looper
```

### State is stale from a previous session

State resets on every SessionStart. If you see unexpected state, check that a new session is starting properly. The `"matcher": "new"` on the SessionStart hook ensures it only fires on new sessions.

To manually reset state:

```bash
rm -rf .claude/state/
```

The kernel recreates the directory on the next session.

---

## 12. Design Decisions

**Why shell scripts?** Claude Code hooks are command-based. Shell is the natural fit: no runtime dependencies, no build step, no package manager. The entire kernel is two files totaling ~500 lines.

**Why jq for state?** JSON state files are human-readable, debuggable, and queryable. `jq` is the standard tool for JSON manipulation in shell. The overhead per call is ~5ms, negligible compared to the gate commands themselves.

**Why per-project config?** Every project has different tools, different test commands, different thresholds. A global config would need conditional logic for every project. A per-project `looper.json` is simple and explicit.

**Why two-phase stop?** To prevent wasted work. Running a 30-second security scan while the code has type errors is pointless. Core gates enforce the basics; post-phase gates add polish.

**Why exit code 2 instead of 1?** Exit code 1 is ambiguous (could be a script error). Exit code 2 is an intentional "continue" signal. The kernel only treats 2 as "keep the loop going." Any other non-zero exit from a hook is treated as a script failure, not a loop signal.

---

## Quick Reference

```
Install*:    claude plugin install looper@claude-plugins-official
Local dev:   claude --plugin-dir /path/to/looper
Configure:   /looper:looper-config
Disable:     claude plugin disable looper@claude-plugins-official
Remove:      claude plugin uninstall looper@claude-plugins-official

Config file: .claude/looper.json
State dir:   .claude/state/       (gitignored, resets per session)

Gate exits:  0 = pass,  2 = fail (continue loop)
Hook exits:  0 = allow, 2 = block/continue

Symbols:     v = pass,  x = fail,  o = skipped
```

`*` once listed in the official marketplace
