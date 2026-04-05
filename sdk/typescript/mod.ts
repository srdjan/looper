export { loadRuntimeEnv } from "./env.ts";
export { createScaffoldFiles } from "./scaffold.ts";
export { createStateStore } from "./state.ts";
export { executeHook } from "./runtime.ts";
export { testHook } from "./testing.ts";
export type {
  CommandRequest,
  CommandResult,
  ConfigSchema,
  HandlerContext,
  HookExecution,
  HookName,
  MockCommand,
  PackageDefinition,
  PostToolUseResult,
  PreToolUseResult,
  RunCommand,
  RuntimeEnv,
  ScaffoldOptions,
  SessionStartResult,
  StateSchema,
  StateStore,
  StopResult,
  TestHarnessInput,
  TestHarnessResult,
} from "./types.ts";

import type { ConfigSchema, PackageDefinition, StateSchema } from "./types.ts";

export const defineConfig = <TConfig>(
  parse: ConfigSchema<TConfig>["parse"],
): ConfigSchema<TConfig> => ({ parse });

export const defineState = <TState>(
  initial: TState,
  parse: StateSchema<TState>["parse"],
): StateSchema<TState> => ({ initial, parse });

export const definePackage = <TConfig, TState>(
  definition: PackageDefinition<TConfig, TState>,
): PackageDefinition<TConfig, TState> => definition;
