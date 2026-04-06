#!/usr/bin/env bash
# kernel/kernel.sh
# Looper kernel - single entry point for all Claude Code hook events.
# Dispatches to package handlers, manages state, enforces circuit breakers.
#
# Usage: kernel.sh <event>
#   Events: SessionStart, PreToolUse, PostToolUse, Stop

set -euo pipefail

EVENT="${1:?Usage: kernel.sh <event>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

CONFIG="${CLAUDE_PROJECT_DIR:-.}/.claude/looper.json"
STATE_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/state"
KERNEL_STATE="$STATE_DIR/kernel.json"
RUNTIME_FIX_HINT="Install the missing runtime or remove the package from .claude/looper.json."

# ── Kernel state helpers ────────────────────────────────
kernel_state_json() {
  jq -n --argjson max "$MAX_ITERATIONS" '{
    iteration: 0,
    max_iterations: $max,
    status: "running",
    files_touched: [],
    missing_runtimes: []
  }'
}

ensure_kernel_state() {
  mkdir -p "$STATE_DIR"
  [ -f "$KERNEL_STATE" ] || kernel_state_json > "$KERNEL_STATE"
}

kernel_read() {
  ensure_kernel_state
  jq -r "$1" "$KERNEL_STATE"
}
_kernel_update() {
  ensure_kernel_state
  local tmp; tmp=$(mktemp)
  jq "$1" "$KERNEL_STATE" > "$tmp" && mv "$tmp" "$KERNEL_STATE"
}
kernel_write() { _kernel_update "$1 = $2"; }
kernel_append() { _kernel_update "$1 += [$2]"; }

# ── Stack detection ─────────────────────────────────────
detect_stack() {
  local d="${CLAUDE_PROJECT_DIR:-.}"
  [ -f "$d/Cargo.toml" ]                                      && echo "rust"             && return 0
  [ -f "$d/go.mod" ]                                          && echo "go"               && return 0
  [ -f "$d/pyproject.toml" ] || [ -f "$d/requirements.txt" ]  && echo "python"           && return 0
  [ -f "$d/deno.json" ] || [ -f "$d/deno.jsonc" ]             && echo "deno"             && return 0
  if [ -f "$d/tsconfig.json" ]; then
    [ -f "$d/biome.json" ] || [ -f "$d/biome.jsonc" ]         && echo "typescript-biome" && return 0
    echo "typescript-eslint" && return 0
  fi
  echo "minimal"
}

# ── Package resolution ──────────────────────────────────
resolve_package_dir() {
  local name="$1"
  local search_paths=(
    "${CLAUDE_PROJECT_DIR:-.}/.claude/packages/$name"   # project-local override
    "$HOME/.claude/packages/$name"                       # user-global
    "$PLUGIN_ROOT/packages/$name"                        # plugin-bundled
  )
  # Backward compat: LOOPER_HOME still works if set
  [ -n "${LOOPER_HOME:-}" ] && search_paths+=("$LOOPER_HOME/packages/$name")
  for path in "${search_paths[@]}"; do
    [ -f "$path/package.json" ] && echo "$path" && return
  done
  echo "Error: package '$name' not found" >&2
  return 1
}

load_active_packages() {
  jq -r '.packages // [] | .[]' "$CONFIG" 2>/dev/null
}

get_package_phase() {
  local pkg_dir="$1"
  jq -r '.phase // "core"' "$pkg_dir/package.json"
}

get_package_matcher() {
  local pkg_dir="$1" event="$2"
  jq -r --arg e "$event" '.matchers[$e] // ""' "$pkg_dir/package.json"
}

get_package_runtime() {
  local pkg_dir="$1"
  jq -r '.runtime // ""' "$pkg_dir/package.json"
}

detect_missing_runtimes() {
  local packages pkg_name missing='[]'
  packages=$(load_active_packages)
  for pkg_name in $packages; do
    local pkg_dir runtime
    pkg_dir=$(resolve_package_dir "$pkg_name") || continue
    runtime=$(get_package_runtime "$pkg_dir")
    [ -z "$runtime" ] && continue
    if ! command -v "$runtime" >/dev/null 2>&1; then
      missing=$(echo "$missing" | jq \
        --arg package "$pkg_name" \
        --arg runtime "$runtime" \
        --arg command "$runtime" \
        '. + [{package:$package, runtime:$runtime, command:$command}]')
    fi
  done
  echo "$missing"
}

render_missing_runtime_list() {
  echo "$1" | jq -r '.[] | "  - \(.package): requires runtime \(.runtime) (command: \(.command))"'
}

render_missing_runtime_reason() {
  echo "$1" | jq -r '
    map("\(.package) requires \(.runtime)")
    | join("; ")
  '
}

runtime_block_active() {
  [ -f "$STATE_DIR/.runtime_blocked" ]
}

emit_runtime_block_message() {
  local missing_json="$1"
  cat <<BLOCK
## Configuration Blocked

Looper cannot start because one or more configured packages require a missing runtime:
$(render_missing_runtime_list "$missing_json")

$RUNTIME_FIX_HINT
BLOCK
}

# ── Handler dispatch ────────────────────────────────────
event_to_handler() {
  case "$1" in
    SessionStart) echo "session-start.sh" ;;
    PreToolUse)   echo "pre-tool-use.sh" ;;
    PostToolUse)  echo "post-tool-use.sh" ;;
    Stop)         echo "stop.sh" ;;
    *) echo "" ;;
  esac
}

matches_tool_filter() {
  local pkg_dir="$1" event="$2" tool_name="$3"
  local matcher
  matcher=$(get_package_matcher "$pkg_dir" "$event")
  [ -z "$matcher" ] || echo "$tool_name" | grep -qE "$matcher"
}

run_handler() {
  local pkg_name="$1" pkg_dir="$2" handler="$3"
  (
    export LOOPER_PKG_NAME="$pkg_name"
    export LOOPER_PKG_DIR="$pkg_dir"
    export LOOPER_PKG_STATE="$STATE_DIR/$pkg_name"
    export LOOPER_STATE_DIR="$STATE_DIR"
    export LOOPER_HOOKS_DIR="$SCRIPT_DIR"
    export LOOPER_CONFIG="$CONFIG"
    export LOOPER_ITERATION=$(kernel_read '.iteration')
    export LOOPER_MAX_ITERATIONS="$MAX_ITERATIONS"
    bash "$handler"
  )
}

# ── SessionStart ────────────────────────────────────────
dispatch_session_start() {
  rm -f "$STATE_DIR/.runtime_blocked"

  # Initialize package state directories
  local packages
  packages=$(load_active_packages)
  for pkg_name in $packages; do
    mkdir -p "$STATE_DIR/$pkg_name"
  done

  # Detect runtime requirements before writing state
  local missing_runtimes
  missing_runtimes=$(detect_missing_runtimes)
  local blocked=false
  [ "$(echo "$missing_runtimes" | jq 'length')" -gt 0 ] && blocked=true

  # Write kernel state atomically (includes missing_runtimes)
  local init_status="running"
  $blocked && init_status="config_blocked"
  jq -n \
    --argjson max "$MAX_ITERATIONS" \
    --argjson mr "$missing_runtimes" \
    --arg status "$init_status" \
    '{iteration:0, max_iterations:$max, status:$status, files_touched:[], missing_runtimes:$mr}' > "$KERNEL_STATE"

  $blocked && touch "$STATE_DIR/.runtime_blocked"

  # Print kernel context
  local pkg_count
  pkg_count=$(echo "$packages" | grep -c . || echo 0)
  cat <<CONTEXT
## Improvement Loop Active

You are operating inside an improvement loop (max $MAX_ITERATIONS passes).
Active packages ($pkg_count): $(echo $packages | tr '\n' ' ')
CONTEXT

  if $blocked; then
    echo ""
    emit_runtime_block_message "$missing_runtimes"
    return 0
  fi

  # Dispatch to package handlers
  local handler_file
  handler_file=$(event_to_handler "SessionStart")
  for pkg_name in $packages; do
    local pkg_dir
    pkg_dir=$(resolve_package_dir "$pkg_name") || continue
    local handler="$pkg_dir/hooks/$handler_file"
    [ -x "$handler" ] || continue
    echo ""
    run_handler "$pkg_name" "$pkg_dir" "$handler"
  done
}

# ── PreToolUse ──────────────────────────────────────────
dispatch_pre_tool_use() {
  local input="$1"
  local tool_name file_path
  read -r tool_name file_path < <(echo "$input" | jq -r '[(.tool_name // ""), (.tool_input.file_path // "")] | @tsv')

  # Budget enforcement
  local iteration
  iteration=$(kernel_read '.iteration')
  if [ "$iteration" -ge "$MAX_ITERATIONS" ]; then
    echo "Budget exhausted: $MAX_ITERATIONS iterations reached. No further edits allowed." >&2
    echo "Summarize what was accomplished and what remains." >&2
    exit 2
  fi

  if runtime_block_active && echo "$tool_name" | grep -qE 'Edit|MultiEdit|Write'; then
    local missing_json deny_reason
    missing_json=$(kernel_read '.missing_runtimes')
    deny_reason="Configuration blocked: $(render_missing_runtime_reason "$missing_json"). $RUNTIME_FIX_HINT"
    jq -n --arg reason "$deny_reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    echo "$deny_reason" >&2
    exit 2
  fi

  # Track touched files
  if [ -n "$file_path" ]; then
    if ! jq -e --arg f "$file_path" '.files_touched | index($f)' "$KERNEL_STATE" >/dev/null 2>&1; then
      kernel_append '.files_touched' "\"$file_path\""
    fi
  fi

  # Dispatch to packages, collect additionalContext
  local all_context=""
  local final_exit=0
  local handler_file
  handler_file=$(event_to_handler "PreToolUse")
  local packages
  packages=$(load_active_packages)

  for pkg_name in $packages; do
    local pkg_dir
    pkg_dir=$(resolve_package_dir "$pkg_name") || continue
    local handler="$pkg_dir/hooks/$handler_file"
    [ -x "$handler" ] || continue

    matches_tool_filter "$pkg_dir" "PreToolUse" "$tool_name" || continue

    local pkg_out pkg_exit=0
    pkg_out=$(echo "$input" | run_handler "$pkg_name" "$pkg_dir" "$handler" 2>&1) || pkg_exit=$?

    if [ "$pkg_exit" -eq 2 ]; then
      final_exit=2
    fi

    # Extract additionalContext from handler JSON output
    local ctx
    ctx=$(echo "$pkg_out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
    [ -n "$ctx" ] && all_context="${all_context}${ctx}\n"
  done

  # Build merged response
  if [ "$final_exit" -eq 2 ]; then
    exit 2
  fi

  all_context="${all_context}Improvement pass ${iteration}/${MAX_ITERATIONS}."
  [ -n "$file_path" ] && all_context="${all_context} Editing: ${file_path}"

  jq -n --arg ctx "$all_context" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      additionalContext: $ctx
    }
  }'
  exit 0
}

# ── PostToolUse ─────────────────────────────────────────
dispatch_post_tool_use() {
  local input="$1"
  local tool_name
  tool_name=$(echo "$input" | jq -r '.tool_name // ""')

  local handler_file
  handler_file=$(event_to_handler "PostToolUse")
  local packages
  packages=$(load_active_packages)

  for pkg_name in $packages; do
    local pkg_dir
    pkg_dir=$(resolve_package_dir "$pkg_name") || continue
    local handler="$pkg_dir/hooks/$handler_file"
    [ -x "$handler" ] || continue

    matches_tool_filter "$pkg_dir" "PostToolUse" "$tool_name" || continue

    echo "$input" | run_handler "$pkg_name" "$pkg_dir" "$handler" || true
  done

  exit 0
}

# ── Stop ────────────────────────────────────────────────
dispatch_stop() {
  local input="$1"

  # Circuit breaker 1: stop_hook_active
  local stop_active
  stop_active=$(echo "$input" | jq -r '.stop_hook_active // false')
  if [ "$stop_active" = "true" ]; then
    kernel_write '.status' '"breaker_tripped"'
    echo "Stop hook breaker: allowing stop on re-entry." >&2
    exit 0
  fi

  if runtime_block_active; then
    local missing_json
    missing_json=$(kernel_read '.missing_runtimes')
    echo "" >&2
    echo "══════════════════════════════════════════════" >&2
    echo "  IMPROVEMENT LOOP BLOCKED - MISSING RUNTIME" >&2
    echo "══════════════════════════════════════════════" >&2
    render_missing_runtime_list "$missing_json" >&2
    echo "" >&2
    echo "$RUNTIME_FIX_HINT" >&2
    exit 0
  fi

  # Circuit breaker 2: iteration budget
  local iteration
  iteration=$(kernel_read '.iteration')
  if [ "$iteration" -ge "$MAX_ITERATIONS" ]; then
    kernel_write '.status' '"budget_exhausted"'
    echo "" >&2
    echo "══════════════════════════════════════════════" >&2
    echo "  IMPROVEMENT LOOP COMPLETE - BUDGET REACHED" >&2
    echo "  Iterations: $iteration/$MAX_ITERATIONS" >&2
    echo "══════════════════════════════════════════════" >&2
    echo "" >&2
    echo "Summarize: what was accomplished, what remains unfixed." >&2
    exit 0
  fi

  # Dispatch to packages in two phases: core, then post
  local handler_file
  handler_file=$(event_to_handler "Stop")
  local packages
  packages=$(load_active_packages)

  local _stop_any_continue=0
  local _stop_all_stderr=""

  # Run stop handlers for a given phase, updating _stop_any_continue and _stop_all_stderr
  run_stop_phase() {
    local target_phase="$1"
    for pkg_name in $packages; do
      local pkg_dir
      pkg_dir=$(resolve_package_dir "$pkg_name") || continue
      local handler="$pkg_dir/hooks/$handler_file"
      [ -x "$handler" ] || continue

      local phase
      phase=$(get_package_phase "$pkg_dir")
      [ "$phase" != "$target_phase" ] && continue

      local pkg_stderr
      pkg_stderr=$(mktemp)
      local pkg_exit=0
      echo "$input" | run_handler "$pkg_name" "$pkg_dir" "$handler" 2>"$pkg_stderr" || pkg_exit=$?

      if [ -s "$pkg_stderr" ]; then
        _stop_all_stderr="${_stop_all_stderr}\n-- [$pkg_name] --\n$(cat "$pkg_stderr")"
      fi
      rm -f "$pkg_stderr"

      if [ "$pkg_exit" -eq 2 ]; then
        _stop_any_continue=1
      fi
    done
  }

  run_stop_phase "core"

  # If any core package wants to continue, skip post phase
  if [ "$_stop_any_continue" -eq 0 ]; then
    run_stop_phase "post"
  fi

  if [ "$_stop_any_continue" -eq 1 ]; then
    kernel_write '.iteration' "$((iteration + 1))"
    printf '%b' "$_stop_all_stderr" >&2
    exit 2
  fi

  kernel_write '.status' '"complete"'
  printf '%b' "$_stop_all_stderr" >&2
  exit 0
}

# ── First-run bootstrap (SessionStart only) ────────────
ensure_config() {
  mkdir -p "$STATE_DIR"

  if [ ! -f "$CONFIG" ]; then
    local stack
    stack=$(detect_stack)
    local preset_file="$PLUGIN_ROOT/packages/quality-gates/presets/${stack}.json"
    [ -f "$preset_file" ] || { preset_file="$PLUGIN_ROOT/packages/quality-gates/presets/minimal.json"; stack="minimal"; }

    local config
    config=$(jq -n --argjson pkgs '["quality-gates"]' --slurpfile qg "$preset_file" '{
      max_iterations: 10,
      packages: $pkgs,
      "quality-gates": $qg[0]
    }')

    printf '%s\n' "$config" > "$CONFIG"
    echo "Looper: detected $stack stack - config written to $CONFIG" >&2
    echo "Looper: customize with /looper:looper-config" >&2
  fi

  # Ensure .claude/state/ is gitignored
  local gitignore="${CLAUDE_PROJECT_DIR:-.}/.gitignore"
  if [ -f "$gitignore" ]; then
    if ! grep -qF ".claude/state/" "$gitignore" 2>/dev/null; then
      # Ensure we start on a new line
      [ -n "$(tail -c1 "$gitignore" 2>/dev/null)" ] && printf '\n' >> "$gitignore"
      echo ".claude/state/" >> "$gitignore"
    fi
  fi
}

MAX_ITERATIONS=$(jq -r '.max_iterations // 10' "$CONFIG" 2>/dev/null || echo 10)

# ── Main dispatch ───────────────────────────────────────
case "$EVENT" in
  SessionStart)
    ensure_config
    MAX_ITERATIONS=$(jq -r '.max_iterations // 10' "$CONFIG" 2>/dev/null || echo 10)
    dispatch_session_start
    ;;
  PreToolUse|PostToolUse)
    INPUT=$(cat)
    if [ "$EVENT" = "PreToolUse" ]; then
      dispatch_pre_tool_use "$INPUT"
    else
      dispatch_post_tool_use "$INPUT"
    fi
    ;;
  Stop)
    INPUT=$(cat)
    dispatch_stop "$INPUT"
    ;;
  *)
    echo "Unknown event: $EVENT" >&2
    exit 1
    ;;
esac
