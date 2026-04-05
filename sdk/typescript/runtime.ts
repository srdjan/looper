import { loadRuntimeEnv } from "./env.ts";
import {
  toPostToolUseExecution,
  toPreToolUseExecution,
  toSessionStartExecution,
  toStopExecution,
} from "./io.ts";
import { createStateStore } from "./state.ts";
import type {
  CommandRequest,
  CommandResult,
  HookExecution,
  HookName,
  PackageDefinition,
  RunCommand,
  RuntimeEnv,
} from "./types.ts";

const stateFilePath = (pkgStateDir: string): string =>
  `${pkgStateDir}/state.json`;

const parseHookInput = (inputText: string): unknown => {
  if (inputText.trim().length === 0) {
    return null;
  }
  return JSON.parse(inputText) as unknown;
};

const defaultCommandRunner: RunCommand = async (
  request: CommandRequest,
): Promise<CommandResult> => {
  const [command, ...args] = request.command;
  const controller = new AbortController();
  const timeoutId = request.timeoutMs
    ? setTimeout(() => controller.abort(), request.timeoutMs)
    : undefined;

  const child = new Deno.Command(command, {
    args,
    cwd: request.cwd,
    env: request.env,
    stdin: request.stdinText === undefined ? "null" : "piped",
    stdout: "piped",
    stderr: "piped",
    signal: controller.signal,
  }).spawn();

  if (request.stdinText !== undefined) {
    const writer = child.stdin.getWriter();
    await writer.write(new TextEncoder().encode(request.stdinText));
    await writer.close();
  }

  try {
    const output = await child.output();
    return {
      ok: output.success,
      code: output.code,
      stdout: new TextDecoder().decode(output.stdout),
      stderr: new TextDecoder().decode(output.stderr),
    };
  } catch (error) {
    if (
      request.timeoutMs !== undefined &&
      error instanceof DOMException &&
      error.name === "AbortError"
    ) {
      return {
        ok: false,
        code: 124,
        stdout: "",
        stderr: `Command timed out after ${request.timeoutMs}ms`,
      };
    }
    throw error;
  } finally {
    if (timeoutId !== undefined) {
      clearTimeout(timeoutId);
    }
  }
};

const loadPackageConfig = async <TConfig, TState>(
  env: RuntimeEnv,
  definition: PackageDefinition<TConfig, TState>,
): Promise<TConfig> => {
  const rawConfig = JSON.parse(
    await Deno.readTextFile(env.configPath),
  ) as Record<string, unknown>;
  return definition.config.parse(rawConfig[env.pkgName] ?? {});
};

export const executeHook = async <TConfig, TState>(
  definition: PackageDefinition<TConfig, TState>,
  hook: HookName,
  options?: {
    readonly env?: RuntimeEnv;
    readonly inputText?: string;
    readonly runCommand?: RunCommand;
  },
): Promise<HookExecution> => {
  const env = options?.env ?? loadRuntimeEnv(hook);
  const config = await loadPackageConfig(env, definition);
  const state = await createStateStore(
    stateFilePath(env.pkgStateDir),
    definition.state,
  );
  const input = parseHookInput(options?.inputText ?? "");
  const runCommand = options?.runCommand ?? defaultCommandRunner;
  const context = { env, input, config, state, runCommand };

  switch (hook) {
    case "session-start":
      return toSessionStartExecution(
        definition.sessionStart ? await definition.sessionStart(context) : null,
      );
    case "pre-tool-use":
      return toPreToolUseExecution(
        definition.preToolUse
          ? await definition.preToolUse(context)
          : { decision: "allow" },
      );
    case "post-tool-use":
      return toPostToolUseExecution(
        definition.postToolUse ? await definition.postToolUse(context) : null,
      );
    case "stop":
      return toStopExecution(
        definition.stop ? await definition.stop(context) : { decision: "done" },
      );
  }
};
