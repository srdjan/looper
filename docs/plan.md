## Implementation Plan

### Slice 1: Recommendation Rules Domain
- Files:
  - `packages/quality-gates/lib/recommendations.sh`
- Types:
  - recommendation categories encoded as stable rule ids
  - session-derived heuristics for baseline, budget, slow checks, and scope drift
- Dependencies:
  - none
- Tests:
  - shell fixture tests for recommendation rules fed with synthetic session/config inputs
- Estimated complexity:
  - moderate

### Slice 2: `/looper:status` Recommendations
- Files:
  - `commands/status.md`
- Types:
  - `status recommendation row` output shape
- Dependencies:
  - Slice 1
- Tests:
  - shell integration coverage for histories that should and should not emit recommendations
- Estimated complexity:
  - low

### Slice 3: Adaptive Stop Coaching
- Files:
  - `packages/quality-gates/hooks/stop.sh`
  - `packages/quality-gates/hooks/session-start.sh`
- Types:
  - none beyond Slice 1 rule ids
- Dependencies:
  - Slice 1
- Tests:
  - shell integration tests for repeated budget pressure, repeated introduced failures, and baseline-worthy sessions
- Estimated complexity:
  - moderate

### Slice 4: Repo Test and Task Integration
- Files:
  - `tests/test-suite.sh`
  - `deno.json`
- Types:
  - none
- Dependencies:
  - Slices 1 through 3
- Tests:
  - extend full shell suite with recommendation and adaptive-coaching assertions
  - keep existing SDK and package checks green
- Estimated complexity:
  - low

### Slice 5: Docs and Evolution Log
- Files:
  - `README.md`
  - `docs/user-guide.md`
  - `docs/evolution-log.md`
  - `.project-loop-state.md`
- Types:
  - none
- Dependencies:
  - Slices 1 through 4
- Tests:
  - verify command examples and recommendation descriptions stay aligned with implementation
- Estimated complexity:
  - low

### Integration
- Order constraints:
  - Slice 1 -> Slice 2
  - Slice 1 -> Slice 3
  - Slice 4 depends on Slices 1 through 3
  - Slice 5 depends on Slices 1 through 4
- Parallel-ready:
  - Slice 2 and Slice 3 can proceed in parallel once Slice 1 lands
- Integration test:
  - run histories that demonstrate budget exhaustion, recurring introduced failures, and successful baseline savings, then verify `/looper:status` and Stop feedback produce the same recommendation direction

### Dependency Graph

```text
Slice 1: Recommendation Rules Domain
  | \
  |  \
  v   v
Slice 2: /looper:status Recommendations
Slice 3: Adaptive Stop Coaching
  \   /
   \ /
    v
Slice 4: Repo Test and Task Integration
  |
  v
Slice 5: Docs and Evolution Log
```
