#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
HERMES_HOME_DIR="${HERMES_HOME:-${HOME}/.hermes}"
RUNTIME_DIR="${HERMES_POSTING_RUNTIME:-${HERMES_HOME_DIR}/runtime/grok-signal-agent}"
REPO_HINT_FILE="${RUNTIME_DIR}/repo-path"
CHANNELS_CONFIG="${HERMES_CHANNELS_CONFIG:-}"

usage() {
  cat <<'EOF'
Usage: hermes-posting-admin.sh <command> [args]

Commands:
  status
      Show Hermes posting runtime, cron, webhook, watcher, and source route state.
  check
      Validate posting JSON config and print route mappings.
  sync
      Install posting scripts/config/skill to ~/.hermes, register cron/webhooks,
      and restart the Hermes gateway.
  dry-run-watchers
      Run signal and X pulse watchers in dry-run mode using runtime config.
  test-webhooks [route...]
      Send Hermes webhook test events. Defaults to lightweight posting routes.
  set-source-route <source-id> <route>
      Update config/signal-watchers.json source route in the repo config.
  set-source-threshold <source-id> <score>
      Update config/signal-watchers.json source min_score in the repo config.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

resolve_repo() {
  local candidate
  for candidate in \
    "${HERMES_POSTING_REPO:-}" \
    "$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd || true)" \
    "$(pwd -P)" \
    "$(cat "${REPO_HINT_FILE}" 2>/dev/null || true)"; do
    [[ -n "${candidate}" ]] || continue
    if [[ -f "${candidate}/config/hermes-webhooks.json" && -f "${candidate}/config/hermes-cronjobs.json" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  die "could not locate grok-signal-agent repo; set HERMES_POSTING_REPO"
}

need_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
}

repo_dir="$(resolve_repo)"

validate_json() {
  need_jq
  jq -e '.version == 1' "${repo_dir}/config/hermes-cronjobs.json" >/dev/null
  jq -e '.version == 1 and (.subscriptions | type == "array")' "${repo_dir}/config/hermes-webhooks.json" >/dev/null
  jq -e '.version == 1 and (.sources | type == "array")' "${repo_dir}/config/signal-watchers.json" >/dev/null
  jq -e '.version == 1' "${repo_dir}/config/x-pulse-watchers.json" >/dev/null
  local channels_config="${CHANNELS_CONFIG:-${repo_dir}/config/hermes-channels.local.json}"
  if [[ -f "${channels_config}" ]]; then
    jq -e '.version == 1 and (.channels | type == "object")' "${channels_config}" >/dev/null
  fi
}

print_routes() {
  need_jq
  local channels_config="${CHANNELS_CONFIG:-${repo_dir}/config/hermes-channels.local.json}"
  if [[ -f "${channels_config}" ]]; then
    echo
    echo "Local channel overrides:"
    jq -r '.channels | to_entries[] | "  - \(.key)=\(.value)"' "${channels_config}"
  fi
  echo
  echo "Signal watcher sources:"
  jq -r '.sources[] | "  - \(.id) -> \(.route // .settings.default_route // "signal-catchup") min_score=\(.min_score // "default") url=\(.url)"' \
    "${repo_dir}/config/signal-watchers.json"
  echo
  echo "Webhook routes:"
  jq -r '.subscriptions[] | select((if has("enabled") then .enabled else true end) == true) | "  - \(.name) channel=\(.channel) mode=\(.mode)"' \
    "${repo_dir}/config/hermes-webhooks.json"
  echo
  echo "Cron jobs:"
  jq -r '.jobs[] | select((if has("enabled") then .enabled else true end) == true) | "  - \(.name) schedule=\(.schedule) channel=\(.channel) mode=\(.mode)"' \
    "${repo_dir}/config/hermes-cronjobs.json"
}

cmd_status() {
  echo "Repo: ${repo_dir}"
  echo "Runtime: ${RUNTIME_DIR}"
  validate_json
  print_routes
  echo
  "${HERMES_BIN}" cron status || true
  echo
  "${HERMES_BIN}" cron list || true
  echo
  "${HERMES_BIN}" webhook list || true
  echo
  if command -v launchctl >/dev/null 2>&1; then
    launchctl list | grep -E 'ai\.hermes\.gateway|grok-signal-agent' || true
  fi
}

install_skill() {
  local source_skill="${repo_dir}/.agents/skills/hermes-posting-admin/SKILL.md"
  local target_dir="${HERMES_HOME_DIR}/skills/devops/hermes-posting-admin"
  [[ -f "${source_skill}" ]] || return 0
  mkdir -p "${target_dir}"
  install -m 644 "${source_skill}" "${target_dir}/SKILL.md"
}

cmd_sync() {
  validate_json
  mkdir -p \
    "${HERMES_HOME_DIR}/bin" \
    "${HERMES_HOME_DIR}/prompts" \
    "${HERMES_HOME_DIR}/scripts" \
    "${RUNTIME_DIR}/config" \
    "${RUNTIME_DIR}/scripts"

  printf '%s\n' "${repo_dir}" > "${REPO_HINT_FILE}"
  install -m 755 "${repo_dir}/scripts/hermes-posting-admin.sh" "${HERMES_HOME_DIR}/bin/hermes-posting-admin.sh"
  install -m 755 "${repo_dir}/scripts/hermes-digest-lint.sh" "${HERMES_HOME_DIR}/bin/hermes-digest-lint.sh"
  install -m 755 "${repo_dir}/scripts/register-hermes-webhooks.sh" "${HERMES_HOME_DIR}/bin/register-hermes-webhooks.sh"
  install -m 755 "${repo_dir}/scripts/hermes-signal-watcher.sh" "${HERMES_HOME_DIR}/bin/hermes-signal-watcher.sh"
  install -m 755 "${repo_dir}/scripts/hermes-x-pulse-watcher.sh" "${HERMES_HOME_DIR}/bin/hermes-x-pulse-watcher.sh"
  install -m 755 "${repo_dir}/scripts/hermes-signal-watcher.py" "${RUNTIME_DIR}/scripts/hermes-signal-watcher.py"
  install -m 755 "${repo_dir}/scripts/hermes-x-pulse-watcher.py" "${RUNTIME_DIR}/scripts/hermes-x-pulse-watcher.py"
  install -m 644 "${repo_dir}/config/signal-watchers.json" "${RUNTIME_DIR}/config/signal-watchers.json"
  install -m 644 "${repo_dir}/config/x-pulse-watchers.json" "${RUNTIME_DIR}/config/x-pulse-watchers.json"
  for cron_script in "${repo_dir}"/scripts/*-cron.sh; do
    [[ -e "${cron_script}" ]] || continue
    install -m 755 "${cron_script}" "${HERMES_HOME_DIR}/scripts/"
  done
  for prompt_file in \
    "${repo_dir}/prompts/hermes-chan-identity.md" \
    "${repo_dir}/prompts/hermes-post-style.md" \
    "${repo_dir}/prompts/evaluate-digest.md" \
    "${repo_dir}/prompts/tech-digest.md" \
    "${repo_dir}/prompts/nightly-dreaming.md" \
    "${repo_dir}/prompts/weekly-self-reflection.md"; do
    [[ -e "${prompt_file}" ]] || continue
    install -m 644 "${prompt_file}" "${HERMES_HOME_DIR}/prompts/"
  done
  if compgen -G "${repo_dir}/prompts/webhooks/*.md" >/dev/null; then
    mkdir -p "${HERMES_HOME_DIR}/prompts/webhooks"
    for prompt_file in "${repo_dir}"/prompts/webhooks/*.md; do
      install -m 644 "${prompt_file}" "${HERMES_HOME_DIR}/prompts/webhooks/"
    done
  fi
  install_skill

  "${repo_dir}/scripts/register-hermes-cronjobs.sh"
  "${repo_dir}/scripts/register-hermes-webhooks.sh"
  "${HERMES_BIN}" gateway restart
  echo "posting sync complete"
}

cmd_dry_run_watchers() {
  "${HERMES_HOME_DIR}/bin/hermes-signal-watcher.sh" --dry-run --allow-first-run-send
  "${HERMES_HOME_DIR}/bin/hermes-x-pulse-watcher.sh" --dry-run --allow-first-run-send
}

cmd_test_webhooks() {
  local routes=("$@")
  local route payload
  if [[ "${#routes[@]}" -eq 0 ]]; then
    routes=(signal-catchup ai-latest-trigger x-buzz-trigger)
  fi
  need_jq
  for route in "${routes[@]}"; do
    payload="$(
      jq -cn \
        --arg route "${route}" \
        --arg url "https://github.com/s-hiraoku/grok-signal-agent" \
        '{event_type:"posting_admin_test", source:"hermes-posting-admin", route:$route, url:$url}'
    )"
    "${HERMES_BIN}" webhook test "${route}" --payload "${payload}"
  done
}

route_exists() {
  local route="$1"
  need_jq
  jq -e --arg route "${route}" '
    any(.subscriptions[];
      ((if has("enabled") then .enabled else true end) == true)
      and (.name == $route)
    )
  ' "${repo_dir}/config/hermes-webhooks.json" >/dev/null
}

update_source_field() {
  local source_id="$1" field="$2" value="$3" value_expr tmp
  need_jq
  tmp="$(mktemp)"
  if [[ "${field}" == "min_score" ]]; then
    [[ "${value}" =~ ^[0-9]+$ ]] || die "min_score must be an integer"
    value_expr='($value | tonumber)'
  else
    value_expr='$value'
  fi
  jq --arg id "${source_id}" --arg value "${value}" --arg field "${field}" "
    if any(.sources[]; .id == \$id) then
      .sources |= map(if .id == \$id then .[\$field] = ${value_expr} else . end)
    else
      error(\"unknown source id: \" + \$id)
    end
  " "${repo_dir}/config/signal-watchers.json" > "${tmp}"
  mv "${tmp}" "${repo_dir}/config/signal-watchers.json"
  echo "updated ${source_id}.${field}=${value}"
}

command="${1:-}"
case "${command}" in
  status)
    cmd_status
    ;;
  check)
    validate_json
    print_routes
    ;;
  sync)
    cmd_sync
    ;;
  dry-run-watchers)
    cmd_dry_run_watchers
    ;;
  test-webhooks)
    shift
    cmd_test_webhooks "$@"
    ;;
  set-source-route)
    [[ "$#" -eq 3 ]] || die "usage: set-source-route <source-id> <route>"
    route_exists "$3" || die "unknown enabled webhook route: $3"
    update_source_field "$2" route "$3"
    ;;
  set-source-threshold)
    [[ "$#" -eq 3 ]] || die "usage: set-source-threshold <source-id> <score>"
    update_source_field "$2" min_score "$3"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
