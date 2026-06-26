#!/usr/bin/env bash
set -euo pipefail

exec "$(dirname "$0")/hermes-mnemo-memory.py" capture-event
