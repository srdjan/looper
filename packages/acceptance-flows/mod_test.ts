import {
  assertEquals,
  assertMatch,
  assertStringIncludes,
} from "jsr:@std/assert";
import { testHook } from "../../sdk/typescript/testing.ts";
import definition from "./mod.ts";

Deno.test("sessionStart shows configured flows", async () => {
  const result = await testHook(definition, {
    hook: "session-start",
    config: {
      tailLines: 40,
      flows: [
        {
          name: "api-smoke",
          command: "npm run smoke:api",
          timeout: 120,
          runWhen: [],
          required: true,
          enabled: true,
        },
        {
          name: "docs-preview",
          command: "./docs.sh",
          timeout: 120,
          runWhen: [],
          required: false,
          enabled: true,
        },
      ],
    },
  });

  assertEquals(result.exitCode, 0);
  assertStringIncludes(result.stdout, "Acceptance Flows");
  assertStringIncludes(result.stdout, "api-smoke [required]");
  assertStringIncludes(result.stdout, "docs-preview [optional]");
});

Deno.test("stop continues when a required flow fails", async () => {
  const result = await testHook(definition, {
    hook: "stop",
    config: {
      tailLines: 40,
      flows: [
        {
          name: "api-smoke",
          command: "npm run smoke:api",
          timeout: 120,
          runWhen: [],
          required: true,
          enabled: true,
        },
      ],
    },
    commands: [{
      command: ["bash", "-lc", "npm run smoke:api"],
      result: {
        ok: false,
        code: 1,
        stdout: "",
        stderr: "api smoke failed\ntrace line\n",
      },
    }],
  });

  assertEquals(result.exitCode, 2);
  assertMatch(result.stderr, /Required flow failures:/);
  assertEquals(result.state.runs, 1);
  assertEquals(result.state.results["api-smoke"]?.status, "fail");
  assertEquals(
    result.state.results["api-smoke"]?.stdoutPath,
    "artifacts/api-smoke.stdout.log",
  );
});

Deno.test("stop reports optional flow failures as non-blocking", async () => {
  const result = await testHook(definition, {
    hook: "stop",
    config: {
      tailLines: 40,
      flows: [
        {
          name: "docs-preview",
          command: "./docs.sh",
          timeout: 120,
          runWhen: [],
          required: false,
          enabled: true,
        },
      ],
    },
    commands: [{
      command: ["bash", "-lc", "./docs.sh"],
      result: {
        ok: false,
        code: 1,
        stdout: "",
        stderr: "preview failed\n",
      },
    }],
  });

  assertEquals(result.exitCode, 0);
  assertMatch(result.stderr, /Optional flow failures \(non-blocking\):/);
  assertEquals(result.state.results["docs-preview"]?.status, "fail");
});

Deno.test("stop marks timeouts distinctly", async () => {
  const result = await testHook(definition, {
    hook: "stop",
    config: {
      tailLines: 40,
      flows: [
        {
          name: "slow-flow",
          command: "./slow.sh",
          timeout: 15,
          runWhen: [],
          required: true,
          enabled: true,
        },
      ],
    },
    commands: [{
      command: ["bash", "-lc", "./slow.sh"],
      result: {
        ok: false,
        code: 124,
        stdout: "",
        stderr: "",
      },
    }],
  });

  assertEquals(result.exitCode, 2);
  assertEquals(result.state.results["slow-flow"]?.status, "timeout");
  assertMatch(result.stderr, /timed out after 15s/);
});

Deno.test("stop skips run_when flows when touched files do not match", async () => {
  const result = await testHook(definition, {
    hook: "stop",
    config: {
      tailLines: 40,
      flows: [
        {
          name: "browser-smoke",
          command: "npm run smoke:web",
          timeout: 120,
          runWhen: ["src/web/**/*"],
          required: true,
          enabled: true,
        },
      ],
    },
  });

  assertEquals(result.exitCode, 0);
  assertEquals(result.state.results["browser-smoke"]?.status, "skipped");
  assertMatch(result.stderr, /skipped - no matching files changed/);
});
