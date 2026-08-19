#!/usr/bin/env bash
set -euo pipefail

# Defensive operational alert helper.
#
# Always writes an alert log. Optionally sends to a Discord webhook or a custom
# command. This script must never make the caller fail just because alert
# delivery is unavailable.

LOG_FILE="${HERMES_ALERT_LOG:-${HOME}/.hermes/logs/hermes-alerts.log}"
WEBHOOK_URL="${HERMES_ALERT_DISCORD_WEBHOOK_URL:-}"
ALERT_COMMAND="${HERMES_ALERT_COMMAND:-}"
HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
ALERT_TARGET="${HERMES_ALERT_TARGET:-discord:hermes-alerts}"
TITLE="${1:-Hermes alert}"

mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true

body="$(cat 2>/dev/null || true)"
[[ -n "${body//[[:space:]]/}" ]] || body="${TITLE}"
message="$(printf '%s\n\n%s\n' "${TITLE}" "${body}")"

printf '%s %s\n%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "${TITLE}" "${body}" \
  >> "${LOG_FILE}" 2>/dev/null || true

delivered=0

if [[ -n "${WEBHOOK_URL}" ]] && command -v curl >/dev/null 2>&1; then
  if command -v jq >/dev/null 2>&1; then
    payload="$(jq -n --arg content "${message}" '{content: $content}')"
  else
    escaped="$(
      printf '%s' "${message}" \
        | sed 's/\\/\\\\/g; s/"/\\"/g' \
        | sed ':a;N;$!ba;s/\n/\\n/g; s/\r/\\r/g'
    )"
    payload="$(printf '{"content": "%s"}' "${escaped}")"
  fi
  if curl -fsS -H 'Content-Type: application/json' -d "${payload}" "${WEBHOOK_URL}" \
    >> "${LOG_FILE}" 2>&1; then
    delivered=1
  fi
fi

if [[ -n "${ALERT_COMMAND}" ]]; then
  if printf '%s' "${message}" | sh -c "${ALERT_COMMAND}" >> "${LOG_FILE}" 2>&1; then
    delivered=1
  fi
fi

# Discord delivery through `hermes send` does not require a running Gateway.
# Use it as the default and as a fallback when an explicitly configured
# webhook/command fails.
if [[ "${delivered}" == "0" && -n "${ALERT_TARGET}" && -x "${HERMES_BIN}" ]]; then
  if printf '%s' "${message}" \
    | "${HERMES_BIN}" send --to "${ALERT_TARGET}" --file - --quiet \
      >> "${LOG_FILE}" 2>&1; then
    printf '%s delivery=hermes-send target=%s status=ok\n' \
      "$(date '+%Y-%m-%d %H:%M:%S %z')" "${ALERT_TARGET}" >> "${LOG_FILE}" 2>/dev/null || true
  else
    printf '%s delivery=hermes-send target=%s status=failed\n' \
      "$(date '+%Y-%m-%d %H:%M:%S %z')" "${ALERT_TARGET}" >> "${LOG_FILE}" 2>/dev/null || true
  fi
fi

exit 0
