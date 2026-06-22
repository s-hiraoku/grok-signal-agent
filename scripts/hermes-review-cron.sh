#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.bun/bin:${PATH}"

HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
PROMPT_DIR="${HERMES_PROMPT_DIR:-${HOME}/.hermes/prompts}"
STATE_DIR="${HERMES_STATE_DIR:-${HOME}/.hermes/state}"
LOG_DIR="${HERMES_LOG_DIR:-${HOME}/.hermes/logs}"
IDENTITY_FILE="${HERMES_IDENTITY_FILE:-${PROMPT_DIR}/hermes-chan-identity.md}"
POST_STYLE_FILE="${HERMES_POST_STYLE_FILE:-${PROMPT_DIR}/hermes-post-style.md}"
MEMORY_FILE="${HERMES_CHAN_MEMORY_FILE:-${STATE_DIR}/hermes-chan-memory.md}"
BRAIN_DIR="${GBRAIN_BRAIN:-${HOME}/.hermes/brain}"
HONCHO_CONFIG_LOCAL="${HERMES_HOME:-${HOME}/.hermes}/honcho.json"
HONCHO_CONFIG_GLOBAL="${HOME}/.honcho/config.json"
MODE="daily"

if [[ "${1:-}" == "--weekly" ]]; then
  MODE="weekly"
elif [[ "${1:-}" == "--daily" || -z "${1:-}" ]]; then
  MODE="daily"
else
  echo "usage: hermes-review-cron.sh [--daily|--weekly]" >&2
  exit 2
fi

REVIEW_DIR="${STATE_DIR}/reviews/${MODE}"
LOG_FILE="${LOG_DIR}/hermes-${MODE}-review.log"
LOCK_DIR="${STATE_DIR}/hermes-${MODE}-review.lock"
LOCK_PID="${LOCK_DIR}/pid"

mkdir -p "${STATE_DIR}" "${LOG_DIR}" "${REVIEW_DIR}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}"
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

read_optional_file() {
  local file="$1" limit="${2:-120}"
  [[ -f "${file}" ]] && sed -n "1,${limit}p" "${file}"
}

latest_files_content() {
  local dir="$1" limit="$2" line_limit="${3:-80}"
  [[ -d "${dir}" ]] || return 0
  if ! find "${dir}" -type f -name '*.md' -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi

  find "${dir}" -type f -name '*.md' -print0 \
    | xargs -0 ls -t \
    | sed -n "1,${limit}p" \
    | while IFS= read -r file; do
        printf '\n\n## %s\n\n' "${file}"
        sed -n "1,${line_limit}p" "${file}"
      done
}

tail_optional_file() {
  local file="$1" limit="${2:-60}"
  [[ -f "${file}" ]] && tail -n "${limit}" "${file}"
}

gbrain_status() {
  local bin
  bin="$(resolve_gbrain_bin)"
  if [[ -z "${bin}" ]]; then
    printf 'gbrain binary: not found\n'
    return 0
  fi

  printf 'gbrain binary: %s\n' "${bin}"
  printf 'gbrain brain dir: %s (%s)\n' "${BRAIN_DIR}" "$([[ -d "${BRAIN_DIR}" ]] && printf present || printf missing)"
  if [[ -d "${BRAIN_DIR}" ]]; then
    (
      cd "${BRAIN_DIR}"
      printf '\n## gbrain list\n'
      "${bin}" list -n 30 2>&1 | sed -n '1,80p'
    ) || true
  fi
}

honcho_status() {
  local status_tmp
  status_tmp="$(mktemp -t hermes-honcho-status.XXXXXX)"
  printf 'honcho local config: %s (%s)\n' "${HONCHO_CONFIG_LOCAL}" "$([[ -f "${HONCHO_CONFIG_LOCAL}" ]] && printf present || printf missing)"
  printf 'honcho global config: %s (%s)\n' "${HONCHO_CONFIG_GLOBAL}" "$([[ -f "${HONCHO_CONFIG_GLOBAL}" ]] && printf present || printf missing)"
  if "${HERMES_BIN}" memory status >"${status_tmp}" 2>&1; then
    sed -E 's/(apiKey|HONCHO_API_KEY|Authorization)([^[:alnum:]_ -]*)([=: ]+).*/\1\2\3[redacted]/I' "${status_tmp}" | sed -n '1,140p'
  else
    sed -E 's/(apiKey|HONCHO_API_KEY|Authorization)([^[:alnum:]_ -]*)([=: ]+).*/\1\2\3[redacted]/I' "${status_tmp}" | sed -n '1,80p' || true
  fi
  rm -f "${status_tmp}"
}

if [[ ! -x "${HERMES_BIN}" ]]; then
  log "missing hermes binary: ${HERMES_BIN}"
  exit 1
fi

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  if [[ -f "${LOCK_PID}" ]]; then
    previous_pid="$(<"${LOCK_PID}")"
    if [[ "${previous_pid}" =~ ^[0-9]+$ ]] && kill -0 "${previous_pid}" 2>/dev/null; then
      log "previous ${MODE} review still running pid=${previous_pid}; skipping"
      exit 0
    fi
  fi
  rm -rf "${LOCK_DIR}"
  mkdir "${LOCK_DIR}"
fi
printf '%s\n' "$$" > "${LOCK_PID}"
trap 'rm -rf "${LOCK_DIR}" 2>/dev/null || true' EXIT

now="$(date '+%Y-%m-%d %H:%M:%S %z')"
timestamp="$(date '+%Y%m%d-%H%M%S')"
report_file="${REVIEW_DIR}/${timestamp}.md"

digest_limit=4
eval_limit=6
dreaming_limit=2
weekly_limit=2
if [[ "${MODE}" == "weekly" ]]; then
  digest_limit=12
  eval_limit=12
  dreaming_limit=7
  weekly_limit=4
fi

context="$(cat <<CONTEXT
# Current time
${now}

# Review mode
${MODE}

# gbrain status
$(gbrain_status)

# honcho status
$(honcho_status)

# Recent digests
$(latest_files_content "${STATE_DIR}/digests" "${digest_limit}" 80)

# Recent evaluations
$(latest_files_content "${STATE_DIR}/evaluations" "${eval_limit}" 120)

# Recent dreaming reports
$(latest_files_content "${STATE_DIR}/dreaming" "${dreaming_limit}" 100)

# Recent weekly reflections
$(latest_files_content "${STATE_DIR}/weekly-reflections" "${weekly_limit}" 140)

# Relevant logs

## hermes-dreaming.log
$(tail_optional_file "${LOG_DIR}/hermes-dreaming.log" 80)

## hermes-weekly-self-reflection.log
$(tail_optional_file "${LOG_DIR}/hermes-weekly-self-reflection.log" 80)

## hermes-tech-digest-cron.log
$(tail_optional_file "${LOG_DIR}/hermes-tech-digest-cron.log" 80)
CONTEXT
)"

if [[ "${MODE}" == "weekly" ]]; then
  instruction="weekly-review チャンネル向けに、この1週間の gbrain と honcho の更新情報・稼働状況を日本語で要約してください。構成は 1) gbrain の更新状況, 2) honcho の設定/稼働状況, 3) 今週蓄積された重要な学び, 4) 来週の運用TODO。honcho が未設定なら未設定とはっきり書いてください。"
else
  instruction="hermes-info チャンネル向けに、今日の gbrain と honcho の状態を日本語で短く要約してください。構成は 1) 今日の更新, 2) gbrain 状況, 3) honcho 状況, 4) 明日の確認ポイント。honcho が未設定なら未設定とはっきり書いてください。"
fi

prompt="$(cat <<PROMPT
${instruction}

ヘルメスちゃんらしく明るい口調で、ただし運用情報は実務的に正確にしてください。事実と推測を分け、ログにないことは断定しないでください。Discord で読みやすい長さにしてください。
無人格な運用レポートではなく、冒頭に短い一言を入れて、ヘルメスちゃんが状況を見て届けている投稿にしてください。

# Stable identity

$(read_optional_file "${IDENTITY_FILE}" 160)

# Posting style

$(read_optional_file "${POST_STYLE_FILE}" 180)

# Current self-memory

$(read_optional_file "${MEMORY_FILE}" 120)

${context}
PROMPT
)"

log "starting ${MODE} review"
if review="$("${HERMES_BIN}" -z "${prompt}" 2>>"${LOG_FILE}")"; then
  if [[ -z "${review//[[:space:]]/}" ]]; then
    log "${MODE} review returned empty output"
    exit 1
  fi
  printf '%s\n' "${review}" > "${report_file}"
  log "wrote ${MODE} review: ${report_file}"
  printf '%s\n' "${review}"
else
  code=$?
  log "${MODE} review failed exit=${code}; returning fallback"
  {
    printf '%s review fallback (%s)\n\n' "${MODE}" "${now}"
    printf 'Hermes review generation failed with exit=%s.\n\n' "${code}"
    printf '## gbrain status\n'
    gbrain_status
    printf '\n## honcho status\n'
    honcho_status
  } | tee "${report_file}"
  exit 0
fi
