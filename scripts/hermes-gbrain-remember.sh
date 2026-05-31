#!/usr/bin/env bash
set -euo pipefail

# Discord-to-brain memory hook (see docs/self-growth.md).
#
# Registered as a Hermes `pre_gateway_dispatch` shell hook: it fires once per
# incoming gateway message with the event payload on stdin as JSON. When the
# message text starts with a remember-prefix (覚えて / おぼえて / 記憶して /
# /remember), the remainder is saved into the gbrain brain as a `note` page so
# digest retrieval can later surface it as soft guidance.
#
# Anything that does not match a prefix is ignored (the hook is a no-op), so a
# normal conversation is never captured. Any failure is logged and the hook
# still exits 0 so it never blocks message dispatch.
#
# Env overrides:
#   GBRAIN_BIN     path to gbrain (default: resolved from PATH / ~/.bun/bin)
#   GBRAIN_BRAIN   brain dir (default: ~/.hermes/brain)
#   HERMES_REMEMBER_LOG  log file (default: ~/.hermes/logs/hermes-gbrain-remember.log)

GBRAIN_BIN="${GBRAIN_BIN:-}"
BRAIN_DIR="${GBRAIN_BRAIN:-${HOME}/.hermes/brain}"
LOG_FILE="${HERMES_REMEMBER_LOG:-${HOME}/.hermes/logs/hermes-gbrain-remember.log}"

mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}" 2>/dev/null || true; }

# Always succeed: a hook that errors could disrupt the gateway.
trap 'exit 0' ERR

payload="$(cat 2>/dev/null || true)"
[[ -n "${payload}" ]] || exit 0

# Extract the message text. Prefer jq; fall back to a minimal grep if absent.
text=""
if command -v jq >/dev/null 2>&1; then
  text="$(printf '%s' "${payload}" | jq -r '.text // .message // .event.text // empty' 2>/dev/null || true)"
fi
if [[ -z "${text}" ]]; then
  # crude fallback: first "text":"..." value
  text="$(printf '%s' "${payload}" | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi
[[ -n "${text//[[:space:]]/}" ]] || exit 0

# Match a remember-prefix (case-insensitive for ASCII) and strip it + any
# following separator/space. Japanese and slash forms supported.
note=""
shopt -s nocasematch 2>/dev/null || true
if [[ "${text}" =~ ^[[:space:]]*(覚えて|おぼえて|記憶して|/remember|remember)[[:space:]]*[:：、]?[[:space:]]*(.*)$ ]]; then
  note="${BASH_REMATCH[2]}"
fi
shopt -u nocasematch 2>/dev/null || true
[[ -n "${note//[[:space:]]/}" ]] || exit 0

# Resolve gbrain; if unavailable, log and bail (never block dispatch).
if [[ -z "${GBRAIN_BIN}" ]]; then
  if command -v gbrain >/dev/null 2>&1; then
    GBRAIN_BIN="$(command -v gbrain)"
  elif [[ -x "${HOME}/.bun/bin/gbrain" ]]; then
    GBRAIN_BIN="${HOME}/.bun/bin/gbrain"
  else
    log "remember requested but gbrain not found; note dropped: ${note}"
    exit 0
  fi
fi
[[ -d "${BRAIN_DIR}" ]] || { log "brain dir missing at ${BRAIN_DIR}; note dropped: ${note}"; exit 0; }

# Capture as a user note. gbrain resolves the brain from the working directory.
if ( cd "${BRAIN_DIR}" && printf '%s' "${note}" | "${GBRAIN_BIN}" capture --stdin --type note --quiet ) >>"${LOG_FILE}" 2>&1; then
  log "remembered: ${note}"
else
  log "gbrain capture failed; note dropped: ${note}"
fi

exit 0
