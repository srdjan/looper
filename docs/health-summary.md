# Health Summary

## Achievement

Started from "find the next best feature" on an existing Claude Code plugin
with a bash kernel, one bundled package, and an emerging TypeScript SDK. Built
6 features across 6 evolution cycles:

1. **Baseline-aware gating**: `quality-gates` captures a pass/fail snapshot at
   SessionStart and classifies Stop failures as pre-existing or introduced.
   Only introduced failures cost iteration budget.

2. **scope-guard package**: second bundled package that prevents Claude from
   editing files outside a declared scope. Uses PreToolUse blocking and
   post-phase Stop evaluation. First production package built with the
   TypeScript SDK, proving the full authoring pipeline.

3. **Session summaries and `/looper:status`**: persistent session history in
   `sessions.jsonl`. Each completed or budget-exhausted session leaves a JSON
   summary. `/looper:status` exposes history, aggregate stats, and current
   config.

4. **Adaptive coaching and recommendations**: shared recommendation rules now
   power both `/looper:status` and Stop-time `Suggestions:` output. Looper can
   now suggest enabling baseline, tuning `max_iterations`, or adding
   `scope-guard` based on recent local session history.

5. **Failure provenance**: `quality-gates` now records per-pass traces in
   `passes.jsonl` and uses them to explain when a gate first went red and which
   files changed on or since that pass. The same signal appears in Stop feedback
   as `PROVENANCE:` and in `/looper:status` as `Failure Introduction Points:`.

6. **Cross-session learning (loop-memory)**: new SDK-authored package that mines
   accumulated quality-gates data to inject predictive context into future
   sessions. Computes gate difficulty profiles, file-gate failure correlations,
   convergence shape, and oscillation patterns. First cross-package data
   consumer in the ecosystem.

Additionally:

- SDK scaffolder emits all four hook wrappers
- `sdk-hello` remains as a reference SDK package
- `acceptance-flows` runs post-core behavior verification
- Legacy migration clutter was removed during cleanup passes

## Test Results

- Shell integration tests: `220/220` passing
- SDK unit tests: `44/44` passing (17 existing + 27 loop-memory)
- TypeScript type-checking: `deno task sdk:check` passes
- Repo formatting check: `deno task check` currently fails on formatting in `site/index.html`
- Shell hook wrappers: executable and exercised in integration tests

## Project Inventory

| Component | Notes |
|-----------|-------|
| Kernel | Bash dispatcher plus package state helpers |
| quality-gates | Core package with gates, checks, baseline support, session summaries, adaptive suggestions, and failure provenance traces |
| loop-memory | SDK-authored core-phase package for cross-session learning from quality-gates history |
| scope-guard | SDK-authored bundled package for edit-scope enforcement |
| acceptance-flows | SDK-authored bundled package for post-core behavior verification |
| SDK | TypeScript runtime, CLI, state bridge, scaffold generator, and test harness |
| sdk-hello | Minimal bundled reference package for SDK compatibility |
| Commands | `bootstrap`, `doctor`, `status`, and `looper-config` command/skill docs |
| Tests | Shell integration suite plus SDK unit tests |
| Docs | Design, user guide, architecture, evolution log, health summary |

## What to Watch

- **Baseline capture latency**: running all gates at SessionStart still adds
  wall-clock time. If users report slow startup, tighten `baseline_timeout` or
  add a fast-path for obviously slow gates.

- **Recommendation noise**: the heuristics are intentionally conservative,
  but they can still become repetitive if projects have unusual session shapes.
  The threshold rules in
  [recommendations.sh](/packages/quality-gates/lib/recommendations.sh)
  are the main tuning point.

- **Pass trace growth**: `passes.jsonl` is append-only within each project and
  stores one row per Stop evaluation. Still small for normal use, but it grows
  faster than `sessions.jsonl`.

- **loop-memory correlation accuracy**: file-gate correlations are based on
  co-occurrence, not causation. A file that appears in many passes may show
  spurious correlations. The `correlation_threshold` and `MIN_CORRELATION_SAMPLES`
  constants in `mining.ts` are the tuning points.

- **loop-memory cold start**: projects with fewer than `min_sessions` completed
  sessions get no context injection. The default of 3 is conservative; heavy
  users may want to lower it to 2.

- **Scope-guard glob matching**: the current TypeScript matcher handles common
  `*`, `**`, and `?` patterns but not full gitignore-style semantics. If users
  report surprising scope decisions, start in
  [mod.ts](/packages/scope-guard/mod.ts).

- **Session history growth**: `sessions.jsonl` is still tiny for normal use,
  but it remains append-only. If Looper sees heavy automated usage, rotation or
  truncation may become worth adding.

- **SDK Deno dependency**: SDK-authored packages require Deno on the host.
  Acceptable today, but clearer startup diagnostics would reduce confusion for
  users who install Looper without Deno.

When you're ready to iterate again, invoke the project-loop skill and it can
resume from the docs and state file.
