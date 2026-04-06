# Looper and the Case for Native Control Loops in Claude Code

Most people discover the same problem in same way...

Claude Code can edit files, run tools, and reason about a codebase. What it does not do by default is stay inside a quality loop until the work meets the project's standard. Most teams fill that gap with habit, they run commands, copy errors, and ask for one more fix. Some build wrappers around the CLI. Some script an outer loop that watches files or replays failures. All of those approaches can help, but they share the same limit: they live outside the session.

Looper takes a different position. It is not an external harness around Claude Code. It is a native control loop inside Claude Code.

Claude Code already has a hook lifecycle. A plugin can run code at session start, before a tool call, after a tool call, and when Claude tries to stop. Looper is built directly on those native control points: `SessionStart`, `PreToolUse`, `PostToolUse`, and `Stop`. That gives it powers an external wrapper does not have.

At `SessionStart`, Looper can tell Claude the rules of the loop before any code is written. It can say: you have ten passes, these are the active gates, this one is required, this one is optional, this is the stack, this is the local context that matters. The loop starts with shared state instead of guesswork.

At `PreToolUse`, Looper can inspect the action before it happens. That matters for budget enforcement and for packages like `scope-guard`. An external wrapper can notice that a protected file was edited after the fact. Looper can block the edit before it lands.

At `PostToolUse`, Looper can run lightweight checks while Claude is still in the middle of the task. Formatting, single-file linting, and fast checks can feed back within seconds. That is a different rhythm from waiting until the end, dumping a pile of failures into the conversation, and asking Claude to unwind them.

At `Stop`, Looper can decide whether Claude is actually done. It can run typecheck, lint, tests, and any other package-defined criteria. If a required gate fails, Claude does not need a human to relay the output. The loop continues on its own.

If you want an agent to improve its own work, the loop should live where the work already happens.

That is why Looper is more interesting than a collection of shell scripts. The shell is only the implementation detail. The real idea is native control. Looper is close enough to Claude Code to enforce rules in real time, but simple enough that the control plane stays readable.

The architecture follows that decision. The kernel is small. It owns state, budget, circuit breakers, handler dispatch, and package resolution. It does not know what "quality" means for your project. Packages define that. The default `quality-gates` package handles the common case: typecheck, lint, test, coverage, per-file checks, coaching, baseline capture, and session summaries. Other packages can add different constraints without changing the kernel.

That separation matters because the job of a loop kernel is not to be smart. It is to be reliable.

A good control loop needs a few properties.

First, it needs a clear budget. Looper does not pretend it can detect perfect convergence. It gives Claude a fixed number of passes and stops cleanly when the budget is exhausted.

Second, it needs observability. Looper keeps local state, records session summaries, and exposes `/looper:status` so users can see what happened across sessions.

Third, it needs to distinguish signal from noise. Baseline-aware gating handles pre-existing failures so Claude does not waste passes trying to fix a test that was already broken before the session began.

Fourth, it needs boundaries. `scope-guard` exists because agent autonomy without edit scope is reckless in a real repository.

Fifth, it needs to fail honestly. If a configured package depends on a runtime that is missing, Looper blocks the session instead of silently skipping the package and pretending the protection is active.

Those are practical requirements, not ideology. If you use agents on production code, you need a loop that tells the truth.

The other important choice in Looper is that it is local and explicit.

Configuration lives in `.claude/looper.json`. State lives in `.claude/state/`. Packages are directories with a manifest and a few handlers. You can override a bundled package in the project, or install one at the user level, without forking the kernel. This is closer to Unix than to platform theater. Files are readable. Behavior is inspectable. If something goes wrong, you can open the state file and see what the loop thinks is happening.

That makes the system easier to trust. Trust does not come from saying "AI-powered" louder. It comes from making control surfaces legible.

This is also where Looper departs from a lot of agent tooling. Many agent products want to hide the machinery. They sell flow and magic. Looper does the opposite. It keeps the kernel small, keeps the contracts visible, and makes the package model explicit. You can explain the whole system to another engineer without hand-waving.

That does not make it less ambitious. It makes the ambition credible.

The long-term value of Looper is not just that it can rerun tests for Claude. Plenty of tools can rerun tests. The value is that it establishes Claude Code as a programmable environment with native control loops. Once that exists, "quality gates" is just the first package. You can enforce scope. You can push TDD habits. You can check docs drift. You can gate on security tools. You can surface recommendations from session history. The kernel does not need to become a product encyclopedia. It just needs to make package composition reliable.

An external wrapper can supervise. A native loop can participate.

Supervision is useful, but participation is stronger. Participation means Claude sees the rules before it starts. Participation means edits can be blocked before they happen. Participation means stop conditions are evaluated at the moment Claude claims it is done. Participation means the feedback path is part of the same session rather than a second system stapled onto the side.

It treats Claude Code not as a chat box that occasionally writes files, but as an environment with control points. It uses those control points to close the gap between "the code looks finished" and "the work is actually done."

That gap is where most of the real cost lives.

Looper reduces that cost by making the feedback loop native.
