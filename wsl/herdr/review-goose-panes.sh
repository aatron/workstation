#!/usr/bin/env bash
#
# review-goose-panes.sh
# Progress panes for Review - Goose. Goose stays LEFT; progress always opens to
# the RIGHT of Goose (then stacked down on that right column).
#
# usage:
#   review-goose-panes.sh open reviewers  <item_dir> <work_item_id> <cursor_cmd...>
#   review-goose-panes.sh open cross      <item_dir> <work_item_id> <cursor_cmd...>
#   review-goose-panes.sh open reconcile  <item_dir> <work_item_id> <cursor_cmd...>
#   review-goose-panes.sh close           <item_dir> <work_item_id>
#
# Requires HERDR_PANE_ID = the Goose pane (herdr sets this in the Goose tab).
# Reviewers/cross: Claude (top) + Cursor (bottom). Reconcile: Cursor.
# Every agent stage runs in a right-hand pane (interactive TUI). Never -p.
#
set -euo pipefail

usage() {
  echo "usage: review-goose-panes.sh open {reviewers|cross|reconcile} <item_dir> <id> <cursor_cmd...>" >&2
  echo "       review-goose-panes.sh close <item_dir> <id>" >&2
  exit 1
}

# Match review-make.sh reviewer allow/deny (deny wins). Built here so Goose does
# not have to pass shell-hostile tool strings through recipe params.
CLAUDE_MODEL="${WT_REVIEW_REVIEWER_MODEL:-claude-opus-4-5}"
# auto: acceptEdits still prompts on uncheckable Bash (e.g. <(…)); the auto classifier decides.
# Bound by RO checkouts + CLAUDE_DENY (git writes / ADO mutates).
CLAUDE_PERM="${WT_REVIEW_PERMISSION_MODE:-auto}"
CLAUDE_ALLOW='Bash,Edit,Write,Read,Grep,Glob'
CLAUDE_DENY='Bash(git commit:*),Bash(git push:*),Bash(git add:*),Bash(git reset:*),Bash(git checkout:*),Bash(git switch:*),Bash(git rebase:*),Bash(git merge:*),Bash(git cherry-pick:*),Bash(git worktree:*),Bash(az boards:*),Bash(az repos pr update:*),Bash(az repos pr set-vote:*),Bash(az repos pr reviewer:*),Bash(az devops invoke:*)'

(($# >= 1)) || usage
ACTION="$1"
shift

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need herdr
need jq

state_path() { printf '%s/review-%s-goose-panes.json' "$1" "$2"; }

goose_pane() {
  local p="${HERDR_PANE_ID:-}"
  [[ -n "$p" ]] || {
    echo "HERDR_PANE_ID is empty — run this from the Goose herdr pane" >&2
    exit 1
  }
  printf '%s' "$p"
}

close_listed() {
  local item="$1" id="$2" state pane
  state="$(state_path "$item" "$id")"
  [[ -f "$state" ]] || return 0
  while read -r pane; do
    [[ -n "$pane" ]] || continue
    herdr pane close "$pane" >/dev/null 2>&1 || true
  done < <(jq -r '.panes[]?' "$state" 2>/dev/null || true)
  rm -f "$state"
}

# Same idea as review-make.sh pane_ready_and_idle: a brand-new split still runs
# profile hooks; typing into it too early drops or mangles the agent command.
pane_ready_and_idle() {
  local pane="$1" deadline=$((SECONDS + 20)) names="" n only_shell durable stable=0
  while (( SECONDS < deadline )); do
    names="$(herdr pane process-info --pane "$pane" 2>/dev/null \
             | jq -r '.result.process_info.foreground_processes[]?.name' || true)"
    if [[ -z "$names" ]]; then
      stable=0
      sleep 0.25
      continue
    fi
    only_shell=1
    durable=0
    while read -r n; do
      case "$n" in
        ""|bash|sh|dash|zsh|fish|"-bash"|"-sh"|"-zsh") ;;
        micro|nvim|vim|vi|emacs|claude|agent|cursor-agent|MainThread|node|goose)
          durable=1; only_shell=0; break ;;
        *) only_shell=0 ;;
      esac
    done <<<"$names"
    if (( durable )); then
      return 1
    fi
    if (( only_shell )); then
      stable=$((stable + 1))
      (( stable >= 2 )) && return 0
    else
      stable=0
    fi
    sleep 0.25
  done
  return 1
}

split_right_of() {
  local from="$1" cwd="$2" label="$3" out new
  out="$(herdr pane split "$from" --direction right --cwd "$cwd" --no-focus --ratio 0.45)"
  new="$(jq -r '.result.pane.pane_id // empty' <<<"$out")"
  [[ -n "$new" ]] || {
    echo "herdr pane split failed:" >&2
    echo "$out" >&2
    exit 1
  }
  herdr pane rename "$new" "$label" >/dev/null 2>&1 || true
  printf '%s' "$new"
}

split_down_of() {
  local from="$1" cwd="$2" label="$3" out new
  out="$(herdr pane split "$from" --direction down --cwd "$cwd" --no-focus --ratio 0.5)"
  new="$(jq -r '.result.pane.pane_id // empty' <<<"$out")"
  [[ -n "$new" ]] || {
    echo "herdr pane split (down) failed:" >&2
    echo "$out" >&2
    exit 1
  }
  herdr pane rename "$new" "$label" >/dev/null 2>&1 || true
  printf '%s' "$new"
}

# Short launcher: herdr only types `bash <script>`; the script loads the prompt.
# Interactive TUI — never -p/--print (print mode looks frozen). Goose waits on
# the findings/complete file marker, not on pane exit.
write_cursor_launcher() {
  local path="$1" role="$2" prompt="$3" workspace="$4"
  shift 4
  local -a cursor_cmd=() raw=("$@")
  local w skip=0
  for w in "${raw[@]}"; do
    if (( skip )); then skip=0; continue; fi
    case "$w" in
      -p|--print|--stream-partial-output) continue ;;
      --output-format) skip=1; continue ;;
      --output-format=*) continue ;;
      *) cursor_cmd+=("$w") ;;
    esac
  done
  ((${#cursor_cmd[@]} > 0)) || cursor_cmd=(agent --trust --approve-mcps --sandbox enabled --force)
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf 'cd %q\n' "$workspace"
    printf 'echo "-> starting Cursor (interactive TUI) in %q"\n' "$workspace"
    printf 'exec'
    for w in "${cursor_cmd[@]}"; do
      printf ' %q' "$w"
    done
    printf ' --workspace %q -- %q "$(cat %q)"\n' "$workspace" "$role" "$prompt"
  } > "$path"
  chmod +x "$path"
}

write_claude_launcher() {
  local path="$1" role="$2" prompt="$3" workspace="$4"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf 'cd %q\n' "$workspace"
    printf 'echo "-> starting Claude (interactive TUI) in %q"\n' "$workspace"
    printf 'exec claude --model %q --permission-mode %q --allowed-tools %q --disallowed-tools %q -- %q "$(cat %q)"\n' \
      "$CLAUDE_MODEL" "$CLAUDE_PERM" "$CLAUDE_ALLOW" "$CLAUDE_DENY" "$role" "$prompt"
  } > "$path"
  chmod +x "$path"
}

run_launcher() {
  local pane="$1" script="$2"
  if ! pane_ready_and_idle "$pane"; then
    echo "WARNING: pane ${pane} not idle after split; submitting anyway" >&2
  fi
  herdr pane run "$pane" "bash $(printf '%q' "$script")" >/dev/null
}

open_reviewers() {
  local item="$1" id="$2"
  shift 2
  local -a cursor_cmd=("$@")
  local goose right_top right_bot prompt fa fb la lb state
  ((${#cursor_cmd[@]} > 0)) || { echo "cursor_cmd required" >&2; exit 1; }

  goose="$(goose_pane)"
  close_listed "$item" "$id"

  prompt="${item}/review-${id}-reviewer-prompt.md"
  fa="${item}/review-${id}-findings-claude.md"
  fb="${item}/review-${id}-findings-cursor.md"
  la="${item}/review-${id}-run-claude.sh"
  lb="${item}/review-${id}-run-cursor.sh"
  [[ -f "$prompt" ]] || { echo "missing reviewer prompt: $prompt" >&2; exit 1; }
  : > "$fa"
  : > "$fb"

  write_claude_launcher "$la" \
    "You are the Claude Opus Reviewer. Write findings only to ${fa}." \
    "$prompt" "$item"
  write_cursor_launcher "$lb" \
    "You are the Cursor Auto Reviewer. Write findings only to ${fb}." \
    "$prompt" "$item" "${cursor_cmd[@]}"

  right_top="$(split_right_of "$goose" "$item" "Claude")"
  right_bot="$(split_down_of "$right_top" "$item" "Cursor")"

  state="$(state_path "$item" "$id")"
  jq -n --arg a "$right_top" --arg b "$right_bot" --arg kind reviewers \
    '{kind:$kind, panes:[$a,$b]}' > "$state"

  run_launcher "$right_top" "$la"
  run_launcher "$right_bot" "$lb"

  echo "progress panes: Claude=${right_top} Cursor=${right_bot}"
}

open_cross() {
  local item="$1" id="$2"
  shift 2
  local -a cursor_cmd=("$@")
  local goose right_top right_bot xa xb pa pb la lb state
  ((${#cursor_cmd[@]} > 0)) || { echo "cursor_cmd required" >&2; exit 1; }

  goose="$(goose_pane)"
  close_listed "$item" "$id"

  xa="${item}/review-${id}-cross-claude.md"
  xb="${item}/review-${id}-cross-cursor.md"
  pa="${item}/review-${id}-cross-claude-prompt.md"
  pb="${item}/review-${id}-cross-cursor-prompt.md"
  la="${item}/review-${id}-run-cross-claude.sh"
  lb="${item}/review-${id}-run-cross-cursor.sh"
  [[ -f "$pa" && -f "$pb" ]] || { echo "missing cross prompts under $item" >&2; exit 1; }
  : > "$xa"
  : > "$xb"

  write_claude_launcher "$la" \
    "You are Claude on the cross-review pass. Write only to ${xa}." \
    "$pa" "$item"
  write_cursor_launcher "$lb" \
    "You are Cursor on the cross-review pass. Write only to ${xb}." \
    "$pb" "$item" "${cursor_cmd[@]}"

  right_top="$(split_right_of "$goose" "$item" "Cross Claude")"
  right_bot="$(split_down_of "$right_top" "$item" "Cross Cursor")"

  state="$(state_path "$item" "$id")"
  jq -n --arg a "$right_top" --arg b "$right_bot" --arg kind cross \
    '{kind:$kind, panes:[$a,$b]}' > "$state"

  run_launcher "$right_top" "$la"
  run_launcher "$right_bot" "$lb"

  echo "progress panes: Cross Claude=${right_top} Cross Cursor=${right_bot}"
}

open_reconcile() {
  local item="$1" id="$2"
  shift 2
  local -a cursor_cmd=("$@")
  local goose right prompt out la state
  ((${#cursor_cmd[@]} > 0)) || { echo "cursor_cmd required" >&2; exit 1; }

  goose="$(goose_pane)"
  close_listed "$item" "$id"

  prompt="${item}/review-${id}-orchestrator-prompt.md"
  out="${item}/review-${id}-complete.json"
  la="${item}/review-${id}-run-reconcile.sh"
  [[ -f "$prompt" ]] || { echo "missing orchestrator prompt: $prompt" >&2; exit 1; }
  rm -f "$out"

  write_cursor_launcher "$la" \
    "You are the Reconcile agent for work item ${id}. Follow the orchestrator prompt. Write reconciled, append ## Review outcome to notes.txt (no summary.md), proposed-comments (grouped by PR), draft post-plan, and the complete marker. Use the higher severity when Claude and Cursor disagree on category; note that discrepancy in the comment body. Do not list severity-only items under Disagrees on." \
    "$prompt" "$item" "${cursor_cmd[@]}"

  right="$(split_right_of "$goose" "$item" "Reconcile")"

  state="$(state_path "$item" "$id")"
  jq -n --arg a "$right" --arg kind reconcile \
    '{kind:$kind, panes:[$a]}' > "$state"

  run_launcher "$right" "$la"

  echo "progress pane: Reconcile=${right}"
}

case "$ACTION" in
  open)
    (($# >= 3)) || usage
    kind="$1"
    item="$2"
    id="$3"
    shift 3
    item="$(cd "$item" && pwd)"
    case "$kind" in
      reviewers) open_reviewers "$item" "$id" "$@" ;;
      cross)     open_cross "$item" "$id" "$@" ;;
      reconcile) open_reconcile "$item" "$id" "$@" ;;
      *) usage ;;
    esac
    ;;
  close)
    (($# == 2)) || usage
    item="$(cd "$1" && pwd)"
    id="$2"
    close_listed "$item" "$id"
    echo "progress panes closed"
    ;;
  *) usage ;;
esac
