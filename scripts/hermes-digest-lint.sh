#!/usr/bin/env bash
set -euo pipefail

# Validate a generated tech digest and emit structured metadata.
#
# Usage:
#   hermes-digest-lint.sh DIGEST_FILE [METADATA_FILE] [REPORT_FILE]
#
# Exit code is non-zero only for hard quality failures. Warnings are included in
# the report and metadata so operators can tune prompts without blocking posts.

DIGEST_FILE="${1:-}"
METADATA_FILE="${2:-}"
REPORT_FILE="${3:-}"
MIN_SECTIONS="${HERMES_DIGEST_MIN_SECTIONS:-4}"
MAX_SECTIONS="${HERMES_DIGEST_MAX_SECTIONS:-12}"
RECENT_WINDOW="${HERMES_DIGEST_RECENT_WINDOW:-12}"
METADATA_DIR="${HERMES_DIGEST_METADATA_DIR:-}"
X_POST_URL_REGEX='https?://(x\.com|twitter\.com)/([^/?#[:space:]]+/status|i/web/status)/[0-9][0-9]*[^[:space:])>]*'

if [[ -z "${DIGEST_FILE}" || ! -f "${DIGEST_FILE}" ]]; then
  echo "Usage: $0 DIGEST_FILE [METADATA_FILE] [REPORT_FILE]" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || {
  echo "jq is required for digest linting." >&2
  exit 2
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

errors_file="${tmpdir}/errors"
warnings_file="${tmpdir}/warnings"
sections_jsonl="${tmpdir}/sections.jsonl"
urls_file="${tmpdir}/urls"
recent_urls_file="${tmpdir}/recent-urls"
: > "${errors_file}"
: > "${warnings_file}"
: > "${sections_jsonl}"
: > "${urls_file}"
: > "${recent_urls_file}"

add_error() { printf '%s\n' "$*" >> "${errors_file}"; }
add_warning() { printf '%s\n' "$*" >> "${warnings_file}"; }
matches_category() {
  printf '%s\n' "$1" | grep -Eiq "$2"
}

created_at="$(
  awk -F '"' '/^created_at:/ { print $2; exit }' "${DIGEST_FILE}" 2>/dev/null || true
)"
digest_prefix="$(
  awk -F '"' '/^digest_prefix:/ { print $2; exit }' "${DIGEST_FILE}" 2>/dev/null || true
)"
curation_source="$(
  awk -F '"' '/^curation_source:/ { print $2; exit }' "${DIGEST_FILE}" 2>/dev/null || true
)"
requires_x_urls=1
if [[ "${curation_source}" == "jina_reader" ]]; then
  requires_x_urls=0
fi

if [[ ! -s "${DIGEST_FILE}" ]]; then
  add_error "digest file is empty"
fi

awk -v dir="${tmpdir}" '
  /^### / {
    if (in_section) close(out)
    section_count++
    out = sprintf("%s/section-%03d", dir, section_count)
    print substr($0, 5) > out
    in_section = 1
    next
  }
  in_section { print >> out }
  END {
    count_file = dir "/section-count"
    print section_count + 0 > count_file
  }
' "${DIGEST_FILE}"

section_count="$(cat "${tmpdir}/section-count")"
if (( section_count < MIN_SECTIONS || section_count > MAX_SECTIONS )); then
  add_error "section count ${section_count} is outside expected range ${MIN_SECTIONS}-${MAX_SECTIONS}"
fi

grep -Eoi "${X_POST_URL_REGEX}" "${DIGEST_FILE}" \
  | sed 's/[.,]$//' > "${urls_file}" || true
total_x_urls="$(wc -l < "${urls_file}" | tr -d ' ')"
unique_x_urls="$(sort -u "${urls_file}" | wc -l | tr -d ' ')"

if (( total_x_urls == 0 && requires_x_urls == 1 )); then
  add_error "digest has no direct X/Twitter source URLs"
elif (( total_x_urls == 0 )); then
  add_warning "digest has no direct X/Twitter source URLs because it used jina_reader fallback"
fi

if (( total_x_urls > unique_x_urls )); then
  add_warning "$((total_x_urls - unique_x_urls)) duplicate X/Twitter source URL(s) inside this digest"
fi

if grep -Eqi 'https?://(www\.)?google\.[^/[:space:]]+/search|https?://[^[:space:]]*[?&]q=' "${DIGEST_FILE}"; then
  add_error "digest appears to contain a search result URL instead of a direct source URL"
fi

if [[ -n "${METADATA_DIR}" && -d "${METADATA_DIR}" ]]; then
  find "${METADATA_DIR}" -type f -name '*.json' -print 2>/dev/null \
    | sort -r \
    | sed -n "1,${RECENT_WINDOW}p" \
    | while IFS= read -r file; do
        jq -r '.sections[]?.x_urls[]? // empty' "${file}" 2>/dev/null || true
      done \
    | sort -u > "${recent_urls_file}" || true
fi

recent_duplicate_count=0
if [[ -s "${recent_urls_file}" ]]; then
  recent_duplicate_count="$(
    comm -12 <(sort -u "${urls_file}") <(sort -u "${recent_urls_file}") \
      | tee "${tmpdir}/recent-duplicates" \
      | wc -l \
      | tr -d ' '
  )"
  if (( recent_duplicate_count > 0 )); then
    add_warning "${recent_duplicate_count} source URL(s) were already covered in recent digest metadata"
  fi
fi

category_counts_ai=0
category_counts_web=0
category_counts_tools=0
category_counts_infra=0
category_counts_security=0
category_counts_other=0

for section_file in "${tmpdir}"/section-[0-9][0-9][0-9]; do
  [[ -f "${section_file}" ]] || continue
  title="$(sed -n '1p' "${section_file}")"
  body="$(sed -n '2,$p' "${section_file}")"
  lower="$(printf '%s\n%s\n' "${title}" "${body}" | tr '[:upper:]' '[:lower:]')"

  section_urls="$(printf '%s\n' "${body}" \
    | grep -Eoi "${X_POST_URL_REGEX}" \
    | sed 's/[.,]$//' \
    | sort -u || true)"
  section_url_count="$(printf '%s\n' "${section_urls}" | sed '/^$/d' | wc -l | tr -d ' ')"
  reference_urls="$(printf '%s\n' "${body}" \
    | grep -Eoi '参照ページ:[[:space:]]*https?://[^[:space:])>]+' \
    | sed -E 's/^参照ページ:[[:space:]]*//' \
    | sort -u || true)"
  reference_url_count="$(printf '%s\n' "${reference_urls}" | sed '/^$/d' | wc -l | tr -d ' ')"
  if (( section_url_count == 0 && requires_x_urls == 1 )); then
    add_error "section '${title}' has no direct X/Twitter source URL"
  elif (( section_url_count == 0 && reference_url_count == 0 )); then
    add_error "section '${title}' has no direct reference URL"
  fi

  if matches_category "${lower}" '(^|[^[:alnum:]_])(security|cve|vulnerability|incident|auth|supply chain)([^[:alnum:]_]|$)'; then
    category="security"
    category_counts_security=$((category_counts_security + 1))
  elif matches_category "${lower}" '(^|[^[:alnum:]_])(cloud|infra|infrastructure|kubernetes|server|runtime|chip|platform)([^[:alnum:]_]|$)'; then
    category="infra"
    category_counts_infra=$((category_counts_infra + 1))
  elif matches_category "${lower}" '(^|[^[:alnum:]_])(web|browser|css|javascript|typescript|react|vue|node|frontend|backend)([^[:alnum:]_]|$)'; then
    category="web"
    category_counts_web=$((category_counts_web + 1))
  elif matches_category "${lower}" '(^|[^[:alnum:]_])(ide|tool|tools|library|libraries|database|db|testing|build tool|compiler|programming)([^[:alnum:]_]|$)'; then
    category="developer-tools"
    category_counts_tools=$((category_counts_tools + 1))
  elif matches_category "${lower}" '(^|[^[:alnum:]_])(ai|agent|agents|llm|model|models|grok|openai|claude|gemini|mcp)([^[:alnum:]_]|$)'; then
    category="ai"
    category_counts_ai=$((category_counts_ai + 1))
  else
    category="other"
    category_counts_other=$((category_counts_other + 1))
  fi

  accounts="$(
    printf '%s\n' "${section_urls}" \
      | sed '/^$/d' \
      | sed -E 's#https?://(x\.com|twitter\.com)/([^/?#]+).*#\2#' \
      | sort -u \
      | jq -R . \
      | jq -s .
  )"
  x_urls_json="$(printf '%s\n' "${section_urls}" | sed '/^$/d' | jq -R . | jq -s .)"
  ref_urls_json="$(printf '%s\n' "${reference_urls}" | sed '/^$/d' | jq -R . | jq -s .)"

  jq -n \
    --arg title "${title}" \
    --arg category "${category}" \
    --argjson x_urls "${x_urls_json}" \
    --argjson reference_urls "${ref_urls_json}" \
    --argjson accounts "${accounts}" \
    '{title: $title, category: $category, x_urls: $x_urls, reference_urls: $reference_urls, accounts: $accounts}' \
    >> "${sections_jsonl}"
done

nonzero_categories=0
for count in \
  "${category_counts_ai}" "${category_counts_web}" "${category_counts_tools}" \
  "${category_counts_infra}" "${category_counts_security}" "${category_counts_other}"; do
  (( count > 0 )) && nonzero_categories=$((nonzero_categories + 1))
done

if (( section_count > 0 )); then
  if (( category_counts_ai * 100 / section_count > 70 )); then
    add_warning "AI/category sections exceed 70%; check for topic imbalance"
  fi
fi

if (( section_count >= 8 && nonzero_categories < 3 )); then
  add_warning "digest covers fewer than three inferred topic categories"
fi

errors_json="$(jq -R . "${errors_file}" | jq -s .)"
warnings_json="$(jq -R . "${warnings_file}" | jq -s .)"
sections_json="$(jq -s . "${sections_jsonl}")"

status="pass"
if [[ -s "${errors_file}" ]]; then
  status="fail"
fi

metadata="$(
  jq -n \
    --arg status "${status}" \
    --arg digest_file "${DIGEST_FILE}" \
    --arg created_at "${created_at}" \
    --arg digest_prefix "${digest_prefix}" \
    --arg curation_source "${curation_source}" \
    --argjson section_count "${section_count}" \
    --argjson total_x_urls "${total_x_urls}" \
    --argjson unique_x_urls "${unique_x_urls}" \
    --argjson recent_duplicate_urls "${recent_duplicate_count}" \
    --argjson categories "$(jq -n \
      --argjson ai "${category_counts_ai}" \
      --argjson web "${category_counts_web}" \
      --argjson tools "${category_counts_tools}" \
      --argjson infra "${category_counts_infra}" \
      --argjson security "${category_counts_security}" \
      --argjson other "${category_counts_other}" \
      '{ai: $ai, web: $web, "developer-tools": $tools, infra: $infra, security: $security, other: $other}')" \
    --argjson errors "${errors_json}" \
    --argjson warnings "${warnings_json}" \
    --argjson sections "${sections_json}" \
    '{
      status: $status,
      digest_file: $digest_file,
      created_at: $created_at,
      digest_prefix: $digest_prefix,
      curation_source: $curation_source,
      section_count: $section_count,
      total_x_urls: $total_x_urls,
      unique_x_urls: $unique_x_urls,
      recent_duplicate_urls: $recent_duplicate_urls,
      categories: $categories,
      errors: $errors,
      warnings: $warnings,
      sections: $sections
    }'
)"

if [[ -n "${METADATA_FILE}" ]]; then
  mkdir -p "$(dirname "${METADATA_FILE}")"
  printf '%s\n' "${metadata}" > "${METADATA_FILE}"
else
  printf '%s\n' "${metadata}"
fi

if [[ -n "${REPORT_FILE}" ]]; then
  mkdir -p "$(dirname "${REPORT_FILE}")"
  {
    printf '# Digest Quality Report\n\n'
    printf -- '- Status: %s\n' "${status}"
    printf -- '- Sections: %s\n' "${section_count}"
    printf -- '- X URLs: %s total / %s unique\n' "${total_x_urls}" "${unique_x_urls}"
    printf -- '- Recent duplicate URLs: %s\n\n' "${recent_duplicate_count}"
    if [[ -s "${errors_file}" ]]; then
      printf '## Errors\n'
      sed 's/^/- /' "${errors_file}"
      printf '\n'
    fi
    if [[ -s "${warnings_file}" ]]; then
      printf '## Warnings\n'
      sed 's/^/- /' "${warnings_file}"
      printf '\n'
    fi
  } > "${REPORT_FILE}"
fi

if [[ "${status}" == "fail" ]]; then
  exit 1
fi
