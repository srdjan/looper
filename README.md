# Agentic Improvement Loop

A Claude Code hooks-based workflow that runs quality gates after each response
and gives Claude another turn when they fail. Up to 10 passes, then it stops.

## Architecture

```
┌─ SessionStart ──────────────────────────────────────┐
│  Initialize state file: iteration=0, scores=[]      │
│  Inject project context into Claude's context       │
└──────────────────────┬─────────────────────────────-┘
                       ▼
            You: "implement feature X"
                       ▼
┌─ PreToolUse (Edit|Write) ───────────────────────────┐
│  Block if iteration >= 10 (budget exhausted)        │
│  Inject current iteration into Claude's context     │
└──────────────────────┬─────────────────────────────-┘
                       ▼
         Claude writes/edits files
                       ▼
┌─ PostToolUse (Edit|Write) ──────────────────────────┐
│  Run fast checks: format, lint                      │
│  Record per-file results to state                   │
└──────────────────────┬─────────────────────────────-┘
                       ▼
        Claude finishes its response
                       ▼
┌─ Stop ──────────────────────────────────────────────┐
│  Read state → current iteration                     │
│  if stop_hook_active == true → exit 0 (breaker)     │
│  if iteration >= 10          → exit 0 (budget)      │
│  Run quality suite:                                 │
│    typecheck → lint → test → coverage               │
│  Score the run (0-100)                              │
│  if score == 100             → exit 0 (done!)       │
│  else                                               │
│    increment iteration                              │
│    write feedback to stderr                         │
│    exit 2 → Claude gets another turn                │
└────────────────────────────────────────────────────-┘
```

## Files

```
.claude/
├── settings.json          # Hook configuration
├── hooks/
│   ├── hook-manifest.sh   # Shared hook file list (used by install, uninstall, tests)
│   ├── state-utils.sh     # State read/write functions
│   ├── session-start.sh   # Initialize state + inject context
│   ├── pre-edit-guard.sh  # Budget gate + iteration context
│   ├── post-edit-check.sh # Fast per-file quality checks
│   └── stop-improve.sh    # Improvement loop driver
└── state/
    └── loop-state.json    # Iteration counter + scores (gitignored)
tests/
└── test-suite.sh          # Shell tests for state-utils, install, uninstall
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

**Requirements:** `jq`, `node`/`npm` (for the quality gates).

## Uninstall

```bash
./uninstall.sh /path/to/your/project
```

Cleanly removes hook scripts, state directory, and settings entries.
Restores your `settings.json` backup if hooks were merged.

## Usage

```bash
# Start a session — hooks load automatically
claude

# Give Claude a task
> implement a user avatar upload endpoint with validation

# Claude works. After each "done" attempt, the Stop hook:
#   - Runs typecheck, lint, tests, coverage
#   - Scores the result (0-100)
#   - If < 100: feeds failures back, Claude continues
#   - If = 100 or iteration = 10: lets Claude stop
#   - Score history is recorded: [40, 60, 80, 100]
```

## Configuration

Edit `.claude/hooks/state-utils.sh`:
```bash
MAX_ITERATIONS=10  # change to any number
```

Edit `.claude/hooks/stop-improve.sh` to adjust gate weights:
```
typecheck = 30 points
lint      = 20 points
test      = 30 points
coverage  = 20 points
─────────────────────
total     = 100
```

## Circuit Breakers

Three independent exit conditions prevent runaway loops:

1. **`stop_hook_active`** — Claude tried to stop, got pushed back,
   and is trying to stop again on the same turn. Let it go.
   Without this: infinite loop.

2. **`iteration >= MAX_ITERATIONS`** — hard budget cap. The PreToolUse
   hook also enforces this by blocking further edits.

3. **`score == 100`** — all four quality gates pass. Mission complete.

## How Feedback Flows

| Hook | When | Feedback channel | Claude sees |
|------|------|-----------------|-------------|
| SessionStart | once | stdout → context | project state, loop rules |
| PreToolUse | per edit | JSON additionalContext | "Pass 3/10. Editing: src/foo.ts" |
| PostToolUse | per edit | stdout → context | per-file lint/type errors |
| Stop | per attempt | stderr → feedback | gate results + specific failures |

## License

MIT
