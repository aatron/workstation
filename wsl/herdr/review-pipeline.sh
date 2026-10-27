#!/usr/bin/env bash
#
# review-pipeline.sh
# Idiomatic review pipeline for one work item. The Orchestrator herdr tab runs
# this script.
#
#   A     Enabled reviewer tab(s) write findings-* (parallel when both on)
#   1     Wait until enabled findings files are ready
#   2–3   Cross-review in parallel — only when BOTH Claude and Cursor are on
#   4     Reconcile in an interactive Claude session (this Orchestrator pane)
#         so you can read the results and keep asking questions
#
# Stages 2–3 use --print (headless). Stage 4 does not — it stays open here.
#
# Toggles come from review-make.sh via env (flip REVIEW_ENABLE_* there):
#   WT_REVIEW_ENABLE_CLAUDE  WT_REVIEW_ENABLE_CURSOR  (1 or 0)
#
# usage:
#   review-pipeline.sh <item-dir> <work-item-id>
#
set -euo pipefail

usage() {
  echo "usage: review-pipeline.sh <item-dir> <work-item-id>" >&2
  exit 1
}
(($# == 2)) || usage

ITEM_DIR="$(cd "$1" && pwd)"
ID="$2"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin_or_here() {
  # Split locals: `local a="$1" b="$a"` leaves a unbound while expanding b (set -u).
  local name="$1"
  local p="${HOME}/bin/${name}"
  [[ -n "$name" && ( -x "$p" || -f "$p" ) ]] && { printf '%s' "$p"; return 0; }
  printf '%s' "${here}/${name}"
}

WAIT_READY="$(bin_or_here review-wait-ready.sh)"
F_CLAUDE="${ITEM_DIR}/review-${ID}-findings-claude.md"
F_CURSOR="${ITEM_DIR}/review-${ID}-findings-cursor.md"
X_CLAUDE="${ITEM_DIR}/review-${ID}-cross-claude.md"
X_CURSOR="${ITEM_DIR}/review-${ID}-cross-cursor.md"
P_CROSS_CLAUDE="${ITEM_DIR}/review-${ID}-cross-claude-prompt.md"
P_CROSS_CURSOR="${ITEM_DIR}/review-${ID}-cross-cursor-prompt.md"
P_ORCH="${ITEM_DIR}/review-${ID}-orchestrator-prompt.md"
LOG_C="${ITEM_DIR}/review-${ID}-cross-claude.log"
LOG_U="${ITEM_DIR}/review-${ID}-cross-cursor.log"

ORCH_MODEL="${WT_REVIEW_ORCHESTRATOR_MODEL:-claude-opus-4-5}"
REVIEW_MODEL="${WT_REVIEW_REVIEWER_MODEL:-claude-opus-4-5}"
PERM="${WT_REVIEW_PERMISSION_MODE:-acceptEdits}"
ENABLE_CLAUDE="${WT_REVIEW_ENABLE_CLAUDE:-1}"
ENABLE_CURSOR="${WT_REVIEW_ENABLE_CURSOR:-1}"
# Word-split on purpose (same flags as review-make CURSOR_CMD).
# shellcheck disable=SC2206
CURSOR_CMD=( ${WT_REVIEW_CURSOR_CMD:-agent --trust --approve-mcps --sandbox enabled --force} )

ALLOW_REVIEW='Bash(git *),Edit,Write,Read'
DENY_REVIEW='Bash(git commit:*),Bash(git push:*),Bash(git add:*),Bash(git reset:*),Bash(git checkout:*),Bash(git switch:*),Bash(git rebase:*),Bash(git merge:*),Bash(git cherry-pick:*),Bash(git worktree:*),Bash(az boards:*),Bash(az repos pr update:*),Bash(az repos pr set-vote:*),Bash(az repos pr reviewer:*),Bash(az devops invoke:*)'
ALLOW_ORCH='Bash(git *),Bash(review-post-comments*),Bash(*review-post-comments.sh*),Edit,Write,Read'
DENY_ORCH='Bash(git commit:*),Bash(git push:*),Bash(git add:*),Bash(git reset:*),Bash(git checkout:*),Bash(git switch:*),Bash(git rebase:*),Bash(git merge:*),Bash(git cherry-pick:*),Bash(git worktree:*),Bash(az boards:*),Bash(az repos pr update:*),Bash(az repos pr set-vote:*),Bash(az repos pr reviewer:*)'

if (( ! ENABLE_CLAUDE && ! ENABLE_CURSOR )); then
  echo "WT_REVIEW_ENABLE_CLAUDE and WT_REVIEW_ENABLE_CURSOR are both 0" >&2
  exit 1
fi
DUAL=0
(( ENABLE_CLAUDE && ENABLE_CURSOR )) && DUAL=1

need_file() {
  [[ -f "$1" ]] || { echo "missing $1 (re-run review-make.sh for this item)" >&2; exit 1; }
}
need_file "$P_ORCH"
if (( DUAL )); then
  need_file "$P_CROSS_CLAUDE"
  need_file "$P_CROSS_CURSOR"
fi

echo "=== review pipeline ${ID} ==="
echo "item: ${ITEM_DIR}"
echo "reviewers: claude=${ENABLE_CLAUDE} cursor=${ENABLE_CURSOR} dual=${DUAL}"

echo
echo "--- stage 1: wait for independent findings ---"
wait_findings=()
(( ENABLE_CLAUDE )) && wait_findings+=("$F_CLAUDE")
(( ENABLE_CURSOR )) && wait_findings+=("$F_CURSOR")
"$WAIT_READY" --marker 'Verified sound' --min-bytes 100 "${wait_findings[@]}"

if (( DUAL )); then
  echo
  echo "--- stage 2: cross-review in parallel (claude -p + agent -p) ---"
  : > "$X_CLAUDE"
  : > "$X_CURSOR"
  : > "$LOG_C"
  : > "$LOG_U"

  claude -p --model "$REVIEW_MODEL" --permission-mode "$PERM" \
    --allowed-tools "$ALLOW_REVIEW" --disallowed-tools "$DENY_REVIEW" \
    -- "$(cat "$P_CROSS_CLAUDE")" >"$LOG_C" 2>&1 &
  pid_c=$!

  role_u="You are the Cursor Auto Reviewer on the cross-review pass. Write only to ${X_CURSOR}."
  "${CURSOR_CMD[@]}" -p -- "$role_u" "$(cat "$P_CROSS_CURSOR")" >"$LOG_U" 2>&1 &
  pid_u=$!

  echo "cross Claude pid=${pid_c}  log=${LOG_C}"
  echo "cross Cursor pid=${pid_u}  log=${LOG_U}"

  echo
  echo "--- stage 3: wait for both cross-review files ---"
  if ! "$WAIT_READY" --marker '## Cross-review complete' --min-bytes 80 "$X_CLAUDE" "$X_CURSOR"; then
    echo "cross-review wait failed; last log lines:" >&2
    tail -n 40 "$LOG_C" "$LOG_U" >&2 || true
    kill "$pid_c" "$pid_u" 2>/dev/null || true
    wait "$pid_c" "$pid_u" 2>/dev/null || true
    exit 1
  fi
  c_ec=0
  u_ec=0
  wait "$pid_c" || c_ec=$?
  wait "$pid_u" || u_ec=$?
  (( c_ec == 0 )) || echo "WARNING: cross Claude exited ${c_ec} (see ${LOG_C})" >&2
  (( u_ec == 0 )) || echo "WARNING: cross Cursor exited ${u_ec} (see ${LOG_U})" >&2
else
  echo
  echo "--- stages 2–3: skip cross-review (single reviewer; no swap) ---"
fi

echo
echo "--- stage 4: reconcile (interactive Claude in this pane) ---"
echo "Artifacts stay under ${ITEM_DIR}; ask follow-ups here when it finishes the pass."
exec claude --model "$ORCH_MODEL" --permission-mode "$PERM" \
  --allowed-tools "$ALLOW_ORCH" --disallowed-tools "$DENY_ORCH" \
  -- "$(cat "$P_ORCH")"
