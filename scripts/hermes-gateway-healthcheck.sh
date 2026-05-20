#!/usr/bin/env bash
set -euo pipefail

GATEWAY_LABEL="com.shiraoku.grok-signal-agent.hermes-gateway"
GUI_DOMAIN="${GUI_DOMAIN:-gui/$(id -u)}"
GATEWAY_PLIST="${HOME}/Library/LaunchAgents/${GATEWAY_LABEL}.plist"
STATE_DIR="${HOME}/.hermes/state"
LOG_DIR="${HOME}/.hermes/logs"
WAKE_STATE="${STATE_DIR}/last-wake-event"
LOG_FILE="${LOG_DIR}/hermes-gateway-healthcheck.log"

mkdir -p "${STATE_DIR}" "${LOG_DIR}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}"
}

latest_wake_event() {
  pmset -g log 2>/dev/null | awk '
    $4 == "Wake" || $4 == "DarkWake" || $4 == "FullWake" {
      event = $1 " " $2 " " $3 " " $4
    }
    END {
      if (event != "") print event
    }
  '
}

gateway_loaded() {
  launchctl print "${GUI_DOMAIN}/${GATEWAY_LABEL}" >/dev/null 2>&1
}

gateway_running() {
  launchctl print "${GUI_DOMAIN}/${GATEWAY_LABEL}" 2>/dev/null | grep -q "state = running"
}

ensure_loaded() {
  if gateway_loaded; then
    return
  fi

  if [[ ! -f "${GATEWAY_PLIST}" ]]; then
    log "gateway plist is missing: ${GATEWAY_PLIST}"
    exit 1
  fi

  log "gateway launch agent is not loaded; bootstrapping"
  launchctl bootstrap "${GUI_DOMAIN}" "${GATEWAY_PLIST}" >/dev/null 2>&1 || true
  launchctl enable "${GUI_DOMAIN}/${GATEWAY_LABEL}" >/dev/null 2>&1 || true
}

kickstart_gateway() {
  local reason="$1"
  log "kickstarting gateway: ${reason}"
  launchctl kickstart -k "${GUI_DOMAIN}/${GATEWAY_LABEL}" >/dev/null 2>&1 || true
}

ensure_loaded

current_wake="$(latest_wake_event || true)"
previous_wake=""
if [[ -f "${WAKE_STATE}" ]]; then
  previous_wake="$(<"${WAKE_STATE}")"
fi

if [[ -n "${current_wake}" && -z "${previous_wake}" ]]; then
  printf '%s\n' "${current_wake}" > "${WAKE_STATE}"
elif [[ -n "${current_wake}" && "${current_wake}" != "${previous_wake}" ]]; then
  printf '%s\n' "${current_wake}" > "${WAKE_STATE}"
  kickstart_gateway "system wake detected (${current_wake})"
  exit 0
fi

if ! gateway_running; then
  kickstart_gateway "gateway is not running"
fi
