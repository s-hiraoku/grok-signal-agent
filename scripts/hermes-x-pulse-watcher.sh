#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO="${HOME}/.hermes/runtime/grok-signal-agent"
if [[ ! -f "${DEFAULT_REPO}/scripts/hermes-x-pulse-watcher.py" ]]; then
  DEFAULT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
REPO_DIR="${HERMES_X_PULSE_WATCHER_REPO:-${DEFAULT_REPO}}"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
CONFIG_FILE="${HERMES_X_PULSE_WATCHER_CONFIG:-${REPO_DIR}/config/x-pulse-watchers.json}"

exec "${PYTHON_BIN}" "${REPO_DIR}/scripts/hermes-x-pulse-watcher.py" --config "${CONFIG_FILE}" "$@"
