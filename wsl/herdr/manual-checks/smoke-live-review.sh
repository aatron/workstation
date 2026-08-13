#!/usr/bin/env bash
# Opt-in LIVE smoke: real az + clones under SRC_ROOT. Never called from run-all.
#
# usage: smoke-live-review.sh <work-item-id>
#        WT_REVIEW_SRC_ROOT=~/source/repos smoke-live-review.sh 23597
#
# Creates a review layout for the work item, then prints cleanup hints.
# Does not pass --yes to remove; you clean up deliberately.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID="${1:-${WT_REVIEW_ID:-}}"
if [[ -z "$ID" || ! "$ID" =~ ^[0-9]+$ ]]; then
  echo "usage: smoke-live-review.sh <work-item-id>" >&2
  echo "Refusing to run without an explicit numeric work item id." >&2
  exit 2
fi
if [[ -n "${WT_REVIEW_AZ:-}" ]]; then
  echo "WT_REVIEW_AZ is set; unset it for a live run against real az." >&2
  exit 2
fi
echo "-> live review-make for work item $ID (real az, SRC_ROOT=${WT_REVIEW_SRC_ROOT:-default})"
bash "$ROOT/review-make.sh" "$ID"
echo
echo "OK review created for $ID."
echo "Cleanup when done:"
echo "  bash $ROOT/review-remove.sh $ID --yes"
