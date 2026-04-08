import type { CommandRequest, CommandResult, RunCommand } from "./types.ts";

export const runShell = (
  runCommand: RunCommand,
  command: string,
  options: Omit<CommandRequest, "command"> = {},
): Promise<CommandResult> =>
  runCommand({
    ...options,
    command: ["bash", "-lc", command],
  });
