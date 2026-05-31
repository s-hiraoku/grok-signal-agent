#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
CONFIG_FILE="${HERMES_CRONJOBS_CONFIG:-${REPO_DIR}/config/hermes-cronjobs.json}"

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
    and (.mode == "prompt" or .mode == "script")
    and (.prompt | type == "string")
    and (if .mode == "script" then (.script | type == "string" and length > 0) else true end)
  )
' "${CONFIG_FILE}" >/dev/null

has_job() {
  local name="$1"
  "${HERMES_BIN}" cron list 2>/dev/null | grep -Fq "Name:      ${name}"
}

expand_home() {
  local value="$1"
  case "${value}" in
    "~/"*) printf '%s/%s' "${HOME}" "${value:2}" ;;
    *) printf '%s' "${value}" ;;
  esac
}

created_count=0
existing_count=0

while IFS= read -r job; do
  name="$(jq -r '.name' <<< "${job}")"
  schedule="$(jq -r '.schedule' <<< "${job}")"
  channel="$(jq -r '.channel' <<< "${job}")"
  deliver="$(jq -r --arg ch "${channel}" '.channels[$ch] // empty' "${CONFIG_FILE}")"
  mode="$(jq -r '.mode' <<< "${job}")"
  prompt="$(jq -r '.prompt' <<< "${job}")"

  if [[ -z "${deliver}" ]]; then
    echo "Unknown channel '${channel}' for job '${name}'." >&2
    exit 1
  fi

  if has_job "${name}"; then
    echo "Already exists: ${name}"
    existing_count=$((existing_count + 1))
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

  "${HERMES_BIN}" "${args[@]}" "${schedule}" "${prompt}"
  created_count=$((created_count + 1))
done < <(jq -c '.jobs[]' "${CONFIG_FILE}")

echo "Cron registration complete: ${created_count} created, ${existing_count} already existed."
