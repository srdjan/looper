import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { testHook } from "../../sdk/typescript/testing.ts";
import definition from "./mod.ts";

Deno.test("sessionStart: shows blocked and allowed patterns", async () => {
  const result = await testHook(definition, {
    hook: "session-start",
    config: { blocked: ["*.lock", ".env*"], allowed: ["src/**/*"] },
  });
  assertEquals(result.exitCode, 0);
  assertEquals(result.stdout.includes("Blocked files"), true);
  assertEquals(result.stdout.includes("*.lock"), true);
  assertEquals(result.stdout.includes("Allowed files"), true);
  assertEquals(result.stdout.includes("src/**/*"), true);
});

Deno.test("sessionStart: empty config returns null", async () => {
  const result = await testHook(definition, {
    hook: "session-start",
    config: { blocked: [], allowed: [] },
  });
  assertEquals(result.exitCode, 0);
  assertEquals(result.stdout, "");
});

Deno.test("preToolUse: blocks file matching blocked pattern", async () => {
  const result = await testHook(definition, {
    hook: "pre-tool-use",
    config: { blocked: ["package-lock.json", ".env*"], allowed: [] },
    input: { tool_name: "Edit", tool_input: { file_path: "package-lock.json" } },
  });
  assertEquals(result.exitCode, 2);
});

Deno.test("preToolUse: allows file not matching blocked pattern", async () => {
  const result = await testHook(definition, {
    hook: "pre-tool-use",
    config: { blocked: ["package-lock.json"], allowed: [] },
    input: { tool_name: "Edit", tool_input: { file_path: "src/app.ts" } },
  });
  assertEquals(result.exitCode, 0);
});

Deno.test("preToolUse: blocks glob pattern match", async () => {
  const result = await testHook(definition, {
    hook: "pre-tool-use",
    config: { blocked: [".env*"], allowed: [] },
    input: { tool_name: "Edit", tool_input: { file_path: ".env.local" } },
  });
  assertEquals(result.exitCode, 2);
});

Deno.test("preToolUse: allows when no file path in input", async () => {
  const result = await testHook(definition, {
    hook: "pre-tool-use",
    config: { blocked: ["*.lock"], allowed: [] },
    input: { tool_name: "Bash", tool_input: { command: "ls" } },
  });
  assertEquals(result.exitCode, 0);
});

Deno.test("stop: done when no allowed patterns configured", async () => {
  const result = await testHook(definition, {
    hook: "stop",
    config: { blocked: [], allowed: [] },
  });
  assertEquals(result.exitCode, 0);
});
