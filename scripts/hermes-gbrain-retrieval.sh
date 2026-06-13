#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.bun/bin:${PATH}"

# Phase 2 of the gbrain integration (see docs/self-growth.md): retrieval
# injection helper.
#
# Queries the gbrain brain for what recent digests already covered and what the
# evaluations flagged, and prints a short Japanese guidance block to stdout for
# the digest prompt to inject as SOFT guidance. It is deliberately
# defensive: any missing brain, missing binary, or query failure prints nothing
# and exits 0, so scheduled digests are never broken by this step.
#
# Usage:
#   scripts/hermes-gbrain-retrieval.sh ["topic hint word"]
#
# Env overrides:
#   GBRAIN_BIN          path to gbrain (default: resolved from PATH / ~/.bun/bin)
#   GBRAIN_BRAIN        brain dir (default: ~/.hermes/brain)
#   GBRAIN_SEARCH_MODE  "search" (keyword, default) | "query" (hybrid; needs an
#                       embedding provider key configured in the brain)
#   GBRAIN_RECALL_N     max hits to show per section (default: 5)

GBRAIN_BIN="${GBRAIN_BIN:-}"
BRAIN_DIR="${GBRAIN_BRAIN:-${HOME}/.hermes/brain}"
SEARCH_MODE="${GBRAIN_SEARCH_MODE:-search}"
RECALL_N="${GBRAIN_RECALL_N:-5}"
HINT="${1:-エージェント}"

# Resolve gbrain; bail quietly if unavailable (digest must not break).
if [[ -z "${GBRAIN_BIN}" ]]; then
  if command -v gbrain >/dev/null 2>&1; then
    GBRAIN_BIN="$(command -v gbrain)"
  elif [[ -x "${HOME}/.bun/bin/gbrain" ]]; then
    GBRAIN_BIN="${HOME}/.bun/bin/gbrain"
  else
    exit 0
  fi
fi

[[ -d "${BRAIN_DIR}" ]] || exit 0

# gbrain resolves the brain from the working directory. Never let a failure
# here abort the script (digest must keep running).
run_gbrain() { ( cd "${BRAIN_DIR}" && "${GBRAIN_BIN}" "$@" 2>/dev/null ) || true; }

# search/query output lines look like: "[score] slug -- <first content line>".
# hits_for WORD SLUG_REGEX: pull those header lines, keep matching slugs,
# rewrite to "- <title>", cap at RECALL_N. grep -m caps without SIGPIPE noise;
# trailing "|| true" keeps a zero-match grep from tripping `set -e`.
hits_for() {
  local word="$1" slug_re="$2"
  run_gbrain "${SEARCH_MODE}" "${word}" \
    | grep -E '^\[[0-9.]+\] ' \
    | grep -E "${slug_re}" \
    | sed -E 's/^\[[0-9.]+\] [^ ]+ -- /- /' \
    | head -n "${RECALL_N}" \
    || true
}

# latest_eval_slug: newest evaluation page slug, or empty. Slugs are
# evaluation-YYYYMMDD-HHMMSS, so a reverse lexical sort yields newest first.
# This is more reliable than `list` date order when many pages share an
# import date (e.g. after a backfill).
latest_eval_slug="$(
  run_gbrain list --type evaluation -n 100 \
    | awk -F '\t' 'NF>=1 { print $1 }' \
    | sort -r \
    | head -n 1 \
    || true
)"

# improvement_block: the "## 次回の改善指示" section body of the latest
# evaluation (the actionable guidance), bullet lines only, capped.
improvement_block=""
if [[ -n "${latest_eval_slug}" ]]; then
  improvement_block="$(
    run_gbrain get "${latest_eval_slug}" \
      | awk '
          /^## 次回の改善指示/ { grab=1; next }
          grab && /^## / { grab=0 }
          grab && /^- / { print }
        ' \
      | head -n "${RECALL_N}" \
      || true
  )"
fi

topic_hits="$(hits_for "${HINT}" 'digest-')"

# user_notes: the most recent direct user guidance pages — things the user
# explicitly asked ヘルメスちゃん to remember, feedback on past posts, or topics
# to track/deep-dive. These rank above the auto-derived guidance below. The page
# title is the note text, which `list` exposes in column 4.
user_notes="$(
  {
    run_gbrain list --type note -n 100
    run_gbrain list --type feedback -n 100
    run_gbrain list --type followup -n 100
  } \
    | awk -F '\t' 'NF>=4 && $4 != "" { print $1 "\t" $4 }' \
    | sort -r \
    | head -n "${RECALL_N}" \
    | cut -f2- \
    | sed -E 's/^/- /' \
    || true
)"

# Nothing useful -> print nothing (digest falls back to flat memory only).
if [[ -z "${topic_hits//[[:space:]]/}" \
   && -z "${improvement_block//[[:space:]]/}" \
   && -z "${user_notes//[[:space:]]/}" ]]; then
  exit 0
fi

printf '## 直近のブレインからのソフトガイダンス\n'
printf '（過去のダイジェストと自己評価、ユーザーからの指示をブレインから引いたもの。）\n\n'

if [[ -n "${user_notes//[[:space:]]/}" ]]; then
  printf '### ユーザーからの記憶・評価・追跡依頼（優先的に守る）\n'
  printf '%s\n\n' "${user_notes}"
fi

if [[ -n "${topic_hits//[[:space:]]/}" ]]; then
  printf '### 最近触れた話題に近い既出（重複・過剰反復を避ける）\n'
  printf '%s\n\n' "${topic_hits}"
fi

if [[ -n "${improvement_block//[[:space:]]/}" ]]; then
  printf '### 直近の自己評価が出した改善指示（今回意識する）\n'
  printf '%s\n' "${improvement_block}"
fi
