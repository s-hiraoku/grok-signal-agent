#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -x "${SCRIPT_DIR}/hermes-discord-jobs.sh" ]]; then
  RUNNER="${SCRIPT_DIR}/hermes-discord-jobs.sh"
elif [[ -x "${HOME}/.hermes/bin/hermes-discord-jobs.sh" ]]; then
  RUNNER="${HOME}/.hermes/bin/hermes-discord-jobs.sh"
else
  echo "missing hermes-discord-jobs.sh" >&2
  exit 1
fi

exec "${RUNNER}" --job "${HERMES_DISCORD_HEARTBEAT_JOB:-tech-digest}" --force "$@"
