#!/usr/bin/env bash
#
# review-wait-findings.sh — thin wrapper (stage 1 of the review pipeline).
# usage: review-wait-findings.sh <findings-claude.md> <findings-cursor.md>
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wait_ready="${HOME}/bin/review-wait-ready.sh"
[[ -x "$wait_ready" || -f "$wait_ready" ]] || wait_ready="${here}/review-wait-ready.sh"
(($# == 2)) || {
  echo "usage: review-wait-findings.sh <findings-claude.md> <findings-cursor.md>" >&2
  exit 1
}
exec "$wait_ready" --marker 'Verified sound' --min-bytes 100 "$1" "$2"
