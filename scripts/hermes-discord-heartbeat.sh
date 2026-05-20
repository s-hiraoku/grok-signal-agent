#!/usr/bin/env bash
set -euo pipefail

HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
TARGET="${HERMES_DISCORD_HEARTBEAT_TARGET:-discord}"
LOG_DIR="${HOME}/.hermes/logs"
LOG_FILE="${LOG_DIR}/hermes-discord-heartbeat.log"
LOCK_DIR="${HOME}/.hermes/state/hermes-discord-heartbeat.lock"
LOCK_PID="${LOCK_DIR}/pid"

mkdir -p "${LOG_DIR}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}"
}

if [[ ! -x "${HERMES_BIN}" ]]; then
  log "missing hermes binary: ${HERMES_BIN}"
  exit 1
fi

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  if [[ -f "${LOCK_PID}" ]]; then
    previous_pid="$(<"${LOCK_PID}")"
    if [[ "${previous_pid}" =~ ^[0-9]+$ ]] && kill -0 "${previous_pid}" 2>/dev/null; then
      log "previous heartbeat still running pid=${previous_pid}; skipping"
      exit 0
    fi
  fi

  log "removing stale heartbeat lock"
  rm -rf "${LOCK_DIR}"
  mkdir "${LOCK_DIR}"
fi
printf '%s\n' "$$" > "${LOCK_PID}"
trap 'rm -rf "${LOCK_DIR}" 2>/dev/null || true' EXIT

now="$(date '+%Y-%m-%d %H:%M:%S %z')"
today="$(date '+%Y-%m-%d')"
prompt="Use x_search to search X/Twitter for recent posts about programming, software engineering, AI agents, coding agents, LLM application development, MCP/tool use, developer tools, IDEs, frameworks, infrastructure for developers, and practical AI engineering. Prefer posts from the last hour; if the tool cannot filter by hour, use from_date=${today} and prioritize the newest posts. Avoid broad AI hype, business funding news, stock/crypto chatter, and generic productivity posts unless they clearly matter to builders. Do not use xurl. Do not use web_search or browser tools. Return a friendly, relaxed Japanese curation. Keep it warm and conversational, not stiff or corporate. Format: a short soft opening sentence, then 4-6 curated items. For each item include a gentle title, what happened, why it is interesting for programmers or AI-agent builders, and direct source URLs/citations. End with one short '気になる流れ' note. Do not over-explain."

log "starting X curation heartbeat"
if ! curation="$("${HERMES_BIN}" -t x_search -z "${prompt}" 2>>"${LOG_FILE}")"; then
  code=$?
  log "x_search curation failed exit=${code}"
  exit "${code}"
fi

if [[ -z "${curation//[[:space:]]/}" ]]; then
  log "x_search curation returned empty output"
  exit 1
fi

message="$(printf 'Hermes tech notes\n%s\n\n%s' "${now}" "${curation}")"

if (( ${#message} > 1850 )); then
  message="${message:0:1800}"$'\n\n[truncated]'
fi

if "${HERMES_BIN}" send --to "${TARGET}" --quiet "${message}"; then
  log "sent X curation heartbeat to ${TARGET}"
else
  code=$?
  log "failed to send X curation heartbeat to ${TARGET} exit=${code}"
  exit "${code}"
fi
