---
description: Verify looper installation and run a health check
allowed-tools: Bash(jq:*), Bash(bash:*), Bash(test:*), Bash(command:*), Bash(timeout:*), Bash(gtimeout:*), Read, Glob, AskUserQuestion
---

# Looper Bootstrap

Run a health check that verifies dependencies, config, and gate availability.

## Steps

1. **Dependency check** - run `jq --version` and report the result. If jq is not found, print install instructions (macOS: `brew install jq`, Debian/Ubuntu: `sudo apt install jq`, Fedora: `sudo dnf install jq`) and stop here.

2. **Config check** - check if `.claude/looper.json` exists.
   - If it exists, read it and extract the stack name (infer from the gate commands or note "custom config") and the list of gate names.
   - If it does not exist, tell the user: "No config found. The kernel auto-detects your stack on the next session start. Run `/looper:looper-config` for guided configuration instead." Then stop here.

3. **Gate dry-run** - for each gate in `.claude/looper.json` under `quality-gates.gates`, check availability:
   - If the gate has `skip_if_missing`, check if that file/binary exists. If absent, mark the gate as "o skipped (tool not found)".
   - If the gate has `enabled: false`, mark it as "o disabled".
   - Otherwise, run the gate command with a 5-second timeout. Use `timeout 5` (or `gtimeout 5` on macOS if `timeout` is not available). Report:
     - Exit 0: "v available"
     - Non-zero exit: "x exit N" with a short hint (e.g., "check your test setup")
     - Timeout: "? timed out (verification only, 5s limit)"
   - For gates marked `required: false`, append "(optional)" to the status line.

4. **Print a compact summary** in this format:

```
Looper Health Check
  jq:         v installed (jq-1.7)
  Config:     v .claude/looper.json
  Gates:
    typecheck: v available
    lint:      v available
    test:      x exit 1 (check your test setup)
    coverage:  o skipped (optional)
```

5. **Actionable next steps** - based on the results:
   - If all required gates pass: "Ready to loop. Start a session and give Claude a task."
   - If any required gate fails: "Some gates are failing. Fix the issues above or adjust your config with /looper:looper-config."
   - Always mention: "Run /looper:doctor for a deeper comparison between your config and the repo's actual tooling."

## Rules

- Do not modify any files. This is a read-only diagnostic.
- Keep the gate dry-run timeout at 5 seconds. The goal is presence-checking, not full execution.
- If a gate command references `$LOOPER_PKG_DIR` or other Looper env vars that are not available in this context, mark the gate as "? cannot verify (requires active session)" instead of running it.
