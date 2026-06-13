#!/usr/bin/env bash
set -euo pipefail

# Configure Hermes Agent to use Google's official remote Calendar MCP server.
# Default exposure is read-only so Discord questions like "今日の予定は？" can
# be answered without giving the model event mutation tools.

CONFIG_FILE="${HERMES_CONFIG:-${HOME}/.hermes/config.yaml}"
SERVER_NAME="google_calendar"
CALENDAR_MCP_URL="${GOOGLE_CALENDAR_MCP_URL:-https://calendarmcp.googleapis.com/mcp/v1}"
CLIENT_ID_ENV="${GOOGLE_CALENDAR_MCP_CLIENT_ID_ENV:-GOOGLE_CALENDAR_MCP_CLIENT_ID}"
CLIENT_SECRET_ENV="${GOOGLE_CALENDAR_MCP_CLIENT_SECRET_ENV:-GOOGLE_CALENDAR_MCP_CLIENT_SECRET}"
CLIENT_NAME="Hermes Google Calendar"
SCOPE="https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/calendar.events.freebusy https://www.googleapis.com/auth/calendar.events.readonly"
REDIRECT_PORT="${GOOGLE_CALENDAR_MCP_REDIRECT_PORT:-0}"
ALLOW_WRITE=0
PUBLIC_CLIENT=0
LOGIN=0
RESTART_GATEWAY=0
HELPER_PATH="${GOOGLE_CALENDAR_HELPER_PATH:-${HOME}/.hermes/skills/productivity/google-workspace/scripts/google_api.py}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/hermes-google-calendar-mcp-setup.sh

Options:
  --name NAME                 MCP server name in Hermes config. Default: google_calendar.
  --url URL                   Calendar MCP endpoint. Default: https://calendarmcp.googleapis.com/mcp/v1.
  --config PATH               Hermes config path. Default: ~/.hermes/config.yaml.
  --client-id-env NAME        Env var holding the OAuth client ID. Default: GOOGLE_CALENDAR_MCP_CLIENT_ID.
  --client-secret-env NAME    Env var holding the OAuth client secret. Default: GOOGLE_CALENDAR_MCP_CLIENT_SECRET.
  --client-name NAME          OAuth client display name. Default: Hermes Google Calendar.
  --scope SCOPE               OAuth scopes. Default: read-only Calendar list/events/freebusy scopes.
  --redirect-port PORT        OAuth loopback callback port. Default: 0 auto-picks a free port.
  --public-client             Omit oauth.client_secret from config.
  --allow-write               Also expose create/update/delete/respond event tools.
  --login                     Run `hermes mcp login NAME` after writing config.
  --restart-gateway           Restart Hermes Gateway after updating config.
  -h, --help                  Show this help.

Examples:
  scripts/hermes-google-calendar-mcp-setup.sh --login --restart-gateway
  scripts/hermes-google-calendar-mcp-setup.sh --public-client --login
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || { echo "--name requires a value" >&2; exit 64; }
      SERVER_NAME="$2"
      shift 2
      ;;
    --url)
      [[ $# -ge 2 ]] || { echo "--url requires a value" >&2; exit 64; }
      CALENDAR_MCP_URL="$2"
      shift 2
      ;;
    --config)
      [[ $# -ge 2 ]] || { echo "--config requires a path" >&2; exit 64; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --client-id-env)
      [[ $# -ge 2 ]] || { echo "--client-id-env requires a variable name" >&2; exit 64; }
      CLIENT_ID_ENV="$2"
      shift 2
      ;;
    --client-secret-env)
      [[ $# -ge 2 ]] || { echo "--client-secret-env requires a variable name" >&2; exit 64; }
      CLIENT_SECRET_ENV="$2"
      shift 2
      ;;
    --client-name)
      [[ $# -ge 2 ]] || { echo "--client-name requires a value" >&2; exit 64; }
      CLIENT_NAME="$2"
      shift 2
      ;;
    --scope)
      [[ $# -ge 2 ]] || { echo "--scope requires a value" >&2; exit 64; }
      SCOPE="$2"
      shift 2
      ;;
    --redirect-port)
      [[ $# -ge 2 ]] || { echo "--redirect-port requires a value" >&2; exit 64; }
      REDIRECT_PORT="$2"
      shift 2
      ;;
    --public-client)
      PUBLIC_CLIENT=1
      shift
      ;;
    --allow-write)
      ALLOW_WRITE=1
      shift
      ;;
    --login)
      LOGIN=1
      shift
      ;;
    --restart-gateway)
      RESTART_GATEWAY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
    *)
      echo "unexpected argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if ! command -v ruby >/dev/null 2>&1; then
  echo "missing ruby; this setup script uses Ruby's standard YAML library to safely merge ~/.hermes/config.yaml" >&2
  exit 69
fi

case "${CALENDAR_MCP_URL}" in
  http://*|https://*) ;;
  *) echo "Calendar MCP URL must start with http:// or https://: ${CALENDAR_MCP_URL}" >&2; exit 64 ;;
esac

for env_name in "${CLIENT_ID_ENV}" "${CLIENT_SECRET_ENV}"; do
  [[ "${env_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    echo "OAuth env var names must be valid shell variable names: ${env_name}" >&2
    exit 64
  }
done

if ! [[ "${REDIRECT_PORT}" =~ ^[0-9]+$ ]] || (( REDIRECT_PORT > 65535 )); then
  echo "--redirect-port must be an integer from 0 to 65535: ${REDIRECT_PORT}" >&2
  exit 64
fi

CONFIG_FILE="$(ruby -e 'puts File.expand_path(ARGV.fetch(0))' "${CONFIG_FILE}")"
HELPER_PATH="$(ruby -e 'puts File.expand_path(ARGV.fetch(0))' "${HELPER_PATH}")"

mkdir -p "$(dirname "${CONFIG_FILE}")"
CREATED_CONFIG=0
if [[ ! -f "${CONFIG_FILE}" ]]; then
  printf '{}\n' > "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}" 2>/dev/null || true
  CREATED_CONFIG=1
fi
BACKUP_FILE=""
if [[ "${CREATED_CONFIG}" != "1" ]]; then
  BACKUP_FILE="${CONFIG_FILE}.bak.$(date '+%Y%m%d-%H%M%S')"
  cp "${CONFIG_FILE}" "${BACKUP_FILE}"
fi

READ_TOOLS='["list_calendars","list_events","get_event","suggest_time"]'
WRITE_TOOLS='["create_event","update_event","delete_event","respond_to_event"]'
CLIENT_ID_REF="\${${CLIENT_ID_ENV}}"
CLIENT_SECRET_REF="\${${CLIENT_SECRET_ENV}}"

ruby - "${CONFIG_FILE}" "${SERVER_NAME}" "${CALENDAR_MCP_URL}" "${CLIENT_ID_REF}" "${CLIENT_SECRET_REF}" "${PUBLIC_CLIENT}" "${CLIENT_NAME}" "${SCOPE}" "${REDIRECT_PORT}" "${ALLOW_WRITE}" "${READ_TOOLS}" "${WRITE_TOOLS}" <<'RUBY'
require "json"
require "yaml"

config_file, server_name, mcp_url, client_id_ref, client_secret_ref, public_client, client_name, scope, redirect_port, allow_write, read_tools_json, write_tools_json = ARGV
raw = File.exist?(config_file) ? File.read(config_file) : ""
config = raw.strip.empty? ? {} : (YAML.safe_load(raw, aliases: true, permitted_classes: [Symbol]) || {})
unless config.is_a?(Hash)
  abort "Hermes config must be a YAML mapping: #{config_file}"
end

read_tools = JSON.parse(read_tools_json)
write_tools = JSON.parse(write_tools_json)
include_tools = allow_write == "1" ? (read_tools + write_tools) : read_tools

oauth = {
  "client_id" => client_id_ref,
  "client_name" => client_name,
  "redirect_port" => redirect_port.to_i,
  "scope" => scope
}
oauth["client_secret"] = client_secret_ref unless public_client == "1"

config["mcp_servers"] = {} unless config["mcp_servers"].is_a?(Hash)
config["mcp_servers"][server_name] = {
  "url" => mcp_url,
  "auth" => "oauth",
  "enabled" => true,
  "timeout" => 180,
  "connect_timeout" => 60,
  "oauth" => oauth,
  "tools" => {
    "include" => include_tools,
    "resources" => false,
    "prompts" => false
  }
}

tmp = "#{config_file}.tmp.#{$$}"
File.write(tmp, YAML.dump(config))
File.rename(tmp, config_file)
RUBY

mkdir -p "$(dirname "${HELPER_PATH}")"
cat > "${HELPER_PATH}" <<'PY'
#!/usr/bin/env python3
"""Small Hermes Calendar MCP proxy used by hermes-morning-brief-cron.sh."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def extract_json_array(text: str) -> list[dict]:
    stripped = text.strip()
    if stripped.startswith("["):
        return json.loads(stripped)
    match = re.search(r"\[[\s\S]*\]", stripped)
    if not match:
        raise ValueError("no JSON array found in Hermes response")
    return json.loads(match.group(0))


def normalize_events(raw_events: object) -> list[dict[str, str]]:
    events: list[dict[str, str]] = []
    if not isinstance(raw_events, list):
        return events
    for raw in raw_events:
        if not isinstance(raw, dict):
            continue
        events.append(
            {
                "summary": str(raw.get("summary") or raw.get("title") or "(タイトルなし)"),
                "start": str(raw.get("start") or raw.get("startTime") or ""),
                "end": str(raw.get("end") or raw.get("endTime") or ""),
                "location": str(raw.get("location") or ""),
                "htmlLink": str(raw.get("htmlLink") or raw.get("url") or raw.get("link") or ""),
            }
        )
    return events


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="resource", required=True)
    calendar = subparsers.add_parser("calendar")
    calendar_sub = calendar.add_subparsers(dest="action", required=True)
    list_cmd = calendar_sub.add_parser("list")
    list_cmd.add_argument("--start", required=True)
    list_cmd.add_argument("--end", required=True)
    list_cmd.add_argument("--max", default="6")
    args = parser.parse_args()

    if args.resource != "calendar" or args.action != "list":
        parser.error("only calendar list is supported")

    hermes_bin = os.environ.get("HERMES_BIN") or str(Path.home() / ".local/bin/hermes")
    server_name = os.environ.get("HERMES_GOOGLE_CALENDAR_MCP_SERVER", "__HERMES_GOOGLE_CALENDAR_MCP_SERVER__")
    prompt = (
        "Use the Google Calendar MCP tools to list calendar events between "
        f"{args.start} and {args.end}. Return ONLY a JSON array with at most {args.max} "
        "objects. Each object must have string fields: summary, start, end, "
        "location, htmlLink. Do not include markdown or commentary."
    )
    completed = subprocess.run(
        [hermes_bin, "-t", server_name, "-z", prompt],
        check=False,
        text=True,
        capture_output=True,
        timeout=int(os.environ.get("HERMES_GOOGLE_CALENDAR_HELPER_TIMEOUT", "90")),
    )
    if completed.returncode != 0:
        sys.stderr.write(completed.stderr or completed.stdout)
        return completed.returncode
    try:
        events = normalize_events(extract_json_array(completed.stdout))
    except Exception as exc:
        sys.stderr.write(f"failed to parse Hermes Calendar response: {exc}\n")
        return 1
    print(json.dumps(events, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
ruby -e 'path, name = ARGV; File.write(path, File.read(path).gsub("__HERMES_GOOGLE_CALENDAR_MCP_SERVER__", name))' \
  "${HELPER_PATH}" "${SERVER_NAME}"
chmod 755 "${HELPER_PATH}"

echo "Configured Hermes MCP server '${SERVER_NAME}' for Google Calendar:"
echo "  ${CALENDAR_MCP_URL}"
echo "Config updated:"
echo "  ${CONFIG_FILE}"
echo "Morning brief Calendar helper installed:"
echo "  ${HELPER_PATH}"
if [[ -n "${BACKUP_FILE}" ]]; then
  echo "Backup written:"
  echo "  ${BACKUP_FILE}"
fi
if [[ "${ALLOW_WRITE}" == "1" ]]; then
  echo "Mode: read/write Calendar tools"
else
  echo "Mode: read-only Calendar tools"
fi
echo "OAuth client ID env: ${CLIENT_ID_ENV}"
if [[ "${REDIRECT_PORT}" == "0" ]]; then
  echo "OAuth redirect port: auto"
else
  echo "OAuth redirect URI: http://127.0.0.1:${REDIRECT_PORT}/callback"
fi
if [[ "${PUBLIC_CLIENT}" == "1" ]]; then
  echo "OAuth client secret: omitted"
else
  echo "OAuth client secret env: ${CLIENT_SECRET_ENV}"
fi

if [[ -z "${!CLIENT_ID_ENV:-}" ]]; then
  echo "Set ${CLIENT_ID_ENV} in ~/.hermes/.env before running: hermes mcp login ${SERVER_NAME}"
fi
if [[ "${PUBLIC_CLIENT}" != "1" && -z "${!CLIENT_SECRET_ENV:-}" ]]; then
  echo "Set ${CLIENT_SECRET_ENV} in ~/.hermes/.env before running: hermes mcp login ${SERVER_NAME}"
fi

if [[ "${LOGIN}" == "1" || "${RESTART_GATEWAY}" == "1" ]]; then
  HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
  [[ -x "${HERMES_BIN}" ]] || { echo "missing Hermes binary: ${HERMES_BIN}" >&2; exit 69; }
fi

if [[ "${LOGIN}" == "1" ]]; then
  "${HERMES_BIN}" mcp login "${SERVER_NAME}"
  echo "Hermes MCP OAuth login completed for '${SERVER_NAME}'."
else
  echo "Run: hermes mcp login ${SERVER_NAME}"
fi

if [[ "${RESTART_GATEWAY}" == "1" ]]; then
  "${HERMES_BIN}" gateway restart
  echo "Hermes Gateway restarted."
else
  echo "Restart Hermes Gateway or start a new Hermes session so Calendar tools are discovered."
fi
