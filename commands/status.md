---
description: Show loop session history and current state
allowed-tools: Bash(bash:*), Bash(jq:*), Bash(cat:*), Bash(wc:*), Bash(tail:*), Bash(test:*), Read
---

# Looper Status

Show the current loop state and recent session history.

## Steps

1. Run:

```bash
bash "$(claude plugin root looper)/packages/quality-gates/lib/status-report.sh"
```

2. Print the output directly if the script succeeds.

3. If the script is unavailable, fall back to the manual procedure below.

4. Check if `.claude/state/sessions.jsonl` exists. If not, say "No session history yet. Sessions are recorded after the first loop completes."

5. If it exists, read the last 10 sessions and display them as a table:

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

6. Show aggregate stats:

```
Summary:
  Total sessions: N
  Completed: N (N%)
  Budget exhausted: N (N%)
  Average iterations: N.N
  Iterations saved by baseline: N
```

7. If `.claude/state/session-current.json` exists, also show the in-progress session state:

```
Current session (in progress):
  Iteration: 3/10
  Score: 70/100
  Introduced failures: 1
  Pre-existing failures: 2
```

8. If `.claude/looper.json` exists, show the active configuration summary:

```
Config:
  Max iterations: 10
  Packages: quality-gates, scope-guard
  Baseline: enabled/disabled
  Gates: typecheck, lint, test, coverage
```

9. Add a `Recommendations:` section when the history or current state supports a concrete suggestion. Prefer only a few high-signal suggestions:

- enable baseline after repeated budget-exhausted sessions without baseline
- raise or lower `max_iterations` based on recent session patterns
- add `scope-guard` when the current session is touching many files without scope protection

10. If `.claude/state/quality-gates/passes.jsonl` exists, show a compact `Failure Introduction Points:` section for the most recent session only. Use at most 3 lines. Include the first failing pass and the files changed on that pass, or since the last green pass when the failure persists across multiple passes.
