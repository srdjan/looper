<p align="center">
  <img src="assets/looper-logo.png" alt="Looper Logo" width="50%">
</p>

# Claude Code Native Improvement Loop, Built By Claude

Looper is a Claude Code hooks-based improvement loop that keeps Claude iterating until quality gates pass. It runs configurable quality gates after each response and gives Claude another turn when required gates fail. Gates, per-file checks, session context, and feedback are all driven by a single JSON config file. Up to 10 passes by default, then it stops.

## Architecture

```mermaid
---
title: Agentic Improvement Loop — Hook Flow
---
flowchart TD
    START["SessionStart Hook"] -->|"init state.json\ninject context to Claude"| PROMPT["You: implement feature X"]

    PROMPT --> CLAUDE["Claude reasons + plans"]

    CLAUDE --> PRE{"PreToolUse\n(Edit|Write)"}

    PRE -->|"iteration >= 10"| BLOCK["exit 2: BLOCKED\n'budget exhausted'"]
    PRE -->|"iteration < 10"| ALLOW["exit 0: ALLOW\n+ inject pass N/10"]

    ALLOW --> TOOL["Tool executes\n(file written/edited)"]

    TOOL --> POST["PostToolUse Hook"]
    POST -->|"format + lint\nstdout → Claude"| CLAUDE2["Claude continues\n(self-corrects if issues)"]

    CLAUDE2 -->|"more edits needed"| PRE
    CLAUDE2 -->|"Claude says 'done'"| STOP{"Stop Hook"}

    STOP -->|"stop_hook_active\n== true"| DONE_BREAKER["exit 0: STOP\n(circuit breaker)"]
    STOP -->|"iteration >= 10"| DONE_BUDGET["exit 0: STOP\n(budget exhausted)\nprint score history"]
    STOP -->|"all required\ngates pass"| DONE_PERFECT["exit 0: STOP\n(required gates pass!)"]
    STOP -->|"required gate\nfailed"| LOOP["exit 2: CONTINUE\nincrement iteration\nfeedback → stderr"]

    LOOP -->|"Claude gets\nanother turn"| CLAUDE

    style START fill:#4a9eff,color:#fff
    style DONE_BREAKER fill:#ff6b6b,color:#fff
    style DONE_BUDGET fill:#ffa94d,color:#fff
    style DONE_PERFECT fill:#51cf66,color:#fff
    style LOOP fill:#845ef7,color:#fff
    style BLOCK fill:#ff6b6b,color:#fff
```

## Files

```
.claude/
├── settings.json              # Hook configuration
├── looper.json                # Gate + check + context config
├── hooks/
│   ├── hook-manifest.sh       # Shared hook file list (installer, uninstaller, tests)
│   ├── state-utils.sh         # State read/write + config helpers
│   ├── session-start.sh       # Initialize state + inject context
│   ├── pre-edit-guard.sh      # Budget gate + iteration context
│   ├── post-edit-check.sh     # Config-driven per-file checks
│   ├── check-coverage.sh      # Default coverage gate helper
│   └── stop-improve.sh        # Improvement loop driver
└── state/
    └── loop-state.json        # Iteration counter + scores (gitignored)
skills/
└── looper-config/             # /looper-config skill for guided setup
tests/
└── test-suite.sh              # Shell tests (74 cases)
```

## Install

```bash
# From anywhere — point at your project
git clone <this-repo> /tmp/improvement-loop
cd /tmp/improvement-loop
chmod +x install.sh
./install.sh /path/to/your/project
```

Or manually copy `.claude/` into your project root.

**Requirements:** `jq` (the installer auto-installs it on macOS/apt systems), plus whatever your gates need. The defaults use `node`/`npm`.

## Uninstall

```bash
./uninstall.sh /path/to/your/project
```

Removes hook scripts, state directory, and settings entries. Restores your `settings.json` backup if hooks were merged.

## Usage

```bash
# Start a session — hooks load automatically
claude

# Give Claude a task
> implement a user avatar upload endpoint with validation

# Claude works. After each "done" attempt, the Stop hook:
#   - Runs each gate command, passes if exit 0
#   - Scores the result (sum of passing gate weights)
#   - If required gates fail: feeds failures back, Claude continues
#   - If all required gates pass or iteration = 10: lets Claude stop
#   - Score history is recorded: [40, 60, 80, 100]
```

## Configuration

Edit `.claude/looper.json`:
```json
{
  "max_iterations": 10,
  "gates": [
    { "name": "typecheck", "command": "npx tsc --noEmit --pretty false", "weight": 30, "skip_if_missing": "tsconfig.json" },
    { "name": "lint",      "command": "npx eslint .",     "weight": 20, "skip_if_missing": "node_modules/.bin/eslint" },
    { "name": "test",      "command": "npm test",                        "weight": 30 },
    { "name": "coverage",  "command": "$LOOPER_HOOKS_DIR/check-coverage.sh", "weight": 20, "required": false }
  ],
  "checks": [
    { "name": "format",    "command": "npx prettier --check {file}", "fix": "npx prettier --write {file}", "pattern": "*.ts,*.tsx", "skip_if_missing": "node_modules/.bin/prettier" },
    { "name": "lint",      "command": "npx eslint {file}",                                                  "pattern": "*.ts,*.tsx", "skip_if_missing": "node_modules/.bin/eslint" },
    { "name": "typecheck", "command": "npx tsc --noEmit --pretty false",                                    "pattern": "*.ts,*.tsx", "skip_if_missing": "tsconfig.json" }
  ]
}
```

Replace the gate commands with whatever your stack uses. Any command that exits `0` on success works.

### Gate Options

Each gate supports these fields:

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

The loop completes when all required gates pass. Optional gates (`required: false`) are scored and reported but don't force additional iterations.

### Post-Edit Checks

The `checks` array configures fast per-file checks that run after each edit (PostToolUse). These give Claude immediate feedback without waiting for the Stop hook.

| Field | Default | Description |
|-------|---------|-------------|
| `name` | required | Check identifier |
| `command` | required | Shell command; `{file}` is replaced with the edited file path |
| `fix` | - | Auto-fix command run silently after a failing check |
| `pattern` | - | Comma-separated globs; check runs only on matching files |
| `skip_if_missing` | - | File/binary path; check skipped if absent |
| `enabled` | `true` | Set `false` to disable |

### Context and Coaching

Optional fields for customizing session context and feedback messaging:

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

- **`context`**: Array of strings injected into Claude's session context. Supports `{max_iterations}`, `{gate_count}`, `{branch}` substitution.
- **`discover`**: Key-value pairs where values are shell commands. Output replaces the default project discovery (git branch, node version, test files).
- **`coaching`**: Customizes the urgency messaging in the Stop hook. `urgency_at` sets the remaining-pass threshold (default 5), `on_failure` replaces the failure header, `on_budget_low` replaces the low-budget warning (`{remaining}` is substituted).

## Circuit Breakers

Three independent exit conditions prevent runaway loops:

1. **`stop_hook_active`**: Claude tried to stop, got pushed back,
   and is trying to stop again on the same turn. Let it go.
   Without this: infinite loop.

2. **`iteration >= MAX_ITERATIONS`**: hard budget cap. The PreToolUse
   hook also enforces this by blocking further edits.

3. **All required gates pass**: required gates (default) must pass for
   the loop to complete. Optional gates (`required: false`) are reported
   but don't block completion.

## How Feedback Flows

| Hook | When | Feedback channel | Claude sees |
|------|------|-----------------|-------------|
| SessionStart | once | stdout → context | project state, loop rules, gate list |
| PreToolUse | per edit | JSON additionalContext | "Pass 3/10. Editing: src/foo.ts" |
| PostToolUse | per edit | stdout → context | per-file lint/type errors |
| Stop | per attempt | stderr → feedback | gate results + specific failures |


>
>#### Built By
> Claude & Srdjan
>

## License

MIT
