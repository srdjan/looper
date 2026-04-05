# Evolution Log

## Iteration 1: Baseline-Aware Gating
- What changed: Added opt-in baseline capture to the quality-gates package. On SessionStart, all gates run before Claude makes changes to establish a pass/fail snapshot. On Stop, failures are classified as "pre-existing" (already broken at baseline, marked `~`) or "introduced" (Claude broke it, marked `x`). Only introduced failures force another iteration. Pre-existing failures appear as informational context.
- Primary metric: Reduction in wasted iterations spent on pre-existing failures
- Leading indicators: Sessions reaching "all pass" in fewer iterations; fewer budget-exhausted sessions on codebases with pre-existing issues
- Guardrails: No change to existing behavior when baseline is disabled (default); no masking of genuine regressions
- Frontier note: Frontier remains thick. Strong candidates for next cycle: TypeScript SDK for package authoring, a second bundled package to prove multi-package composition, session analytics for loop performance visibility.

## Iteration 2: scope-guard Package
- What changed: Added a second bundled package `scope-guard` that prevents Claude from editing files outside a declared scope. Uses PreToolUse to block edits to protected files in real time (first package-level PreToolUse handler), and Stop in the post phase to report scope compliance. Built with the TypeScript SDK, proving the SDK's full pipeline end-to-end: typed handlers, bash wrapper shims, kernel dispatch, multi-package composition. Also fixed the SDK scaffolder to generate wrappers for all four hooks.
- Primary metric: Number of out-of-scope file edits prevented per session
- Leading indicators: Multi-package composition validated with two real packages; PreToolUse blocking demonstrated at the package level; SDK authoring proven with a production package
- Guardrails: No interference with quality-gates; no blocking when no scope rules configured; no startup latency beyond config read
- Frontier note: Frontier thinning but still viable. Session analytics, adaptive coaching, and team features remain. The SDK + two real packages make a strong marketplace launch story.
