#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${HERMES_X_PULSE_WATCHER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
CONFIG_FILE="${HERMES_X_PULSE_WATCHER_CONFIG:-${REPO_DIR}/config/x-pulse-watchers.json}"

exec "${PYTHON_BIN}" "${REPO_DIR}/scripts/hermes-x-pulse-watcher.py" --config "${CONFIG_FILE}" "$@"
