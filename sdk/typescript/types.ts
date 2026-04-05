export type HookName =
  | "session-start"
  | "pre-tool-use"
  | "post-tool-use"
  | "stop";

export type CommandRequest = {
  readonly command: readonly [string, ...string[]];
  readonly cwd?: string;
  readonly env?: Readonly<Record<string, string>>;
  readonly stdinText?: string;
  readonly timeoutMs?: number;
};

export type CommandResult = {
  readonly ok: boolean;
  readonly code: number;
  readonly stdout: string;
  readonly stderr: string;
};

export type RunCommand = (
  request: CommandRequest,
) => Promise<CommandResult>;

export type RuntimeEnv = {
  readonly hook: HookName;
  readonly pkgName: string;
  readonly pkgDir: string;
  readonly pkgStateDir: string;
  readonly stateDir: string;
  readonly configPath: string;
  readonly iteration: number;
  readonly maxIterations: number;
  readonly cwd: string;
};

export type StateStore<TState> = {
  readonly get: () => TState;
  readonly set: (next: TState) => Promise<TState>;
  readonly update: (
    transform: (current: TState) => TState | Promise<TState>,
  ) => Promise<TState>;
};

export type ConfigSchema<TConfig> = {
  readonly parse: (raw: unknown) => TConfig;
};

export type StateSchema<TState> = {
  readonly initial: TState;
  readonly parse: (raw: unknown) => TState;
};

export type HandlerContext<TConfig, TState, TInput> = {
  readonly env: RuntimeEnv;
  readonly input: TInput;
  readonly config: TConfig;
  readonly state: StateStore<TState>;
  readonly runCommand: RunCommand;
};

export type SessionStartResult = string | null;

export type PreToolUseAllow = {
  readonly decision: "allow";
  readonly context?: string;
};

export type PreToolUseBlock = {
  readonly decision: "block";
  readonly reason: string;
};

export type PreToolUseResult = PreToolUseAllow | PreToolUseBlock;

export type PostToolUseResult = string | null;

export type StopDone = {
  readonly decision: "done";
  readonly feedback?: string;
};

export type StopContinue = {
  readonly decision: "continue";
  readonly feedback: string;
};

export type StopResult = StopDone | StopContinue;

export type PackageDefinition<TConfig, TState> = {
  readonly config: ConfigSchema<TConfig>;
  readonly state: StateSchema<TState>;
  readonly sessionStart?: (
    context: HandlerContext<TConfig, TState, unknown>,
  ) => SessionStartResult | Promise<SessionStartResult>;
  readonly preToolUse?: (
    context: HandlerContext<TConfig, TState, unknown>,
  ) => PreToolUseResult | Promise<PreToolUseResult>;
  readonly postToolUse?: (
    context: HandlerContext<TConfig, TState, unknown>,
  ) => PostToolUseResult | Promise<PostToolUseResult>;
  readonly stop?: (
    context: HandlerContext<TConfig, TState, unknown>,
  ) => StopResult | Promise<StopResult>;
};

export type HookExecution = {
  readonly stdout: string;
  readonly stderr: string;
  readonly exitCode: number;
};

export type TestHarnessInput<TConfig, TState> = {
  readonly hook: HookName;
  readonly config: TConfig;
  readonly state?: TState;
  readonly input?: unknown;
  readonly env?: Partial<Omit<RuntimeEnv, "hook">>;
  readonly commands?: readonly MockCommand[];
};

export type TestHarnessResult<TState> = HookExecution & {
  readonly state: TState;
};

export type MockCommand = {
  readonly command: readonly [string, ...string[]];
  readonly result: CommandResult;
};

export type ScaffoldOptions = {
  readonly packageName: string;
  readonly description?: string;
  readonly importPath?: string;
};
