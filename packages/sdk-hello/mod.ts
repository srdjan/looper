import {
  defineConfig,
  definePackage,
  defineState,
} from "../../sdk/typescript/mod.ts";

const parseConfig = (
  raw: unknown,
): { readonly message: string; readonly succeedAfter: number } => {
  const record = typeof raw === "object" && raw !== null
    ? raw as Record<string, unknown>
    : {};

  return {
    message: typeof record.message === "string"
      ? record.message
      : "SDK hello package active",
    succeedAfter: typeof record.succeed_after === "number"
      ? record.succeed_after
      : 2,
  };
};

const parseState = (raw: unknown): { readonly attempts: number } => {
  const record = typeof raw === "object" && raw !== null
    ? raw as Record<string, unknown>
    : {};

  return {
    attempts: typeof record.attempts === "number" ? record.attempts : 0,
  };
};

export default definePackage({
  config: defineConfig(parseConfig),
  state: defineState({ attempts: 0 }, parseState),
  sessionStart: ({ config }) => `## SDK Hello\n${config.message}`,
  stop: async ({ config, state }) => {
    const next = await state.update((current) => ({
      attempts: current.attempts + 1,
    }));

    if (next.attempts < config.succeedAfter) {
      return {
        decision: "continue",
        feedback: `SDK hello: continue ${next.attempts}/${config.succeedAfter}`,
      } as const;
    }

    return {
      decision: "done",
      feedback: `SDK hello: done ${next.attempts}/${config.succeedAfter}`,
    } as const;
  },
});
