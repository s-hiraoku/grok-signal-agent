#!/usr/bin/env bash
set -euo pipefail

LEGACY_GATEWAY_LABEL="com.shiraoku.grok-signal-agent.hermes-gateway"
LEGACY_HEALTHCHECK_LABEL="com.shiraoku.grok-signal-agent.hermes-gateway-healthcheck"
HEARTBEAT_LABEL="com.shiraoku.grok-signal-agent.discord-heartbeat"
WEEKLY_REFLECTION_LABEL="com.shiraoku.grok-signal-agent.weekly-self-reflection"
SIGNAL_WATCHER_LABEL="com.shiraoku.grok-signal-agent.signal-watcher"
HEALTH_WATCHDOG_LABEL="com.shiraoku.grok-signal-agent.health-watchdog"
LEGACY_X_PULSE_WATCHER_LABEL="com.shiraoku.grok-signal-agent.x-pulse-watcher"
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
  "${HOME}/.hermes/prompts/webhooks" \
  "${HOME}/.hermes/skills/devops/hermes-posting-admin" \
  "${HOME}/.hermes/scripts" \
  "${HOME}/.hermes/state/digests" \
  "${HOME}/.hermes/state/evaluations" \
  "${HOME}/.hermes/state/digest-metadata" \
  "${HOME}/.hermes/state/digest-quality" \
  "${HOME}/.hermes/state/user-feedback" \
  "${HOME}/.hermes/state/signal-watcher" \
  "${HOME}/.hermes/state/weekly-reflections" \
  "${HOME}/.hermes/mnemo/knowledge" \
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
  "${REPO_DIR}/scripts/hermes-mnemo-memory.py" \
  "${HOME}/.hermes/bin/hermes-mnemo-memory.py"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-mnemo-memory-hook.sh" \
  "${HOME}/.hermes/bin/hermes-mnemo-memory-hook.sh"
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
  "${REPO_DIR}/scripts/hermes-health-watchdog.sh" \
  "${HOME}/.hermes/bin/hermes-health-watchdog.sh"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-obsidian-mcp-setup.sh" \
  "${HOME}/.hermes/bin/hermes-obsidian-mcp-setup.sh"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-jina-mcp-setup.sh" \
  "${HOME}/.hermes/bin/hermes-jina-mcp-setup.sh"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-google-calendar-mcp-setup.sh" \
  "${HOME}/.hermes/bin/hermes-google-calendar-mcp-setup.sh"
install -m 755 \
  "${REPO_DIR}/scripts/hermes-posting-admin.sh" \
  "${HOME}/.hermes/bin/hermes-posting-admin.sh"
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
  "${REPO_DIR}/config/hermes-cronjobs.json" \
  "${RUNTIME_DIR}/config/hermes-cronjobs.json"
install -m 644 \
  "${REPO_DIR}/config/signal-watchers.json" \
  "${RUNTIME_DIR}/config/signal-watchers.json"
printf '%s\n' "${REPO_DIR}" > "${RUNTIME_DIR}/repo-path"
for cron_script in "${REPO_DIR}"/scripts/*-cron.sh; do
  [[ -e "${cron_script}" ]] || continue
  install -m 755 "${cron_script}" "${HOME}/.hermes/scripts/"
done
for extra_script in \
  "${REPO_DIR}/scripts/hermes-x-buzz-search.py" \
  "${REPO_DIR}/scripts/hermes-x-buzz-rank.py"; do
  [[ -e "${extra_script}" ]] || continue
  install -m 755 "${extra_script}" "${HOME}/.hermes/scripts/"
done
install -m 644 \
  "${REPO_DIR}/prompts/hermes-chan-identity.md" \
  "${REPO_DIR}/prompts/evaluate-digest.md" \
  "${REPO_DIR}/prompts/hermes-post-style.md" \
  "${REPO_DIR}/prompts/tech-digest.md" \
  "${REPO_DIR}/prompts/x-buzz-digest.md" \
  "${REPO_DIR}/prompts/curiosity-candidate.md" \
  "${REPO_DIR}/prompts/curiosity-research.md" \
  "${REPO_DIR}/prompts/nightly-dreaming.md" \
  "${REPO_DIR}/prompts/weekly-self-reflection.md" \
  "${HOME}/.hermes/prompts/"
if compgen -G "${REPO_DIR}/prompts/webhooks/*.md" >/dev/null; then
  for prompt_file in "${REPO_DIR}"/prompts/webhooks/*.md; do
    install -m 644 "${prompt_file}" "${HOME}/.hermes/prompts/webhooks/"
  done
fi
install -m 644 \
  "${REPO_DIR}/.agents/skills/hermes-posting-admin/SKILL.md" \
  "${HOME}/.hermes/skills/devops/hermes-posting-admin/SKILL.md"

"${HERMES_BIN}" config set cron.script_timeout_seconds 600 >/dev/null

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

ensure_gateway_hooks() {
  local config_file="${HOME}/.hermes/config.yaml"
  [[ -f "${config_file}" ]] || return 0
  command -v ruby >/dev/null 2>&1 || {
    echo "Skipped Gateway hook config merge because ruby was not found"
    return 0
  }

  ruby -ryaml -e '
    config_file = ARGV.shift
    commands = ARGV
    config = YAML.load_file(config_file) || {}
    config["hooks"] = {} unless config["hooks"].is_a?(Hash)
    hooks = config["hooks"]
    hooks["pre_gateway_dispatch"] = [] unless hooks["pre_gateway_dispatch"].is_a?(Array)
    existing = hooks["pre_gateway_dispatch"]
    commands.each do |command|
      next if existing.any? { |entry| entry.is_a?(Hash) && entry["command"] == command }
      existing << { "command" => command, "timeout" => 30 }
    end
    File.write(config_file, YAML.dump(config))
  ' "${config_file}" \
    "${HOME}/.hermes/bin/hermes-gbrain-remember.sh" \
    "${HOME}/.hermes/bin/hermes-mnemo-memory-hook.sh" \
    "${HOME}/.hermes/bin/hermes-discord-feedback.sh"
}

approve_gateway_hooks() {
  local allowlist_file="${HOME}/.hermes/shell-hooks-allowlist.json"
  command -v ruby >/dev/null 2>&1 || {
    echo "Skipped Gateway hook allowlist update because ruby was not found"
    return 0
  }

  ruby -rjson -rtime -e '
    allowlist_file = ARGV.shift
    commands = ARGV
    data = begin
      File.exist?(allowlist_file) ? JSON.parse(File.read(allowlist_file)) : {}
    rescue JSON::ParserError
      {}
    end
    data["approvals"] = [] unless data["approvals"].is_a?(Array)
    commands.each do |command|
      data["approvals"].reject! do |entry|
        entry.is_a?(Hash) &&
          entry["event"] == "pre_gateway_dispatch" &&
          entry["command"] == command
      end
      data["approvals"] << {
        "event" => "pre_gateway_dispatch",
        "command" => command,
        "approved_at" => Time.now.utc.iso8601(6).sub("+00:00", "Z")
      }
    end
    File.write(allowlist_file, JSON.pretty_generate(data) + "\n")
  ' "${allowlist_file}" \
    "${HOME}/.hermes/bin/hermes-gbrain-remember.sh" \
    "${HOME}/.hermes/bin/hermes-mnemo-memory-hook.sh" \
    "${HOME}/.hermes/bin/hermes-discord-feedback.sh"
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
render_plist "${HEALTH_WATCHDOG_LABEL}"

remove_legacy_agent "${HEARTBEAT_LABEL}"
remove_legacy_agent "${LEGACY_GATEWAY_LABEL}"
remove_legacy_agent "${LEGACY_HEALTHCHECK_LABEL}"
remove_legacy_agent "${LEGACY_X_PULSE_WATCHER_LABEL}"
rm -f "${HOME}/.hermes/bin/hermes-x-pulse-watcher.sh" "${RUNTIME_DIR}/scripts/hermes-x-pulse-watcher.py" "${RUNTIME_DIR}/config/x-pulse-watchers.json"
"${REPO_DIR}/scripts/register-hermes-cronjobs.sh"
set +e
webhook_list_output="$("${HERMES_BIN}" webhook list 2>&1)"
webhook_list_status=$?
set -e
if [[ "${webhook_list_status}" -ne 0 && "${webhook_list_output}" == *"Webhook platform is not enabled"* ]]; then
  echo "Skipped webhook registration because Hermes webhook platform is not enabled"
elif [[ "${webhook_list_status}" -ne 0 ]]; then
  printf '%s\n' "${webhook_list_output}" >&2
  exit "${webhook_list_status}"
else
  "${REPO_DIR}/scripts/register-hermes-webhooks.sh"
fi
install_agent "${WEEKLY_REFLECTION_LABEL}"
install_agent "${SIGNAL_WATCHER_LABEL}"
install_agent "${HEALTH_WATCHDOG_LABEL}"

if [[ ! -f "${BUILTIN_GATEWAY_PLIST}" ]]; then
  "${HERMES_BIN}" gateway install
fi
ensure_gateway_hooks
approve_gateway_hooks
"${HERMES_BIN}" gateway restart
for _ in {1..20}; do
  if [[ -f "${HOME}/.hermes/gateway_state.json" ]] && grep -q '"gateway_state":"running"' "${HOME}/.hermes/gateway_state.json"; then
    break
  fi
  sleep 1
done

echo "Installed and restarted Hermes built-in gateway service"
echo "Removed legacy ${HEARTBEAT_LABEL}, ${LEGACY_GATEWAY_LABEL}, ${LEGACY_HEALTHCHECK_LABEL}, and ${LEGACY_X_PULSE_WATCHER_LABEL}"
echo "Installed ${WEEKLY_REFLECTION_LABEL}; it will update self-memory weekly"
echo "Installed ${SIGNAL_WATCHER_LABEL}; it will catch up source changes via webhook thresholds"
echo "Installed ${HEALTH_WATCHDOG_LABEL}; it will send runtime failures directly to #hermes-alerts"
echo "X buzz digest now runs twice daily via Hermes cron (see config/hermes-cronjobs.json)"
echo "Installed and approved Gateway memory/feedback hooks"
echo "Installed Hermes posting admin helper and skill"
echo "Installed watcher runtime under ${RUNTIME_DIR}"
echo "Status:"
launchctl print "${GUI_DOMAIN}/ai.hermes.gateway" | sed -n '1,80p'
