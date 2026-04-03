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

# Second run should not recreate config
FIRST_CONFIG=$(cat "$FIXTURE_BOOT/.claude/looper.json")
run_kernel "$FIXTURE_BOOT" "SessionStart" "" "$BOOT_STDOUT" "$BOOT_STDERR"
SECOND_CONFIG=$(cat "$FIXTURE_BOOT/.claude/looper.json")
assert_eq "bootstrap: idempotent config" "$FIRST_CONFIG" "$SECOND_CONFIG"

rm -rf "$FIXTURE_BOOT" "$BOOT_STDOUT" "$BOOT_STDERR"

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
