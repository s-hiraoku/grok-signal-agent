#!/usr/bin/env bash
set -euo pipefail

LABELS=(
  "com.shiraoku.grok-signal-agent.discord-heartbeat"
  "com.shiraoku.grok-signal-agent.hermes-gateway-healthcheck"
  "com.shiraoku.grok-signal-agent.hermes-gateway"
)
GUI_DOMAIN="gui/$(id -u)"

for label in "${LABELS[@]}"; do
  target="${HOME}/Library/LaunchAgents/${label}.plist"
  launchctl bootout "${GUI_DOMAIN}" "${target}" >/dev/null 2>&1 || true
  rm -f "${target}"
  echo "Stopped and removed ${label}"
done
