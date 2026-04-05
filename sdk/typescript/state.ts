import type { StateSchema, StateStore } from "./types.ts";

const ensureDir = async (path: string): Promise<void> => {
  await Deno.mkdir(path, { recursive: true });
};

const readJsonFile = async (path: string): Promise<unknown | null> => {
  try {
    const text = await Deno.readTextFile(path);
    return JSON.parse(text) as unknown;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      return null;
    }
    throw error;
  }
};

const writeJsonFile = async (path: string, value: unknown): Promise<void> => {
  await Deno.writeTextFile(path, `${JSON.stringify(value, null, 2)}\n`);
};

const resolveState = <TState>(
  raw: unknown | null,
  schema: StateSchema<TState>,
): TState => raw === null ? schema.parse(schema.initial) : schema.parse(raw);

export const createStateStore = async <TState>(
  filePath: string,
  schema: StateSchema<TState>,
): Promise<StateStore<TState>> => {
  const directory = filePath.replace(/\/[^/]+$/, "");
  await ensureDir(directory);

  let current = resolveState(await readJsonFile(filePath), schema);
  await writeJsonFile(filePath, current);

  const persist = async (next: TState): Promise<TState> => {
    current = schema.parse(next);
    await writeJsonFile(filePath, current);
    return current;
  };

  return {
    get: () => current,
    set: persist,
    update: async (transform) => {
      const next = await transform(current);
      return await persist(next);
    },
  };
};
