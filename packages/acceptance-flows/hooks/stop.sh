#!/usr/bin/env bash
set -euo pipefail
exec deno run -A "$CLAUDE_PLUGIN_ROOT/sdk/typescript/cli.ts" "$LOOPER_PKG_DIR/mod.ts" stop
