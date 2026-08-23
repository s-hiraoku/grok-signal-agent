#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.bun/bin:${PATH}"

HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
HERMES_HOME_DIR="${HERMES_HOME:-${HOME}/.hermes}"
PROMPT_DIR="${HERMES_PROMPT_DIR:-${HERMES_HOME_DIR}/prompts}"
STATE_DIR="${HERMES_STATE_DIR:-${HERMES_HOME_DIR}/state}"
LOG_DIR="${HERMES_LOG_DIR:-${HERMES_HOME_DIR}/logs}"
LOG_FILE="${LOG_DIR}/hermes-x-buzz-digest-cron.log"
PROMPT_FILE="${HERMES_X_BUZZ_PROMPT_FILE:-${PROMPT_DIR}/x-buzz-digest.md}"
IDENTITY_FILE="${HERMES_IDENTITY_FILE:-${PROMPT_DIR}/hermes-chan-identity.md}"
POST_STYLE_FILE="${HERMES_POST_STYLE_FILE:-${PROMPT_DIR}/hermes-post-style.md}"
MEMORY_FILE="${HERMES_CHAN_MEMORY_FILE:-${STATE_DIR}/hermes-chan-memory.md}"
BUZZ_DIR="${STATE_DIR}/x-buzz-digests"
POSTED_IDS_FILE="${STATE_DIR}/x-buzz-posted-status-ids.txt"
ALERT_SCRIPT="${HERMES_ALERT_SCRIPT:-${HERMES_HOME_DIR}/bin/hermes-alert.sh}"
GATEWAY_ERROR_LOG="${HERMES_GATEWAY_ERROR_LOG:-${LOG_DIR}/gateway.error.log}"
WINDOW_HOURS="${HERMES_X_BUZZ_WINDOW_HOURS:-13}"
X_POST_URL_REGEX='https?://(x\.com|twitter\.com)/([^/?#[:space:]]+/status|i/web/status)/[0-9][0-9]*[^[:space:])>]*'
STATUS_ID_REGEX='https?://(x\.com|twitter\.com)/([^/?#[:space:]]+/status|i/web/status)/([0-9]+)'
UNAVAILABLE_ALERT_STREAK="${HERMES_X_BUZZ_UNAVAILABLE_ALERT_STREAK:-4}"
TOOL_TIMEOUT_SECONDS="${HERMES_X_BUZZ_TOOL_TIMEOUT_SECONDS:-480}"
X_BUZZ_MODEL="${HERMES_X_BUZZ_MODEL:-grok-4.6}"
X_BUZZ_PROVIDER="${HERMES_X_BUZZ_PROVIDER:-xai-oauth}"
X_BUZZ_PREFLIGHT="${HERMES_X_BUZZ_PREFLIGHT:-1}"
DEDUP_LOOKBACK_POSTS="${HERMES_X_BUZZ_DEDUP_LOOKBACK_POSTS:-40}"
DEDUP_PROMPT_LIMIT="${HERMES_X_BUZZ_DEDUP_PROMPT_LIMIT:-80}"
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_TOPICS="${HERMES_X_BUZZ_MAX_TOPICS:-4}"
MAX_OFFICIAL_TOPICS="${HERMES_X_BUZZ_MAX_OFFICIAL_TOPICS:-2}"
MIN_SCORE="${HERMES_X_BUZZ_MIN_SCORE:-1500}"
MIN_SOCIAL_LIKES="${HERMES_X_BUZZ_MIN_SOCIAL_LIKES:-250}"
MIN_SOCIAL_REPOSTS="${HERMES_X_BUZZ_MIN_SOCIAL_REPOSTS:-25}"
OFFICIAL_MIN_LIKES="${HERMES_X_BUZZ_OFFICIAL_MIN_LIKES:-20}"
OFFICIAL_MIN_VIEWS="${HERMES_X_BUZZ_OFFICIAL_MIN_VIEWS:-2000}"
OFFICIAL_HANDLES="${HERMES_X_BUZZ_OFFICIAL_HANDLES:-OpenAI OpenAIDevs AnthropicAI claudeai SpaceX Google GoogleDeepMind GeminiApp xai GoogleAI}"
SEARCH_HELPER="${HERMES_X_BUZZ_SEARCH_HELPER:-${HERMES_HOME_DIR}/scripts/hermes-x-buzz-search.py}"
RANK_HELPER="${HERMES_X_BUZZ_RANK_HELPER:-${HERMES_HOME_DIR}/scripts/hermes-x-buzz-rank.py}"
REPO_SEARCH_HELPER_CANDIDATES=(
  "${HERMES_HOME_DIR}/runtime/grok-signal-agent/scripts/hermes-x-buzz-search.py"
)
REPO_RANK_HELPER_CANDIDATES=(
  "${THIS_DIR}/hermes-x-buzz-rank.py"
  "${HERMES_HOME_DIR}/runtime/grok-signal-agent/scripts/hermes-x-buzz-rank.py"
)

mkdir -p "${LOG_DIR}" "${BUZZ_DIR}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}"
}

read_optional_file() {
  local file="$1" limit="${2:-260}"
  [[ -f "${file}" ]] && sed -n "1,${limit}p" "${file}"
}

run_with_timeout() {
  local seconds="$1"
  shift
  if command -v perl >/dev/null 2>&1; then
    perl -e '$seconds = shift @ARGV; alarm $seconds; exec @ARGV or die "exec failed: $!\n"' \
      "${seconds}" "$@"
  else
    "$@"
  fi
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

extract_digest_body() {
  printf '%s\n' "$1" \
    | tr -d '\r' \
    | awk '
        /^###[[:space:]]+/ { keep=1 }
        keep && $0 == "NO_QUALIFIED_BUZZ" { next }
        keep && $0 ~ /already_posted_status_ids|fresh_status_ids_seen|The evidence|the prompt explicitly|The user wants|Let me carefully|If nothing qualifies|the correct output is/ { next }
        keep { print }
      '
}

is_tool_leak_output() {
  local text="$1"
  grep -Eqi 'tool_call|eth_call|x_keyword_search|function[ _]?call|</?xai|min_likes:|product_Latest|Satool |call_thread:|<\|eos\|>' <<< "${text}"
}

is_postable_buzz_digest() {
  local text="$1" section_count
  section_count="$(grep -Ec '^###[[:space:]]+' <<< "${text}" || true)"
  (( section_count >= 1 )) && has_source_links "${text}" && ! is_tool_leak_output "${text}"
}

normalize_status_id_list() {
  grep -Eo '[0-9]{15,}' | sort -u || true
}

extract_status_ids_from_text() {
  local text="$1"
  {
    printf '%s\n' "${text}" | grep -Eoi "${STATUS_ID_REGEX}" || true
    printf '%s\n' "${text}" | grep -Eo '/status/[0-9]+' || true
  } | grep -Eo '[0-9]{15,}' | sort -u
}

rebuild_posted_ids_file() {
  local tmp
  tmp="$(mktemp)"
  if compgen -G "${BUZZ_DIR}/[0-9]*.md" >/dev/null; then
    # shellcheck disable=SC2012
    ls -1t "${BUZZ_DIR}"/[0-9]*.md 2>/dev/null | head -n "${DEDUP_LOOKBACK_POSTS}" \
      | while IFS= read -r f; do
          extract_status_ids_from_text "$(cat "${f}")"
        done | normalize_status_id_list > "${tmp}" || true
  else
    : > "${tmp}"
  fi
  if [[ -f "${POSTED_IDS_FILE}" ]]; then
    cat "${POSTED_IDS_FILE}" >> "${tmp}" || true
    normalize_status_id_list < "${tmp}" > "${POSTED_IDS_FILE}.new"
    mv "${POSTED_IDS_FILE}.new" "${POSTED_IDS_FILE}"
  else
    normalize_status_id_list < "${tmp}" > "${POSTED_IDS_FILE}"
  fi
  rm -f "${tmp}"
}

load_posted_ids() {
  [[ -f "${POSTED_IDS_FILE}" ]] || rebuild_posted_ids_file
  [[ -s "${POSTED_IDS_FILE}" ]] || return 0
  cat "${POSTED_IDS_FILE}"
}

remember_posted_ids() {
  local text="$1" tmp
  tmp="$(mktemp)"
  {
    load_posted_ids || true
    extract_status_ids_from_text "${text}"
  } | normalize_status_id_list > "${tmp}"
  mv "${tmp}" "${POSTED_IDS_FILE}"
}

resolve_rank_helper() {
  if [[ -f "${RANK_HELPER}" ]]; then
    printf '%s\n' "${RANK_HELPER}"
    return 0
  fi
  local candidate
  for candidate in "${REPO_RANK_HELPER_CANDIDATES[@]}"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

filter_already_posted_sections() {
  local text="$1"
  local posted_ids="$2"
  local tmp ranker
  ranker="$(resolve_rank_helper || true)"
  if [[ -z "${ranker}" ]]; then
    log "rank helper missing; refusing to post an unranked digest"
    return 1
  fi
  tmp="$(mktemp)"
  printf '%s\n' "${text}" > "${tmp}"
  HERMES_X_BUZZ_MAX_TOPICS="${MAX_TOPICS}" \
    HERMES_X_BUZZ_MAX_OFFICIAL_TOPICS="${MAX_OFFICIAL_TOPICS}" \
    HERMES_X_BUZZ_MIN_SCORE="${MIN_SCORE}" \
    HERMES_X_BUZZ_MIN_SOCIAL_LIKES="${MIN_SOCIAL_LIKES}" \
    HERMES_X_BUZZ_MIN_SOCIAL_REPOSTS="${MIN_SOCIAL_REPOSTS}" \
    HERMES_X_BUZZ_OFFICIAL_MIN_LIKES="${OFFICIAL_MIN_LIKES}" \
    HERMES_X_BUZZ_OFFICIAL_MIN_VIEWS="${OFFICIAL_MIN_VIEWS}" \
    HERMES_X_BUZZ_OFFICIAL_HANDLES="${OFFICIAL_HANDLES}" \
    python3 "${ranker}" select \
      --text-file "${tmp}" \
      --posted-ids "$(printf '%s\n' "${posted_ids}" | tr '\n' ' ')"
  local status=$?
  rm -f "${tmp}"
  return "${status}"
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
  # Live check only. Do not treat stale gateway.error.log lines as current
  # outages — old spending-limit 403s were blocking later healthy runs.
  local probe
  probe="$(
    python3 - <<'PY' 2>/dev/null || true
import sys
from pathlib import Path
root = Path.home() / ".hermes" / "hermes-agent"
if (root / "tools" / "x_search_tool.py").exists():
    sys.path.insert(0, str(root))
try:
    from tools.x_search_tool import check_x_search_requirements
    print("ok" if check_x_search_requirements() else "missing")
except Exception as exc:
    print(f"error:{exc}")
PY
  )"
  case "${probe}" in
    ok) return 1 ;;
    missing)
      printf 'xAI OAuth credentials are not available'
      return 0
      ;;
    error:*)
      printf 'x_search credential probe failed'
      return 0
      ;;
  esac
  return 1
}

resolve_search_helper() {
  if [[ -f "${SEARCH_HELPER}" ]]; then
    printf '%s\n' "${SEARCH_HELPER}"
    return 0
  fi
  local candidate
  for candidate in "${REPO_SEARCH_HELPER_CANDIDATES[@]}"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
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

mark_unavailable() {
  local reason="$1" streak
  streak=$(( $(read_streak) + 1 ))
  write_streak "${streak}" "${reason}"
  if (( streak == UNAVAILABLE_ALERT_STREAK )) || { (( streak > UNAVAILABLE_ALERT_STREAK )) && (( streak % UNAVAILABLE_ALERT_STREAK == 0 )); }; then
    send_alert "Hermes X buzz digest has skipped x_search ${streak} times in a row" \
      "reason=${reason}
X buzz digest has been unable to produce a source-backed post for ${streak} consecutive scheduled attempts. Check xAI/Grok access and Hermes tool execution."
  fi
}

[[ -x "${HERMES_BIN}" ]] || { echo "missing Hermes binary: ${HERMES_BIN}" >&2; exit 1; }
[[ -f "${PROMPT_FILE}" ]] || { echo "missing x buzz digest prompt: ${PROMPT_FILE}" >&2; exit 1; }

helper_path="$(resolve_search_helper || true)"
if [[ -z "${helper_path}" ]]; then
  log "direct x_search helper unavailable; using Hermes tool fallback"
fi

now="$(date '+%Y-%m-%d %H:%M:%S %z')"
timestamp="$(date '+%Y%m%d-%H%M%S')"
digest_prefix="$(digest_prefix_for_hour "$(date '+%H')")"
from_date="$(date -u -v-"${WINDOW_HOURS}"H '+%Y-%m-%d' 2>/dev/null || date -u -d "${WINDOW_HOURS} hours ago" '+%Y-%m-%d')"
to_date="$(date -u '+%Y-%m-%d')"

log "starting x buzz digest cron model=${X_BUZZ_MODEL} provider=${X_BUZZ_PROVIDER} helper=${helper_path}"

xai_reason=""
if [[ "${X_BUZZ_PREFLIGHT}" != "0" ]]; then
  xai_reason="$(xai_unavailable_reason || true)"
fi
if [[ -n "${xai_reason}" ]]; then
  log "x_search preflight skipped: ${xai_reason}"
  mark_unavailable "${xai_reason}"
  exit 0
fi

rebuild_posted_ids_file
posted_ids="$(load_posted_ids || true)"
posted_ids_for_prompt="$(printf '%s\n' "${posted_ids}" | tail -n "${DEDUP_PROMPT_LIMIT}" | tr '\n' ' ')"
posted_count="$(printf '%s\n' "${posted_ids}" | grep -c '^[0-9]' || true)"

search_raw_file="$(mktemp)"
set +e
if [[ -n "${helper_path}" ]]; then
  run_with_timeout "${TOOL_TIMEOUT_SECONDS}" \
    python3 "${helper_path}" \
      --window-hours "${WINDOW_HOURS}" \
      --from-date "${from_date}" \
      --to-date "${to_date}" \
      --exclude-ids-file "${POSTED_IDS_FILE}" \
      --out "${search_raw_file}" \
    >>"${LOG_FILE}" 2>&1
else
  run_with_timeout "${TOOL_TIMEOUT_SECONDS}" \
    "${HERMES_BIN}" -t x_search -z "Find qualified circulating X/Twitter posts from the last ${WINDOW_HOURS} hours about AI, developer tools, and infrastructure. Return direct post URLs and engagement evidence only." \
    >"${search_raw_file}" 2>>"${LOG_FILE}"
fi
search_code=$?
set -e

if [[ "${search_code}" -ne 0 ]]; then
  log "direct x_search helper failed exit=${search_code}"
  mark_unavailable "direct x_search helper failed with exit ${search_code}"
  rm -f "${search_raw_file}"
  exit 0
fi

if [[ ! -s "${search_raw_file}" ]] || grep -Eq '^NO_QUALIFIED_BUZZ[[:space:]]*$' "${search_raw_file}"; then
  clear_streak
  log "no qualified buzz from direct search; not posting"
  printf '' > "${BUZZ_DIR}/.${timestamp}.no-buzz"
  rm -f "${search_raw_file}"
  exit 0
fi

search_blob="$(cat "${search_raw_file}")"
rm -f "${search_raw_file}"

if [[ -z "${helper_path}" ]]; then
  # The legacy Hermes tool already returns a post-shaped digest. Keep this
  # path for older installs and test doubles that do not have the helper yet.
  curation="${search_blob}"
  code=0
else
  # Summarize pre-fetched X results only — no live tools needed.
prompt="$(cat <<PROMPT
$(read_optional_file "${PROMPT_FILE}" 320)

# Runtime context

Current local time is ${now}.
This is the ${digest_prefix} X buzz check.
window_hours=${WINDOW_HOURS}
When an example includes <digest_prefix>, replace it with "${digest_prefix}".
already_posted_status_id_count=${posted_count}
already_posted_status_ids=${posted_ids_for_prompt}
Hard rule: never include any status id listed in already_posted_status_ids.

IMPORTANT: Do NOT call any tools. X search already ran. Use ONLY the evidence
block below. Every topic URL must come from that evidence. If nothing qualifies
as NEW and useful after excluding already_posted_status_ids, return exactly:
NO_QUALIFIED_BUZZ

# Evidence from x_search (already executed)

${search_blob}

Output rules: return only the digest body. No greeting, no Hermes-chan voice,
no intro, no outro, no next-action advice. Follow the structure in the prompt.
PROMPT
)"

set +e
curation="$(
  run_with_timeout 240 \
    "${HERMES_BIN}" chat \
      -q "${prompt}" \
      -t '' \
      -m "${X_BUZZ_MODEL}" \
      --provider "${X_BUZZ_PROVIDER}" \
      -Q \
      --ignore-rules \
      --safe-mode \
      --max-turns 2 \
      --yolo \
    2>>"${LOG_FILE}"
)"
code=$?
set -e
fi

curation="$(
  printf '%s\n' "${curation}" \
    | grep -vE '^(session_id: |Warning: )' \
    | awk 'NF { p=1 } p' \
    | awk 'BEGIN{n=0} {lines[++n]=$0} END{while(n>0 && lines[n] ~ /^[[:space:]]*$/) n--; for(i=1;i<=n;i++) print lines[i]}'
)"
extracted="$(extract_digest_body "${curation}")"
if [[ -n "${extracted//[[:space:]]/}" ]]; then
  curation="${extracted}"
fi

if [[ "${code}" -ne 0 ]]; then
  log "summarizer failed exit=${code}"
  mark_unavailable "summarizer failed with exit ${code}"
  exit 0
fi

if [[ -z "${curation//[[:space:]]/}" ]] || is_no_qualified_buzz "${curation}"; then
  clear_streak
  log "no qualified buzz this window; not posting"
  printf '' > "${BUZZ_DIR}/.${timestamp}.no-buzz"
  exit 0
fi

if is_tool_leak_output "${curation}"; then
  log "curation leaked tool-call text; saving for inspection, not posting"
  {
    printf -- '---\n'
    printf 'created_at: "%s"\n' "${now}"
    printf 'digest_prefix: "%s"\n' "${digest_prefix}"
    printf 'status: "not_posted_tool_leak"\n'
    printf -- '---\n\n'
    printf '%s\n' "${curation}"
  } > "${BUZZ_DIR}/.failed-${timestamp}.md"
  mark_unavailable "model returned tool-call text instead of a digest"
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
  mark_unavailable "summarizer returned no postable sections or direct X links"
  exit 0
fi

filtered="$(filter_already_posted_sections "${curation}" "${posted_ids}" || true)"
if [[ -z "${filtered//[[:space:]]/}" ]] || ! is_postable_buzz_digest "${filtered}"; then
  clear_streak
  log "all candidate posts already posted; not posting"
  {
    printf -- '---\n'
    printf 'created_at: "%s"\n' "${now}"
    printf 'digest_prefix: "%s"\n' "${digest_prefix}"
    printf 'status: "deduped_not_posted"\n'
    printf -- '---\n\n'
    printf '%s\n' "${curation}"
  } > "${BUZZ_DIR}/.deduped-${timestamp}.md"
  exit 0
fi

curation="${filtered}"
clear_streak

{
  printf -- '---\n'
  printf 'created_at: "%s"\n' "${now}"
  printf 'digest_prefix: "%s"\n' "${digest_prefix}"
  printf 'model: "%s"\n' "${X_BUZZ_MODEL}"
  printf -- '---\n\n'
  printf '%s\n' "${curation}"
} > "${BUZZ_DIR}/${timestamp}.md"

remember_posted_ids "${curation}"
log "saved and posting x buzz digest ${BUZZ_DIR}/${timestamp}.md"

printf '%s\n' "${curation}"
