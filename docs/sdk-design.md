# Looper SDK: Polyglot Package Authoring

## Context

Building Looper packages today requires raw bash: jq wrangling for config/state, TSV parsing loops, unsafe `eval` for command templates, manual stdout/stderr routing per hook type, and no way to unit test handlers without the full kernel fixture. This is fine for the bundled quality-gates package but creates a steep barrier for the package ecosystem to grow.

The idea: a typed SDK per language (TypeScript, Python) that wraps the kernel's handler contract in an ergonomic API. Package authors write functions that return typed values; the SDK handles I/O routing, config validation, state atomicity, and command safety. The bash kernel stays untouched.

## What the SDK solves

| Pain point | Bash today | SDK |
|---|---|---|
| Config reading | `pkg_config '.gates // []'` - returns untyped JSON, null on typo | Zod/Pydantic schema - validated at startup, typed access |
| State management | mktemp + jq + mv atomic pattern, repeated manually | `state.set('scores', [...])` - atomic writes handled internally |
| Output routing | SessionStart=stdout, Stop=stderr, PreToolUse=JSON. Mix them up and feedback disappears | Return typed values (`Done`, `Continue`, `Allow`, `Block`). SDK routes to correct stream |
| Command execution | `eval "${cmd//\{file\}/$FILE}"` - injection risk | `exec(template, { file: shellEscape(path) })` |
| Testing | Full kernel fixture: temp dirs, 9 env vars, stdin pipes, exit code capture | `testHandler(myStop, { config: {...}, mockCommands: {...} })` |
| Cross-package state | `pkg_read` returns string "null" on missing data | Typed `readPackageState()` returns `T | null` |

## API design: TypeScript

```typescript
import { definePackage, defineConfig, defineState } from "@anthropic/looper-sdk";
import { z } from "zod";

const config = defineConfig(z.object({
  scanCommand: z.string().default("npm audit --json"),
  severityThreshold: z.enum(["low", "moderate", "high", "critical"]).default("high"),
}));

const state = defineState(
  z.object({ findings: z.array(z.string()), lastScan: z.string().nullable() }),
  { findings: [], lastScan: null }
);

export default definePackage({ config, state }, {

  sessionStart({ env, config }) {
    return `## Security Audit\nScan: ${config.get("scanCommand")}`;
  },

  preToolUse({ env, input }) {
    if (input.toolInput.filePath?.includes("secrets"))
      return { decision: "block", reason: "Protected file." };
    return { decision: "allow", context: `Pass ${env.iteration}/${env.maxIterations}` };
  },

  postToolUse({ env, config, input }) {
    const file = input.toolInput.filePath;
    if (!file) return null;
    const result = exec(`ruff check ${shellEscape(file)}`);
    return result.ok ? `ok ${file}` : `${file}: issues found`;
  },

  stop({ env, config, state }) {
    const result = runWithTimeout(60, config.get("scanCommand"));
    if (result.ok) {
      state.set("findings", []);
      return { decision: "done", feedback: "Security scan: clean." };
    }
    const findings = parseAuditOutput(result.stdout);
    state.set("findings", findings.map(f => f.name));
    return {
      decision: "continue",
      feedback: findings.map(f => `  - ${f.name}: ${f.title}`).join("\n"),
    };
  },
});
```

Key types that the handler author sees:

- `sessionStart` returns `string` (injected into Claude's context via stdout)
- `preToolUse` returns `{ decision: "allow", context? } | { decision: "block", reason }` (SDK emits JSON to stdout, sets exit code)
- `postToolUse` returns `string | null` (SDK writes to stdout)
- `stop` returns `{ decision: "done", feedback? } | { decision: "continue", feedback }` (SDK writes feedback to stderr, sets exit code)

The handler never touches `process.stdout`, `process.stderr`, or `process.exit`. The SDK does all routing.

## API design: Python

```python
from looper_sdk import handler, define_config, define_state, exec_cmd, Allow, Block, Done, Continue
from pydantic import BaseModel

class Config(BaseModel):
    scan_command: str = "npm audit --json"
    severity_threshold: str = "high"

class State(BaseModel):
    findings: list[str] = []

config = define_config(Config)
state = define_state(State)

@handler("session_start")
def session_start(env, cfg: Config, st: State):
    return f"## Security Audit\nScan: {cfg.scan_command}"

@handler("stop")
def stop(env, cfg: Config, st: State, input):
    result = exec_cmd(cfg.scan_command)
    if result.ok:
        st.findings = []
        return Done(feedback="Security scan: clean.")
    findings = parse_audit(result.stdout)
    st.findings = [f.name for f in findings]
    return Continue(feedback="\n".join(f"  - {f.name}" for f in findings))
```

Same idea, Pythonic idioms: Pydantic for schemas, decorators for handler registration, dataclasses for return types.

## How handlers get invoked (zero kernel changes)

Each SDK handler ships with a thin bash wrapper that the kernel calls normally:

```bash
#!/usr/bin/env bash
exec deno run --allow-all "$LOOPER_PKG_DIR/hooks/stop.ts"
```

The kernel sees `stop.sh` and runs it with `bash`. The wrapper immediately `exec`s into the SDK runtime. The scaffolding CLI generates these wrappers. Package authors never edit them.

## Testing without the kernel

The biggest value-add. Current testing requires full kernel fixtures. The SDK provides:

```typescript
import { testHandler } from "@anthropic/looper-sdk/testing";
import myPackage from "./mod.ts";

Deno.test("continues when audit finds vulnerabilities", async () => {
  const result = await testHandler(myPackage, "stop", {
    config: { scanCommand: "npm audit --json", severityThreshold: "high" },
    state: { findings: [], lastScan: null },
    env: { iteration: 0, maxIterations: 10 },
    mockCommands: {
      "npm audit --json": { exitCode: 1, stdout: '{"vulnerabilities":[{"name":"lodash","severity":"high"}]}' },
    },
  });
  assertEquals(result.decision, "continue");
  assertEquals(result.state.findings, ["lodash"]);
});
```

Mock command support means handlers are testable without running real tools. The test harness validates config against the Zod schema, initializes state from defaults, and captures the typed return value.

## Novelty assessment

**Genuinely novel:**

1. **Per-hook output routing abstraction.** No other plugin system has four different I/O semantics (stdout-as-context, stderr-as-feedback, JSON-as-hook-response, exit-code-as-vote) for the same plugin depending on which hook fires. The SDK's return-type-to-stream mapping is unique to Looper's architecture.

2. **Polyglot SDK over a bash kernel.** The kernel stays bash. TypeScript and Python are authoring layers that compile down to the same exit-code-and-stream contract. This "bash runtime, typed authoring" pattern is uncommon. Most SDKs target a single runtime.

3. **Command-level mock testing for shell-executing handlers.** The combination of schema-validated config, typed state, and per-command mocking for handlers that invoke arbitrary shell commands does not exist in other plugin SDKs.

**Not novel (table stakes):** Zod/Pydantic for validation, config readers, state managers, handler registration patterns. These exist in every plugin SDK.

**Comparison to closest analogues:**
- VS Code Extension API: typed, event-driven, but runs in a managed Node runtime. Looper handlers are one-shot subprocesses.
- Terraform Provider SDK: schema-driven CRUD with test framework. Closest in spirit, but Terraform providers are long-running gRPC servers.
- GitHub Actions SDK: typed inputs/outputs per step, but no state management or feedback routing.

The novelty is in the specific combination: typed handlers over a shell protocol, with stream-aware routing and command-level test mocking.

## Business model

**Free (open source, MIT):**
- The bash kernel, bundled quality-gates package, all documentation
- Bash package authoring with pkg-utils.sh
- The handler contract specification (so anyone can build their own SDK)

**Two monetization options:**

Option A - SDK is paid:
- TypeScript SDK (`@anthropic/looper-sdk`) and Python SDK (`looper-sdk`) are proprietary
- Scaffolding CLI, test harness, safe command execution
- Targets package authors (small audience, high willingness to pay)

Option B - SDK is open source, team features are paid:
- SDK is MIT, grows the package ecosystem faster
- Paid tier is team/org features: shared package registries, cross-project coaching analytics, team-wide gate enforcement
- Larger addressable market, network effects

**Recommendation: Option B.** The SDK audience (people building Looper packages) is small. Making the SDK free grows the ecosystem, which makes the team tier more valuable. The SDK becomes a growth lever, not a revenue stream.

## Implementation scope (if proceeding)

| Phase | Work | Duration |
|---|---|---|
| 1. TypeScript SDK core | Types, runtime, config/state, I/O router, exec safety | 2 weeks |
| 2. Test harness | testHandler, mock commands, reference tests | 1 week |
| 3. Port quality-gates | Rewrite the bundled package in TypeScript as proof | 1 week |
| 4. Python SDK | Mirror API with Pydantic, decorators | 2 weeks |
| 5. CLI + docs | `looper-sdk init`, scaffolding, documentation | 1 week |
