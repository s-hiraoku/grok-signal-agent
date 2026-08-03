#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${HERMES_CONFIG:-${HOME}/.hermes/config.yaml}"
FALLBACK_PROVIDER="${HERMES_FALLBACK_PROVIDER:-openai-codex}"
FALLBACK_MODEL="${HERMES_FALLBACK_MODEL:-gpt-5.6-luna}"
FALLBACK_BASE_URL="${HERMES_FALLBACK_BASE_URL:-https://chatgpt.com/backend-api/codex}"

usage() {
  cat <<'EOF'
Usage: configure-hermes-fallback.sh [options]

Put a model at the front of Hermes' fallback provider chain while preserving
fallbacks for other providers.

Options:
  --config PATH       Hermes config path (default: ~/.hermes/config.yaml)
  --provider NAME     Fallback provider (default: openai-codex)
  --model NAME        Fallback model (default: gpt-5.6-luna)
  --base-url URL      Provider base URL
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { echo "--config requires a path" >&2; exit 2; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --provider)
      [[ $# -ge 2 ]] || { echo "--provider requires a name" >&2; exit 2; }
      FALLBACK_PROVIDER="$2"
      shift 2
      ;;
    --model)
      [[ $# -ge 2 ]] || { echo "--model requires a name" >&2; exit 2; }
      FALLBACK_MODEL="$2"
      shift 2
      ;;
    --base-url)
      [[ $# -ge 2 ]] || { echo "--base-url requires a URL" >&2; exit 2; }
      FALLBACK_BASE_URL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v ruby >/dev/null 2>&1 || {
  echo "missing ruby; Ruby's standard YAML library is required" >&2
  exit 1
}

mkdir -p "$(dirname "${CONFIG_FILE}")"

ruby -ryaml -rtempfile -e '
  config_file, provider, model, base_url = ARGV
  config = File.exist?(config_file) ? (YAML.load_file(config_file) || {}) : {}
  abort "Hermes config root must be a mapping" unless config.is_a?(Hash)

  chain = config["fallback_providers"]
  chain = [] unless chain.is_a?(Array)
  retained = chain.select do |entry|
    !entry.is_a?(Hash) || entry["provider"].to_s.strip.downcase != provider.downcase
  end

  selected = { "provider" => provider, "model" => model }
  selected["base_url"] = base_url unless base_url.empty?
  config["fallback_providers"] = [selected] + retained

  directory = File.dirname(config_file)
  basename = File.basename(config_file)
  mode = File.exist?(config_file) ? File.stat(config_file).mode : 0600
  tempfile = Tempfile.new([".#{basename}.", ".tmp"], directory)
  begin
    tempfile.chmod(mode)
    tempfile.write(YAML.dump(config))
    tempfile.flush
    tempfile.fsync
    tempfile.close
    File.rename(tempfile.path, config_file)
  ensure
    tempfile.close! if tempfile
  end
' "${CONFIG_FILE}" "${FALLBACK_PROVIDER}" "${FALLBACK_MODEL}" "${FALLBACK_BASE_URL}"

printf 'Configured Hermes fallback: provider=%s model=%s\n' \
  "${FALLBACK_PROVIDER}" "${FALLBACK_MODEL}"
printf 'Config: %s\n' "${CONFIG_FILE}"
