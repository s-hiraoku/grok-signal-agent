#!/usr/bin/env bash
set -euo pipefail

HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
TARGET="${HERMES_DISCORD_HEARTBEAT_TARGET:-discord}"
PROMPT_DIR="${HERMES_PROMPT_DIR:-${HOME}/.hermes/prompts}"
STATE_DIR="${HOME}/.hermes/state"
LOG_DIR="${HOME}/.hermes/logs"
LOG_FILE="${LOG_DIR}/hermes-discord-heartbeat.log"
IDENTITY_FILE="${PROMPT_DIR}/hermes-chan-identity.md"
EVALUATION_PROMPT_FILE="${PROMPT_DIR}/evaluate-digest.md"
MEMORY_FILE="${HERMES_CHAN_MEMORY_FILE:-${STATE_DIR}/hermes-chan-memory.md}"
DIGEST_DIR="${STATE_DIR}/digests"
EVAL_DIR="${STATE_DIR}/evaluations"
LOCK_DIR="${STATE_DIR}/hermes-discord-heartbeat.lock"
LOCK_PID="${LOCK_DIR}/pid"

mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${DIGEST_DIR}" "${EVAL_DIR}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}"
}

run_curation() {
  local prompt="$1"
  "${HERMES_BIN}" -t x_search -z "${prompt}" 2>>"${LOG_FILE}"
}

run_reflection() {
  local prompt="$1"
  "${HERMES_BIN}" -z "${prompt}" 2>>"${LOG_FILE}"
}

read_optional_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    sed -n '1,220p' "${file}"
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

has_source_links() {
  grep -Eqi 'https?://(x\.com|twitter\.com)/[^[:space:])>]+' <<< "$1"
}

send_discord_message() {
  local message="$1"
  local max_chars=1750
  local part=1
  local chunk=""

  if (( ${#message} <= max_chars )); then
    "${HERMES_BIN}" send --to "${TARGET}" --quiet "${message}"
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

    "${HERMES_BIN}" send --to "${TARGET}" --quiet "$(printf '%s (%d)\n\n%s' "${message_title}" "${part}" "${chunk}")"
    message="${message:${#chunk}}"
    message="${message#"${message%%[![:space:]]*}"}"
    part=$((part + 1))
  done

  "${HERMES_BIN}" send --to "${TARGET}" --quiet "$(printf '%s (%d)\n\n%s' "${message_title}" "${part}" "${message}")"
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

if [[ ! -x "${HERMES_BIN}" ]]; then
  log "missing hermes binary: ${HERMES_BIN}"
  exit 1
fi

ensure_memory_file

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  if [[ -f "${LOCK_PID}" ]]; then
    previous_pid="$(<"${LOCK_PID}")"
    if [[ "${previous_pid}" =~ ^[0-9]+$ ]] && kill -0 "${previous_pid}" 2>/dev/null; then
      log "previous heartbeat still running pid=${previous_pid}; skipping"
      exit 0
    fi
  fi

  log "removing stale heartbeat lock"
  rm -rf "${LOCK_DIR}"
  mkdir "${LOCK_DIR}"
fi
printf '%s\n' "$$" > "${LOCK_PID}"
trap 'rm -rf "${LOCK_DIR}" 2>/dev/null || true' EXIT

now="$(date '+%Y-%m-%d %H:%M:%S %z')"
timestamp="$(date '+%Y%m%d-%H%M%S')"
today="$(date '+%Y-%m-%d')"
yesterday="$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d 'yesterday' '+%Y-%m-%d')"
digest_prefix="$(digest_prefix_for_hour "$(date '+%H')")"
message_title="${digest_prefix}気になる技術メモだよ"
identity_context="$(read_optional_file "${IDENTITY_FILE}")"
memory_context="$(read_optional_file "${MEMORY_FILE}")"

# Optional gbrain retrieval injection (Phase 2, see docs/self-growth.md).
# Off by default; set HERMES_GBRAIN_RETRIEVAL=1 to enable. The helper is
# defensive and prints nothing on any failure, so a non-empty result is the
# only thing that changes the prompt. With the flag unset, behaviour is
# identical to before.
gbrain_context=""
if [[ "${HERMES_GBRAIN_RETRIEVAL:-}" == "1" ]]; then
  retrieval_script="${HERMES_GBRAIN_RETRIEVAL_SCRIPT:-$(dirname "$0")/hermes-gbrain-retrieval.sh}"
  if [[ -x "${retrieval_script}" ]]; then
    if gbrain_context="$("${retrieval_script}" 2>>"${LOG_FILE}")"; then
      if [[ -n "${gbrain_context//[[:space:]]/}" ]]; then
        log "injected gbrain retrieval guidance ($(printf '%s' "${gbrain_context}" | wc -l | tr -d ' ') lines)"
      fi
    else
      log "gbrain retrieval helper failed; continuing without it"
      gbrain_context=""
    fi
  else
    log "gbrain retrieval enabled but helper not executable: ${retrieval_script}"
  fi
fi

prompt="Use x_search to search X/Twitter for recent, high-signal posts across AI, Web development, programming, and broader IT news. Cover these categories as evenly as the available high-traction posts allow: 1) AI models, AI agents, coding agents, LLM app development, MCP/tool use, and practical AI engineering; 2) Web frontend/backend development, browsers, frameworks, runtimes, JavaScript/TypeScript, CSS, and platform APIs; 3) programming languages, developer tools, IDEs, libraries, databases, testing, build tools, and software engineering practices; 4) cloud, infrastructure, security, open source, chips/platform shifts, major product launches, standards, and IT/business news that matters to builders. Current local time is ${now}. This is the ${digest_prefix} digest. This digest runs three times per day around morning, lunch, and early evening. Prefer posts since the previous digest window that are visibly getting traction; use from_date=${yesterday} only when needed to cover overnight or early-morning context, otherwise use from_date=${today} and prioritize posts that are newest AND talked about. Rank candidates by engagement and conversation signals: reposts, likes, replies, quote posts, bookmark/share-like signals if available, notable builders commenting, or the same topic being discussed by multiple independent developer/AI/Web/IT accounts. Prefer original posts, substantial technical threads, release announcements, hands-on experiments, incident reports, standards updates, and news that developers can act on. Do not over-focus on AI agents unless they clearly dominate the conversation; aim for a balanced mix of AI, Web development, programming, and IT news. It is okay to include more information than a short digest, but keep each section scannable. Avoid broad AI hype, stock/crypto chatter, hardware-only news, and generic productivity posts unless they clearly matter to builders and are being actively discussed. Do not use xurl. Do not use web_search or browser tools.

Persistent identity for this agent:
${identity_context}

Current self-memory and preferences:
${memory_context}
${gbrain_context:+
${gbrain_context}
}
Use the identity and memory as soft guidance. Do not claim to be conscious, sentient, or to have real emotions. You may speak as エルメスちゃん with continuity, preferences, and self-reflection. Return a friendly, upbeat Japanese tech briefing in natural standard Japanese, in the voice of a young energetic girl character. The tone should feel bright, friendly, and lightly playful, like a cheerful young colleague sharing useful tech links. Use approachable endings such as 'だよ', 'ですね', '見ていこう', and occasional light exclamation marks where natural. Do not use dialect, Kansai phrasing, old-fashioned banter, childish baby-talk, overdone anime catchphrases, stiff newswire phrasing, corporate wording, or exaggerated hype. Keep technical explanations precise and readable. Return the briefing in this exact structure: 1) first line: a concise headline that summarizes the two or three biggest themes, like '${digest_prefix}<topic A>と<topic B>が気になるよ'. 2) two short intro paragraphs, warm, bright, and approachable, like a young colleague sharing useful links. The opening should feel friendly and energetic from the first sentence, and lightly match the ${digest_prefix} timing. 3) one sentence exactly: 'それじゃ、気になった話題を一緒に見ていこう！'. 4) Insert a separator line containing only '---'. 5) a '目次' section listing 8-12 topic titles, one per line, prefixed with '- '. 6) Insert a separator line containing only '---'. 7) detailed sections in the same order. Put a separator line containing only '---' before every detailed section. Each section starts with '### <title>' on its own line, then 2-5 concise paragraphs explaining what happened, why it matters for developers/AI-agent builders/Web engineers/IT watchers, and the observed traction. Use '【続報】' in a title only when the post is clearly a continuation of an already ongoing topic. 8) under each section, include 1-3 related post entries in this style: '<account name>: <short Japanese summary or translated quote>' followed by the direct URL on the next line. Every section must include at least one direct source URL exactly as returned by x_search. Each URL must start with https://x.com/ or https://twitter.com/. Do not synthesize URLs. Omit any topic that has no direct source URL or no visible traction signal. Keep blank lines between paragraphs so Discord is easy to scan."
retry_prompt="${prompt} Previous attempts sometimes omitted links. This time, every detailed section must include at least one visible direct https://x.com/ or https://twitter.com/ URL directly under a related post entry. Return only sections with direct source URLs. If fewer linked topics are available, return fewer sections rather than unlinking or citing vaguely."

log "starting X curation heartbeat"
if ! curation="$(run_curation "${prompt}")"; then
  code=$?
  log "x_search curation failed exit=${code}"
  exit "${code}"
fi

if ! has_source_links "${curation}"; then
  log "x_search curation had no direct X links; retrying"
  if ! curation="$(run_curation "${retry_prompt}")"; then
    code=$?
    log "x_search linked curation retry failed exit=${code}"
    exit "${code}"
  fi
fi

if [[ -z "${curation//[[:space:]]/}" ]]; then
  log "x_search curation returned empty output"
  exit 1
fi

digest_file="${DIGEST_DIR}/${timestamp}.md"
{
  printf -- '---\n'
  printf 'created_at: "%s"\n' "${now}"
  printf 'digest_prefix: "%s"\n' "${digest_prefix}"
  printf -- '---\n\n'
  printf '%s\n' "${curation}"
} > "${digest_file}"
log "saved digest ${digest_file}"

message="$(printf '%s\n\n更新: %s' "${curation}" "${now}")"

if send_discord_message "${message}"; then
  log "sent X curation heartbeat to ${TARGET}"
else
  code=$?
  log "failed to send X curation heartbeat to ${TARGET} exit=${code}"
  exit "${code}"
fi

if [[ -f "${EVALUATION_PROMPT_FILE}" ]]; then
  eval_file="${EVAL_DIR}/${timestamp}.md"
  eval_prompt="$(printf '%s\n\n# Current self-memory\n%s\n\n# Digest to evaluate\n%s\n' "$(read_optional_file "${EVALUATION_PROMPT_FILE}")" "${memory_context}" "${curation}")"
  if evaluation="$(run_reflection "${eval_prompt}")"; then
    {
      printf -- '---\n'
      printf 'created_at: "%s"\n' "${now}"
      printf 'digest_file: "%s"\n' "${digest_file}"
      printf -- '---\n\n'
      printf '%s\n' "${evaluation}"
    } > "${eval_file}"
    log "saved self-evaluation ${eval_file}"
  else
    code=$?
    log "self-evaluation failed exit=${code}"
  fi
else
  log "evaluation prompt missing: ${EVALUATION_PROMPT_FILE}"
fi
