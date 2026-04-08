#!/usr/bin/env bash
# quality-gates/lib/doctor-report.sh
# Render a human-readable doctor report from repo truth.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-.}"

bash "$SCRIPT_DIR/bootstrap-config.sh" doctor "$ROOT"
