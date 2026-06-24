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

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="${3:-value}"
  [[ "${actual}" == "${expected}" ]] || fail "expected ${label}=${expected}, got ${actual}"
}

assert_json_eq() {
  local json="$1"
  local expr="$2"
  local expected="$3"
  assert_eq "$(jq -r "${expr}" <<< "${json}")" "${expected}" "${expr}"
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
    for name in "tech-digest 08:00" "tech-digest 12:30" "tech-digest 18:00" "平日9:50リマインダー" "毎晩2:30 dreaming再合成" "金曜17時gbrainサマリー"; do
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

if [[ "$1" == "cron" && "$2" == "remove" ]]; then
  exit 0
fi

if [[ "$1" == "webhook" && "$2" == "list" ]]; then
  echo "Webhook platform is not enabled"
  exit "${HERMES_WEBHOOK_LIST_STATUS:-0}"
fi

if [[ "$1" == "webhook" && "$2" == "subscribe" ]]; then
  exit 0
fi

if [[ "$1" == "webhook" && "$2" == "remove" ]]; then
  exit 0
fi

if [[ "$1" == "config" && "$2" == "set" ]]; then
  exit 0
fi

if [[ "$1" == "gateway" && "$2" == "install" ]]; then
  mkdir -p "${HOME}/Library/LaunchAgents"
  printf '<plist/>\n' > "${HOME}/Library/LaunchAgents/ai.hermes.gateway.plist"
  [[ -f "${HOME}/.hermes/config.yaml" ]] || printf 'hooks: {}\n' > "${HOME}/.hermes/config.yaml"
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

test_register_cronjobs_syncs_enabled_tech_digest_jobs() {
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

  assert_contains "${output}" "Synced existing: tech-digest 08:00"
  assert_contains "${output}" "Skipped disabled cron job: 毎晩2:30 dreaming再合成"
  assert_contains "${output}" "Cron registration complete: 5 created, 1 updated, 1 already existed, 1 disabled, 0 removed."
  assert_file_contains "${log_file}" "cron edit --name tech-digest\\ 08:00"
  assert_file_contains "${log_file}" "--script hermes-tech-digest-cron.sh"
  assert_file_contains "${log_file}" "--script hermes-morning-brief-cron.sh"
  assert_file_contains "${log_file}" "--no-agent 50\\ 9\\ \\*\\ \\*\\ 1-5 Run\\ the\\ morning\\ brief\\ script."
  assert_file_contains "${log_file}" "--script hermes-weekly-review-cron.sh"
  assert_file_contains "${log_file}" "--script hermes-daily-review-cron.sh"
  assert_file_contains "${log_file}" "--deliver discord:1513665059723808878"
  assert_file_not_contains "${log_file}" "cron remove stub-id"
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

test_register_cronjobs_uses_local_channel_overrides() {
  local tmp_home channels output log_file
  tmp_home="$(make_tmp_home)"
  write_hermes_stub "${tmp_home}" ""
  log_file="${tmp_home}/hermes-calls.log"
  channels="${tmp_home}/channels.json"
  cat > "${channels}" <<'JSON'
{
  "version": 1,
  "channels": {
    "tech-digest": "discord:999999999999999999"
  }
}
JSON

  output="$(
    HOME="${tmp_home}" \
    HERMES_BIN="${tmp_home}/.local/bin/hermes" \
    HERMES_STUB_LOG="${HERMES_STUB_LOG}" \
    HERMES_CHANNELS_CONFIG="${channels}" \
    "${REPO_DIR}/scripts/register-hermes-cronjobs.sh"
  )"

  assert_contains "${output}" "Cron registration complete:"
  assert_file_contains "${log_file}" "--name tech-digest\\ 08:00 --deliver discord:999999999999999999"
  assert_file_contains "${log_file}" "--deliver discord:1510425534436212817"
}

test_morning_brief_cron_reads_direct_feeds() {
  local tmp_home general_feed tech_feed output
  tmp_home="$(mktemp -d)"
  general_feed="${tmp_home}/general.xml"
  tech_feed="${tmp_home}/tech.xml"
  cat > "${general_feed}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>General Test</title>
    <item>
      <title>重要な一般ニュース</title>
      <link>https://example.com/general-news</link>
      <pubDate>Fri, 12 Jun 2026 09:10:00 +0900</pubDate>
    </item>
  </channel>
</rss>
XML
  cat > "${tech_feed}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Tech Test</title>
    <item>
      <title>重要なAI開発ニュース</title>
      <link>https://example.com/tech-news</link>
      <pubDate>Fri, 12 Jun 2026 09:20:00 +0900</pubDate>
    </item>
  </channel>
</rss>
XML

  output="$(
    HOME="${tmp_home}" \
    HERMES_MORNING_CALENDAR_ENABLED=0 \
    HERMES_MORNING_GENERAL_FEEDS="General Test|file://${general_feed}" \
    HERMES_MORNING_TECH_FEEDS="Tech Test|file://${tech_feed}" \
    "${REPO_DIR}/scripts/hermes-morning-brief-cron.sh"
  )"

  assert_contains "${output}" "おはよう、ヘルメスちゃんです"
  assert_contains "${output}" "重要な一般ニュース"
  assert_contains "${output}" "出典: https://example.com/general-news"
  assert_contains "${output}" "重要なAI開発ニュース"
  assert_contains "${output}" "出典: https://example.com/tech-news"
  [[ "${output}" != *"大きな動きは見つからなかった"* ]] || fail "morning brief should not emit generic no-news filler"
}

test_morning_brief_includes_today_calendar_events() {
  local tmp_home feed google_api output
  tmp_home="$(mktemp -d)"
  feed="${tmp_home}/feed.xml"
  google_api="${tmp_home}/google_api.py"
  cat > "${feed}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Brief Test</title>
    <item>
      <title>今日の確認ニュース</title>
      <link>https://example.com/news</link>
      <pubDate>Fri, 12 Jun 2026 08:10:00 +0900</pubDate>
    </item>
  </channel>
</rss>
XML
  cat > "${google_api}" <<'PY'
#!/usr/bin/env python3
import json

print(json.dumps([
  {
    "summary": "朝会",
    "start": "2026-06-12T10:00:00+09:00",
    "end": "2026-06-12T10:30:00+09:00",
    "location": "オンライン",
    "htmlLink": "https://calendar.example.com/today"
  }
]))
PY
  chmod +x "${google_api}"

  output="$(
    TZ=Asia/Tokyo \
    HOME="${tmp_home}" \
    HERMES_MORNING_NOW="2026-06-12T09:50:00+09:00" \
    HERMES_GOOGLE_API_SCRIPT="${google_api}" \
    HERMES_GOOGLE_API_PYTHON="${PYTHON:-python3}" \
    HERMES_MORNING_GENERAL_FEEDS="Brief Test|file://${feed}" \
    HERMES_MORNING_TECH_FEEDS="Brief Test|file://${feed}" \
    "${REPO_DIR}/scripts/hermes-morning-brief-cron.sh"
  )"

  assert_contains "${output}" "今日の予定"
  assert_contains "${output}" "06/12 10:00-10:30 / オンライン 朝会"
  assert_contains "${output}" "予定: https://calendar.example.com/today"
  [[ "${output}" != *"今週の予定"* ]] || fail "non-Monday morning brief should not include weekly schedule"
}

test_monday_morning_brief_includes_weekly_calendar_events() {
  local tmp_home feed google_api output
  tmp_home="$(mktemp -d)"
  feed="${tmp_home}/feed.xml"
  google_api="${tmp_home}/google_api.py"
  cat > "${feed}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Brief Test</title>
    <item>
      <title>週初めニュース</title>
      <link>https://example.com/monday-news</link>
      <pubDate>Mon, 15 Jun 2026 08:10:00 +0900</pubDate>
    </item>
  </channel>
</rss>
XML
  cat > "${google_api}" <<'PY'
#!/usr/bin/env python3
import json
import sys

max_arg = sys.argv[sys.argv.index("--max") + 1]
if max_arg == "6":
    events = [
      {
        "summary": "月曜朝会",
        "start": "2026-06-15T10:00:00+09:00",
        "end": "2026-06-15T10:30:00+09:00",
        "location": "",
        "htmlLink": "https://calendar.example.com/monday"
      }
    ]
else:
    events = [
      {
        "summary": "週次レビュー",
        "start": "2026-06-18T15:00:00+09:00",
        "end": "2026-06-18T16:00:00+09:00",
        "location": "会議室",
        "htmlLink": "https://calendar.example.com/week"
      }
    ]
print(json.dumps(events))
PY
  chmod +x "${google_api}"

  output="$(
    TZ=Asia/Tokyo \
    HOME="${tmp_home}" \
    HERMES_MORNING_NOW="2026-06-15T09:50:00+09:00" \
    HERMES_GOOGLE_API_SCRIPT="${google_api}" \
    HERMES_GOOGLE_API_PYTHON="${PYTHON:-python3}" \
    HERMES_MORNING_GENERAL_FEEDS="Brief Test|file://${feed}" \
    HERMES_MORNING_TECH_FEEDS="Brief Test|file://${feed}" \
    "${REPO_DIR}/scripts/hermes-morning-brief-cron.sh"
  )"

  assert_contains "${output}" "今日の予定"
  assert_contains "${output}" "06/15 10:00-10:30 月曜朝会"
  assert_contains "${output}" "今週の予定"
  assert_contains "${output}" "06/18 15:00-16:00 / 会議室 週次レビュー"
  assert_contains "${output}" "予定: https://calendar.example.com/week"
}

test_installer_uses_builtin_gateway_only() {
  local tmp_home stub_bin launchctl_log output
  tmp_home="$(make_tmp_home)"
  write_hermes_stub "${tmp_home}" "*"
  stub_bin="${tmp_home}/stub-bin"
  launchctl_log="${tmp_home}/launchctl-calls.log"
  mkdir -p "${stub_bin}" "${tmp_home}/Library/LaunchAgents" "${tmp_home}/.hermes"
  cat > "${tmp_home}/.hermes/config.yaml" <<'YAML'
hooks: {}
YAML
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
    HERMES_WEBHOOK_LIST_STATUS=1 \
    LAUNCHCTL_STUB_LOG="${launchctl_log}" \
    "${REPO_DIR}/scripts/install-macos-launchagent.sh"
  )"

  assert_contains "${output}" "Installed and restarted Hermes built-in gateway service"
  assert_contains "${output}" "Installed Hermes posting admin helper and skill"
  assert_contains "${output}" "Removed legacy com.shiraoku.grok-signal-agent.discord-heartbeat, com.shiraoku.grok-signal-agent.hermes-gateway, and com.shiraoku.grok-signal-agent.hermes-gateway-healthcheck"
  [[ ! -e "${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.hermes-gateway.plist" ]] || fail "legacy gateway plist should be removed"
  [[ ! -e "${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.hermes-gateway-healthcheck.plist" ]] || fail "legacy healthcheck plist should be removed"
  [[ ! -e "${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.discord-heartbeat.plist" ]] || fail "legacy heartbeat plist should be removed"
  [[ -e "${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.weekly-self-reflection.plist" ]] || fail "weekly reflection plist should be rendered"
  assert_file_contains "${tmp_home}/hermes-calls.log" "config set cron.script_timeout_seconds 300"
  assert_file_contains "${tmp_home}/hermes-calls.log" "cron remove"
  assert_contains "${output}" "Skipped webhook registration because Hermes webhook platform is not enabled"
  assert_file_contains "${tmp_home}/hermes-calls.log" "gateway restart"
  [[ -x "${tmp_home}/.hermes/bin/hermes-digest-lint.sh" ]] || fail "digest linter should be installed"
  [[ -x "${tmp_home}/.hermes/bin/hermes-discord-feedback.sh" ]] || fail "feedback hook should be installed"
  [[ -x "${tmp_home}/.hermes/bin/hermes-alert.sh" ]] || fail "alert helper should be installed"
  [[ -x "${tmp_home}/.hermes/bin/hermes-obsidian-mcp-setup.sh" ]] || fail "obsidian MCP setup helper should be installed"
  [[ -x "${tmp_home}/.hermes/bin/hermes-jina-mcp-setup.sh" ]] || fail "jina MCP setup helper should be installed"
  [[ -x "${tmp_home}/.hermes/bin/hermes-google-calendar-mcp-setup.sh" ]] || fail "google calendar MCP setup helper should be installed"
  [[ -x "${tmp_home}/.hermes/bin/hermes-posting-admin.sh" ]] || fail "posting admin helper should be installed"
  [[ -x "${tmp_home}/.hermes/bin/register-hermes-webhooks.sh" ]] || fail "webhook registration helper should be installed"
  [[ -x "${tmp_home}/.hermes/bin/hermes-signal-watcher.sh" ]] || fail "signal watcher helper should be installed"
  [[ -x "${tmp_home}/.hermes/bin/hermes-x-pulse-watcher.sh" ]] || fail "x pulse watcher helper should be installed"
  [[ -x "${tmp_home}/.hermes/runtime/grok-signal-agent/scripts/hermes-signal-watcher.py" ]] || fail "signal watcher runtime script should be installed"
  [[ -x "${tmp_home}/.hermes/runtime/grok-signal-agent/scripts/hermes-x-pulse-watcher.py" ]] || fail "x pulse watcher runtime script should be installed"
  [[ -f "${tmp_home}/.hermes/runtime/grok-signal-agent/config/signal-watchers.json" ]] || fail "signal watcher runtime config should be installed"
  [[ -f "${tmp_home}/.hermes/runtime/grok-signal-agent/config/x-pulse-watchers.json" ]] || fail "x pulse watcher runtime config should be installed"
  [[ -f "${tmp_home}/.hermes/runtime/grok-signal-agent/repo-path" ]] || fail "posting admin repo hint should be installed"
  [[ -f "${tmp_home}/.hermes/skills/devops/hermes-posting-admin/SKILL.md" ]] || fail "posting admin skill should be installed"
  [[ -f "${tmp_home}/.hermes/prompts/hermes-post-style.md" ]] || fail "posting style prompt should be installed"
  [[ -x "${tmp_home}/.hermes/scripts/hermes-dreaming-cron.sh" ]] || fail "dreaming cron script should be installed"
  [[ -x "${tmp_home}/.hermes/scripts/hermes-morning-brief-cron.sh" ]] || fail "morning brief cron script should be installed"
  [[ -x "${tmp_home}/.hermes/scripts/hermes-review-cron.sh" ]] || fail "review cron script should be installed"
  [[ -x "${tmp_home}/.hermes/scripts/hermes-daily-review-cron.sh" ]] || fail "daily review cron wrapper should be installed"
  [[ -x "${tmp_home}/.hermes/scripts/hermes-weekly-review-cron.sh" ]] || fail "weekly review cron wrapper should be installed"
  [[ -f "${tmp_home}/.hermes/prompts/nightly-dreaming.md" ]] || fail "dreaming prompt should be installed"
  assert_file_contains "${tmp_home}/.hermes/config.yaml" "hermes-gbrain-remember.sh"
  assert_file_contains "${tmp_home}/.hermes/config.yaml" "hermes-discord-feedback.sh"
  assert_file_contains "${tmp_home}/.hermes/shell-hooks-allowlist.json" "hermes-gbrain-remember.sh"
  assert_file_contains "${tmp_home}/.hermes/shell-hooks-allowlist.json" "hermes-discord-feedback.sh"
  assert_file_contains "${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.signal-watcher.plist" "${tmp_home}/.hermes/runtime/grok-signal-agent"
  assert_file_contains "${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.x-pulse-watcher.plist" "${tmp_home}/.hermes/runtime/grok-signal-agent"
  assert_file_not_contains "${tmp_home}/hermes-calls.log" "gateway install"
  assert_file_not_contains "${launchctl_log}" "bootstrap gui/$(id -u) ${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.hermes-gateway.plist"
  assert_file_not_contains "${launchctl_log}" "bootstrap gui/$(id -u) ${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.hermes-gateway-healthcheck.plist"
  assert_file_contains "${launchctl_log}" "bootstrap gui/$(id -u) ${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.weekly-self-reflection.plist"
  assert_file_contains "${launchctl_log}" "bootstrap gui/$(id -u) ${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.signal-watcher.plist"
  assert_file_contains "${launchctl_log}" "bootstrap gui/$(id -u) ${tmp_home}/Library/LaunchAgents/com.shiraoku.grok-signal-agent.x-pulse-watcher.plist"
  assert_file_contains "${launchctl_log}" "print gui/$(id -u)/ai.hermes.gateway"
}

test_installer_installs_gateway_before_merging_hooks() {
  local tmp_home stub_bin launchctl_log output
  tmp_home="$(make_tmp_home)"
  write_hermes_stub "${tmp_home}" "*"
  stub_bin="${tmp_home}/stub-bin"
  launchctl_log="${tmp_home}/launchctl-calls.log"
  mkdir -p "${stub_bin}"

  cat > "${stub_bin}/launchctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${LAUNCHCTL_STUB_LOG}"
printf '\n' >> "${LAUNCHCTL_STUB_LOG}"
if [[ "$1" == "print" ]]; then
  printf 'state = running\n'
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
    HERMES_WEBHOOK_LIST_STATUS=1 \
    LAUNCHCTL_STUB_LOG="${launchctl_log}" \
    "${REPO_DIR}/scripts/install-macos-launchagent.sh"
  )"

  assert_contains "${output}" "Skipped webhook registration because Hermes webhook platform is not enabled"
  assert_file_contains "${tmp_home}/hermes-calls.log" "gateway install"
  assert_file_contains "${tmp_home}/hermes-calls.log" "gateway restart"
  assert_file_contains "${tmp_home}/.hermes/config.yaml" "hermes-gbrain-remember.sh"
  assert_file_contains "${tmp_home}/.hermes/config.yaml" "hermes-discord-feedback.sh"
  assert_file_contains "${tmp_home}/.hermes/shell-hooks-allowlist.json" "hermes-gbrain-remember.sh"
  assert_file_contains "${tmp_home}/.hermes/shell-hooks-allowlist.json" "hermes-discord-feedback.sh"
}

test_obsidian_mcp_setup_writes_read_write_config() {
  local tmp_home stub_bin vault config output
  tmp_home="$(mktemp -d)"
  stub_bin="${tmp_home}/bin"
  vault="${tmp_home}/Vault"
  config="${tmp_home}/config.yaml"
  mkdir -p "${stub_bin}" "${vault}/.obsidian"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${stub_bin}/npx"
  chmod +x "${stub_bin}/npx"
  cat > "${config}" <<'YAML'
model:
  provider: xai-oauth
YAML

  output="$(
    PATH="${stub_bin}:${PATH}" \
      "${REPO_DIR}/scripts/hermes-obsidian-mcp-setup.sh" \
        --vault "${vault}" \
        --config "${config}"
  )"

  assert_contains "${output}" "Configured Hermes MCP server 'obsidian'"
  assert_file_contains "${config}" "mcp_servers:"
  assert_file_contains "${config}" "obsidian:"
  assert_file_contains "${config}" "@modelcontextprotocol/server-filesystem"
  assert_file_contains "${config}" "${vault}"
  assert_file_contains "${config}" "write_file"
  assert_file_contains "${config}" "edit_file"
  assert_file_contains "${config}" "create_directory"
  assert_file_not_contains "${config}" "move_file"
  assert_file_not_contains "${config}" "delete"
  assert_file_contains "${config}" "provider: xai-oauth"
}

test_obsidian_mcp_setup_read_only_omits_write_tools() {
  local tmp_home stub_bin vault config
  tmp_home="$(mktemp -d)"
  stub_bin="${tmp_home}/bin"
  vault="${tmp_home}/Vault"
  config="${tmp_home}/config.yaml"
  mkdir -p "${stub_bin}" "${vault}/.obsidian"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${stub_bin}/npx"
  chmod +x "${stub_bin}/npx"

  PATH="${stub_bin}:${PATH}" \
    "${REPO_DIR}/scripts/hermes-obsidian-mcp-setup.sh" \
      --vault "${vault}" \
      --config "${config}" \
      --read-only >/dev/null

  assert_file_contains "${config}" "search_files"
  assert_file_contains "${config}" "read_text_file"
  assert_file_not_contains "${config}" "write_file"
  assert_file_not_contains "${config}" "edit_file"
  assert_file_not_contains "${config}" "create_directory"
}

test_jina_mcp_setup_writes_reader_only_config() {
  local tmp_home config output
  tmp_home="$(mktemp -d)"
  config="${tmp_home}/config.yaml"
  cat > "${config}" <<'YAML'
model:
  provider: xai-oauth
YAML

  output="$(
    "${REPO_DIR}/scripts/hermes-jina-mcp-setup.sh" \
      --config "${config}"
  )"

  assert_contains "${output}" "Configured Hermes MCP server 'jina_reader'"
  assert_contains "${output}" "Authorization header: none"
  assert_file_contains "${config}" "jina_reader:"
  assert_file_contains "${config}" "url: https://mcp.jina.ai/v1"
  assert_file_contains "${config}" "read_url"
  assert_file_contains "${config}" "parallel_read_url"
  assert_file_contains "${config}" "capture_screenshot_url"
  assert_file_contains "${config}" "search_jina_blog"
  assert_file_not_contains "${config}" "search_web"
  assert_file_not_contains "${config}" "sort_by_relevance"
  assert_file_not_contains "${config}" "Authorization"
  assert_file_contains "${config}" "provider: xai-oauth"
}

test_jina_mcp_setup_can_reference_api_key_env() {
  local tmp_home config
  tmp_home="$(mktemp -d)"
  config="${tmp_home}/config.yaml"

  "${REPO_DIR}/scripts/hermes-jina-mcp-setup.sh" \
    --config "${config}" \
    --api-key-env JINA_API_KEY >/dev/null

  assert_file_contains "${config}" "Authorization"
  assert_file_contains "${config}" 'Bearer ${JINA_API_KEY}'
}

test_google_calendar_mcp_setup_writes_read_only_oauth_config() {
  local tmp_home config helper_path output
  tmp_home="$(mktemp -d)"
  config="${tmp_home}/config.yaml"
  helper_path="${tmp_home}/google_api.py"
  cat > "${config}" <<'YAML'
model:
  provider: xai-oauth
YAML

  output="$(
    GOOGLE_CALENDAR_HELPER_PATH="${helper_path}" \
    "${REPO_DIR}/scripts/hermes-google-calendar-mcp-setup.sh" \
      --config "${config}"
  )"

  assert_contains "${output}" "Configured Hermes MCP server 'google_calendar'"
  assert_contains "${output}" "Morning brief Calendar helper installed:"
  assert_contains "${output}" "Mode: read-only Calendar tools"
  [[ -x "${helper_path}" ]] || fail "calendar helper should be executable"
  assert_file_contains "${helper_path}" 'os.environ.get("HERMES_GOOGLE_CALENDAR_MCP_SERVER", "google_calendar")'
  assert_file_contains "${config}" "google_calendar:"
  assert_file_contains "${config}" "url: https://calendarmcp.googleapis.com/mcp/v1"
  assert_file_contains "${config}" "auth: oauth"
  assert_file_contains "${config}" 'client_id: "${GOOGLE_CALENDAR_MCP_CLIENT_ID}"'
  assert_file_contains "${config}" 'client_secret: "${GOOGLE_CALENDAR_MCP_CLIENT_SECRET}"'
  assert_file_contains "${config}" "redirect_port: 0"
  assert_file_contains "${config}" "calendar.events.readonly"
  assert_file_contains "${config}" "list_calendars"
  assert_file_contains "${config}" "list_events"
  assert_file_contains "${config}" "get_event"
  assert_file_contains "${config}" "suggest_time"
  assert_file_not_contains "${config}" "create_event"
  assert_file_not_contains "${config}" "update_event"
  assert_file_not_contains "${config}" "delete_event"
  assert_file_contains "${config}" "provider: xai-oauth"
}

test_google_calendar_mcp_setup_can_enable_write_tools_and_public_client() {
  local tmp_home config helper_path
  tmp_home="$(mktemp -d)"
  config="${tmp_home}/config.yaml"
  helper_path="${tmp_home}/calendar_ro_api.py"

  GOOGLE_CALENDAR_HELPER_PATH="${helper_path}" \
    "${REPO_DIR}/scripts/hermes-google-calendar-mcp-setup.sh" \
      --config "${config}" \
      --name calendar_ro \
      --client-id-env CUSTOM_CALENDAR_CLIENT_ID \
      --public-client \
      --redirect-port 56122 \
      --allow-write >/dev/null

  [[ -x "${helper_path}" ]] || fail "calendar helper should be executable"
  assert_file_contains "${helper_path}" 'os.environ.get("HERMES_GOOGLE_CALENDAR_MCP_SERVER", "calendar_ro")'
  assert_file_contains "${config}" "calendar_ro:"
  assert_file_contains "${config}" 'client_id: "${CUSTOM_CALENDAR_CLIENT_ID}"'
  assert_file_not_contains "${config}" "client_secret"
  assert_file_contains "${config}" "redirect_port: 56122"
  assert_file_contains "${config}" "create_event"
  assert_file_contains "${config}" "update_event"
  assert_file_contains "${config}" "delete_event"
  assert_file_contains "${config}" "respond_to_event"
}

test_dreaming_cron_recomposes_memory_and_writes_report() {
  local tmp_home hermes_stub output report_file memory_file
  tmp_home="$(mktemp -d)"
  mkdir -p "${tmp_home}/.local/bin" "${tmp_home}/prompts" "${tmp_home}/state/digests" "${tmp_home}/state/evaluations" "${tmp_home}/state/user-feedback" "${tmp_home}/memories"
  hermes_stub="${tmp_home}/.local/bin/hermes"
  cat > "${hermes_stub}" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cat <<'DREAM'
# Dreaming Report

## 入力の要約
- 最近の明示指示と評価を確認した。

## 再合成した変化
- Zenn と wbsb.dev を技術記事ソースとして整理した。

## 矛盾解決
- AI偏重を避けつつ、必要なAI情報は一次情報で扱う。

## 次の観察テーマ
- 出典品質。

# ヘルメスちゃんの自己メモリ

## 私は誰か
- 名前はヘルメスちゃん。

## 好み
- 忘却ではなく再合成として記憶を更新する。

## 最近の学び
- Jina Readerで技術記事ソースを確認する。

## 避けたい癖
- 生ログをそのまま記憶に混ぜる。

## 次に改善すること
- 明示指示と最近の傾向を統合する。

## 見守るテーマ
- 記憶の再合成品質。

# 付録
- これは report だけに残る。
DREAM
STUB
  chmod +x "${hermes_stub}"

  cat > "${tmp_home}/prompts/nightly-dreaming.md" <<'PROMPT'
# Nightly Dreaming Recomposition
PROMPT
  cat > "${tmp_home}/prompts/hermes-chan-identity.md" <<'IDENTITY'
# Identity
IDENTITY
  cat > "${tmp_home}/state/hermes-chan-memory.md" <<'MEMORY'
# old memory
MEMORY
  cat > "${tmp_home}/state/evaluations/eval.md" <<'EVAL'
# eval
EVAL
  cat > "${tmp_home}/memories/MEMORY.md" <<'MEMORY'
source memory
MEMORY
  cat > "${tmp_home}/memories/USER.md" <<'USER'
source user
USER

  output="$(
    HOME="${tmp_home}" \
    HERMES_BIN="${hermes_stub}" \
    HERMES_PROMPT_DIR="${tmp_home}/prompts" \
    HERMES_STATE_DIR="${tmp_home}/state" \
    HERMES_LOG_DIR="${tmp_home}/logs" \
    HERMES_MEMORY_DIR="${tmp_home}/memories" \
    "${REPO_DIR}/scripts/hermes-dreaming-cron.sh"
  )"

  assert_contains "${output}" "nightly dreaming updated memory:"
  memory_file="${tmp_home}/state/hermes-chan-memory.md"
  assert_file_contains "${memory_file}" "# ヘルメスちゃんの自己メモリ"
  assert_file_contains "${memory_file}" "忘却ではなく再合成"
  assert_file_not_contains "${memory_file}" "# Dreaming Report"
  assert_file_not_contains "${memory_file}" "# 付録"
  report_file="$(find "${tmp_home}/state/dreaming" -type f -name '*.md' -print -quit)"
  [[ -n "${report_file}" ]] || fail "expected dreaming report"
  assert_file_contains "${report_file}" "# Dreaming Report"
  assert_file_contains "${report_file}" "# ヘルメスちゃんの自己メモリ"
  assert_file_contains "${report_file}" "# 付録"
}

test_review_cron_reports_gbrain_and_honcho_status() {
  local tmp_home hermes_stub output report_file
  tmp_home="$(mktemp -d)"
  mkdir -p "${tmp_home}/.local/bin" "${tmp_home}/state/digests" "${tmp_home}/state/evaluations" "${tmp_home}/logs"
  hermes_stub="${tmp_home}/.local/bin/hermes"
  cat > "${hermes_stub}" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "memory" && "${2:-}" == "status" ]]; then
  echo "Honcho: not configured"
  exit 0
fi
if [[ "${1:-}" == "-z" ]]; then
  cat <<'REVIEW'
daily-review

## 今日の更新
- gbrainとhonchoの状態を確認したよ。

## gbrain 状況
- gbrain binary は未検出。

## honcho 状況
- honcho は未設定。

## 明日の確認ポイント
- Honcho API key と config を設定するか確認。
REVIEW
  exit 0
fi
echo "unexpected hermes call: $*" >&2
exit 64
STUB
  chmod +x "${hermes_stub}"

  output="$(
    HOME="${tmp_home}" \
    HERMES_BIN="${hermes_stub}" \
    HERMES_STATE_DIR="${tmp_home}/state" \
    HERMES_LOG_DIR="${tmp_home}/logs" \
    "${REPO_DIR}/scripts/hermes-review-cron.sh" --daily
  )"

  assert_contains "${output}" "daily-review"
  assert_contains "${output}" "honcho は未設定"
  report_file="$(find "${tmp_home}/state/reviews/daily" -type f -name '*.md' -print -quit)"
  [[ -n "${report_file}" ]] || fail "expected daily review report"
  assert_file_contains "${report_file}" "gbrain"
  assert_file_contains "${report_file}" "honcho"
}

test_review_cron_finds_bun_for_gbrain() {
  local tmp_home hermes_stub output
  tmp_home="$(mktemp -d)"
  mkdir -p "${tmp_home}/.local/bin" "${tmp_home}/.bun/bin" "${tmp_home}/.hermes/brain" "${tmp_home}/state" "${tmp_home}/logs"
  hermes_stub="${tmp_home}/.local/bin/hermes"
  cat > "${tmp_home}/.bun/bin/bun" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "gbrain list ok"
STUB
  chmod +x "${tmp_home}/.bun/bin/bun"
  cat > "${tmp_home}/.bun/bin/gbrain" <<'STUB'
#!/usr/bin/env bun
STUB
  chmod +x "${tmp_home}/.bun/bin/gbrain"
  cat > "${hermes_stub}" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "memory" && "${2:-}" == "status" ]]; then
  echo "Honcho: not configured"
  exit 0
fi
if [[ "${1:-}" == "-z" ]]; then
  printf '%s\n' "${2:-}"
  exit 0
fi
echo "unexpected hermes call: $*" >&2
exit 64
STUB
  chmod +x "${hermes_stub}"

  output="$(
    env -i \
      HOME="${tmp_home}" \
      PATH="${tmp_home}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      HERMES_BIN="${hermes_stub}" \
      HERMES_PROMPT_DIR="${REPO_DIR}/prompts" \
      HERMES_STATE_DIR="${tmp_home}/state" \
      HERMES_LOG_DIR="${tmp_home}/logs" \
      "${REPO_DIR}/scripts/hermes-review-cron.sh" --daily
  )"

  assert_contains "${output}" "gbrain list ok"
  assert_contains "${output}" "# Posting style"
  assert_contains "${output}" "ヘルメスちゃんが届けている"
}

test_scheduled_prompts_require_direct_source_links() {
  assert_file_contains "${REPO_DIR}/prompts/x-daily-summary.md" "handle だけの出典は不可"
  assert_file_contains "${REPO_DIR}/prompts/x-daily-summary.md" "Google の検索結果 URL ではなく"
  assert_file_contains "${REPO_DIR}/prompts/tech-digest.md" "参照ページ: <direct URL>"
  assert_file_contains "${REPO_DIR}/prompts/tech-digest.md" "Use a soft traction gate"
  assert_file_contains "${REPO_DIR}/prompts/tech-digest.md" "反応: <likes/reposts/replies/quotes/views"
  assert_file_contains "${REPO_DIR}/prompts/tech-digest.md" "Posting Style"
  assert_file_contains "${REPO_DIR}/prompts/hermes-post-style.md" "ヘルメスちゃんが届けている"
  assert_file_contains "${REPO_DIR}/config/x-pulse-watchers.json" '"min_likes_early": 100'
  assert_file_contains "${REPO_DIR}/config/x-pulse-watchers.json" '"min_views_early": 10000'
  assert_file_contains "${REPO_DIR}/config/hermes-cronjobs.json" '"script": "hermes-morning-brief-cron.sh"'
  assert_file_contains "${REPO_DIR}/scripts/hermes-morning-brief-cron.sh" "DEFAULT_GENERAL_FEEDS"
  assert_file_contains "${REPO_DIR}/scripts/hermes-morning-brief-cron.sh" "DEFAULT_TECH_FEEDS"
  assert_file_contains "${REPO_DIR}/scripts/hermes-morning-brief-cron.sh" "出典:"
  assert_file_contains "${REPO_DIR}/config/hermes-cronjobs.json" '"x-buzz-info": "discord:1514063902529556491"'
  assert_file_contains "${REPO_DIR}/config/hermes-cronjobs.json" '"zenn-dev-info": "discord:1513332081806147724"'
  assert_file_contains "${REPO_DIR}/config/hermes-cronjobs.json" '"wbsb-dev-info": "discord:1514063970368229447"'
  assert_file_contains "${REPO_DIR}/config/hermes-cronjobs.json" '"tech-signals": "discord:1514063816093335653"'
  assert_file_contains "${REPO_DIR}/README.md" "Hermes channel routing is organized by what readers expect"
  assert_file_contains "${REPO_DIR}/README.md" '`#zenn-dev-info`'
  assert_file_contains "${REPO_DIR}/docs/scheduled-jobs.md" "Google/Web-derived items must include the original page URL"
  assert_file_contains "${REPO_DIR}/config/hermes-webhooks.json" '"name": "signal-catchup"'
  assert_file_contains "${REPO_DIR}/config/hermes-webhooks.json" '"channel": "tech-signals"'
  assert_file_contains "${REPO_DIR}/config/hermes-webhooks.json" '"name": "tech-digest-trigger"'
  assert_file_contains "${REPO_DIR}/config/hermes-webhooks.json" '"name": "x-buzz-trigger"'
  assert_file_contains "${REPO_DIR}/config/hermes-webhooks.json" '"channel": "x-buzz-info"'
  assert_file_contains "${REPO_DIR}/config/hermes-webhooks.json" "full tech digest ではありません"
  assert_file_contains "${REPO_DIR}/config/hermes-webhooks.json" '"name": "zenn-dev-trigger"'
  assert_file_contains "${REPO_DIR}/config/hermes-webhooks.json" '"channel": "zenn-dev-info"'
  assert_file_contains "${REPO_DIR}/config/hermes-webhooks.json" '"name": "wbsb-trigger"'
  assert_file_contains "${REPO_DIR}/config/hermes-webhooks.json" '"channel": "wbsb-dev-info"'
  assert_file_contains "${REPO_DIR}/config/hermes-webhooks.json" "ヘルメスちゃんが届けている"
  assert_file_contains "${REPO_DIR}/config/hermes-webhooks.json" "ヘルメスちゃんです"
  assert_file_contains "${REPO_DIR}/config/hermes-webhooks.json" '"replaces_cron_jobs"'
  assert_file_contains "${REPO_DIR}/config/signal-watchers.json" '"id": "zenn-trending"'
  assert_file_contains "${REPO_DIR}/config/signal-watchers.json" '"id": "wbsb-feed"'
  assert_file_contains "${REPO_DIR}/docs/scheduled-jobs.md" "Hermes' webhook platform"
  assert_file_contains "${REPO_DIR}/config/hermes-channels.example.json" '"tech-digest"'
}

test_register_webhooks_preserves_existing_secret() {
  local tmp_home output log_file
  tmp_home="$(make_tmp_home)"
  write_hermes_stub "${tmp_home}" ""
  log_file="${tmp_home}/hermes-calls.log"
  mkdir -p "${tmp_home}/.hermes"
  cat > "${tmp_home}/.hermes/.env" <<'ENV'
HERMES_POST_TRIGGER_WEBHOOK_SECRET=post-secret-from-env-file
ENV
  cat > "${tmp_home}/.hermes/webhook_subscriptions.json" <<'JSON'
{
  "signal-catchup": {
    "secret": "existing-secret"
  }
}
JSON

  output="$(
    HOME="${tmp_home}" \
    HERMES_BIN="${tmp_home}/.local/bin/hermes" \
    HERMES_STUB_LOG="${HERMES_STUB_LOG}" \
    "${REPO_DIR}/scripts/register-hermes-webhooks.sh"
  )"

  assert_contains "${output}" "Synced existing webhook: signal-catchup"
  assert_contains "${output}" "Created webhook: tech-digest-trigger"
  assert_contains "${output}" "Created webhook: x-buzz-trigger"
  assert_contains "${output}" "Created webhook: zenn-dev-trigger"
  assert_contains "${output}" "Created webhook: wbsb-trigger"
  assert_contains "${output}" "Created webhook: nightly-dreaming-trigger"
  assert_contains "${output}" "Skipped disabled webhook: morning-brief-trigger"
  assert_contains "${output}" "Skipped disabled webhook: gbrain-weekly-summary-trigger"
  assert_contains "${output}" "Webhook registration complete: 5 created, 1 updated, 2 disabled, 0 removed."
  assert_file_contains "${log_file}" "webhook subscribe signal-catchup"
  assert_file_contains "${log_file}" "webhook subscribe tech-digest-trigger"
  assert_file_contains "${log_file}" "webhook subscribe x-buzz-trigger"
  assert_file_contains "${log_file}" "webhook subscribe zenn-dev-trigger"
  assert_file_contains "${log_file}" "webhook subscribe wbsb-trigger"
  assert_file_contains "${log_file}" "hermes-tech-digest-cron.sh"
  assert_file_contains "${log_file}" "script_path="
  assert_file_contains "${log_file}" "SCRIPT_UNAVAILABLE"
  assert_file_contains "${log_file}" 'bash "${script_path}"'
  assert_file_contains "${log_file}" "--deliver discord --deliver-chat-id 1510425425971515503"
  assert_file_contains "${log_file}" "--deliver discord --deliver-chat-id 1514063902529556491"
  assert_file_contains "${log_file}" "--deliver discord --deliver-chat-id 1513332081806147724"
  assert_file_contains "${log_file}" "--deliver discord --deliver-chat-id 1514063970368229447"
  assert_file_contains "${log_file}" "--deliver discord --deliver-chat-id 1514063816093335653"
  assert_file_contains "${log_file}" "--secret existing-secret"
  assert_file_contains "${log_file}" "--secret post-secret-from-env-file"
}

test_register_webhooks_uses_local_channel_overrides() {
  local tmp_home channels output log_file
  tmp_home="$(make_tmp_home)"
  write_hermes_stub "${tmp_home}" ""
  log_file="${tmp_home}/hermes-calls.log"
  channels="${tmp_home}/channels.json"
  mkdir -p "${tmp_home}/.hermes"
  cat > "${tmp_home}/.hermes/.env" <<'ENV'
HERMES_SIGNAL_CATCHUP_WEBHOOK_SECRET=signal-secret-from-env-file
HERMES_POST_TRIGGER_WEBHOOK_SECRET=post-secret-from-env-file
ENV
  cat > "${channels}" <<'JSON'
{
  "version": 1,
  "channels": {
    "x-buzz-info": "discord:888888888888888888"
  }
}
JSON

  output="$(
    HOME="${tmp_home}" \
    HERMES_BIN="${tmp_home}/.local/bin/hermes" \
    HERMES_STUB_LOG="${HERMES_STUB_LOG}" \
    HERMES_CHANNELS_CONFIG="${channels}" \
    "${REPO_DIR}/scripts/register-hermes-webhooks.sh"
  )"

  assert_contains "${output}" "Created webhook: x-buzz-trigger"
  assert_file_contains "${log_file}" "webhook subscribe x-buzz-trigger"
  assert_file_contains "${log_file}" "--deliver-chat-id 888888888888888888"
  assert_file_contains "${log_file}" "webhook subscribe signal-catchup"
  assert_file_contains "${log_file}" "--deliver-chat-id 1514063816093335653"
}

test_register_webhooks_rejects_script_names_outside_runtime_cron_pattern() {
  local tmp_home webhooks_config cron_config output status
  tmp_home="$(make_tmp_home)"
  write_hermes_stub "${tmp_home}" ""
  webhooks_config="${tmp_home}/webhooks.json"
  cron_config="${tmp_home}/cronjobs.json"
  cat > "${cron_config}" <<'JSON'
{
  "version": 1,
  "channels": {
    "tech-signals": "discord:123"
  },
  "jobs": []
}
JSON
  cat > "${webhooks_config}" <<'JSON'
{
  "version": 1,
  "subscriptions": [
    {
      "name": "bad-script-trigger",
      "enabled": true,
      "channel": "tech-signals",
      "mode": "script",
      "script": "example-script-job.sh",
      "prompt": "",
      "events": [],
      "skills": []
    }
  ]
}
JSON

  set +e
  output="$(
    HOME="${tmp_home}" \
    HERMES_BIN="${tmp_home}/.local/bin/hermes" \
    HERMES_STUB_LOG="${HERMES_STUB_LOG}" \
    HERMES_WEBHOOKS_CONFIG="${webhooks_config}" \
    HERMES_CRONJOBS_CONFIG="${cron_config}" \
    "${REPO_DIR}/scripts/register-hermes-webhooks.sh" 2>&1
  )"
  status=$?
  set -e

  [[ "${status}" -ne 0 ]] || fail "expected non-cron script-mode webhook to fail"
  assert_contains "${output}" "must match scripts/*-cron.sh"
}

test_posting_admin_escapes_test_payload_and_rejects_unknown_routes() {
  local tmp_home tmp_repo hermes_stub webhook_log output status
  tmp_home="$(make_tmp_home)"
  tmp_repo="${tmp_home}/repo"
  webhook_log="${tmp_home}/webhook-payloads.log"
  mkdir -p "${tmp_repo}/config"
  cp "${REPO_DIR}/config/hermes-cronjobs.json" "${tmp_repo}/config/hermes-cronjobs.json"
  cp "${REPO_DIR}/config/hermes-webhooks.json" "${tmp_repo}/config/hermes-webhooks.json"
  cp "${REPO_DIR}/config/signal-watchers.json" "${tmp_repo}/config/signal-watchers.json"
  cp "${REPO_DIR}/config/x-pulse-watchers.json" "${tmp_repo}/config/x-pulse-watchers.json"
  hermes_stub="${tmp_home}/.local/bin/hermes"
  cat > "${hermes_stub}" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "webhook" && "$2" == "test" ]]; then
  [[ "$4" == "--payload" ]] || exit 64
  printf '%s\n%s\n' "$3" "$5" >> "${HERMES_TEST_WEBHOOK_LOG}"
  jq -e . >/dev/null <<< "$5"
  exit 0
fi
exit 0
STUB
  chmod +x "${hermes_stub}"

  output="$(
    HOME="${tmp_home}" \
    HERMES_BIN="${hermes_stub}" \
    HERMES_POSTING_REPO="${tmp_repo}" \
    HERMES_TEST_WEBHOOK_LOG="${webhook_log}" \
    "${REPO_DIR}/scripts/hermes-posting-admin.sh" test-webhooks 'quote"route'
  )"

  [[ -z "${output}" ]] || fail "posting admin test-webhooks should be quiet on success"
  assert_file_contains "${webhook_log}" 'quote"route'
  assert_eq "$(sed -n '2p' "${webhook_log}" | jq -r '.route')" 'quote"route' "test webhook route"

  set +e
  output="$(
    HOME="${tmp_home}" \
    HERMES_BIN="${hermes_stub}" \
    HERMES_POSTING_REPO="${tmp_repo}" \
    "${REPO_DIR}/scripts/hermes-posting-admin.sh" set-source-route zenn-trending missing-route 2>&1
  )"
  status=$?
  set -e

  [[ "${status}" -ne 0 ]] || fail "expected unknown route update to fail"
  assert_contains "${output}" "unknown enabled webhook route: missing-route"
  assert_file_not_contains "${tmp_repo}/config/signal-watchers.json" "missing-route"
}

test_signal_watcher_scores_local_feed() {
  local tmp_home feed config output
  tmp_home="$(mktemp -d)"
  feed="${tmp_home}/feed.xml"
  config="${tmp_home}/watchers.json"
  cat > "${feed}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Local Feed</title>
    <item>
      <title>Claude Code agent security release</title>
      <link>https://example.com/agent-security</link>
      <guid>agent-security</guid>
      <description>AI agent security and MCP release notes.</description>
      <pubDate>Sun, 07 Jun 2026 10:15:27 GMT</pubDate>
    </item>
    <item>
      <title>Unrelated gardening note</title>
      <link>https://example.com/garden</link>
      <guid>garden</guid>
      <description>not technical</description>
    </item>
  </channel>
</rss>
XML
  cat > "${config}" <<JSON
{
  "version": 1,
  "settings": {
    "state_file": "${tmp_home}/state.json",
    "log_file": "${tmp_home}/watcher.log",
    "prime_only_on_first_run": true,
    "source_timeout_seconds": 5,
    "max_items_per_source": 10,
    "default_min_score": 70,
    "default_cooldown_minutes": 90,
    "default_webhook_base_url": "http://127.0.0.1:8644",
    "secret_env": "HERMES_SIGNAL_CATCHUP_WEBHOOK_SECRET",
    "post_trigger_secret_env": "HERMES_POST_TRIGGER_WEBHOOK_SECRET"
  },
  "keyword_weights": {
    "agent": 30,
    "security": 25,
    "mcp": 20,
    "release": 15
  },
  "sources": [
    {
      "id": "local-feed",
      "enabled": true,
      "type": "feed",
      "url": "file://${feed}",
      "base_score": 20,
      "min_score": 70,
      "route": "signal-catchup",
      "tags": ["test"]
    }
  ]
}
JSON

  output="$("${REPO_DIR}/scripts/hermes-signal-watcher.py" --config "${config}" --dry-run --allow-first-run-send)"

  assert_json_eq "${output}" ".observed" "2"
  assert_json_eq "${output}" ".candidates" "1"
  assert_json_eq "${output}" ".dry_run" "true"
}

test_signal_watcher_reads_env_file_for_secret() {
  local tmp_home feed config env_file output log_file alert_script alert_log
  tmp_home="$(mktemp -d)"
  feed="${tmp_home}/feed.xml"
  config="${tmp_home}/watchers.json"
  env_file="${tmp_home}/.env"
  log_file="${tmp_home}/watcher.log"
  alert_script="${tmp_home}/alert.sh"
  alert_log="${tmp_home}/alerts.log"
  cat > "${alert_script}" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${HERMES_TEST_ALERT_LOG}"
cat >> "${HERMES_TEST_ALERT_LOG}"
SH
  chmod +x "${alert_script}"
  cat > "${env_file}" <<'ENV'
HERMES_SIGNAL_CATCHUP_WEBHOOK_SECRET=signal-secret-from-env-file
ENV
  cat > "${feed}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Local Feed</title>
    <item>
      <title>AI agent MCP release</title>
      <link>https://example.com/agent-release</link>
      <guid>agent-release</guid>
      <description>MCP release for AI agents.</description>
    </item>
  </channel>
</rss>
XML
  cat > "${config}" <<JSON
{
  "version": 1,
  "settings": {
    "state_file": "${tmp_home}/state.json",
    "log_file": "${log_file}",
    "env_file": "${env_file}",
    "prime_only_on_first_run": false,
    "source_timeout_seconds": 5,
    "max_items_per_source": 10,
    "default_min_score": 70,
    "default_cooldown_minutes": 90,
    "default_webhook_base_url": "http://127.0.0.1:1",
    "secret_env": "HERMES_SIGNAL_CATCHUP_WEBHOOK_SECRET",
    "post_trigger_secret_env": "HERMES_POST_TRIGGER_WEBHOOK_SECRET"
  },
  "keyword_weights": {
    "agent": 30,
    "mcp": 20,
    "release": 15
  },
  "sources": [
    {
      "id": "local-feed",
      "enabled": true,
      "type": "feed",
      "url": "file://${feed}",
      "base_score": 30,
      "min_score": 70,
      "route": "signal-catchup",
      "tags": ["test"]
    }
  ]
}
JSON

  output="$(
    HERMES_ALERT_SCRIPT="${alert_script}" \
    HERMES_TEST_ALERT_LOG="${alert_log}" \
    "${REPO_DIR}/scripts/hermes-signal-watcher.py" --config "${config}" --allow-first-run-send
  )"

  assert_json_eq "${output}" ".candidates" "1"
  assert_json_eq "${output}" ".sent" "0"
  assert_file_contains "${log_file}" "send failed route=signal-catchup"
  assert_file_not_contains "${log_file}" "missing secret env"
  assert_file_contains "${alert_log}" "Hermes signal watcher webhook send failed"
}

test_signal_watcher_parses_nested_html_links() {
  local tmp_home page config output
  tmp_home="$(mktemp -d)"
  page="${tmp_home}/page.html"
  config="${tmp_home}/watchers.json"
  cat > "${page}" <<'HTML'
<!doctype html>
<html>
  <body>
    <a data-kind="article" href="/articles/agent-mcp">
      <span>Claude Code <strong>MCP</strong> release</span>
    </a>
    <a href=/articles/browser-security><span>Browser security update</span></a>
  </body>
</html>
HTML
  cat > "${config}" <<JSON
{
  "version": 1,
  "settings": {
    "state_file": "${tmp_home}/state.json",
    "log_file": "${tmp_home}/watcher.log",
    "prime_only_on_first_run": false,
    "source_timeout_seconds": 5,
    "max_items_per_source": 10,
    "default_min_score": 50,
    "default_cooldown_minutes": 90,
    "default_webhook_base_url": "http://127.0.0.1:8644",
    "secret_env": "HERMES_SIGNAL_CATCHUP_WEBHOOK_SECRET",
    "post_trigger_secret_env": "HERMES_POST_TRIGGER_WEBHOOK_SECRET"
  },
  "keyword_weights": {
    "claude code": 30,
    "mcp": 20,
    "security": 25
  },
  "sources": [
    {
      "id": "html-source",
      "enabled": true,
      "type": "html_links",
      "url": "file://${page}",
      "base_score": 25,
      "min_score": 50,
      "route": "signal-catchup",
      "include_url_patterns": ["/articles/"],
      "tags": ["test"]
    }
  ]
}
JSON

  output="$("${REPO_DIR}/scripts/hermes-signal-watcher.py" --config "${config}" --dry-run --allow-first-run-send)"

  assert_json_eq "${output}" ".observed" "2"
  assert_json_eq "${output}" ".candidates" "2"
  assert_file_contains "${tmp_home}/watcher.log" "dry-run route=signal-catchup candidates=2"
}

test_signal_watcher_tracks_standalone_document_hash_changes() {
  local tmp_home document config state log_file output seen_count
  tmp_home="$(mktemp -d)"
  document="${tmp_home}/codex-whitepaper.pdf"
  config="${tmp_home}/watchers.json"
  state="${tmp_home}/state.json"
  log_file="${tmp_home}/watcher.log"
  printf '%s\n' '%PDF-1.7 test codex whitepaper v1' > "${document}"
  cat > "${config}" <<JSON
{
  "version": 1,
  "settings": {
    "state_file": "${state}",
    "log_file": "${log_file}",
    "prime_only_on_first_run": true,
    "source_timeout_seconds": 5,
    "max_items_per_source": 10,
    "default_min_score": 70,
    "default_cooldown_minutes": 90,
    "default_webhook_base_url": "http://127.0.0.1:8644",
    "secret_env": "HERMES_SIGNAL_CATCHUP_WEBHOOK_SECRET",
    "post_trigger_secret_env": "HERMES_POST_TRIGGER_WEBHOOK_SECRET"
  },
  "keyword_weights": {
    "openai": 22,
    "codex": 28,
    "whitepaper": 12
  },
  "sources": [
    {
      "id": "local-document",
      "enabled": true,
      "type": "document",
      "url": "file://${document}",
      "title": "OpenAI Codex maxxing whitepaper",
      "description": "Standalone OpenAI Codex whitepaper PDF.",
      "content_type": "application/pdf",
      "base_score": 30,
      "min_score": 70,
      "route": "signal-catchup",
      "tags": ["openai", "codex", "whitepaper", "pdf"]
    }
  ]
}
JSON

  output="$("${REPO_DIR}/scripts/hermes-signal-watcher.py" --config "${config}")"
  seen_count="$(jq -r '.seen | length' "${state}")"

  assert_json_eq "${output}" ".observed" "1"
  assert_json_eq "${output}" ".candidates" "1"
  assert_json_eq "${output}" ".sent" "0"
  assert_json_eq "${output}" ".prime_only" "true"
  assert_eq "${seen_count}" "1" "seen_count"
  assert_file_contains "${log_file}" "primed 1 observed items; no webhook sent"

  output="$("${REPO_DIR}/scripts/hermes-signal-watcher.py" --config "${config}" --dry-run)"
  assert_json_eq "${output}" ".observed" "1"
  assert_json_eq "${output}" ".candidates" "0"

  printf '%s\n' 'updated document bytes' >> "${document}"
  output="$("${REPO_DIR}/scripts/hermes-signal-watcher.py" --config "${config}" --dry-run)"

  assert_json_eq "${output}" ".observed" "1"
  assert_json_eq "${output}" ".candidates" "1"
}

test_signal_watcher_retries_candidates_blocked_by_cooldown() {
  local tmp_home feed config state output log_file seen_count
  tmp_home="$(mktemp -d)"
  feed="${tmp_home}/feed.xml"
  config="${tmp_home}/watchers.json"
  state="${tmp_home}/state.json"
  log_file="${tmp_home}/watcher.log"
  cat > "${state}" <<'JSON'
{
  "initialized": true,
  "seen": {},
  "sent": {},
  "runs": [],
  "last_sent_routes": {
    "signal-catchup": 9999999999
  }
}
JSON
  cat > "${feed}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Local Feed</title>
    <item>
      <title>Claude Code agent MCP release</title>
      <link>https://example.com/retry-candidate</link>
      <guid>retry-candidate</guid>
      <description>Agent release with MCP notes.</description>
    </item>
  </channel>
</rss>
XML
  cat > "${config}" <<JSON
{
  "version": 1,
  "settings": {
    "state_file": "${state}",
    "log_file": "${log_file}",
    "prime_only_on_first_run": false,
    "source_timeout_seconds": 5,
    "max_items_per_source": 10,
    "default_min_score": 70,
    "default_cooldown_minutes": 90,
    "default_webhook_base_url": "http://127.0.0.1:1",
    "secret_env": "HERMES_SIGNAL_CATCHUP_WEBHOOK_SECRET",
    "post_trigger_secret_env": "HERMES_POST_TRIGGER_WEBHOOK_SECRET"
  },
  "keyword_weights": {
    "agent": 30,
    "mcp": 20,
    "release": 15,
    "claude code": 30
  },
  "sources": [
    {
      "id": "local-feed",
      "enabled": true,
      "type": "feed",
      "url": "file://${feed}",
      "base_score": 20,
      "min_score": 70,
      "route": "signal-catchup",
      "tags": ["test"]
    }
  ]
}
JSON

  output="$("${REPO_DIR}/scripts/hermes-signal-watcher.py" --config "${config}")"
  seen_count="$(jq -r '.seen | length' "${state}")"

  assert_json_eq "${output}" ".candidates" "1"
  assert_json_eq "${output}" ".sent" "0"
  assert_eq "${seen_count}" "0" "seen_count"
  assert_file_contains "${log_file}" "cooldown route=signal-catchup candidates=1"
}

test_signal_watcher_keeps_custom_routes_out_of_batch() {
  local tmp_home default_feed zenn_feed config log_file output
  tmp_home="$(mktemp -d)"
  default_feed="${tmp_home}/default-feed.xml"
  zenn_feed="${tmp_home}/zenn-feed.xml"
  config="${tmp_home}/watchers.json"
  log_file="${tmp_home}/watcher.log"
  cat > "${default_feed}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Default Feed</title>
    <item>
      <title>Claude Code agent MCP release one</title>
      <link>https://example.com/default-one</link>
      <guid>default-one</guid>
      <description>Agent release with MCP notes.</description>
    </item>
    <item>
      <title>Claude Code agent MCP release two</title>
      <link>https://example.com/default-two</link>
      <guid>default-two</guid>
      <description>Agent release with MCP notes.</description>
    </item>
  </channel>
</rss>
XML
  cat > "${zenn_feed}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Zenn Feed</title>
    <item>
      <title>Zenn Claude Code MCP article</title>
      <link>https://zenn.dev/example/articles/custom-route</link>
      <guid>zenn-one</guid>
      <description>Agent article with MCP notes.</description>
    </item>
  </channel>
</rss>
XML
  cat > "${config}" <<JSON
{
  "version": 1,
  "settings": {
    "state_file": "${tmp_home}/state.json",
    "log_file": "${log_file}",
    "prime_only_on_first_run": false,
    "source_timeout_seconds": 5,
    "max_items_per_source": 10,
    "default_min_score": 70,
    "default_cooldown_minutes": 90,
    "default_webhook_base_url": "http://127.0.0.1:8644",
    "secret_env": "HERMES_SIGNAL_CATCHUP_WEBHOOK_SECRET",
    "post_trigger_secret_env": "HERMES_POST_TRIGGER_WEBHOOK_SECRET",
    "batch_min_items": 2,
    "batch_min_score": 100,
    "batch_route": "tech-digest-trigger",
    "default_route": "signal-catchup"
  },
  "keyword_weights": {
    "agent": 30,
    "mcp": 20,
    "claude code": 30
  },
  "sources": [
    {
      "id": "default-feed",
      "enabled": true,
      "type": "feed",
      "url": "file://${default_feed}",
      "base_score": 20,
      "min_score": 70,
      "route": "signal-catchup",
      "tags": ["test"]
    },
    {
      "id": "zenn-feed",
      "enabled": true,
      "type": "feed",
      "url": "file://${zenn_feed}",
      "base_score": 20,
      "min_score": 70,
      "route": "zenn-dev-trigger",
      "tags": ["zenn"]
    }
  ]
}
JSON

  output="$("${REPO_DIR}/scripts/hermes-signal-watcher.py" --config "${config}" --dry-run --allow-first-run-send)"

  assert_json_eq "${output}" ".candidates" "3"
  assert_file_contains "${log_file}" "dry-run route=tech-digest-trigger candidates=2"
  assert_file_contains "${log_file}" "dry-run route=zenn-dev-trigger candidates=1"
  assert_file_not_contains "${log_file}" "dry-run route=tech-digest-trigger candidates=3"
}

test_x_pulse_watcher_primes_sample_urls() {
  local tmp_home sample config state output seen_count
  tmp_home="$(mktemp -d)"
  sample="${tmp_home}/x-sample.txt"
  config="${tmp_home}/x-pulse.json"
  state="${tmp_home}/state.json"
  cat > "${sample}" <<'SAMPLE'
pulse summary
CANDIDATE
topic: Official agent release
url: https://x.com/devrel/status/10001
posted_minutes_ago: 35
likes: 42
reposts: 8
replies: 4
quotes: 3
views: 12000
account_type: official
independent_posts: 2
reason: official release with early engagement

CANDIDATE
topic: Browser security update
url: https://x.com/browser/status/10006
posted_minutes_ago: 80
likes: 140
reposts: 18
replies: 12
quotes: 9
views: 18000
account_type: notable
independent_posts: 3
reason: developer-impacting security update
SAMPLE
  cat > "${config}" <<JSON
{
  "version": 1,
  "settings": {
    "state_file": "${state}",
    "log_file": "${tmp_home}/x-pulse.log",
    "prime_only_on_first_run": true,
    "route": "x-buzz-trigger",
    "cooldown_minutes": 90,
    "min_qualified_urls": 1,
    "min_qualified_score": 40
  },
  "queries": ["AI agents"]
}
JSON

  output="$("${REPO_DIR}/scripts/hermes-x-pulse-watcher.py" --config "${config}" --sample-file "${sample}")"
  seen_count="$(jq -r '.seen_urls | length' "${state}")"

  assert_json_eq "${output}" ".total_urls" "2"
  assert_json_eq "${output}" ".sent" "0"
  assert_json_eq "${output}" ".prime_only" "true"
  assert_eq "${seen_count}" "2" "seen_count"
}

test_x_pulse_watcher_detects_sample_pulse() {
  local tmp_home sample config state output
  tmp_home="$(mktemp -d)"
  sample="${tmp_home}/x-sample.txt"
  config="${tmp_home}/x-pulse.json"
  state="${tmp_home}/state.json"
  cat > "${state}" <<'JSON'
{
  "initialized": true,
  "seen_urls": {
    "https://x.com/devrel/status/10001": {
      "first_seen_at": "2026-06-08T00:00:00+00:00"
    }
  },
  "sent": {},
  "runs": []
}
JSON
  cat > "${sample}" <<'SAMPLE'
high signal
CANDIDATE
topic: Official agent release
url: https://x.com/devrel/status/10001
posted_minutes_ago: 35
likes: 42
reposts: 8
replies: 4
quotes: 3
views: 12000
account_type: official
independent_posts: 2
reason: already seen official release

CANDIDATE
topic: Browser security update
url: https://twitter.com/webdev/status/10003
posted_minutes_ago: 75
likes: 1,234
reposts: 1
replies: 2
quotes: 1
views: 12K
account_type: notable
independent_posts: 3
reason: browser security update with early engagement

CANDIDATE
topic: Thin link repost
url: https://x.com/security/status/10004
posted_minutes_ago: 40
likes: 2
reposts: 0
replies: 0
quotes: 0
views: 0
account_type: general
independent_posts: 1
reason: low engagement link repost
SAMPLE
  cat > "${config}" <<JSON
{
  "version": 1,
  "settings": {
    "state_file": "${state}",
    "log_file": "${tmp_home}/x-pulse.log",
    "prime_only_on_first_run": true,
    "route": "x-buzz-trigger",
    "cooldown_minutes": 90,
    "min_qualified_urls": 1,
    "min_qualified_score": 40
  },
  "queries": ["AI agents"]
}
JSON

  output="$("${REPO_DIR}/scripts/hermes-x-pulse-watcher.py" --config "${config}" --sample-file "${sample}" --dry-run)"

  assert_json_eq "${output}" ".total_urls" "3"
  assert_json_eq "${output}" ".new_urls" "1"
  assert_json_eq "${output}" ".candidate_count" "3"
  assert_json_eq "${output}" ".qualified_count" "1"
  assert_json_eq "${output}" ".should_trigger" "true"
  assert_json_eq "${output}" ".dry_run" "true"
}

test_x_pulse_watcher_rejects_low_engagement_url_bundle() {
  local tmp_home sample config state output
  tmp_home="$(mktemp -d)"
  sample="${tmp_home}/x-sample.txt"
  config="${tmp_home}/x-pulse.json"
  state="${tmp_home}/state.json"
  cat > "${state}" <<'JSON'
{
  "initialized": true,
  "seen_urls": {},
  "sent": {},
  "runs": []
}
JSON
  cat > "${sample}" <<'SAMPLE'
CANDIDATE
topic: Thin post one
url: https://x.com/thin1/status/10001
posted_minutes_ago: 20
likes: 3
reposts: 0
replies: 0
quotes: 0
views: 0
account_type: general
independent_posts: 5
reason: low engagement

CANDIDATE
topic: Thin post two
url: https://x.com/thin2/status/10002
posted_minutes_ago: 25
likes: 2
reposts: 0
replies: 0
quotes: 0
views: 0
account_type: general
independent_posts: 5
reason: low engagement

CANDIDATE
topic: Thin post three
url: https://x.com/thin3/status/10003
posted_minutes_ago: 30
likes: 1
reposts: 0
replies: 0
quotes: 0
views: 0
account_type: general
independent_posts: 5
reason: low engagement

CANDIDATE
topic: Thin post four
url: https://x.com/thin4/status/10004
posted_minutes_ago: 35
likes: 4
reposts: 0
replies: 0
quotes: 0
views: 0
account_type: general
independent_posts: 5
reason: low engagement
SAMPLE
  cat > "${config}" <<JSON
{
  "version": 1,
  "settings": {
    "state_file": "${state}",
    "log_file": "${tmp_home}/x-pulse.log",
    "prime_only_on_first_run": true,
    "route": "x-buzz-trigger",
    "min_qualified_urls": 1,
    "min_qualified_score": 40
  },
  "queries": ["AI agents"]
}
JSON

  output="$("${REPO_DIR}/scripts/hermes-x-pulse-watcher.py" --config "${config}" --sample-file "${sample}" --dry-run)"

  assert_json_eq "${output}" ".total_urls" "4"
  assert_json_eq "${output}" ".candidate_count" "4"
  assert_json_eq "${output}" ".qualified_count" "0"
  assert_json_eq "${output}" ".should_trigger" "false"
}

test_x_pulse_watcher_treats_search_failure_as_nonfatal() {
  local tmp_home config output status alert_script alert_log
  tmp_home="$(mktemp -d)"
  config="${tmp_home}/x-pulse.json"
  alert_script="${tmp_home}/alert.sh"
  alert_log="${tmp_home}/alerts.log"
  cat > "${alert_script}" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${HERMES_TEST_ALERT_LOG}"
cat >> "${HERMES_TEST_ALERT_LOG}"
SH
  chmod +x "${alert_script}"
  cat > "${config}" <<JSON
{
  "version": 1,
  "settings": {
    "state_file": "${tmp_home}/state.json",
    "log_file": "${tmp_home}/x-pulse.log",
    "hermes_bin": "/usr/bin/false",
    "route": "x-buzz-trigger",
    "min_qualified_urls": 1,
    "min_qualified_score": 40
  },
  "queries": ["AI agents"]
}
JSON

  set +e
  output="$(
    HERMES_ALERT_SCRIPT="${alert_script}" \
    HERMES_TEST_ALERT_LOG="${alert_log}" \
    "${REPO_DIR}/scripts/hermes-x-pulse-watcher.py" --config "${config}"
  )"
  status=$?
  set -e

  [[ "${status}" -ne 0 ]] || fail "expected x pulse watcher search failure to be fatal"
  assert_json_eq "${output}" ".sent" "0"
  assert_contains "${output}" '"errors":'
  assert_file_contains "${tmp_home}/x-pulse.log" "x_search failed"
  assert_file_contains "${alert_log}" "Hermes X pulse watcher x_search failed"
}

test_digest_linter_writes_metadata() {
  local tmp_home digest metadata report
  tmp_home="$(mktemp -d)"
  digest="${tmp_home}/digest.md"
  metadata="${tmp_home}/metadata.json"
  report="${tmp_home}/report.md"
  cat > "${digest}" <<'DIGEST'
---
created_at: "2026-06-08 09:00:00 +0900"
digest_prefix: "朝の"
---

朝の注目トピックはAIとWebだよ

それじゃ、気になった話題を一緒に見ていこう！

---

目次
- AI model release
- Browser platform update
- Developer tool launch
- Cloud runtime incident
- Security advisory
- MCP implementation
- Database release
- Testing framework update

---
### AI model release
OpenAI account: practical model release with visible traction.
https://x.com/openai/status/1001

---
### Browser platform update
Chrome team: new Web API shipping note.
https://x.com/chromiumdev/status/1002

---
### Developer tool launch
Tool author: CLI workflow update.
https://x.com/tooldev/status/1003

---
### Cloud runtime incident
Cloud team: incident report for builders.
https://x.com/cloud/status/1004

---
### Security advisory
Security team: CVE remediation guidance.
https://x.com/security/status/1005

---
### MCP implementation
Builder: MCP server implementation notes.
https://x.com/mcpdev/status/1006

---
### Database release
Database team: release notes and migration detail.
https://x.com/db/status/1007

---
### Testing framework update
Maintainer: testing framework update.
https://x.com/testdev/status/1008
DIGEST

  HERMES_DIGEST_METADATA_DIR="${tmp_home}/metadata-dir" \
    "${REPO_DIR}/scripts/hermes-digest-lint.sh" "${digest}" "${metadata}" "${report}"

  assert_file_contains "${report}" "Status: pass"
  assert_eq "$(jq -r '.status' "${metadata}")" "pass" "digest status"
  assert_eq "$(jq -r '.section_count' "${metadata}")" "8" "digest section count"
  assert_eq "$(jq -r '.sections[0].accounts[0]' "${metadata}")" "openai" "digest first account"
}

test_digest_linter_rejects_missing_section_urls() {
  local tmp_home digest output status
  tmp_home="$(mktemp -d)"
  digest="${tmp_home}/bad-digest.md"
  cat > "${digest}" <<'DIGEST'
---
created_at: "2026-06-08 09:00:00 +0900"
---

---
### Good section
Source:
https://x.com/example/status/1

---
### Bad section
This section has no direct source URL.
DIGEST

  set +e
  output="$("${REPO_DIR}/scripts/hermes-digest-lint.sh" "${digest}" 2>&1)"
  status=$?
  set -e

  [[ "${status}" -ne 0 ]] || fail "expected digest linter to fail"
  assert_contains "${output}" "section count 2 is outside expected range"
  assert_contains "${output}" "Bad section"
}

test_discord_feedback_hook_writes_fallback_artifact() {
  local tmp_home feedback_file
  tmp_home="$(mktemp -d)"

  printf '%s\n' '{"text":"評価: 今日のセキュリティ項目は良かった","user_id":"u1","channel_id":"c1"}' \
    | HOME="${tmp_home}" HERMES_STATE_DIR="${tmp_home}/state" \
      "${REPO_DIR}/scripts/hermes-discord-feedback.sh"

  feedback_file="$(find "${tmp_home}/state/user-feedback" -type f -name 'feedback-*.md' -print -quit)"
  [[ -n "${feedback_file}" ]] || fail "expected feedback artifact"
  assert_file_contains "${feedback_file}" 'type: "feedback"'
  assert_file_contains "${feedback_file}" "今日のセキュリティ項目は良かった"
}

test_discord_feedback_and_remember_hooks_accept_string_event_payloads() {
  local tmp_home feedback_file gbrain_stub capture_log
  tmp_home="$(mktemp -d)"
  mkdir -p "${tmp_home}/brain"

  printf '%s\n' '{"event":"MessageCreate(text='\''評価: event string safe feedback'\'')","user_id":"u1","channel_id":"c1"}' \
    | HOME="${tmp_home}" HERMES_STATE_DIR="${tmp_home}/state" \
      "${REPO_DIR}/scripts/hermes-discord-feedback.sh"

  feedback_file="$(find "${tmp_home}/state/user-feedback" -type f -name 'feedback-*.md' -print -quit)"
  [[ -n "${feedback_file}" ]] || fail "expected feedback artifact from string event"
  assert_file_contains "${feedback_file}" "event string safe feedback"

  gbrain_stub="${tmp_home}/gbrain"
  capture_log="${tmp_home}/captured-note.txt"
  cat > "${gbrain_stub}" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "capture" && "$2" == "--stdin" ]] || exit 64
cat > "${GBRAIN_TEST_CAPTURE_LOG}"
STUB
  chmod +x "${gbrain_stub}"

  printf '%s\n' '{"extra":{"event":"MessageCreate(text='\''覚えて: event string safe memory'\'')"}}' \
    | HOME="${tmp_home}" \
      GBRAIN_BIN="${gbrain_stub}" \
      GBRAIN_BRAIN="${tmp_home}/brain" \
      GBRAIN_TEST_CAPTURE_LOG="${capture_log}" \
      "${REPO_DIR}/scripts/hermes-gbrain-remember.sh"

  assert_file_contains "${capture_log}" "event string safe memory"
}

test_tech_digest_cron_falls_back_to_jina_reader_when_x_search_fails() {
  local tmp_home hermes_stub output digest_file log_file metadata_file
  tmp_home="$(mktemp -d)"
  mkdir -p "${tmp_home}/.local/bin"
  hermes_stub="${tmp_home}/.local/bin/hermes"
  cat > "${hermes_stub}" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"-t x_search"* ]]; then
  echo "x_search credits exhausted" >&2
  exit 42
fi

if [[ "$*" == *"-t jina_reader"* ]]; then
  cat <<'DIGEST'
Jina Reader fallback digest

### Browser platform update
Jina Readerで公開ページを確認した代替トピック。
参照ページ: https://web.dev/blog/

### Developer tools update
GitHub Changelogから確認した開発者向け更新。
参照ページ: https://github.blog/changelog/

### AI engineering update
OpenAI Newsから確認したAI開発者向け更新。
参照ページ: https://openai.com/news/

### Japanese dev source update
Zenn Exploreから確認した国内開発者向け更新。
参照ページ: https://zenn.dev/articles/explore
DIGEST
  exit 0
fi

cat <<'EVAL'
## スコア
- 総合: 4
EVAL
STUB
  chmod +x "${hermes_stub}"

  output="$(
    HOME="${tmp_home}" \
    HERMES_BIN="${hermes_stub}" \
    HERMES_PROMPT_DIR="${REPO_DIR}/prompts" \
    HERMES_TECH_DIGEST_JINA_FALLBACK=1 \
    HERMES_DIGEST_LINT_SCRIPT="${REPO_DIR}/scripts/hermes-digest-lint.sh" \
    HERMES_DIGEST_LINT_STRICT=1 \
    "${REPO_DIR}/scripts/hermes-tech-digest-cron.sh"
  )"

  assert_contains "${output}" "Jina Reader fallback digest"
  assert_contains "${output}" "参照ページ: https://web.dev/blog/"
  digest_file="$(find "${tmp_home}/.hermes/state/digests" -type f -name '*.md' -print -quit)"
  [[ -n "${digest_file}" ]] || fail "expected Jina fallback digest"
  assert_file_contains "${digest_file}" 'curation_source: "jina_reader"'
  assert_file_contains "${digest_file}" "https://github.blog/changelog/"
  metadata_file="$(find "${tmp_home}/.hermes/state/digest-metadata" -type f -name '*.json' -print -quit)"
  [[ -n "${metadata_file}" ]] || fail "expected Jina fallback digest metadata"
  assert_eq "$(jq -r '.status' "${metadata_file}")" "pass" "Jina fallback digest status"
  assert_eq "$(jq -r '.curation_source' "${metadata_file}")" "jina_reader" "Jina fallback curation source"
  assert_eq "$(jq -r '.total_x_urls' "${metadata_file}")" "0" "Jina fallback X URL count"
  assert_eq "$(jq -r '.sections[0].reference_urls[0]' "${metadata_file}")" "https://web.dev/blog/" "Jina fallback reference URL"
  log_file="${tmp_home}/.hermes/logs/hermes-tech-digest-cron.log"
  assert_file_contains "${log_file}" "x_search curation failed exit=42"
  assert_file_contains "${log_file}" "jina_reader fallback curation succeeded after x_search failure"
}

test_tech_digest_cron_logs_when_jina_reader_fallback_fails_after_linkless_retry() {
  local tmp_home hermes_stub output log_file
  tmp_home="$(mktemp -d)"
  mkdir -p "${tmp_home}/.local/bin"
  hermes_stub="${tmp_home}/.local/bin/hermes"
  cat > "${hermes_stub}" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"-t x_search"* ]]; then
  cat <<'DIGEST'
Digest without direct X links

### Browser platform update
The browser platform shipped a practical update.

### Developer tools update
A developer tool shipped a workflow improvement.

### AI engineering update
An AI engineering team published implementation notes.

### Japanese dev source update
A Japanese developer source published a useful article.
DIGEST
  exit 0
fi

if [[ "$*" == *"-t jina_reader"* ]]; then
  echo "jina_reader unavailable" >&2
  exit 43
fi

cat <<'EVAL'
## スコア
- 総合: 4
EVAL
STUB
  chmod +x "${hermes_stub}"

  output="$(
    HOME="${tmp_home}" \
    HERMES_BIN="${hermes_stub}" \
    HERMES_PROMPT_DIR="${REPO_DIR}/prompts" \
    HERMES_TECH_DIGEST_JINA_FALLBACK=1 \
    "${REPO_DIR}/scripts/hermes-tech-digest-cron.sh"
  )"

  assert_contains "${output}" "Digest without direct X links"
  log_file="${tmp_home}/.hermes/logs/hermes-tech-digest-cron.log"
  assert_file_contains "${log_file}" "x_search retry still had no direct X links; trying jina_reader fallback"
  assert_file_contains "${log_file}" "warning: jina_reader fallback failed after missing X links; proceeding with linkless x_search curation"
}

test_tech_digest_cron_runs_lint_and_low_score_alert() {
  local tmp_home hermes_stub output metadata_file alert_log
  tmp_home="$(mktemp -d)"
  mkdir -p "${tmp_home}/.local/bin"
  hermes_stub="${tmp_home}/.local/bin/hermes"
  cat > "${hermes_stub}" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"-t x_search"* ]]; then
  cat <<'DIGEST'
朝の注目トピックはAIとWebだよ

それじゃ、気になった話題を一緒に見ていこう！

---
目次
- AI model release
- Browser platform update
- Developer tool launch
- Cloud runtime incident
- Security advisory
- MCP implementation
- Database release
- Testing framework update

---
### AI model release
OpenAI account: practical model release with visible traction.
https://x.com/openai/status/1001

---
### Browser platform update
Chrome team: new Web API shipping note.
https://x.com/chromiumdev/status/1002

---
### Developer tool launch
Tool author: CLI workflow update.
https://x.com/tooldev/status/1003

---
### Cloud runtime incident
Cloud team: incident report for builders.
https://x.com/cloud/status/1004

---
### Security advisory
Security team: CVE remediation guidance.
https://x.com/security/status/1005

---
### MCP implementation
Builder: MCP server implementation notes.
https://x.com/mcpdev/status/1006

---
### Database release
Database team: release notes and migration detail.
https://x.com/db/status/1007

---
### Testing framework update
Maintainer: testing framework update.
https://x.com/testdev/status/1008
DIGEST
  exit 0
fi

cat <<'EVAL'
# 自己評価 2026-06-08 09:00

## スコア
- 関連性: 2
- 新規性: 2
- 出典品質: 2
- 多様性: 2
- 具体性: 2
- トーン: 2
- 総合: 2

## 次回の改善指示
- より一次情報を優先する。
EVAL
STUB
  chmod +x "${hermes_stub}"

  output="$(
    HOME="${tmp_home}" \
    HERMES_BIN="${hermes_stub}" \
    HERMES_PROMPT_DIR="${REPO_DIR}/prompts" \
    HERMES_DIGEST_LINT_SCRIPT="${REPO_DIR}/scripts/hermes-digest-lint.sh" \
    HERMES_ALERT_SCRIPT="${REPO_DIR}/scripts/hermes-alert.sh" \
    "${REPO_DIR}/scripts/hermes-tech-digest-cron.sh"
  )"

  assert_contains "${output}" "更新:"
  metadata_file="$(find "${tmp_home}/.hermes/state/digest-metadata" -type f -name '*.json' -print -quit)"
  [[ -n "${metadata_file}" ]] || fail "expected digest metadata"
  assert_eq "$(jq -r '.status' "${metadata_file}")" "pass" "digest status"
  alert_log="${tmp_home}/.hermes/logs/hermes-alerts.log"
  assert_file_contains "${alert_log}" "Hermes digest self-evaluation is low"
}

main() {
  local tests=(
    test_register_cronjobs_syncs_enabled_tech_digest_jobs
    test_register_cronjobs_rejects_unknown_channel
    test_register_cronjobs_uses_local_channel_overrides
    test_morning_brief_cron_reads_direct_feeds
    test_morning_brief_includes_today_calendar_events
    test_monday_morning_brief_includes_weekly_calendar_events
    test_installer_uses_builtin_gateway_only
    test_installer_installs_gateway_before_merging_hooks
    test_obsidian_mcp_setup_writes_read_write_config
    test_obsidian_mcp_setup_read_only_omits_write_tools
    test_jina_mcp_setup_writes_reader_only_config
    test_jina_mcp_setup_can_reference_api_key_env
    test_google_calendar_mcp_setup_writes_read_only_oauth_config
    test_google_calendar_mcp_setup_can_enable_write_tools_and_public_client
    test_dreaming_cron_recomposes_memory_and_writes_report
    test_review_cron_reports_gbrain_and_honcho_status
    test_review_cron_finds_bun_for_gbrain
    test_scheduled_prompts_require_direct_source_links
    test_register_webhooks_preserves_existing_secret
    test_register_webhooks_uses_local_channel_overrides
    test_register_webhooks_rejects_script_names_outside_runtime_cron_pattern
    test_posting_admin_escapes_test_payload_and_rejects_unknown_routes
    test_signal_watcher_scores_local_feed
    test_signal_watcher_reads_env_file_for_secret
    test_signal_watcher_parses_nested_html_links
    test_signal_watcher_tracks_standalone_document_hash_changes
    test_signal_watcher_retries_candidates_blocked_by_cooldown
    test_signal_watcher_keeps_custom_routes_out_of_batch
    test_x_pulse_watcher_primes_sample_urls
    test_x_pulse_watcher_detects_sample_pulse
    test_x_pulse_watcher_rejects_low_engagement_url_bundle
    test_x_pulse_watcher_treats_search_failure_as_nonfatal
    test_digest_linter_writes_metadata
    test_digest_linter_rejects_missing_section_urls
    test_discord_feedback_hook_writes_fallback_artifact
    test_discord_feedback_and_remember_hooks_accept_string_event_payloads
    test_tech_digest_cron_falls_back_to_jina_reader_when_x_search_fails
    test_tech_digest_cron_logs_when_jina_reader_fallback_fails_after_linkless_retry
    test_tech_digest_cron_runs_lint_and_low_score_alert
  )
  local test_name

  for test_name in "${tests[@]}"; do
    "${test_name}"
    echo "ok - ${test_name}"
  done
}

main "$@"
