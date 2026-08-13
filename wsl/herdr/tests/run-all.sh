#!/usr/bin/env bash
# Run every throwaway-fixture unit test under tests/.
set -euo pipefail
cd "$(dirname "$0")"
bash test-worktree-make.sh
bash test-worktree-remove.sh
echo "OK all tests passed"
