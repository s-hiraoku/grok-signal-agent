#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.bun/bin:${PATH}"

# Discord feedback/follow-up hook.
#
# Captures explicit user reactions and follow-up requests from Gateway event
# payloads. It writes a local fallback artifact and, when gbrain is available,
# captures the same item as a typed brain page.

STATE_DIR="${HERMES_STATE_DIR:-${HOME}/.hermes/state}"
LOG_FILE="${HERMES_FEEDBACK_LOG:-${HOME}/.hermes/logs/hermes-discord-feedback.log}"
BRAIN_DIR="${GBRAIN_BRAIN:-${HOME}/.hermes/brain}"
GBRAIN_BIN="${GBRAIN_BIN:-}"

mkdir -p "${STATE_DIR}/user-feedback" "$(dirname "${LOG_FILE}")" 2>/dev/null || true
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}" 2>/dev/null || true; }

trap 'exit 0' ERR

payload="$(cat 2>/dev/null || true)"
[[ -n "${payload}" ]] || exit 0

if command -v jq >/dev/null 2>&1; then
  text="$(printf '%s' "${payload}" | jq -r '
    .text
    // .message
    // .event.text
    // .content
    // .extra.text
    // .extra.message
    // .extra.event.text
    // .extra.event.content
    // empty
  ' 2>/dev/null || true)"
  if [[ -z "${text}" ]]; then
    text="$(printf '%s' "${payload}" | jq -r '.extra.event // .event // empty' 2>/dev/null \
      | sed -n "s/.*text='\([^']*\)'.*/\1/p" \
      | head -1)"
  fi
  user_id="$(printf '%s' "${payload}" | jq -r '.user_id // .author.id // .event.author.id // .event.user_id // .extra.user_id // .extra.author.id // .extra.event.author.id // .extra.event.user_id // empty' 2>/dev/null || true)"
  channel_id="$(printf '%s' "${payload}" | jq -r '.channel_id // .event.channel_id // .extra.channel_id // .extra.event.channel_id // empty' 2>/dev/null || true)"
else
  text="$(printf '%s' "${payload}" | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  user_id=""
  channel_id=""
fi
[[ -n "${text//[[:space:]]/}" ]] || exit 0

kind=""
body=""
shopt -s nocasematch 2>/dev/null || true
if [[ "${text}" =~ ^[[:space:]]*(評価|/feedback|feedback)[[:space:]]*[:：]?[[:space:]]*(.*)$ ]]; then
  kind="feedback"
  body="${BASH_REMATCH[2]}"
elif [[ "${text}" =~ ^[[:space:]]*(良かった|よかった|微妙|ノイズ|重要).*$ ]]; then
  kind="feedback"
  body="${text}"
elif [[ "${text}" =~ ^[[:space:]]*(追跡|/track|track)[[:space:]]*[:：]?[[:space:]]*(.*)$ ]]; then
  kind="followup"
  body="${BASH_REMATCH[2]}"
elif [[ "${text}" =~ ^[[:space:]]*(深掘り|/deepdive|deepdive)[[:space:]]*[:：]?[[:space:]]*(.*)$ ]]; then
  kind="followup"
  body="${BASH_REMATCH[2]}"
fi
shopt -u nocasematch 2>/dev/null || true

[[ -n "${kind}" && -n "${body//[[:space:]]/}" ]] || exit 0

timestamp="$(date '+%Y%m%d-%H%M%S')"
created_at="$(date '+%Y-%m-%d %H:%M:%S %z')"
slug="${kind}-${timestamp}"
file="${STATE_DIR}/user-feedback/${slug}.md"

{
  printf -- '---\n'
  printf 'type: "%s"\n' "${kind}"
  printf 'slug: "%s"\n' "${slug}"
  printf 'created_at: "%s"\n' "${created_at}"
  [[ -z "${user_id}" ]] || printf 'user_id: "%s"\n' "${user_id}"
  [[ -z "${channel_id}" ]] || printf 'channel_id: "%s"\n' "${channel_id}"
  printf -- '---\n\n'
  printf '%s\n' "${body}"
} > "${file}"
chmod 600 "${file}" 2>/dev/null || true
log "captured ${kind}: ${body}"

if [[ -z "${GBRAIN_BIN}" ]]; then
  if command -v gbrain >/dev/null 2>&1; then
    GBRAIN_BIN="$(command -v gbrain)"
  elif [[ -x "${HOME}/.bun/bin/gbrain" ]]; then
    GBRAIN_BIN="${HOME}/.bun/bin/gbrain"
  fi
fi

if [[ -n "${GBRAIN_BIN}" && -d "${BRAIN_DIR}" ]]; then
  if ( cd "${BRAIN_DIR}" && "${GBRAIN_BIN}" put "${slug}" < "${file}" ) >>"${LOG_FILE}" 2>&1; then
    log "gbrain upsert ok: ${slug}"
  else
    log "gbrain upsert failed: ${slug}"
  fi
fi

exit 0
