---
description: Show loop session history and current state
allowed-tools: Bash(jq:*), Bash(cat:*), Bash(wc:*), Bash(tail:*), Bash(test:*), Read
---

# Looper Status

Show the current loop state and recent session history.

## Steps

1. Check if `.claude/state/sessions.jsonl` exists. If not, say "No session history yet. Sessions are recorded after the first loop completes."

2. If it exists, read the last 10 sessions and display them as a table:

```
Session History (last N sessions):

  #  Status            Iters  Score   Baseline  Timestamp
  1  complete          3/10   100/100  2 saved  2025-04-05T14:30:00Z
  2  budget_exhausted  10/10  70/100   0 saved  2025-04-05T12:15:00Z
  3  complete          1/10   100/100  -        2025-04-04T09:00:00Z
```

Build the table from the JSONL data using jq. For each line:
- Status: `.status`
- Iters: `.iteration` / `.max_iterations`
- Score: `.score` / `.total`
- Baseline: if `.preexisting_failures` > 0, show "N saved", otherwise "-"
- Timestamp: `.timestamp`

3. Show aggregate stats:

```
Summary:
  Total sessions: N
  Completed: N (N%)
  Budget exhausted: N (N%)
  Average iterations: N.N
  Iterations saved by baseline: N
```

4. If `.claude/state/session-current.json` exists, also show the in-progress session state:

```
Current session (in progress):
  Iteration: 3/10
  Score: 70/100
  Introduced failures: 1
  Pre-existing failures: 2
```

5. If `.claude/looper.json` exists, show the active configuration summary:

```
Config:
  Max iterations: 10
  Packages: quality-gates, scope-guard
  Baseline: enabled/disabled
  Gates: typecheck, lint, test, coverage
```
