#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.bun/bin:${PATH}"

HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
PROMPT_DIR="${HERMES_PROMPT_DIR:-${HOME}/.hermes/prompts}"
STATE_DIR="${HERMES_STATE_DIR:-${HOME}/.hermes/state}"
LOG_DIR="${HERMES_LOG_DIR:-${HOME}/.hermes/logs}"
LOG_FILE="${LOG_DIR}/hermes-x-buzz-digest-cron.log"
PROMPT_FILE="${HERMES_X_BUZZ_PROMPT_FILE:-${PROMPT_DIR}/x-buzz-digest.md}"
IDENTITY_FILE="${HERMES_IDENTITY_FILE:-${PROMPT_DIR}/hermes-chan-identity.md}"
POST_STYLE_FILE="${HERMES_POST_STYLE_FILE:-${PROMPT_DIR}/hermes-post-style.md}"
MEMORY_FILE="${HERMES_CHAN_MEMORY_FILE:-${STATE_DIR}/hermes-chan-memory.md}"
BUZZ_DIR="${STATE_DIR}/x-buzz-digests"
ALERT_SCRIPT="${HERMES_ALERT_SCRIPT:-${HOME}/.hermes/bin/hermes-alert.sh}"
GATEWAY_ERROR_LOG="${HERMES_GATEWAY_ERROR_LOG:-${LOG_DIR}/gateway.error.log}"
WINDOW_HOURS="${HERMES_X_BUZZ_WINDOW_HOURS:-10}"
X_POST_URL_REGEX='https?://(x\.com|twitter\.com)/([^/?#[:space:]]+/status|i/web/status)/[0-9][0-9]*[^[:space:])>]*'
UNAVAILABLE_ALERT_STREAK="${HERMES_X_BUZZ_UNAVAILABLE_ALERT_STREAK:-4}"

mkdir -p "${LOG_DIR}" "${BUZZ_DIR}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}"
}

read_optional_file() {
  local file="$1" limit="${2:-260}"
  [[ -f "${file}" ]] && sed -n "1,${limit}p" "${file}"
}

digest_prefix_for_hour() {
  local hour="$1"
  if (( 10#${hour} < 14 )); then
    printf '朝の'
  else
    printf '夕方の'
  fi
}

has_source_links() {
  grep -Eqi "${X_POST_URL_REGEX}" <<< "$1"
}

is_no_qualified_buzz() {
  local text
  text="$(tr -d '[:space:]' <<< "$1")"
  [[ "${text}" == "NO_QUALIFIED_BUZZ" ]]
}

is_postable_buzz_digest() {
  local text="$1" section_count
  section_count="$(grep -Ec '^###[[:space:]]+' <<< "${text}" || true)"
  (( section_count >= 1 )) && has_source_links "${text}"
}

send_alert() {
  local title="$1" body="$2"
  if [[ -x "${ALERT_SCRIPT}" ]]; then
    printf '%s\n' "${body}" | "${ALERT_SCRIPT}" "${title}" || true
  else
    log "alert skipped (${title}): ${body}"
  fi
}

xai_unavailable_reason() {
  [[ -f "${GATEWAY_ERROR_LOG}" ]] || return 1
  if tail -n 250 "${GATEWAY_ERROR_LOG}" 2>/dev/null | grep -Fq "personal-team-blocked:spending-limit"; then
    printf 'xAI/Grok spending or subscription access is blocked'
    return 0
  fi
  if tail -n 250 "${GATEWAY_ERROR_LOG}" 2>/dev/null | grep -Fq "No xAI OAuth credentials stored"; then
    printf 'xAI OAuth credentials are not available'
    return 0
  fi
  return 1
}

state_file="${STATE_DIR}/x-buzz-digest-state.json"

read_streak() {
  [[ -f "${state_file}" ]] || { printf '0'; return; }
  awk -F ':' '/"unavailable_streak"/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "${state_file}" 2>/dev/null || printf '0'
}

write_streak() {
  local streak="$1" reason="$2"
  printf '{"unavailable_streak": %s, "last_unavailable_reason": "%s", "last_unavailable_at": "%s"}\n' \
    "${streak}" "${reason//\"/}" "$(date '+%Y-%m-%d %H:%M:%S %z')" > "${state_file}"
}

clear_streak() {
  printf '{"unavailable_streak": 0}\n' > "${state_file}"
}

[[ -x "${HERMES_BIN}" ]] || { echo "missing Hermes binary: ${HERMES_BIN}" >&2; exit 1; }
[[ -f "${PROMPT_FILE}" ]] || { echo "missing x buzz digest prompt: ${PROMPT_FILE}" >&2; exit 1; }

now="$(date '+%Y-%m-%d %H:%M:%S %z')"
timestamp="$(date '+%Y%m%d-%H%M%S')"
digest_prefix="$(digest_prefix_for_hour "$(date '+%H')")"

log "starting x buzz digest cron"

xai_reason="$(xai_unavailable_reason || true)"
if [[ -n "${xai_reason}" ]]; then
  log "x_search preflight skipped: ${xai_reason}"
  streak=$(( $(read_streak) + 1 ))
  write_streak "${streak}" "${xai_reason}"
  if (( streak == UNAVAILABLE_ALERT_STREAK )) || { (( streak > UNAVAILABLE_ALERT_STREAK )) && (( streak % UNAVAILABLE_ALERT_STREAK == 0 )); }; then
    send_alert "Hermes X buzz digest has skipped x_search ${streak} times in a row" \
      "reason=${xai_reason}
X buzz digest has been unable to run for ${streak} consecutive scheduled attempts. Check xAI/Grok subscription or spending-limit status."
  fi
  exit 0
fi

prompt="$(cat <<PROMPT
$(read_optional_file "${PROMPT_FILE}" 260)

# Runtime context

Current local time is ${now}.
This is the ${digest_prefix} X buzz check.
window_hours=${WINDOW_HOURS}
When an example includes <digest_prefix>, replace it with "${digest_prefix}".

# Persistent identity

$(read_optional_file "${IDENTITY_FILE}" 180)

# Posting style for Discord

$(read_optional_file "${POST_STYLE_FILE}" 180)

# Current self-memory and preferences

$(read_optional_file "${MEMORY_FILE}" 160)
PROMPT
)"

set +e
curation="$("${HERMES_BIN}" -t x_search -z "${prompt}" 2>>"${LOG_FILE}")"
code=$?
set -e

if [[ "${code}" -ne 0 ]]; then
  log "x_search failed exit=${code}"
  send_alert "Hermes X buzz digest x_search failed" "exit=${code}. See ${LOG_FILE}."
  exit "${code}"
fi

clear_streak

if [[ -z "${curation//[[:space:]]/}" ]] || is_no_qualified_buzz "${curation}"; then
  log "no qualified buzz this window; not posting"
  printf '' > "${BUZZ_DIR}/.${timestamp}.no-buzz"
  exit 0
fi

if ! is_postable_buzz_digest "${curation}"; then
  log "curation had no postable sections/links; saving for inspection, not posting"
  {
    printf -- '---\n'
    printf 'created_at: "%s"\n' "${now}"
    printf 'digest_prefix: "%s"\n' "${digest_prefix}"
    printf 'status: "not_posted"\n'
    printf -- '---\n\n'
    printf '%s\n' "${curation}"
  } > "${BUZZ_DIR}/.failed-${timestamp}.md"
  send_alert "Hermes X buzz digest produced no postable sections" "Saved (not posted): ${BUZZ_DIR}/.failed-${timestamp}.md"
  exit 1
fi

{
  printf -- '---\n'
  printf 'created_at: "%s"\n' "${now}"
  printf 'digest_prefix: "%s"\n' "${digest_prefix}"
  printf -- '---\n\n'
  printf '%s\n' "${curation}"
} > "${BUZZ_DIR}/${timestamp}.md"
log "saved and posting x buzz digest ${BUZZ_DIR}/${timestamp}.md"

printf '%s\n' "${curation}"
