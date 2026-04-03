---
name: looper-config
description: Configure Looper quality gates for your project through guided detection and Q&A
---

# Looper Configuration Wizard

Generate a `.claude/looper.json` configuration by detecting the project's tech stack and guiding the user through targeted refinement.

## When to Use

- User invokes `/looper:looper-config`
- User asks to "configure looper", "set up quality gates", or "create looper config"
- User wants to customize an existing `looper.json`

## Workflow

Execute these four phases in order. Never skip DETECT or PROPOSE. Always wait for user confirmation before writing files.

### Phase 1: DETECT

Scan the project root for stack indicators. Use Glob and Read tools - do not guess.

**Check these files (existence only unless noted):**

| File | Indicates | Also read |
|------|-----------|-----------|
| `package.json` | Node/npm | Read `scripts` and `devDependencies` keys |
| `tsconfig.json` | TypeScript | - |
| `deno.json` or `deno.jsonc` | Deno | - |
| `pyproject.toml` | Python | Read for `[tool.ruff]`, `[tool.mypy]`, `[tool.pytest]` |
| `setup.py` or `requirements.txt` | Python | - |
| `go.mod` | Go | - |
| `Cargo.toml` | Rust | - |
| `Makefile` | Make-based builds | Scan for `test:` target |
| `node_modules/.bin/eslint` | ESLint installed | - |
| `node_modules/.bin/prettier` | Prettier installed | - |
| `node_modules/.bin/biome` | Biome installed | - |
| `node_modules/.bin/vitest` | Vitest installed | - |
| `.eslintrc*` or `eslint.config.*` | ESLint configured | - |
| `.prettierrc*` | Prettier configured | - |
| `jest.config.*` | Jest configured | - |
| `vitest.config.*` | Vitest configured | - |
| `mypy.ini` or `pyrightconfig.json` | Python type checker | - |
| `ruff.toml` or `.ruff.toml` | Ruff linter | - |
| `.golangci.yml` | golangci-lint configured | - |

**From `package.json`, extract:**
- `scripts.test` - test command
- `scripts.lint` - lint command
- `scripts.format` or `scripts.prettier` - format command
- `scripts.typecheck` or `scripts.check` - type check command
- `devDependencies` - installed tool names (eslint, prettier, biome, jest, vitest, mocha)

**ESLint version detection:**
- If `eslint.config.*` (flat config) is found, use `npx eslint .` without `--ext` flag (deprecated in ESLint v9+)
- If `.eslintrc*` (legacy config) is found, use `npx eslint . --ext .ts,.tsx` (or appropriate extensions)

**Conflicting tools:**
- If both ESLint and Biome are detected, prefer Biome (it replaces ESLint + Prettier) and note the conflict to the user
- If both Jest and Vitest are detected, check which one `scripts.test` actually invokes

**Check for existing config:**
- If `.claude/looper.json` already exists, read it and offer to update rather than replace

Run all detection checks in parallel where possible.

### Phase 2: PROPOSE

Map detected tools to the closest preset from `references/stack-presets.md`. Then present the proposal.

**Output format (print this, do not use AskUserQuestion):**

List what was detected (runtime, test runner, linter, formatter, type checker), then show the proposed gates and checks in a compact table with name, weight, required/optional, and command. Show the matching preset name from `references/stack-presets.md` so the user understands the basis. End with `Settings: max_iterations=10`.

Then ask:

> Does this look right? Tell me what to change, or say "looks good" to continue.

Wait for the user's response. If they request changes, apply them and re-propose. If they approve, move to REFINE.

### Phase 3: REFINE

Ask targeted follow-up questions using AskUserQuestion. Only ask about things that matter and can't be auto-detected. Skip questions where the default is clearly appropriate.

**Round 1 - Basics (always ask):**

Use AskUserQuestion with these questions:

1. "How many improvement passes should Claude get before stopping?" - Options: "5 (quick tasks)", "10 (default)", "15 (complex work)", with 10 as recommended
2. "Should coverage be a required gate or optional?" - Options: "Required", "Optional (Recommended)" - only ask if coverage gate was proposed

**Round 2 - Advanced (ask only if the user seems interested in customization):**

3. "Do you want to add custom context instructions for Claude?" - Options: "No, use defaults (Recommended)", "Yes, let me add some"
4. "Do you want to customize project discovery commands?" - Options: "No, use defaults (Recommended)", "Yes, customize"

If the user selects custom context, ask them to type their context lines. If they select custom discovery, ask what commands to run.

**Do NOT ask about:**
- Gate weights (use defaults from presets)
- Timeout values (use 300s default)
- Coaching messages (use defaults)
- The `enabled` field (everything is enabled by default)

These are advanced options users can edit manually later.

### Phase 4: WRITE

1. Build the final JSON from the proposal + refinements
2. Show the complete `looper.json` to the user in a code block
3. Ask: "Write this to .claude/looper.json?"
4. On confirmation:
   - Write the file using the Write tool
   - Validate with: `jq empty .claude/looper.json`
   - If the looper plugin is not enabled, suggest running `/plugin install looper`

## Rules

1. **Never guess commands.** Only propose commands for tools that were positively detected in DETECT. If you're unsure whether a tool is installed, use `skip_if_missing`.

2. **Use skip_if_missing for all tool-dependent gates.** This makes the config portable - it works even if tools are later removed or not yet installed.

3. **Default weights must sum to 100.** Redistribute proportionally if a category is missing. For example, if there's no formatter: typecheck=35, lint=25, test=40.

4. **Default to required=true** for all gates except coverage and formatting. These two are commonly optional because they can be noisy.

5. **Always include checks** for the detected formatter and linter. These give Claude fast per-file feedback without waiting for the Stop hook.

6. **Show config before writing.** Never write `.claude/looper.json` without explicit user confirmation.

7. **Validate after writing.** Run `jq empty` on the generated file to catch JSON syntax errors.

8. **Respect existing config.** If `.claude/looper.json` already exists, show the user what would change and offer to merge rather than overwrite.

## Anti-Patterns

- Do not add gates for tools that aren't installed - use `skip_if_missing` instead of hoping the tool exists
- Do not set `max_iterations` below 3 - too few passes to be useful
- Do not set all gates to `required: false` - the loop needs at least one required gate to drive iteration
- Do not use relative paths in commands - use `npx` for Node tools, bare commands for system tools
- Do not add `run_when` patterns unless the user specifically asks - it's an advanced feature that can cause gates to be silently skipped
- Do not propose checks without a `pattern` field - without it, every file edit triggers every check
