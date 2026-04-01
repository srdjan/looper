# User Guide

## What This Project Does

The improvement loop uses Claude Code hooks to keep a session alive after Claude thinks it is done. Instead of stopping after one attempt, the Stop hook evaluates the current result, feeds failures back into the same session, and gives Claude another turn until one of these happens:

- all gates reach a perfect score of `100/100`
- the loop hits the iteration budget
- Claude re-enters the Stop hook on the same turn and the breaker allows the session to end

The shipped hooks live in [`.claude/hooks/session-start.sh`](/Users/srdjans/Code/improvement-loop/.claude/hooks/session-start.sh), [`.claude/hooks/pre-edit-guard.sh`](/Users/srdjans/Code/improvement-loop/.claude/hooks/pre-edit-guard.sh), [`.claude/hooks/post-edit-check.sh`](/Users/srdjans/Code/improvement-loop/.claude/hooks/post-edit-check.sh), and [`.claude/hooks/stop-improve.sh`](/Users/srdjans/Code/improvement-loop/.claude/hooks/stop-improve.sh).

## Prerequisites

- `jq`
- `node` and `npm`
- Claude Code installed and available as `claude`

Useful checks:

```bash
jq --version
node --version
npm --version
claude --version
```

Notes based on the current implementation:

- The installer hard-fails if `jq` is missing.
- The hooks call `npx`, `npm`, and `node`, so Node.js must be available in the project environment.
- Coverage partial scoring uses `awk`, which is available on all POSIX systems.

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

What the installer actually does:

- creates `.claude/hooks/` and `.claude/state/`
- copies six scripts into `.claude/hooks/`
- makes those scripts executable
- creates or merges `.claude/settings.json`
- backs up an existing settings file to `.claude/settings.json.bak`
- adds `.claude/state/` and `.claude/settings.json.bak` to `.gitignore`

The merged hook wiring comes from [`.claude/settings.json`](/Users/srdjans/Code/improvement-loop/.claude/settings.json).

### Option 2: Manual setup

If you do not want to run the installer, copy these files into the target project:

- `.claude/hooks/hook-manifest.sh`
- `.claude/hooks/state-utils.sh`
- `.claude/hooks/session-start.sh`
- `.claude/hooks/pre-edit-guard.sh`
- `.claude/hooks/post-edit-check.sh`
- `.claude/hooks/stop-improve.sh`
- `.claude/settings.json`

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

Also add this to `.gitignore`:

```gitignore
.claude/state/
.claude/settings.json.bak
```

## Quick Start

1. Install the hooks into your project.
2. Start Claude Code in that project.
3. Give Claude a task that changes code.

Example:

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
- when Claude tries to finish, `Stop` runs the quality suite
- if the score is below `100`, Claude gets another turn in the same session

## Understanding the Feedback Cycle

### `SessionStart`

Implemented in [`.claude/hooks/session-start.sh`](/Users/srdjans/Code/improvement-loop/.claude/hooks/session-start.sh).

Runs once at the start of a new session and does two things:

- initializes fresh loop state by calling `init_state`
- injects context into Claude through `stdout`

The injected context includes:

- the loop rules
- the default gate commands
- the max pass budget
- current git branch
- Node version
- package scripts from `package.json`
- up to 20 discovered `*.test.ts` or `*.spec.ts` files

### `PreToolUse`

Implemented in [`.claude/hooks/pre-edit-guard.sh`](/Users/srdjans/Code/improvement-loop/.claude/hooks/pre-edit-guard.sh).

Runs before `Edit`, `MultiEdit`, and `Write`.

Responsibilities:

- blocks further edits once `iteration >= MAX_ITERATIONS`
- appends the edited file to `files_touched` if it is new
- injects the current pass into Claude through `additionalContext`

Example injected context:

```text
Improvement pass 3/10. Editing: src/api/avatar.ts
```

If the budget is exhausted, the hook exits `2` and tells Claude to summarize what was accomplished.

### `PostToolUse`

Implemented in [`.claude/hooks/post-edit-check.sh`](/Users/srdjans/Code/improvement-loop/.claude/hooks/post-edit-check.sh).

Runs after `Edit`, `MultiEdit`, and `Write`, but only performs checks for `.ts` and `.tsx` files.

Checks performed:

- `prettier --check`, followed by a silent `prettier --write` auto-fix when available
- single-file `eslint`
- `tsc --noEmit --pretty false "$FILE"` syntax/type feedback

This hook writes feedback to `stdout`, so Claude sees fast local issues before the full Stop evaluation.

### `Stop`

Implemented in [`.claude/hooks/stop-improve.sh`](/Users/srdjans/Code/improvement-loop/.claude/hooks/stop-improve.sh).

Runs when Claude finishes a response. This is the loop driver.

Order of operations:

1. checks the `stop_hook_active` breaker
2. checks whether the iteration budget is already exhausted
3. runs the four quality gates
4. computes a score out of `100`
5. records the score in state
6. either exits `0` to stop or exits `2` to continue

## Interpreting Loop Output

The Stop hook prints its status to `stderr`. Typical output contains these sections:

- current pass, for example `Running typecheck...`
- a score block, for example `Score: 80/100`
- history, for example `History: [40,60,80]`
- gate-by-gate results
- targeted failures to fix next

Meaning of the symbols in the current implementation:

- `✓` gate passed and received full points
- `✗` gate failed and received `0` points
- `○` gate was skipped
- `△` coverage was below target and received partial points

Example gate block:

```text
✓ typecheck: pass (30/30)
✗ lint: 3 errors (0/20)
✓ test: pass (30/30)
△ coverage: 72% — need 80%+ (18/20)
```

How pass numbers work:

- state starts at `iteration = 0`
- the first Stop evaluation prints as pass `1/10`
- on an imperfect run, the Stop hook increments `iteration`
- `PreToolUse` then shows the next edit pass as `Improvement pass 1/10`, `2/10`, and so on

This means the human-facing pass count is effectively one-based during Stop output, while the stored state counter is zero-based before increment.

## Configuration Options

There is no dedicated config file yet. The current customization points are shell constants and commands in the installed hook scripts.

### Max iterations

Edit the installed copy of [`.claude/hooks/state-utils.sh`](/Users/srdjans/Code/improvement-loop/.claude/hooks/state-utils.sh):

```bash
MAX_ITERATIONS=10
```

Related implementation detail:

- `init_state` also writes `"max_iterations": 10` as a JSON literal
- `session-start.sh` prints `max 10 passes` and `Budget: 10 passes total` as fixed text

If you change the budget, update those hard-coded `10` values too so the state file and Claude’s startup context stay consistent.

### Gate weights

Edit the scoring logic in the installed copy of [`.claude/hooks/stop-improve.sh`](/Users/srdjans/Code/improvement-loop/.claude/hooks/stop-improve.sh):

- typecheck: `30`
- lint: `20`
- test: `30`
- coverage: `20`

The loop only stops early when the total score reaches `100`.

### Quality thresholds

Current hard-coded thresholds and commands:

- typecheck: `npx tsc --noEmit --pretty false`
- lint: `npx eslint . --ext .ts,.tsx --format compact`
- test: `npm test -- --reporter=dot`
- coverage target: `80%` line coverage from `coverage/coverage-summary.json`

Practical implications:

- no `tsconfig.json` means typecheck is skipped and full typecheck points are awarded
- missing `eslint` means lint is skipped and full lint points are awarded
- missing `package.json` test script means tests are skipped with `0/30` and a failure message asking for tests
- missing coverage summary means coverage gets `0/20`

## Troubleshooting

### Budget exhausted

Symptoms:

- `Budget exhausted: 10 iterations reached. No further edits allowed.`
- final Stop output says `IMPROVEMENT LOOP COMPLETE — BUDGET REACHED`

What to do:

- inspect `.claude/state/loop-state.json` for score history and touched files
- tighten the task scope and start a fresh session
- increase `MAX_ITERATIONS` if the project genuinely needs a larger budget

### Failing gates

Typecheck failures:

- look for the `── TypeCheck Failures ──` section from the Stop hook
- fix those errors first, because typecheck is worth `30` points

Lint failures:

- check the `── Lint Failures ──` block
- `PostToolUse` may already have shown the first few lint issues after each edit

Test failures:

- the Stop hook prints the last 20 lines of test output
- the current implementation treats common failure markers such as `FAIL`, `✗`, and `failed` as a failure signal

Coverage failures:

- generate `coverage/coverage-summary.json`
- raise total line coverage to at least `80%`
- use the uncovered-file list in the Stop feedback when present

### Hook errors

Common causes:

- `jq` not installed
- `node`, `npm`, or `npx` not installed
- hook scripts copied without execute permission
- `.claude/settings.json` missing the hook entries

Checks:

```bash
ls -l .claude/hooks
jq empty .claude/settings.json
cat .claude/state/loop-state.json
```

If a hook appears not to run, compare the project’s installed settings against [`.claude/settings.json`](/Users/srdjans/Code/improvement-loop/.claude/settings.json).

## Uninstallation

Remove the loop from the current project:

```bash
./uninstall.sh
```

Remove it from another project:

```bash
./uninstall.sh /path/to/your/project
```

The uninstaller in [`uninstall.sh`](/Users/srdjans/Code/improvement-loop/uninstall.sh) does the following:

- removes the six hook scripts from `.claude/hooks/`
- deletes `.claude/state/`
- removes matching hook commands from `.claude/settings.json`
- restores `.claude/settings.json.bak` if the resulting `hooks` object becomes empty

Recommended verification:

```bash
test ! -d .claude/state
test ! -f .claude/hooks/stop-improve.sh
jq '.' .claude/settings.json
```
