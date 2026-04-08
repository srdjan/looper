import {
  createScaffoldFiles,
  defineConfig,
  definePackage,
  defineState,
  runShell,
  testHook,
} from "./mod.ts";
import {
  assertEquals,
  assertMatch,
  assertStringIncludes,
} from "jsr:@std/assert";

const parseConfig = (raw: unknown): { readonly message: string } => {
  const record = typeof raw === "object" && raw !== null
    ? raw as Record<string, unknown>
    : {};
  return {
    message: typeof record.message === "string"
      ? record.message
      : "hello from sdk",
  };
};

const parseState = (raw: unknown): { readonly runs: number } => {
  const record = typeof raw === "object" && raw !== null
    ? raw as Record<string, unknown>
    : {};
  return {
    runs: typeof record.runs === "number" ? record.runs : 0,
  };
};

const examplePackage = definePackage({
  config: defineConfig(parseConfig),
  state: defineState({ runs: 0 }, parseState),
  sessionStart: ({ config }) => `message=${config.message}`,
  preToolUse: () => ({
    decision: "allow",
    context: "typed pre-tool-use context",
  }),
  stop: async ({ runCommand, state }) => {
    const command = await runCommand({ command: ["echo", "ok"] });
    const next = await state.update((current) => ({ runs: current.runs + 1 }));
    return {
      decision: "continue",
      feedback: `${command.stdout.trim()}:${next.runs}`,
    } as const;
  },
});

Deno.test({
  name: "session-start maps string output to stdout",
  fn: async () => {
    const result = await testHook(examplePackage, {
      hook: "session-start",
      config: { message: "from test" },
    });

    assertEquals(result.exitCode, 0);
    assertEquals(result.stdout, "message=from test");
    assertEquals(result.stderr, "");
    assertEquals(result.state.runs, 0);
  },
});

Deno.test({
  name: "pre-tool-use serializes the Claude hook payload",
  fn: async () => {
    const result = await testHook(examplePackage, {
      hook: "pre-tool-use",
      config: { message: "ignored" },
    });

    assertEquals(result.exitCode, 0);
    assertMatch(result.stdout, /"hookEventName":"PreToolUse"/);
    assertMatch(result.stdout, /"permissionDecision":"allow"/);
    assertMatch(result.stdout, /typed pre-tool-use context/);
  },
});

Deno.test({
  name: "stop uses mocked commands and persists state",
  fn: async () => {
    const result = await testHook(examplePackage, {
      hook: "stop",
      config: { message: "ignored" },
      commands: [{
        command: ["echo", "ok"],
        result: {
          ok: true,
          code: 0,
          stdout: "ok\n",
          stderr: "",
        },
      }],
    });

    assertEquals(result.exitCode, 2);
    assertEquals(result.stdout, "");
    assertEquals(result.stderr, "ok:1");
    assertEquals(result.state.runs, 1);
  },
});

Deno.test("runShell wraps shell commands in bash -lc", async () => {
  const result = await runShell(
    async (request) => {
      assertEquals(request.command, ["bash", "-lc", "printf ok"]);
      assertEquals(request.timeoutMs, 2500);
      return {
        ok: true,
        code: 0,
        stdout: "ok",
        stderr: "",
      };
    },
    "printf ok",
    { timeoutMs: 2500 },
  );

  assertEquals(result.ok, true);
  assertEquals(result.stdout, "ok");
});

Deno.test("scaffold creates kernel-compatible files", () => {
  const files = createScaffoldFiles({ packageName: "demo-sdk-package" });

  assertStringIncludes(
    files["hooks/session-start.sh"],
    "sdk/typescript/cli.ts",
  );
  assertStringIncludes(files["hooks/stop.sh"], "sdk/typescript/cli.ts");
  assertStringIncludes(files["mod.ts"], "definePackage");
  assertMatch(files["package.json"], /"name": "demo-sdk-package"/);
});
