#!/usr/bin/env bash
# tests/test-suite.sh - Test suite for Looper v2 kernel + package architecture.

set -uo pipefail

PASS=0
FAIL=0
ERRORS=""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KERNEL="$PROJECT_DIR/kernel/kernel.sh"
PKG_UTILS="$PROJECT_DIR/kernel/pkg-utils.sh"
COVERAGE_FILE="$PROJECT_DIR/coverage/coverage-summary.json"
COVERAGE_DIR="$(dirname "$COVERAGE_FILE")"
COVERAGE_BACKUP=$(mktemp)
COVERAGE_PRESENT=0

if [ -f "$COVERAGE_FILE" ]; then
  cp "$COVERAGE_FILE" "$COVERAGE_BACKUP"
  COVERAGE_PRESENT=1
fi

cleanup() {
  if [ "$COVERAGE_PRESENT" -eq 1 ]; then
    mkdir -p "$COVERAGE_DIR"
    cp "$COVERAGE_BACKUP" "$COVERAGE_FILE"
  else
    rm -f "$COVERAGE_FILE"
    rmdir "$COVERAGE_DIR" 2>/dev/null || true
  fi
  rm -f "$COVERAGE_BACKUP"
}
trap cleanup EXIT

# ── Helpers ─────────────────────────────────────────────

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  v $desc"
  else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  x $desc\n    expected: $expected\n    actual:   $actual"
    echo "  x $desc"
  fi
}

assert_true() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  v $desc"
  else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  x $desc"
    echo "  x $desc"
  fi
}

assert_false() {
  local desc="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  v $desc"
  else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  x $desc"
    echo "  x $desc"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -Fq "$needle"; then
    PASS=$((PASS + 1))
    echo "  v $desc"
  else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  x $desc\n    missing: $needle"
    echo "  x $desc"
  fi
}

make_fixture() {
  local fixture_dir
  fixture_dir=$(mktemp -d)
  mkdir -p "$fixture_dir/.claude/packages" "$fixture_dir/.claude/state"
  echo "$fixture_dir"
}

install_package() {
  local fixture_dir="$1" pkg_name="$2"
  local src="$PROJECT_DIR/packages/$pkg_name"
  local dest="$fixture_dir/.claude/packages/$pkg_name"
  cp -r "$src" "$dest"
  chmod +x "$dest/hooks/"*.sh 2>/dev/null || true
  chmod +x "$dest/lib/"*.sh 2>/dev/null || true
}

run_kernel() {
  local fixture_dir="$1" event="$2" input="$3" stdout_file="$4" stderr_file="$5"
  (
    export CLAUDE_PROJECT_DIR="$fixture_dir"
    export CLAUDE_PLUGIN_ROOT="$PROJECT_DIR"
    cd "$fixture_dir" || exit 1
    printf '%s' "$input" | bash "$PROJECT_DIR/kernel/kernel.sh" "$event" >"$stdout_file" 2>"$stderr_file"
  )
}

# ── pkg-utils.sh ────────────────────────────────────────

echo ""
echo "-- pkg-utils.sh --------------------------"

FIXTURE_UTILS=$(make_fixture)
mkdir -p "$FIXTURE_UTILS/.claude/state/test-pkg"
echo '{}' > "$FIXTURE_UTILS/.claude/state/kernel.json"
echo '{}' > "$FIXTURE_UTILS/.claude/state/test-pkg/state.json"

# Test kernel_read / pkg_state_write / pkg_state_read
(
  export LOOPER_HOOKS_DIR="$PROJECT_DIR/kernel"
  export LOOPER_STATE_DIR="$FIXTURE_UTILS/.claude/state"
  export LOOPER_PKG_NAME="test-pkg"
  export LOOPER_PKG_STATE="$FIXTURE_UTILS/.claude/state/test-pkg"
  export LOOPER_CONFIG="$FIXTURE_UTILS/.claude/looper.json"
  source "$PKG_UTILS"

  # Write and read package state
  pkg_state_write '.score' '42'
  RESULT=$(pkg_state_read '.score')
  echo "$RESULT"
) > /tmp/looper-test-out 2>&1
assert_eq "pkg_state_write/read works" "42" "$(cat /tmp/looper-test-out)"

# Test pkg_state_append
(
  export LOOPER_HOOKS_DIR="$PROJECT_DIR/kernel"
  export LOOPER_STATE_DIR="$FIXTURE_UTILS/.claude/state"
  export LOOPER_PKG_NAME="test-pkg"
  export LOOPER_PKG_STATE="$FIXTURE_UTILS/.claude/state/test-pkg"
  export LOOPER_CONFIG="$FIXTURE_UTILS/.claude/looper.json"
  source "$PKG_UTILS"

  pkg_state_write '.scores' '[]'
  pkg_state_append '.scores' '10'
  pkg_state_append '.scores' '20'
  pkg_state_read '.scores | length'
) > /tmp/looper-test-out 2>&1
assert_eq "pkg_state_append grows array" "2" "$(cat /tmp/looper-test-out)"

rm -rf "$FIXTURE_UTILS"

# ── kernel: SessionStart ────────────────────────────────

echo ""
echo "-- kernel: SessionStart ------------------"

FIXTURE_SESSION=$(make_fixture)
install_package "$FIXTURE_SESSION" "quality-gates"

# Minimal config
cat > "$FIXTURE_SESSION/.claude/looper.json" <<'EOF'
{
  "max_iterations": 5,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [
      { "name": "pass-gate", "command": "true", "weight": 100 }
    ]
  }
}
EOF

SESSION_STDOUT=$(mktemp)
SESSION_STDERR=$(mktemp)
run_kernel "$FIXTURE_SESSION" "SessionStart" "" "$SESSION_STDOUT" "$SESSION_STDERR"
assert_eq "session start exits 0" "0" "$?"
assert_true "session start creates kernel.json" test -f "$FIXTURE_SESSION/.claude/state/kernel.json"
assert_eq "kernel state iteration is 0" "0" "$(jq -r '.iteration' "$FIXTURE_SESSION/.claude/state/kernel.json")"
assert_eq "kernel state status is running" "running" "$(jq -r '.status' "$FIXTURE_SESSION/.claude/state/kernel.json")"
assert_contains "session start outputs loop info" "Improvement Loop Active" "$(cat "$SESSION_STDOUT")"
assert_contains "session start outputs gate info" "pass-gate" "$(cat "$SESSION_STDOUT")"
assert_true "session start creates package state dir" test -d "$FIXTURE_SESSION/.claude/state/quality-gates"

rm -rf "$FIXTURE_SESSION" "$SESSION_STDOUT" "$SESSION_STDERR"

# ── kernel: Stop - circuit breakers ─────────────────────

echo ""
echo "-- kernel: Stop - circuit breakers -------"

# Breaker: stop_hook_active
FIXTURE_BREAKER=$(make_fixture)
install_package "$FIXTURE_BREAKER" "quality-gates"
cat > "$FIXTURE_BREAKER/.claude/looper.json" <<'EOF'
{ "max_iterations": 10, "packages": ["quality-gates"], "quality-gates": { "gates": [{ "name": "fail", "command": "false", "weight": 100 }] } }
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_BREAKER/.claude/state/kernel.json"

B_STDOUT=$(mktemp); B_STDERR=$(mktemp)
run_kernel "$FIXTURE_BREAKER" "Stop" '{"stop_hook_active":true}' "$B_STDOUT" "$B_STDERR"
assert_eq "stop_hook_active breaker exits 0" "0" "$?"
assert_eq "stop_hook_active sets breaker_tripped" "breaker_tripped" "$(jq -r '.status' "$FIXTURE_BREAKER/.claude/state/kernel.json")"
assert_contains "breaker reports re-entry" "allowing stop on re-entry" "$(cat "$B_STDERR")"
rm -rf "$FIXTURE_BREAKER" "$B_STDOUT" "$B_STDERR"

# Breaker: budget exhausted
FIXTURE_BUDGET=$(make_fixture)
install_package "$FIXTURE_BUDGET" "quality-gates"
cat > "$FIXTURE_BUDGET/.claude/looper.json" <<'EOF'
{ "max_iterations": 10, "packages": ["quality-gates"], "quality-gates": { "gates": [{ "name": "fail", "command": "false", "weight": 100 }] } }
EOF
jq -n '{ iteration: 10, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_BUDGET/.claude/state/kernel.json"

B_STDOUT=$(mktemp); B_STDERR=$(mktemp)
run_kernel "$FIXTURE_BUDGET" "Stop" '{"stop_hook_active":false}' "$B_STDOUT" "$B_STDERR"
assert_eq "budget breaker exits 0" "0" "$?"
assert_eq "budget sets budget_exhausted" "budget_exhausted" "$(jq -r '.status' "$FIXTURE_BUDGET/.claude/state/kernel.json")"
assert_contains "budget reports exhaustion" "BUDGET REACHED" "$(cat "$B_STDERR")"
rm -rf "$FIXTURE_BUDGET" "$B_STDOUT" "$B_STDERR"

# Missing kernel state
FIXTURE_MISSING_STATE=$(make_fixture)
install_package "$FIXTURE_MISSING_STATE" "quality-gates"
cat > "$FIXTURE_MISSING_STATE/.claude/looper.json" <<'EOF'
{ "max_iterations": 10, "packages": ["quality-gates"], "quality-gates": { "gates": [{ "name": "pass", "command": "true", "weight": 100 }] } }
EOF
mkdir -p "$FIXTURE_MISSING_STATE/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_MISSING_STATE/.claude/state/quality-gates/state.json"

B_STDOUT=$(mktemp); B_STDERR=$(mktemp)
run_kernel "$FIXTURE_MISSING_STATE" "Stop" '{"stop_hook_active":false}' "$B_STDOUT" "$B_STDERR"
assert_eq "missing kernel state exits 0" "0" "$?"
assert_true "missing kernel state is bootstrapped" test -f "$FIXTURE_MISSING_STATE/.claude/state/kernel.json"
assert_eq "missing kernel state completes stop" "complete" "$(jq -r '.status' "$FIXTURE_MISSING_STATE/.claude/state/kernel.json")"
assert_false "missing kernel state does not emit jq file error" grep -F "Could not open file" "$B_STDERR"
rm -rf "$FIXTURE_MISSING_STATE" "$B_STDOUT" "$B_STDERR"

# ── kernel: Stop - gate evaluation ──────────────────────

echo ""
echo "-- kernel: Stop - gate evaluation --------"

# All gates pass
FIXTURE_PASS=$(make_fixture)
install_package "$FIXTURE_PASS" "quality-gates"
cat > "$FIXTURE_PASS/.claude/looper.json" <<'EOF'
{ "max_iterations": 10, "packages": ["quality-gates"], "quality-gates": { "gates": [{ "name": "always-pass", "command": "true", "weight": 100 }] } }
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_PASS/.claude/state/kernel.json"
mkdir -p "$FIXTURE_PASS/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_PASS/.claude/state/quality-gates/state.json"

P_STDOUT=$(mktemp); P_STDERR=$(mktemp)
run_kernel "$FIXTURE_PASS" "Stop" '{"stop_hook_active":false}' "$P_STDOUT" "$P_STDERR"
assert_eq "all gates pass exits 0" "0" "$?"
assert_eq "all gates pass sets complete" "complete" "$(jq -r '.status' "$FIXTURE_PASS/.claude/state/kernel.json")"
assert_contains "all gates pass reports success" "ALL PASS" "$(cat "$P_STDERR")"
rm -rf "$FIXTURE_PASS" "$P_STDOUT" "$P_STDERR"

# Required gate fails
FIXTURE_FAIL=$(make_fixture)
install_package "$FIXTURE_FAIL" "quality-gates"
cat > "$FIXTURE_FAIL/.claude/looper.json" <<'EOF'
{ "max_iterations": 10, "packages": ["quality-gates"], "quality-gates": { "gates": [{ "name": "always-fail", "command": "false", "weight": 100 }] } }
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_FAIL/.claude/state/kernel.json"
mkdir -p "$FIXTURE_FAIL/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_FAIL/.claude/state/quality-gates/state.json"

F_STDOUT=$(mktemp); F_STDERR=$(mktemp)
run_kernel "$FIXTURE_FAIL" "Stop" '{"stop_hook_active":false}' "$F_STDOUT" "$F_STDERR"
assert_eq "required gate fail exits 2" "2" "$?"
assert_eq "required gate fail increments iteration" "1" "$(jq -r '.iteration' "$FIXTURE_FAIL/.claude/state/kernel.json")"
rm -rf "$FIXTURE_FAIL" "$F_STDOUT" "$F_STDERR"

# Optional gate fails but required passes
FIXTURE_OPT=$(make_fixture)
install_package "$FIXTURE_OPT" "quality-gates"
cat > "$FIXTURE_OPT/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [
      { "name": "required-pass", "command": "true", "weight": 50 },
      { "name": "optional-fail", "command": "false", "weight": 50, "required": false }
    ]
  }
}
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_OPT/.claude/state/kernel.json"
mkdir -p "$FIXTURE_OPT/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_OPT/.claude/state/quality-gates/state.json"

O_STDOUT=$(mktemp); O_STDERR=$(mktemp)
run_kernel "$FIXTURE_OPT" "Stop" '{"stop_hook_active":false}' "$O_STDOUT" "$O_STDERR"
assert_eq "optional fail allows completion (exit 0)" "0" "$?"
assert_eq "optional fail status is complete" "complete" "$(jq -r '.status' "$FIXTURE_OPT/.claude/state/kernel.json")"
assert_contains "optional fail reports REQUIRED GATES PASS" "REQUIRED GATES PASS" "$(cat "$O_STDERR")"
rm -rf "$FIXTURE_OPT" "$O_STDOUT" "$O_STDERR"

# Disabled gate excluded
FIXTURE_DIS=$(make_fixture)
install_package "$FIXTURE_DIS" "quality-gates"
cat > "$FIXTURE_DIS/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [
      { "name": "pass", "command": "true", "weight": 50 },
      { "name": "disabled-fail", "command": "false", "weight": 50, "enabled": false }
    ]
  }
}
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_DIS/.claude/state/kernel.json"
mkdir -p "$FIXTURE_DIS/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_DIS/.claude/state/quality-gates/state.json"

D_STDOUT=$(mktemp); D_STDERR=$(mktemp)
run_kernel "$FIXTURE_DIS" "Stop" '{"stop_hook_active":false}' "$D_STDOUT" "$D_STDERR"
assert_eq "disabled gate excluded (exit 0)" "0" "$?"
assert_eq "disabled gate: score is 50" "50" "$(jq -r '.scores[0]' "$FIXTURE_DIS/.claude/state/quality-gates/state.json")"
rm -rf "$FIXTURE_DIS" "$D_STDOUT" "$D_STDERR"

# run_when conditional execution
FIXTURE_RW=$(make_fixture)
install_package "$FIXTURE_RW" "quality-gates"
cat > "$FIXTURE_RW/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [
      { "name": "always", "command": "true", "weight": 50 },
      { "name": "ts-only", "command": "false", "weight": 50, "run_when": ["src/**/*.ts"] }
    ]
  }
}
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: ["README.md"] }' > "$FIXTURE_RW/.claude/state/kernel.json"
mkdir -p "$FIXTURE_RW/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_RW/.claude/state/quality-gates/state.json"

RW_STDOUT=$(mktemp); RW_STDERR=$(mktemp)
run_kernel "$FIXTURE_RW" "Stop" '{"stop_hook_active":false}' "$RW_STDOUT" "$RW_STDERR"
assert_eq "run_when skips gate when no files match (exit 0)" "0" "$?"
assert_contains "run_when reports skip" "no matching files changed" "$(cat "$RW_STDERR")"

# With matching file
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: ["src/app/index.ts"] }' > "$FIXTURE_RW/.claude/state/kernel.json"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_RW/.claude/state/quality-gates/state.json"
run_kernel "$FIXTURE_RW" "Stop" '{"stop_hook_active":false}' "$RW_STDOUT" "$RW_STDERR"
assert_eq "run_when runs gate when files match (exit 2)" "2" "$?"
rm -rf "$FIXTURE_RW" "$RW_STDOUT" "$RW_STDERR"

# ── kernel: Stop - coaching ─────────────────────────────

echo ""
echo "-- kernel: Stop - coaching ---------------"

FIXTURE_COACH=$(make_fixture)
install_package "$FIXTURE_COACH" "quality-gates"
cat > "$FIXTURE_COACH/.claude/looper.json" <<'EOF'
{
  "max_iterations": 4,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [{ "name": "fail", "command": "false", "weight": 100 }],
    "coaching": {
      "urgency_at": 3,
      "on_failure": "CUSTOM: Fix these now.",
      "on_budget_low": "BUDGET: {remaining} left, hurry!"
    }
  }
}
EOF
jq -n '{ iteration: 0, max_iterations: 4, status: "running", files_touched: [] }' > "$FIXTURE_COACH/.claude/state/kernel.json"
mkdir -p "$FIXTURE_COACH/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_COACH/.claude/state/quality-gates/state.json"

C_STDOUT=$(mktemp); C_STDERR=$(mktemp)
run_kernel "$FIXTURE_COACH" "Stop" '{"stop_hook_active":false}' "$C_STDOUT" "$C_STDERR"
assert_eq "coaching: first pass exits 2" "2" "$?"
assert_contains "coaching: custom failure message" "CUSTOM: Fix these now." "$(cat "$C_STDERR")"
assert_contains "coaching: urgency at 3 remaining" "3 passes remaining" "$(cat "$C_STDERR")"

# Second pass: iteration is now 1, budget_low kicks in
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_COACH/.claude/state/quality-gates/state.json"
run_kernel "$FIXTURE_COACH" "Stop" '{"stop_hook_active":false}' "$C_STDOUT" "$C_STDERR"
assert_contains "coaching: custom budget low message" "BUDGET: 2 left, hurry!" "$(cat "$C_STDERR")"
rm -rf "$FIXTURE_COACH" "$C_STDOUT" "$C_STDERR"

# ── kernel: multi-package composition ───────────────────

echo ""
echo "-- kernel: multi-package composition -----"

# Create a minimal second package inline for testing
FIXTURE_MULTI=$(make_fixture)
install_package "$FIXTURE_MULTI" "quality-gates"

# Create a trivial "always-pass" package
PASS_PKG="$FIXTURE_MULTI/.claude/packages/always-pass"
mkdir -p "$PASS_PKG/hooks"
cat > "$PASS_PKG/package.json" <<'EOF'
{ "name": "always-pass", "version": "1.0.0", "description": "Always satisfied", "phase": "core" }
EOF
cat > "$PASS_PKG/hooks/stop.sh" <<'EOF'
#!/usr/bin/env bash
echo "always-pass: satisfied" >&2
exit 0
EOF
chmod +x "$PASS_PKG/hooks/stop.sh"

cat > "$FIXTURE_MULTI/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates", "always-pass"],
  "quality-gates": {
    "gates": [{ "name": "pass-gate", "command": "true", "weight": 100 }]
  }
}
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_MULTI/.claude/state/kernel.json"
mkdir -p "$FIXTURE_MULTI/.claude/state/quality-gates" "$FIXTURE_MULTI/.claude/state/always-pass"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_MULTI/.claude/state/quality-gates/state.json"

M_STDOUT=$(mktemp); M_STDERR=$(mktemp)
run_kernel "$FIXTURE_MULTI" "Stop" '{"stop_hook_active":false}' "$M_STDOUT" "$M_STDERR"
assert_eq "multi-package: both pass exits 0" "0" "$?"
assert_contains "multi-package: quality-gates header in output" "quality-gates" "$(cat "$M_STDERR")"
assert_contains "multi-package: always-pass header in output" "always-pass" "$(cat "$M_STDERR")"

# Test: one package fails, loop continues
FAIL_PKG="$FIXTURE_MULTI/.claude/packages/always-fail"
mkdir -p "$FAIL_PKG/hooks"
cat > "$FAIL_PKG/package.json" <<'EOF'
{ "name": "always-fail", "version": "1.0.0", "description": "Never satisfied", "phase": "core" }
EOF
cat > "$FAIL_PKG/hooks/stop.sh" <<'EOF'
#!/usr/bin/env bash
echo "always-fail: not satisfied" >&2
exit 2
EOF
chmod +x "$FAIL_PKG/hooks/stop.sh"

cat > "$FIXTURE_MULTI/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates", "always-fail"],
  "quality-gates": {
    "gates": [{ "name": "pass-gate", "command": "true", "weight": 100 }]
  }
}
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_MULTI/.claude/state/kernel.json"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_MULTI/.claude/state/quality-gates/state.json"

run_kernel "$FIXTURE_MULTI" "Stop" '{"stop_hook_active":false}' "$M_STDOUT" "$M_STDERR"
assert_eq "multi-package: one fails exits 2" "2" "$?"
assert_eq "multi-package: iteration incremented" "1" "$(jq -r '.iteration' "$FIXTURE_MULTI/.claude/state/kernel.json")"

rm -rf "$FIXTURE_MULTI" "$M_STDOUT" "$M_STDERR"

# ── kernel: two-phase stop model ────────────────────────

echo ""
echo "-- kernel: two-phase stop model ----------"

FIXTURE_PHASE=$(make_fixture)
install_package "$FIXTURE_PHASE" "quality-gates"

# Create a post-phase package
POST_PKG="$FIXTURE_PHASE/.claude/packages/post-check"
mkdir -p "$POST_PKG/hooks"
cat > "$POST_PKG/package.json" <<'EOF'
{ "name": "post-check", "version": "1.0.0", "description": "Post-phase check", "phase": "post" }
EOF
cat > "$POST_PKG/hooks/stop.sh" <<'EOF'
#!/usr/bin/env bash
echo "post-check: evaluating" >&2
exit 2
EOF
chmod +x "$POST_PKG/hooks/stop.sh"

# Core package fails: post should NOT run
cat > "$FIXTURE_PHASE/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates", "post-check"],
  "quality-gates": {
    "gates": [{ "name": "core-fail", "command": "false", "weight": 100 }]
  }
}
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_PHASE/.claude/state/kernel.json"
mkdir -p "$FIXTURE_PHASE/.claude/state/quality-gates" "$FIXTURE_PHASE/.claude/state/post-check"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_PHASE/.claude/state/quality-gates/state.json"

PH_STDOUT=$(mktemp); PH_STDERR=$(mktemp)
run_kernel "$FIXTURE_PHASE" "Stop" '{"stop_hook_active":false}' "$PH_STDOUT" "$PH_STDERR"
assert_eq "phase: core fails, exits 2" "2" "$?"

STDERR_CONTENT=$(cat "$PH_STDERR")
# Post-check should NOT have run since core failed
if printf '%s' "$STDERR_CONTENT" | grep -Fq "post-check: evaluating"; then
  FAIL=$((FAIL + 1))
  ERRORS="${ERRORS}\n  x phase: post should not run when core fails"
  echo "  x phase: post should not run when core fails"
else
  PASS=$((PASS + 1))
  echo "  v phase: post does not run when core fails"
fi

# Core passes: post should run
cat > "$FIXTURE_PHASE/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates", "post-check"],
  "quality-gates": {
    "gates": [{ "name": "core-pass", "command": "true", "weight": 100 }]
  }
}
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_PHASE/.claude/state/kernel.json"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_PHASE/.claude/state/quality-gates/state.json"

run_kernel "$FIXTURE_PHASE" "Stop" '{"stop_hook_active":false}' "$PH_STDOUT" "$PH_STDERR"
assert_eq "phase: core pass + post fail exits 2" "2" "$?"
assert_contains "phase: post runs after core passes" "post-check: evaluating" "$(cat "$PH_STDERR")"

rm -rf "$FIXTURE_PHASE" "$PH_STDOUT" "$PH_STDERR"

# ── plugin: ensure_config bootstrap ────────────────────

echo ""
echo "-- plugin: ensure_config bootstrap -------"

FIXTURE_BOOT=$(make_fixture)
# Remove looper.json so ensure_config creates it
rm -f "$FIXTURE_BOOT/.claude/looper.json"
# Create a .gitignore so ensure_config can update it
echo "node_modules/" > "$FIXTURE_BOOT/.gitignore"

BOOT_STDOUT=$(mktemp); BOOT_STDERR=$(mktemp)
run_kernel "$FIXTURE_BOOT" "SessionStart" "" "$BOOT_STDOUT" "$BOOT_STDERR"
assert_eq "bootstrap exits 0" "0" "$?"
assert_true "bootstrap: looper.json created" test -f "$FIXTURE_BOOT/.claude/looper.json"
assert_true "bootstrap: looper.json valid" jq empty "$FIXTURE_BOOT/.claude/looper.json"
assert_true "bootstrap: has packages array" jq -e '.packages | length > 0' "$FIXTURE_BOOT/.claude/looper.json"
assert_true "bootstrap: has quality-gates config" jq -e '.["quality-gates"]' "$FIXTURE_BOOT/.claude/looper.json"
assert_true "bootstrap: state dir created" test -d "$FIXTURE_BOOT/.claude/state"
assert_contains "bootstrap: .gitignore updated" ".claude/state/" "$(cat "$FIXTURE_BOOT/.gitignore")"
# Bare fixture (no marker files) should detect minimal stack
assert_contains "bootstrap: detects minimal stack" "detected minimal" "$(cat "$BOOT_STDERR")"
assert_true "bootstrap: minimal has test gate" jq -e '.["quality-gates"].gates[] | select(.name == "test")' "$FIXTURE_BOOT/.claude/looper.json"

# Second run should not recreate config
FIRST_CONFIG=$(cat "$FIXTURE_BOOT/.claude/looper.json")
run_kernel "$FIXTURE_BOOT" "SessionStart" "" "$BOOT_STDOUT" "$BOOT_STDERR"
SECOND_CONFIG=$(cat "$FIXTURE_BOOT/.claude/looper.json")
assert_eq "bootstrap: idempotent config" "$FIRST_CONFIG" "$SECOND_CONFIG"

rm -rf "$FIXTURE_BOOT" "$BOOT_STDOUT" "$BOOT_STDERR"

# ── plugin: stack auto-detection ─────────────────────

echo ""
echo "-- plugin: stack auto-detection ----------"

# Helper: test that a stack marker file triggers the expected preset
test_stack_detection() {
  local desc="$1" marker="$2" expected_stack="$3" expected_gate="$4"
  local fixture
  fixture=$(make_fixture)
  rm -f "$fixture/.claude/looper.json"
  echo "node_modules/" > "$fixture/.gitignore"
  # Create marker file(s) - supports space-separated list
  for f in $marker; do
    touch "$fixture/$f"
  done
  local out=$(mktemp) err=$(mktemp)
  run_kernel "$fixture" "SessionStart" "" "$out" "$err"
  assert_eq "detect $desc: exits 0" "0" "$?"
  assert_contains "detect $desc: detected $expected_stack" "detected $expected_stack" "$(cat "$err")"
  assert_true "detect $desc: has $expected_gate gate" jq -e --arg g "$expected_gate" '.["quality-gates"].gates[] | select(.name == $g)' "$fixture/.claude/looper.json"
  rm -rf "$fixture" "$out" "$err"
}

test_stack_detection "rust"              "Cargo.toml"              "rust"             "check"
test_stack_detection "go"                "go.mod"                  "go"               "build"
test_stack_detection "python"            "pyproject.toml"          "python"           "typecheck"
test_stack_detection "python-reqs"       "requirements.txt"        "python"           "typecheck"
test_stack_detection "deno"              "deno.json"               "deno"             "check"
test_stack_detection "deno-jsonc"        "deno.jsonc"              "deno"             "check"
test_stack_detection "typescript-biome"  "tsconfig.json biome.json" "typescript-biome" "typecheck"
test_stack_detection "typescript-eslint" "tsconfig.json"           "typescript-eslint" "typecheck"

# Priority: Rust wins over TypeScript when both markers present
test_stack_detection "rust-over-ts"      "Cargo.toml tsconfig.json" "rust"            "check"

# ── plugin: bundled package resolution ─────────────────

echo ""
echo "-- plugin: bundled package resolution ----"

FIXTURE_BUNDLED=$(make_fixture)
# Do NOT install package into fixture - kernel should find it via CLAUDE_PLUGIN_ROOT
cat > "$FIXTURE_BUNDLED/.claude/looper.json" <<'EOF'
{
  "max_iterations": 5,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [{ "name": "pass", "command": "true", "weight": 100 }]
  }
}
EOF

BND_STDOUT=$(mktemp); BND_STDERR=$(mktemp)
run_kernel "$FIXTURE_BUNDLED" "SessionStart" "" "$BND_STDOUT" "$BND_STDERR"
assert_eq "bundled: session start exits 0" "0" "$?"
assert_contains "bundled: finds quality-gates package" "quality-gates" "$(cat "$BND_STDOUT")"

# Stop should also work with bundled package
jq -n '{ iteration: 0, max_iterations: 5, status: "running", files_touched: [] }' > "$FIXTURE_BUNDLED/.claude/state/kernel.json"
mkdir -p "$FIXTURE_BUNDLED/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_BUNDLED/.claude/state/quality-gates/state.json"
run_kernel "$FIXTURE_BUNDLED" "Stop" '{"stop_hook_active":false}' "$BND_STDOUT" "$BND_STDERR"
assert_eq "bundled: stop with bundled package exits 0" "0" "$?"

rm -rf "$FIXTURE_BUNDLED" "$BND_STDOUT" "$BND_STDERR"

# ── plugin: project-local override ─────────────────────

echo ""
echo "-- plugin: project-local override --------"

FIXTURE_OVERRIDE=$(make_fixture)
cat > "$FIXTURE_OVERRIDE/.claude/looper.json" <<'EOF'
{
  "max_iterations": 5,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [{ "name": "pass", "command": "true", "weight": 100 }]
  }
}
EOF

# Install a modified package locally that adds a custom marker
install_package "$FIXTURE_OVERRIDE" "quality-gates"
# Patch the local session-start to add a marker
cat > "$FIXTURE_OVERRIDE/.claude/packages/quality-gates/hooks/session-start.sh" <<'HANDLER'
#!/usr/bin/env bash
echo "LOCAL-OVERRIDE-MARKER"
HANDLER
chmod +x "$FIXTURE_OVERRIDE/.claude/packages/quality-gates/hooks/session-start.sh"

OVR_STDOUT=$(mktemp); OVR_STDERR=$(mktemp)
run_kernel "$FIXTURE_OVERRIDE" "SessionStart" "" "$OVR_STDOUT" "$OVR_STDERR"
assert_eq "override: exits 0" "0" "$?"
assert_contains "override: uses project-local package" "LOCAL-OVERRIDE-MARKER" "$(cat "$OVR_STDOUT")"

rm -rf "$FIXTURE_OVERRIDE" "$OVR_STDOUT" "$OVR_STDERR"

# ── kernel: runtime readiness ──────────────────────────

echo ""
echo "-- kernel: runtime readiness -------------"

FIXTURE_RUNTIME=$(make_fixture)
mkdir -p "$FIXTURE_RUNTIME/.claude/packages/runtime-missing/hooks"
cat > "$FIXTURE_RUNTIME/.claude/packages/runtime-missing/package.json" <<'EOF'
{
  "name": "runtime-missing",
  "version": "1.0.0",
  "description": "Fixture package with a missing runtime",
  "runtime": "missing-bin",
  "phase": "core"
}
EOF

cat > "$FIXTURE_RUNTIME/.claude/looper.json" <<'EOF'
{
  "max_iterations": 5,
  "packages": ["runtime-missing"]
}
EOF

RT_STDOUT=$(mktemp); RT_STDERR=$(mktemp)
run_kernel "$FIXTURE_RUNTIME" "SessionStart" "" "$RT_STDOUT" "$RT_STDERR"
assert_eq "runtime: session start exits 0" "0" "$?"
assert_eq "runtime: kernel status is config_blocked" "config_blocked" "$(jq -r '.status' "$FIXTURE_RUNTIME/.claude/state/kernel.json")"
assert_eq "runtime: missing runtime package recorded" "runtime-missing" "$(jq -r '.missing_runtimes[0].package' "$FIXTURE_RUNTIME/.claude/state/kernel.json")"
assert_eq "runtime: missing runtime command recorded" "missing-bin" "$(jq -r '.missing_runtimes[0].command' "$FIXTURE_RUNTIME/.claude/state/kernel.json")"
assert_contains "runtime: session start reports blocked config" "Configuration Blocked" "$(cat "$RT_STDOUT")"
assert_contains "runtime: session start reports missing runtime" "missing-bin" "$(cat "$RT_STDOUT")"

run_kernel "$FIXTURE_RUNTIME" "PreToolUse" '{"tool_name":"Edit","tool_input":{"file_path":"src/app.ts"}}' "$RT_STDOUT" "$RT_STDERR"
assert_eq "runtime: pre-tool edit blocked" "2" "$?"
assert_contains "runtime: pre-tool emits deny payload" '"permissionDecision": "deny"' "$(cat "$RT_STDOUT")"
assert_contains "runtime: pre-tool explains missing runtime" "runtime-missing requires missing-bin" "$(cat "$RT_STDERR")"

run_kernel "$FIXTURE_RUNTIME" "PreToolUse" '{"tool_name":"Read","tool_input":{"file_path":"README.md"}}' "$RT_STDOUT" "$RT_STDERR"
assert_eq "runtime: non-edit tool still allowed" "0" "$?"

run_kernel "$FIXTURE_RUNTIME" "Stop" '{"stop_hook_active":false}' "$RT_STDOUT" "$RT_STDERR"
assert_eq "runtime: stop exits 0" "0" "$?"
assert_contains "runtime: stop reports blocked runtime" "MISSING RUNTIME" "$(cat "$RT_STDERR")"
assert_contains "runtime: stop names package" "runtime-missing" "$(cat "$RT_STDERR")"

RT_STATUS_OUT=$(bash "$PROJECT_DIR/packages/quality-gates/lib/status-report.sh" "$FIXTURE_RUNTIME")
assert_contains "runtime: status-report mentions runtime block" "Runtime Block:" "$RT_STATUS_OUT"
assert_contains "runtime: status-report mentions missing command" "missing-bin" "$RT_STATUS_OUT"

rm -rf "$FIXTURE_RUNTIME" "$RT_STDOUT" "$RT_STDERR"

# ── kernel: post-edit checks ───────────────────────────

echo ""
echo "-- kernel: post-edit checks --------------"

FIXTURE_CHECKS=$(make_fixture)
install_package "$FIXTURE_CHECKS" "quality-gates"
cat > "$FIXTURE_CHECKS/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [],
    "checks": [
      { "name": "md-check", "command": "true", "pattern": "*.md" },
      { "name": "ts-check", "command": "false", "pattern": "*.ts" }
    ]
  }
}
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_CHECKS/.claude/state/kernel.json"
mkdir -p "$FIXTURE_CHECKS/.claude/state/quality-gates"
echo '{}' > "$FIXTURE_CHECKS/.claude/state/quality-gates/state.json"

CHK_STDOUT=$(mktemp); CHK_STDERR=$(mktemp)

# .md file - md-check passes, ts-check skipped
run_kernel "$FIXTURE_CHECKS" "PostToolUse" '{"tool_name":"Edit","tool_input":{"file_path":"README.md"}}' "$CHK_STDOUT" "$CHK_STDERR"
assert_eq "post-edit: exits 0" "0" "$?"
assert_contains "post-edit: reports clean for .md" "all checks clean" "$(cat "$CHK_STDOUT")"

# .ts file - ts-check fails
run_kernel "$FIXTURE_CHECKS" "PostToolUse" '{"tool_name":"Edit","tool_input":{"file_path":"src/app.ts"}}' "$CHK_STDOUT" "$CHK_STDERR"
assert_contains "post-edit: reports issues for .ts" "ts-check" "$(cat "$CHK_STDOUT")"

# .py file - no matching checks
run_kernel "$FIXTURE_CHECKS" "PostToolUse" '{"tool_name":"Edit","tool_input":{"file_path":"main.py"}}' "$CHK_STDOUT" "$CHK_STDERR"
assert_contains "post-edit: reports clean for unmatched" "all checks clean" "$(cat "$CHK_STDOUT")"

# Non-matching tool name should be skipped (quality-gates matcher is Edit|MultiEdit|Write)
run_kernel "$FIXTURE_CHECKS" "PostToolUse" '{"tool_name":"Bash","tool_input":{}}' "$CHK_STDOUT" "$CHK_STDERR"
assert_eq "post-edit: non-matching tool produces no output" "" "$(cat "$CHK_STDOUT")"

rm -rf "$FIXTURE_CHECKS" "$CHK_STDOUT" "$CHK_STDERR"

# ── kernel: context injection ───────────────────────────

echo ""
echo "-- kernel: context injection -------------"

FIXTURE_CTX=$(make_fixture)
install_package "$FIXTURE_CTX" "quality-gates"
cat > "$FIXTURE_CTX/.claude/looper.json" <<'EOF'
{
  "max_iterations": 5,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [{ "name": "pass", "command": "true", "weight": 100 }],
    "context": [
      "This project uses {max_iterations} max iterations.",
      "Custom rule: never modify the API contract."
    ]
  }
}
EOF

CTX_STDOUT=$(mktemp); CTX_STDERR=$(mktemp)
run_kernel "$FIXTURE_CTX" "SessionStart" "" "$CTX_STDOUT" "$CTX_STDERR"
assert_contains "context: substitutes max_iterations" "5 max iterations" "$(cat "$CTX_STDOUT")"
assert_contains "context: includes custom rule" "never modify the API contract" "$(cat "$CTX_STDOUT")"
rm -rf "$FIXTURE_CTX" "$CTX_STDOUT" "$CTX_STDERR"

# ── baseline-aware gating ─────────────────────────────

echo ""
echo "-- baseline-aware gating -----------------"

# Baseline capture stores pass/fail map
FIXTURE_BL=$(make_fixture)
install_package "$FIXTURE_BL" "quality-gates"
cat > "$FIXTURE_BL/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "baseline": true,
    "gates": [
      { "name": "passing-gate", "command": "true", "weight": 50 },
      { "name": "failing-gate", "command": "false", "weight": 50 }
    ]
  }
}
EOF

BL_STDOUT=$(mktemp); BL_STDERR=$(mktemp)
run_kernel "$FIXTURE_BL" "SessionStart" "" "$BL_STDOUT" "$BL_STDERR"
assert_eq "baseline: session start exits 0" "0" "$?"
assert_eq "baseline: passing gate recorded as pass" "pass" "$(jq -r '.baseline["passing-gate"]' "$FIXTURE_BL/.claude/state/quality-gates/state.json")"
assert_eq "baseline: failing gate recorded as fail" "fail" "$(jq -r '.baseline["failing-gate"]' "$FIXTURE_BL/.claude/state/quality-gates/state.json")"
assert_contains "baseline: session context mentions pre-existing" "Pre-Existing Failures" "$(cat "$BL_STDOUT")"
assert_contains "baseline: session context names failing gate" "failing-gate" "$(cat "$BL_STDOUT")"

# Stop with baseline: pre-existing failure does not force iteration
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_BL/.claude/state/kernel.json"
# Reset scores but keep baseline
jq '.scores = [] | .checks = {} | .satisfied = false' "$FIXTURE_BL/.claude/state/quality-gates/state.json" > /tmp/bl-reset.json && mv /tmp/bl-reset.json "$FIXTURE_BL/.claude/state/quality-gates/state.json"

run_kernel "$FIXTURE_BL" "Stop" '{"stop_hook_active":false}' "$BL_STDOUT" "$BL_STDERR"
assert_eq "baseline: pre-existing failure allows completion (exit 0)" "0" "$?"
assert_contains "baseline: report uses ~ for pre-existing" "~ failing-gate" "$(cat "$BL_STDERR")"
assert_contains "baseline: report shows pre-existing label" "pre-existing" "$(cat "$BL_STDERR")"

rm -rf "$FIXTURE_BL" "$BL_STDOUT" "$BL_STDERR"

# Baseline: introduced failure still forces iteration
FIXTURE_BL2=$(make_fixture)
install_package "$FIXTURE_BL2" "quality-gates"
cat > "$FIXTURE_BL2/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "baseline": true,
    "gates": [
      { "name": "was-passing", "command": "false", "weight": 100 }
    ]
  }
}
EOF

BL2_STDOUT=$(mktemp); BL2_STDERR=$(mktemp)
# First run SessionStart with passing gate to capture baseline
cat > "$FIXTURE_BL2/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "baseline": true,
    "gates": [
      { "name": "was-passing", "command": "true", "weight": 100 }
    ]
  }
}
EOF
run_kernel "$FIXTURE_BL2" "SessionStart" "" "$BL2_STDOUT" "$BL2_STDERR"
assert_eq "baseline-intro: baseline records pass" "pass" "$(jq -r '.baseline["was-passing"]' "$FIXTURE_BL2/.claude/state/quality-gates/state.json")"

# Now change the gate to fail (simulating Claude breaking it)
cat > "$FIXTURE_BL2/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "baseline": true,
    "gates": [
      { "name": "was-passing", "command": "false", "weight": 100 }
    ]
  }
}
EOF
jq '.scores = [] | .checks = {} | .satisfied = false' "$FIXTURE_BL2/.claude/state/quality-gates/state.json" > /tmp/bl2-reset.json && mv /tmp/bl2-reset.json "$FIXTURE_BL2/.claude/state/quality-gates/state.json"

run_kernel "$FIXTURE_BL2" "Stop" '{"stop_hook_active":false}' "$BL2_STDOUT" "$BL2_STDERR"
assert_eq "baseline-intro: introduced failure exits 2" "2" "$?"
assert_contains "baseline-intro: report uses x for introduced" "x was-passing" "$(cat "$BL2_STDERR")"

rm -rf "$FIXTURE_BL2" "$BL2_STDOUT" "$BL2_STDERR"

# No baseline (default): existing behavior preserved
FIXTURE_BL3=$(make_fixture)
install_package "$FIXTURE_BL3" "quality-gates"
cat > "$FIXTURE_BL3/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [
      { "name": "fail-gate", "command": "false", "weight": 100 }
    ]
  }
}
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_BL3/.claude/state/kernel.json"
mkdir -p "$FIXTURE_BL3/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_BL3/.claude/state/quality-gates/state.json"

BL3_STDOUT=$(mktemp); BL3_STDERR=$(mktemp)
run_kernel "$FIXTURE_BL3" "Stop" '{"stop_hook_active":false}' "$BL3_STDOUT" "$BL3_STDERR"
assert_eq "no-baseline: failure exits 2 as before" "2" "$?"
assert_contains "no-baseline: report uses x for failure" "x fail-gate" "$(cat "$BL3_STDERR")"

rm -rf "$FIXTURE_BL3" "$BL3_STDOUT" "$BL3_STDERR"

# ── sdk: package integration ───────────────────────────

echo ""
echo "-- sdk: package integration --------------"

FIXTURE_SDK=$(make_fixture)
cat > "$FIXTURE_SDK/.claude/looper.json" <<'EOF'
{
  "max_iterations": 3,
  "packages": ["sdk-hello"],
  "sdk-hello": {
    "message": "SDK package online",
    "succeed_after": 2
  }
}
EOF

SDK_STDOUT=$(mktemp); SDK_STDERR=$(mktemp)
run_kernel "$FIXTURE_SDK" "SessionStart" "" "$SDK_STDOUT" "$SDK_STDERR"
assert_eq "sdk: session start exits 0" "0" "$?"
assert_contains "sdk: session start includes package message" "SDK package online" "$(cat "$SDK_STDOUT")"

run_kernel "$FIXTURE_SDK" "Stop" '{"stop_hook_active":false}' "$SDK_STDOUT" "$SDK_STDERR"
assert_eq "sdk: first stop exits 2" "2" "$?"
assert_contains "sdk: first stop reports continue" "SDK hello: continue 1/2" "$(cat "$SDK_STDERR")"
assert_eq "sdk: first stop increments iteration" "1" "$(jq -r '.iteration' "$FIXTURE_SDK/.claude/state/kernel.json")"

run_kernel "$FIXTURE_SDK" "Stop" '{"stop_hook_active":false}' "$SDK_STDOUT" "$SDK_STDERR"
assert_eq "sdk: second stop exits 0" "0" "$?"
assert_contains "sdk: second stop reports done" "SDK hello: done 2/2" "$(cat "$SDK_STDERR")"
assert_eq "sdk: second stop marks kernel complete" "complete" "$(jq -r '.status' "$FIXTURE_SDK/.claude/state/kernel.json")"
assert_eq "sdk: state persists attempts" "2" "$(jq -r '.attempts' "$FIXTURE_SDK/.claude/state/sdk-hello/state.json")"

rm -rf "$FIXTURE_SDK" "$SDK_STDOUT" "$SDK_STDERR"

# ── scope-guard package ───────────────────────────────

echo ""
echo "-- scope-guard package -------------------"

# scope-guard: uses bundled resolution (not install_package) so SDK relative imports work
FIXTURE_SG=$(make_fixture)
# Do NOT install_package - let kernel resolve via CLAUDE_PLUGIN_ROOT/packages/scope-guard
cat > "$FIXTURE_SG/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["scope-guard"],
  "scope-guard": {
    "blocked": ["package-lock.json", ".env*"],
    "allowed": ["src/**/*"]
  }
}
EOF

SG_STDOUT=$(mktemp); SG_STDERR=$(mktemp)

# SessionStart: should inject scope rules
run_kernel "$FIXTURE_SG" "SessionStart" "" "$SG_STDOUT" "$SG_STDERR"
assert_eq "scope-guard: session start exits 0" "0" "$?"
assert_contains "scope-guard: session start shows blocked" "Blocked files" "$(cat "$SG_STDOUT")"
assert_contains "scope-guard: session start shows allowed" "Allowed files" "$(cat "$SG_STDOUT")"

# PreToolUse: blocked file should be denied
SG_EXIT=0
run_kernel "$FIXTURE_SG" "PreToolUse" '{"tool_name":"Edit","tool_input":{"file_path":"package-lock.json"}}' "$SG_STDOUT" "$SG_STDERR" || SG_EXIT=$?
assert_eq "scope-guard: PreToolUse blocks package-lock.json" "2" "$SG_EXIT"

# PreToolUse: allowed file should pass
run_kernel "$FIXTURE_SG" "PreToolUse" '{"tool_name":"Edit","tool_input":{"file_path":"src/app.ts"}}' "$SG_STDOUT" "$SG_STDERR"
assert_eq "scope-guard: PreToolUse allows src/app.ts" "0" "$?"

rm -rf "$FIXTURE_SG" "$SG_STDOUT" "$SG_STDERR"

# scope-guard + quality-gates: multi-package composition (bundled resolution for both)
FIXTURE_SG2=$(make_fixture)
cat > "$FIXTURE_SG2/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates", "scope-guard"],
  "quality-gates": {
    "gates": [{ "name": "pass-gate", "command": "true", "weight": 100 }]
  },
  "scope-guard": {
    "blocked": [],
    "allowed": ["src/**/*"]
  }
}
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: ["src/app.ts"] }' > "$FIXTURE_SG2/.claude/state/kernel.json"
mkdir -p "$FIXTURE_SG2/.claude/state/quality-gates" "$FIXTURE_SG2/.claude/state/scope-guard"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_SG2/.claude/state/quality-gates/state.json"

SG2_STDOUT=$(mktemp); SG2_STDERR=$(mktemp)
run_kernel "$FIXTURE_SG2" "Stop" '{"stop_hook_active":false}' "$SG2_STDOUT" "$SG2_STDERR"
assert_eq "scope-guard+qg: in-scope files complete (exit 0)" "0" "$?"
assert_contains "scope-guard+qg: quality-gates header" "quality-gates" "$(cat "$SG2_STDERR")"
assert_contains "scope-guard+qg: scope-guard reports clean" "within scope" "$(cat "$SG2_STDERR")"

# With out-of-scope file: post phase should force continue
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: ["src/app.ts", "package-lock.json"] }' > "$FIXTURE_SG2/.claude/state/kernel.json"
echo '{"scores":[],"checks":{},"satisfied":false}' > "$FIXTURE_SG2/.claude/state/quality-gates/state.json"
echo '{"violations":[]}' > "$FIXTURE_SG2/.claude/state/scope-guard/state.json"

run_kernel "$FIXTURE_SG2" "Stop" '{"stop_hook_active":false}' "$SG2_STDOUT" "$SG2_STDERR"
assert_eq "scope-guard+qg: out-of-scope file exits 2" "2" "$?"
assert_contains "scope-guard+qg: reports violation" "outside allowed scope" "$(cat "$SG2_STDERR")"

rm -rf "$FIXTURE_SG2" "$SG2_STDOUT" "$SG2_STDERR"

# ── acceptance-flows package ──────────────────────────

echo ""
echo "-- acceptance-flows package ---------------"

FIXTURE_AF=$(make_fixture)
mkdir -p "$FIXTURE_AF/scripts"
cat > "$FIXTURE_AF/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates", "acceptance-flows"],
  "quality-gates": {
    "gates": [{ "name": "pass-gate", "command": "true", "weight": 100 }]
  },
  "acceptance-flows": {
    "tail_lines": 2,
    "flows": [
      {
        "name": "api-smoke",
        "command": "./scripts/api-smoke.sh",
        "timeout": 30,
        "run_when": ["src/api/**/*"],
        "required": true
      },
      {
        "name": "docs-preview",
        "command": "./scripts/docs-preview.sh",
        "timeout": 30,
        "run_when": ["docs/**/*"],
        "required": false
      }
    ]
  }
}
EOF
cat > "$FIXTURE_AF/scripts/api-smoke.sh" <<'EOF'
#!/usr/bin/env bash
echo "api smoke failed"
echo "trace tail line 1" >&2
echo "trace tail line 2" >&2
exit 1
EOF
cat > "$FIXTURE_AF/scripts/docs-preview.sh" <<'EOF'
#!/usr/bin/env bash
echo "docs preview ok"
exit 0
EOF
chmod +x "$FIXTURE_AF/scripts/api-smoke.sh" "$FIXTURE_AF/scripts/docs-preview.sh"

AF_STDOUT=$(mktemp); AF_STDERR=$(mktemp)
run_kernel "$FIXTURE_AF" "SessionStart" "" "$AF_STDOUT" "$AF_STDERR"
assert_eq "acceptance-flows: session start exits 0" "0" "$?"
assert_contains "acceptance-flows: session start mentions package" "Acceptance Flows" "$(cat "$AF_STDOUT")"
assert_contains "acceptance-flows: session start lists api-smoke" "api-smoke [required]" "$(cat "$AF_STDOUT")"

jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: ["src/api/route.ts"] }' > "$FIXTURE_AF/.claude/state/kernel.json"
mkdir -p "$FIXTURE_AF/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false,"baseline":null}' > "$FIXTURE_AF/.claude/state/quality-gates/state.json"

run_kernel "$FIXTURE_AF" "Stop" '{"stop_hook_active":false}' "$AF_STDOUT" "$AF_STDERR"
assert_eq "acceptance-flows: required failure exits 2" "2" "$?"
assert_contains "acceptance-flows: feedback includes package header" "acceptance-flows" "$(cat "$AF_STDERR")"
assert_contains "acceptance-flows: required failure heading shown" "Required flow failures:" "$(cat "$AF_STDERR")"
assert_eq "acceptance-flows: result status persisted" "fail" "$(jq -r '.results["api-smoke"].status' "$FIXTURE_AF/.claude/state/acceptance-flows/state.json")"
assert_eq "acceptance-flows: run_when skip persisted" "skipped" "$(jq -r '.results["docs-preview"].status' "$FIXTURE_AF/.claude/state/acceptance-flows/state.json")"
assert_true "acceptance-flows: stdout artifact written" test -f "$FIXTURE_AF/.claude/state/acceptance-flows/artifacts/api-smoke.stdout.log"
assert_true "acceptance-flows: stderr artifact written" test -f "$FIXTURE_AF/.claude/state/acceptance-flows/artifacts/api-smoke.stderr.log"

rm -rf "$FIXTURE_AF" "$AF_STDOUT" "$AF_STDERR"

FIXTURE_AF2=$(make_fixture)
mkdir -p "$FIXTURE_AF2/scripts"
cat > "$FIXTURE_AF2/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates", "acceptance-flows"],
  "quality-gates": {
    "gates": [{ "name": "pass-gate", "command": "true", "weight": 100 }]
  },
  "acceptance-flows": {
    "flows": [
      {
        "name": "api-smoke",
        "command": "./scripts/api-smoke.sh",
        "required": true
      },
      {
        "name": "docs-preview",
        "command": "./scripts/docs-preview.sh",
        "required": false
      }
    ]
  }
}
EOF
cat > "$FIXTURE_AF2/scripts/api-smoke.sh" <<'EOF'
#!/usr/bin/env bash
echo "api smoke ok"
exit 0
EOF
cat > "$FIXTURE_AF2/scripts/docs-preview.sh" <<'EOF'
#!/usr/bin/env bash
echo "preview broke" >&2
exit 1
EOF
chmod +x "$FIXTURE_AF2/scripts/api-smoke.sh" "$FIXTURE_AF2/scripts/docs-preview.sh"
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: ["src/api/route.ts"] }' > "$FIXTURE_AF2/.claude/state/kernel.json"
mkdir -p "$FIXTURE_AF2/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false,"baseline":null}' > "$FIXTURE_AF2/.claude/state/quality-gates/state.json"

AF2_STDOUT=$(mktemp); AF2_STDERR=$(mktemp)
run_kernel "$FIXTURE_AF2" "Stop" '{"stop_hook_active":false}' "$AF2_STDOUT" "$AF2_STDERR"
assert_eq "acceptance-flows: optional failure does not block" "0" "$?"
assert_contains "acceptance-flows: optional failure section shown" "Optional flow failures (non-blocking):" "$(cat "$AF2_STDERR")"
assert_eq "acceptance-flows: required pass persisted" "pass" "$(jq -r '.results["api-smoke"].status' "$FIXTURE_AF2/.claude/state/acceptance-flows/state.json")"
assert_eq "acceptance-flows: optional failure persisted" "fail" "$(jq -r '.results["docs-preview"].status' "$FIXTURE_AF2/.claude/state/acceptance-flows/state.json")"

rm -rf "$FIXTURE_AF2" "$AF2_STDOUT" "$AF2_STDERR"

FIXTURE_AF3=$(make_fixture)
cat > "$FIXTURE_AF3/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates", "acceptance-flows"],
  "quality-gates": {
    "gates": [{ "name": "fail-gate", "command": "false", "weight": 100 }]
  },
  "acceptance-flows": {
    "flows": [
      {
        "name": "api-smoke",
        "command": "echo should-not-run",
        "required": true
      }
    ]
  }
}
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: ["src/api/route.ts"] }' > "$FIXTURE_AF3/.claude/state/kernel.json"
mkdir -p "$FIXTURE_AF3/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false,"baseline":null}' > "$FIXTURE_AF3/.claude/state/quality-gates/state.json"

AF3_STDOUT=$(mktemp); AF3_STDERR=$(mktemp)
run_kernel "$FIXTURE_AF3" "Stop" '{"stop_hook_active":false}' "$AF3_STDOUT" "$AF3_STDERR"
assert_eq "acceptance-flows: core failure keeps post phase from running" "2" "$?"
assert_false "acceptance-flows: no post-phase state written when core fails" test -f "$FIXTURE_AF3/.claude/state/acceptance-flows/state.json"
assert_false "acceptance-flows: no post-phase feedback when core fails" grep -F "acceptance-flows:" "$AF3_STDERR"

rm -rf "$FIXTURE_AF3" "$AF3_STDOUT" "$AF3_STDERR"

# ── session summaries ─────────────────────────────────

echo ""
echo "-- session summaries ---------------------"

# Summary appended on completion
FIXTURE_SS=$(make_fixture)
install_package "$FIXTURE_SS" "quality-gates"
cat > "$FIXTURE_SS/.claude/looper.json" <<'EOF'
{ "max_iterations": 10, "packages": ["quality-gates"], "quality-gates": { "gates": [{ "name": "pass", "command": "true", "weight": 100 }] } }
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_SS/.claude/state/kernel.json"
mkdir -p "$FIXTURE_SS/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false,"baseline":null}' > "$FIXTURE_SS/.claude/state/quality-gates/state.json"

SS_STDOUT=$(mktemp); SS_STDERR=$(mktemp)
run_kernel "$FIXTURE_SS" "Stop" '{"stop_hook_active":false}' "$SS_STDOUT" "$SS_STDERR"
assert_eq "summary: completion exits 0" "0" "$?"
assert_true "summary: sessions.jsonl created" test -f "$FIXTURE_SS/.claude/state/sessions.jsonl"
assert_eq "summary: status is complete" "complete" "$(jq -r '.status' "$FIXTURE_SS/.claude/state/sessions.jsonl")"
assert_eq "summary: score recorded" "100" "$(jq -r '.score' "$FIXTURE_SS/.claude/state/sessions.jsonl")"
assert_eq "summary: has timestamp" "true" "$(jq -e '.timestamp' "$FIXTURE_SS/.claude/state/sessions.jsonl" >/dev/null 2>&1 && echo true || echo false)"
assert_false "summary: session-current.json cleaned up" test -f "$FIXTURE_SS/.claude/state/session-current.json"

rm -rf "$FIXTURE_SS" "$SS_STDOUT" "$SS_STDERR"

# session-current.json written on continue (exit 2)
FIXTURE_SS2=$(make_fixture)
install_package "$FIXTURE_SS2" "quality-gates"
cat > "$FIXTURE_SS2/.claude/looper.json" <<'EOF'
{ "max_iterations": 10, "packages": ["quality-gates"], "quality-gates": { "gates": [{ "name": "fail", "command": "false", "weight": 100 }] } }
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_SS2/.claude/state/kernel.json"
mkdir -p "$FIXTURE_SS2/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false,"baseline":null}' > "$FIXTURE_SS2/.claude/state/quality-gates/state.json"

SS2_STDOUT=$(mktemp); SS2_STDERR=$(mktemp)
run_kernel "$FIXTURE_SS2" "Stop" '{"stop_hook_active":false}' "$SS2_STDOUT" "$SS2_STDERR"
assert_eq "summary: continue exits 2" "2" "$?"
assert_true "summary: session-current.json created" test -f "$FIXTURE_SS2/.claude/state/session-current.json"
assert_eq "summary: current status is in_progress" "in_progress" "$(jq -r '.status' "$FIXTURE_SS2/.claude/state/session-current.json")"

rm -rf "$FIXTURE_SS2" "$SS2_STDOUT" "$SS2_STDERR"

# Incomplete session promoted on next SessionStart
FIXTURE_SS3=$(make_fixture)
install_package "$FIXTURE_SS3" "quality-gates"
cat > "$FIXTURE_SS3/.claude/looper.json" <<'EOF'
{ "max_iterations": 10, "packages": ["quality-gates"], "quality-gates": { "gates": [{ "name": "pass", "command": "true", "weight": 100 }] } }
EOF
mkdir -p "$FIXTURE_SS3/.claude/state"
# Simulate a leftover session-current.json from a budget-exhausted session
jq -n '{status:"in_progress",timestamp:"2025-01-01T00:00:00Z",iteration:10,max_iterations:10,score:50,total:100,introduced_failures:1,preexisting_failures:0,score_history:[50]}' > "$FIXTURE_SS3/.claude/state/session-current.json"

SS3_STDOUT=$(mktemp); SS3_STDERR=$(mktemp)
run_kernel "$FIXTURE_SS3" "SessionStart" "" "$SS3_STDOUT" "$SS3_STDERR"
assert_eq "summary: promotion exits 0" "0" "$?"
assert_true "summary: sessions.jsonl created by promotion" test -f "$FIXTURE_SS3/.claude/state/sessions.jsonl"
assert_eq "summary: promoted status is budget_exhausted" "budget_exhausted" "$(jq -r '.status' "$FIXTURE_SS3/.claude/state/sessions.jsonl")"
assert_false "summary: session-current.json removed after promotion" test -f "$FIXTURE_SS3/.claude/state/session-current.json"

rm -rf "$FIXTURE_SS3" "$SS3_STDOUT" "$SS3_STDERR"

# ── adaptive recommendations ──────────────────────────

echo ""
echo "-- adaptive recommendations --------------"

FIXTURE_REC=$(make_fixture)
cat > "$FIXTURE_REC/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [{ "name": "test", "command": "npm test", "weight": 100 }]
  }
}
EOF
mkdir -p "$FIXTURE_REC/.claude/state"
cat > "$FIXTURE_REC/.claude/state/sessions.jsonl" <<'EOF'
{"status":"budget_exhausted","timestamp":"2025-01-01T00:00:00Z","iteration":10,"max_iterations":10,"score":70,"total":100,"introduced_failures":1,"preexisting_failures":0,"score_history":[70]}
{"status":"budget_exhausted","timestamp":"2025-01-02T00:00:00Z","iteration":10,"max_iterations":10,"score":80,"total":100,"introduced_failures":1,"preexisting_failures":0,"score_history":[80]}
EOF
jq -n '{ iteration: 0, max_iterations: 10, status: "running", files_touched: ["src/a.ts","src/b.ts","src/c.ts","src/d.ts","src/e.ts","src/f.ts","src/g.ts","src/h.ts"] }' > "$FIXTURE_REC/.claude/state/kernel.json"

(
  source "$PROJECT_DIR/packages/quality-gates/lib/recommendations.sh"
  recommendations_json \
    "$FIXTURE_REC/.claude/state/sessions.jsonl" \
    "$FIXTURE_REC/.claude/looper.json" \
    "$FIXTURE_REC/.claude/state/kernel.json" \
    0 \
    0 \
    0
) > /tmp/looper-rec.json 2>/dev/null
assert_contains "recommendations: enable_baseline rule emitted" "enable_baseline" "$(cat /tmp/looper-rec.json)"
assert_contains "recommendations: increase_budget rule emitted" "increase_budget" "$(cat /tmp/looper-rec.json)"
assert_contains "recommendations: add_scope_guard rule emitted" "add_scope_guard" "$(cat /tmp/looper-rec.json)"

REC_STATUS_OUT=$(bash "$PROJECT_DIR/packages/quality-gates/lib/status-report.sh" "$FIXTURE_REC")
assert_contains "status-report: prints recommendations heading" "Recommendations:" "$REC_STATUS_OUT"
assert_contains "status-report: mentions baseline" 'Consider enabling `"quality-gates".baseline`.' "$REC_STATUS_OUT"
assert_contains "status-report: mentions scope-guard" 'Consider adding `scope-guard`' "$REC_STATUS_OUT"

rm -rf "$FIXTURE_REC"

# Stop feedback includes adaptive suggestions
FIXTURE_REC2=$(make_fixture)
install_package "$FIXTURE_REC2" "quality-gates"
cat > "$FIXTURE_REC2/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [{ "name": "fail", "command": "false", "weight": 100 }]
  }
}
EOF
mkdir -p "$FIXTURE_REC2/.claude/state/quality-gates"
echo '{"scores":[],"checks":{},"satisfied":false,"baseline":null}' > "$FIXTURE_REC2/.claude/state/quality-gates/state.json"
jq -n '{ iteration: 3, max_iterations: 10, status: "running", files_touched: ["src/a.ts","src/b.ts","src/c.ts","src/d.ts","src/e.ts","src/f.ts","src/g.ts","src/h.ts"] }' > "$FIXTURE_REC2/.claude/state/kernel.json"

REC2_STDOUT=$(mktemp); REC2_STDERR=$(mktemp)
run_kernel "$FIXTURE_REC2" "Stop" '{"stop_hook_active":false}' "$REC2_STDOUT" "$REC2_STDERR"
assert_eq "adaptive coaching: failing stop exits 2" "2" "$?"
assert_contains "adaptive coaching: suggestions heading shown" "Suggestions:" "$(cat "$REC2_STDERR")"
assert_contains "adaptive coaching: baseline suggestion shown" 'Consider enabling `"quality-gates".baseline`.' "$(cat "$REC2_STDERR")"
assert_contains "adaptive coaching: scope-guard suggestion shown" 'Consider adding `scope-guard`' "$(cat "$REC2_STDERR")"

rm -rf "$FIXTURE_REC2" "$REC2_STDOUT" "$REC2_STDERR"

# ── Trajectory analysis ─────────────────────────────────

echo ""
echo "-- trajectory analysis --------------------"

# Unit tests: detect_trajectory
(
  source "$PROJECT_DIR/packages/quality-gates/lib/trajectory.sh"

  # Too early: 1 score
  result=$(detect_trajectory '[40]' 100)
  pattern=$(echo "$result" | jq -r '.pattern')
  assert_eq "trajectory: 1 score returns null" "null" "$pattern"

  # Too early: 2 scores
  result=$(detect_trajectory '[40, 40]' 100)
  pattern=$(echo "$result" | jq -r '.pattern')
  assert_eq "trajectory: 2 scores returns null" "null" "$pattern"

  # Improving: no pattern
  result=$(detect_trajectory '[0, 30, 60]' 100)
  pattern=$(echo "$result" | jq -r '.pattern')
  assert_eq "trajectory: improving scores return null" "null" "$pattern"

  # Improving (4 scores): no pattern
  result=$(detect_trajectory '[0, 30, 50, 70]' 100)
  pattern=$(echo "$result" | jq -r '.pattern')
  assert_eq "trajectory: 4 improving scores return null" "null" "$pattern"

  # Plateau: 3 identical scores
  result=$(detect_trajectory '[40, 40, 40]' 100)
  pattern=$(echo "$result" | jq -r '.pattern')
  assert_eq "trajectory: plateau detected (3 scores)" "plateau" "$pattern"
  assert_contains "trajectory: plateau detail mentions unchanged" "unchanged" "$(echo "$result" | jq -r '.detail')"

  # Extended plateau: 5 identical scores
  result=$(detect_trajectory '[40, 40, 40, 40, 40]' 100)
  detail=$(echo "$result" | jq -r '.detail')
  assert_contains "trajectory: extended plateau shows 5 passes" "5 passes" "$detail"

  # Oscillation: alternating pattern
  result=$(detect_trajectory '[40, 60, 40, 60]' 100)
  pattern=$(echo "$result" | jq -r '.pattern')
  assert_eq "trajectory: oscillation detected" "oscillation" "$pattern"
  assert_contains "trajectory: oscillation detail shows values" "40 -> 60 -> 40 -> 60" "$(echo "$result" | jq -r '.detail')"

  # Regression: score declining from peak
  result=$(detect_trajectory '[40, 60, 30]' 100)
  pattern=$(echo "$result" | jq -r '.pattern')
  assert_eq "trajectory: regression detected (3 scores)" "regression" "$pattern"
  assert_contains "trajectory: regression detail mentions drop" "dropped" "$(echo "$result" | jq -r '.detail')"

  # Regression: 4 scores, declining at end
  result=$(detect_trajectory '[30, 50, 60, 40]' 100)
  pattern=$(echo "$result" | jq -r '.pattern')
  assert_eq "trajectory: regression detected (4 scores)" "regression" "$pattern"
)

# Unit tests: trajectory_coaching
(
  source "$PROJECT_DIR/packages/quality-gates/lib/trajectory.sh"

  # Budget boundary: remaining=1 suppresses coaching
  out=$(trajectory_coaching '[40, 40, 40]' 100 1)
  assert_eq "trajectory coaching: suppressed at remaining=1" "" "$out"

  # Budget boundary: remaining=0 suppresses coaching
  out=$(trajectory_coaching '[40, 40, 40]' 100 0)
  assert_eq "trajectory coaching: suppressed at remaining=0" "" "$out"

  # Plateau coaching emitted when remaining > 1
  out=$(trajectory_coaching '[40, 40, 40]' 100 5)
  assert_contains "trajectory coaching: plateau emits TRAJECTORY prefix" "TRAJECTORY:" "$out"
  assert_contains "trajectory coaching: plateau suggests different strategy" "different strategy" "$out"

  # Oscillation coaching
  out=$(trajectory_coaching '[40, 60, 40, 60]' 100 5)
  assert_contains "trajectory coaching: oscillation emits TRAJECTORY prefix" "TRAJECTORY:" "$out"
  assert_contains "trajectory coaching: oscillation suggests addressing together" "together" "$out"

  # Regression coaching
  out=$(trajectory_coaching '[40, 60, 30]' 100 5)
  assert_contains "trajectory coaching: regression emits TRAJECTORY prefix" "TRAJECTORY:" "$out"
  assert_contains "trajectory coaching: regression suggests reverting" "reverting" "$out"

  # No pattern: empty output
  out=$(trajectory_coaching '[0, 30, 60]' 100 5)
  assert_eq "trajectory coaching: improving gives empty output" "" "$out"
)

# Integration test: trajectory coaching appears in stop hook output
FIXTURE_TRAJ=$(make_fixture)
install_package "$FIXTURE_TRAJ" "quality-gates"
cat > "$FIXTURE_TRAJ/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [{ "name": "fail", "command": "false", "weight": 100 }]
  }
}
EOF
mkdir -p "$FIXTURE_TRAJ/.claude/state/quality-gates"
echo '{"scores":[0,0],"checks":{},"satisfied":false,"baseline":null}' > "$FIXTURE_TRAJ/.claude/state/quality-gates/state.json"
jq -n '{ iteration: 2, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_TRAJ/.claude/state/kernel.json"

TRAJ_STDOUT=$(mktemp); TRAJ_STDERR=$(mktemp)
run_kernel "$FIXTURE_TRAJ" "Stop" '{"stop_hook_active":false}' "$TRAJ_STDOUT" "$TRAJ_STDERR"
assert_eq "trajectory integration: stop exits 2" "2" "$?"
assert_contains "trajectory integration: plateau coaching in stop output" "TRAJECTORY:" "$(cat "$TRAJ_STDERR")"
assert_contains "trajectory integration: mentions unchanged" "unchanged" "$(cat "$TRAJ_STDERR")"

rm -rf "$FIXTURE_TRAJ" "$TRAJ_STDOUT" "$TRAJ_STDERR"

# Integration test: no trajectory when improving
# Use two gates: one passes (60pts), one fails (40pts). Score = 60.
# With history [20, 40], new score 60 -> [20, 40, 60] = improving.
FIXTURE_TRAJ2=$(make_fixture)
install_package "$FIXTURE_TRAJ2" "quality-gates"
cat > "$FIXTURE_TRAJ2/.claude/looper.json" <<'EOF'
{
  "max_iterations": 10,
  "packages": ["quality-gates"],
  "quality-gates": {
    "gates": [
      { "name": "pass-gate", "command": "true", "weight": 60 },
      { "name": "fail-gate", "command": "false", "weight": 40 }
    ]
  }
}
EOF
mkdir -p "$FIXTURE_TRAJ2/.claude/state/quality-gates"
echo '{"scores":[20,40],"checks":{},"satisfied":false,"baseline":null}' > "$FIXTURE_TRAJ2/.claude/state/quality-gates/state.json"
jq -n '{ iteration: 2, max_iterations: 10, status: "running", files_touched: [] }' > "$FIXTURE_TRAJ2/.claude/state/kernel.json"

TRAJ2_STDOUT=$(mktemp); TRAJ2_STDERR=$(mktemp)
run_kernel "$FIXTURE_TRAJ2" "Stop" '{"stop_hook_active":false}' "$TRAJ2_STDOUT" "$TRAJ2_STDERR"
# Should NOT contain trajectory coaching since scores are improving
if grep -Fq "TRAJECTORY:" "$TRAJ2_STDERR"; then
  FAIL=$((FAIL + 1))
  ERRORS="${ERRORS}\n  x trajectory integration: no coaching when improving"
  echo "  x trajectory integration: no coaching when improving"
else
  PASS=$((PASS + 1))
  echo "  v trajectory integration: no coaching when improving"
fi

rm -rf "$FIXTURE_TRAJ2" "$TRAJ2_STDOUT" "$TRAJ2_STDERR"

# ── Summary ─────────────────────────────────────────────

TOTAL_TESTS=$((PASS + FAIL))
echo ""
echo "=========================================="
printf "  %d/%d passed\n" "$PASS" "$TOTAL_TESTS"
echo "=========================================="

if [ -n "$ERRORS" ]; then
  echo ""
  echo "Failures:"
  echo -e "$ERRORS"
fi

# Coverage summary
PCT=$(awk "BEGIN { printf \"%.1f\", ($PASS / ($TOTAL_TESTS > 0 ? $TOTAL_TESTS : 1)) * 100 }")
mkdir -p "$COVERAGE_DIR"
cat > "$COVERAGE_FILE" <<EOF
{
  "total": {
    "lines":      { "total": $TOTAL_TESTS, "covered": $PASS, "skipped": 0, "pct": $PCT },
    "statements": { "total": $TOTAL_TESTS, "covered": $PASS, "skipped": 0, "pct": $PCT },
    "functions":  { "total": $TOTAL_TESTS, "covered": $PASS, "skipped": 0, "pct": $PCT },
    "branches":   { "total": $TOTAL_TESTS, "covered": $PASS, "skipped": 0, "pct": $PCT }
  }
}
EOF

[ "$FAIL" -eq 0 ]
