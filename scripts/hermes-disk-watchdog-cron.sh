#!/usr/bin/env bash
set -euo pipefail

THRESHOLD="${HERMES_DISK_WATCHDOG_THRESHOLD:-90}"
PATHS_VALUE="${HERMES_DISK_WATCHDOG_PATHS:-/}"

[[ "${THRESHOLD}" =~ ^[0-9]+$ ]] || {
  printf 'Hermes disk watchdog misconfigured: HERMES_DISK_WATCHDOG_THRESHOLD=%s is not an integer\n' "${THRESHOLD}"
  exit 0
}

output=""
while IFS= read -r path; do
  [[ -n "${path}" ]] || continue
  if ! line="$(df -P "${path}" 2>/dev/null | awk 'NR == 2 { print $0 }')"; then
    output+=$'\n'"- ${path}: df failed"
    continue
  fi
  [[ -n "${line}" ]] || {
    output+=$'\n'"- ${path}: df returned no data"
    continue
  }
  usage_pct="$(awk '{ gsub(/%/, "", $5); print $5 }' <<< "${line}")"
  mount_point="$(awk '{ print $6 }' <<< "${line}")"
  if [[ "${usage_pct}" =~ ^[0-9]+$ && "${usage_pct}" -ge "${THRESHOLD}" ]]; then
    output+=$'\n'"- ${mount_point}: ${usage_pct}% used (threshold ${THRESHOLD}%)"
  fi
done < <(tr ',:' '\n' <<< "${PATHS_VALUE}")

if [[ -n "${output}" ]]; then
  printf 'Hermes disk watchdog: attention needed\n%s\n' "${output}"
fi
