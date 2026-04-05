import type { HookName, RuntimeEnv } from "./types.ts";

const readRequiredEnv = (name: string): string => {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
};

const parseInteger = (value: string, name: string): number => {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed)) {
    throw new Error(`Invalid integer for ${name}: ${value}`);
  }
  return parsed;
};

export const loadRuntimeEnv = (hook: HookName): RuntimeEnv => ({
  hook,
  pkgName: readRequiredEnv("LOOPER_PKG_NAME"),
  pkgDir: readRequiredEnv("LOOPER_PKG_DIR"),
  pkgStateDir: readRequiredEnv("LOOPER_PKG_STATE"),
  stateDir: readRequiredEnv("LOOPER_STATE_DIR"),
  configPath: readRequiredEnv("LOOPER_CONFIG"),
  iteration: parseInteger(
    readRequiredEnv("LOOPER_ITERATION"),
    "LOOPER_ITERATION",
  ),
  maxIterations: parseInteger(
    readRequiredEnv("LOOPER_MAX_ITERATIONS"),
    "LOOPER_MAX_ITERATIONS",
  ),
  cwd: Deno.cwd(),
});
