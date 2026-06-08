#!/usr/bin/env bash
set -euo pipefail

LEGACY_GATEWAY_LABEL="com.shiraoku.grok-signal-agent.hermes-gateway"
LEGACY_HEALTHCHECK_LABEL="com.shiraoku.grok-signal-agent.hermes-gateway-healthcheck"
HEARTBEAT_LABEL="com.shiraoku.grok-signal-agent.discord-heartbeat"
WEEKLY_REFLECTION_LABEL="com.shiraoku.grok-signal-agent.weekly-self-reflection"
SIGNAL_WATCHER_LABEL="com.shiraoku.grok-signal-agent.signal-watcher"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_BIN="${HOME}/.local/bin/hermes"
GUI_DOMAIN="gui/$(id -u)"
BUILTIN_GATEWAY_PLIST="${HOME}/Library/LaunchAgents/ai.hermes.gateway.plist"
RUNTIME_DIR="${HOME}/.hermes/runtime/grok-signal-agent"

if [[ ! -x "${HERMES_BIN}" ]]; then
  echo "Hermes is not installed at ${HERMES_BIN}."
  echo "Install Hermes first, then run this script again."
  exit 1
fi

mkdir -p \
  "${HOME}/.hermes/bin" \
  "${HOME}/.hermes/logs" \
  "${HOME}/.hermes/prompts" \
  "${HOME}/.hermes/scripts" \
  "${HOME}/.hermes/state/digests" \
  "${HOME}/.hermes/state/evaluations" \
  "${HOME}/.hermes/state/digest-metadata" \
  "${HOME}/.hermes/state/digest-quality" \
  "${HOME}/.hermes/state/user-feedback" \
  "${HOME}/.hermes/state/signal-watcher" \
  "${HOME}/.hermes/state/weekly-reflections" \
  "${RUNTIME_DIR}/config" \
  "${RUNTIME_DIR}/scripts" \
  "${HOME}/Library/LaunchAgents"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-weekly-self-reflection.sh" \
  "${HOME}/.hermes/bin/hermes-weekly-self-reflection.sh"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-gbrain-retrieval.sh" \
  "${HOME}/.hermes/bin/hermes-gbrain-retrieval.sh"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-gbrain-remember.sh" \
  "${HOME}/.hermes/bin/hermes-gbrain-remember.sh"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-discord-feedback.sh" \
  "${HOME}/.hermes/bin/hermes-discord-feedback.sh"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-digest-lint.sh" \
  "${HOME}/.hermes/bin/hermes-digest-lint.sh"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-alert.sh" \
  "${HOME}/.hermes/bin/hermes-alert.sh"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-obsidian-mcp-setup.sh" \
  "${HOME}/.hermes/bin/hermes-obsidian-mcp-setup.sh"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-jina-mcp-setup.sh" \
  "${HOME}/.hermes/bin/hermes-jina-mcp-setup.sh"
install -m 755 \
  "${REPO_DIR}/scripts/register-hermes-webhooks.sh" \
  "${HOME}/.hermes/bin/register-hermes-webhooks.sh"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-signal-watcher.sh" \
  "${HOME}/.hermes/bin/hermes-signal-watcher.sh"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-signal-watcher.py" \
  "${RUNTIME_DIR}/scripts/hermes-signal-watcher.py"
install -m 644 \
  "${REPO_DIR}/config/signal-watchers.json" \
  "${RUNTIME_DIR}/config/signal-watchers.json"
for cron_script in "${REPO_DIR}"/scripts/*-cron.sh; do
  [[ -e "${cron_script}" ]] || continue
  install -m 755 "${cron_script}" "${HOME}/.hermes/scripts/"
done
install -m 644 \
  "${REPO_DIR}/prompts/hermes-chan-identity.md" \
  "${REPO_DIR}/prompts/evaluate-digest.md" \
  "${REPO_DIR}/prompts/tech-digest.md" \
  "${REPO_DIR}/prompts/nightly-dreaming.md" \
  "${REPO_DIR}/prompts/weekly-self-reflection.md" \
  "${HOME}/.hermes/prompts/"

"${HERMES_BIN}" config set cron.script_timeout_seconds 300 >/dev/null

render_plist() {
  local label="$1"
  local template="${REPO_DIR}/launchd/${label}.plist"
  local target="${HOME}/Library/LaunchAgents/${label}.plist"

  sed \
    -e "s|__HOME__|${HOME}|g" \
    -e "s|__REPO__|${REPO_DIR}|g" \
    -e "s|__RUNTIME__|${RUNTIME_DIR}|g" \
    "${template}" > "${target}"
}

install_agent() {
  local label="$1"
  local target="${HOME}/Library/LaunchAgents/${label}.plist"

  launchctl bootout "${GUI_DOMAIN}" "${target}" >/dev/null 2>&1 || true
  launchctl bootstrap "${GUI_DOMAIN}" "${target}"
  launchctl enable "${GUI_DOMAIN}/${label}"
}

remove_legacy_agent() {
  local label="$1"
  local target="${HOME}/Library/LaunchAgents/${label}.plist"

  launchctl bootout "${GUI_DOMAIN}/${label}" >/dev/null 2>&1 || true
  launchctl bootout "${GUI_DOMAIN}" "${target}" >/dev/null 2>&1 || true
  rm -f "${target}"
}

pmset -g log 2>/dev/null | awk '
  $4 == "Wake" || $4 == "DarkWake" || $4 == "FullWake" {
    event = $1 " " $2 " " $3 " " $4
  }
  END {
    if (event != "") print event
  }
' > "${HOME}/.hermes/state/last-wake-event" || true

render_plist "${WEEKLY_REFLECTION_LABEL}"
render_plist "${SIGNAL_WATCHER_LABEL}"

remove_legacy_agent "${HEARTBEAT_LABEL}"
remove_legacy_agent "${LEGACY_GATEWAY_LABEL}"
remove_legacy_agent "${LEGACY_HEALTHCHECK_LABEL}"
"${REPO_DIR}/scripts/register-hermes-cronjobs.sh"
if "${HERMES_BIN}" webhook list 2>&1 | grep -q "Webhook platform is not enabled"; then
  echo "Skipped webhook registration because Hermes webhook platform is not enabled"
else
  "${REPO_DIR}/scripts/register-hermes-webhooks.sh"
fi
install_agent "${WEEKLY_REFLECTION_LABEL}"
install_agent "${SIGNAL_WATCHER_LABEL}"

if [[ ! -f "${BUILTIN_GATEWAY_PLIST}" ]]; then
  "${HERMES_BIN}" gateway install
fi
"${HERMES_BIN}" gateway restart
for _ in {1..20}; do
  if [[ -f "${HOME}/.hermes/gateway_state.json" ]] && grep -q '"gateway_state":"running"' "${HOME}/.hermes/gateway_state.json"; then
    break
  fi
  sleep 1
done

echo "Installed and restarted Hermes built-in gateway service"
echo "Removed legacy ${HEARTBEAT_LABEL}, ${LEGACY_GATEWAY_LABEL}, and ${LEGACY_HEALTHCHECK_LABEL}"
echo "Installed ${WEEKLY_REFLECTION_LABEL}; it will update self-memory weekly"
echo "Installed ${SIGNAL_WATCHER_LABEL}; it will catch up source changes via webhook thresholds"
echo "Installed watcher runtime under ${RUNTIME_DIR}"
echo "Status:"
launchctl print "${GUI_DOMAIN}/ai.hermes.gateway" | sed -n '1,80p'
