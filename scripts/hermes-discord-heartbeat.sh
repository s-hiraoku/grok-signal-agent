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

    "${HERMES_BIN}" send --to "${TARGET}" --quiet "$(printf 'Tech curation (%d)\n\n%s' "${part}" "${chunk}")"
    message="${message:${#chunk}}"
    message="${message#"${message%%[![:space:]]*}"}"
    part=$((part + 1))
  done

  "${HERMES_BIN}" send --to "${TARGET}" --quiet "$(printf 'Tech curation (%d)\n\n%s' "${part}" "${message}")"
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
yesterday="$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d 'yesterday' '+%Y-%m-%d')"
prompt="Use x_search to search X/Twitter for recent, high-signal posts across AI, Web development, programming, and broader IT news. Cover these categories as evenly as the available high-traction posts allow: 1) AI models, AI agents, coding agents, LLM app development, MCP/tool use, and practical AI engineering; 2) Web frontend/backend development, browsers, frameworks, runtimes, JavaScript/TypeScript, CSS, and platform APIs; 3) programming languages, developer tools, IDEs, libraries, databases, testing, build tools, and software engineering practices; 4) cloud, infrastructure, security, open source, chips/platform shifts, major product launches, standards, and IT/business news that matters to builders. Current local time is ${now}. This digest runs three times per day around morning, lunch, and early evening. Prefer posts since the previous digest window that are visibly getting traction; use from_date=${yesterday} only when needed to cover overnight or early-morning context, otherwise use from_date=${today} and prioritize posts that are newest AND talked about. Rank candidates by engagement and conversation signals: reposts, likes, replies, quote posts, bookmark/share-like signals if available, notable builders commenting, or the same topic being discussed by multiple independent developer/AI/Web/IT accounts. Prefer original posts, substantial technical threads, release announcements, hands-on experiments, incident reports, standards updates, and news that developers can act on. Do not over-focus on AI agents unless they clearly dominate the conversation; aim for a balanced mix of AI, Web development, programming, and IT news. It is okay to include more information than a short digest, but keep each section scannable. Avoid broad AI hype, stock/crypto chatter, hardware-only news, and generic productivity posts unless they clearly matter to builders and are being actively discussed. Do not use xurl. Do not use web_search or browser tools. Return a friendly, relaxed Japanese tech briefing in this exact structure: 1) first line: a concise headline that summarizes the two or three biggest themes, like '<topic A>と<topic B>が話題に'. 2) two short intro paragraphs, written in a natural, approachable tone like sharing useful links with a colleague; avoid stiff newswire phrasing, corporate wording, and exaggerated hype. The opening should feel warm from the first sentence. 3) one sentence: '本日の主要な動向を順番に追っていきましょう。'. 4) Insert a separator line containing only '---'. 5) a '目次' section listing 8-12 topic titles, one per line, prefixed with '- '. 6) Insert a separator line containing only '---'. 7) detailed sections in the same order. Put a separator line containing only '---' before every detailed section. Each section starts with '### <title>' on its own line, then 2-5 concise paragraphs explaining what happened, why it matters for developers/AI-agent builders/Web engineers/IT watchers, and the observed traction. Use '【続報】' in a title only when the post is clearly a continuation of an already ongoing topic. 8) under each section, include 1-3 related post entries in this style: '<account name>: <short Japanese summary or translated quote>' followed by the direct URL on the next line. Every section must include at least one direct source URL exactly as returned by x_search. Each URL must start with https://x.com/ or https://twitter.com/. Do not synthesize URLs. Omit any topic that has no direct source URL or no visible traction signal. Keep the writing friendly like a helpful colleague, not stiff or corporate. Keep blank lines between paragraphs so Discord is easy to scan."
retry_prompt="${prompt} Previous attempts sometimes omitted links. This time, every detailed section must include at least one visible direct https://x.com/ or https://twitter.com/ URL directly under a related post entry. Return only sections with direct source URLs. If fewer linked topics are available, return fewer sections rather than unlinking or citing vaguely."

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

message="$(printf '%s\n\n更新: %s' "${curation}" "${now}")"

if send_discord_message "${message}"; then
  log "sent X curation heartbeat to ${TARGET}"
else
  code=$?
  log "failed to send X curation heartbeat to ${TARGET} exit=${code}"
  exit "${code}"
fi
