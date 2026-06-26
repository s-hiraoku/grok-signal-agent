#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.bun/bin:${PATH}"

HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
PROMPT_DIR="${HERMES_PROMPT_DIR:-${HOME}/.hermes/prompts}"
STATE_DIR="${HERMES_STATE_DIR:-${HOME}/.hermes/state}"
LOG_DIR="${HERMES_LOG_DIR:-${HOME}/.hermes/logs}"
LOG_FILE="${LOG_DIR}/hermes-tech-digest-cron.log"
PROMPT_FILE="${HERMES_TECH_DIGEST_PROMPT_FILE:-${PROMPT_DIR}/tech-digest.md}"
IDENTITY_FILE="${HERMES_IDENTITY_FILE:-${PROMPT_DIR}/hermes-chan-identity.md}"
POST_STYLE_FILE="${HERMES_POST_STYLE_FILE:-${PROMPT_DIR}/hermes-post-style.md}"
MEMORY_FILE="${HERMES_CHAN_MEMORY_FILE:-${STATE_DIR}/hermes-chan-memory.md}"
EVALUATION_PROMPT_FILE="${HERMES_EVALUATION_PROMPT_FILE:-${PROMPT_DIR}/evaluate-digest.md}"
DIGEST_DIR="${STATE_DIR}/digests"
METADATA_DIR="${STATE_DIR}/digest-metadata"
QUALITY_DIR="${STATE_DIR}/digest-quality"
LINT_SCRIPT="${HERMES_DIGEST_LINT_SCRIPT:-${HOME}/.hermes/bin/hermes-digest-lint.sh}"
ALERT_SCRIPT="${HERMES_ALERT_SCRIPT:-${HOME}/.hermes/bin/hermes-alert.sh}"
JINA_FALLBACK_ENABLED="${HERMES_TECH_DIGEST_JINA_FALLBACK:-1}"
JINA_FALLBACK_URLS="${HERMES_TECH_DIGEST_JINA_URLS:-OpenAI News|https://openai.com/news/;GitHub Changelog|https://github.blog/changelog/;web.dev Blog|https://web.dev/blog/;Chrome Developers Blog|https://developer.chrome.com/blog/;Zenn Explore|https://zenn.dev/articles/explore}"
JINA_READER_BASE_URL="${HERMES_TECH_DIGEST_JINA_READER_BASE_URL:-https://r.jina.ai/}"
CURL_BIN="${CURL_BIN:-curl}"
GATEWAY_ERROR_LOG="${HERMES_GATEWAY_ERROR_LOG:-${LOG_DIR}/gateway.error.log}"
FORCE_DIRECT_FALLBACK="${HERMES_TECH_DIGEST_FORCE_DIRECT_FALLBACK:-0}"
X_POST_URL_REGEX='https?://(x\.com|twitter\.com)/([^/?#[:space:]]+/status|i/web/status)/[0-9][0-9]*[^[:space:])>]*'

mkdir -p "${LOG_DIR}" "${DIGEST_DIR}" "${METADATA_DIR}" "${QUALITY_DIR}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}"
}

read_optional_file() {
  local file="$1" limit="${2:-260}"
  [[ -f "${file}" ]] && sed -n "1,${limit}p" "${file}"
}

digest_prefix_for_hour() {
  local hour="$1"
  if (( 10#${hour} < 11 )); then
    printf '朝の'
  elif (( 10#${hour} < 16 )); then
    printf '昼の'
  else
    printf '夕方の'
  fi
}

has_source_links() {
  grep -Eqi "${X_POST_URL_REGEX}" <<< "$1"
}

has_reference_sections() {
  local text="$1" section_count reference_count
  section_count="$(grep -Ec '^###[[:space:]]+' <<< "${text}" || true)"
  reference_count="$(grep -Ec '^参照ページ:[[:space:]]*https?://' <<< "${text}" || true)"
  (( section_count >= 4 && reference_count >= section_count ))
}

reader_url_for() {
  printf '%s%s' "${JINA_READER_BASE_URL}" "$1"
}

run_jina_direct_fallback() {
  command -v "${CURL_BIN}" >/dev/null 2>&1 || return 1

  local fallback_sources source label url page title links output sections reader_url
  fallback_sources="${JINA_FALLBACK_URLS//;/$'\n'}"
  output="Jina Reader direct fallback digest"
  sections=0
  while IFS= read -r source; do
    [[ -n "${source}" ]] || continue
    label="${source%%|*}"
    url="${source#*|}"
    [[ "${label}" != "${url}" && "${url}" == http* ]] || continue

    reader_url="$(reader_url_for "${url}")"
    if ! page="$("${CURL_BIN}" -L --max-time 20 -sS "${reader_url}" 2>>"${LOG_FILE}")"; then
      log "jina_reader direct fetch failed for ${label}"
      continue
    fi
    [[ -n "${page//[[:space:]]/}" ]] || continue

    title="$(awk -F ': ' '/^Title: / { print $2; exit }' <<< "${page}")"
    [[ -n "${title}" ]] || title="${label}"
    links="$(grep -Eo '\[[^][]+\]\(https?://[^) ]+\)' <<< "${page}" \
      | sed -E 's/^\[([^]]+)\]\(([^)]+)\)$/  - \1: \2/' \
      | awk '!seen[$0]++' \
      | sed -n '1,3p' || true)"

    output+=$'\n\n'"### ${label}"$'\n'
    output+="${title} をJina Readerの公開エンドポイントで確認しました。X/Twitterの反応指標は使えないため、一次情報ページを優先してください。"$'\n'
    if [[ -n "${links}" ]]; then
      output+="関連リンク:"$'\n'"${links}"$'\n'
    fi
    output+="参照ページ: ${url}"$'\n'
    sections=$((sections + 1))
    (( sections >= 4 )) && break
  done <<< "${fallback_sources}"

  (( sections >= 4 )) || return 1
  printf '%s\n' "${output}"
}

run_jina_fallback() {
  [[ "${JINA_FALLBACK_ENABLED}" == "1" ]] || return 1

  local fallback_prompt fallback_sources mcp_output
  fallback_sources="${JINA_FALLBACK_URLS//;/$'\n'}"
  fallback_prompt="$(cat <<PROMPT
$(read_optional_file "${PROMPT_FILE}" 260)

# Runtime context

Current local time is ${now}.
This is the ${digest_prefix} digest.
x_search is currently unavailable. Use the Jina Reader MCP tools instead.

# Jina Reader fallback sources

Read these public pages with Jina Reader. Prefer recent, direct source pages and
do not invent X/Twitter URLs or engagement metrics.

${fallback_sources}

# Output requirements

- Write a Japanese Discord-ready digest with 4 to 8 sections.
- Use headings in the form "### <topic>".
- Every section must include a direct source line in this exact form:
  参照ページ: <direct URL>
- Prefer AI engineering, developer tools, web platform, infrastructure, and
  security topics.
- Mention that this is a Jina Reader fallback only if needed to explain missing
  X/Twitter reaction metrics.

# Persistent identity

$(read_optional_file "${IDENTITY_FILE}" 180)

# Posting style for Discord

$(read_optional_file "${POST_STYLE_FILE}" 180)

# Current self-memory and preferences

$(read_optional_file "${MEMORY_FILE}" 160)
${gbrain_context:+
# Retrieved gbrain guidance

${gbrain_context}
}
PROMPT
)"

  if mcp_output="$("${HERMES_BIN}" -t jina_reader -z "${fallback_prompt}" 2>>"${LOG_FILE}")" \
      && has_reference_sections "${mcp_output}"; then
    printf '%s\n' "${mcp_output}"
    return 0
  fi

  log "jina_reader MCP fallback did not return a valid digest; trying direct Reader fallback"
  run_jina_direct_fallback
}

gbrain_retrieval_context() {
  [[ "${HERMES_GBRAIN_RETRIEVAL:-}" == "1" ]] || return 0
  local retrieval_script="${HERMES_GBRAIN_RETRIEVAL_SCRIPT:-${HOME}/.hermes/bin/hermes-gbrain-retrieval.sh}"
  [[ -x "${retrieval_script}" ]] && "${retrieval_script}" 2>>"${LOG_FILE}" || true
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
  [[ "${FORCE_DIRECT_FALLBACK}" == "1" ]] && {
    printf 'forced direct fallback requested'
    return 0
  }
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

[[ -x "${HERMES_BIN}" ]] || { echo "missing Hermes binary: ${HERMES_BIN}" >&2; exit 1; }
[[ -f "${PROMPT_FILE}" ]] || { echo "missing tech digest prompt: ${PROMPT_FILE}" >&2; exit 1; }

now="$(date '+%Y-%m-%d %H:%M:%S %z')"
timestamp="$(date '+%Y%m%d-%H%M%S')"
today="$(date '+%Y-%m-%d')"
yesterday="$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d 'yesterday' '+%Y-%m-%d')"
digest_prefix="$(digest_prefix_for_hour "$(date '+%H')")"
gbrain_context="$(gbrain_retrieval_context)"

prompt="$(cat <<PROMPT
$(read_optional_file "${PROMPT_FILE}" 420)

# Runtime context

Current local time is ${now}.
This is the ${digest_prefix} digest.
Prefer from_date=${today}; use from_date=${yesterday} only when needed to cover overnight or early-morning context.
When an example includes <digest_prefix>, replace it with "${digest_prefix}".

# Persistent identity

$(read_optional_file "${IDENTITY_FILE}" 220)

# Posting style for Discord

$(read_optional_file "${POST_STYLE_FILE}" 220)

# Current self-memory and preferences

$(read_optional_file "${MEMORY_FILE}" 220)
${gbrain_context:+
# Retrieved gbrain guidance

${gbrain_context}
}
PROMPT
)"

retry_prompt="${prompt}

Previous attempts sometimes omitted links. This time, every detailed section must include at least one visible direct https://x.com/ or https://twitter.com/ URL directly under a related post entry. Return only sections with direct source URLs."

log "starting tech digest cron"
xai_reason="$(xai_unavailable_reason || true)"
if [[ -n "${xai_reason}" ]]; then
  log "x_search preflight skipped: ${xai_reason}"
  if curation="$(run_jina_direct_fallback)"; then
    log "direct Jina Reader degraded fallback succeeded after x_search preflight skip"
    curation_source="jina_reader"
  else
    send_alert "Hermes tech digest degraded fallback failed" "Reason: ${xai_reason}"
    exit 1
  fi
else
  set +e
  curation="$("${HERMES_BIN}" -t x_search -z "${prompt}" 2>>"${LOG_FILE}")"
  code=$?
  set -e
  if [[ "${code}" -ne 0 ]]; then
    log "x_search curation failed exit=${code}"
    if curation="$(run_jina_fallback)"; then
      log "jina_reader fallback curation succeeded after x_search failure"
      curation_source="jina_reader"
    else
      log "jina_reader fallback curation failed after x_search failure"
      exit "${code}"
    fi
  else
    curation_source="x_search"
  fi

  if [[ "${curation_source}" == "x_search" ]] && ! has_source_links "${curation}"; then
    log "curation had no direct X links; retrying"
    set +e
    curation="$("${HERMES_BIN}" -t x_search -z "${retry_prompt}" 2>>"${LOG_FILE}")"
    code=$?
    set -e
    if [[ "${code}" -ne 0 ]]; then
      log "x_search retry failed; trying jina_reader fallback"
      if curation="$(run_jina_fallback)"; then
        log "jina_reader fallback curation succeeded after x_search retry failure"
        curation_source="jina_reader"
      else
        log "jina_reader fallback curation failed after x_search retry failure"
        exit 1
      fi
    elif ! has_source_links "${curation}"; then
      log "x_search retry still had no direct X links; trying jina_reader fallback"
      if fallback_curation="$(run_jina_fallback)"; then
        curation="${fallback_curation}"
        log "jina_reader fallback curation succeeded after missing X links"
        curation_source="jina_reader"
      else
        log "warning: jina_reader fallback failed after missing X links; proceeding with linkless x_search curation"
      fi
    fi
  fi
fi

[[ -n "${curation//[[:space:]]/}" ]] || { log "curation returned empty output"; exit 1; }

digest_file="${DIGEST_DIR}/${timestamp}.md"
{
  printf -- '---\n'
  printf 'created_at: "%s"\n' "${now}"
  printf 'digest_prefix: "%s"\n' "${digest_prefix}"
  printf 'curation_source: "%s"\n' "${curation_source}"
  printf -- '---\n\n'
  printf '%s\n' "${curation}"
} > "${digest_file}"
log "saved digest ${digest_file}"

metadata_file="${METADATA_DIR}/${timestamp}.json"
quality_report="${QUALITY_DIR}/${timestamp}.md"
if [[ -x "${LINT_SCRIPT}" ]]; then
  if HERMES_DIGEST_METADATA_DIR="${METADATA_DIR}" \
       "${LINT_SCRIPT}" "${digest_file}" "${metadata_file}" "${quality_report}" \
       >>"${LOG_FILE}" 2>&1; then
    log "digest quality lint passed: ${quality_report}"
  else
    log "digest quality lint failed: ${quality_report}"
    send_alert "Hermes digest quality lint failed" "Digest: ${digest_file}
Report: ${quality_report}"
    if [[ "${HERMES_DIGEST_LINT_STRICT:-}" == "1" ]]; then
      exit 1
    fi
  fi
else
  log "digest lint skipped; missing executable ${LINT_SCRIPT}"
fi

log "deferred digest evaluation and gbrain write-back to hermes-tech-digest-evaluate-cron.sh"

printf '%s\n\n更新: %s\n' "${curation}" "${now}"
