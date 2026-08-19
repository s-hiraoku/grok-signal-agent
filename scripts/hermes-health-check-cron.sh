#!/usr/bin/env bash
set -euo pipefail

HERMES_HOME_DIR="${HERMES_HOME:-${HOME}/.hermes}"
HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
LOG_FILE="${HERMES_HEALTH_LOG:-${HERMES_HOME_DIR}/logs/hermes-health-check.log}"
JOBS_FILE="${HERMES_CRON_JOBS_FILE:-${HERMES_HOME_DIR}/cron/jobs.json}"
WEBHOOKS_FILE="${HERMES_WEBHOOK_SUBSCRIPTIONS_FILE:-${HERMES_HOME_DIR}/webhook_subscriptions.json}"
GATEWAY_STATE_FILE="${HERMES_GATEWAY_STATE_FILE:-${HERMES_HOME_DIR}/gateway_state.json}"
SIGNAL_STATE_FILE="${HERMES_SIGNAL_WATCHER_STATE_FILE:-${HERMES_HOME_DIR}/state/signal-watcher-state.json}"
FORCE_REPORT="${HERMES_HEALTH_FORCE_REPORT:-0}"
CHECK_LAUNCHD="${HERMES_HEALTH_CHECK_LAUNCHD:-1}"
CHECK_XAI="${HERMES_HEALTH_CHECK_XAI:-1}"

issues=()
notes=()
launchd_running=0

mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true

add_issue() {
  issues+=("$*")
}

add_note() {
  notes+=("$*")
}

json_value() {
  local file="$1" expr="$2"
  [[ -f "${file}" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -r "${expr}" "${file}" 2>/dev/null
}

check_launchd_gateway() {
  [[ "${CHECK_LAUNCHD}" == "1" ]] || return 0
  command -v launchctl >/dev/null 2>&1 || {
    add_note "launchctl unavailable; skipped launchd gateway check"
    return 0
  }

  local output
  output="$(launchctl print "gui/$(id -u)/ai.hermes.gateway" 2>&1)"
  if [[ "${output}" == *"state = running"* || "${output}" == *'"PID"'* || "${output}" == *$'\tPID = '* ]]; then
    launchd_running=1
  else
    add_issue "Hermes Gateway launchd service is not running or not loaded."
  fi
}

check_gateway_state() {
  if [[ ! -f "${GATEWAY_STATE_FILE}" ]]; then
    add_issue "gateway_state.json is missing: ${GATEWAY_STATE_FILE}"
    return 0
  fi

  local state discord_state webhook_state
  state="$(json_value "${GATEWAY_STATE_FILE}" '.gateway_state // "unknown"' || printf 'unknown')"
  discord_state="$(json_value "${GATEWAY_STATE_FILE}" '.platforms.discord.state // "unknown"' || printf 'unknown')"
  webhook_state="$(json_value "${GATEWAY_STATE_FILE}" '.platforms.webhook.state // "unknown"' || printf 'unknown')"

  if [[ "${state}" != "running" && "${launchd_running}" != "1" ]]; then
    add_issue "Hermes Gateway state is ${state}."
  elif [[ "${state}" != "running" && "${launchd_running}" == "1" ]]; then
    add_note "gateway_state.json says ${state}, but launchd reports the service is running."
  fi

  if [[ "${discord_state}" != "connected" && "${discord_state}" != "unknown" ]]; then
    add_issue "Discord gateway state is ${discord_state}."
  fi
  if [[ "${webhook_state}" != "connected" && "${webhook_state}" != "unknown" ]]; then
    add_issue "Webhook gateway state is ${webhook_state}."
  fi
}

check_cron_jobs() {
  if [[ ! -f "${JOBS_FILE}" ]]; then
    add_issue "Cron jobs file is missing: ${JOBS_FILE}"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || {
    add_issue "jq is unavailable; cannot inspect cron jobs."
    return 0
  }

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    add_issue "${line}"
  done < <(
    jq -r '
      .jobs[]?
      | select((.enabled // true) == true)
      | select((.last_status // "ok") != "ok" or (.last_delivery_error // "") != "")
      | "Cron job last failure: \(.name) status=\(.last_status // "unknown") error=\((.last_error // .last_delivery_error // "unknown"))"
    ' "${JOBS_FILE}" 2>/dev/null
  )
}

check_webhooks() {
  if [[ ! -f "${WEBHOOKS_FILE}" ]]; then
    add_issue "Webhook subscriptions file is missing: ${WEBHOOKS_FILE}"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || return 0

  local route
  for route in signal-catchup ai-latest-trigger tech-digest-trigger x-buzz-trigger github-pr-review-trigger nightly-dreaming-trigger; do
    if ! jq -e --arg route "${route}" 'has($route)' "${WEBHOOKS_FILE}" >/dev/null 2>&1; then
      add_issue "Expected webhook route is missing: ${route}"
    fi
  done

  for route in zenn-dev-trigger wbsb-trigger; do
    if jq -e --arg route "${route}" 'has($route)' "${WEBHOOKS_FILE}" >/dev/null 2>&1; then
      add_issue "Disabled legacy webhook route is still registered: ${route}"
    fi
  done
}

check_watcher_state() {
  local file="$1" label="$2"
  [[ -f "${file}" ]] || {
    add_note "${label} state file is not present yet."
    return 0
  }
  command -v jq >/dev/null 2>&1 || return 0

  local error_count
  error_count="$(jq -r '(.runs[-1].errors // []) | length' "${file}" 2>/dev/null || printf '0')"
  if [[ "${error_count}" =~ ^[0-9]+$ && "${error_count}" -gt 0 ]]; then
    add_issue "${label} latest run has ${error_count} error(s)."
  fi
}

check_xai_auth_hint() {
  [[ "${CHECK_XAI}" == "1" ]] || return 0
  local log="${HERMES_HOME_DIR}/logs/gateway.error.log"
  [[ -f "${log}" ]] || return 0
  if tail -n 200 "${log}" 2>/dev/null | grep -Fq "personal-team-blocked:spending-limit"; then
    add_issue "xAI/Grok request failed recently because credits or subscription access are blocked."
  fi
}

check_launchd_gateway
check_gateway_state
check_cron_jobs
check_webhooks
check_watcher_state "${SIGNAL_STATE_FILE}" "Signal watcher"
check_xai_auth_hint

{
  printf '%s issues=%s notes=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "${#issues[@]}" "${#notes[@]}"
  if [[ "${#issues[@]}" -gt 0 ]]; then
    for item in "${issues[@]}"; do
      printf 'issue: %s\n' "${item}"
    done
  fi
  if [[ "${#notes[@]}" -gt 0 ]]; then
    for item in "${notes[@]}"; do
      printf 'note: %s\n' "${item}"
    done
  fi
} >> "${LOG_FILE}" 2>/dev/null || true

if [[ "${#issues[@]}" -eq 0 && "${FORCE_REPORT}" != "1" ]]; then
  exit 0
fi

if [[ "${#issues[@]}" -eq 0 ]]; then
  printf 'Hermes health check: OK\n\n'
else
  printf 'Hermes health check: attention needed\n\n'
  printf 'Issues:\n'
  if [[ "${#issues[@]}" -gt 0 ]]; then
    for item in "${issues[@]}"; do
      printf -- '- %s\n' "${item}"
    done
  fi
  printf '\n'
fi

if [[ "${#notes[@]}" -gt 0 ]]; then
  printf 'Notes:\n'
  for item in "${notes[@]}"; do
    printf -- '- %s\n' "${item}"
  done
  printf '\n'
fi

printf 'Checked at: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
