import {
  defineConfig,
  definePackage,
  defineState,
  matchesAny,
  runShell,
} from "../../sdk/typescript/mod.ts";
import type {
  RuntimeEnv,
  StateStore,
  StopResult,
} from "../../sdk/typescript/types.ts";

type FlowConfig = {
  readonly name: string;
  readonly command: string;
  readonly timeout: number;
  readonly runWhen: readonly string[];
  readonly required: boolean;
  readonly enabled: boolean;
};

type AcceptanceConfig = {
  readonly tailLines: number;
  readonly flows: readonly FlowConfig[];
};

type FlowStatus = "pass" | "fail" | "timeout" | "skipped";

type FlowResult = {
  readonly command: string;
  readonly durationMs: number;
  readonly exitCode: number | null;
  readonly required: boolean;
  readonly skippedReason: string | null;
  readonly status: FlowStatus;
  readonly stderrPath: string | null;
  readonly stdoutPath: string | null;
  readonly summary: string;
  readonly timestamp: string;
};

type AcceptanceState = {
  readonly results: Readonly<Record<string, FlowResult>>;
  readonly runs: number;
};

const DEFAULT_TIMEOUT_SECONDS = 120;
const DEFAULT_TAIL_LINES = 40;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null;

const asStringArray = (value: unknown): readonly string[] =>
  Array.isArray(value)
    ? value.filter((entry): entry is string => typeof entry === "string")
    : [];

const positiveInteger = (value: unknown, fallback: number): number =>
  typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : fallback;

const parseFlow = (raw: unknown): FlowConfig | null => {
  if (!isRecord(raw)) return null;

  const name = typeof raw.name === "string" ? raw.name.trim() : "";
  const command = typeof raw.command === "string" ? raw.command.trim() : "";
  const runWhen = Array.isArray(raw.run_when) ? raw.run_when : raw.runWhen;
  if (name.length === 0 || command.length === 0) {
    return null;
  }

  return {
    name,
    command,
    timeout: positiveInteger(raw.timeout, DEFAULT_TIMEOUT_SECONDS),
    runWhen: asStringArray(runWhen),
    required: raw.required !== false,
    enabled: raw.enabled !== false,
  };
};

const parseConfig = (raw: unknown): AcceptanceConfig => {
  const record = isRecord(raw) ? raw : {};
  const flows = Array.isArray(record.flows)
    ? record.flows.map(parseFlow).filter((flow): flow is FlowConfig =>
      flow !== null
    )
    : [];

  return {
    tailLines: positiveInteger(
      record.tail_lines ?? record.tailLines,
      DEFAULT_TAIL_LINES,
    ),
    flows,
  };
};

const parseFlowResult = (raw: unknown): FlowResult | null => {
  if (!isRecord(raw)) return null;
  const status = raw.status;
  if (
    status !== "pass" && status !== "fail" && status !== "timeout" &&
    status !== "skipped"
  ) {
    return null;
  }

  return {
    command: typeof raw.command === "string" ? raw.command : "",
    durationMs:
      typeof raw.durationMs === "number" && Number.isFinite(raw.durationMs)
        ? raw.durationMs
        : 0,
    exitCode: typeof raw.exitCode === "number" && Number.isFinite(raw.exitCode)
      ? raw.exitCode
      : null,
    required: raw.required !== false,
    skippedReason: typeof raw.skippedReason === "string"
      ? raw.skippedReason
      : null,
    status,
    stderrPath: typeof raw.stderrPath === "string" ? raw.stderrPath : null,
    stdoutPath: typeof raw.stdoutPath === "string" ? raw.stdoutPath : null,
    summary: typeof raw.summary === "string" ? raw.summary : "",
    timestamp: typeof raw.timestamp === "string" ? raw.timestamp : "",
  };
};

const parseState = (raw: unknown): AcceptanceState => {
  const record = isRecord(raw) ? raw : {};
  const rawResults = isRecord(record.results) ? record.results : {};
  const results = Object.fromEntries(
    Object.entries(rawResults)
      .map(([name, value]) => [name, parseFlowResult(value)] as const)
      .filter((entry): entry is readonly [string, FlowResult] =>
        entry[1] !== null
      ),
  );

  return {
    results,
    runs: typeof record.runs === "number" && Number.isFinite(record.runs)
      ? record.runs
      : 0,
  };
};


const readFilesTouched = async (
  env: RuntimeEnv,
): Promise<readonly string[]> => {
  try {
    const kernelText = await Deno.readTextFile(`${env.stateDir}/kernel.json`);
    const kernel = JSON.parse(kernelText) as Record<string, unknown>;
    return Array.isArray(kernel.files_touched)
      ? kernel.files_touched.filter((file): file is string =>
        typeof file === "string"
      )
      : [];
  } catch {
    return [];
  }
};

const slugify = (value: string): string =>
  value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") ||
  "flow";

const artifactDisplayPath = (
  env: RuntimeEnv,
  relativePath: string | null,
): string | null =>
  relativePath === null ? null : `.claude/state/${env.pkgName}/${relativePath}`;

const artifactRelativePath = (
  slug: string,
  stream: "stdout" | "stderr",
): string => `artifacts/${slug}.${stream}.log`;

const writeArtifacts = async (
  env: RuntimeEnv,
  slug: string,
  stdout: string,
  stderr: string,
): Promise<{ readonly stdoutPath: string; readonly stderrPath: string }> => {
  const artifactsDir = `${env.pkgStateDir}/artifacts`;
  await Deno.mkdir(artifactsDir, { recursive: true });

  const stdoutPath = artifactRelativePath(slug, "stdout");
  const stderrPath = artifactRelativePath(slug, "stderr");

  await Deno.writeTextFile(`${env.pkgStateDir}/${stdoutPath}`, stdout);
  await Deno.writeTextFile(`${env.pkgStateDir}/${stderrPath}`, stderr);

  return { stdoutPath, stderrPath };
};

const tailLines = (text: string, lineCount: number): string => {
  if (text.trim().length === 0) {
    return "";
  }
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  const normalized = lines.at(-1) === "" ? lines.slice(0, -1) : lines;
  return normalized.slice(-lineCount).join("\n");
};

const formatDuration = (durationMs: number): string =>
  durationMs >= 10_000
    ? `${Math.round(durationMs / 1000)}s`
    : `${(durationMs / 1000).toFixed(1)}s`;

const renderSummaryLine = (
  symbol: string,
  name: string,
  detail: string,
): string => `  ${symbol} ${name}: ${detail}`;

const recordSkippedFlow = (flow: FlowConfig): FlowResult => ({
  command: flow.command,
  durationMs: 0,
  exitCode: null,
  required: flow.required,
  skippedReason: "no matching files changed",
  status: "skipped",
  stderrPath: null,
  stdoutPath: null,
  summary: renderSummaryLine(
    "o",
    flow.name,
    "skipped - no matching files changed",
  ),
  timestamp: new Date().toISOString(),
});

const renderFailureBlock = (
  env: RuntimeEnv,
  flowName: string,
  result: FlowResult,
  excerpt: string,
): string => {
  const lines = [`-- ${flowName} --`];
  if (excerpt.length > 0) {
    lines.push(excerpt);
  } else if (result.status === "timeout") {
    lines.push("Command timed out without producing output.");
  } else {
    lines.push("Command failed without producing output.");
  }

  const stdoutPath = artifactDisplayPath(env, result.stdoutPath);
  const stderrPath = artifactDisplayPath(env, result.stderrPath);
  if (stdoutPath !== null || stderrPath !== null) {
    lines.push("");
    lines.push("Artifacts:");
    if (stdoutPath !== null) lines.push(`  stdout: ${stdoutPath}`);
    if (stderrPath !== null) lines.push(`  stderr: ${stderrPath}`);
  }

  return lines.join("\n");
};

const persistResults = async (
  state: StateStore<AcceptanceState>,
  results: Readonly<Record<string, FlowResult>>,
): Promise<void> => {
  await state.set({
    runs: state.get().runs + 1,
    results,
  });
};

const buildStopFeedback = (
  summaryLines: readonly string[],
  requiredBlocks: readonly string[],
  optionalBlocks: readonly string[],
): string => {
  const sections = ["acceptance-flows:", ...summaryLines];
  if (requiredBlocks.length > 0) {
    sections.push("", "Required flow failures:", ...requiredBlocks);
  }
  if (optionalBlocks.length > 0) {
    sections.push(
      "",
      "Optional flow failures (non-blocking):",
      ...optionalBlocks,
    );
  }
  return sections.join("\n");
};

export default definePackage({
  config: defineConfig(parseConfig),
  state: defineState({ runs: 0, results: {} }, parseState),

  sessionStart: ({ config }) => {
    const flows = config.flows.filter((flow) => flow.enabled);
    if (flows.length === 0) {
      return null;
    }

    const lines = [
      "## Acceptance Flows",
      "",
      "After core quality gates pass, Looper will run these behavior checks:",
    ];

    for (const flow of flows) {
      lines.push(
        `  - ${flow.name} [${
          flow.required ? "required" : "optional"
        }] - ${flow.command}`,
      );
      if (flow.runWhen.length > 0) {
        lines.push(`    run_when: ${flow.runWhen.join(", ")}`);
      }
    }

    return lines.join("\n");
  },

  stop: async ({ config, env, runCommand, state }) => {
    const flows = config.flows.filter((flow) => flow.enabled);
    if (flows.length === 0) {
      return { decision: "done" };
    }

    const filesTouched = await readFilesTouched(env);
    const results: Record<string, FlowResult> = {};
    const summaryLines: string[] = [];
    const requiredBlocks: string[] = [];
    const optionalBlocks: string[] = [];
    let requiredFailureCount = 0;

    for (const flow of flows) {
      if (
        flow.runWhen.length > 0 &&
        !filesTouched.some((path) => matchesAny(path, flow.runWhen))
      ) {
        const skipped = recordSkippedFlow(flow);
        results[flow.name] = skipped;
        summaryLines.push(skipped.summary);
        continue;
      }

      const startedAt = Date.now();
      const commandResult = await runShell(runCommand, flow.command, {
        cwd: env.cwd,
        timeoutMs: flow.timeout * 1000,
      });
      const durationMs = Date.now() - startedAt;
      const artifactPaths = await writeArtifacts(
        env,
        slugify(flow.name),
        commandResult.stdout,
        commandResult.stderr,
      );

      const status: FlowStatus = commandResult.ok
        ? "pass"
        : commandResult.code === 124
        ? "timeout"
        : "fail";

      const detail = status === "pass"
        ? `pass (${formatDuration(durationMs)})`
        : status === "timeout"
        ? `timed out after ${flow.timeout}s${
          flow.required ? "" : " [optional]"
        }`
        : `failed (exit ${commandResult.code}, ${formatDuration(durationMs)})${
          flow.required ? "" : " [optional]"
        }`;

      const flowResult: FlowResult = {
        command: flow.command,
        durationMs,
        exitCode: commandResult.ok ? 0 : commandResult.code,
        required: flow.required,
        skippedReason: null,
        status,
        stderrPath: artifactPaths.stderrPath,
        stdoutPath: artifactPaths.stdoutPath,
        summary: renderSummaryLine(
          status === "pass" ? "v" : "x",
          flow.name,
          detail,
        ),
        timestamp: new Date().toISOString(),
      };

      results[flow.name] = flowResult;
      summaryLines.push(flowResult.summary);

      if (status !== "pass") {
        const excerpt = tailLines(
          commandResult.stderr.trim().length > 0
            ? commandResult.stderr
            : commandResult.stdout,
          config.tailLines,
        );
        const block = renderFailureBlock(env, flow.name, flowResult, excerpt);
        if (flow.required) {
          requiredFailureCount += 1;
          requiredBlocks.push(block);
        } else {
          optionalBlocks.push(block);
        }
      }
    }

    await persistResults(state, results);

    const feedback = buildStopFeedback(
      summaryLines,
      requiredBlocks,
      optionalBlocks,
    );
    if (requiredFailureCount > 0) {
      return { decision: "continue", feedback } satisfies StopResult;
    }

    return { decision: "done", feedback } satisfies StopResult;
  },
});
