import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { testHook } from "../../sdk/typescript/testing.ts";
import definition from "./mod.ts";
import {
  computeConvergenceShape,
  computeFileCorrelations,
  computeGateProfiles,
  computeOscillationPatterns,
  parsePassTraces,
  parseSessionSummaries,
} from "./mining.ts";
import type { PassTrace, SessionSummary } from "./mining.ts";
import { formatContextBlock, formatFileWarning } from "./format.ts";

// ── Test Fixtures ────────────────────────────────────────

const makePass = (
  overrides: Partial<PassTrace> & { session_id: string; pass: number },
): PassTrace => ({
  score: 0,
  total: 100,
  files: [],
  gates: {},
  ...overrides,
});

const makeSession = (
  overrides: Partial<SessionSummary> & { status: string },
): SessionSummary => ({
  iteration: 1,
  max_iterations: 10,
  score: 100,
  total: 100,
  ...overrides,
});

// ── Pure Function Tests: Parsing ─────────────────────────

Deno.test("parsePassTraces: filters invalid entries", () => {
  const raw = [
    { session_id: "s1", pass: 1, score: 50, total: 100, files: [], gates: {} },
    "not an object",
    { session_id: "", pass: 1 }, // empty session_id filtered
    null,
  ];
  const result = parsePassTraces(raw);
  assertEquals(result.length, 1);
  assertEquals(result[0].session_id, "s1");
});

Deno.test("parseSessionSummaries: filters invalid entries", () => {
  const raw = [
    { status: "complete", iteration: 2, max_iterations: 10, score: 80, total: 100 },
    { status: "", iteration: 1 }, // empty status filtered
    42,
  ];
  const result = parseSessionSummaries(raw);
  assertEquals(result.length, 1);
  assertEquals(result[0].status, "complete");
});

// ── Pure Function Tests: Gate Profiles ───────────────────

Deno.test("computeGateProfiles: computes failure rates", () => {
  const passes: PassTrace[] = [
    makePass({
      session_id: "s1",
      pass: 1,
      gates: {
        lint: { status: "fail", required: true },
        test: { status: "pass", required: true },
      },
    }),
    makePass({
      session_id: "s1",
      pass: 2,
      gates: {
        lint: { status: "pass", required: true },
        test: { status: "pass", required: true },
      },
    }),
  ];
  const profiles = computeGateProfiles(passes);
  const lint = profiles.find((p) => p.gate === "lint");
  const test = profiles.find((p) => p.gate === "test");
  assertEquals(lint?.failureRate, 0.5);
  assertEquals(test?.failureRate, 0);
});

Deno.test("computeGateProfiles: skips preexisting status", () => {
  const passes: PassTrace[] = [
    makePass({
      session_id: "s1",
      pass: 1,
      gates: {
        lint: { status: "preexisting", required: true },
        test: { status: "fail", required: true },
      },
    }),
  ];
  const profiles = computeGateProfiles(passes);
  // lint should not appear (only preexisting entries)
  const lint = profiles.find((p) => p.gate === "lint");
  assertEquals(lint, undefined);
  const test = profiles.find((p) => p.gate === "test");
  assertEquals(test?.failureRate, 1);
});

Deno.test("computeGateProfiles: computes avg iterations to pass", () => {
  const passes: PassTrace[] = [
    makePass({
      session_id: "s1",
      pass: 1,
      gates: { lint: { status: "fail", required: true } },
    }),
    makePass({
      session_id: "s1",
      pass: 2,
      gates: { lint: { status: "fail", required: true } },
    }),
    makePass({
      session_id: "s1",
      pass: 3,
      gates: { lint: { status: "pass", required: true } },
    }),
    makePass({
      session_id: "s2",
      pass: 1,
      gates: { lint: { status: "pass", required: true } },
    }),
  ];
  const profiles = computeGateProfiles(passes);
  const lint = profiles.find((p) => p.gate === "lint");
  // Session s1: first pass at 3, Session s2: first pass at 1 => avg = 2
  assertEquals(lint?.avgIterationsToPass, 2);
});

Deno.test("computeGateProfiles: empty passes returns empty", () => {
  assertEquals(computeGateProfiles([]).length, 0);
});

// ── Pure Function Tests: File Correlations ───────────────

Deno.test("computeFileCorrelations: detects file-gate association", () => {
  const passes: PassTrace[] = [
    makePass({
      session_id: "s1",
      pass: 1,
      files: ["src/auth.ts"],
      gates: { test: { status: "fail", required: true } },
    }),
    makePass({
      session_id: "s2",
      pass: 1,
      files: ["src/auth.ts"],
      gates: { test: { status: "fail", required: true } },
    }),
    makePass({
      session_id: "s3",
      pass: 1,
      files: ["src/auth.ts"],
      gates: { test: { status: "fail", required: true } },
    }),
  ];
  const corr = computeFileCorrelations(passes, 0.3);
  assertEquals(corr.length, 1);
  assertEquals(corr[0].filePattern, "src/auth.ts");
  assertEquals(corr[0].gate, "test");
  assertEquals(corr[0].failureRate, 1);
  assertEquals(corr[0].sampleSize, 3);
});

Deno.test("computeFileCorrelations: filters below threshold", () => {
  const passes: PassTrace[] = [
    makePass({
      session_id: "s1",
      pass: 1,
      files: ["src/app.ts"],
      gates: { lint: { status: "pass", required: true } },
    }),
    makePass({
      session_id: "s2",
      pass: 1,
      files: ["src/app.ts"],
      gates: { lint: { status: "pass", required: true } },
    }),
    makePass({
      session_id: "s3",
      pass: 1,
      files: ["src/app.ts"],
      gates: { lint: { status: "fail", required: true } },
    }),
  ];
  // 1/3 = 0.33, threshold is 0.5
  const corr = computeFileCorrelations(passes, 0.5);
  assertEquals(corr.length, 0);
});

Deno.test("computeFileCorrelations: deduplicates by directory", () => {
  const passes: PassTrace[] = [];
  // Create 3 passes for each of 2 files in the same directory
  for (const file of ["src/auth/login.ts", "src/auth/register.ts"]) {
    for (let i = 0; i < 3; i++) {
      passes.push(
        makePass({
          session_id: `s${i}`,
          pass: 1,
          files: [file],
          gates: { test: { status: "fail", required: true } },
        }),
      );
    }
  }
  const corr = computeFileCorrelations(passes, 0.3);
  // Should collapse into a single src/auth/* pattern
  assertEquals(corr.length, 1);
  assertEquals(corr[0].filePattern, "src/auth/*");
  assertEquals(corr[0].sampleSize, 6);
});

Deno.test("computeFileCorrelations: empty passes returns empty", () => {
  assertEquals(computeFileCorrelations([], 0.3).length, 0);
});

// ── Pure Function Tests: Convergence ─────────────────────

Deno.test("computeConvergenceShape: computes rates correctly", () => {
  const sessions: SessionSummary[] = [
    makeSession({ status: "complete", iteration: 2 }),
    makeSession({ status: "complete", iteration: 4 }),
    makeSession({ status: "budget_exhausted", iteration: 10 }),
    makeSession({ status: "complete", iteration: 1 }),
  ];
  const shape = computeConvergenceShape(sessions);
  assertEquals(shape.completionRate, 0.75);
  assertEquals(shape.budgetExhaustionRate, 0.25);
  assertEquals(shape.avgIterations, (2 + 4 + 10 + 1) / 4);
});

Deno.test("computeConvergenceShape: empty sessions returns zeros", () => {
  const shape = computeConvergenceShape([]);
  assertEquals(shape.avgIterations, 0);
  assertEquals(shape.completionRate, 0);
  assertEquals(shape.budgetExhaustionRate, 0);
});

// ── Pure Function Tests: Oscillation ─────────────────────

Deno.test("computeOscillationPatterns: detects opposing gates", () => {
  // Two sessions with lint/test oscillating in opposition
  const makePasses = (sid: string): PassTrace[] => [
    makePass({
      session_id: sid,
      pass: 1,
      gates: {
        lint: { status: "pass", required: true },
        test: { status: "fail", required: true },
      },
    }),
    makePass({
      session_id: sid,
      pass: 2,
      gates: {
        lint: { status: "fail", required: true },
        test: { status: "pass", required: true },
      },
    }),
    makePass({
      session_id: sid,
      pass: 3,
      gates: {
        lint: { status: "pass", required: true },
        test: { status: "fail", required: true },
      },
    }),
    makePass({
      session_id: sid,
      pass: 4,
      gates: {
        lint: { status: "fail", required: true },
        test: { status: "pass", required: true },
      },
    }),
  ];

  const passes = [...makePasses("s1"), ...makePasses("s2")];
  const patterns = computeOscillationPatterns(passes);
  assertEquals(patterns.length, 1);
  assertEquals(patterns[0].gates.includes("lint"), true);
  assertEquals(patterns[0].gates.includes("test"), true);
  assertEquals(patterns[0].sessionCount, 2);
});

Deno.test("computeOscillationPatterns: ignores short sessions", () => {
  const passes: PassTrace[] = [
    makePass({
      session_id: "s1",
      pass: 1,
      gates: {
        lint: { status: "pass", required: true },
        test: { status: "fail", required: true },
      },
    }),
    makePass({
      session_id: "s1",
      pass: 2,
      gates: {
        lint: { status: "fail", required: true },
        test: { status: "pass", required: true },
      },
    }),
  ];
  // Only 2 passes - below threshold of 4
  assertEquals(computeOscillationPatterns(passes).length, 0);
});

// ── Pure Function Tests: Formatting ──────────────────────

Deno.test("formatContextBlock: healthy project is minimal", () => {
  const result = formatContextBlock(
    {
      gateProfiles: [],
      fileCorrelations: [],
      convergence: {
        avgIterations: 1.5,
        completionRate: 1,
        budgetExhaustionRate: 0,
      },
      oscillations: [],
    },
    8,
    18,
  );
  assertEquals(result !== null, true);
  assertEquals(result!.includes("No recurring issues"), true);
  assertEquals(result!.split("\n").length <= 4, true);
});

Deno.test("formatContextBlock: includes hardest gate", () => {
  const result = formatContextBlock(
    {
      gateProfiles: [
        { gate: "test", failureRate: 0.6, avgIterationsToPass: 3 },
        { gate: "lint", failureRate: 0.1, avgIterationsToPass: 1 },
      ],
      fileCorrelations: [],
      convergence: {
        avgIterations: 3,
        completionRate: 0.7,
        budgetExhaustionRate: 0.3,
      },
      oscillations: [],
    },
    10,
    18,
  );
  assertEquals(result !== null, true);
  assertEquals(result!.includes("Hardest gate: test"), true);
  assertEquals(result!.includes("60%"), true);
});

Deno.test("formatContextBlock: includes watch list", () => {
  const result = formatContextBlock(
    {
      gateProfiles: [],
      fileCorrelations: [
        { filePattern: "src/auth/*", gate: "test", failureRate: 0.8, sampleSize: 5 },
      ],
      convergence: {
        avgIterations: 3,
        completionRate: 0.8,
        budgetExhaustionRate: 0.2,
      },
      oscillations: [],
    },
    10,
    18,
  );
  assertEquals(result !== null, true);
  assertEquals(result!.includes("Watch list:"), true);
  assertEquals(result!.includes("src/auth/*"), true);
});

Deno.test("formatContextBlock: respects maxLines", () => {
  const result = formatContextBlock(
    {
      gateProfiles: [
        { gate: "test", failureRate: 0.6, avgIterationsToPass: 3 },
      ],
      fileCorrelations: [
        { filePattern: "a.ts", gate: "test", failureRate: 0.9, sampleSize: 5 },
        { filePattern: "b.ts", gate: "test", failureRate: 0.8, sampleSize: 5 },
        { filePattern: "c.ts", gate: "test", failureRate: 0.7, sampleSize: 5 },
        { filePattern: "d.ts", gate: "test", failureRate: 0.6, sampleSize: 5 },
      ],
      convergence: {
        avgIterations: 4,
        completionRate: 0.5,
        budgetExhaustionRate: 0.5,
      },
      oscillations: [
        { gates: ["lint", "test"], sessionCount: 3 },
      ],
    },
    20,
    8,
  );
  assertEquals(result !== null, true);
  assertEquals(result!.split("\n").length <= 8, true);
});

Deno.test("formatFileWarning: returns warning for matching file", () => {
  const warning = formatFileWarning(
    "src/auth/login.ts",
    [{ filePattern: "src/auth/*", gate: "test", failureRate: 0.8, sampleSize: 5 }],
    0.3,
  );
  assertEquals(warning !== null, true);
  assertEquals(warning!.includes("loop-memory:"), true);
  assertEquals(warning!.includes("test"), true);
  assertEquals(warning!.includes("80%"), true);
});

Deno.test("formatFileWarning: returns null for non-matching file", () => {
  const warning = formatFileWarning(
    "src/utils.ts",
    [{ filePattern: "src/auth/*", gate: "test", failureRate: 0.8, sampleSize: 5 }],
    0.3,
  );
  assertEquals(warning, null);
});

Deno.test("formatFileWarning: returns null below threshold", () => {
  const warning = formatFileWarning(
    "src/auth/login.ts",
    [{ filePattern: "src/auth/*", gate: "test", failureRate: 0.2, sampleSize: 5 }],
    0.3,
  );
  assertEquals(warning, null);
});

// ── Hook Integration Tests ───────────────────────────────

const defaultConfig = {
  minSessions: 3,
  maxContextLines: 18,
  lookbackSessions: 20,
  correlationThreshold: 0.3,
  enableFileWarnings: true,
};

Deno.test("sessionStart: cold start returns empty", async () => {
  const result = await testHook(definition, {
    hook: "session-start",
    config: { ...defaultConfig, minSessions: 3 },
  });
  assertEquals(result.exitCode, 0);
  assertEquals(result.stdout, "");
});

Deno.test("preToolUse: allows when no priors cached", async () => {
  const result = await testHook(definition, {
    hook: "pre-tool-use",
    config: defaultConfig,
    input: { tool_name: "Edit", tool_input: { file_path: "src/auth.ts" } },
  });
  assertEquals(result.exitCode, 0);
});

Deno.test("preToolUse: allows when file warnings disabled", async () => {
  const result = await testHook(definition, {
    hook: "pre-tool-use",
    config: { ...defaultConfig, enableFileWarnings: false },
    state: {
      computedAt: "2026-01-01T00:00:00Z",
      sessionCount: 5,
      priors: {
        gateProfiles: [],
        fileCorrelations: [
          { filePattern: "src/auth.ts", gate: "test", failureRate: 0.9, sampleSize: 5 },
        ],
        convergence: { avgIterations: 3, completionRate: 0.7, budgetExhaustionRate: 0.3 },
        oscillations: [],
      },
    },
    input: { tool_name: "Edit", tool_input: { file_path: "src/auth.ts" } },
  });
  assertEquals(result.exitCode, 0);
});

Deno.test("preToolUse: emits context for correlated file", async () => {
  const result = await testHook(definition, {
    hook: "pre-tool-use",
    config: { ...defaultConfig, correlationThreshold: 0.3 },
    state: {
      computedAt: "2026-01-01T00:00:00Z",
      sessionCount: 5,
      priors: {
        gateProfiles: [],
        fileCorrelations: [
          { filePattern: "src/auth.ts", gate: "test", failureRate: 0.9, sampleSize: 5 },
        ],
        convergence: { avgIterations: 3, completionRate: 0.7, budgetExhaustionRate: 0.3 },
        oscillations: [],
      },
    },
    input: { tool_name: "Edit", tool_input: { file_path: "src/auth.ts" } },
  });
  assertEquals(result.exitCode, 0);
  // The context should be in the JSON output on stdout
  assertEquals(result.stdout.includes("loop-memory:"), true);
});

Deno.test("preToolUse: no context for uncorrelated file", async () => {
  const result = await testHook(definition, {
    hook: "pre-tool-use",
    config: { ...defaultConfig, correlationThreshold: 0.3 },
    state: {
      computedAt: "2026-01-01T00:00:00Z",
      sessionCount: 5,
      priors: {
        gateProfiles: [],
        fileCorrelations: [
          { filePattern: "src/auth.ts", gate: "test", failureRate: 0.9, sampleSize: 5 },
        ],
        convergence: { avgIterations: 3, completionRate: 0.7, budgetExhaustionRate: 0.3 },
        oscillations: [],
      },
    },
    input: { tool_name: "Edit", tool_input: { file_path: "src/utils.ts" } },
  });
  assertEquals(result.exitCode, 0);
  assertEquals(result.stdout.includes("loop-memory:"), false);
});

Deno.test("config defaults: parseConfig produces expected defaults", async () => {
  const result = await testHook(definition, {
    hook: "session-start",
    config: defaultConfig,
  });
  // Should not error with default config
  assertEquals(result.exitCode, 0);
});
