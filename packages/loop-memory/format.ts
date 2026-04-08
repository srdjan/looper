// Pure formatting functions for rendering computed priors as context blocks.

import type {
  ComputedPriors,
  FileCorrelation,
  GateProfile,
  OscillationPattern,
} from "./mining.ts";

const pct = (rate: number): string => `${Math.round(rate * 100)}%`;
const round1 = (n: number): string => n.toFixed(1);

export const formatContextBlock = (
  priors: ComputedPriors,
  sessionCount: number,
  maxLines: number,
): string | null => {
  const lines: string[] = [];

  lines.push(`## Session Memory (${sessionCount} sessions analyzed)`);
  lines.push("");

  // Convergence summary (always present)
  const { convergence } = priors;
  if (convergence.completionRate >= 1 && convergence.avgIterations <= 2) {
    lines.push(
      `Convergence: ${pct(convergence.completionRate)} complete in avg ${round1(convergence.avgIterations)} iterations. No recurring issues detected.`,
    );
    return lines.join("\n");
  }

  const convergenceParts: string[] = [
    `${pct(convergence.completionRate)} of sessions complete in avg ${round1(convergence.avgIterations)} iterations`,
  ];
  if (convergence.budgetExhaustionRate > 0) {
    convergenceParts.push(
      `Budget exhausted ${pct(convergence.budgetExhaustionRate)}.`,
    );
  }
  lines.push(`Convergence: ${convergenceParts.join(". ")}`);

  // Hardest gate (highest failure rate)
  const hardest = priors.gateProfiles.length > 0
    ? priors.gateProfiles.reduce((a, b) =>
      b.failureRate > a.failureRate ? b : a
    )
    : undefined;
  if (hardest !== undefined && hardest.failureRate > 0.2) {
    lines.push(
      `Hardest gate: ${hardest.gate} (${pct(hardest.failureRate)} fail rate, avg ${round1(hardest.avgIterationsToPass)} iterations to pass).`,
    );
  }

  // File-gate correlations
  const topCorrelations = priors.fileCorrelations.slice(0, 4);
  if (topCorrelations.length > 0 && lines.length + 3 <= maxLines) {
    lines.push("");
    lines.push("Watch list:");
    for (const corr of topCorrelations) {
      if (lines.length >= maxLines - 1) break;
      lines.push(
        `  - Editing ${corr.filePattern} frequently breaks ${corr.gate} (${pct(corr.failureRate)}, ${corr.sampleSize} samples)`,
      );
    }
  }

  // Oscillation patterns
  if (
    priors.oscillations.length > 0 &&
    lines.length + 2 <= maxLines
  ) {
    lines.push("");
    for (const osc of priors.oscillations.slice(0, 2)) {
      if (lines.length >= maxLines) break;
      lines.push(
        `Known oscillation: ${osc.gates[0]} and ${osc.gates[1]} tend to see-saw - fix them together, not separately.`,
      );
    }
  }

  return lines.join("\n");
};

export const formatFileWarning = (
  filePath: string,
  correlations: readonly FileCorrelation[],
  threshold: number,
): string | null => {
  const matching = correlations.filter((corr) => {
    if (corr.failureRate < threshold) return false;
    return fileMatchesPattern(filePath, corr.filePattern);
  });

  if (matching.length === 0) return null;

  return matching
    .slice(0, 2)
    .map(
      (corr) =>
        `loop-memory: ${corr.gate} fails ${pct(corr.failureRate)} of the time when ${corr.filePattern} is edited.`,
    )
    .join(" ");
};

const fileMatchesPattern = (filePath: string, pattern: string): boolean => {
  if (pattern === filePath) return true;

  // Handle dir/* patterns
  if (pattern.endsWith("/*")) {
    const dir = pattern.slice(0, -2);
    // File is in this directory (not a subdirectory)
    const fileDir = filePath.substring(0, filePath.lastIndexOf("/"));
    return fileDir === dir;
  }

  return false;
};
