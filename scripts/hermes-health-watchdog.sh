#!/usr/bin/env bash
set -euo pipefail

HERMES_HOME_DIR="${HERMES_HOME:-${HOME}/.hermes}"
HEALTH_SCRIPT="${HERMES_HEALTH_SCRIPT:-${HERMES_HOME_DIR}/scripts/hermes-health-check-cron.sh}"
ALERT_SCRIPT="${HERMES_ALERT_SCRIPT:-${HERMES_HOME_DIR}/bin/hermes-alert.sh}"
STATE_FILE="${HERMES_HEALTH_WATCHDOG_STATE_FILE:-${HERMES_HOME_DIR}/state/health-watchdog.json}"
LOG_FILE="${HERMES_HEALTH_WATCHDOG_LOG:-${HERMES_HOME_DIR}/logs/hermes-health-watchdog.log}"
REMINDER_SECONDS="${HERMES_HEALTH_WATCHDOG_REMINDER_SECONDS:-3600}"

mkdir -p "$(dirname "${STATE_FILE}")" "$(dirname "${LOG_FILE}")"

[[ "${REMINDER_SECONDS}" =~ ^[0-9]+$ ]] || REMINDER_SECONDS=3600

now="$(date +%s)"
health_output=""
if [[ -x "${HEALTH_SCRIPT}" ]]; then
  health_output="$(
    HERMES_HEALTH_CHECK_LAUNCHD=1 \
    HERMES_HEALTH_CHECK_XAI=0 \
      "${HEALTH_SCRIPT}" 2>&1 || true
  )"
else
  health_output="Hermes health watchdog: health check script is missing: ${HEALTH_SCRIPT}"
fi

previous_status="healthy"
previous_fingerprint=""
last_sent=0
if [[ -f "${STATE_FILE}" ]] && command -v jq >/dev/null 2>&1; then
  previous_status="$(jq -r '.status // "healthy"' "${STATE_FILE}" 2>/dev/null || printf 'healthy')"
  previous_fingerprint="$(jq -r '.fingerprint // ""' "${STATE_FILE}" 2>/dev/null || true)"
  last_sent="$(jq -r '.last_sent // 0' "${STATE_FILE}" 2>/dev/null || printf '0')"
fi
[[ "${last_sent}" =~ ^[0-9]+$ ]] || last_sent=0

status="healthy"
fingerprint=""
if [[ -n "${health_output//[[:space:]]/}" ]]; then
  status="unhealthy"
  fingerprint="$(printf '%s' "${health_output}" | shasum -a 256 | awk '{print $1}')"
fi

sent_at="${last_sent}"
if [[ "${status}" == "unhealthy" ]]; then
  if [[ "${previous_status}" != "unhealthy" || "${fingerprint}" != "${previous_fingerprint}" || $((now - last_sent)) -ge "${REMINDER_SECONDS}" ]]; then
    if [[ -x "${ALERT_SCRIPT}" ]]; then
      printf '%s\n' "${health_output}" | "${ALERT_SCRIPT}" "Hermes runtime health alert"
    fi
    sent_at="${now}"
    printf '%s alert sent fingerprint=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "${fingerprint}" >> "${LOG_FILE}"
  fi
elif [[ "${previous_status}" == "unhealthy" ]]; then
  if [[ -x "${ALERT_SCRIPT}" ]]; then
    printf 'The previously reported Hermes runtime issue has cleared.\n' \
      | "${ALERT_SCRIPT}" "Hermes runtime recovered"
  fi
  sent_at="${now}"
  printf '%s recovery sent\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" >> "${LOG_FILE}"
fi

tmp_state="${STATE_FILE}.tmp.$$"
if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg status "${status}" \
    --arg fingerprint "${fingerprint}" \
    --argjson last_sent "${sent_at}" \
    --argjson checked_at "${now}" \
    '{status: $status, fingerprint: $fingerprint, last_sent: $last_sent, checked_at: $checked_at}' \
    > "${tmp_state}"
  mv "${tmp_state}" "${STATE_FILE}"
fi

exit 0
