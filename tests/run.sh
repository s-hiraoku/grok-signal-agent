#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "not ok - $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "${haystack}" == *"${needle}"* ]] || fail "expected output to contain: ${needle}"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  LC_ALL=C grep -Fq -- "${needle}" "${file}" || fail "expected ${file} to contain: ${needle}"
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  ! LC_ALL=C grep -Fq -- "${needle}" "${file}" || fail "expected ${file} not to contain: ${needle}"
}

make_tmp_home() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  mkdir -p "${tmp_home}/.local/bin" "${tmp_home}/Library/LaunchAgents"
  printf '%s\n' "${tmp_home}"
}

write_hermes_stub() {
  local home_dir="$1"
  local existing_job="${2:-}"
  local log_file="${home_dir}/hermes-calls.log"

  cat > "${home_dir}/.local/bin/hermes" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "${HERMES_STUB_LOG}"
printf '\n' >> "${HERMES_STUB_LOG}"

if [[ "$1" == "cron" && "$2" == "list" ]]; then
  if [[ "${HERMES_EXISTING_JOB:-}" == "*" ]]; then
    for name in "tech-digest 08:00" "tech-digest 12:30" "tech-digest 18:00" "平日9:50リマインダー" "金曜17時gbrainサマリー"; do
      printf '  stub-%s [active]\n' "${name// /-}"
      printf '    Name:      %s\n' "${name}"
    done
  elif [[ -n "${HERMES_EXISTING_JOB:-}" ]]; then
    printf '  stub-id [active]\n'
    printf '    Name:      %s\n' "${HERMES_EXISTING_JOB}"
  fi
  exit 0
fi

if [[ "$1" == "cron" && "$2" == "create" ]]; then
  exit 0
fi

if [[ "$1" == "cron" && "$2" == "edit" ]]; then
  exit 0
fi

if [[ "$1" == "config" && "$2" == "set" ]]; then
  exit 0
fi

if [[ "$1" == "gateway" && "$2" == "install" ]]; then
  mkdir -p "${HOME}/Library/LaunchAgents"
  printf '<plist/>\n' > "${HOME}/Library/LaunchAgents/ai.hermes.gateway.plist"
  exit 0
fi

if [[ "$1" == "gateway" && "$2" == "restart" ]]; then
  printf '{"gateway_state":"running"}\n' > "${HOME}/.hermes/gateway_state.json"
  exit 0
fi

echo "unexpected hermes call: $*" >&2
exit 64
STUB
  chmod +x "${home_dir}/.local/bin/hermes"

  export HERMES_STUB_LOG="${log_file}"
  export HERMES_EXISTING_JOB="${existing_job}"
  : > "${log_file}"
}

test_register_cronjobs_creates_missing_jobs() {
  local tmp_home output log_file
  tmp_home="$(make_tmp_home)"
  write_hermes_stub "${tmp_home}" "tech-digest 08:00"
  log_file="${tmp_home}/hermes-calls.log"

  output="$(
    HOME="${tmp_home}" \
    HERMES_BIN="${tmp_home}/.local/bin/hermes" \
    HERMES_STUB_LOG="${HERMES_STUB_LOG}" \
    HERMES_EXISTING_JOB="${HERMES_EXISTING_JOB}" \
    "${REPO_DIR}/scripts/register-hermes-cronjobs.sh"
  )"

  assert_contains "${output}" "Already exists: tech-digest 08:00"
  assert_contains "${output}" "Cron registration complete: 4 created, 1 updated, 1 already existed."
  assert_file_contains "${log_file}" "cron edit --name tech-digest\\ 08:00 --schedule 0\\ 8\\ \\*\\ \\*\\ \\* --deliver discord:1510425425971515503 --prompt Run\\ the\\ tech\\ digest\\ script. --workdir '' --script hermes-tech-digest-cron.sh --no-agent stub-id"
  assert_file_contains "${log_file}" "cron create --name tech-digest\\ 12:30 --deliver discord:1510425425971515503 --script hermes-tech-digest-cron.sh --no-agent 30\\ 12\\ \\*\\ \\*\\ \\* Run\\ the\\ tech\\ digest\\ script."
  assert_file_contains "${log_file}" "--deliver discord:1510425534436212817 50\\ 9\\ \\*\\ \\*\\ 1-5"
  assert_file_contains "${log_file}" "--deliver discord:1510425635745435648 --workdir ${tmp_home}/.hermes/brain 0\\ 17\\ \\*\\ \\*\\ 5"
  assert_file_not_contains "${log_file}" "cron create --name tech-digest\\ 08:00"
}

test_register_cronjobs_rejects_unknown_channel() {
  local tmp_home config output status
  tmp_home="$(make_tmp_home)"
  write_hermes_stub "${tmp_home}" ""
  config="${tmp_home}/bad-cronjobs.json"
  cat > "${config}" <<'JSON'
{
  "version": 1,
  "channels": {},
  "jobs": [
    {
      "name": "bad job",
      "schedule": "0 9 * * *",
      "channel": "missing-channel",
      "mode": "prompt",
      "prompt": "hello"
    }
  ]
}
JSON

  set +e
  output="$(
    HOME="${tmp_home}" \
    HERMES_BIN="${tmp_home}/.local/bin/hermes" \
    HERMES_STUB_LOG="${HERMES_STUB_LOG}" \
    HERMES_CRONJOBS_CONFIG="${config}" \
    "${REPO_DIR}/scripts/register-hermes-cronjobs.sh" 2>&1
  )"
  status=$?
  set -e

  [[ "${status}" -ne 0 ]] || fail "expected register script to fail for unknown channel"
  assert_contains "${output}" "Unknown channel 'missing-channel' for job 'bad job'."
}

test_installer_uses_builtin_gateway_only() {
  local tmp_home stub_bin launchctl_log output
  tmp_home="$(make_tmp_home)"
  write_hermes_stub "${tmp_home}" "*"
  stub_bin="${tmp_home}/stub-bin"
  launchctl_log="${tmp_home}/launchctl-calls.log"
  mkdir -p "${stub_bin}" "${tmp_home}/Library/LaunchAgents"
  printf '<plist/>\n' > "${tmp_home}/Library/LaunchAgents/ai.hermes.gateway.plist"
  printf 'legacy\n' > "${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.hermes-gateway.plist"
  printf 'legacy\n' > "${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.hermes-gateway-healthcheck.plist"
  printf 'legacy\n' > "${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.discord-heartbeat.plist"

  cat > "${stub_bin}/launchctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${LAUNCHCTL_STUB_LOG}"
printf '\n' >> "${LAUNCHCTL_STUB_LOG}"
if [[ "$1" == "print" ]]; then
  printf 'state = running\n'
  exit 0
fi
exit 0
STUB
  chmod +x "${stub_bin}/launchctl"

  cat > "${stub_bin}/pmset" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "${stub_bin}/pmset"

  : > "${launchctl_log}"
  output="$(
    HOME="${tmp_home}" \
    PATH="${stub_bin}:${PATH}" \
    HERMES_STUB_LOG="${HERMES_STUB_LOG}" \
    HERMES_EXISTING_JOB="*" \
    LAUNCHCTL_STUB_LOG="${launchctl_log}" \
    "${REPO_DIR}/scripts/install-macos-launchagent.sh"
  )"

  assert_contains "${output}" "Installed and restarted Hermes built-in gateway service"
  assert_contains "${output}" "Removed legacy com.shiraoku.grok-signal-agent.discord-heartbeat, com.shiraoku.grok-signal-agent.hermes-gateway, and com.shiraoku.grok-signal-agent.hermes-gateway-healthcheck"
  [[ ! -e "${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.hermes-gateway.plist" ]] || fail "legacy gateway plist should be removed"
  [[ ! -e "${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.hermes-gateway-healthcheck.plist" ]] || fail "legacy healthcheck plist should be removed"
  [[ ! -e "${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.discord-heartbeat.plist" ]] || fail "legacy heartbeat plist should be removed"
  [[ -e "${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.weekly-self-reflection.plist" ]] || fail "weekly reflection plist should be rendered"
  assert_file_contains "${tmp_home}/hermes-calls.log" "config set cron.script_timeout_seconds 300"
  assert_file_contains "${tmp_home}/hermes-calls.log" "gateway restart"
  assert_file_not_contains "${tmp_home}/hermes-calls.log" "gateway install"
  assert_file_not_contains "${launchctl_log}" "bootstrap gui/$(id -u) ${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.hermes-gateway.plist"
  assert_file_not_contains "${launchctl_log}" "bootstrap gui/$(id -u) ${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.hermes-gateway-healthcheck.plist"
  assert_file_contains "${launchctl_log}" "bootstrap gui/$(id -u) ${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.weekly-self-reflection.plist"
  assert_file_contains "${launchctl_log}" "print gui/$(id -u)/ai.hermes.gateway"
}

test_scheduled_prompts_require_direct_source_links() {
  assert_file_contains "${REPO_DIR}/prompts/x-daily-summary.md" "handle だけの出典は不可"
  assert_file_contains "${REPO_DIR}/prompts/x-daily-summary.md" "Google の検索結果 URL ではなく"
  assert_file_contains "${REPO_DIR}/prompts/tech-digest.md" "参照ページ: <direct URL>"
  assert_file_contains "${REPO_DIR}/config/hermes-cronjobs.json" '各ニュース項目には必ず `出典: <直接URL>`'
  assert_file_contains "${REPO_DIR}/config/hermes-cronjobs.json" "Google検索結果URLではなく"
  assert_file_contains "${REPO_DIR}/docs/scheduled-jobs.md" "Google/Web-derived items must include the original page URL"
}

main() {
  local tests=(
    test_register_cronjobs_creates_missing_jobs
    test_register_cronjobs_rejects_unknown_channel
    test_installer_uses_builtin_gateway_only
    test_scheduled_prompts_require_direct_source_links
  )
  local test_name

  for test_name in "${tests[@]}"; do
    "${test_name}"
    echo "ok - ${test_name}"
  done
}

main "$@"
