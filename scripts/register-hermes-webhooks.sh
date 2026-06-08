#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
CONFIG_FILE="${HERMES_WEBHOOKS_CONFIG:-${REPO_DIR}/config/hermes-webhooks.json}"
CRON_CONFIG_FILE="${HERMES_CRONJOBS_CONFIG:-${REPO_DIR}/config/hermes-cronjobs.json}"
HERMES_HOME_DIR="${HERMES_HOME:-${HOME}/.hermes}"
SUBSCRIPTIONS_FILE="${HERMES_WEBHOOK_SUBSCRIPTIONS_FILE:-${HERMES_HOME_DIR}/webhook_subscriptions.json}"
ENV_FILE="${HERMES_ENV_FILE:-${HERMES_HOME_DIR}/.env}"

if [[ ! -x "${HERMES_BIN}" ]]; then
  echo "Hermes is not installed at ${HERMES_BIN}." >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || {
  echo "jq is required but was not found on PATH." >&2
  exit 1
}

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Webhook config not found: ${CONFIG_FILE}" >&2
  exit 1
fi

if [[ ! -f "${CRON_CONFIG_FILE}" ]]; then
  echo "Channel config not found: ${CRON_CONFIG_FILE}" >&2
  exit 1
fi

jq -e '
  .version == 1
  and (.subscriptions | type == "array")
  and all(.subscriptions[];
    (.name | type == "string" and length > 0)
    and (.channel | type == "string" and length > 0)
    and (.mode == "prompt" or .mode == "script" or .mode == "agent" or .mode == "deliver-only")
    and (if .mode == "script" then (.script | type == "string" and length > 0) else (.prompt | type == "string") end)
    and ((.events // []) | type == "array")
    and ((.skills // []) | type == "array")
    and ((.secret_env // "") | type == "string")
  )
' "${CONFIG_FILE}" >/dev/null

jq -e '.version == 1 and (.channels | type == "object")' "${CRON_CONFIG_FILE}" >/dev/null

normalize_name() {
  local name="$1"
  printf '%s' "${name// /-}" | tr '[:upper:]' '[:lower:]'
}

expand_home() {
  local value="$1"
  case "${value}" in
    "~/"*) printf '%s/%s' "${HOME}" "${value:2}" ;;
    *) printf '%s' "${value}" ;;
  esac
}

existing_secret() {
  local name="$1"
  [[ -f "${SUBSCRIPTIONS_FILE}" ]] || return 1
  jq -er --arg name "${name}" '.[$name].secret // empty' "${SUBSCRIPTIONS_FILE}" 2>/dev/null
}

env_file_value() {
  local key="$1"
  local line value

  [[ -f "${ENV_FILE}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
    [[ "${line}" == "${key}="* ]] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    if [[ "${value}" == \"*\" && "${value}" == *\" && "${#value}" -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' && "${#value}" -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    fi
    printf '%s' "${value}"
    return 0
  done < "${ENV_FILE}"
  return 1
}

env_value() {
  local key="$1"
  if [[ -n "${!key:-}" ]]; then
    printf '%s' "${!key}"
    return 0
  fi
  env_file_value "${key}"
}

script_prompt() {
  local script="$1"
  local workdir="$2"
  local script_path="\${HOME}/.hermes/scripts/${script}"
  local cd_line=""

  if [[ -n "${workdir}" ]]; then
    cd_line="cd \"$(expand_home "${workdir}")\" && "
  fi

  cat <<EOF
外部トリガーにより Hermes の投稿 handler script を実行します。これは cron ではなく webhook payload による起動です。

イベント種別: {event_type}
ペイロード:
\`\`\`json
{__raw__}
\`\`\`

terminal/shell が利用可能なら、次のコマンドを実行してください。

\`\`\`bash
${cd_line}\"${script_path}\"
\`\`\`

script の標準出力が Discord 投稿本文です。成功した場合は、その標準出力を最終回答としてそのまま返してください。失敗した場合は、失敗したコマンド、終了コード、重要な stderr を短く報告してください。
EOF
}

run_hermes() {
  local output status

  set +e
  output="$("${HERMES_BIN}" "$@" 2>&1)"
  status=$?
  set -e

  [[ -z "${output}" ]] || printf '%s\n' "${output}" | sed -E 's/^([[:space:]]*Secret:).*/\1 [redacted]/'
  if [[ "${status}" -ne 0 || "${output}" == *"Webhook platform is not enabled"* || "${output}" == *"Error:"* ]]; then
    return 1
  fi
}

created_count=0
updated_count=0

while IFS= read -r subscription; do
  name="$(normalize_name "$(jq -r '.name' <<< "${subscription}")")"
  channel="$(jq -r '.channel' <<< "${subscription}")"
  target="$(jq -r --arg ch "${channel}" '.channels[$ch] // empty' "${CRON_CONFIG_FILE}")"
  mode="$(jq -r '.mode' <<< "${subscription}")"
  description="$(jq -r '.description // empty' <<< "${subscription}")"

  if [[ -z "${target}" ]]; then
    echo "Unknown channel '${channel}' for webhook '${name}'." >&2
    exit 1
  fi

  IFS=':' read -r deliver chat_id _ <<< "${target}"
  if [[ -z "${deliver}" || -z "${chat_id}" ]]; then
    echo "Webhook '${name}' channel '${channel}' must resolve to platform:chat_id." >&2
    exit 1
  fi

  existed=0
  if [[ -f "${SUBSCRIPTIONS_FILE}" ]] && jq -e --arg name "${name}" 'has($name)' "${SUBSCRIPTIONS_FILE}" >/dev/null 2>&1; then
    existed=1
  fi

  if [[ "${mode}" == "script" ]]; then
    script="$(jq -r '.script' <<< "${subscription}")"
    workdir="$(jq -r '.workdir // empty' <<< "${subscription}")"
    prompt="$(script_prompt "${script}" "${workdir}")"
  else
    prompt="$(jq -r '.prompt' <<< "${subscription}")"
  fi

  args=(webhook subscribe "${name}" --prompt "${prompt}" --deliver "${deliver}" --deliver-chat-id "${chat_id}")

  if [[ -n "${description}" ]]; then
    args+=(--description "${description}")
  fi

  events="$(jq -r '(.events // []) | join(",")' <<< "${subscription}")"
  if [[ -n "${events}" ]]; then
    args+=(--events "${events}")
  fi

  skills="$(jq -r '(.skills // []) | join(",")' <<< "${subscription}")"
  if [[ -n "${skills}" ]]; then
    args+=(--skills "${skills}")
  fi

  if [[ "${mode}" == "deliver-only" ]]; then
    args+=(--deliver-only)
  fi

  secret_env="$(jq -r '.secret_env // empty' <<< "${subscription}")"
  secret=""
  if [[ -n "${secret_env}" ]]; then
    secret="$(env_value "${secret_env}" || true)"
  fi
  if [[ -z "${secret}" ]]; then
    secret="$(existing_secret "${name}" || true)"
  fi
  if [[ -n "${secret}" ]]; then
    args+=(--secret "${secret}")
  fi

  run_hermes "${args[@]}"

  if [[ "${existed}" == "1" ]]; then
    updated_count=$((updated_count + 1))
    echo "Synced existing webhook: ${name}"
  else
    created_count=$((created_count + 1))
    echo "Created webhook: ${name}"
  fi
done < <(jq -c '.subscriptions[]' "${CONFIG_FILE}")

echo "Webhook registration complete: ${created_count} created, ${updated_count} updated."
