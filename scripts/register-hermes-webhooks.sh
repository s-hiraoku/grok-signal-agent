#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
CONFIG_FILE="${HERMES_WEBHOOKS_CONFIG:-${REPO_DIR}/config/hermes-webhooks.json}"
CRON_CONFIG_FILE="${HERMES_CRONJOBS_CONFIG:-${REPO_DIR}/config/hermes-cronjobs.json}"
CHANNELS_CONFIG="${HERMES_CHANNELS_CONFIG:-${REPO_DIR}/config/hermes-channels.local.json}"
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
    and ((if has("enabled") then .enabled else true end) | type == "boolean")
    and (.mode == "prompt" or .mode == "script" or .mode == "agent" or .mode == "deliver-only")
    and (if .mode == "script" then
      (.script | type == "string" and length > 0)
    else
      ((.prompt | type == "string") or (.prompt_file | type == "string" and length > 0))
    end)
    and ((.events // []) | type == "array")
    and ((.skills // []) | type == "array")
    and ((.secret_env // "") | type == "string")
  )
' "${CONFIG_FILE}" >/dev/null

jq -e '.version == 1 and (.channels | type == "object")' "${CRON_CONFIG_FILE}" >/dev/null

if [[ -f "${CHANNELS_CONFIG}" ]]; then
  jq -e '.version == 1 and (.channels | type == "object")' "${CHANNELS_CONFIG}" >/dev/null
fi

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

repo_file() {
  local value="$1"
  case "${value}" in
    "~/"*|/*) expand_home "${value}" ;;
    *) printf '%s/%s' "${REPO_DIR}" "${value}" ;;
  esac
}

channel_target() {
  local channel="$1" target=""
  if [[ -f "${CHANNELS_CONFIG}" ]]; then
    target="$(jq -r --arg ch "${channel}" '.channels[$ch] // empty' "${CHANNELS_CONFIG}")"
  fi
  if [[ -z "${target}" ]]; then
    target="$(jq -r --arg ch "${channel}" '.channels[$ch] // empty' "${CRON_CONFIG_FILE}")"
  fi
  if [[ "${target}" == *"replace-with-"* ]]; then
    target=""
  fi
  printf '%s' "${target}"
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

webhook_delivery_contract() {
  cat <<'EOF'

# Webhook Delivery Contract

- Do not call Discord or any other messaging or delivery tool.
- Return only the post body as the final answer. The webhook router will deliver it to the configured channel.
- Never return only a delivery acknowledgement such as `投稿完了`, `送信済み`, or `#hermes に配信`.
- Return the specified silent marker only when the route's suppression conditions apply.
EOF
}

script_prompt() {
  local script="$1"
  local workdir="$2"
  local script_path
  local cd_line=""

  case "${script}" in
    *-cron.sh) ;;
    *) echo "Script-mode webhook script must match scripts/*-cron.sh for runtime sync: ${script}" >&2; exit 1 ;;
  esac

  script_path="$(expand_home "~/.hermes/scripts/${script}")"

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
set -euo pipefail
script_path="${script_path}"
if [[ ! -f "\${script_path}" ]]; then
  echo "SCRIPT_UNAVAILABLE: \${script_path} が見つかりません。scripts/install-macos-launchagent.sh または hermes-posting-admin.sh sync を実行して runtime scripts を同期してください。" >&2
  exit 66
fi
${cd_line}bash "\${script_path}"
\`\`\`

この shell コマンドを実行せずに本文を推測しないでください。script の標準出力が Discord 投稿本文です。成功した場合は、その標準出力を最終回答としてそのまま返してください。失敗した場合は、失敗したコマンド、終了コード、重要な stderr を短く報告してください。
EOF
  webhook_delivery_contract
}

load_prompt() {
  local subscription="$1" prompt_file include_style prompt_path prompt_text style_file
  prompt_file="$(jq -r '.prompt_file // empty' <<< "${subscription}")"
  if [[ -n "${prompt_file}" ]]; then
    prompt_path="$(repo_file "${prompt_file}")"
    [[ -f "${prompt_path}" ]] || {
      echo "Webhook prompt_file not found: ${prompt_file}" >&2
      exit 1
    }
    prompt_text="$(cat "${prompt_path}")"
  else
    prompt_text="$(jq -r '.prompt' <<< "${subscription}")"
  fi

  include_style="$(jq -r '.include_post_style // false' <<< "${subscription}")"
  if [[ "${include_style}" == "true" ]]; then
    style_file="$(repo_file "prompts/hermes-post-style.md")"
    [[ -f "${style_file}" ]] || {
      echo "Posting style prompt not found: prompts/hermes-post-style.md" >&2
      exit 1
    }
    prompt_text="${prompt_text}"$'\n\n'"# Posting Style"$'\n\n'"$(cat "${style_file}")"
  fi
  prompt_text="${prompt_text}"$'\n\n'"$(webhook_delivery_contract)"
  printf '%s' "${prompt_text}"
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
disabled_count=0
removed_count=0

while IFS= read -r subscription; do
  name="$(normalize_name "$(jq -r '.name' <<< "${subscription}")")"
  enabled="$(jq -r 'if has("enabled") then .enabled else true end' <<< "${subscription}")"
  channel="$(jq -r '.channel' <<< "${subscription}")"
  target="$(channel_target "${channel}")"
  mode="$(jq -r '.mode' <<< "${subscription}")"
  description="$(jq -r '.description // empty' <<< "${subscription}")"

  if [[ -z "${target}" ]]; then
    echo "Unknown channel '${channel}' for webhook '${name}'." >&2
    echo "Map every current channel key in config/hermes-channels.local.json (start from config/hermes-channels.example.json). Older local override files predate the ai-news/tech-signals/digest/hermes channel keys and must be rewritten by hand." >&2
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
    case "${script}" in
      *-cron.sh) ;;
      *) echo "Script-mode webhook '${name}' script must match scripts/*-cron.sh for runtime sync: ${script}" >&2; exit 1 ;;
    esac
    if [[ ! -f "${REPO_DIR}/scripts/${script}" ]]; then
      echo "Script-mode webhook '${name}' references missing script: scripts/${script}" >&2
      exit 1
    fi
    prompt="$(script_prompt "${script}" "${workdir}")"
  else
    prompt="$(load_prompt "${subscription}")"
  fi

  if [[ "${enabled}" != "true" ]]; then
    disabled_count=$((disabled_count + 1))
    if [[ "${existed}" == "1" ]]; then
      run_hermes webhook remove "${name}"
      removed_count=$((removed_count + 1))
      echo "Removed disabled webhook: ${name}"
    else
      echo "Skipped disabled webhook: ${name}"
    fi
    continue
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

echo "Webhook registration complete: ${created_count} created, ${updated_count} updated, ${disabled_count} disabled, ${removed_count} removed."
