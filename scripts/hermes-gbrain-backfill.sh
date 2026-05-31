#!/usr/bin/env bash
set -euo pipefail

# Phase 1 of the gbrain integration (see docs/self-growth.md).
#
# Backfills the existing self-growth state under ~/.hermes/state into a gbrain
# brain. Scheduled jobs are NOT modified by this step.
#
# gbrain's `import <dir>` has no --type flag: a page's type lives in its YAML
# frontmatter. Our digests/evaluations carry `created_at` but no `type`/`slug`,
# so we stage copies, inject `type` and a stable `slug` into the frontmatter,
# then import the staging directory. Staging keeps the originals untouched and
# makes the run idempotent (re-running rebuilds staging from source).
#
# Usage:
#   scripts/hermes-gbrain-backfill.sh            # init brain if needed, then import
#   GBRAIN_SKIP_IMPORT=1 scripts/...             # stage only, print the import cmd
#
# Env overrides:
#   GBRAIN_BIN     path to gbrain (default: resolved from PATH / ~/.bun/bin)
#   HERMES_STATE   state dir (default: ~/.hermes/state)
#   GBRAIN_BRAIN   brain dir (default: ~/.hermes/brain)

GBRAIN_BIN="${GBRAIN_BIN:-}"
STATE_DIR="${HERMES_STATE:-${HOME}/.hermes/state}"
BRAIN_DIR="${GBRAIN_BRAIN:-${HOME}/.hermes/brain}"
STAGING_DIR="${STATE_DIR}/.gbrain-staging"

if [[ -z "${GBRAIN_BIN}" ]]; then
  if command -v gbrain >/dev/null 2>&1; then
    GBRAIN_BIN="$(command -v gbrain)"
  elif [[ -x "${HOME}/.bun/bin/gbrain" ]]; then
    GBRAIN_BIN="${HOME}/.bun/bin/gbrain"
  else
    printf 'gbrain not found. Install with: bun install -g github:garrytan/gbrain\n' >&2
    exit 1
  fi
fi

log() { printf '%s\n' "$*" >&2; }

# slug_for FILE TYPE -> "<type>-<timestamp>" from the filename stem.
slug_for() {
  local file="$1" type="$2" stem
  stem="$(basename "${file}" .md)"
  printf '%s-%s' "${type}" "${stem}"
}

# stage_one SRC TYPE: copy SRC into staging with `type`/`slug` ensured in its
# leading `---` frontmatter block. If the source has no frontmatter, one is
# created. Idempotent: existing `type`/`slug` keys are left as-is.
stage_one() {
  local src="$1" type="$2"
  local slug dest
  slug="$(slug_for "${src}" "${type}")"
  dest="${STAGING_DIR}/${slug}.md"

  if [[ "$(sed -n '1p' "${src}")" == "---" ]]; then
    # Has frontmatter: inject type/slug after the opening --- unless present.
    awk -v type="${type}" -v slug="${slug}" '
      NR == 1 { print; in_fm = 1; printed = 1
                print "type: \"" type "\""
                print "slug: \"" slug "\""
                next }
      in_fm && /^type:/ { next }   # drop any pre-existing to avoid duplicates
      in_fm && /^slug:/ { next }
      in_fm && $0 == "---" { in_fm = 0 }
      { print }
    ' "${src}" > "${dest}"
  else
    {
      printf -- '---\n'
      printf 'type: "%s"\n' "${type}"
      printf 'slug: "%s"\n' "${slug}"
      printf -- '---\n\n'
      cat "${src}"
    } > "${dest}"
  fi
  log "  staged ${slug}"
}

stage_dir() {
  local dir="$1" type="$2" count=0
  [[ -d "${dir}" ]] || { log "  (no ${dir})"; return; }
  while IFS= read -r -d '' f; do
    stage_one "${f}" "${type}"
    count=$((count + 1))
  done < <(find "${dir}" -maxdepth 1 -type f -name '*.md' -print0)
  log "  ${type}: ${count} file(s)"
}

log "Staging into ${STAGING_DIR}"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

stage_dir "${STATE_DIR}/digests"            digest
stage_dir "${STATE_DIR}/evaluations"        evaluation
stage_dir "${STATE_DIR}/weekly-reflections" reflection

staged_count="$(find "${STAGING_DIR}" -type f -name '*.md' | wc -l | tr -d ' ')"
if [[ "${staged_count}" == "0" ]]; then
  log "Nothing to backfill (no state files found under ${STATE_DIR})."
  exit 0
fi
log "Staged ${staged_count} page(s)."

if [[ "${GBRAIN_SKIP_IMPORT:-}" == "1" ]]; then
  log "GBRAIN_SKIP_IMPORT=1 set; skipping init/import."
  log "To import manually: '${GBRAIN_BIN}' import '${STAGING_DIR}'"
  exit 0
fi

# Initialize the brain once (PGLite, no server). gbrain stores its brain in a
# default location; we run init from the brain dir so the repo lives there.
#
# Embeddings need an external provider key (OPENAI/VOYAGE/ZEROENTROPY). Phase 1
# only needs the brain to exist and ingest pages, so we default to
# --no-embedding (keyword search works; vector search is enabled in Phase 2 via
# `gbrain config set embedding_model …` once a key is available). Set
# GBRAIN_EMBED=1 (with a provider key exported) to init with embeddings now.
if [[ ! -d "${BRAIN_DIR}" ]]; then
  log "Initializing brain at ${BRAIN_DIR} (PGLite)"
  mkdir -p "${BRAIN_DIR}"
  if [[ "${GBRAIN_EMBED:-}" == "1" ]]; then
    ( cd "${BRAIN_DIR}" && "${GBRAIN_BIN}" init --pglite )
  else
    ( cd "${BRAIN_DIR}" && "${GBRAIN_BIN}" init --pglite --no-embedding )
  fi
fi

# Import from the brain dir so gbrain resolves the brain we just created.
# --no-embed skips embedding generation at import time (matches --no-embedding).
log "Importing staged pages into the brain"
if [[ "${GBRAIN_EMBED:-}" == "1" ]]; then
  ( cd "${BRAIN_DIR}" && "${GBRAIN_BIN}" import "${STAGING_DIR}" )
else
  ( cd "${BRAIN_DIR}" && "${GBRAIN_BIN}" import "${STAGING_DIR}" --no-embed )
fi

log "Done. Verify with: '${GBRAIN_BIN}' list -n 20"
