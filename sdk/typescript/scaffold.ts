import type { ScaffoldOptions } from "./types.ts";

const defaultImportPath = "../../../../sdk/typescript/mod.ts";

const hookWrapper = (hookName: string): string =>
  `#!/usr/bin/env bash
set -euo pipefail
exec deno run -A "$CLAUDE_PLUGIN_ROOT/sdk/typescript/cli.ts" "$LOOPER_PKG_DIR/mod.ts" ${hookName}
`;

const moduleTemplate = (importPath: string): string =>
  `import { defineConfig, definePackage, defineState } from "${importPath}";

const parseConfig = (raw: unknown): { message: string } => {
  const record = typeof raw === "object" && raw !== null ? raw as Record<string, unknown> : {};
  return {
    message: typeof record.message === "string" ? record.message : "Hello from the SDK package.",
  };
};

const parseState = (raw: unknown): { runs: number } => {
  const record = typeof raw === "object" && raw !== null ? raw as Record<string, unknown> : {};
  return {
    runs: typeof record.runs === "number" ? record.runs : 0,
  };
};

export default definePackage({
  config: defineConfig(parseConfig),
  state: defineState({ runs: 0 }, parseState),
  sessionStart: ({ config }) => config.message,
  stop: async ({ state }) => {
    const next = await state.update((current) => ({ runs: current.runs + 1 }));
    return { decision: "done", feedback: \`SDK package ran \${next.runs} time(s).\` };
  },
});
`;

export const createScaffoldFiles = (
  options: ScaffoldOptions,
): Readonly<Record<string, string>> => {
  const importPath = options.importPath ?? defaultImportPath;

  return {
    "package.json": `${
      JSON.stringify(
        {
          name: options.packageName,
          version: "0.1.0",
          description: options.description ??
            "SDK-authored Looper package scaffold",
          phase: "core",
        },
        null,
        2,
      )
    }\n`,
    "hooks/session-start.sh": hookWrapper("session-start"),
    "hooks/pre-tool-use.sh": hookWrapper("pre-tool-use"),
    "hooks/post-tool-use.sh": hookWrapper("post-tool-use"),
    "hooks/stop.sh": hookWrapper("stop"),
    "mod.ts": moduleTemplate(importPath),
  };
};
