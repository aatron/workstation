#!/usr/bin/env bash
#
# worktree-launch.sh — herdr-plus quick-action entrypoint.
#
# herdr-plus runs actions inside the overlay picker (stdin=/dev/null, TUI already
# tearing down). gum cannot prompt there. This opens a real tab and submits the
# target script into that pane via `herdr pane run`.
#
# Usage:
#   worktree-launch.sh development [ws] [cwd]                                    -> make-worktree.sh development
#   worktree-launch.sh remove [ws] [cwd] [story-id]                              -> worktree-remove.sh
#   worktree-launch.sh new-review [ws] [cwd] [work-item-id]                      -> review-make.sh <id>
#   worktree-launch.sh remove-review [ws] [cwd] [work-item-id|empty]             -> review-remove.sh [<id>]
#   worktree-launch.sh reap [ws] [cwd]                                           -> story-reap.sh
#   worktree-launch.sh az-sync [ws] [cwd]                                        -> az-watcher run
#
# There is deliberately NO 'review' action here. `make-worktree.sh review` still
# exists, but it is branch-driven: it wants a story id, a slug and a
# <repo>:<branch> list, which is a lot to type for something a tool can work out
# on its own. Only az-watcher drives it now — it reads your Azure assignments and
# supplies WT_ID / WT_SLUG / WT_BRANCHES_FILE itself. To create review worktrees
# by hand, run 'az-watcher new-review' (or the 'Sync Azure Reviews' quick
# action). 'new-review' below is a different feature again: the read-only code
# review of a work item's pull requests (review-make.sh).
#
set -euo pipefail

ACTION="${1:-}"
WS="${2:-}"
CWD="${3:-}"
STORY_ID="${4:-}"

case "$ACTION" in
  development)         SCRIPT="${HOME}/bin/make-worktree.sh"; RUN_ARGS="$ACTION"; label="New Dev Worktree" ;;
  remove)              SCRIPT="${HOME}/bin/worktree-remove.sh"; RUN_ARGS="$STORY_ID"; label="Delete Story Worktree" ;;
  new-review)
    [[ -n "$STORY_ID" ]] || { echo "new-review needs the Azure DevOps work item id" >&2; exit 1; }
    SCRIPT="${HOME}/bin/review-make.sh"; RUN_ARGS="$STORY_ID"; label="Review ${STORY_ID}" ;;
  remove-review)
    # An empty id is meaningful here: it means "examine every review".
    SCRIPT="${HOME}/bin/review-remove.sh"; RUN_ARGS="$STORY_ID"
    if [[ -n "$STORY_ID" ]]; then label="Clean Up Review ${STORY_ID}"; else label="Clean Up Reviews"; fi ;;
  # No args: the script finds the finished stories itself and asks before it
  # deletes anything. A scheduled run passes --yes instead, and never comes
  # through here.
  reap)                SCRIPT="${HOME}/bin/story-reap.sh"; RUN_ARGS=""; label="Clean Up Closed Stories" ;;
  # az-watcher is non-interactive; the tab just makes its log visible.
  az-sync)             SCRIPT="${HOME}/bin/az-watcher"; RUN_ARGS="run"; label="Sync Azure Reviews" ;;
  *)
    echo "usage: $0 <development|new-review|remove-review|remove|reap|az-sync> [workspace_id] [cwd] [story-or-work-item-id]" >&2
    exit 1 ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need herdr
need jq
[[ -x "$SCRIPT" || -f "$SCRIPT" ]] || {
  echo "missing $SCRIPT (run install.sh)" >&2
  exit 1
}

args=(tab create --label "$label" --focus)
[[ -n "$WS" ]] && args+=(--workspace "$WS")
[[ -n "$CWD" ]] && args+=(--cwd "$CWD")

out="$(herdr "${args[@]}")"
pane="$(jq -r '.result.root_pane.pane_id // empty' <<<"$out")"
[[ -n "$pane" ]] || {
  echo "herdr tab create failed:" >&2
  echo "$out" >&2
  exit 1
}

# Submit into the new pane's shell (returns immediately; script runs interactively).
herdr pane run "$pane" "${SCRIPT} ${RUN_ARGS}" || {
  echo "herdr pane run failed for pane ${pane}" >&2
  exit 1
}

exit 0
