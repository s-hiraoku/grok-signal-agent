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

run_curation() {
  local prompt="$1"
  "${HERMES_BIN}" -t x_search -z "${prompt}" 2>>"${LOG_FILE}"
}

has_source_links() {
  grep -Eqi 'https?://(x\.com|twitter\.com)/[^[:space:])>]+' <<< "$1"
}

send_discord_message() {
  local message="$1"
  local max_chars=1750
  local part=1
  local chunk=""

  if (( ${#message} <= max_chars )); then
    "${HERMES_BIN}" send --to "${TARGET}" --quiet "${message}"
    return
  fi

  while (( ${#message} > max_chars )); do
    chunk="${message:0:max_chars}"
    if [[ "${chunk}" == *$'\n'* ]]; then
      chunk="${chunk%$'\n'*}"
    fi
    if (( ${#chunk} < 800 )); then
      chunk="${message:0:max_chars}"
    fi

    "${HERMES_BIN}" send --to "${TARGET}" --quiet "$(printf 'Hermes tech notes (%d)\n\n%s' "${part}" "${chunk}")"
    message="${message:${#chunk}}"
    message="${message#"${message%%[![:space:]]*}"}"
    part=$((part + 1))
  done

  "${HERMES_BIN}" send --to "${TARGET}" --quiet "$(printf 'Hermes tech notes (%d)\n\n%s' "${part}" "${message}")"
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
prompt="Use x_search to search X/Twitter for recent, high-signal posts about programming, software engineering, AI agents, coding agents, LLM application development, MCP/tool use, developer tools, IDEs, frameworks, infrastructure for developers, and practical AI engineering. Prefer posts from the last 3 hours that are visibly getting traction; if the tool cannot filter by hour, use from_date=${today} and prioritize posts that are newest AND talked about. Rank candidates by engagement and conversation signals: reposts, likes, replies, quote posts, bookmark/share-like signals if available, notable builders commenting, or the same topic being discussed by multiple independent developer/AI accounts. Prefer original posts or substantial technical threads over repost-only summaries. Avoid broad AI hype, business funding news, stock/crypto chatter, and generic productivity posts unless they clearly matter to builders and are being actively discussed. Do not use xurl. Do not use web_search or browser tools. Return a friendly, relaxed Japanese curation. Keep it warm and conversational, not stiff or corporate. Format: a short soft opening sentence explaining that these are the posts with some momentum, then 4-6 curated items. For each item include a gentle title, what happened, why it is interesting for programmers or AI-agent builders, a short '話題感:' note describing the engagement/conversation signal you saw, and a 'Links:' line with one or more direct source URLs exactly as returned by x_search. Each URL must start with https://x.com/ or https://twitter.com/. Do not synthesize URLs. Omit any item that has no direct source URL or no visible traction signal. End with one short '気になる流れ' note. Do not over-explain."
retry_prompt="${prompt} Previous attempts sometimes omitted links. This time, every curated item must include a visible Links: line containing direct https://x.com/ or https://twitter.com/ URLs. Return only items with direct source URLs. If fewer linked items are available, return fewer items rather than unlinking or citing vaguely."

log "starting X curation heartbeat"
if ! curation="$(run_curation "${prompt}")"; then
  code=$?
  log "x_search curation failed exit=${code}"
  exit "${code}"
fi

if ! has_source_links "${curation}"; then
  log "x_search curation had no direct X links; retrying"
  if ! curation="$(run_curation "${retry_prompt}")"; then
    code=$?
    log "x_search linked curation retry failed exit=${code}"
    exit "${code}"
  fi
fi

if [[ -z "${curation//[[:space:]]/}" ]]; then
  log "x_search curation returned empty output"
  exit 1
fi

message="$(printf 'Hermes tech notes\n%s\n\n%s' "${now}" "${curation}")"

if send_discord_message "${message}"; then
  log "sent X curation heartbeat to ${TARGET}"
else
  code=$?
  log "failed to send X curation heartbeat to ${TARGET} exit=${code}"
  exit "${code}"
fi
