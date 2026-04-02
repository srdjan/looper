# User Guide

## What This Project Does

The improvement loop uses Claude Code hooks to keep a session alive after Claude thinks it is done. Instead of stopping after one attempt, the Stop hook evaluates the current result, feeds failures back into the same session, and gives Claude another turn until one of these happens:

- all required gates pass
- the loop hits the iteration budget
- Claude re-enters the Stop hook on the same turn and the breaker allows the session to end

The shipped hooks live in `.claude/hooks/`. Gate commands and loop budget are configured in `.claude/looper.json`.

## Prerequisites

- `jq` (the installer auto-installs it on macOS/apt systems)
- Claude Code installed and available as `claude`
- Whatever tools your gates need (the defaults use `node` and `npm`)

Useful checks:

```bash
jq --version
claude --version
```

## Installation

### Option 1: Use `install.sh`

Install into the current project:

```bash
./install.sh
```

Install into another project:

```bash
./install.sh /path/to/your/project
```

What the installer does:

- creates `.claude/hooks/` and `.claude/state/`
- copies seven hook scripts into `.claude/hooks/` and makes them executable
- copies `.claude/looper.json` (skipped if already present)
- creates or merges `.claude/settings.json`
- backs up an existing settings file to `.claude/settings.json.bak`
- adds `.claude/state/` and `.claude/settings.json.bak` to `.gitignore`

### Option 2: Manual setup

Copy these files into the target project:

```
.claude/hooks/hook-manifest.sh
.claude/hooks/state-utils.sh
.claude/hooks/session-start.sh
.claude/hooks/pre-edit-guard.sh
.claude/hooks/post-edit-check.sh
.claude/hooks/check-coverage.sh
.claude/hooks/stop-improve.sh
.claude/looper.json
.claude/settings.json
```

Then:

```bash
mkdir -p .claude/hooks .claude/state
chmod +x .claude/hooks/*.sh
```

If the project already has a `.claude/settings.json`, merge in these hook entries:

- `SessionStart` with matcher `new`
- `PreToolUse` with matcher `Edit|MultiEdit|Write`
- `PostToolUse` with matcher `Edit|MultiEdit|Write`
- `Stop`

Also add to `.gitignore`:

```gitignore
.claude/state/
.claude/settings.json.bak
```

## Quick Start

1. Install the hooks into your project.
2. Start Claude Code in that project.
3. Give Claude a task that changes code.

```bash
cd /path/to/your/project
claude
```

Then prompt Claude with something concrete, for example:

```text
Implement a user avatar upload endpoint with validation.
```

What happens next:

- `SessionStart` initializes `.claude/state/loop-state.json`
- each file edit passes through `PreToolUse` and `PostToolUse`
- when Claude tries to finish, `Stop` runs the quality gates
- if the score is below the total, Claude gets another turn in the same session

## Understanding the Feedback Cycle

### `SessionStart`

Runs once at the start of a new session. Initializes fresh loop state and injects context into Claude through `stdout`.

The injected context includes:

- the loop rules and max pass budget
- the configured gate list with weights, commands, and required/optional labels
- custom context lines from the `context` array in `looper.json` (if configured)
- project discovery output: either custom commands from the `discover` config, or the defaults (git branch, node version, package scripts, test files)

### `PreToolUse`

Runs before `Edit`, `MultiEdit`, and `Write`.

- blocks further edits once `iteration >= MAX_ITERATIONS`
- appends the edited file to `files_touched` if it is new
- injects the current pass into Claude through `additionalContext`

Example injected context:

```text
Improvement pass 3/10. Editing: src/api/avatar.ts
```

If the budget is exhausted, the hook exits `2` and tells Claude to summarize what was accomplished.

### `PostToolUse`

Runs after `Edit`, `MultiEdit`, and `Write`. Checks are configured via the `checks` array in `.claude/looper.json`.

Each check specifies a `command` (with `{file}` placeholder for the edited file path), a `pattern` for matching file types, and an optional `fix` command for auto-correction. Checks with `skip_if_missing` are skipped when the specified file or binary is absent.

If no `checks` config exists, the hook falls back to hardcoded TypeScript checks (prettier, eslint, tsc).

This hook writes feedback to `stdout`, so Claude sees fast local issues before the full Stop evaluation.

### `Stop`

The loop driver. Runs when Claude finishes a response.

Order of operations:

1. check the `stop_hook_active` breaker
2. check whether the iteration budget is already exhausted
3. load gate config from `.claude/looper.json`
4. run each gate command, pass if exit 0
5. record score and per-gate pass/fail in state
6. exit `0` to stop or exit `2` to continue

## Interpreting Loop Output

The Stop hook prints its status to `stderr`. Typical output contains these sections:

- current gate running, for example `Running typecheck...`
- a score block, for example `Score: 80/100`
- history, for example `History: [40,60,80]`
- gate-by-gate results
- targeted failures to fix next

Symbols in the gate results:

- `✓` gate passed and received full points
- `✗` gate failed and received `0` points
- `○` gate was skipped (full points awarded) - reasons include: `skip_if_missing` file absent, `run_when` patterns not matching any touched files, or gate disabled

Example gate block:

```text
  ✓ typecheck: skipped — tsconfig.json not found (30/30)
  ✗ lint: failed (0/20)
  ✓ test: pass (30/30)
  ✗ coverage: failed (0/20)
```

How pass numbers work:

- state starts at `iteration = 0`
- the first Stop evaluation prints as pass `1/10`
- on an imperfect run, the Stop hook increments `iteration`
- `PreToolUse` then shows the next edit pass as `Improvement pass 1/10`, `2/10`, and so on

## Configuration

All configuration lives in `.claude/looper.json`. No hook scripts need to be modified.

### Max iterations

```json
{
  "max_iterations": 10,
  "gates": [ ... ]
}
```

### Gate commands and weights

```json
{
  "max_iterations": 10,
  "gates": [
    { "name": "typecheck", "command": "npx tsc --noEmit --pretty false", "weight": 30, "skip_if_missing": "tsconfig.json" },
    { "name": "lint",      "command": "npx eslint .",     "weight": 20, "skip_if_missing": "node_modules/.bin/eslint" },
    { "name": "test",      "command": "npm test",                        "weight": 30 },
    { "name": "coverage",  "command": "$LOOPER_HOOKS_DIR/check-coverage.sh", "weight": 20, "required": false }
  ]
}
```

The loop completes when all required gates pass. Optional gate fields:

- `required` (default `true`): set `false` for non-blocking gates
- `run_when`: array of glob patterns; gate skipped if no `files_touched` match
- `timeout` (default 300): seconds before the command is killed
- `enabled` (default `true`): set `false` to disable without removing

### Post-edit checks

Configure fast per-file checks that run after each edit:

```json
{
  "checks": [
    { "name": "format",    "command": "npx prettier --check {file}", "fix": "npx prettier --write {file}", "pattern": "*.ts,*.tsx" },
    { "name": "lint",      "command": "npx eslint {file}",                                                  "pattern": "*.ts,*.tsx" },
    { "name": "typecheck", "command": "npx tsc --noEmit --pretty false",                                    "pattern": "*.ts,*.tsx" }
  ]
}
```

Use `{file}` as a placeholder for the edited file path. The `fix` field is optional and runs silently after a failing check.

### Context and coaching

Inject custom context into Claude's session and customize urgency messaging:

```json
{
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
```

### Non-TypeScript projects

Replace the gate commands with whatever your project uses. The hooks only care that the gate command exits `0` on success.

Python example:

```json
{
  "max_iterations": 10,
  "gates": [
    { "name": "typecheck", "command": "mypy src/",    "weight": 30, "skip_if_missing": "mypy.ini" },
    { "name": "lint",      "command": "ruff check .", "weight": 20, "skip_if_missing": "ruff.toml" },
    { "name": "test",      "command": "pytest -q",    "weight": 50 }
  ]
}
```

Go example:

```json
{
  "max_iterations": 10,
  "gates": [
    { "name": "build", "command": "go build ./...", "weight": 30 },
    { "name": "vet",   "command": "go vet ./...",   "weight": 20 },
    { "name": "test",  "command": "go test ./...",  "weight": 50 }
  ]
}
```

Gate weights can be any positive integers. The loop stops when all required gates pass.

### Default coverage gate behavior

`.claude/hooks/check-coverage.sh` reads `coverage/coverage-summary.json` and exits non-zero if line coverage is below 80%. The `skip_if_missing` field is not set for this gate by default, so a missing coverage file counts as a failure. Run tests with `--coverage` to generate it. Replace the command with any tool that exits `0` at your coverage threshold.

## Troubleshooting

### Budget exhausted

Symptoms:

- `Budget exhausted: N iterations reached. No further edits allowed.`
- final Stop output says `IMPROVEMENT LOOP COMPLETE — BUDGET REACHED`

What to do:

- inspect `.claude/state/loop-state.json` for score history and touched files
- tighten the task scope and start a fresh session
- increase `max_iterations` in `.claude/looper.json` if the project needs a larger budget

### Failing gates

The Stop hook prints a failure block for each failing gate with the last 20 lines of its output:

```text
── gatename ──
<command output>
```

For the default TypeScript gates:

- typecheck: fix TypeScript errors first (worth the most points with the default weights)
- lint: `PostToolUse` may have already shown lint issues after each edit
- test: the last 20 lines of `npm test` output are in the failure block
- coverage: run `npm test -- --coverage` to generate `coverage/coverage-summary.json`, then get total line coverage to 80%

### Hook errors

Common causes:

- `jq` not installed
- hook scripts copied without execute permission
- `.claude/settings.json` missing the hook entries

Checks:

```bash
ls -l .claude/hooks
jq empty .claude/settings.json
cat .claude/state/loop-state.json
```

## Uninstallation

Remove the loop from the current project:

```bash
./uninstall.sh
```

Remove it from another project:

```bash
./uninstall.sh /path/to/your/project
```

The uninstaller removes the hook scripts from `.claude/hooks/`, deletes `.claude/state/`, removes matching hook commands from `.claude/settings.json`, and restores `.claude/settings.json.bak` if the resulting `hooks` object becomes empty.

Verification:

```bash
test ! -d .claude/state
test ! -f .claude/hooks/stop-improve.sh
jq '.' .claude/settings.json
```
