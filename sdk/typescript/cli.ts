import { executeHook } from "./runtime.ts";
import type { HookName, PackageDefinition } from "./types.ts";

const parseHook = (value: string): HookName => {
  if (
    value === "session-start" || value === "pre-tool-use" ||
    value === "post-tool-use" || value === "stop"
  ) {
    return value;
  }
  throw new Error(`Unsupported hook name: ${value}`);
};

const toModuleUrl = (modulePath: string): string =>
  new URL(`file://${Deno.realPathSync(modulePath)}`).href;

if (import.meta.main) {
  const [modulePath, hookName] = Deno.args;
  if (!modulePath || !hookName) {
    throw new Error("Usage: cli.ts <module-path> <hook-name>");
  }

  const module = await import(toModuleUrl(modulePath)) as {
    default: PackageDefinition<unknown, unknown>;
  };
  const inputText = await new Response(Deno.stdin.readable).text();
  const execution = await executeHook(module.default, parseHook(hookName), {
    inputText,
  });

  if (execution.stdout.length > 0) {
    await Deno.stdout.write(new TextEncoder().encode(execution.stdout));
  }
  if (execution.stderr.length > 0) {
    await Deno.stderr.write(new TextEncoder().encode(execution.stderr));
  }
  Deno.exit(execution.exitCode);
}
