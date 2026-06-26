#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
CONFIG_FILE="${HERMES_CRONJOBS_CONFIG:-${REPO_DIR}/config/hermes-cronjobs.json}"
CHANNELS_CONFIG="${HERMES_CHANNELS_CONFIG:-${REPO_DIR}/config/hermes-channels.local.json}"

if [[ ! -x "${HERMES_BIN}" ]]; then
  echo "Hermes is not installed at ${HERMES_BIN}." >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || {
  echo "jq is required but was not found on PATH." >&2
  exit 1
}

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Cron job config not found: ${CONFIG_FILE}" >&2
  exit 1
fi

jq -e '
  .version == 1
  and (.channels | type == "object")
  and (.jobs | type == "array")
  and all(.jobs[];
    (.name | type == "string" and length > 0)
    and (.schedule | type == "string" and length > 0)
    and (.channel | type == "string" and length > 0)
    and ((if has("enabled") then .enabled else true end) | type == "boolean")
    and (.mode == "prompt" or .mode == "script")
    and (.prompt | type == "string")
    and (if .mode == "script" then (.script | type == "string" and length > 0) else true end)
  )
' "${CONFIG_FILE}" >/dev/null

if [[ -f "${CHANNELS_CONFIG}" ]]; then
  jq -e '.version == 1 and (.channels | type == "object")' "${CHANNELS_CONFIG}" >/dev/null
fi

existing_job_id() {
  local name="$1"
  local line current_id=""

  while IFS= read -r line; do
    if [[ "${line}" =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]+\[ ]]; then
      current_id="${BASH_REMATCH[1]}"
    elif [[ "${line}" == "    Name:      ${name}" ]]; then
      [[ -n "${current_id}" ]] || return 1
      printf '%s\n' "${current_id}"
      return 0
    fi
  done < <("${HERMES_BIN}" cron list 2>/dev/null)

  return 1
}

expand_home() {
  local value="$1"
  case "${value}" in
    "~/"*) printf '%s/%s' "${HOME}" "${value:2}" ;;
    *) printf '%s' "${value}" ;;
  esac
}

channel_target() {
  local channel="$1" target=""
  if [[ -f "${CHANNELS_CONFIG}" ]]; then
    target="$(jq -r --arg ch "${channel}" '.channels[$ch] // empty' "${CHANNELS_CONFIG}")"
  fi
  if [[ -z "${target}" ]]; then
    target="$(jq -r --arg ch "${channel}" '.channels[$ch] // empty' "${CONFIG_FILE}")"
  fi
  if [[ "${target}" == *"replace-with-"* ]]; then
    target=""
  fi
  printf '%s' "${target}"
}

run_hermes() {
  local output status

  set +e
  output="$("${HERMES_BIN}" "$@" 2>&1)"
  status=$?
  set -e

  [[ -z "${output}" ]] || printf '%s\n' "${output}"
  if [[ "${status}" -ne 0 || "${output}" == *"Failed to "* ]]; then
    return 1
  fi
}

created_count=0
existing_count=0
updated_count=0
disabled_count=0
removed_count=0

while IFS= read -r job; do
  name="$(jq -r '.name' <<< "${job}")"
  enabled="$(jq -r 'if has("enabled") then .enabled else true end' <<< "${job}")"
  schedule="$(jq -r '.schedule' <<< "${job}")"
  channel="$(jq -r '.channel' <<< "${job}")"
  deliver="$(channel_target "${channel}")"
  mode="$(jq -r '.mode' <<< "${job}")"
  prompt="$(jq -r '.prompt' <<< "${job}")"

  if [[ -z "${deliver}" ]]; then
    echo "Unknown channel '${channel}' for job '${name}'." >&2
    exit 1
  fi

  if [[ "${enabled}" != "true" ]]; then
    disabled_count=$((disabled_count + 1))
    if existing_id="$(existing_job_id "${name}")"; then
      if [[ "${HERMES_CRONJOBS_REMOVE_DISABLED:-1}" == "1" ]]; then
        run_hermes cron remove "${existing_id}"
        removed_count=$((removed_count + 1))
        echo "Removed disabled cron job: ${name}"
      else
        echo "Disabled cron job still registered: ${name}"
      fi
    else
      echo "Skipped disabled cron job: ${name}"
    fi
    continue
  fi

  if existing_id="$(existing_job_id "${name}")"; then
    echo "Already exists: ${name}"
    existing_count=$((existing_count + 1))
    if [[ "${HERMES_CRONJOBS_SYNC_EXISTING:-1}" == "1" ]]; then
      args=(cron edit
        --name "${name}"
        --schedule "${schedule}"
        --deliver "${deliver}"
        --prompt "${prompt}"
      )

      workdir="$(jq -r '.workdir // empty' <<< "${job}")"
      if [[ -n "${workdir}" ]]; then
        args+=(--workdir "$(expand_home "${workdir}")")
      else
        args+=(--workdir "")
      fi

      if [[ "${mode}" == "script" ]]; then
        script="$(jq -r '.script' <<< "${job}")"
        args+=(--script "${script}")
        if [[ "$(jq -r '.no_agent // false' <<< "${job}")" == "true" ]]; then
          args+=(--no-agent)
        else
          args+=(--agent)
        fi
      else
        args+=(--script "" --agent)
      fi

      run_hermes "${args[@]}" "${existing_id}"
      updated_count=$((updated_count + 1))
      echo "Synced existing: ${name}"
    fi
    continue
  fi

  args=(cron create --name "${name}" --deliver "${deliver}")

  workdir="$(jq -r '.workdir // empty' <<< "${job}")"
  if [[ -n "${workdir}" ]]; then
    args+=(--workdir "$(expand_home "${workdir}")")
  fi

  if [[ "${mode}" == "script" ]]; then
    script="$(jq -r '.script' <<< "${job}")"
    args+=(--script "${script}")
    if [[ "$(jq -r '.no_agent // false' <<< "${job}")" == "true" ]]; then
      args+=(--no-agent)
    fi
  fi

  run_hermes "${args[@]}" "${schedule}" "${prompt}"
  created_count=$((created_count + 1))
done < <(jq -c '.jobs[]' "${CONFIG_FILE}")

echo "Cron registration complete: ${created_count} created, ${updated_count} updated, ${existing_count} already existed, ${disabled_count} disabled, ${removed_count} removed."
