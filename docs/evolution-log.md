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

## Iteration 3: Session Summaries and /looper:status
- What changed: Added session summary persistence. Each completed session appends a JSON summary line to `.claude/state/sessions.jsonl` recording status, iterations, score, baseline savings, and timestamp. Budget-exhausted sessions are captured via `session-current.json` and promoted to the log on the next SessionStart. Added `/looper:status` command for viewing session history, aggregate stats, and current config.
- Primary metric: Users have access to per-session loop summaries showing whether Looper is helping
- Leading indicators: Session data persists across sessions; config tuning becomes data-driven
- Guardrails: No hook path slowdown; summary-only (no full gate output); local-first, no external services
- Frontier note: Adaptive coaching remained as the next smallest useful step because the analytics layer existed but was not yet actionable.

## Iteration 4: Adaptive Coaching and Recommendations
- What changed: Added a shared recommendation engine in `packages/quality-gates/lib/recommendations.sh`, a `status-report.sh` renderer behind `/looper:status`, and adaptive `Suggestions:` output in failing quality-gates Stop feedback. Recommendations are local-first and read-only, covering cases like enabling baseline, tuning `max_iterations`, and adding `scope-guard`.
- Primary metric: Users receive concrete, situation-aware next steps instead of raw session history only
- Leading indicators: `/looper:status` surfaces recommendations on real history; failing sessions emit short suggestion blocks; recommendation logic stays consistent between status and Stop output
- Guardrails: No config auto-mutation; no remote telemetry; recommendation output stays small and only appears when signal is strong enough
- Frontier note: Frontier is now very thin. The core local-first loop, package SDK, multi-package control, analytics, and recommendations are all in place. Remaining work should be driven by real usage rather than more speculative features.
