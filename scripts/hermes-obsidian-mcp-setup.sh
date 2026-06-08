#!/usr/bin/env bash
set -euo pipefail

# Configure Hermes Agent to access one Obsidian vault through the official
# filesystem MCP server. The MCP server is sandboxed to the vault directory
# passed here; Hermes cannot use this server outside that directory.

CONFIG_FILE="${HERMES_CONFIG:-${HOME}/.hermes/config.yaml}"
SERVER_NAME="obsidian"
VAULT_PATH="${OBSIDIAN_VAULT_PATH:-}"
READ_ONLY=0
RESTART_GATEWAY=0
ALLOW_NON_VAULT=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/hermes-obsidian-mcp-setup.sh --vault /path/to/ObsidianVault

Options:
  --vault PATH         Obsidian vault directory. Defaults to OBSIDIAN_VAULT_PATH.
  --name NAME          MCP server name in Hermes config. Default: obsidian.
  --config PATH        Hermes config path. Default: ~/.hermes/config.yaml.
  --read-only          Expose only Obsidian read/search tools.
  --allow-non-vault    Do not require PATH/.obsidian to exist.
  --restart-gateway    Restart Hermes Gateway after updating config.
  -h, --help           Show this help.

Examples:
  OBSIDIAN_VAULT_PATH="$HOME/Documents/Notes" scripts/hermes-obsidian-mcp-setup.sh
  scripts/hermes-obsidian-mcp-setup.sh --vault "$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Main"
  scripts/hermes-obsidian-mcp-setup.sh --vault "$HOME/Documents/Notes" --read-only
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault)
      [[ $# -ge 2 ]] || { echo "--vault requires a path" >&2; exit 64; }
      VAULT_PATH="$2"
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || { echo "--name requires a value" >&2; exit 64; }
      SERVER_NAME="$2"
      shift 2
      ;;
    --config)
      [[ $# -ge 2 ]] || { echo "--config requires a path" >&2; exit 64; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --read-only)
      READ_ONLY=1
      shift
      ;;
    --allow-non-vault)
      ALLOW_NON_VAULT=1
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
      if [[ -z "${VAULT_PATH}" ]]; then
        VAULT_PATH="$1"
        shift
      else
        echo "unexpected argument: $1" >&2
        usage >&2
        exit 64
      fi
      ;;
  esac
done

[[ -n "${VAULT_PATH}" ]] || { echo "missing Obsidian vault path; pass --vault or set OBSIDIAN_VAULT_PATH" >&2; exit 64; }

if ! command -v ruby >/dev/null 2>&1; then
  echo "missing ruby; this setup script uses Ruby's standard YAML library to safely merge ~/.hermes/config.yaml" >&2
  exit 69
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "missing npx; install Node.js/npm so Hermes can launch @modelcontextprotocol/server-filesystem" >&2
  exit 69
fi

VAULT_PATH="$(ruby -e 'puts File.expand_path(ARGV.fetch(0))' "${VAULT_PATH}")"
CONFIG_FILE="$(ruby -e 'puts File.expand_path(ARGV.fetch(0))' "${CONFIG_FILE}")"

[[ -d "${VAULT_PATH}" ]] || { echo "vault directory does not exist: ${VAULT_PATH}" >&2; exit 66; }
if [[ "${ALLOW_NON_VAULT}" != "1" && ! -d "${VAULT_PATH}/.obsidian" ]]; then
  echo "not an Obsidian vault: ${VAULT_PATH} (missing .obsidian)" >&2
  echo "Use --allow-non-vault only if you intentionally want this directory exposed." >&2
  exit 66
fi

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

READ_TOOLS='["read_text_file","read_media_file","read_file","read_multiple_files","list_directory","directory_tree","search_files","get_file_info","list_allowed_directories"]'
WRITE_TOOLS='["write_file","edit_file","create_directory"]'

ruby - "${CONFIG_FILE}" "${SERVER_NAME}" "${VAULT_PATH}" "${READ_ONLY}" "${READ_TOOLS}" "${WRITE_TOOLS}" <<'RUBY'
require "json"
require "yaml"

config_file, server_name, vault_path, read_only, read_tools_json, write_tools_json = ARGV
raw = File.exist?(config_file) ? File.read(config_file) : ""
config = raw.strip.empty? ? {} : (YAML.safe_load(raw, aliases: true, permitted_classes: [Symbol]) || {})
unless config.is_a?(Hash)
  abort "Hermes config must be a YAML mapping: #{config_file}"
end

read_tools = JSON.parse(read_tools_json)
write_tools = JSON.parse(write_tools_json)
include_tools = read_only == "1" ? read_tools : (read_tools + write_tools)

config["mcp_servers"] = {} unless config["mcp_servers"].is_a?(Hash)
config["mcp_servers"][server_name] = {
  "command" => "npx",
  "args" => ["-y", "@modelcontextprotocol/server-filesystem", vault_path],
  "enabled" => true,
  "timeout" => 120,
  "connect_timeout" => 60,
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

echo "Configured Hermes MCP server '${SERVER_NAME}' for Obsidian vault:"
echo "  ${VAULT_PATH}"
echo "Config updated:"
echo "  ${CONFIG_FILE}"
if [[ -n "${BACKUP_FILE}" ]]; then
  echo "Backup written:"
  echo "  ${BACKUP_FILE}"
fi
if [[ "${READ_ONLY}" == "1" ]]; then
  echo "Mode: read-only"
else
  echo "Mode: read/write without delete or move tools"
fi

if [[ "${RESTART_GATEWAY}" == "1" ]]; then
  HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
  [[ -x "${HERMES_BIN}" ]] || { echo "missing Hermes binary: ${HERMES_BIN}" >&2; exit 69; }
  "${HERMES_BIN}" gateway restart
  echo "Hermes Gateway restarted."
else
  echo "Restart Hermes Gateway or start a new Hermes session so MCP tools are discovered."
fi
