# Health Summary

## Achievement

Started from "find the next best feature" on an existing Claude Code plugin
with a bash kernel, one bundled package, and an emerging TypeScript SDK. Built
5 features across 5 evolution cycles:

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

Additionally:

- SDK scaffolder now emits all four hook wrappers
- `sdk-hello` remains as a reference SDK package
- legacy migration clutter was removed during the cleanup pass

## Test Results

- Shell integration tests: `203/203` passing
- SDK unit tests: `17/17` passing
- TypeScript type-checking: `deno task sdk:check` passes
- Repo formatting check: `deno task check` currently fails on formatting in `site/index.html`
- Shell hook wrappers: executable and exercised in integration tests

## Project Inventory

| Component | Notes |
|-----------|-------|
| Kernel | Bash dispatcher plus package state helpers |
| quality-gates | Core package with gates, checks, baseline support, session summaries, adaptive suggestions, and failure provenance traces |
| scope-guard | SDK-authored bundled package for edit-scope enforcement |
| SDK | TypeScript runtime, CLI, state bridge, scaffold generator, and test harness |
| sdk-hello | Minimal bundled reference package for SDK compatibility |
| Commands | `bootstrap` and `status` command docs |
| Tests | Shell integration suite plus SDK unit tests |
| Docs | Design, user guide, architecture, evolution log, health summary |

## What to Watch

- **Baseline capture latency**: running all gates at SessionStart still adds
  wall-clock time. If users report slow startup, tighten `baseline_timeout` or
  add a fast-path for obviously slow gates.

- **Recommendation noise**: the new heuristics are intentionally conservative,
  but they can still become repetitive if projects have unusual session shapes.
  The threshold rules in
  [recommendations.sh](/Users/srdjans/Code/looper/packages/quality-gates/lib/recommendations.sh)
  are the main tuning point.

- **Pass trace growth**: `passes.jsonl` is append-only within each project and
  now stores one row per Stop evaluation. That is still small for normal use,
  but it grows faster than `sessions.jsonl`.

- **Scope-guard glob matching**: the current TypeScript matcher handles common
  `*`, `**`, and `?` patterns but not full gitignore-style semantics. If users
  report surprising scope decisions, start in
  [mod.ts](/Users/srdjans/Code/looper/packages/scope-guard/mod.ts).

- **Session history growth**: `sessions.jsonl` is still tiny for normal use,
  but it remains append-only. If Looper sees heavy automated usage, rotation or
  truncation may become worth adding.

- **SDK Deno dependency**: SDK-authored packages require Deno on the host.
  That is acceptable today, but clearer startup diagnostics would reduce
  confusion for users who install Looper without Deno.

When you're ready to iterate again, invoke the project-loop skill and it can
resume from the docs and state file.
