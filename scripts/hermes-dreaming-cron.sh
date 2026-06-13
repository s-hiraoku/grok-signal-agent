#!/usr/bin/env bash
set -euo pipefail

# Nightly memory recomposition for ヘルメスちゃん.
#
# This is intentionally "recomposition", not forgetting:
# - raw sessions, digests, evaluations, and feedback stay untouched;
# - a full dreaming report is saved under ~/.hermes/state/dreaming/;
# - only the working memory view (~/.hermes/state/hermes-chan-memory.md) is
#   replaced with the synthesized section from the report.

HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
PROMPT_DIR="${HERMES_PROMPT_DIR:-${HOME}/.hermes/prompts}"
STATE_DIR="${HERMES_STATE_DIR:-${HOME}/.hermes/state}"
LOG_DIR="${HERMES_LOG_DIR:-${HOME}/.hermes/logs}"
MEMORY_FILE="${HERMES_CHAN_MEMORY_FILE:-${STATE_DIR}/hermes-chan-memory.md}"
PROMPT_FILE="${HERMES_DREAMING_PROMPT_FILE:-${PROMPT_DIR}/nightly-dreaming.md}"
IDENTITY_FILE="${HERMES_IDENTITY_FILE:-${PROMPT_DIR}/hermes-chan-identity.md}"
HERMES_MEMORY_DIR="${HERMES_MEMORY_DIR:-${HOME}/.hermes/memories}"
STATE_DB="${HERMES_STATE_DB:-${HOME}/.hermes/state.db}"

DREAMING_DIR="${STATE_DIR}/dreaming"
DIGEST_DIR="${STATE_DIR}/digests"
EVAL_DIR="${STATE_DIR}/evaluations"
FEEDBACK_DIR="${STATE_DIR}/user-feedback"
WEEKLY_DIR="${STATE_DIR}/weekly-reflections"
LOG_FILE="${LOG_DIR}/hermes-dreaming.log"
LOCK_DIR="${STATE_DIR}/hermes-dreaming.lock"
LOCK_PID="${LOCK_DIR}/pid"

RECENT_MESSAGE_LIMIT="${HERMES_DREAMING_MESSAGE_LIMIT:-80}"
RECENT_DIGEST_LIMIT="${HERMES_DREAMING_DIGEST_LIMIT:-6}"
RECENT_EVAL_LIMIT="${HERMES_DREAMING_EVAL_LIMIT:-12}"
RECENT_FEEDBACK_LIMIT="${HERMES_DREAMING_FEEDBACK_LIMIT:-12}"
RECENT_WEEKLY_LIMIT="${HERMES_DREAMING_WEEKLY_LIMIT:-4}"

mkdir -p "${STATE_DIR}" "${LOG_DIR}" "${DREAMING_DIR}" "${DIGEST_DIR}" "${EVAL_DIR}" "${FEEDBACK_DIR}" "${WEEKLY_DIR}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}"
}

read_optional_file() {
  local file="$1" limit="${2:-260}"
  [[ -f "${file}" ]] && sed -n "1,${limit}p" "${file}"
}

latest_files_content() {
  local dir="$1" limit="$2" line_limit="${3:-180}"

  if ! find "${dir}" -type f -name '*.md' -print -quit 2>/dev/null | grep -q .; then
    return
  fi

  find "${dir}" -type f -name '*.md' -print0 \
    | xargs -0 ls -t \
    | sed -n "1,${limit}p" \
    | while IFS= read -r file; do
        printf '\n\n## %s\n\n' "${file}"
        sed -n "1,${line_limit}p" "${file}"
      done
}

recent_session_context() {
  command -v sqlite3 >/dev/null 2>&1 || return 0
  [[ -f "${STATE_DB}" ]] || return 0

  sqlite3 -readonly "${STATE_DB}" <<SQL 2>/dev/null || true
.mode list
.separator ' '
SELECT line FROM (
  SELECT
    timestamp,
    strftime('%Y-%m-%d %H:%M:%S', timestamp, 'unixepoch', 'localtime')
      || ' ' || role || ': '
      || replace(replace(substr(coalesce(content, ''), 1, 1200), char(10), ' '), char(13), ' ')
      AS line
  FROM messages
  WHERE role IN ('user', 'assistant')
    AND content IS NOT NULL
    AND length(trim(content)) > 0
  ORDER BY timestamp DESC
  LIMIT ${RECENT_MESSAGE_LIMIT}
)
ORDER BY timestamp ASC;
SQL
}

extract_recomposed_memory() {
  awk '
    /^# ヘルメスちゃんの自己メモリ[[:space:]]*$/ { capture=1 }
    capture { print }
  ' "$1"
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

gbrain_put_dream() {
  [[ "${HERMES_DREAMING_GBRAIN_WRITEBACK:-${HERMES_GBRAIN_WRITEBACK:-}}" == "1" ]] || return 0
  local report_file="$1" slug="$2" bin
  bin="$(resolve_gbrain_bin)"
  [[ -n "${bin}" ]] || { log "dreaming gbrain write-back skipped; gbrain not found"; return 0; }

  {
    printf -- '---\n'
    printf 'type: "dreaming"\n'
    printf 'slug: "%s"\n' "${slug}"
    printf 'created_at: "%s"\n' "${now}"
    printf -- '---\n\n'
    cat "${report_file}"
  } | "${bin}" put "${slug}" >>"${LOG_FILE}" 2>&1 \
    && log "dreaming gbrain write-back ok: ${slug}" \
    || log "dreaming gbrain write-back failed: ${slug}; continuing"
}

if [[ ! -x "${HERMES_BIN}" ]]; then
  log "missing hermes binary: ${HERMES_BIN}"
  exit 1
fi

if [[ ! -f "${PROMPT_FILE}" ]]; then
  log "missing dreaming prompt: ${PROMPT_FILE}"
  exit 1
fi

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  if [[ -f "${LOCK_PID}" ]]; then
    previous_pid="$(<"${LOCK_PID}")"
    if [[ "${previous_pid}" =~ ^[0-9]+$ ]] && kill -0 "${previous_pid}" 2>/dev/null; then
      log "previous dreaming still running pid=${previous_pid}; skipping"
      exit 0
    fi
  fi

  log "removing stale dreaming lock"
  rm -rf "${LOCK_DIR}"
  mkdir "${LOCK_DIR}"
fi
printf '%s\n' "$$" > "${LOCK_PID}"
trap 'rm -rf "${LOCK_DIR}" 2>/dev/null || true' EXIT

now="$(date '+%Y-%m-%d %H:%M:%S %z')"
timestamp="$(date '+%Y%m%d-%H%M%S')"
report_file="${DREAMING_DIR}/${timestamp}.md"
memory_tmp="${DREAMING_DIR}/.${timestamp}.memory.md"

prompt="$(cat <<PROMPT
$(read_optional_file "${PROMPT_FILE}" 260)

# Current time

${now}

# Stable identity

$(read_optional_file "${IDENTITY_FILE}" 220)

# Current working memory view

$(read_optional_file "${MEMORY_FILE}" 280)

# Built-in Hermes memory snapshot

## MEMORY.md

$(read_optional_file "${HERMES_MEMORY_DIR}/MEMORY.md" 120)

## USER.md

$(read_optional_file "${HERMES_MEMORY_DIR}/USER.md" 120)

# Recent conversation excerpts

$(recent_session_context)

# Recent digests

$(latest_files_content "${DIGEST_DIR}" "${RECENT_DIGEST_LIMIT}" 120)

# Recent self-evaluations

$(latest_files_content "${EVAL_DIR}" "${RECENT_EVAL_LIMIT}" 180)

# Recent explicit feedback and follow-ups

$(latest_files_content "${FEEDBACK_DIR}" "${RECENT_FEEDBACK_LIMIT}" 160)

# Recent weekly reflections

$(latest_files_content "${WEEKLY_DIR}" "${RECENT_WEEKLY_LIMIT}" 220)
PROMPT
)"

log "starting nightly dreaming recomposition"
if dreaming_output="$("${HERMES_BIN}" -z "${prompt}" 2>>"${LOG_FILE}")"; then
  if [[ -z "${dreaming_output//[[:space:]]/}" ]]; then
    log "dreaming returned empty output"
    exit 1
  fi

  printf '%s\n' "${dreaming_output}" > "${report_file}"
  extract_recomposed_memory "${report_file}" > "${memory_tmp}"

  if [[ ! -s "${memory_tmp}" ]] || ! grep -q '^# ヘルメスちゃんの自己メモリ' "${memory_tmp}"; then
    log "dreaming output did not contain recomposed memory section: ${report_file}"
    rm -f "${memory_tmp}"
    exit 1
  fi

  install -m 600 "${memory_tmp}" "${MEMORY_FILE}"
  rm -f "${memory_tmp}"
  log "updated working memory from dreaming: ${MEMORY_FILE}"
  gbrain_put_dream "${report_file}" "dreaming-${timestamp}"

  printf 'nightly dreaming updated memory: %s\nreport: %s\nupdated_at: %s\n' \
    "${MEMORY_FILE}" "${report_file}" "${now}"
else
  code=$?
  log "nightly dreaming failed exit=${code}"
  exit "${code}"
fi
