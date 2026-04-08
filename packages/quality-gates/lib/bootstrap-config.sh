#!/usr/bin/env bash
# quality-gates/lib/bootstrap-config.sh
# Inspect repo truth, synthesize a Looper config, and optionally render a doctor report.

set -euo pipefail

MODE="${1:-inspect}"
ROOT="${2:-.}"

PACKAGE_JSON="$ROOT/package.json"
CURRENT_CONFIG="$ROOT/.claude/looper.json"

VERIFIED=()
ASSUMPTIONS=()
UNRESOLVED=()

note_verified() {
  VERIFIED+=("$1")
}

note_assumption() {
  ASSUMPTIONS+=("$1")
}

note_unresolved() {
  UNRESOLVED+=("$1")
}

json_array_from_args() {
  if [ "$#" -eq 0 ]; then
    echo '[]'
    return 0
  fi
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

has_file() {
  [ -f "$ROOT/$1" ]
}

has_any_file() {
  local file
  for file in "$@"; do
    if [ -f "$ROOT/$file" ]; then
      return 0
    fi
  done
  return 1
}

package_json_exists() {
  [ -f "$PACKAGE_JSON" ]
}

package_script_value() {
  local key="$1"
  if ! package_json_exists; then
    return 1
  fi
  jq -r --arg key "$key" '.scripts[$key] // empty' "$PACKAGE_JSON"
}

package_has_script() {
  local key="$1"
  [ -n "$(package_script_value "$key" 2>/dev/null || true)" ]
}

package_has_dep() {
  local name="$1"
  if ! package_json_exists; then
    return 1
  fi
  jq -e --arg name "$name" '
    (.dependencies // {})[$name] != null
    or (.devDependencies // {})[$name] != null
  ' "$PACKAGE_JSON" >/dev/null 2>&1
}

package_script_mentions() {
  local key="$1" pattern="$2"
  local value
  value="$(package_script_value "$key" 2>/dev/null || true)"
  [ -n "$value" ] && printf '%s' "$value" | grep -Eiq "$pattern"
}

detect_package_manager() {
  if has_any_file "pnpm-lock.yaml"; then
    echo "pnpm"
  elif has_any_file "bun.lock" "bun.lockb"; then
    echo "bun"
  elif has_any_file "yarn.lock"; then
    echo "yarn"
  else
    echo "npm"
  fi
}

run_script_command() {
  local package_manager="$1" script_name="$2"
  case "$package_manager" in
    npm)
      if [ "$script_name" = "test" ]; then
        echo "npm test"
      else
        echo "npm run $script_name"
      fi
      ;;
    pnpm)
      if [ "$script_name" = "test" ]; then
        echo "pnpm test"
      else
        echo "pnpm run $script_name"
      fi
      ;;
    yarn)
      echo "yarn $script_name"
      ;;
    bun)
      echo "bun run $script_name"
      ;;
    *)
      echo "npm run $script_name"
      ;;
  esac
}

makefile_has_target() {
  local target="$1"
  [ -f "$ROOT/Makefile" ] && grep -Eq "^${target}:" "$ROOT/Makefile"
}

detect_stack() {
  if has_file "Cargo.toml"; then
    echo "rust"
    return 0
  fi
  if has_file "go.mod"; then
    echo "go"
    return 0
  fi
  if has_any_file "pyproject.toml" "requirements.txt"; then
    echo "python"
    return 0
  fi
  if has_any_file "deno.json" "deno.jsonc"; then
    echo "deno"
    return 0
  fi
  if has_file "tsconfig.json"; then
    local use_biome="false"
    if has_any_file "biome.json" "biome.jsonc" || package_has_dep "biome" || package_has_dep "@biomejs/biome" ||
      package_script_mentions "lint" "biome" || package_script_mentions "format" "biome"; then
      use_biome="true"
    fi
    if [ "$use_biome" = "true" ] && ! package_script_mentions "lint" "eslint"; then
      echo "typescript-biome"
    else
      echo "typescript-eslint"
    fi
    return 0
  fi
  echo "minimal"
}

load_base_config() {
  local stack="$1"
  local preset_file="$ROOT/does-not-exist"
  preset_file="$(cd "$(dirname "$0")/.." && pwd)/presets/${stack}.json"
  [ -f "$preset_file" ] || preset_file="$(cd "$(dirname "$0")/.." && pwd)/presets/minimal.json"

  jq -n --argjson pkgs '["quality-gates"]' --slurpfile qg "$preset_file" '{
    max_iterations: 10,
    packages: $pkgs,
    "quality-gates": $qg[0]
  }'
}

replace_gate_command() {
  local config_json="$1" gate_name="$2" command="$3"
  echo "$config_json" | jq --arg gate "$gate_name" --arg command "$command" '
    .["quality-gates"].gates |= map(
      if .name == $gate then
        .command = $command | del(.skip_if_missing)
      else
        .
      end
    )
  '
}

replace_check_command() {
  local config_json="$1" check_name="$2" command="$3" fix="${4:-}"
  if [ -n "$fix" ]; then
    echo "$config_json" | jq --arg name "$check_name" --arg command "$command" --arg fix "$fix" '
      .["quality-gates"].checks |= map(
        if .name == $name then
          .command = $command | .fix = $fix | del(.skip_if_missing)
        else
          .
        end
      )
    '
  else
    echo "$config_json" | jq --arg name "$check_name" --arg command "$command" '
      .["quality-gates"].checks |= map(
        if .name == $name then
          .command = $command | del(.skip_if_missing)
        else
          .
        end
      )
    '
  fi
}

remove_gate() {
  local config_json="$1" gate_name="$2"
  echo "$config_json" | jq --arg gate "$gate_name" '
    .["quality-gates"].gates |= map(select(.name != $gate))
  '
}

redistribute_gate_weights() {
  local config_json="$1"
  echo "$config_json" | jq '
    .["quality-gates"].gates as $gates
    | ($gates | map(select(.required != false)) | length) as $required_count
    | if $required_count == 0 then
        .
      else
        .["quality-gates"].gates = (
          if ($gates | length) == 1 then
            [$gates[0] | .weight = 100]
          elif ($gates | map(.name) | index("coverage")) != null and ($gates | length) == 4 then
            $gates
          elif ($gates | map(.name) | index("typecheck")) != null and ($gates | map(.name) | index("lint")) != null and ($gates | map(.name) | index("test")) != null and ($gates | length) == 3 then
            ($gates | map(
              if .name == "typecheck" then .weight = 35
              elif .name == "lint" then .weight = 25
              elif .name == "test" then .weight = 40
              else .
              end
            ))
          else
            ($gates
              | to_entries
              | map(.value.weight = (if .key == (length - 1) then 100 - (20 * .key) else 20 end))
              | map(.value)
            )
          end
        )
      end
  '
}

python_uses_pyproject_tool() {
  local tool="$1"
  [ -f "$ROOT/pyproject.toml" ] && grep -Eq "^\[tool\\.${tool}\]" "$ROOT/pyproject.toml"
}

config_lines_from_json() {
  local config_json="$1"
  echo "$config_json" | jq -r '
    [
      "max_iterations:\(.max_iterations // 10)",
      (.packages // [] | .[] | "package:\(.)"),
      (."quality-gates".gates // [] | .[] | "gate:\(.name)\t\(.command)"),
      (."quality-gates".checks // [] | .[] | "check:\(.name)\t\(.command)\t\(.pattern // "")")
    ] | .[]
  '
}

drift_json() {
  local proposed_config="$1"
  if [ ! -f "$CURRENT_CONFIG" ]; then
    echo '[]'
    return 0
  fi

  local current_lines proposed_lines
  current_lines="$(config_lines_from_json "$(cat "$CURRENT_CONFIG")" | LC_ALL=C sort)"
  proposed_lines="$(config_lines_from_json "$proposed_config" | LC_ALL=C sort)"

  local added removed
  added="$(comm -13 <(printf '%s\n' "$current_lines") <(printf '%s\n' "$proposed_lines") | sed '/^$/d' || true)"
  removed="$(comm -23 <(printf '%s\n' "$current_lines") <(printf '%s\n' "$proposed_lines") | sed '/^$/d' || true)"

  {
    if [ -n "$added" ]; then
      printf '%s\n' "$added" | sed 's/^/add\t/'
    fi
    if [ -n "$removed" ]; then
      printf '%s\n' "$removed" | sed 's/^/remove\t/'
    fi
  } | jq -Rsc '
    split("\n")
    | map(select(length > 0))
    | map(split("\t"))
    | map({change: .[0], item: .[1]})
  '
}

synthesize_report() {
  local stack package_manager config_json confidence verified_json assumptions_json unresolved_json drift
  stack="$(detect_stack)"
  package_manager="$(detect_package_manager)"
  config_json="$(load_base_config "$stack")"

  case "$stack" in
    rust)
      note_verified "Detected Rust from Cargo.toml."
      ;;
    go)
      note_verified "Detected Go from go.mod."
      ;;
    python)
      note_verified "Detected Python from pyproject.toml or requirements.txt."
      if has_file "pyrightconfig.json"; then
        config_json="$(replace_gate_command "$config_json" "typecheck" "pyright")"
        note_verified "Typecheck gate uses pyright from pyrightconfig.json."
      elif python_uses_pyproject_tool "mypy" || has_file "mypy.ini"; then
        note_verified "Typecheck gate uses mypy from repo config."
      else
        note_assumption "Typecheck gate uses the default Python mypy command."
      fi

      if python_uses_pyproject_tool "ruff"; then
        config_json="$(echo "$config_json" | jq '
          .["quality-gates"].gates |= map(
            if .name == "lint" or .name == "format" then .skip_if_missing = "pyproject.toml" else . end
          )
          | .["quality-gates"].checks |= map(
            if .name == "lint" or .name == "format" then .skip_if_missing = "pyproject.toml" else . end
          )
        ')"
        note_verified "Ruff configuration detected in pyproject.toml."
      elif has_any_file "ruff.toml" ".ruff.toml"; then
        note_verified "Ruff configuration detected from repo files."
      else
        note_assumption "Lint and format gates use the default Ruff commands."
      fi
      ;;
    deno)
      note_verified "Detected Deno from deno.json."
      ;;
    typescript-biome|typescript-eslint)
      local lint_script typecheck_script test_script coverage_script has_prettier has_eslint has_biome has_vitest has_jest
      lint_script="$(package_script_value "lint" 2>/dev/null || true)"
      typecheck_script="$(package_script_value "typecheck" 2>/dev/null || true)"
      test_script="$(package_script_value "test" 2>/dev/null || true)"
      coverage_script="$(package_script_value "coverage" 2>/dev/null || true)"
      has_prettier="false"
      has_eslint="false"
      has_biome="false"
      has_vitest="false"
      has_jest="false"

      note_verified "Detected TypeScript from tsconfig.json."

      if has_any_file ".prettierrc" ".prettierrc.json" ".prettierrc.js" ".prettierrc.cjs" ".prettierrc.yaml" ".prettierrc.yml" ||
        package_has_dep "prettier" || has_file "node_modules/.bin/prettier"; then
        has_prettier="true"
      fi
      if has_any_file ".eslintrc" ".eslintrc.js" ".eslintrc.cjs" ".eslintrc.json" "eslint.config.js" "eslint.config.mjs" "eslint.config.cjs" ||
        package_has_dep "eslint" || has_file "node_modules/.bin/eslint"; then
        has_eslint="true"
      fi
      if has_any_file "biome.json" "biome.jsonc" || package_has_dep "biome" || package_has_dep "@biomejs/biome" || has_file "node_modules/.bin/biome"; then
        has_biome="true"
      fi
      if has_any_file "vitest.config.ts" "vitest.config.js" "vitest.config.mjs" "vitest.config.cjs" ||
        package_has_dep "vitest" || has_file "node_modules/.bin/vitest"; then
        has_vitest="true"
      fi
      if has_any_file "jest.config.js" "jest.config.cjs" "jest.config.mjs" "jest.config.ts" ||
        package_has_dep "jest"; then
        has_jest="true"
      fi

      if [ -n "$typecheck_script" ]; then
        config_json="$(replace_gate_command "$config_json" "typecheck" "$(run_script_command "$package_manager" "typecheck")")"
        note_verified "Typecheck gate uses package.json script via $package_manager."
      else
        note_assumption "Typecheck gate uses the default TypeScript command."
      fi

      if [ -n "$lint_script" ]; then
        config_json="$(replace_gate_command "$config_json" "lint" "$(run_script_command "$package_manager" "lint")")"
        note_verified "Lint gate uses package.json script via $package_manager."
      elif [ "$stack" = "typescript-biome" ] && [ "$has_biome" = "true" ]; then
        note_verified "Biome detected for lint and format checks."
      elif [ "$stack" = "typescript-eslint" ] && [ "$has_eslint" = "true" ]; then
        note_verified "ESLint detected for lint checks."
      else
        note_unresolved "No explicit lint signal found; using the stack default lint command."
      fi

      if [ -n "$test_script" ]; then
        config_json="$(replace_gate_command "$config_json" "test" "$(run_script_command "$package_manager" "test")")"
        note_verified "Test gate uses package.json script via $package_manager."
      elif [ "$has_vitest" = "true" ]; then
        config_json="$(replace_gate_command "$config_json" "test" "npx vitest run")"
        note_verified "Vitest detected for the test gate."
      elif [ "$has_jest" = "true" ]; then
        config_json="$(replace_gate_command "$config_json" "test" "npx jest --runInBand")"
        note_verified "Jest detected for the test gate."
      else
        note_unresolved "No explicit test command was detected; falling back to the stack default."
      fi

      if [ -n "$coverage_script" ]; then
        config_json="$(replace_gate_command "$config_json" "coverage" "$(run_script_command "$package_manager" "coverage")")"
        note_verified "Coverage gate uses package.json script via $package_manager."
      else
        note_assumption "Coverage gate remains an optional inferred preset gate."
      fi

      if [ "$stack" = "typescript-eslint" ]; then
        if [ "$has_prettier" = "true" ]; then
          note_verified "Prettier detected for per-file format checks."
        else
          note_assumption "Prettier check remains optional and skips when the binary is absent."
        fi
      fi
      ;;
    minimal)
      if package_json_exists && package_has_script "test"; then
        config_json="$(replace_gate_command "$config_json" "test" "$(run_script_command "$package_manager" "test")")"
        note_verified "Minimal bootstrap uses package.json test script via $package_manager."
      elif makefile_has_target "test"; then
        config_json="$(replace_gate_command "$config_json" "test" "make test")"
        note_verified "Minimal bootstrap uses Makefile test target."
      else
        note_unresolved "No test script or stack marker was detected; bootstrap fell back to npm test."
      fi
      ;;
  esac

  config_json="$(redistribute_gate_weights "$config_json")"
  if [ "${#VERIFIED[@]}" -gt 0 ]; then
    verified_json="$(json_array_from_args "${VERIFIED[@]}")"
  else
    verified_json='[]'
  fi
  if [ "${#ASSUMPTIONS[@]}" -gt 0 ]; then
    assumptions_json="$(json_array_from_args "${ASSUMPTIONS[@]}")"
  else
    assumptions_json='[]'
  fi
  if [ "${#UNRESOLVED[@]}" -gt 0 ]; then
    unresolved_json="$(json_array_from_args "${UNRESOLVED[@]}")"
  else
    unresolved_json='[]'
  fi
  drift="$(drift_json "$config_json")"

  if [ "$stack" = "minimal" ] || [ "${#UNRESOLVED[@]}" -ge 2 ]; then
    confidence="low"
  elif [ "${#UNRESOLVED[@]}" -ge 1 ] || [ "${#ASSUMPTIONS[@]}" -ge 2 ]; then
    confidence="medium"
  else
    confidence="high"
  fi

  jq -n \
    --arg stack "$stack" \
    --arg package_manager "$package_manager" \
    --arg confidence "$confidence" \
    --argjson config "$config_json" \
    --argjson verified "$verified_json" \
    --argjson assumptions "$assumptions_json" \
    --argjson unresolved "$unresolved_json" \
    --argjson drift "$drift" \
    --arg current_exists "$(if [ -f "$CURRENT_CONFIG" ]; then echo true; else echo false; fi)" '
    {
      stack: $stack,
      package_manager: $package_manager,
      confidence: $confidence,
      current_config_exists: ($current_exists == "true"),
      verified: $verified,
      assumptions: $assumptions,
      unresolved: $unresolved,
      drift: $drift,
      config: $config
    }
  '
}

render_doctor_report() {
  local report="$1"
  local drift_count
  drift_count="$(echo "$report" | jq '.drift | length')"

  echo "Looper Doctor"
  echo ""
  echo "Repo Truth:"
  echo "$report" | jq -r '
    [
      "  Stack: \(.stack)",
      "  Package manager: \(.package_manager)",
      "  Bootstrap confidence: \(.confidence)"
    ] | .[]
  '

  if echo "$report" | jq -e '.verified | length > 0' >/dev/null 2>&1; then
    echo ""
    echo "Verified Signals:"
    echo "$report" | jq -r '.verified[] | "  - " + .'
  fi

  if echo "$report" | jq -e '.assumptions | length > 0' >/dev/null 2>&1; then
    echo ""
    echo "Assumptions:"
    echo "$report" | jq -r '.assumptions[] | "  - " + .'
  fi

  if echo "$report" | jq -e '.unresolved | length > 0' >/dev/null 2>&1; then
    echo ""
    echo "Unresolved:"
    echo "$report" | jq -r '.unresolved[] | "  - " + .'
  fi

  echo ""
  if echo "$report" | jq -e '.current_config_exists' >/dev/null 2>&1; then
    echo "Current Config Drift:"
    if [ "$drift_count" -eq 0 ]; then
      echo "  - none"
    else
      echo "$report" | jq -r '.drift[:8][] | "  - " + .change + ": " + .item'
    fi
  else
    echo "Current Config Drift:"
    echo "  - no current .claude/looper.json"
  fi

  echo ""
  echo "Proposed Gates:"
  echo "$report" | jq -r '
    .config["quality-gates"].gates[]
    | "  - \(.name): \(.command)"
  '

  if echo "$report" | jq -e '.config["quality-gates"].checks | length > 0' >/dev/null 2>&1; then
    echo ""
    echo "Proposed Checks:"
    echo "$report" | jq -r '
      .config["quality-gates"].checks[]
      | "  - \(.name): \(.command) [\(.pattern // "*")]"
    '
  fi

  echo ""
  echo "Next Step:"
  if [ "$drift_count" -eq 0 ] && echo "$report" | jq -e '.current_config_exists' >/dev/null 2>&1; then
    echo "  - Keep the current config. Run /looper:looper-config only if you want manual changes."
  else
    echo "  - Review /looper:looper-config for guided edits, or copy the proposed config into .claude/looper.json."
  fi
}

main() {
  local report
  report="$(synthesize_report)"
  case "$MODE" in
    inspect)
      echo "$report"
      ;;
    doctor)
      render_doctor_report "$report"
      ;;
    *)
      echo "Usage: bootstrap-config.sh <inspect|doctor> [root]" >&2
      exit 1
      ;;
  esac
}

main "$@"
