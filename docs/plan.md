## Implementation Plan

### Slice 1: SDK Core Contract
- Files:
  - `sdk/typescript/mod.ts`
  - `sdk/typescript/types.ts`
- Types:
  - `SdkHook`
  - `PackageDefinition`
  - `SessionStartResult`
  - `PreToolUseResult`
  - `PostToolUseResult`
  - `StopResult`
  - `ConfigSchema<T>`
  - `StateSchema<T>`
- Dependencies:
  - none
- Tests:
  - Deno unit tests for typed return normalization and exhaustive hook routing
- Estimated complexity:
  - moderate

### Slice 2: Runtime Loader and State Bridge
- Files:
  - `sdk/typescript/runtime.ts`
  - `sdk/typescript/io.ts`
  - `sdk/typescript/state.ts`
  - `sdk/typescript/env.ts`
- Types:
  - `RuntimeEnv`
  - `RuntimeContext`
  - `StateStore<T>`
  - `HookExecution`
- Dependencies:
  - Slice 1
- Tests:
  - Deno unit tests for config loading, state persistence, and stream/exit-code mapping
- Estimated complexity:
  - moderate

### Slice 3: Test Harness
- Files:
  - `sdk/typescript/testing.ts`
  - `sdk/typescript/testing_test.ts`
- Types:
  - `TestHarnessInput`
  - `TestHarnessResult`
  - `MockCommand`
- Dependencies:
  - Slices 1 and 2
- Tests:
  - Deno unit tests for isolated handler execution with mocked command results
- Estimated complexity:
  - moderate

### Slice 4: Scaffolder and Reference Package
- Files:
  - `sdk/typescript/scaffold.ts`
  - `packages/sdk-hello/package.json`
  - `packages/sdk-hello/hooks/session-start.sh`
  - `packages/sdk-hello/hooks/stop.sh`
  - `packages/sdk-hello/mod.ts`
- Types:
  - `ScaffoldOptions`
- Dependencies:
  - Slices 1 and 2
- Tests:
  - Deno unit test for scaffold output shape
  - shell-level fixture test proving the example package executes through generated wrappers
- Estimated complexity:
  - moderate

### Slice 5: Kernel-Level Integration Test and Docs
- Files:
  - `tests/test-suite.sh`
  - `docs/sdk-design.md`
- Types:
  - none
- Dependencies:
  - Slices 1 through 4
- Tests:
  - extend `tests/test-suite.sh` with an SDK-authored package fixture
  - run `bash tests/test-suite.sh`
  - run `deno task sdk:check`
  - run `deno task sdk:test`
- Estimated complexity:
  - low

### Integration
- Order constraints:
  - Slice 1 -> Slice 2 -> Slice 3
  - Slice 4 depends on Slices 1 and 2
  - Slice 5 depends on Slices 1 through 4
- Parallel-ready:
  - Slice 3 and Slice 4 can proceed in parallel once Slice 2 lands
- Integration test:
  - execute a generated example package through Looper's existing shell hook contract and verify stream routing plus stop semantics

### Dependency Graph

```text
Slice 1: SDK Core Contract
  |
  v
Slice 2: Runtime Loader and State Bridge
  | \
  |  \
  v   v
Slice 3: Test Harness   Slice 4: Scaffolder and Reference Package
  \                     /
   \                   /
    v                 v
     Slice 5: Kernel-Level Integration Test and Docs
```
