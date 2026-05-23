#!/usr/bin/env bash
set -euo pipefail

GATEWAY_LABEL="com.shiraoku.grok-signal-agent.hermes-gateway"
HEALTHCHECK_LABEL="com.shiraoku.grok-signal-agent.hermes-gateway-healthcheck"
HEARTBEAT_LABEL="com.shiraoku.grok-signal-agent.discord-heartbeat"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_BIN="${HOME}/.local/bin/hermes"
GUI_DOMAIN="gui/$(id -u)"

if [[ ! -x "${HERMES_BIN}" ]]; then
  echo "Hermes is not installed at ${HERMES_BIN}."
  echo "Install Hermes first, then run this script again."
  exit 1
fi

mkdir -p "${HOME}/.hermes/bin" "${HOME}/.hermes/logs" "${HOME}/.hermes/state" "${HOME}/Library/LaunchAgents"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-gateway-healthcheck.sh" \
  "${HOME}/.hermes/bin/hermes-gateway-healthcheck.sh"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-discord-heartbeat.sh" \
  "${HOME}/.hermes/bin/hermes-discord-heartbeat.sh"

render_plist() {
  local label="$1"
  local template="${REPO_DIR}/launchd/${label}.plist"
  local target="${HOME}/Library/LaunchAgents/${label}.plist"

  sed \
    -e "s|__HOME__|${HOME}|g" \
    -e "s|__REPO__|${REPO_DIR}|g" \
    "${template}" > "${target}"
}

install_agent() {
  local label="$1"
  local target="${HOME}/Library/LaunchAgents/${label}.plist"

  launchctl bootout "${GUI_DOMAIN}" "${target}" >/dev/null 2>&1 || true
  launchctl bootstrap "${GUI_DOMAIN}" "${target}"
  launchctl enable "${GUI_DOMAIN}/${label}"
}

pmset -g log 2>/dev/null | awk '
  $4 == "Wake" || $4 == "DarkWake" || $4 == "FullWake" {
    event = $1 " " $2 " " $3 " " $4
  }
  END {
    if (event != "") print event
  }
' > "${HOME}/.hermes/state/last-wake-event" || true

render_plist "${GATEWAY_LABEL}"
render_plist "${HEALTHCHECK_LABEL}"
render_plist "${HEARTBEAT_LABEL}"

install_agent "${GATEWAY_LABEL}"
install_agent "${HEALTHCHECK_LABEL}"
install_agent "${HEARTBEAT_LABEL}"

launchctl kickstart -k "${GUI_DOMAIN}/${GATEWAY_LABEL}"
launchctl kickstart -k "${GUI_DOMAIN}/${HEALTHCHECK_LABEL}"

echo "Installed and started ${GATEWAY_LABEL}"
echo "Installed and started ${HEALTHCHECK_LABEL}"
echo "Installed ${HEARTBEAT_LABEL}; it will run at its scheduled times"
echo "Status:"
launchctl print "${GUI_DOMAIN}/${GATEWAY_LABEL}" | sed -n '1,80p'
