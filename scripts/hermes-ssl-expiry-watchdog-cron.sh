#!/usr/bin/env bash
set -euo pipefail

HOSTS_VALUE="${HERMES_SSL_WATCH_HOSTS:-}"
THRESHOLD_DAYS="${HERMES_SSL_WATCH_THRESHOLD_DAYS:-14}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

[[ -n "${HOSTS_VALUE//[[:space:],]/}" ]] || exit 0
[[ "${THRESHOLD_DAYS}" =~ ^[0-9]+$ ]] || {
  printf 'Hermes SSL expiry watchdog misconfigured: HERMES_SSL_WATCH_THRESHOLD_DAYS=%s is not an integer\n' "${THRESHOLD_DAYS}"
  exit 0
}
command -v "${OPENSSL_BIN}" >/dev/null 2>&1 || {
  printf 'Hermes SSL expiry watchdog: openssl is not available\n'
  exit 0
}

parse_expiry_epoch() {
  local end_date="$1"
  date -j -f '%b %e %T %Y %Z' "${end_date}" '+%s' 2>/dev/null \
    || date -d "${end_date}" '+%s' 2>/dev/null
}

check_host() {
  local host_port="$1" host port cert_info end_date expiry now days_left
  host="${host_port%%:*}"
  port="${host_port#*:}"
  [[ "${port}" != "${host}" ]] || port="443"
  [[ -n "${host}" ]] || return 0

  if ! cert_info="$(printf '' | "${OPENSSL_BIN}" s_client -servername "${host}" -connect "${host}:${port}" 2>/dev/null | "${OPENSSL_BIN}" x509 -noout -enddate 2>/dev/null)"; then
    printf -- '- %s:%s: certificate check failed\n' "${host}" "${port}"
    return 0
  fi
  end_date="${cert_info#notAfter=}"
  if ! expiry="$(parse_expiry_epoch "${end_date}")"; then
    printf -- '- %s:%s: could not parse expiry date: %s\n' "${host}" "${port}" "${end_date}"
    return 0
  fi
  now="$(date '+%s')"
  days_left="$(( (expiry - now) / 86400 ))"
  if (( days_left <= THRESHOLD_DAYS )); then
    printf -- '- %s:%s: certificate expires in %s day(s), notAfter=%s\n' "${host}" "${port}" "${days_left}" "${end_date}"
  fi
}

output=""
while IFS= read -r host; do
  [[ -n "${host}" ]] || continue
  result="$(check_host "${host}")"
  [[ -z "${result}" ]] || output+=$'\n'"${result}"
done < <(tr ', ' '\n' <<< "${HOSTS_VALUE}")

if [[ -n "${output}" ]]; then
  printf 'Hermes SSL expiry watchdog: attention needed\n%s\n' "${output}"
fi
