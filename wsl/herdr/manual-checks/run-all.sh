#!/usr/bin/env bash
# Run every stubbed manual-check (not live smoke). Requires herdr for review suites.
set -euo pipefail
cd "$(dirname "$0")"
bash check-review-make.sh
bash check-review-remove.sh
bash check-story-reap.sh
echo "OK all manual-checks passed"
