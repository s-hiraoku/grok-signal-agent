#!/usr/bin/env bash
set -euo pipefail

# Configure Hermes Agent to use the official Jina AI Remote MCP server for
# URL-to-Markdown reading. By default this exposes only Reader-oriented tools
# that can run without an API key, subject to Jina's anonymous rate limits.

CONFIG_FILE="${HERMES_CONFIG:-${HOME}/.hermes/config.yaml}"
SERVER_NAME="jina_reader"
JINA_MCP_URL="${JINA_MCP_URL:-https://mcp.jina.ai/v1}"
API_KEY_ENV=""
RESTART_GATEWAY=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/hermes-jina-mcp-setup.sh

Options:
  --name NAME          MCP server name in Hermes config. Default: jina_reader.
  --url URL            Jina MCP URL. Default: https://mcp.jina.ai/v1.
  --config PATH        Hermes config path. Default: ~/.hermes/config.yaml.
  --api-key-env NAME   Add Authorization: Bearer ${NAME}; store the key in env or ~/.hermes/.env.
  --restart-gateway    Restart Hermes Gateway after updating config.
  -h, --help           Show this help.

Examples:
  scripts/hermes-jina-mcp-setup.sh --restart-gateway
  scripts/hermes-jina-mcp-setup.sh --api-key-env JINA_API_KEY --restart-gateway
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
      JINA_MCP_URL="$2"
      shift 2
      ;;
    --config)
      [[ $# -ge 2 ]] || { echo "--config requires a path" >&2; exit 64; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --api-key-env)
      [[ $# -ge 2 ]] || { echo "--api-key-env requires a variable name" >&2; exit 64; }
      API_KEY_ENV="$2"
      shift 2
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

case "${JINA_MCP_URL}" in
  http://*|https://*) ;;
  *) echo "Jina MCP URL must start with http:// or https://: ${JINA_MCP_URL}" >&2; exit 64 ;;
esac

if [[ -n "${API_KEY_ENV}" && ! "${API_KEY_ENV}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "--api-key-env must be an environment variable name: ${API_KEY_ENV}" >&2
  exit 64
fi

CONFIG_FILE="$(ruby -e 'puts File.expand_path(ARGV.fetch(0))' "${CONFIG_FILE}")"

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

READER_TOOLS='["primer","read_url","parallel_read_url","guess_datetime_url","capture_screenshot_url","search_jina_blog"]'

ruby - "${CONFIG_FILE}" "${SERVER_NAME}" "${JINA_MCP_URL}" "${API_KEY_ENV}" "${READER_TOOLS}" <<'RUBY'
require "json"
require "yaml"

config_file, server_name, mcp_url, api_key_env, tools_json = ARGV
raw = File.exist?(config_file) ? File.read(config_file) : ""
config = raw.strip.empty? ? {} : (YAML.safe_load(raw, aliases: true, permitted_classes: [Symbol]) || {})
unless config.is_a?(Hash)
  abort "Hermes config must be a YAML mapping: #{config_file}"
end

entry = {
  "url" => mcp_url,
  "enabled" => true,
  "timeout" => 180,
  "connect_timeout" => 30,
  "tools" => {
    "include" => JSON.parse(tools_json),
    "resources" => false,
    "prompts" => false
  }
}
unless api_key_env.to_s.empty?
  entry["headers"] = {
    "Authorization" => "Bearer ${#{api_key_env}}"
  }
end

config["mcp_servers"] = {} unless config["mcp_servers"].is_a?(Hash)
config["mcp_servers"][server_name] = entry

tmp = "#{config_file}.tmp.#{$$}"
File.write(tmp, YAML.dump(config))
File.rename(tmp, config_file)
RUBY

echo "Configured Hermes MCP server '${SERVER_NAME}' for Jina Reader:"
echo "  ${JINA_MCP_URL}"
echo "Config updated:"
echo "  ${CONFIG_FILE}"
if [[ -n "${BACKUP_FILE}" ]]; then
  echo "Backup written:"
  echo "  ${BACKUP_FILE}"
fi
if [[ -n "${API_KEY_ENV}" ]]; then
  echo "Authorization header: Bearer \${${API_KEY_ENV}}"
else
  echo "Authorization header: none (anonymous Reader rate limits apply)"
fi

if [[ "${RESTART_GATEWAY}" == "1" ]]; then
  HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
  [[ -x "${HERMES_BIN}" ]] || { echo "missing Hermes binary: ${HERMES_BIN}" >&2; exit 69; }
  "${HERMES_BIN}" gateway restart
  echo "Hermes Gateway restarted."
else
  echo "Restart Hermes Gateway or start a new Hermes session so MCP tools are discovered."
fi
