#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.bun/bin:${PATH}"

HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
PROMPT_DIR="${HERMES_PROMPT_DIR:-${HOME}/.hermes/prompts}"
STATE_DIR="${HOME}/.hermes/state"
LOG_DIR="${HOME}/.hermes/logs"
MEMORY_FILE="${HERMES_CHAN_MEMORY_FILE:-${STATE_DIR}/hermes-chan-memory.md}"
REFLECTION_PROMPT_FILE="${PROMPT_DIR}/weekly-self-reflection.md"
IDENTITY_FILE="${PROMPT_DIR}/hermes-chan-identity.md"
EVAL_DIR="${STATE_DIR}/evaluations"
REPORT_DIR="${STATE_DIR}/weekly-reflections"
LOG_FILE="${LOG_DIR}/hermes-weekly-self-reflection.log"
LOCK_DIR="${STATE_DIR}/hermes-weekly-self-reflection.lock"
LOCK_PID="${LOCK_DIR}/pid"

# gbrain reconcile (Phase 4, see docs/self-growth.md). Off by default.
# The brain's primary store is the PGLite DB created by `gbrain init`; the
# markdown "brain repo" under PAGES_DIR is the exported, git-tracked view that
# `gbrain dream` operates on.
GBRAIN_PAGES_DIR="${GBRAIN_PAGES_DIR:-${HOME}/.hermes/brain/pages}"

mkdir -p "${STATE_DIR}" "${LOG_DIR}" "${EVAL_DIR}" "${REPORT_DIR}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}"
}

resolve_gbrain_bin() {
  if [[ -n "${GBRAIN_BIN:-}" ]]; then
    printf '%s' "${GBRAIN_BIN}"
  elif command -v gbrain >/dev/null 2>&1; then
    command -v gbrain
  elif [[ -x "${HOME}/.bun/bin/gbrain" ]]; then
    printf '%s' "${HOME}/.bun/bin/gbrain"
  fi
}

# gbrain_put SLUG TYPE BODY: upsert a page into the brain DB via stdin.
# Echoes nothing; returns non-zero on failure. Caller logs.
gbrain_put() {
  local bin="$1" slug="$2" type="$3" body="$4"
  {
    printf -- '---\n'
    printf 'type: "%s"\n' "${type}"
    printf 'slug: "%s"\n' "${slug}"
    printf 'created_at: "%s"\n' "${now}"
    printf -- '---\n\n'
    printf '%s\n' "${body}"
  } | "${bin}" put "${slug}"
}

# gbrain_reconcile LEARNINGS_SLUG LEARNINGS_BODY: Phase 4 brain reconcile.
# Off unless HERMES_GBRAIN_RECONCILE=1. Steps, each defensive (logged + ignored
# on failure so the weekly memory update is never blocked):
#   1. upsert a learnings-<week> page from the reflection,
#   2. export the DB to the git-tracked markdown brain repo and commit it,
#   3. run `gbrain dream --dir` once (lint, backlinks, consolidate, ...).
gbrain_reconcile() {
  local learnings_slug="$1" learnings_body="$2"
  [[ "${HERMES_GBRAIN_RECONCILE:-}" == "1" ]] || return 0

  local bin
  bin="$(resolve_gbrain_bin)"
  if [[ -z "${bin}" ]]; then
    log "gbrain reconcile enabled but gbrain not found; skipping"
    return 0
  fi

  if [[ -n "${learnings_body//[[:space:]]/}" ]]; then
    if gbrain_put "${bin}" "${learnings_slug}" "reflection" "${learnings_body}" \
         >>"${LOG_FILE}" 2>&1; then
      log "gbrain learnings upsert ok: ${learnings_slug}"
    else
      log "gbrain learnings upsert failed: ${learnings_slug}; continuing"
    fi
  fi

  mkdir -p "${GBRAIN_PAGES_DIR}"
  if "${bin}" export --dir "${GBRAIN_PAGES_DIR}" >>"${LOG_FILE}" 2>&1; then
    log "gbrain export ok: ${GBRAIN_PAGES_DIR}"
    # Commit the exported repo so dream's writes are revertable (Safety Boundary).
    local repo="${GBRAIN_PAGES_DIR}"
    if ! git -C "${repo}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "${repo}" init -q >>"${LOG_FILE}" 2>&1 || true
    fi
    git -C "${repo}" add -A >>"${LOG_FILE}" 2>&1 || true
    git -C "${repo}" -c user.name=hermes -c user.email=hermes@localhost \
      commit -q -m "weekly export ${timestamp}" >>"${LOG_FILE}" 2>&1 \
      || log "gbrain export commit skipped (nothing to commit?)"
  else
    log "gbrain export failed; skipping dream"
    return 0
  fi

  if "${bin}" dream --dir "${GBRAIN_PAGES_DIR}" >>"${LOG_FILE}" 2>&1; then
    log "gbrain dream cycle ok"
  else
    log "gbrain dream cycle failed; continuing"
  fi
}

read_optional_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    sed -n '1,260p' "${file}"
  fi
}

latest_files_content() {
  local dir="$1"
  local limit="$2"

  if ! find "${dir}" -type f -name '*.md' -print -quit | grep -q .; then
    return
  fi

  find "${dir}" -type f -name '*.md' -print0 \
    | xargs -0 ls -t \
    | sed -n "1,${limit}p" \
    | while IFS= read -r file; do
        printf '\n\n## %s\n\n' "${file}"
        sed -n '1,220p' "${file}"
      done
}

if [[ ! -x "${HERMES_BIN}" ]]; then
  log "missing hermes binary: ${HERMES_BIN}"
  exit 1
fi

if [[ ! -f "${REFLECTION_PROMPT_FILE}" ]]; then
  log "missing reflection prompt: ${REFLECTION_PROMPT_FILE}"
  exit 1
fi

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  if [[ -f "${LOCK_PID}" ]]; then
    previous_pid="$(<"${LOCK_PID}")"
    if [[ "${previous_pid}" =~ ^[0-9]+$ ]] && kill -0 "${previous_pid}" 2>/dev/null; then
      log "previous weekly reflection still running pid=${previous_pid}; skipping"
      exit 0
    fi
  fi

  log "removing stale weekly reflection lock"
  rm -rf "${LOCK_DIR}"
  mkdir "${LOCK_DIR}"
fi
printf '%s\n' "$$" > "${LOCK_PID}"
trap 'rm -rf "${LOCK_DIR}" 2>/dev/null || true' EXIT

now="$(date '+%Y-%m-%d %H:%M:%S %z')"
timestamp="$(date '+%Y%m%d-%H%M%S')"
current_memory="$(read_optional_file "${MEMORY_FILE}")"
identity_context="$(read_optional_file "${IDENTITY_FILE}")"
evaluation_context="$(latest_files_content "${EVAL_DIR}" 21)"

if [[ -z "${evaluation_context//[[:space:]]/}" ]]; then
  log "no evaluation logs found; skipping weekly reflection"
  exit 0
fi

prompt="$(printf '%s\n\n# Current time\n%s\n\n# Identity\n%s\n\n# Current memory\n%s\n\n# Recent self-evaluations\n%s\n' \
  "$(read_optional_file "${REFLECTION_PROMPT_FILE}")" \
  "${now}" \
  "${identity_context}" \
  "${current_memory}" \
  "${evaluation_context}")"

log "starting weekly self-reflection"
if updated_memory="$("${HERMES_BIN}" -z "${prompt}" 2>>"${LOG_FILE}")"; then
  if [[ -z "${updated_memory//[[:space:]]/}" ]]; then
    log "weekly reflection returned empty output"
    exit 1
  fi

  report_file="${REPORT_DIR}/${timestamp}.md"
  printf '%s\n' "${updated_memory}" > "${report_file}"
  install -m 600 "${report_file}" "${MEMORY_FILE}"
  log "updated memory from weekly reflection: ${MEMORY_FILE}"

  # Phase 4: reconcile the brain (learnings page + export/commit + dream).
  # Flag-gated and defensive; the flat memory update above already succeeded.
  gbrain_reconcile "learnings-${timestamp}" "${updated_memory}"
else
  code=$?
  log "weekly self-reflection failed exit=${code}"
  exit "${code}"
fi
