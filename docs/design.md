# Looper Design: Unlock the Package Ecosystem

## Current Product Read

Looper is not fundamentally a "run the test suite again" plugin. Its core idea
is stronger: turn Claude Code's stop moment into a programmable control loop.

Today the project already has a clear shape:

1. A thin bash kernel owns loop mechanics, state, budget, circuit breakers, and
   hook dispatch.
2. Packages own behavior. The bundled `quality-gates` package proves the model
   with gates, checks, coaching, and stack-aware defaults.
3. The docs consistently position Looper as a package platform, not just a
   quality-gate preset.

That philosophy is coherent and differentiated. The gap is that package
authoring is still raw bash and `jq`, which makes the ecosystem thesis much
harder to realize than the product story implies.

## Loop Envelope

```yaml
envelope: DESIGN_DECISION
problem: Looper's architecture promises an extensible package ecosystem, but the current package authoring model is shell-heavy and too costly for most package authors to adopt confidently.
user: Package authors and advanced Claude Code users who want to create new improvement loops beyond the bundled quality-gates package.
evidence:
  - The repo's kernel/package split is explicit across README, architecture docs, and the implementation.
  - The only bundled production package is quality-gates, while other package examples remain conceptual.
  - Current package authoring requires bash, jq state handling, manual stream routing, and eval-heavy command composition.
  - docs/sdk-design.md already captures real authoring pain and a plausible direction, which suggests the bottleneck has already surfaced in practice.
primary_metric: Number of non-bundled Looper packages that are created, tested, and used successfully in real projects.
leading_indicators:
  - Time for a new author to scaffold and run a first package
  - Number of package handlers covered by isolated tests
  - Number of example or community packages shipped on top of the SDK
guardrails:
  - Do not require kernel architecture changes for v1
  - Preserve compatibility with existing bash-authored packages
  - Keep hook startup overhead low enough that loop latency does not materially worsen
goals:
  - Make package authoring safe, typed, and testable
  - Turn Looper from a promising architecture into a real package platform
  - Preserve the current shell-first kernel and local-first philosophy
non_goals:
  - Rewriting the kernel in TypeScript or Python
  - Building a package marketplace or registry in this phase
  - Adding team analytics, billing, or licensing work
constraints:
  - The current product is a Claude Code plugin with a bash kernel and shell hook contracts
  - Existing docs and architecture emphasize package extensibility as the product thesis
  - The next addition should compound future work, not just add one more bespoke built-in package
scale:
  poc: TypeScript SDK plus scaffolder can create one reference package and run handler tests without touching the kernel contract.
  v1: Multiple first-party and third-party packages can be authored with the SDK while bash packages remain supported.
tradeoffs:
  - option: Build another first-party package next
    cost: Faster to demo in the short term, but each new package repeats the authoring pain.
    value: Adds one more capability for users immediately.
    notes: This strengthens the catalog but not the platform.
  - option: Build the package-authoring SDK first
    cost: Requires careful API design, test harness work, and one polished reference flow.
    value: Every future package becomes cheaper, safer, and easier to ship.
    notes: Best fit for the repo's stated philosophy.
  - option: Build a marketplace or registry first
    cost: High coordination and product complexity before authoring friction is solved.
    value: Distribution upside later.
    notes: Premature until package creation is materially easier.
open_questions:
  - Should v1 target TypeScript only, or include Python from the start?
  - Should the reference implementation port quality-gates, or ship as a smaller example package first?
  - Should scaffolding live as a Looper command, a standalone CLI, or both?
recommended_scope: Ship a TypeScript package-authoring SDK with typed handler returns, config and state schemas, safe command execution, a local test harness, and a scaffolder that emits kernel-compatible wrapper scripts.
frontier_assessment: The highest-leverage frontier is not another built-in check package; it is removing package-authoring friction so the ecosystem can exist in practice rather than only in architecture diagrams and docs.
first_move: Approve the SDK direction, then write docs/plan.md for a narrow v1 consisting of a TypeScript SDK core, handler test harness, scaffolder, and one reference package.
```

## Problem Statement

Looper already has a differentiated architecture: the kernel is minimal, and
behavior lives in packages. That is the right product shape. The missing piece
is that the project currently behaves like a platform in theory and like a
single-package product in practice.

If the next addition is just another built-in package, Looper gets a little
broader. If the next addition is a package-authoring SDK, Looper gets easier to
extend forever.

## Success Metrics

- Primary KPI: active non-bundled packages created with Looper's authoring
  tooling
- Leading indicators:
  - first package scaffolded and executed in under 15 minutes
  - handler logic tested without full kernel fixtures
  - at least one reference package proves the authoring flow end to end
- Guardrails:
  - no kernel rewrite
  - no regression for bash packages
  - no major slowdown in hook execution

## Goals and Non-Goals

### Goals

- Make package authoring dramatically simpler than writing raw bash handlers
- Preserve Looper's current kernel contract and shell-first runtime
- Create a compounding base for future packages such as security audits, TDD
  loops, docs verification, and browser-flow verification

### Non-Goals

- Expanding the built-in package catalog first
- Inventing a hosted service or registry now
- Adding commercial infrastructure now

## Trade-Offs and Recommendation

### Option A: another first-party package

This is tempting because it is visible. A `security-audit` or `doc-check`
package would make the README examples more concrete. But it does not solve the
platform bottleneck. It adds surface area without reducing future package cost.

### Option B: package-authoring SDK and scaffolder

This is the strongest move now. It improves safety, lowers the barrier to
entry, makes testing realistic, and multiplies the output of every future
package effort. It fits the project's philosophy better than any single new
package.

### Option C: registry or marketplace mechanics

Too early. Distribution only matters once authoring is tractable.

### Recommendation

Build the SDK first. Specifically: a TypeScript-first package-authoring kit
that keeps the bash kernel untouched while making handlers typed, testable, and
safe to execute.

## Architecture Overview

The recommended addition keeps today's boundaries intact:

- Bash kernel remains the only runtime Claude hooks call directly.
- SDK-authored packages generate thin bash wrapper scripts in `hooks/*.sh`.
- Handler authors write TypeScript functions that return typed results for
  `sessionStart`, `preToolUse`, `postToolUse`, and `stop`.
- The SDK handles stream routing, exit code mapping, config validation, state
  persistence, and shell-safe command execution.
- A test harness runs handlers outside the kernel by providing config, state,
  mocked commands, and hook input.

## Domain Model

- `KernelContract`
  - Hook event in
  - stdout, stderr, and exit code semantics out
- `PackageManifest`
  - package metadata
  - phase and matcher declarations
- `PackageConfigSchema`
  - validated package config shape
- `PackageStateSchema`
  - validated persisted state shape with defaults
- `HandlerResult`
  - typed return values that map to kernel protocol behavior
- `CommandRunner`
  - shell-safe execution for templated commands and timeouts

## Interface Contract

V1 should expose a small authoring surface:

- `definePackage(...)`
- `defineConfig(...)`
- `defineState(...)`
- typed handler functions for each hook
- test harness helpers for isolated handler execution
- scaffolder output:
  - `package.json`
  - generated `hooks/*.sh` wrappers
  - source entrypoints
  - a starter test file

## Assumptions

- The project's near-term success depends more on becoming extensible in
  practice than on adding one more built-in package.
- TypeScript is the right first SDK target because it balances developer reach,
  type safety, and parity with the existing docs direction.
- Preserving bash-package compatibility matters more than elegance.

## Open Questions

1. TypeScript only for v1, or TypeScript plus Python?
2. Port `quality-gates` as the proof point, or ship a smaller reference package
   first?
3. Should scaffolding be exposed as a Looper command, a separate CLI, or both?
