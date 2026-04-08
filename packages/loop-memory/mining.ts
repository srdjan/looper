// Pure data mining functions for computing cross-session priors.

type GateStatus = "pass" | "fail" | "timeout" | "skip" | "preexisting";

export type PassTrace = {
  readonly session_id: string;
  readonly pass: number;
  readonly score: number;
  readonly total: number;
  readonly files: readonly string[];
  readonly gates: Readonly<
    Record<string, { readonly status: GateStatus; readonly required: boolean }>
  >;
};

export type SessionSummary = {
  readonly status: "complete" | "budget_exhausted" | "in_progress";
  readonly iteration: number;
  readonly max_iterations: number;
  readonly score: number;
  readonly total: number;
};

export type GateProfile = {
  readonly gate: string;
  readonly failureRate: number;
  readonly avgIterationsToPass: number;
};

export type FileCorrelation = {
  readonly filePattern: string;
  readonly gate: string;
  readonly failureRate: number;
  readonly sampleSize: number;
};

export type ConvergenceShape = {
  readonly avgIterations: number;
  readonly completionRate: number;
  readonly budgetExhaustionRate: number;
};

export type OscillationPattern = {
  readonly gates: readonly [string, string];
  readonly sessionCount: number;
};

export type ComputedPriors = {
  readonly gateProfiles: readonly GateProfile[];
  readonly fileCorrelations: readonly FileCorrelation[];
  readonly convergence: ConvergenceShape;
  readonly oscillations: readonly OscillationPattern[];
};

export const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null;

const isFailing = (status: GateStatus): boolean =>
  status === "fail" || status === "timeout";

const isCountable = (status: GateStatus): boolean =>
  status !== "skip" && status !== "preexisting";

const MIN_CORRELATION_SAMPLES = 3;

// ── Shared Helpers ───────────────────────────────────────

const groupBySession = (
  passes: readonly PassTrace[],
): Map<string, PassTrace[]> => {
  const groups = new Map<string, PassTrace[]>();
  for (const pass of passes) {
    const group = groups.get(pass.session_id);
    if (group !== undefined) {
      group.push(pass);
    } else {
      groups.set(pass.session_id, [pass]);
    }
  }
  // Sort each group by pass number once
  for (const group of groups.values()) {
    group.sort((a, b) => a.pass - b.pass);
  }
  return groups;
};

const dirname = (filePath: string): string => {
  const lastSlash = filePath.lastIndexOf("/");
  return lastSlash > 0 ? filePath.substring(0, lastSlash) : "";
};

// ── Parsers ──────────────────────────────────────────────

export const parsePassTraces = (
  raw: readonly unknown[],
): readonly PassTrace[] =>
  raw
    .filter(isRecord)
    .map((row) => {
      const gates: Record<
        string,
        { readonly status: GateStatus; readonly required: boolean }
      > = {};
      const rawGates = isRecord(row.gates) ? row.gates : {};
      for (const [name, value] of Object.entries(rawGates)) {
        if (isRecord(value) && typeof value.status === "string") {
          gates[name] = {
            status: value.status as GateStatus,
            required: value.required !== false,
          };
        }
      }

      return {
        session_id: typeof row.session_id === "string" ? row.session_id : "",
        pass: typeof row.pass === "number" ? row.pass : 0,
        score: typeof row.score === "number" ? row.score : 0,
        total: typeof row.total === "number" ? row.total : 0,
        files: Array.isArray(row.files)
          ? row.files.filter((f): f is string => typeof f === "string")
          : [],
        gates,
      };
    })
    .filter((trace) => trace.session_id.length > 0);

export const parseSessionSummaries = (
  raw: readonly unknown[],
): readonly SessionSummary[] =>
  raw
    .filter(isRecord)
    .map((row) => ({
      status: (typeof row.status === "string" ? row.status : "") as
        SessionSummary["status"],
      iteration: typeof row.iteration === "number" ? row.iteration : 0,
      max_iterations:
        typeof row.max_iterations === "number" ? row.max_iterations : 10,
      score: typeof row.score === "number" ? row.score : 0,
      total: typeof row.total === "number" ? row.total : 0,
    }))
    .filter((session) => session.status.length > 0);

// ── Gate Difficulty Profiles ─────────────────────────────

export const computeGateProfiles = (
  passes: readonly PassTrace[],
): readonly GateProfile[] => {
  if (passes.length === 0) return [];

  const gateStats = new Map<
    string,
    { appearances: number; failures: number }
  >();

  for (const pass of passes) {
    for (const [name, gate] of Object.entries(pass.gates)) {
      if (!isCountable(gate.status)) continue;
      const stats = gateStats.get(name) ?? { appearances: 0, failures: 0 };
      stats.appearances += 1;
      if (isFailing(gate.status)) stats.failures += 1;
      gateStats.set(name, stats);
    }
  }

  const sessionGroups = groupBySession(passes);

  const avgIterToPass = new Map<string, number>();
  for (const name of gateStats.keys()) {
    const iterationsToFirstPass: number[] = [];

    for (const group of sessionGroups.values()) {
      // Groups are already sorted by pass number
      const firstPass = group.find(
        (p) => p.gates[name]?.status === "pass",
      );
      if (firstPass !== undefined) {
        iterationsToFirstPass.push(firstPass.pass);
      }
    }

    if (iterationsToFirstPass.length > 0) {
      const sum = iterationsToFirstPass.reduce((a, b) => a + b, 0);
      avgIterToPass.set(name, sum / iterationsToFirstPass.length);
    }
  }

  const profiles: GateProfile[] = [];
  for (const [name, stats] of gateStats) {
    if (stats.appearances === 0) continue;
    profiles.push({
      gate: name,
      failureRate: stats.failures / stats.appearances,
      avgIterationsToPass: avgIterToPass.get(name) ?? 1,
    });
  }

  return profiles;
};

// ── File-Gate Correlations ───────────────────────────────

export const computeFileCorrelations = (
  passes: readonly PassTrace[],
  threshold: number,
): readonly FileCorrelation[] => {
  if (passes.length === 0) return [];

  const coOccurrences = new Map<
    string,
    { filePresent: number; coFail: number }
  >();

  for (const pass of passes) {
    if (pass.files.length === 0) continue;
    for (const file of pass.files) {
      for (const [gateName, gate] of Object.entries(pass.gates)) {
        if (!isCountable(gate.status)) continue;
        const key = `${file}\0${gateName}`;
        const stats = coOccurrences.get(key) ?? {
          filePresent: 0,
          coFail: 0,
        };
        stats.filePresent += 1;
        if (isFailing(gate.status)) stats.coFail += 1;
        coOccurrences.set(key, stats);
      }
    }
  }

  const rawCorrelations: FileCorrelation[] = [];
  for (const [key, stats] of coOccurrences) {
    if (stats.filePresent < MIN_CORRELATION_SAMPLES) continue;
    const rate = stats.coFail / stats.filePresent;
    if (rate < threshold) continue;
    const [file, gate] = key.split("\0");
    rawCorrelations.push({
      filePattern: file,
      gate,
      failureRate: rate,
      sampleSize: stats.filePresent,
    });
  }

  return deduplicateByDirectory(rawCorrelations);
};

const deduplicateByDirectory = (
  correlations: readonly FileCorrelation[],
): readonly FileCorrelation[] => {
  const groups = new Map<string, FileCorrelation[]>();
  for (const corr of correlations) {
    const dir = dirname(corr.filePattern);
    if (dir.length === 0) continue;
    const key = `${dir}\0${corr.gate}`;
    const group = groups.get(key) ?? [];
    group.push(corr);
    groups.set(key, group);
  }

  const collapsed = new Set<string>();
  const result: FileCorrelation[] = [];

  for (const [key, group] of groups) {
    if (group.length >= 2) {
      const [dir, gate] = key.split("\0");
      const totalSamples = group.reduce((s, c) => s + c.sampleSize, 0);
      const weightedRate =
        group.reduce((s, c) => s + c.failureRate * c.sampleSize, 0) /
        totalSamples;
      result.push({
        filePattern: `${dir}/*`,
        gate,
        failureRate: weightedRate,
        sampleSize: totalSamples,
      });
      for (const corr of group) collapsed.add(`${corr.filePattern}\0${gate}`);
    }
  }

  for (const corr of correlations) {
    const key = `${corr.filePattern}\0${corr.gate}`;
    if (!collapsed.has(key)) {
      result.push(corr);
    }
  }

  return result.sort((a, b) => b.failureRate - a.failureRate);
};

// ── Convergence Shape ────────────────────────────────────

export const computeConvergenceShape = (
  sessions: readonly SessionSummary[],
): ConvergenceShape => {
  if (sessions.length === 0) {
    return { avgIterations: 0, completionRate: 0, budgetExhaustionRate: 0 };
  }

  const complete = sessions.filter((s) => s.status === "complete");
  const exhausted = sessions.filter((s) => s.status === "budget_exhausted");
  const totalIterations = sessions.reduce((s, sess) => s + sess.iteration, 0);

  return {
    avgIterations: totalIterations / sessions.length,
    completionRate: complete.length / sessions.length,
    budgetExhaustionRate: exhausted.length / sessions.length,
  };
};

// ── Oscillation Patterns ─────────────────────────────────

export const computeOscillationPatterns = (
  passes: readonly PassTrace[],
): readonly OscillationPattern[] => {
  const sessionGroups = groupBySession(passes);
  const pairCounts = new Map<string, number>();

  for (const group of sessionGroups.values()) {
    if (group.length < 4) continue;
    // Groups are already sorted by pass number

    const gateNames = new Set<string>();
    for (const pass of group) {
      for (const name of Object.keys(pass.gates)) {
        gateNames.add(name);
      }
    }

    const timelines = new Map<string, boolean[]>();
    for (const name of gateNames) {
      const timeline = group.map((p) => {
        const gate = p.gates[name];
        if (gate === undefined) return true;
        return gate.status === "pass" || gate.status === "skip";
      });
      timelines.set(name, timeline);
    }

    const oscillatingGates = new Set<string>();
    for (const [name, timeline] of timelines) {
      let alternations = 0;
      for (let i = 1; i < timeline.length; i++) {
        if (timeline[i] !== timeline[i - 1]) alternations += 1;
      }
      if (alternations >= 3) oscillatingGates.add(name);
    }

    const oscillatingList = [...oscillatingGates].sort();
    for (let i = 0; i < oscillatingList.length; i++) {
      for (let j = i + 1; j < oscillatingList.length; j++) {
        const a = timelines.get(oscillatingList[i])!;
        const b = timelines.get(oscillatingList[j])!;
        let oppositions = 0;
        for (let k = 0; k < a.length; k++) {
          if (a[k] !== b[k]) oppositions += 1;
        }
        if (oppositions >= Math.floor(a.length / 2)) {
          const pairKey = `${oscillatingList[i]}\0${oscillatingList[j]}`;
          pairCounts.set(pairKey, (pairCounts.get(pairKey) ?? 0) + 1);
        }
      }
    }
  }

  const patterns: OscillationPattern[] = [];
  for (const [key, count] of pairCounts) {
    if (count < 2) continue;
    const [a, b] = key.split("\0");
    patterns.push({ gates: [a, b], sessionCount: count });
  }

  return patterns.sort((a, b) => b.sessionCount - a.sessionCount);
};

// ── Top-Level Computation ────────────────────────────────

export const computePriors = (
  rawPasses: readonly unknown[],
  rawSessions: readonly unknown[],
  lookbackSessions: number,
  correlationThreshold: number,
): ComputedPriors => {
  const allSessions = parseSessionSummaries(rawSessions);
  const sessions = allSessions.slice(-lookbackSessions);

  const allPasses = parsePassTraces(rawPasses);
  const passes =
    lookbackSessions >= allSessions.length
      ? allPasses
      : allPasses.slice(-lookbackSessions * 15);

  return {
    gateProfiles: computeGateProfiles(passes),
    fileCorrelations: computeFileCorrelations(passes, correlationThreshold),
    convergence: computeConvergenceShape(sessions),
    oscillations: computeOscillationPatterns(passes),
  };
};
