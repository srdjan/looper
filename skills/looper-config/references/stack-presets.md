# Stack Presets

Preset configurations for common tech stacks. Each preset defines gates (Stop hook quality checks) and checks (PostToolUse per-file feedback). The DETECT phase maps detected tools to the closest preset, then customizes it based on what's actually installed.

## TypeScript + ESLint + Prettier + Jest

The default and most common configuration.

### Gates

```json
[
  { "name": "typecheck", "command": "npx tsc --noEmit --pretty false", "weight": 30, "skip_if_missing": "tsconfig.json" },
  { "name": "lint",      "command": "npx eslint .",                     "weight": 20, "skip_if_missing": "node_modules/.bin/eslint" },
  { "name": "test",      "command": "npm test",                        "weight": 30 },
  { "name": "coverage",  "command": "$LOOPER_PKG_DIR/lib/check-coverage.sh", "weight": 20, "required": false }
]
```

### Checks

```json
[
  { "name": "format",    "command": "npx prettier --check {file}", "fix": "npx prettier --write {file}", "pattern": "*.ts,*.tsx,*.js,*.jsx", "skip_if_missing": "node_modules/.bin/prettier" },
  { "name": "lint",      "command": "npx eslint {file}",                                                  "pattern": "*.ts,*.tsx,*.js,*.jsx", "skip_if_missing": "node_modules/.bin/eslint" },
  { "name": "typecheck", "command": "npx tsc --noEmit --pretty false",                                    "pattern": "*.ts,*.tsx",             "skip_if_missing": "tsconfig.json" }
]
```

## TypeScript + Biome + Vitest

Modern alternative using Biome for linting and formatting.

### Gates

```json
[
  { "name": "typecheck", "command": "npx tsc --noEmit --pretty false", "weight": 30, "skip_if_missing": "tsconfig.json" },
  { "name": "lint",      "command": "npx biome check .",               "weight": 20, "skip_if_missing": "node_modules/.bin/biome" },
  { "name": "test",      "command": "npx vitest run",                  "weight": 30, "skip_if_missing": "node_modules/.bin/vitest" },
  { "name": "coverage",  "command": "$LOOPER_PKG_DIR/lib/check-coverage.sh", "weight": 20, "required": false }
]
```

### Checks

```json
[
  { "name": "biome",     "command": "npx biome check {file}", "fix": "npx biome check --write {file}", "pattern": "*.ts,*.tsx,*.js,*.jsx", "skip_if_missing": "node_modules/.bin/biome" },
  { "name": "typecheck", "command": "npx tsc --noEmit --pretty false",                                  "pattern": "*.ts,*.tsx",             "skip_if_missing": "tsconfig.json" }
]
```

## Deno

Deno has built-in tools for everything.

### Gates

```json
[
  { "name": "check", "command": "deno check .",       "weight": 30 },
  { "name": "lint",  "command": "deno lint",           "weight": 20 },
  { "name": "test",  "command": "deno test",           "weight": 30 },
  { "name": "fmt",   "command": "deno fmt --check",    "weight": 20, "required": false }
]
```

### Checks

```json
[
  { "name": "fmt",   "command": "deno fmt --check {file}", "fix": "deno fmt {file}", "pattern": "*.ts,*.tsx" },
  { "name": "lint",  "command": "deno lint {file}",                                   "pattern": "*.ts,*.tsx" },
  { "name": "check", "command": "deno check {file}",                                  "pattern": "*.ts,*.tsx" }
]
```

## Python + mypy + ruff + pytest

Modern Python stack with type checking and fast linting.

### Gates

```json
[
  { "name": "typecheck", "command": "python -m mypy src/",     "weight": 30, "skip_if_missing": "mypy.ini" },
  { "name": "lint",      "command": "ruff check .",             "weight": 20, "skip_if_missing": "ruff.toml" },
  { "name": "test",      "command": "python -m pytest -q",      "weight": 30 },
  { "name": "format",    "command": "ruff format --check .",     "weight": 20, "skip_if_missing": "ruff.toml", "required": false }
]
```

### Checks

```json
[
  { "name": "format", "command": "ruff format --check {file}", "fix": "ruff format {file}", "pattern": "*.py", "skip_if_missing": "ruff.toml" },
  { "name": "lint",   "command": "ruff check {file}",                                       "pattern": "*.py", "skip_if_missing": "ruff.toml" }
]
```

Note: If `pyproject.toml` contains `[tool.ruff]`, use that instead of `ruff.toml` for `skip_if_missing`. If `pyrightconfig.json` exists, use `pyright` instead of `mypy`.

## Go

Go's toolchain has built-in checks.

### Gates

```json
[
  { "name": "build", "command": "go build ./...", "weight": 30 },
  { "name": "vet",   "command": "go vet ./...",   "weight": 20 },
  { "name": "test",  "command": "go test ./...",  "weight": 30 },
  { "name": "lint",  "command": "golangci-lint run", "weight": 20, "skip_if_missing": ".golangci.yml", "required": false }
]
```

### Checks

```json
[
  { "name": "format", "command": "test -z \"$(gofmt -l {file})\"", "fix": "gofmt -w {file}", "pattern": "*.go" }
]
```

Note: `go vet` operates on packages, not individual files, so it is a gate only. `gofmt -l` always exits 0 so it must be wrapped in a `test -z` check.

## Rust

Rust with cargo and clippy.

### Gates

```json
[
  { "name": "check",  "command": "cargo check",       "weight": 30 },
  { "name": "clippy", "command": "cargo clippy -- -D warnings", "weight": 20 },
  { "name": "test",   "command": "cargo test",        "weight": 30 },
  { "name": "fmt",    "command": "cargo fmt -- --check", "weight": 20, "required": false }
]
```

### Checks

```json
[
  { "name": "fmt", "command": "cargo fmt -- --check", "fix": "cargo fmt", "pattern": "*.rs" }
]
```

Note: `cargo clippy` operates on the entire crate and is slow as a per-file check. Use it as a gate only. `cargo fmt` is fast enough for per-file use.

## Generic (Fallback)

When only a test command is detected (from package.json scripts or Makefile).

### Gates

```json
[
  { "name": "test", "command": "npm test", "weight": 100 }
]
```

### Checks

Empty - no per-file checks without knowing the toolchain.

```json
[]
```

## Weight Guidelines

Default weight distribution for a 100-point total:

| Gate Type | Weight | Rationale |
|-----------|--------|-----------|
| Type checking | 30 | Catches most bugs before runtime |
| Linting | 20 | Style and common mistakes |
| Tests | 30 | Behavioral correctness |
| Coverage/Format | 20 | Nice to have, often optional |

If a project doesn't have one of these categories, redistribute its weight proportionally among the remaining gates.
