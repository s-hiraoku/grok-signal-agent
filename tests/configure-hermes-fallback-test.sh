#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
CONFIG_FILE="${TMP_DIR}/config.yaml"

cat > "${CONFIG_FILE}" <<'YAML'
model:
  provider: xai-oauth
  default: grok-4.5
fallback_providers:
- provider: other-provider
  model: other-model
- provider: openai-codex
  model: gpt-5.5
  base_url: https://chatgpt.com/backend-api/codex
agent:
  max_turns: 60
YAML

"${REPO_DIR}/scripts/configure-hermes-fallback.sh" --config "${CONFIG_FILE}" >/dev/null

ruby -ryaml -e '
  config = YAML.load_file(ARGV.fetch(0))
  abort "primary provider changed" unless config.dig("model", "provider") == "xai-oauth"
  abort "primary model changed" unless config.dig("model", "default") == "grok-4.5"
  abort "agent config changed" unless config.dig("agent", "max_turns") == 60

  chain = config.fetch("fallback_providers")
  expected = {
    "provider" => "openai-codex",
    "model" => "gpt-5.6-luna",
    "base_url" => "https://chatgpt.com/backend-api/codex"
  }
  abort "Luna is not the first fallback" unless chain.first == expected
  abort "other fallback was not preserved" unless chain[1] == {
    "provider" => "other-provider", "model" => "other-model"
  }
  abort "old Codex fallback remains" unless chain.count { |entry| entry["provider"] == "openai-codex" } == 1
' "${CONFIG_FILE}"

first_checksum="$(shasum -a 256 "${CONFIG_FILE}" | awk '{print $1}')"
"${REPO_DIR}/scripts/configure-hermes-fallback.sh" --config "${CONFIG_FILE}" >/dev/null
second_checksum="$(shasum -a 256 "${CONFIG_FILE}" | awk '{print $1}')"
[[ "${first_checksum}" == "${second_checksum}" ]] || {
  echo "second run changed an already-correct config" >&2
  exit 1
}

echo "configure-hermes-fallback tests passed"
