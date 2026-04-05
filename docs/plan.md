## Implementation Plan

### Slice 1: Session Record Domain
- Files:
  - `packages/session-analytics/mod.ts`
  - `packages/session-analytics/package.json`
- Types:
  - `SessionAnalyticsConfig`
  - `SessionRecord`
  - `PackageOutcome`
  - `BudgetOutcome`
- Dependencies:
  - none
- Tests:
  - SDK unit tests for config parsing and pure session-summary helpers
- Estimated complexity:
  - moderate

### Slice 2: SessionStart Context and State Capture
- Files:
  - `packages/session-analytics/mod.ts`
  - `packages/session-analytics/hooks/session-start.sh`
- Types:
  - `PreviousSessionSummary`
- Dependencies:
  - Slice 1
- Tests:
  - shell integration test proving previous-session context is shown at SessionStart
- Estimated complexity:
  - moderate

### Slice 3: Stop-Time Summary and Local Persistence
- Files:
  - `packages/session-analytics/mod.ts`
  - `packages/session-analytics/hooks/stop.sh`
- Types:
  - `CurrentSessionSummary`
  - `SessionHistory`
- Dependencies:
  - Slices 1 and 2
- Tests:
  - SDK unit tests for summary generation from kernel and package state
  - shell integration tests for complete, continue, and budget-exhausted sessions
- Estimated complexity:
  - moderate

### Slice 4: Cross-Package Insights
- Files:
  - `packages/session-analytics/mod.ts`
  - `tests/test-suite.sh`
- Types:
  - `TopCause`
  - `PackageInsight`
- Dependencies:
  - Slice 3
- Tests:
  - shell integration coverage across `quality-gates`, `scope-guard`, and `session-analytics`
  - assertions for blocked edits, pre-existing failures, and dominant continue cause
- Estimated complexity:
  - moderate

### Slice 5: Docs and Example Config
- Files:
  - `README.md`
  - `docs/user-guide.md`
  - `docs/evolution-log.md`
- Types:
  - none
- Dependencies:
  - Slices 1 through 4
- Tests:
  - verify config examples and commands remain consistent
- Estimated complexity:
  - low

### Integration
- Order constraints:
  - Slice 1 -> Slice 2 -> Slice 3 -> Slice 4 -> Slice 5
- Parallel-ready:
  - none worth splitting before Slice 3, because the package contract and summary shape are the critical path
- Integration test:
  - run a fixture with `quality-gates`, `scope-guard`, and `session-analytics`, then verify SessionStart shows the previous summary and Stop writes a correct local session record plus final report

### Dependency Graph

```text
Slice 1: Session Record Domain
  |
  v
Slice 2: SessionStart Context and State Capture
  |
  v
Slice 3: Stop-Time Summary and Local Persistence
  |
  v
Slice 4: Cross-Package Insights
  |
  v
Slice 5: Docs and Example Config
```
