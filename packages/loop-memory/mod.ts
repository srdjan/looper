import {
  defineConfig,
  definePackage,
  defineState,
} from "../../sdk/typescript/mod.ts";
import type { ComputedPriors } from "./mining.ts";
import { computePriors, isRecord } from "./mining.ts";
import { formatContextBlock, formatFileWarning } from "./format.ts";

type MemoryConfig = {
  readonly minSessions: number;
  readonly maxContextLines: number;
  readonly lookbackSessions: number;
  readonly correlationThreshold: number;
  readonly enableFileWarnings: boolean;
};

type MemoryState = {
  readonly computedAt: string | null;
  readonly sessionCount: number;
  readonly priors: ComputedPriors | null;
};

const positiveNumber = (value: unknown, fallback: number): number =>
  typeof value === "number" && Number.isFinite(value) && value > 0
    ? value
    : fallback;

const parseConfig = (raw: unknown): MemoryConfig => {
  const record = isRecord(raw) ? raw : {};
  return {
    minSessions: Math.floor(
      positiveNumber(record.min_sessions ?? record.minSessions, 3),
    ),
    maxContextLines: Math.floor(
      positiveNumber(record.max_context_lines ?? record.maxContextLines, 18),
    ),
    lookbackSessions: Math.floor(
      positiveNumber(
        record.lookback_sessions ?? record.lookbackSessions,
        20,
      ),
    ),
    correlationThreshold: positiveNumber(
      record.correlation_threshold ?? record.correlationThreshold,
      0.3,
    ),
    enableFileWarnings:
      (record.enable_file_warnings ?? record.enableFileWarnings) !== false,
  };
};

const parseState = (raw: unknown): MemoryState => {
  const record = isRecord(raw) ? raw : {};
  return {
    computedAt:
      typeof record.computedAt === "string" ? record.computedAt : null,
    sessionCount:
      typeof record.sessionCount === "number" ? record.sessionCount : 0,
    // Priors are written by this package's own sessionStart handler, so the
    // shape is trusted. If the file is corrupt, the worst case is a stale or
    // nonsensical context block for one session.
    priors: isRecord(record.priors) && Array.isArray((record.priors as Record<string, unknown>).gateProfiles)
      ? (record.priors as ComputedPriors)
      : null,
  };
};

const readJsonLines = async (path: string): Promise<readonly unknown[]> => {
  try {
    const text = await Deno.readTextFile(path);
    return text
      .trim()
      .split("\n")
      .filter((line) => line.trim().length > 0)
      .map((line) => {
        try {
          return JSON.parse(line);
        } catch {
          return null;
        }
      })
      .filter((entry) => entry !== null);
  } catch {
    return [];
  }
};

const extractFilePath = (input: unknown): string | null => {
  if (!isRecord(input)) return null;
  const toolInput = input.tool_input;
  if (!isRecord(toolInput)) return null;
  return typeof toolInput.file_path === "string" ? toolInput.file_path : null;
};

export default definePackage({
  config: defineConfig(parseConfig),
  state: defineState(
    { computedAt: null, sessionCount: 0, priors: null },
    parseState,
  ),

  sessionStart: async ({ env, config, state }) => {
    const passes = await readJsonLines(
      `${env.stateDir}/quality-gates/passes.jsonl`,
    );
    const sessions = await readJsonLines(`${env.stateDir}/sessions.jsonl`);

    if (sessions.length < config.minSessions) return null;

    const priors = computePriors(
      passes,
      sessions,
      config.lookbackSessions,
      config.correlationThreshold,
    );

    await state.set({
      computedAt: new Date().toISOString(),
      sessionCount: sessions.length,
      priors,
    });

    return formatContextBlock(priors, sessions.length, config.maxContextLines);
  },

  preToolUse: ({ config, state, input }) => {
    if (!config.enableFileWarnings) return { decision: "allow" as const };
    const current = state.get();
    if (current.priors === null) return { decision: "allow" as const };

    const filePath = extractFilePath(input);
    if (filePath === null) return { decision: "allow" as const };

    const warning = formatFileWarning(
      filePath,
      current.priors.fileCorrelations,
      config.correlationThreshold,
    );

    return warning !== null
      ? { decision: "allow" as const, context: warning }
      : { decision: "allow" as const };
  },
});
