import type {
  HookExecution,
  PostToolUseResult,
  PreToolUseResult,
  SessionStartResult,
  StopResult,
} from "./types.ts";

const preToolUsePayload = (result: PreToolUseResult) => ({
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: result.decision === "block" ? "deny" : "allow",
    permissionDecisionReason: result.decision === "block"
      ? result.reason
      : undefined,
    additionalContext: result.decision === "allow" ? result.context ?? "" : "",
  },
});

export const toSessionStartExecution = (
  result: SessionStartResult,
): HookExecution => ({
  stdout: result ?? "",
  stderr: "",
  exitCode: 0,
});

export const toPreToolUseExecution = (
  result: PreToolUseResult,
): HookExecution => ({
  stdout: JSON.stringify(preToolUsePayload(result)),
  stderr: result.decision === "block" ? result.reason : "",
  exitCode: result.decision === "block" ? 2 : 0,
});

export const toPostToolUseExecution = (
  result: PostToolUseResult,
): HookExecution => ({
  stdout: result ?? "",
  stderr: "",
  exitCode: 0,
});

export const toStopExecution = (result: StopResult): HookExecution => ({
  stdout: "",
  stderr: result.feedback ?? "",
  exitCode: result.decision === "continue" ? 2 : 0,
});
