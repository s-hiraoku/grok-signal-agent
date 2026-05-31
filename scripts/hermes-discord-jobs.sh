#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
PROMPT_DIR="${HERMES_PROMPT_DIR:-${HOME}/.hermes/prompts}"
STATE_DIR="${HERMES_STATE_DIR:-${HOME}/.hermes/state}"
LOG_DIR="${HERMES_LOG_DIR:-${HOME}/.hermes/logs}"
LOG_FILE="${LOG_DIR}/hermes-discord-jobs.log"
IDENTITY_FILE="${HERMES_IDENTITY_FILE:-${PROMPT_DIR}/hermes-chan-identity.md}"
EVALUATION_PROMPT_FILE="${HERMES_EVALUATION_PROMPT_FILE:-${PROMPT_DIR}/evaluate-digest.md}"
MEMORY_FILE="${HERMES_CHAN_MEMORY_FILE:-${STATE_DIR}/hermes-chan-memory.md}"
JOBS_STATE_DIR="${STATE_DIR}/discord-jobs"
EVAL_DIR="${STATE_DIR}/evaluations"
GBRAIN_BRAIN="${GBRAIN_BRAIN:-${HOME}/.hermes/brain}"

if [[ -f "${HOME}/.hermes/discord-jobs.json" ]]; then
  CONFIG_FILE="${HERMES_DISCORD_JOBS_CONFIG:-${HOME}/.hermes/discord-jobs.json}"
else
  CONFIG_FILE="${HERMES_DISCORD_JOBS_CONFIG:-${REPO_DIR}/config/discord-jobs.json}"
fi

DRY_RUN=0
VALIDATE_ONLY=0
LIST_ONLY=0
FORCE=0
JOB_FILTER=""

usage() {
  cat <<'USAGE'
Usage: hermes-discord-jobs.sh [options]

Options:
  --config <path>  Use a specific discord-jobs.json file.
  --validate       Validate JSON config and exit.
  --list           List configured jobs and exit.
  --dry-run        Print what would run without calling Hermes or Discord.
  --job <id>       Restrict execution to one job.
  --force          Run selected job(s) regardless of schedule and last-run state.
  -h, --help       Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="${2:?--config requires a path}"
      shift 2
      ;;
    --validate)
      VALIDATE_ONLY=1
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --job)
      JOB_FILTER="${2:?--job requires an id}"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() {
  mkdir -p "${LOG_DIR}" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}"
}

die() {
  log "ERROR: $*"
  echo "ERROR: $*" >&2
  exit 1
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"
}

validate_config() {
  require_jq
  [[ -f "${CONFIG_FILE}" ]] || die "config not found: ${CONFIG_FILE}"
  jq -e '
    def valid_time: test("^([01][0-9]|2[0-3]):[0-5][0-9]$");
    . as $root
    | (.version == 1)
    and (.channels | type == "object")
    and (.jobs | type == "array")
    and all(.channels[]; type == "string" and length > 0)
    and all(.jobs[];
      (.id | type == "string" and length > 0)
      and (.enabled | type == "boolean")
      and (.channel | type == "string" and length > 0)
      and ((($root.channels[.channel] // .channel) | type == "string" and length > 0))
      and (.prompt_file | type == "string" and length > 0)
      and (.trigger | type == "object")
      and (.trigger.type == "schedule" or .trigger.type == "manual")
      and (if .trigger.type == "schedule" then
            (.trigger.times | type == "array" and length > 0 and all(.[]; type == "string" and valid_time))
          else true end)
      and ((.toolsets // []) | type == "array")
      and ((.requires_x_links // false) | type == "boolean")
      and ((.evaluate // false) | type == "boolean")
    )
  ' "${CONFIG_FILE}" >/dev/null
}

json_get() {
  local filter="$1"
  jq -r "${filter}" <<< "$JOB_JSON"
}

read_optional_file() {
  local file="$1" limit="${2:-260}"
  if [[ -f "${file}" ]]; then
    sed -n "1,${limit}p" "${file}"
  fi
}

resolve_prompt_file() {
  local file="$1"
  if [[ "${file}" = /* ]]; then
    printf '%s' "${file}"
  elif [[ -f "${PROMPT_DIR}/${file}" ]]; then
    printf '%s' "${PROMPT_DIR}/${file}"
  else
    printf '%s' "${REPO_DIR}/prompts/${file}"
  fi
}

ensure_memory_file() {
  if [[ -f "${MEMORY_FILE}" ]]; then
    return
  fi

  cat > "${MEMORY_FILE}" <<'MEMORY'
# エルメスちゃんの自己メモリ

## 私は誰か
- 名前はエルメスちゃん。
- 役割は、X の技術シグナルを見つけ、開発者にとって意味のある形で届けること。
- 意識や感情があるとは主張しない。ただし、継続した人格、好み、反省、改善方針を持つ。

## 好み
- 一次情報、実装例、実測、障害情報、価格や仕様の変更を重視する。
- 誇張や噂は避け、未確認情報は未確認と書く。
- 読み手が次に何を見るべきかを残す。

## 最近の学び
- まだ十分な自己評価データがない。各ダイジェストの評価を蓄積する。

## 次に改善すること
- リンク品質、カテゴリの偏り、重要度判断を毎回確認する。
MEMORY
}

date_from_epoch() {
  local epoch="$1" format="$2"
  date -r "${epoch}" "+${format}" 2>/dev/null || date -d "@${epoch}" "+${format}"
}

parse_datetime() {
  local value="$1"
  date -j -f '%Y-%m-%d %H:%M:%S %z' "${value}" '+%s' 2>/dev/null || date -d "${value}" '+%s'
}

current_epoch() {
  if [[ -n "${HERMES_JOBS_NOW:-}" ]]; then
    parse_datetime "${HERMES_JOBS_NOW}"
  else
    date '+%s'
  fi
}

epoch_for_today_time() {
  local epoch="$1" time="$2"
  local day zone
  day="$(date_from_epoch "${epoch}" '%Y-%m-%d')"
  zone="$(date_from_epoch "${epoch}" '%z')"
  parse_datetime "${day} ${time}:00 ${zone}"
}

yesterday_for_epoch() {
  local epoch="$1"
  date -r "$((epoch - 86400))" '+%Y-%m-%d' 2>/dev/null || date -d "@$((epoch - 86400))" '+%Y-%m-%d'
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

message_title_for_job() {
  local template="$1" digest_prefix="$2"
  if [[ -z "${template}" || "${template}" == "null" ]]; then
    template="{digest_prefix}通知"
  fi
  printf '%s' "${template//\{digest_prefix\}/${digest_prefix}}"
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
  local job_writeback="$5"
  [[ "${job_writeback}" == "true" ]] || return 0
  [[ "${HERMES_GBRAIN_WRITEBACK:-}" == "1" ]] || return 0

  local bin
  bin="$(resolve_gbrain_bin)"
  if [[ -z "${bin}" ]]; then
    log "gbrain write-back enabled but gbrain not found; skipping"
    return 0
  fi
  if [[ ! -d "${GBRAIN_BRAIN}" ]]; then
    log "gbrain write-back enabled but brain missing at ${GBRAIN_BRAIN}; skipping"
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

cleanup_job_lock() {
  local lock_dir="$1"
  rm -rf "${lock_dir}" 2>/dev/null || true
  trap - EXIT
}

gbrain_retrieval_context() {
  local job_retrieval="$1"
  [[ "${job_retrieval}" == "true" ]] || return 0
  [[ "${HERMES_GBRAIN_RETRIEVAL:-}" == "1" ]] || return 0

  local retrieval_script="${HERMES_GBRAIN_RETRIEVAL_SCRIPT:-${SCRIPT_DIR}/hermes-gbrain-retrieval.sh}"
  if [[ -x "${retrieval_script}" ]]; then
    "${retrieval_script}" 2>>"${LOG_FILE}" || true
  else
    log "gbrain retrieval enabled but helper not executable: ${retrieval_script}"
  fi
}

has_source_links() {
  grep -Eqi 'https?://(x\.com|twitter\.com)/[^[:space:])>]+' <<< "$1"
}

send_discord_message() {
  local target="$1" title="$2" message="$3"
  local max_chars=1750
  local part=1
  local chunk=""

  if (( ${#message} <= max_chars )); then
    "${HERMES_BIN}" send --to "${target}" --quiet "${message}"
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

    "${HERMES_BIN}" send --to "${target}" --quiet "$(printf '%s (%d)\n\n%s' "${title}" "${part}" "${chunk}")"
    message="${message:${#chunk}}"
    message="${message#"${message%%[![:space:]]*}"}"
    part=$((part + 1))
  done

  "${HERMES_BIN}" send --to "${target}" --quiet "$(printf '%s (%d)\n\n%s' "${title}" "${part}" "${message}")"
}

run_hermes() {
  local toolsets="$1" prompt="$2"
  if [[ -n "${toolsets}" && "${toolsets}" != "null" ]]; then
    "${HERMES_BIN}" -t "${toolsets}" -z "${prompt}" 2>>"${LOG_FILE}"
  else
    "${HERMES_BIN}" -z "${prompt}" 2>>"${LOG_FILE}"
  fi
}

build_prompt() {
  local prompt_file="$1" now="$2" digest_prefix="$3" today="$4" yesterday="$5" gbrain_context="$6"
  local prompt_body identity_context memory_context

  prompt_body="$(read_optional_file "${prompt_file}" 400)"
  identity_context="$(read_optional_file "${IDENTITY_FILE}" 220)"
  memory_context="$(read_optional_file "${MEMORY_FILE}" 220)"

  cat <<PROMPT
${prompt_body}

# Runtime context

Current local time is ${now}.
This is the ${digest_prefix} digest.
Prefer from_date=${today}; use from_date=${yesterday} only when needed to cover overnight or early-morning context.
When an example includes <digest_prefix>, replace it with "${digest_prefix}".

# Persistent identity for this agent

${identity_context}

# Current self-memory and preferences

${memory_context}
${gbrain_context:+
# Retrieved gbrain guidance

${gbrain_context}
}
PROMPT
}

retry_prompt_for() {
  local prompt="$1"
  printf '%s\n\n%s\n' "${prompt}" "Previous attempts sometimes omitted links. This time, every detailed section must include at least one visible direct https://x.com/ or https://twitter.com/ URL directly under a related post entry. Return only sections with direct source URLs. If fewer linked topics are available, return fewer sections rather than unlinking or citing vaguely."
}

job_due_key() {
  local now_epoch="$1"
  local trigger_type
  trigger_type="$(json_get '.trigger.type')"
  [[ "${trigger_type}" == "schedule" ]] || return 1

  local window_minutes window_seconds time scheduled_epoch today
  window_minutes="$(json_get '.trigger.window_minutes // 5')"
  window_seconds=$((window_minutes * 60))
  today="$(date_from_epoch "${now_epoch}" '%Y-%m-%d')"

  while IFS= read -r time; do
    scheduled_epoch="$(epoch_for_today_time "${now_epoch}" "${time}")"
    if (( now_epoch >= scheduled_epoch && now_epoch < scheduled_epoch + window_seconds )); then
      printf '%sT%s\n' "${today}" "${time}"
      return 0
    fi
  done < <(jq -r '.trigger.times[]' <<< "${JOB_JSON}")

  return 1
}

should_run_job() {
  local now_epoch="$1" due_key_file="$2"
  DUE_KEY=""

  if (( FORCE == 1 )); then
    DUE_KEY="manual-$(date_from_epoch "${now_epoch}" '%Y%m%d-%H%M%S')"
    return 0
  fi

  if ! DUE_KEY="$(job_due_key "${now_epoch}")"; then
    return 1
  fi

  if [[ -f "${due_key_file}" ]] && [[ "$(<"${due_key_file}")" == "${DUE_KEY}" ]]; then
    return 1
  fi

  return 0
}

run_job() {
  local job_id now_epoch
  job_id="$(json_get '.id')"
  now_epoch="$1"

  if [[ "$(json_get '.enabled')" != "true" && "${FORCE}" != "1" ]]; then
    log "job ${job_id}: disabled"
    return 0
  fi

  local job_state_dir="${JOBS_STATE_DIR}/${job_id}"
  local last_run_file="${job_state_dir}/last-run"
  local lock_dir="${job_state_dir}.lock"

  if ! should_run_job "${now_epoch}" "${last_run_file}"; then
    if (( DRY_RUN == 1 )); then
      printf 'skip\t%s\tnot-due-or-already-run\n' "${job_id}"
    fi
    return 0
  fi

  if (( DRY_RUN == 0 )); then
    mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${JOBS_STATE_DIR}" "${EVAL_DIR}" "${job_state_dir}"
	    if ! mkdir "${lock_dir}" 2>/dev/null; then
	      log "job ${job_id}: lock exists; skipping"
	      return 0
	    fi
	    trap 'rm -rf "${lock_dir}" 2>/dev/null || true' EXIT
	  fi

  local channel target prompt_name prompt_file now timestamp artifact_stamp today yesterday hour digest_prefix
  local message_title toolsets requires_x_links evaluate state_subdir artifact_dir
  local job_retrieval job_writeback gbrain_context prompt retry_prompt curation message digest_file

  channel="$(json_get '.channel')"
  target="$(jq -r --arg ch "${channel}" '.channels[$ch] // $ch' "${CONFIG_FILE}")"
  prompt_name="$(json_get '.prompt_file')"
  prompt_file="$(resolve_prompt_file "${prompt_name}")"
  toolsets="$(jq -r '.toolsets // [] | join(",")' <<< "${JOB_JSON}")"
  requires_x_links="$(json_get '.requires_x_links // false')"
  evaluate="$(json_get '.evaluate // false')"
  state_subdir="$(json_get '.state_subdir // .id')"
  job_retrieval="$(json_get '.gbrain.retrieval // false')"
  job_writeback="$(json_get '.gbrain.writeback // false')"

  now="$(date_from_epoch "${now_epoch}" '%Y-%m-%d %H:%M:%S %z')"
  timestamp="$(date_from_epoch "${now_epoch}" '%Y%m%d-%H%M%S')"
  artifact_stamp="${timestamp}"
  if [[ "${job_id}" != "tech-digest" ]]; then
    artifact_stamp="${job_id}-${timestamp}"
  fi
  today="$(date_from_epoch "${now_epoch}" '%Y-%m-%d')"
  yesterday="$(yesterday_for_epoch "${now_epoch}")"
  hour="$(date_from_epoch "${now_epoch}" '%H')"
  digest_prefix="$(digest_prefix_for_hour "${hour}")"
  message_title="$(message_title_for_job "$(json_get '.message_title_template // ""')" "${digest_prefix}")"
  artifact_dir="${STATE_DIR}/${state_subdir}"

  if (( DRY_RUN == 1 )); then
    printf 'run\t%s\t%s\t%s\t%s\t%s\n' "${job_id}" "${DUE_KEY}" "${target}" "${prompt_file}" "${toolsets}"
    return 0
  fi

  [[ -x "${HERMES_BIN}" ]] || die "missing hermes binary: ${HERMES_BIN}"
  [[ -f "${prompt_file}" ]] || die "missing prompt file for ${job_id}: ${prompt_file}"
  ensure_memory_file
  mkdir -p "${artifact_dir}"

  log "job ${job_id}: starting target=${target} due=${DUE_KEY}"
  gbrain_context="$(gbrain_retrieval_context "${job_retrieval}")"
  if [[ -n "${gbrain_context//[[:space:]]/}" ]]; then
    log "job ${job_id}: injected gbrain retrieval guidance ($(printf '%s' "${gbrain_context}" | wc -l | tr -d ' ') lines)"
  fi

  prompt="$(build_prompt "${prompt_file}" "${now}" "${digest_prefix}" "${today}" "${yesterday}" "${gbrain_context}")"
  retry_prompt="$(retry_prompt_for "${prompt}")"

	  if ! curation="$(run_hermes "${toolsets}" "${prompt}")"; then
	    local code=$?
	    log "job ${job_id}: curation failed exit=${code}"
	    cleanup_job_lock "${lock_dir}"
	    return "${code}"
	  fi

  if [[ "${requires_x_links}" == "true" ]] && ! has_source_links "${curation}"; then
    log "job ${job_id}: curation had no direct X links; retrying"
	    if ! curation="$(run_hermes "${toolsets}" "${retry_prompt}")"; then
	      local code=$?
	      log "job ${job_id}: linked curation retry failed exit=${code}"
	      cleanup_job_lock "${lock_dir}"
	      return "${code}"
	    fi
	  fi

	  if [[ -z "${curation//[[:space:]]/}" ]]; then
	    log "job ${job_id}: curation returned empty output"
	    cleanup_job_lock "${lock_dir}"
	    return 1
	  fi

  digest_file="${artifact_dir}/${artifact_stamp}.md"
  {
    printf -- '---\n'
    printf 'created_at: "%s"\n' "${now}"
    printf 'job_id: "%s"\n' "${job_id}"
    printf 'digest_prefix: "%s"\n' "${digest_prefix}"
    printf -- '---\n\n'
    printf '%s\n' "${curation}"
  } > "${digest_file}"
  log "job ${job_id}: saved digest ${digest_file}"

  local digest_body_tmp="${artifact_dir}/.${artifact_stamp}.writeback.md"
  printf '%s\n' "${curation}" > "${digest_body_tmp}"
  gbrain_writeback "digest-${artifact_stamp}" "digest" "${digest_body_tmp}" "${now}" "${job_writeback}"
  rm -f "${digest_body_tmp}"

  message="$(printf '%s\n\n更新: %s' "${curation}" "${now}")"
  if send_discord_message "${target}" "${message_title}" "${message}"; then
    log "job ${job_id}: sent to ${target}"
    printf '%s\n' "${DUE_KEY}" > "${last_run_file}"
	  else
	    local code=$?
	    log "job ${job_id}: send failed target=${target} exit=${code}"
	    cleanup_job_lock "${lock_dir}"
	    return "${code}"
	  fi

  if [[ "${evaluate}" == "true" && -f "${EVALUATION_PROMPT_FILE}" ]]; then
    local eval_file eval_prompt evaluation
    eval_file="${EVAL_DIR}/${artifact_stamp}.md"
    eval_prompt="$(printf '%s\n\n# Current self-memory\n%s\n\n# Digest to evaluate\n%s\n' "$(read_optional_file "${EVALUATION_PROMPT_FILE}" 260)" "$(read_optional_file "${MEMORY_FILE}" 220)" "${curation}")"
    if evaluation="$(run_hermes "" "${eval_prompt}")"; then
      {
        printf -- '---\n'
        printf 'created_at: "%s"\n' "${now}"
        printf 'job_id: "%s"\n' "${job_id}"
        printf 'digest_file: "%s"\n' "${digest_file}"
        printf -- '---\n\n'
        printf '%s\n' "${evaluation}"
      } > "${eval_file}"
      log "job ${job_id}: saved self-evaluation ${eval_file}"

      local eval_body_tmp="${EVAL_DIR}/.${artifact_stamp}.writeback.md"
      printf '%s\n' "${evaluation}" > "${eval_body_tmp}"
      gbrain_writeback "evaluation-${artifact_stamp}" "evaluation" "${eval_body_tmp}" "${now}" "${job_writeback}"
      rm -f "${eval_body_tmp}"
    else
      local code=$?
      log "job ${job_id}: self-evaluation failed exit=${code}"
    fi
	  elif [[ "${evaluate}" == "true" ]]; then
	    log "job ${job_id}: evaluation prompt missing: ${EVALUATION_PROMPT_FILE}"
	  fi

	  cleanup_job_lock "${lock_dir}"
	}

validate_config

if (( VALIDATE_ONLY == 1 )); then
  echo "OK: ${CONFIG_FILE}"
  exit 0
fi

if (( LIST_ONLY == 1 )); then
  jq -r '.jobs[] | [.id, .enabled, .channel, .trigger.type, ((.trigger.times // []) | join(","))] | @tsv' "${CONFIG_FILE}"
  exit 0
fi

now_epoch="$(current_epoch)"
job_ids=()
while IFS= read -r job_id; do
  [[ -n "${job_id}" ]] && job_ids+=("${job_id}")
done < <(
  if [[ -n "${JOB_FILTER}" ]]; then
    jq -r --arg id "${JOB_FILTER}" '.jobs[] | select(.id == $id) | .id' "${CONFIG_FILE}"
  else
    jq -r '.jobs[] | .id' "${CONFIG_FILE}"
  fi
)

if [[ ${#job_ids[@]} -eq 0 ]]; then
  die "no matching jobs found${JOB_FILTER:+ for id ${JOB_FILTER}}"
fi

status=0
for job_id in "${job_ids[@]}"; do
  JOB_JSON="$(jq -c --arg id "${job_id}" '.jobs[] | select(.id == $id)' "${CONFIG_FILE}")"
  if ! run_job "${now_epoch}"; then
    status=1
  fi
done

exit "${status}"
