import { executeHook } from "./runtime.ts";
import type {
  CommandResult,
  MockCommand,
  PackageDefinition,
  RunCommand,
  TestHarnessInput,
  TestHarnessResult,
} from "./types.ts";

const createTempEnv = async (
  hook: TestHarnessInput<unknown, unknown>["hook"],
  config: unknown,
  pkgState?: unknown,
  override?: TestHarnessInput<unknown, unknown>["env"],
) => {
  const root = await Deno.makeTempDir({ prefix: "looper-sdk-test-" });
  const configPath = `${root}/looper.json`;
  const pkgStateDir = `${root}/state/test-pkg`;

  await Deno.mkdir(pkgStateDir, { recursive: true });
  await Deno.writeTextFile(
    configPath,
    `${JSON.stringify({ "test-pkg": config }, null, 2)}\n`,
  );

  if (pkgState !== undefined) {
    await Deno.writeTextFile(
      `${pkgStateDir}/state.json`,
      `${JSON.stringify(pkgState, null, 2)}\n`,
    );
  }

  return {
    root,
    env: {
      hook,
      pkgName: "test-pkg",
      pkgDir: root,
      pkgStateDir,
      stateDir: `${root}/state`,
      configPath,
      iteration: 0,
      maxIterations: 10,
      cwd: root,
      ...override,
    },
  };
};

const commandKey = (command: readonly [string, ...string[]]): string =>
  command.join("\u0000");

const createMockRunner = (mocks: readonly MockCommand[] = []): RunCommand => {
  const byCommand = new Map<string, CommandResult>(
    mocks.map((mock) => [commandKey(mock.command), mock.result]),
  );

  return async ({ command }) => {
    const result = byCommand.get(commandKey(command));
    if (!result) {
      throw new Error(`No mock registered for command: ${command.join(" ")}`);
    }
    return result;
  };
};

export const testHook = async <TConfig, TState>(
  definition: PackageDefinition<TConfig, TState>,
  input: TestHarnessInput<TConfig, TState>,
): Promise<TestHarnessResult<TState>> => {
  const fixture = await createTempEnv(
    input.hook,
    input.config,
    input.state,
    input.env,
  );

  try {
    const execution = await executeHook(definition, input.hook, {
      env: fixture.env,
      inputText: input.input === undefined ? "" : JSON.stringify(input.input),
      runCommand: createMockRunner(input.commands),
    });
    const state = JSON.parse(
      await Deno.readTextFile(`${fixture.env.pkgStateDir}/state.json`),
    ) as TState;

    return {
      ...execution,
      state,
    };
  } finally {
    await Deno.remove(fixture.root, { recursive: true });
  }
};
