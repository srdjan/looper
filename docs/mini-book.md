# Looper: A Native Improvement Loop for Claude Code

A practitioner's guide to native agentic quality enforcement inside Claude Code.

---

## Chapter 1: The Problem Nobody Talks About

Claude Code writes good code. It handles architecture decisions and complex refactors that would take a human developer hours. But there is a gap between "code that looks right" and "code that works."

You prompt Claude to implement a user registration endpoint. Claude writes the handler, the validation, the tests. You run the tests. Two fail. You copy the error output, paste it back into the conversation, and ask Claude to fix it. Claude fixes the test assertions but introduces a type error. You run the type checker, copy that output, paste it back. Claude fixes the type but breaks the import. Three rounds later, you are doing Claude's QA by hand.

This is the copy-paste-fix loop. Every Claude Code user has lived it. The pattern is always the same: Claude generates code, you run your tools, you relay the results, Claude adjusts, you run the tools again. You become a human middleware layer between Claude and your own development toolchain.

The type checker, linter, and test runner are all installed and configured. Claude cannot see their output. It writes code into a void and hopes for the best. When it misses, you close the loop by hand.

Looper closes it automatically.

---

## Chapter 2: What Looper Does

Looper is a Claude Code plugin that intercepts the moment Claude finishes working and asks: did the code pass your quality checks? If the answer is no, Claude gets another turn with the failure output as feedback. This repeats until all required gates pass or an iteration budget is exhausted.

That native part matters. Many teams try to bolt an improvement loop onto Claude from the outside with shell wrappers, copied transcripts, cron-style watchers, or a second process that re-runs tools after the model stops. Those approaches can be useful, but they sit beside Claude Code, not inside it. They do not share the same hook lifecycle. They do not get first-class access to SessionStart, PreToolUse, PostToolUse, and Stop. They cannot block an edit before it happens. They usually depend on log scraping, transcript parsing, or extra prompting discipline.

Looper takes the opposite route. It runs where the work is already happening, inside Claude Code's native plugin and hook model. The loop is not an external supervisor peeking through a window. It is part of the session itself. Claude sees the loop rules at session start, gets per-edit feedback while working, and receives stop-time gate failures through the same native control path that Claude Code already exposes. That is the novelty in one sentence: Looper is not an external harness around Claude Code. It is a native control loop inside Claude Code.

The effect is that Claude self-corrects. You ask for a feature, and the delivered code compiles, passes lint, and has green tests, because Claude kept iterating until those things were true.

Looper uses four hooks that Claude Code exposes to plugins:

SessionStart fires once when a new conversation begins. Looper initializes its state, detects your tech stack, and tells Claude about the active quality gates, their weights, and the iteration budget.

PreToolUse fires before every tool invocation. Looper tracks which files Claude is editing, injects the current pass counter ("Pass 3/10. Editing: src/user.ts"), and enforces the iteration budget by blocking edits when the budget is exhausted.

PostToolUse fires after every tool invocation. When Claude edits a file, Looper runs per-file checks like formatting and linting on that file. If prettier finds an issue, Claude knows within seconds, not at the end of the session.

Stop fires when Claude finishes its response and tries to stop. This is where the loop lives. Looper runs every quality gate. If all required gates pass, the loop ends. If any required gate fails, Looper sends the failure output back to Claude and increments the iteration counter. Claude reads the failures, fixes them, and the cycle repeats.

The system has two layers. A minimal kernel handles loop mechanics: state, dispatch, circuit breakers. Pluggable packages handle domain logic: what to check, how to score, when to stop. The bundled quality-gates package implements the classic behavior, but the architecture supports any kind of improvement cycle.

---

## Chapter 3: Getting Started

Install the plugin:

```bash
claude plugin install looper@claude-plugins-official
```

You need `jq` on your system. On macOS that is `brew install jq`. On Debian or Ubuntu, `apt install jq`. If you enable SDK-authored packages such as `scope-guard`, you also need the runtime they declare in their package manifest. Today that usually means `deno`.

Start Claude Code in any project:

```bash
cd your-project
claude
```

On the first session, Looper detects your tech stack by checking for marker files in the project root. It looks for `Cargo.toml` (Rust), `go.mod` (Go), `pyproject.toml` or `requirements.txt` (Python), `deno.json` (Deno), `tsconfig.json` with or without `biome.json` (TypeScript). Based on what it finds, it writes a `.claude/looper.json` with the matching preset configuration.

No manual setup required. If you have a TypeScript project with ESLint and Jest, Looper configures gates for type checking, linting, testing, and coverage. If you have a Rust project, it configures cargo check, clippy, cargo test, and cargo fmt. Detection is fast (file-existence checks, no parsing) and the presets are validated against the actual tool commands each stack uses.

Prompt Claude with something that changes code:

```
add input validation to the user registration endpoint
```

Here is what happens behind the scenes. SessionStart fires. Claude sees the gate list, the weights, the budget. Claude works. Each file edit triggers per-file checks. Claude finishes and tries to stop. The Stop hook runs typecheck, lint, test. If something fails, Claude gets the output: "typecheck failed on line 42: Cannot assign type string to number." Claude reads it, fixes it, tries to stop again. The loop continues until everything passes or the budget runs out.

You did not paste a single error message. You did not run a single command. Looper handled the feedback loop that you used to do manually.

---

## Chapter 4: Configuration

Everything lives in `.claude/looper.json`. One file per project, version-controlled, human-readable. The structure has two levels: kernel settings that control the loop itself, and package settings that control what each package does.

```json
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [
      { "name": "typecheck", "command": "npx tsc --noEmit --pretty false", "weight": 30 },
      { "name": "lint",      "command": "npx eslint .",                     "weight": 20 },
      { "name": "test",      "command": "npm test",                        "weight": 30 },
      { "name": "coverage",  "command": "$LOOPER_PKG_DIR/lib/check-coverage.sh", "weight": 20, "required": false }
    ]
  }
}
```

`max_iterations` is the hard cap on how many passes Claude gets. The default is 10. This is a circuit breaker, not a target. Most tasks converge in 2-4 passes. If you find Claude consistently exhausting the budget, the task is probably too large and should be broken into smaller pieces.

`packages` is an ordered array of active package names. The kernel processes them in declaration order. Most projects use just `["quality-gates"]`, but you can add custom packages for additional improvement cycles.

### Gates

Gates are the core of the quality-gates package. Each gate is a shell command that runs at the Stop hook. Exit 0 means pass. Any other exit code means fail.

Every gate has a name and a command. Beyond that, several optional fields control behavior:

`weight` determines how many points a gate contributes to the score out of 100. The default distribution is 30 for type checking, 20 for linting, 30 for tests, and 20 for coverage or formatting. The score is a progress indicator, not a threshold. The loop continues based on pass/fail of required gates, not the numeric score.

`skip_if_missing` takes a file path. If that file does not exist in the project, the gate is skipped with full points. This makes configurations portable: a gate for ESLint will not fail in a project that does not use ESLint. It gets skipped. The quality-gates presets use this throughout.

`required` defaults to true. A required gate failure forces another iteration. An optional gate (like coverage) provides feedback but does not block completion. If all required gates pass, the loop ends even if optional gates fail.

`run_when` takes an array of glob patterns. The gate only runs if at least one file matching those patterns was touched during the session. This prevents running the type checker when Claude only edited markdown files.

`timeout` sets a per-gate time limit in seconds, defaulting to 300. If a gate exceeds its timeout, it is killed and treated as a failure.

`enabled` can be set to false to disable a gate without removing it from the configuration.

### Post-Edit Checks

Checks are lighter-weight validations that run immediately after each file edit, rather than waiting for the Stop hook. They give Claude fast feedback while it is still working.

```json
{
  "checks": [
    {
      "name": "format",
      "command": "npx prettier --check {file}",
      "fix": "npx prettier --write {file}",
      "pattern": "*.ts,*.tsx",
      "skip_if_missing": "node_modules/.bin/prettier"
    }
  ]
}
```

The `{file}` placeholder is replaced with the path of the file that was just edited. The `pattern` field filters which files trigger the check. The `fix` command, if provided, runs after a failed check to auto-correct formatting issues without bothering Claude about them.

### Context Injection

The `context` array lets you inject project-specific information into Claude's session context:

```json
{
  "context": [
    "This project uses React 19 with Server Components.",
    "Never modify the public API contract in docs/api.md.",
    "Tests use in-memory SQLite, not mocks."
  ]
}
```

These strings are printed to stdout during SessionStart, which means Claude sees them as part of its initial context. Placeholders like `{max_iterations}`, `{gate_count}`, and `{branch}` are substituted automatically.

### Discovery

The `discover` object maps labels to shell commands that run at session start:

```json
{
  "discover": {
    "test_files": "find . -name '*.test.*' | head -20",
    "runtime": "node --version"
  }
}
```

The output is injected into Claude's context under a "Project State" heading. This gives Claude awareness of the project's test structure, runtime versions, and tooling without you having to explain it in every prompt.

### Coaching

The `coaching` object customizes the feedback messages Claude receives when gates fail:

```json
{
  "coaching": {
    "urgency_at": 3,
    "on_failure": "Fix the specific failures only. Do not refactor unrelated code.",
    "on_budget_low": "Only {remaining} passes left. Focus exclusively on failing gates."
  }
}
```

`urgency_at` is the number of remaining passes at which Claude starts receiving budget warnings. `on_failure` replaces the default failure heading. `on_budget_low` replaces the default low-budget message. The `{remaining}` placeholder is substituted with the actual number of passes left.

---

## Chapter 5: Stack Presets

Looper ships with seven preset configurations. When no `.claude/looper.json` exists, the kernel's `detect_stack()` function checks for marker files in priority order and selects the matching preset. The priority order matters for mixed-stack projects: Rust beats TypeScript (catches wasm-pack projects), Go beats TypeScript (catches projects with tooling package.json), Python beats Deno and TypeScript (catches Django projects with frontend assets).

### TypeScript + ESLint + Prettier + Jest

The most common configuration and the historical default. Triggered by `tsconfig.json` without `biome.json`.

Gates: `npx tsc --noEmit` (30 points), `npx eslint .` (20), `npm test` (30), coverage check (20, optional). Checks: prettier format with auto-fix, eslint per-file, tsc per-file. Checks are skipped if their tool is not installed.

### TypeScript + Biome + Vitest

The modern alternative. Triggered by `tsconfig.json` with `biome.json` or `biome.jsonc`.

Biome replaces both ESLint and Prettier with a single tool. The lint gate runs `npx biome check .` instead of eslint, and the test gate runs `npx vitest run` instead of `npm test`. The per-file check uses `npx biome check {file}` with `--write` for auto-fix.

### Deno

Triggered by `deno.json` or `deno.jsonc`. Deno has built-in tools for everything, so no external dependencies are needed.

Gates: `deno check .` (30), `deno lint` (20), `deno test` (30), `deno fmt --check` (20, optional). Checks: deno fmt per-file with auto-fix, deno lint per-file, deno check per-file. No `skip_if_missing` needed because the tools are part of the Deno runtime itself.

### Python + mypy + ruff + pytest

Triggered by `pyproject.toml` or `requirements.txt`.

Gates: `python -m mypy src/` (30), `ruff check .` (20), `python -m pytest -q` (30), `ruff format --check .` (20, optional). Checks: ruff format per-file with auto-fix, ruff check per-file. Both mypy and ruff gates use `skip_if_missing` for their config files, so they skip in projects that do not use them.

### Go

Triggered by `go.mod`. Go's built-in toolchain covers most of the quality surface.

Gates: `go build ./...` (30), `go vet ./...` (20), `go test ./...` (30), `golangci-lint run` (20, optional). The only per-file check is gofmt with auto-fix. Note that `go vet` operates on packages, not individual files, so it runs only as a gate. The gofmt check wraps the command in `test -z` because gofmt always exits 0 even when it finds issues.

### Rust

Triggered by `Cargo.toml`.

Gates: `cargo check` (30), `cargo clippy -- -D warnings` (20), `cargo test` (30), `cargo fmt -- --check` (20, optional). The only per-file check is cargo fmt. Clippy is excluded from per-file checks because it operates on the entire crate and is too slow for per-edit feedback.

### Minimal

The fallback when no recognized stack is detected. A single gate: `npm test` with 100 points. No per-file checks. This covers the case where a project has a test command but Looper cannot identify the specific toolchain.

---

## Chapter 6: What Claude Sees

Understanding the feedback Claude receives at each stage makes it easier to debug configuration issues and write effective coaching messages.

### Session Start

When a new session begins, Claude's context includes:

```
## Improvement Loop Active

You are operating inside an improvement loop (max 10 passes).
Active packages (1): quality-gates

## Quality Gates

Total: 100 points. Pass when all required gates exit 0.

  typecheck   30pts  required   npx tsc --noEmit --pretty false
  lint         20pts  required   npx eslint .
  test        30pts  required   npm test
  coverage    20pts  optional   check-coverage.sh

## Project Context

This project uses React 19 with Server Components.
```

Claude knows the rules before it writes a single line of code. It knows how many passes it has, what gates will be evaluated, which ones are required, and any project-specific context you have configured.

### Per-Edit Feedback

After each file edit, Claude sees immediate feedback:

```
post-edit checks -- src/user.ts
ok src/user.ts: all checks clean
```

Or, if there are issues:

```
post-edit checks -- src/user.ts
  format: 2 issues
  lint: 1 issue
Fix these before moving on.
```

This fast feedback loop means Claude can correct formatting and lint issues as it works, rather than discovering them all at once during the Stop hook.

### Gate Results

When the Stop hook fires, Claude sees a detailed report:

```
QUALITY GATES -- PASS 2/10
Score: 80/100  History: [50, 80]
-------------------------------------------
 v typecheck   30/30
 v lint         20/20
 x test          0/30   FAILED
 o coverage      -/20   skipped
-------------------------------------------
-- test --
FAIL src/user.test.ts
  x should validate email format
    Expected: true
    Received: false
-------------------------------------------
FIX THE SPECIFIC FAILURES. 8 passes remaining.
```

The `v` symbol means pass, `x` means fail, `o` means skipped. The score history shows progress across iterations - Claude can see that it is improving from 50 to 80 and knows exactly what remains. The last 20 lines of failure output from each failed gate are included so Claude has the specific error messages it needs to fix the code.

If Claude is running low on budget, the coaching message changes:

```
Only 2 passes left. Focus exclusively on failing gates.
```

This prevents Claude from spending its remaining budget on refactoring or improvements when it should be focused on making the failing gate pass.

---

## Chapter 7: The Kernel

The kernel is about 400 lines of bash that manage state, dispatch events to packages, and enforce safety constraints. It knows nothing about quality gates, scoring, or specific tools. All domain logic lives in packages.

### State

The kernel maintains a JSON state file at `.claude/state/kernel.json`:

```json
{
  "iteration": 2,
  "max_iterations": 10,
  "status": "running",
  "missing_runtimes": [],
  "files_touched": ["src/user.ts", "src/user.test.ts"]
}
```

`iteration` is zero-indexed and increments each time the Stop hook forces another pass. `status` tracks the loop's lifecycle: `running`, `complete`, `budget_exhausted`, `breaker_tripped`, or `config_blocked`. `missing_runtimes` records configured packages whose declared runtime is not installed. `files_touched` accumulates every file Claude edits during the session, which gates use for conditional execution via `run_when`.

State is managed through jq with atomic writes. Every mutation goes through a temp file that is moved into place, preventing corruption from concurrent access.

### Package Resolution

When the kernel needs to find a package, it searches three locations in order:

1. `.claude/packages/<name>/` in the project directory (project-local override)
2. `$HOME/.claude/packages/<name>/` (user-global)
3. `$CLAUDE_PLUGIN_ROOT/packages/<name>/` (plugin-bundled)

The first match wins. This means you can override the bundled quality-gates package by placing a modified copy in your project's `.claude/packages/` directory. The search chain makes packages customizable at every level without modifying the plugin itself.

### Event Dispatch

For each hook event, the kernel resolves the handler file name by convention: SessionStart maps to `session-start.sh`, PreToolUse to `pre-tool-use.sh`, PostToolUse to `post-tool-use.sh`, Stop to `stop.sh`. If a package does not have a handler for a given event, it is skipped.

Handlers run in a subshell with a set of environment variables that provide access to paths, state, and configuration:

- `LOOPER_PKG_NAME` - the package's name
- `LOOPER_PKG_DIR` - the package's root directory
- `LOOPER_PKG_STATE` - the package's state directory
- `LOOPER_CONFIG` - path to looper.json
- `LOOPER_ITERATION` - current iteration number
- `LOOPER_MAX_ITERATIONS` - the budget cap

### Circuit Breakers

Three safety mechanisms prevent the loop from running forever.

The **re-entry guard** checks a `stop_hook_active` flag in the Stop hook's input. If Claude triggers the Stop hook while a Stop handler is already running (which can happen if Claude's response to a failure is very short), the kernel exits with status `breaker_tripped`. This prevents an infinite recursion where the Stop hook keeps re-triggering itself.

The **iteration budget** is the hard cap set by `max_iterations`. When the iteration counter reaches this limit, the PreToolUse hook blocks all further edits and the Stop hook allows Claude to stop regardless of gate status. The kernel prints a summary of what was accomplished and what remains.

The **two-phase stop model** is a subtler safety mechanism. Packages are classified as either `core` or `post` phase. Core packages always run. Post packages only run if all core packages are satisfied. This prevents wasted work: there is no point running a security audit if the code does not compile. It also prevents a post-phase package from keeping the loop going indefinitely when the core issue is already resolved.

---

## Chapter 8: Building Custom Packages

The quality-gates package is one implementation of the package interface. The kernel dispatches to any package you write. A minimal package needs two files:

```
packages/my-package/
  package.json
  hooks/
    stop.sh
```

The manifest declares the package's identity and behavior:

```json
{
  "name": "my-package",
  "version": "1.0.0",
  "description": "What this package does",
  "runtime": "deno",
  "matchers": {
    "PreToolUse": "Edit|MultiEdit|Write",
    "PostToolUse": "Edit|MultiEdit|Write"
  },
  "phase": "core"
}
```

The optional `runtime` field is a package-level contract. `deno` is supported today. If a configured package declares a runtime that is not present, the kernel fails closed: SessionStart reports a configuration block, PreToolUse blocks edits, and Stop exits cleanly without burning iteration budget. Looper does not silently skip the package because that would hide a broken setup.

The `matchers` object contains regex patterns that filter which tool events reach the package's handlers. If you only care about file edits, match on `Edit|MultiEdit|Write`. If you want to see all tool invocations, omit the matcher for that event.

The `phase` field is either `"core"` or `"post"`. Core packages run first and determine whether post packages run at all.

### Handler Protocol

Handlers communicate through exit codes and standard streams.

For the **Stop** handler, exit 0 means "I am satisfied, the loop can end." Exit 2 means "I am not satisfied, Claude needs another pass." Any output written to stderr is sent to Claude as feedback.

For the **PreToolUse** handler, exit 0 means "allow this tool to execute." Exit 2 means "block this tool." Output should be a JSON object with a `hookSpecificOutput.additionalContext` field that gets injected into Claude's context.

For the **PostToolUse** handler, anything written to stdout becomes part of Claude's context. The exit code does not affect the loop.

For the **SessionStart** handler, anything written to stdout becomes part of Claude's initial context for the session.

### State Utilities

Package handlers can source `pkg-utils.sh` from the kernel directory to access state and configuration helpers:

```bash
source "$LOOPER_HOOKS_DIR/pkg-utils.sh"

# Read kernel state (read-only)
iteration=$(kernel_read '.iteration')

# Read/write own package state
pkg_state_write '.my_counter' '0'
pkg_state_append '.history' '"passed"'
current=$(pkg_state_read '.my_counter')

# Read another package's state (read-only)
other_score=$(pkg_read 'quality-gates' '.scores[-1]')

# Read own config from looper.json
my_setting=$(pkg_config '.some_setting')

# Check if touched files match a pattern
if files_match_patterns '["*.ts", "*.tsx"]'; then
  echo "TypeScript files were edited"
fi

# Run a command with timeout
run_with_timeout 30 npm test
```

These utilities abstract away the jq invocations and file path resolution that would otherwise clutter every handler.

### Example: A Documentation Checker

Here is a complete package that verifies README.md is up to date whenever source files change:

```json
{
  "name": "doc-check",
  "version": "1.0.0",
  "description": "Ensure README reflects source changes",
  "phase": "post"
}
```

```bash
#!/usr/bin/env bash
# hooks/stop.sh
source "$LOOPER_HOOKS_DIR/pkg-utils.sh"

# Only check if source files were touched
if ! files_match_patterns '["src/**/*", "lib/**/*"]'; then
  exit 0
fi

# Check if README mentions all exported functions
exports=$(grep -r "^export " src/ | sed 's/.*export //' | sort)
documented=$(grep -oP '`\K[^`]+(?=`)' README.md | sort)
missing=$(comm -23 <(echo "$exports") <(echo "$documented"))

if [ -z "$missing" ]; then
  echo "doc-check: README covers all exports" >&2
  exit 0
fi

echo "doc-check: README is missing documentation for:" >&2
echo "$missing" >&2
echo "Update README.md to document these exports." >&2
exit 2
```

This package runs in the `post` phase, so it only executes after all core gates (typecheck, lint, test) have passed. It checks whether exported functions are mentioned in the README and forces another iteration if any are missing.

---

## Chapter 9: Multi-Package Composition

Multiple packages compose through a voting system. The kernel collects votes from all package stop handlers and uses a simple rule: all packages must vote "done" (exit 0) for the loop to end. Any single package voting "continue" (exit 2) forces another iteration.

Packages run in declaration order within the same phase. A configuration like this:

```json
{
  "packages": ["quality-gates", "doc-check", "security-audit"]
}
```

would run quality-gates and doc-check (if both are core phase) in that order, then security-audit (if it is post phase) only after both core packages are satisfied.

The two-phase model creates a natural hierarchy. You would not want a documentation checker or security scanner running on code that does not compile. By placing quality-gates in the core phase and secondary packages in the post phase, you ensure that basic correctness is established before higher-level checks begin.

Output from multiple packages is aggregated with package-name headers so Claude can tell which package is providing which feedback:

```
-- [quality-gates] --
Score: 100/100. All required gates pass.

-- [doc-check] --
doc-check: README is missing documentation for:
  createUser
  validateEmail
Update README.md to document these exports.
```

Claude sees both packages' feedback and knows that quality-gates is satisfied but doc-check needs attention.

---

## Chapter 10: Design Decisions

### Why Bash

Claude Code hooks execute shell commands. Looper's kernel could have been written in Python or Node, but that would add a runtime dependency to the dispatcher itself. Bash and jq are available on every machine where Claude Code runs. The kernel is about 400 lines. No build step, no package manager, no transpilation for the control layer. You can read the source and modify it in minutes.

Shell scripts are the natural language for orchestrating other tools. Gate commands and check commands are shell commands. Writing the orchestrator in the same language as the things it orchestrates eliminates an impedance mismatch.

### Why Native Instead of External

This is the architectural bet behind the whole project.

An external loop usually works by wrapping `claude` in another command, scraping output, replaying tool failures through pasted prompts, or running a second process that watches files and decides when to ask the model for another pass. That can work, but it is structurally late. The wrapper only sees what happened after the fact. It cannot participate in Claude Code's own control points.

Looper runs at those control points. SessionStart gives it a place to inject rules and project context before Claude starts. PreToolUse lets it block an edit before a protected file is touched. PostToolUse lets it run light checks while Claude is still in the middle of the task. Stop gives it a native place to decide whether Claude is actually done. That is not a cosmetic difference. It changes what the system can enforce.

Native integration also keeps the mental model smaller. There is one session, one tool invocation stream, one state directory, and one control loop. You do not have to debug a second orchestration layer that shadows Claude Code from the outside.

### Why jq for State

State files are JSON managed through jq. You can `cat .claude/state/kernel.json` and see the loop's status. You can modify state with jq during development. Packages can read each other's state through jq filters. A binary format would be faster but opaque. For a system where the primary debugging tool is "read the file," transparency wins.

### Why Per-Project Configuration

Different projects use different tools. A monorepo might use Biome while a legacy project uses ESLint. A Rust project has no use for prettier. Per-project configuration means each project gets exactly the gates and checks it needs. The configuration file lives in the project directory, checked into version control, so every developer on the team gets the same quality gates.

### Why Two-Phase Stop

Without phases, every package runs on every iteration. If you have a slow security scanner alongside fast quality gates, the scanner runs even when the code does not compile. The two-phase model avoids this waste. Core packages validate basic correctness. Post packages validate higher-order properties. The kernel skips the post phase entirely when core packages are not satisfied.

### Why Exit Code 2

Exit code 1 is ambiguous. It could mean "the script crashed" or "the gate found issues." Exit code 2 is an intentional signal: "I evaluated the code and it needs more work." The kernel treats only exit 2 as a "continue loop" signal. Any other non-zero exit is treated as a script failure and logged, but does not drive the loop. This distinction prevents a buggy handler from trapping Claude in an infinite loop.

### Why Budget Instead of Convergence Detection

A simpler design might watch the score and stop when it plateaus. But convergence detection is fragile. A flaky test might cause the score to oscillate. A gate that checks generated files might produce different output each run. A hard iteration budget is predictable and controllable. You know exactly how many passes Claude will attempt. When the budget is exhausted, Claude summarizes what it accomplished and what remains, giving you a clear handoff point.

---

## Chapter 11: Troubleshooting

### Budget exhausted before gates pass

This usually means the task is too large for a single prompt. Break it into smaller pieces. If Claude is consistently hitting the budget on routine tasks, check whether a gate has a pre-existing failure that Claude cannot fix (a test that was already broken before the session started, for example).

### A gate keeps failing with the same error

Claude may not understand the fix. Add a `context` entry explaining the pattern: "When you see error TS2322, check the type definition file, not the usage site." Coaching messages help too - replace the generic failure heading with specific guidance via `on_failure`.

### Post-edit checks are slow

A check that takes more than a second per file will make editing feel sluggish. Move slow checks to gates (which run only at the Stop hook) and keep per-file checks lightweight. Formatting and single-file linting are good checks. Full-project type checking is a better gate.

### The loop is not starting

Verify the plugin is installed and enabled: `claude plugin list` should show looper. Verify jq is installed: `jq --version`. Check that `.claude/looper.json` exists and is valid JSON: `jq empty .claude/looper.json`.

### A configured package is blocked on a missing runtime

If SessionStart prints `Configuration Blocked`, Looper found a package whose declared runtime is missing. This is most common when `scope-guard` or another SDK-authored package is enabled but `deno` is not installed.

Check the package manifest for its `runtime` field, install that runtime, or remove the package from `.claude/looper.json`. While the configuration is blocked, Looper denies edit tools on purpose. It is safer to stop than to pretend the package is active when it is not.

### Stale state

State resets automatically on each new SessionStart. If you need to force a reset mid-session, delete the state directory: `rm -rf .claude/state/`.

---

## Chapter 12: The Road Ahead

The kernel is stable and minimal. New behavior comes from new packages, not kernel changes.

The quality-gates package covers the most common case: making sure code compiles, passes lint, and has green tests. The package interface supports more ambitious cycles. A TDD package could enforce test-first development by checking that test files are modified before implementation files. A security audit package could run static analysis tools and block completion when vulnerabilities surface. A performance package could run benchmarks and reject regressions.

Each of these is a directory with a manifest and a stop handler. The kernel dispatches to them, composes their votes, and manages their state.

Looper turns Claude Code into a code improver. You define the quality standards. The feedback loop that you used to close by hand is now automatic and composable.

One command to install. Zero configuration for common stacks.

```bash
claude plugin install looper@claude-plugins-official
```

---

## Appendix A: Configuration Reference

### Kernel Settings

| Key              | Type     | Default             | Description                                         |
| ---------------- | -------- | ------------------- | --------------------------------------------------- |
| `max_iterations` | number   | 10                  | Maximum improvement passes before budget exhaustion |
| `packages`       | string[] | `["quality-gates"]` | Active packages in execution order                  |

### Package Manifest Settings

| Key           | Type   | Default  | Description                                                               |
| ------------- | ------ | -------- | ------------------------------------------------------------------------- |
| `name`        | string | required | Package identifier                                                        |
| `version`     | string | required | Package version                                                           |
| `description` | string | required | Short package description                                                 |
| `runtime`     | string | -        | Optional runtime contract such as `deno`; missing runtimes block the loop |
| `phase`       | string | `core`   | `core` or `post`; controls stop-phase ordering                            |

### Gate Settings

| Key               | Type     | Default  | Description                                              |
| ----------------- | -------- | -------- | -------------------------------------------------------- |
| `name`            | string   | required | Gate identifier                                          |
| `command`         | string   | required | Shell command (exit 0 = pass)                            |
| `weight`          | number   | 0        | Points awarded on pass (out of 100 total)                |
| `skip_if_missing` | string   | -        | File path; gate skipped with full points if absent       |
| `required`        | boolean  | true     | Whether failure forces another iteration                 |
| `run_when`        | string[] | -        | Glob patterns; gate skipped if no matching files touched |
| `timeout`         | number   | 300      | Seconds before gate is killed                            |
| `enabled`         | boolean  | true     | Set false to disable without removing                    |

### Check Settings

| Key               | Type    | Default  | Description                                 |
| ----------------- | ------- | -------- | ------------------------------------------- |
| `name`            | string  | required | Check identifier                            |
| `command`         | string  | required | Shell command with `{file}` placeholder     |
| `fix`             | string  | -        | Auto-fix command (runs silently on failure) |
| `pattern`         | string  | -        | Comma-separated globs for file matching     |
| `skip_if_missing` | string  | -        | File path; check skipped if absent          |
| `enabled`         | boolean | true     | Set false to disable without removing       |

### Coaching Settings

| Key             | Type   | Default | Description                                                 |
| --------------- | ------ | ------- | ----------------------------------------------------------- |
| `urgency_at`    | number | 2       | Remaining passes threshold for budget warnings              |
| `on_failure`    | string | -       | Replaces default failure heading                            |
| `on_budget_low` | string | -       | Replaces default low-budget message; supports `{remaining}` |

### Context and Discovery

| Key        | Type     | Description                                                           |
| ---------- | -------- | --------------------------------------------------------------------- |
| `context`  | string[] | Lines injected into Claude's session context                          |
| `discover` | object   | Key-value pairs of label to shell command; output injected as context |

---

## Appendix B: Environment Variables

Variables available to package handlers:

| Variable                | Description                                  |
| ----------------------- | -------------------------------------------- |
| `LOOPER_PKG_NAME`       | Package name                                 |
| `LOOPER_PKG_DIR`        | Package root directory                       |
| `LOOPER_PKG_STATE`      | Package state directory                      |
| `LOOPER_STATE_DIR`      | Root state directory                         |
| `LOOPER_HOOKS_DIR`      | Kernel directory (for sourcing pkg-utils.sh) |
| `LOOPER_CONFIG`         | Path to looper.json                          |
| `LOOPER_ITERATION`      | Current iteration number (0-indexed)         |
| `LOOPER_MAX_ITERATIONS` | Budget cap                                   |
| `CLAUDE_PROJECT_DIR`    | Project root directory                       |

---

## Appendix C: Exit Code Reference

| Code  | PreToolUse   | PostToolUse  | Stop            |
| ----- | ------------ | ------------ | --------------- |
| 0     | Allow tool   | Normal       | Vote "done"     |
| 2     | Block tool   | -            | Vote "continue" |
| Other | Script error | Script error | Script error    |

---

*Looper is open source under the MIT License. Source code and documentation at [github.com/srdjan/looper](https://github.com/srdjan/looper).*
