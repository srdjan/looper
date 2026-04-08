# Looper: A Native Improvement Loop for Claude Code

A practitioner's guide to native agentic quality enforcement inside Claude Code.

---

## Chapter 1: The Problem

Claude Code writes good code. It reasons about architecture, generates tests, refactors with intent. But it operates blind to one critical piece of the development workflow: your toolchain output.

When Claude finishes writing a function and the type checker rejects it, Claude does not know. When the linter flags a style violation, Claude does not see the warning. When a test fails with a clear assertion error, that output lands in your terminal, not in Claude's context.

So you become the relay. You copy the error from your terminal. You paste it into the chat. Claude reads it, fixes the code, and finishes again. The type checker runs. A different error this time. You copy. You paste. Claude fixes. The linter complains. Copy. Paste. Fix.

This is human middleware. You are manually closing the feedback loop between an AI that can write code and the tools that validate it. The type checker, linter, test runner, and formatter are all installed. They are all configured. Claude simply cannot see their output.

The pattern is universal among Claude Code users. The tools vary - tsc or mypy, eslint or clippy, jest or pytest - but the loop is identical. Claude writes, tools reject, you relay, Claude fixes. Repeat until green. The cognitive cost is not in understanding the errors. It is in the mechanical act of ferrying text between two processes that should be talking directly.

Looper closes this loop automatically.

---

## Chapter 2: What Looper Does

Looper is a Claude Code plugin that intercepts the moment Claude finishes a response and asks a simple question: did the code pass your quality checks? If the answer is no, Claude gets another turn with the failure output injected as feedback. This repeats until all required gates pass or an iteration budget is exhausted.

The key word is "native." Looper is not a wrapper script that invokes Claude from the outside. It runs inside Claude Code's own hook system, responding to the same lifecycle events that Claude Code uses internally. No log scraping, no process orchestration, no screen parsing. Four hooks cover the entire workflow:

**SessionStart** fires once when a new session begins. This is where Looper initializes its state, detects your project's stack, injects context into Claude's prompt, and optionally captures a baseline of pre-existing failures.

**PreToolUse** fires before every tool invocation. Looper uses this to track which files Claude edits, inject the current pass counter into Claude's context, enforce the iteration budget, and block edits if the configuration is in a broken state.

**PostToolUse** fires after every tool invocation. For edit tools specifically, Looper runs per-file checks here - formatting and linting against the individual file that was just changed. If the formatter finds issues, it auto-fixes them silently. If the linter finds issues, Claude sees them immediately rather than waiting for the stop-time evaluation.

**Stop** fires when Claude indicates it is finished. This is the main evaluation point. Looper runs all configured quality gates, computes a score, compares results against any baseline, generates a failure report with coaching, and decides whether Claude should continue or stop. If any required gate failed, Looper exits with code 2, which tells Claude Code to push Claude back for another attempt. The failure output goes to stderr, which Claude reads as feedback.

Architecturally, Looper has two layers. The kernel handles loop mechanics: state management, hook dispatch, circuit breakers, package discovery. It knows nothing about quality gates or what constitutes a "pass." All domain logic lives in packages - separate directories with handler scripts that define what to check, how to score, and when to stop.

The bundled quality-gates package is the primary one. It implements gate evaluation, per-file checks, baseline capture, session summaries, failure provenance tracking, trajectory analysis, and adaptive recommendations. But quality-gates is not the only package. Scope-guard enforces edit boundaries, preventing Claude from modifying files outside a declared scope. Acceptance-flows runs smoke tests after gates pass, verifying that user-visible behavior actually works. Loop-memory reads accumulated gate history across sessions and injects predictive context - warning Claude about files that historically correlate with gate failures.

These packages compose. Multiple packages run in declaration order, and the kernel aggregates their stop/continue votes. All packages must vote "done" for the loop to end. Any package voting "continue" forces another iteration.

---

## Chapter 3: Getting Started

Install with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/srdjan/looper/main/install.sh | bash
```

The script checks that `jq` and `claude` are available, clones the repository to `~/.claude/plugins/looper`, and prints the command to start Claude Code with the plugin enabled. If you prefer, clone manually:

```bash
git clone https://github.com/srdjan/looper.git ~/.claude/plugins/looper
```

The only external dependency is `jq`. The kernel checks for it at SessionStart and prints platform-specific install instructions if it is missing - `brew install jq` on macOS, `apt install jq` on Debian/Ubuntu, `dnf install jq` on Fedora. This preflight check runs before anything else, preventing cryptic "command not found" errors from surfacing later.

Start Claude Code with the plugin:

```bash
claude --plugin-dir ~/.claude/plugins/looper
```

A marketplace install path is planned:

```bash
claude plugin install looper@claude-plugins-official
```

On first run, the kernel detects that no `.claude/looper.json` exists and triggers the bootstrap. The bootstrap script - `bootstrap-config.sh` - inspects repo truth. It looks for stack markers (Cargo.toml, go.mod, pyproject.toml, deno.json, tsconfig.json), reads package.json scripts to find actual test and lint commands, checks lockfiles to determine the package manager, and scans for tool configuration files like eslint.config.js or biome.json. From these signals, it writes `.claude/looper.json` with gates and checks matched to your project.

The bootstrap reports its findings in three signal categories. "Verified" signals are confirmed by file or config existence - for example, "ESLint detected from eslint.config.js." "Assumed" signals are reasonable defaults applied when no signal is present - "Assuming npm as package manager." "Unresolved" signals are ambiguous cases where the detector could not determine the right answer.

These categories feed into a confidence level. High confidence means all key signals were verified. Medium means some assumptions were made. Low means minimal signals were detected.

Claude sees a one-time "Bootstrap Summary" block at the first SessionStart, showing the detected stack, the confidence level, and the verified signals. This block appears once and is then removed.

Three commands help you verify and refine the setup:

`/looper:bootstrap` is a health check. It validates that jq is present, that the config file parses correctly, and runs each configured gate with a 5-second timeout to confirm the commands are actually available.

`/looper:doctor` re-runs the bootstrap detection against the current state of the repo and compares the proposed config against your existing `.claude/looper.json`. If your project gained ESLint since Looper was first configured, doctor shows the drift and suggests running `/looper:looper-config` for guided repair.

`/looper:looper-config` is a guided 4-phase wizard: detect the stack, propose a config, let you refine it, and write the result.

With the setup complete, prompt Claude with a code change. SessionStart fires, injecting loop context. Claude works, editing files. PostToolUse runs per-file checks on each edit, giving Claude immediate feedback on formatting and lint issues. When Claude finishes, the Stop hook runs all quality gates. If anything fails, Claude gets the failure output and tries again. If everything passes, the loop ends. You did not paste a single error message.

---

## Chapter 4: Configuration

All configuration lives in `.claude/looper.json`. The file has two levels: kernel settings at the top and package settings nested under each package's name.

```json
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [
      { "name": "typecheck", "command": "npx tsc --noEmit --pretty false", "weight": 30 },
      { "name": "lint", "command": "npx eslint .", "weight": 20 },
      { "name": "test", "command": "npm test", "weight": 30 },
      { "name": "coverage", "command": "$LOOPER_PKG_DIR/lib/check-coverage.sh", "weight": 20, "required": false }
    ]
  }
}
```

`max_iterations` and `packages` are the only kernel-level settings. Everything under the `"quality-gates"` key belongs to that package. The kernel passes it through without interpretation.

`max_iterations` is a circuit breaker, not a target. Most tasks converge in 2-4 passes. Setting it to 10 gives Claude room for harder problems without encouraging waste.

### Gates

Each gate has a `name` and a `command`. The command runs in a shell; exit code 0 means pass, anything else means fail.

`weight` assigns points out of a 100-point total. Weights are a progress indicator, not a threshold. Claude sees "Score: 50/100" and knows which gates are passing and which are not. The loop continues until all required gates exit 0, regardless of the numeric score.

`skip_if_missing` takes a file path. If that path does not exist, the gate is skipped and awarded full points. This makes configs portable - a gate that checks for `node_modules/.bin/eslint` silently skips in projects where ESLint is not installed.

`required` defaults to true. Optional gates (like coverage) report their results but do not block completion. A session can end with optional gates failing.

`run_when` takes an array of glob patterns. The gate only runs if files matching those patterns were touched during the session. This prevents running the type checker when Claude only edited markdown.

`timeout` defaults to 300 seconds. The gate command is killed if it exceeds this limit.

`enabled` can be set to false to disable a gate without removing it from the config.

### Post-Edit Checks

Checks run per file, immediately after each edit, rather than waiting for the stop evaluation:

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

The `{file}` placeholder is replaced with the path of the file Claude just edited. The `fix` command runs silently when the check fails - Prettier reformats the file without Claude needing to do anything. The `pattern` field restricts the check to matching file extensions. This gives Claude fast, granular feedback on each edit rather than accumulating issues until stop time.

### Context Injection

```json
{ "context": ["This project uses Deno with Oak.", "Never modify docs/api.md."] }
```

Strings in the `context` array are injected into Claude's prompt at SessionStart. They support placeholders: `{max_iterations}`, `{gate_count}`, `{branch}`. Use this for project-specific constraints that Claude should know about before it starts working.

### Discovery

```json
{ "discover": { "test_files": "find . -name '*.test.*' | head -20", "runtime": "node --version" } }
```

Discovery commands run at session start. Their output is injected under a "Project State" heading. This is useful for giving Claude awareness of the test file layout, installed runtime versions, or other dynamic project facts.

### Coaching

```json
{ "coaching": { "urgency_at": 3, "on_failure": "Fix failures only.", "on_budget_low": "Only {remaining} passes left." } }
```

`urgency_at` sets the remaining-passes threshold at which budget warnings appear. `on_failure` replaces the default failure heading in the stop report. `on_budget_low` replaces the default low-budget warning, with `{remaining}` substituted for the actual count. These let you tune how Looper talks to Claude when things are going wrong.

### Baseline

```json
{ "quality-gates": { "baseline": true, "baseline_timeout": 60, "gates": [...] } }
```

When `baseline` is true, all gates run at SessionStart before Claude changes anything. The results are stored as a pass/fail snapshot. On each subsequent Stop evaluation, failures that match the baseline are marked as pre-existing and do not force another iteration. Only new failures that Claude introduces cost budget. This is covered in depth in Chapter 8.

---

## Chapter 5: Repo-Truth Bootstrap

On first run, `bootstrap-config.sh` inspects the project and writes a config from what it finds. The detection follows a strict priority order, and the first match wins. This matters for mixed-stack projects.

1. Cargo.toml - Rust
2. go.mod - Go
3. pyproject.toml or requirements.txt - Python
4. deno.json or deno.jsonc - Deno
5. tsconfig.json + biome.json - TypeScript-Biome
6. tsconfig.json (no biome) - TypeScript-ESLint
7. Fallback - Minimal

A Rust project with a package.json - common in wasm-pack projects - detects as Rust, not TypeScript. The priority order prevents false classification.

Beyond stack detection, the bootstrap reads package.json scripts to find the actual commands your project uses. If package.json has `"test": "vitest run"`, the test gate uses `pnpm test` (or whichever package manager was detected from lockfiles), not a generic `npm test`. The package manager is detected from lockfiles: pnpm-lock.yaml maps to pnpm, yarn.lock to yarn, bun.lock or bun.lockb to bun, and the default is npm.

Seven presets correspond to the seven detection outcomes. Each preset includes tuned gates and per-file checks.

**TypeScript + ESLint** gets four gates: tsc at 30 points, eslint at 20, npm test at 30, and coverage at 20 (optional). Per-file checks include prettier format with auto-fix, eslint, and tsc.

**TypeScript + Biome** replaces eslint and prettier with biome. Gates are tsc at 30, biome check at 20, vitest at 30, biome format at 20 (optional). Biome handles both linting and formatting in a single tool.

**Deno** needs no external dependencies. Gates are deno check at 30, deno lint at 20, deno test at 30, deno fmt at 20 (optional). Everything comes from the Deno runtime itself.

**Python** uses mypy at 30 points, ruff check at 20, pytest at 30, ruff format at 20 (optional). Both mypy and ruff gates include `skip_if_missing` for their respective config files, so the config works even in projects that have not set up these tools yet.

**Go** uses go build at 30, go vet at 20, go test at 30, golangci-lint at 20 (optional). The per-file check runs gofmt with auto-fix.

**Rust** uses cargo check at 30, clippy at 20, cargo test at 30, cargo fmt at 20 (optional). Clippy is too slow for per-file checks, so only cargo fmt runs per-file with auto-fix.

**Minimal** is the fallback when no stack is recognized. It has a single gate: the test command at 100 points. No per-file checks.

Weights across all presets sum to 100. When a category is missing - no formatter detected, for instance - the bootstrap redistributes weights proportionally among the remaining gates. Without a formatter, typecheck goes to 35, lint to 25, test to 40.

The `/looper:doctor` command re-runs the detection logic against the current state of the repo and compares its proposal to your existing config. If your project added ESLint since Looper was first configured, doctor shows the drift as a list of additions and removals.

---

## Chapter 6: What Claude Sees

Understanding what information Claude receives at each stage of the loop explains why the system works. The feedback is structured, concise, and actionable.

### Session Start

When a session begins, Claude's context includes a block like this:

```
## Improvement Loop Active
You are operating inside an improvement loop (max 10 passes).
Active packages (1): quality-gates

## Quality Gates
Total: 100 points. Pass when all required gates exit 0.
  typecheck  30pts required  npx tsc --noEmit --pretty false
  lint       20pts required  npx eslint .
  test       30pts required  npm test
  coverage   20pts optional  check-coverage.sh
```

Claude knows it is inside a loop, knows the budget, and knows exactly which gates will evaluate its work. This is not decorative context. Knowing that a type checker will run changes how carefully Claude writes types.

On the very first run, Claude also sees the Bootstrap Summary:

```
## Bootstrap Summary
Detected stack: typescript-eslint
Bootstrap confidence: high
Verified:
  - TypeScript detected from tsconfig.json
  - ESLint detected from eslint.config.js
```

If baseline capture is enabled and pre-existing failures were found, Claude sees those too:

```
Pre-Existing Failures (not blocking):
  - lint: 3 warnings in src/legacy.ts
These failures existed before your session started. Ignore them.
```

This prevents Claude from spending its budget fixing problems it did not create.

### Per-Edit Feedback

After each file edit, PostToolUse runs per-file checks and reports the results:

```
post-edit checks -- src/user.ts
ok src/user.ts: all checks clean
```

Or when issues are found:

```
post-edit checks -- src/user.ts
  format: 2 issues (auto-fixed)
  lint: 1 issue
```

Format issues are auto-fixed silently. Lint issues are reported so Claude can address them before moving on. This is faster feedback than waiting for the stop evaluation.

### Stop Evaluation

When Claude finishes and the Stop hook runs, Claude sees the full gate report:

```
QUALITY GATES -- PASS 2/10
Score: 80/100  History: [50, 80]
-------------------------------------------
 v typecheck  30/30
 v lint       20/20
 x test        0/30  FAILED
 o coverage    -/20  skipped
-------------------------------------------
-- test --
FAIL src/user.test.ts
  x should validate email format
    Expected: true  Received: false
-------------------------------------------
FIX THE SPECIFIC FAILURES. 8 passes remaining.
```

The symbols are consistent: `v` means pass, `x` means failed (a failure Claude introduced), `~` means pre-existing (captured at baseline), `o` means skipped. The score history array shows the trajectory across passes. The failure block includes the tail of the gate command's output - the specific assertion that failed, the specific type mismatch.

### Trajectory Analysis

When Claude gets stuck, the stop feedback changes. Three patterns are detected and addressed with specific coaching:

A plateau - the score unchanged across multiple passes - triggers: "The current strategy isn't working. Try a different approach." This redirects Claude away from repeating the same fix that keeps failing.

Oscillation - the score alternating up and down between passes - triggers: "Fixing one gate keeps breaking another. Address both together." This tells Claude that its fixes are interfering with each other.

Regression - the score dropping below earlier passes - triggers: "Recent changes made things worse. Consider reverting." This gives Claude permission to back out of a bad path.

### Failure Provenance

When a gate fails, provenance tracking shows when the failure first appeared:

```
PROVENANCE:
  test: first failed on pass 2. Files changed on pass 2: src/user.ts, src/user.test.ts
```

This narrows Claude's search space. Instead of re-examining everything, it knows exactly which pass introduced the problem and which files were involved.

### Recommendations

When recent session history supports it, the stop feedback includes suggestions:

```
Suggestions:
  - Enable baseline to ignore 3 pre-existing lint warnings
  - Consider adding scope-guard: 12 files touched without scope protection
```

These appear only when the signal is strong enough to be actionable.

### Budget Exhaustion

When the iteration budget runs out:

```
IMPROVEMENT LOOP COMPLETE - BUDGET REACHED
Iterations: 10/10
Summarize: what was accomplished, what remains unfixed.
```

Claude stops editing and produces a summary of what it achieved and what still needs attention. The summary gives you a starting point for the next session.

---

## Chapter 7: The Kernel

The entire control layer is two files: `kernel/kernel.sh` at 540 lines and `kernel/pkg-utils.sh` at 105 lines. Everything runs through bash and jq. No build step, no dependency install for the kernel itself.

### Preflight

The first thing SessionStart does is call `preflight_check()`. It runs `command -v jq`. If jq is missing, it prints install instructions for brew, apt, and dnf, then exits 0. It does not crash Claude's session - it tells you what to install and gets out of the way.

### Bootstrap

`ensure_config()` fires on SessionStart. If `.claude/looper.json` does not exist, it shells out to `bootstrap-config.sh inspect` inside the quality-gates package. The detector inspects the actual repo - package.json scripts, lockfiles, tool configs - and returns a JSON report containing the proposed config, detected stack, confidence level, verified signals, assumed signals, and unresolved signals. The kernel writes the config and saves a transient `bootstrap-summary.json` in the state directory. SessionStart renders the summary and deletes the file.

After the first session, the config file exists, so `ensure_config` is a no-op.

### State

Kernel state lives at `.claude/state/kernel.json`:

```json
{
  "iteration": 2,
  "max_iterations": 10,
  "status": "running",
  "missing_runtimes": [],
  "files_touched": ["src/user.ts", "src/user.test.ts"]
}
```

Five possible status values: `running`, `complete`, `budget_exhausted`, `breaker_tripped`, `config_blocked`.

All state mutations use jq with atomic writes. The pattern: write to a temp file with `mktemp`, run the jq filter, then `mv` into place. Three functions handle this: `kernel_write` sets a field, `kernel_append` pushes to an array, `kernel_read` extracts a value.

### Package Resolution

When the kernel needs a package, it searches three locations and takes the first match:

1. `$CLAUDE_PROJECT_DIR/.claude/packages/<name>/` - project-local override
2. `$HOME/.claude/packages/<name>/` - user-global
3. `$CLAUDE_PLUGIN_ROOT/packages/<name>/` - plugin-bundled

This means you can override any bundled package by dropping a replacement in your project's `.claude/packages/` directory.

### Event Dispatch

Handler filenames follow a naming convention: `session-start.sh`, `pre-tool-use.sh`, `post-tool-use.sh`, `stop.sh`. If a package directory has no handler for an event, the kernel skips it silently. A package can implement any subset of events.

Handlers run in a subshell. The kernel exports environment variables before executing:

- `LOOPER_PKG_NAME` - the package name
- `LOOPER_PKG_DIR` - absolute path to the package directory
- `LOOPER_PKG_STATE` - path to this package's state directory
- `LOOPER_STATE_DIR` - path to the shared state directory
- `LOOPER_HOOKS_DIR` - path to the kernel directory (where pkg-utils.sh lives)
- `LOOPER_CONFIG` - path to looper.json
- `LOOPER_ITERATION` - current iteration number
- `LOOPER_MAX_ITERATIONS` - budget cap
- `CLAUDE_PROJECT_DIR` - the project root

The subshell boundary is important. Handlers cannot corrupt kernel state through environment pollution.

### Circuit Breakers

Three mechanisms prevent runaway loops:

**Re-entry guard.** The Stop event payload includes a `stop_hook_active` flag. If Stop fires while a Stop handler is already running, the kernel writes `breaker_tripped` to status and exits 0 immediately. No handler runs. The session ends.

**Iteration budget.** A hard cap at `max_iterations`. When PreToolUse fires and the iteration count has reached the limit, it blocks edit tools and tells Claude to summarize. When Stop fires at the limit, it writes `budget_exhausted` and exits 0.

**Two-phase stop.** Packages declare a phase: `core` or `post`. During Stop, the kernel runs all core-phase handlers first. If any core handler votes "continue" (exit 2), the kernel skips the post phase entirely. This prevents wasted work. There is no point running a security scanner on code that does not compile.

### Runtime Contracts

Packages can declare `"runtime": "deno"` in their manifest. At SessionStart, the kernel iterates all active packages and checks whether each declared runtime exists on the system. If any are missing: status becomes `config_blocked`, SessionStart prints a warning listing the missing runtimes, PreToolUse blocks all edit tools, and Stop exits cleanly. Looper fails closed. It will not silently skip a package because its runtime is absent.

### Hook Registration

The file `hooks/hooks.json` registers the kernel with Claude Code's hook system. Each event has a timeout: SessionStart at 30 seconds, PreToolUse at 10 seconds, PostToolUse at 30 seconds, Stop at 600 seconds. The generous Stop timeout reflects the reality that running a full test suite, linter, and type checker takes time.

---

## Chapter 8: Baseline, History, and Provenance

### Baseline Capture

Set `"baseline": true` in your config and all gates run at SessionStart before Claude changes anything. The results are stored as a pass/fail snapshot. When Stop evaluates gates later, failures that match the baseline are marked `~` (pre-existing) instead of `x` (new). Pre-existing failures do not block the loop. Only new failures cost budget.

The `baseline_timeout` setting (default 60 seconds) controls the per-gate time limit during capture. This is shorter than the normal gate timeout because baseline runs at session start, where you want fast feedback over exhaustive coverage.

The practical effect: if a project has 15 pre-existing lint warnings, Claude does not spend its iteration budget fixing problems that existed before it started working. It focuses on the failures it introduced.

### Session History

Each completed session appends a one-line JSON object to `.claude/state/sessions.jsonl`. Fields include status, timestamp, iteration count, final score, introduced failure count, and pre-existing failure count. If a session exhausted its budget without finalizing, the next SessionStart promotes it to the log.

The `/looper:status` command reads this log and displays a table of recent sessions plus aggregate statistics.

### Failure Provenance

The quality-gates package records per-pass traces in `.claude/state/quality-gates/passes.jsonl`. Each row captures the session ID, timestamp, pass number, score, per-gate statuses, and files changed during that pass.

When a gate turns red after being green, or stays red across multiple passes, the Stop feedback includes a PROVENANCE block. It tells Claude exactly when the failure first appeared and which files changed around that turn.

Two types are detected:

Introduced failures: the gate was passing, now it fails. The provenance message reads something like "test: first failed on pass 3. Files changed: src/api.ts". This gives Claude a clear starting point for debugging.

Persistent failures: the gate has failed for multiple consecutive passes. The message shows "lint: failing since pass 1. Files changed since last green: src/handler.ts, src/types.ts". This signals that the current fix strategy is not working.

The `/looper:status` command surfaces the same information as "Failure Introduction Points" for the most recent session.

### Trajectory Analysis

After each Stop, the system analyzes the score history across passes and looks for three patterns:

Plateau: the same score repeats for three or more consecutive passes. Whatever Claude is doing, it is not making progress. The coaching message suggests trying a different approach.

Oscillation: the score alternates up and down (80, 50, 80, 50). Fixing one gate breaks another. The coaching message points this out and suggests fixing the root cause rather than ping-ponging between symptoms.

Regression: the score drops below earlier passes. Recent changes made things worse. The coaching message flags the regression and suggests reverting or rethinking.

### Adaptive Recommendations

Based on the last 10 sessions of history, Looper suggests configuration changes. These are not automatic - they appear as suggestions in Stop feedback and in `/looper:status` output.

The recommendations include: enable baseline after repeated budget exhaustion, increase max_iterations if tasks consistently exhaust budget, decrease max_iterations if tasks complete in 1-2 passes, add scope-guard when sessions touch many files without scope protection.

---

## Chapter 9: The Package Ecosystem

### quality-gates

Core phase. Shell-native - no external runtime required.

This is the default package and the one doing the most work. It runs gates at Stop, per-file checks at PostToolUse, and context injection at SessionStart. It handles baseline capture, scoring, failure provenance, trajectory analysis, adaptive recommendations, and coaching. All in bash and jq.

### scope-guard

Post phase. Requires deno.

Prevents Claude from editing files outside a declared scope. Two enforcement modes:

`blocked`: glob patterns for files Claude must never edit. Enforcement happens at PreToolUse - the edit is denied in real time before it occurs.

`allowed`: glob patterns for files Claude may edit. Enforcement happens at Stop - out-of-scope edits are reported after the fact.

```json
{
  "scope-guard": {
    "blocked": ["package-lock.json", ".env*"],
    "allowed": ["src/**/*", "tests/**/*"]
  }
}
```

Because scope-guard runs in the post phase, it only evaluates after quality-gates passes.

### acceptance-flows

Post phase. Requires deno.

Runs smoke or acceptance tests after core gates pass. Each flow is a named command with a timeout, optional file-glob triggers (`run_when`), and a `required` flag. Standard output and error are stored as artifacts in `.claude/state/acceptance-flows/artifacts/`.

```json
{
  "acceptance-flows": {
    "flows": [
      {
        "name": "api-smoke",
        "command": "npm run smoke:api",
        "timeout": 120,
        "run_when": ["src/api/**/*"],
        "required": true
      }
    ]
  }
}
```

### loop-memory

Core phase. Requires deno.

Reads accumulated quality-gates data across sessions and injects predictive context. It computes gate difficulty profiles, file-gate failure correlations, convergence patterns, and oscillation detection. At PreToolUse, it warns when Claude is about to edit a file that is historically correlated with gate failures.

```json
{
  "loop-memory": {
    "min_sessions": 3,
    "max_context_lines": 18,
    "lookback_sessions": 20,
    "correlation_threshold": 0.3,
    "enable_file_warnings": true
  }
}
```

Loop-memory never blocks edits or forces continuation. It is advisory context only.

### sdk-hello

A minimal reference package demonstrating the SDK package format.

---

## Chapter 10: Building Custom Packages

### Minimal Package

Two files: a `package.json` manifest and `hooks/stop.sh`.

```json
{
  "name": "my-package",
  "version": "1.0.0",
  "description": "What this package does",
  "phase": "core"
}
```

Optional manifest fields:

- `runtime` - set to `"deno"` if your handlers need it. The kernel fails closed if the runtime is missing.
- `matchers` - an object mapping event names to regex patterns for tool filtering. `{ "PreToolUse": "Edit|MultiEdit|Write" }` means your PreToolUse handler only fires for edit tools.
- `phase` - `"core"` (default) or `"post"`. Core packages run first; post packages only run when all core packages pass.

### Handler Protocol

**Stop**: Exit 0 means "done, this package is satisfied." Exit 2 means "continue, there is still work to do." Anything written to stderr becomes Claude's feedback.

**PreToolUse**: Exit 0 means "allow the tool call." Exit 2 means "block it." The handler can emit JSON with `additionalContext` to inject context into Claude's view.

**PostToolUse**: Standard output goes to Claude as feedback. The exit code does not affect the loop.

**SessionStart**: Standard output becomes part of Claude's initial context for the session.

### State Utilities

Handlers source `pkg-utils.sh` from the kernel directory to get state helpers:

```bash
source "$LOOPER_HOOKS_DIR/pkg-utils.sh"

# Read kernel state
kernel_read '.iteration'

# Read/write your package's private state
pkg_state_write '.my_counter' '0'
pkg_state_read '.my_counter'

# Read another package's state (read-only)
pkg_read 'quality-gates' '.scores[-1]'

# Read your config from looper.json
pkg_config '.my_setting'

# Check if touched files match glob patterns
files_match_patterns '["*.ts"]'

# Run a command with a timeout
run_with_timeout 30 npm test
```

State is scoped. Each package gets its own directory under `.claude/state/<package-name>/`. Packages can read each other's state but can only write to their own.

### Example: Documentation Checker

A post-phase package that verifies README covers all exported functions. It sources pkg-utils, checks `files_match_patterns` to see if source files were touched, diffs the export list against README mentions, and exits 2 with the missing list on stderr if anything is undocumented. Next iteration, Claude adds the documentation, the check passes, exit 0.

### Multi-Package Composition

All active packages must vote "done" for the loop to end. A single "continue" vote from any package forces another iteration. Packages run in declaration order within the same phase. Output is aggregated with package-name headers.

---

## Chapter 11: Design Decisions

### Why bash

Hooks execute shell commands. Bash and jq are available everywhere Claude Code runs. No build step, no package manager for the control layer. The kernel is 540 lines. Shell is the natural language for orchestrating other shell tools - test runners, linters, type checkers. The kernel calls them; it does not reimplement them.

### Why native

External loops wrap the `claude` CLI, scrape its output, and replay failures by pasting prompts back in. They are structurally late - they see what happened after the fact. Looper runs at the control points: SessionStart injects rules before Claude starts working, PreToolUse blocks edits before they happen, PostToolUse gives feedback while Claude is still in context, Stop decides whether Claude is done. One session, one state directory, one control loop.

### Why jq

State files are JSON. Run `cat .claude/state/kernel.json` to see loop status. Packages read each other's state through jq filters. The design prioritizes transparency over performance. Each jq call costs roughly 5 milliseconds, which is negligible next to the gate commands that take seconds.

### Why per-project config

Different projects use different tools. A Go project does not run eslint. A frontend project does not run `go vet`. Config lives in the project directory, checked into version control. Every developer on the team gets the same gates.

### Why two-phase stop

Without phases, every package runs every iteration. A slow security scanner runs on code that does not compile. With two phases, the core phase validates correctness. The post phase validates higher-order properties. The kernel skips post entirely when core fails.

### Why exit code 2

Exit 1 is ambiguous. It could mean the script crashed, or it could mean the gate evaluated the code and found a problem. Exit 2 is intentional: "I evaluated the code and it needs more work." Only exit 2 drives the loop. Other non-zero exit codes are treated as script failures - logged, but they do not trigger another iteration.

### Why budget over convergence detection

Convergence detection sounds appealing: stop when the score stops improving. In practice, it is fragile. Flaky tests cause oscillation that looks like non-convergence. A hard budget is predictable. You know the maximum cost before the session starts. When the budget is exhausted, Claude summarizes what it accomplished and what remains.

### Why fail closed on missing runtimes

The alternative is to silently skip a package whose runtime is absent. If scope-guard requires deno and deno is not installed, the silent-skip approach would run the session with no scope protection. Looper blocks edits and tells you exactly why. Loud failure over silent omission.

### Why repo-truth bootstrap over simple presets

The old approach checked for marker files and mapped to presets. The new `bootstrap-config.sh` inspects what is actually in the repo - package.json scripts, lockfile contents, tool configs - and builds a config from the ground truth. It reports confidence levels so you know when manual review is warranted.

---

## Chapter 12: Troubleshooting

### Budget exhausted

The task is too large for the iteration budget, or pre-existing failures are draining it. Break the task into smaller pieces. If pre-existing failures are the problem, enable `"baseline": true` so failures present before Claude started working do not count. Run `/looper:status` to see patterns across recent sessions.

### Same error repeating

Claude does not understand how to fix the issue. Look at the PROVENANCE block in the Stop feedback - it shows when the failure first appeared and which files changed. If the trajectory analysis shows a plateau or oscillation, the coaching messages already suggest a different strategy. You can also add a `context` entry that explains the fix.

### Post-edit checks are slow

Move slow checks from `checks` (per-file, PostToolUse) to `gates` (per-stop, Stop). Keep per-file checks under 1 second. Type checking the whole project after every single edit will grind things down; type checking once at Stop is fast enough.

### Loop not starting

`claude plugin list` should show looper. `jq --version` should succeed. `.claude/looper.json` should be valid JSON - test with `jq empty .claude/looper.json`. Run `/looper:bootstrap` for a full health check.

### Config blocked on missing runtime

SessionStart prints "Configuration Blocked" and lists which packages need which runtimes. Install the runtime or remove the package from `looper.json`. Edit tools are blocked on purpose while config is blocked.

### Config drifted from repo

Run `/looper:doctor`. It compares the current config against what the bootstrap detector would propose today and shows drift.

### Stale state

State resets on each SessionStart. Force reset: `rm -rf .claude/state/`. The kernel recreates everything on the next session.

---

## Appendix A: Configuration Reference

### Kernel Settings

| Setting | Type | Default | Description |
|---|---|---|---|
| `max_iterations` | number | `10` | Maximum loop passes before budget exhaustion |
| `packages` | string[] | `["quality-gates"]` | Active packages in declaration order |

### Package Manifest

| Field | Required | Default | Description |
|---|---|---|---|
| `name` | yes | - | Package identifier |
| `version` | yes | - | Semver version |
| `description` | yes | - | Human-readable purpose |
| `runtime` | no | - | Required runtime (e.g. `"deno"`) |
| `phase` | no | `"core"` | `"core"` or `"post"` |
| `matchers` | no | - | Object mapping event names to regex tool filters |

### Gate Settings

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Gate identifier |
| `command` | string | required | Shell command to run |
| `weight` | number | required | Score weight for this gate |
| `skip_if_missing` | string | - | File path; gate skipped with full points if absent |
| `required` | boolean | `true` | Whether failure blocks the loop |
| `run_when` | string[] | - | Glob patterns; gate only runs if touched files match |
| `timeout` | number | `300` | Per-gate timeout in seconds |
| `enabled` | boolean | `true` | Set to false to disable without removing |

### Check Settings

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Check identifier |
| `command` | string | required | Shell command with `{file}` placeholder |
| `fix` | string | - | Auto-fix command (runs silently on failure) |
| `pattern` | string | - | Comma-separated globs for file matching |
| `skip_if_missing` | string | - | File path; check skipped if absent |
| `enabled` | boolean | `true` | Set to false to disable without removing |

### Coaching Settings

| Field | Type | Default | Description |
|---|---|---|---|
| `urgency_at` | number | `2` | Remaining passes threshold for budget warnings |
| `on_failure` | string | - | Replaces default failure heading |
| `on_budget_low` | string | - | Replaces default low-budget message; supports `{remaining}` |

### Baseline Settings

| Field | Type | Default | Description |
|---|---|---|---|
| `baseline` | boolean | `false` | Enable baseline capture at SessionStart |
| `baseline_timeout` | number | `60` | Per-gate timeout during baseline capture (seconds) |

### Context and Discovery

| Field | Type | Description |
|---|---|---|
| `context` | string[] | Lines injected into Claude's context at SessionStart |
| `discover` | object | Map of label to shell command; output injected at SessionStart |

---

## Appendix B: Environment Variables

These variables are exported into every handler's subshell:

| Variable | Description |
|---|---|
| `LOOPER_PKG_NAME` | Name of the current package |
| `LOOPER_PKG_DIR` | Absolute path to the package directory |
| `LOOPER_PKG_STATE` | Path to this package's state directory |
| `LOOPER_STATE_DIR` | Path to the shared `.claude/state/` directory |
| `LOOPER_HOOKS_DIR` | Path to the kernel directory (where `pkg-utils.sh` lives) |
| `LOOPER_CONFIG` | Path to `.claude/looper.json` |
| `LOOPER_ITERATION` | Current iteration number |
| `LOOPER_MAX_ITERATIONS` | Budget cap from config |
| `CLAUDE_PROJECT_DIR` | The project root directory |

---

## Appendix C: Exit Code Reference

| Code | PreToolUse | PostToolUse | Stop |
|---|---|---|---|
| `0` | Allow tool | Normal | Vote "done" |
| `2` | Block tool | - | Vote "continue" |
| Other | Script error | Script error | Script error |

Exit 0 and exit 2 are the only intentional codes. Everything else is treated as a script failure: logged, but it does not drive the loop.

---

*Looper is open source under the MIT License. Source code and documentation at [github.com/srdjan/looper](https://github.com/srdjan/looper).*
