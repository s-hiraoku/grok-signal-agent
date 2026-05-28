#!/usr/bin/env bash
set -euo pipefail

HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
PROMPT_DIR="${HERMES_PROMPT_DIR:-${HOME}/.hermes/prompts}"
STATE_DIR="${HOME}/.hermes/state"
LOG_DIR="${HOME}/.hermes/logs"
MEMORY_FILE="${HERMES_CHAN_MEMORY_FILE:-${STATE_DIR}/hermes-chan-memory.md}"
REFLECTION_PROMPT_FILE="${PROMPT_DIR}/weekly-self-reflection.md"
IDENTITY_FILE="${PROMPT_DIR}/hermes-chan-identity.md"
EVAL_DIR="${STATE_DIR}/evaluations"
REPORT_DIR="${STATE_DIR}/weekly-reflections"
LOG_FILE="${LOG_DIR}/hermes-weekly-self-reflection.log"
LOCK_DIR="${STATE_DIR}/hermes-weekly-self-reflection.lock"
LOCK_PID="${LOCK_DIR}/pid"

mkdir -p "${STATE_DIR}" "${LOG_DIR}" "${EVAL_DIR}" "${REPORT_DIR}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}"
}

read_optional_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    sed -n '1,260p' "${file}"
  fi
}

latest_files_content() {
  local dir="$1"
  local limit="$2"

  if ! find "${dir}" -type f -name '*.md' -print -quit | grep -q .; then
    return
  fi

  find "${dir}" -type f -name '*.md' -print0 \
    | xargs -0 ls -t \
    | sed -n "1,${limit}p" \
    | while IFS= read -r file; do
        printf '\n\n## %s\n\n' "${file}"
        sed -n '1,220p' "${file}"
      done
}

if [[ ! -x "${HERMES_BIN}" ]]; then
  log "missing hermes binary: ${HERMES_BIN}"
  exit 1
fi

if [[ ! -f "${REFLECTION_PROMPT_FILE}" ]]; then
  log "missing reflection prompt: ${REFLECTION_PROMPT_FILE}"
  exit 1
fi

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  if [[ -f "${LOCK_PID}" ]]; then
    previous_pid="$(<"${LOCK_PID}")"
    if [[ "${previous_pid}" =~ ^[0-9]+$ ]] && kill -0 "${previous_pid}" 2>/dev/null; then
      log "previous weekly reflection still running pid=${previous_pid}; skipping"
      exit 0
    fi
  fi

  log "removing stale weekly reflection lock"
  rm -rf "${LOCK_DIR}"
  mkdir "${LOCK_DIR}"
fi
printf '%s\n' "$$" > "${LOCK_PID}"
trap 'rm -rf "${LOCK_DIR}" 2>/dev/null || true' EXIT

now="$(date '+%Y-%m-%d %H:%M:%S %z')"
timestamp="$(date '+%Y%m%d-%H%M%S')"
current_memory="$(read_optional_file "${MEMORY_FILE}")"
identity_context="$(read_optional_file "${IDENTITY_FILE}")"
evaluation_context="$(latest_files_content "${EVAL_DIR}" 21)"

if [[ -z "${evaluation_context//[[:space:]]/}" ]]; then
  log "no evaluation logs found; skipping weekly reflection"
  exit 0
fi

prompt="$(printf '%s\n\n# Current time\n%s\n\n# Identity\n%s\n\n# Current memory\n%s\n\n# Recent self-evaluations\n%s\n' \
  "$(read_optional_file "${REFLECTION_PROMPT_FILE}")" \
  "${now}" \
  "${identity_context}" \
  "${current_memory}" \
  "${evaluation_context}")"

log "starting weekly self-reflection"
if updated_memory="$("${HERMES_BIN}" -z "${prompt}" 2>>"${LOG_FILE}")"; then
  if [[ -z "${updated_memory//[[:space:]]/}" ]]; then
    log "weekly reflection returned empty output"
    exit 1
  fi

  report_file="${REPORT_DIR}/${timestamp}.md"
  printf '%s\n' "${updated_memory}" > "${report_file}"
  install -m 600 "${report_file}" "${MEMORY_FILE}"
  log "updated memory from weekly reflection: ${MEMORY_FILE}"
else
  code=$?
  log "weekly self-reflection failed exit=${code}"
  exit "${code}"
fi
