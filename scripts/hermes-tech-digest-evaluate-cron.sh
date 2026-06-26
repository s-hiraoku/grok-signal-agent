#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.bun/bin:${PATH}"

HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
PROMPT_DIR="${HERMES_PROMPT_DIR:-${HOME}/.hermes/prompts}"
STATE_DIR="${HERMES_STATE_DIR:-${HOME}/.hermes/state}"
LOG_DIR="${HERMES_LOG_DIR:-${HOME}/.hermes/logs}"
LOG_FILE="${LOG_DIR}/hermes-tech-digest-evaluate-cron.log"
EVALUATION_PROMPT_FILE="${HERMES_EVALUATION_PROMPT_FILE:-${PROMPT_DIR}/evaluate-digest.md}"
MEMORY_FILE="${HERMES_CHAN_MEMORY_FILE:-${STATE_DIR}/hermes-chan-memory.md}"
DIGEST_DIR="${STATE_DIR}/digests"
EVAL_DIR="${STATE_DIR}/evaluations"
GBRAIN_BRAIN="${GBRAIN_BRAIN:-${HOME}/.hermes/brain}"
ALERT_SCRIPT="${HERMES_ALERT_SCRIPT:-${HOME}/.hermes/bin/hermes-alert.sh}"

mkdir -p "${LOG_DIR}" "${EVAL_DIR}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}"
}

read_optional_file() {
  local file="$1" limit="${2:-260}"
  [[ -f "${file}" ]] && sed -n "1,${limit}p" "${file}"
}

send_alert() {
  local title="$1" body="$2"
  if [[ -x "${ALERT_SCRIPT}" ]]; then
    printf '%s\n' "${body}" | "${ALERT_SCRIPT}" "${title}" || true
  else
    log "alert skipped (${title}): ${body}"
  fi
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

extract_total_score() {
  awk -F ':' '
    /^[[:space:]]*-[[:space:]]*総合:/ {
      gsub(/[^0-9.]/, "", $2)
      print $2
      exit
    }
  ' "$1" 2>/dev/null || true
}

latest_digest_file() {
  if [[ -n "${HERMES_TECH_DIGEST_EVAL_DIGEST_FILE:-}" ]]; then
    printf '%s\n' "${HERMES_TECH_DIGEST_EVAL_DIGEST_FILE}"
    return 0
  fi
  find "${DIGEST_DIR}" -maxdepth 1 -type f -name '*.md' -print 2>/dev/null \
    | sort -r \
    | sed -n '1p'
}

digest_body() {
  awk '
    NR == 1 && $0 == "---" { frontmatter = 1; next }
    frontmatter && $0 == "---" { frontmatter = 0; next }
    !frontmatter { print }
  ' "$1"
}

[[ -x "${HERMES_BIN}" ]] || { log "missing Hermes binary: ${HERMES_BIN}"; exit 0; }
[[ -f "${EVALUATION_PROMPT_FILE}" ]] || { log "missing evaluation prompt: ${EVALUATION_PROMPT_FILE}"; exit 0; }

digest_file="$(latest_digest_file)"
[[ -n "${digest_file}" && -f "${digest_file}" ]] || { log "no digest file found"; exit 0; }

timestamp="$(basename "${digest_file}" .md)"
eval_file="${EVAL_DIR}/${timestamp}.md"
now="$(date '+%Y-%m-%d %H:%M:%S %z')"

if [[ -f "${eval_file}" && "${HERMES_TECH_DIGEST_EVAL_FORCE:-0}" != "1" ]]; then
  log "evaluation already exists for ${digest_file}; skipping"
  exit 0
fi

curation="$(digest_body "${digest_file}")"
[[ -n "${curation//[[:space:]]/}" ]] || { log "digest body is empty: ${digest_file}"; exit 0; }

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
else
  log "self-evaluation failed for ${digest_file}; continuing silently"
  send_alert "Hermes digest self-evaluation failed" "Digest: ${digest_file}"
  exit 0
fi

total_score="$(extract_total_score "${eval_file}")"
if [[ -n "${total_score}" ]] && awk "BEGIN { exit !(${total_score} < 3) }"; then
  send_alert "Hermes digest self-evaluation is low" "Evaluation: ${eval_file}
Total score: ${total_score}
Digest: ${digest_file}"
fi

digest_tmp="${DIGEST_DIR}/.${timestamp}.writeback.md"
printf '%s\n' "${curation}" > "${digest_tmp}"
gbrain_writeback "digest-${timestamp}" "digest" "${digest_tmp}" "${now}"
rm -f "${digest_tmp}"

eval_tmp="${EVAL_DIR}/.${timestamp}.writeback.md"
printf '%s\n' "${evaluation}" > "${eval_tmp}"
gbrain_writeback "evaluation-${timestamp}" "evaluation" "${eval_tmp}" "${now}"
rm -f "${eval_tmp}"
