#!/usr/bin/env bash
# kernel/pkg-utils.sh
# State and config helpers for package authors.
# Packages source this to read/write state and config.

# ── Kernel state (read-only from packages) ──────────────
KERNEL_STATE="${LOOPER_STATE_DIR}/kernel.json"

kernel_read() {
  local field="$1"
  jq -r "$field" "$KERNEL_STATE"
}

# ── Package state (read-write, scoped to calling package) ─
_ensure_pkg_state() {
  local state_file="${LOOPER_PKG_STATE}/state.json"
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  echo "$state_file"
}

_jq_update() {
  local file="$1" filter="$2"
  local tmp; tmp=$(mktemp)
  jq "$filter" "$file" > "$tmp" && mv "$tmp" "$file"
}

pkg_state_read() {
  jq -r "$1" "$(_ensure_pkg_state)"
}

pkg_state_write() {
  _jq_update "$(_ensure_pkg_state)" "$1 = $2"
}

pkg_state_append() {
  _jq_update "$(_ensure_pkg_state)" "$1 += [$2]"
}

# ── Read another package's state (read-only) ────────────
pkg_read() {
  local pkg_name="$1"
  local field="$2"
  local state_file="${LOOPER_STATE_DIR}/${pkg_name}/state.json"
  [ -f "$state_file" ] || { echo "null"; return; }
  jq -r "$field" "$state_file"
}

# ── Package config from looper.json ─────────────────────
pkg_config() {
  local field="$1"
  jq -r --arg pkg "$LOOPER_PKG_NAME" '.[$pkg]'"$field" "$LOOPER_CONFIG"
}

# ── Pattern matching ────────────────────────────────────
# shellcheck disable=SC2254
glob_match() {
  [[ "$1" == $2 ]]
}

file_matches_pattern() {
  local file="$1"
  local patterns="$2"
  local base="${file##*/}"
  local IFS=','
  for pattern in $patterns; do
    pattern="${pattern# }"
    pattern="${pattern% }"
    glob_match "$base" "$pattern" && return 0
    glob_match "$file" "$pattern" && return 0
  done
  return 1
}

files_match_patterns() {
  local patterns_json="$1"
  local files_str patterns_str
  files_str=$(kernel_read '.files_touched | .[]')
  patterns_str=$(echo "$patterns_json" | jq -r '.[]')
  local pattern file
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    while IFS= read -r file; do
      [ -z "$file" ] && continue
      glob_match "$file" "$pattern" && return 0
    done <<< "$files_str"
  done <<< "$patterns_str"
  return 1
}

# ── Misc helpers ────────────────────────────────────────
is_set() {
  [ -n "$1" ] && [ "$1" != "null" ]
}

run_with_timeout() {
  local secs="$1"
  shift
  if command -v timeout &>/dev/null; then
    timeout "$secs" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$secs" "$@"
  else
    "$@"
  fi
}
