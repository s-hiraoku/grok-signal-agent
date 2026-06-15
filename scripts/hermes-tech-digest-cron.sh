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
EVAL_DIR="${STATE_DIR}/evaluations"
METADATA_DIR="${STATE_DIR}/digest-metadata"
QUALITY_DIR="${STATE_DIR}/digest-quality"
GBRAIN_BRAIN="${GBRAIN_BRAIN:-${HOME}/.hermes/brain}"
LINT_SCRIPT="${HERMES_DIGEST_LINT_SCRIPT:-${HOME}/.hermes/bin/hermes-digest-lint.sh}"
ALERT_SCRIPT="${HERMES_ALERT_SCRIPT:-${HOME}/.hermes/bin/hermes-alert.sh}"
JINA_FALLBACK_ENABLED="${HERMES_TECH_DIGEST_JINA_FALLBACK:-1}"
JINA_FALLBACK_URLS="${HERMES_TECH_DIGEST_JINA_URLS:-OpenAI News|https://openai.com/news/;GitHub Changelog|https://github.blog/changelog/;web.dev Blog|https://web.dev/blog/;Chrome Developers Blog|https://developer.chrome.com/blog/;Zenn Explore|https://zenn.dev/articles/explore;wbsb.dev New|https://wbsb.dev/?tab=new}"

mkdir -p "${LOG_DIR}" "${DIGEST_DIR}" "${EVAL_DIR}" "${METADATA_DIR}" "${QUALITY_DIR}"

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
  grep -Eqi 'https?://(x\.com|twitter\.com)/[^[:space:])>]+' <<< "$1"
}

run_jina_fallback() {
  [[ "${JINA_FALLBACK_ENABLED}" == "1" ]] || return 1

  local fallback_prompt fallback_sources
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

  "${HERMES_BIN}" -t jina_reader -z "${fallback_prompt}" 2>>"${LOG_FILE}"
}

resolve_gbrain_bin() {
  if [[ -n "${GBRAIN_BIN:-}" ]]; then
    printf '%s' "${GBRAIN_BIN}"
  elif command -v gbrain >/dev/null 2>&1; then
    command -v gbrain
  elif [[ -x "${HOME}/.bun/bin/gbrain" ]]; then
    printf '%s' "${HOME}/.bun/bin/gbrain"
  fi
}

gbrain_writeback() {
  local slug="$1" type="$2" body_file="$3" created_at="$4"
  [[ "${HERMES_GBRAIN_WRITEBACK:-}" == "1" ]] || return 0

  local bin
  bin="$(resolve_gbrain_bin)"
  if [[ -z "${bin}" || ! -d "${GBRAIN_BRAIN}" ]]; then
    log "gbrain write-back skipped for ${slug}"
    return 0
  fi

  if {
        printf -- '---\n'
        printf 'type: "%s"\n' "${type}"
        printf 'slug: "%s"\n' "${slug}"
        printf 'created_at: "%s"\n' "${created_at}"
        printf -- '---\n\n'
        cat "${body_file}"
      } | ( cd "${GBRAIN_BRAIN}" && "${bin}" put "${slug}" >>"${LOG_FILE}" 2>&1 ); then
    log "gbrain write-back ok: ${slug}"
  else
    log "gbrain write-back failed for ${slug}; continuing"
  fi
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

extract_total_score() {
  awk -F ':' '
    /^[[:space:]]*-[[:space:]]*総合:/ {
      gsub(/[^0-9.]/, "", $2)
      print $2
      exit
    }
  ' "$1" 2>/dev/null || true
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

digest_tmp="${DIGEST_DIR}/.${timestamp}.writeback.md"
printf '%s\n' "${curation}" > "${digest_tmp}"
gbrain_writeback "digest-${timestamp}" "digest" "${digest_tmp}" "${now}"
rm -f "${digest_tmp}"

if [[ -f "${EVALUATION_PROMPT_FILE}" ]]; then
  eval_file="${EVAL_DIR}/${timestamp}.md"
  eval_prompt="$(printf '%s\n\n# Current self-memory\n%s\n\n# Digest to evaluate\n%s\n' "$(read_optional_file "${EVALUATION_PROMPT_FILE}" 260)" "$(read_optional_file "${MEMORY_FILE}" 220)" "${curation}")"
  if evaluation="$("${HERMES_BIN}" -z "${eval_prompt}" 2>>"${LOG_FILE}")"; then
    {
      printf -- '---\n'
      printf 'created_at: "%s"\n' "${now}"
      printf 'digest_file: "%s"\n' "${digest_file}"
      printf -- '---\n\n'
      printf '%s\n' "${evaluation}"
    } > "${eval_file}"
    log "saved self-evaluation ${eval_file}"

    total_score="$(extract_total_score "${eval_file}")"
    if [[ -n "${total_score}" ]] && awk "BEGIN { exit !(${total_score} < 3) }"; then
      send_alert "Hermes digest self-evaluation is low" "Evaluation: ${eval_file}
Total score: ${total_score}
Digest: ${digest_file}"
    fi

    eval_tmp="${EVAL_DIR}/.${timestamp}.writeback.md"
    printf '%s\n' "${evaluation}" > "${eval_tmp}"
    gbrain_writeback "evaluation-${timestamp}" "evaluation" "${eval_tmp}" "${now}"
    rm -f "${eval_tmp}"
  else
    log "self-evaluation failed; continuing"
  fi
fi

printf '%s\n\n更新: %s\n' "${curation}" "${now}"
