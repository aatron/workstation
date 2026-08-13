#!/usr/bin/env bash
#
# az-watcher.sh
# Headless driver that keeps local herdr story worktrees in sync with Azure
# DevOps pull requests. Two scenarios:
#
#   new-review     A PR was assigned to me for review in the last N minutes
#                  -> create a REVIEW worktree for that PR's repo + source
#                     branch (reusing worktree-make.sh, so tabs/notes/agents all
#                     come up exactly as they do for a manual review worktree).
#
#   remove-merged  A PR of mine (as creator OR as reviewer) was completed o
#                  abandoned in the last N minutes
#                  -> remove that repo's local worktree, its local branch and
#                     its notes file (reusing worktree-remove.sh), and drop the
#                     story folder once no worktrees remain in it.
#
# Designed for `*/5 * * * *` cron: non-interactive, idempotent, and stateless —
# nothing is remembered between runs, so a reboot loses nothing.
#
# ---------------------------------------------------------------------------
# How a PR maps to a local story folder ({id}-{slug})
# ---------------------------------------------------------------------------
# 1. The last segment of the PR source branch, when it looks like <id>-<slug>:
#        refs/heads/team/dev/22831-order-entry-forms
#          -> id 22831, slug "order-entry-forms"
#        refs/heads/feature/<you>/23334-cancel-posted-spot-rate
#          -> id 23334, slug "cancel-posted-spot-rate"
#    This is free (no extra az call) and matches the folder names this workflow
#    already produces, because the branch and the folder share that suffix.
# 2. Otherwise the PR's linked work item id, with the slug derived from the work
#    item title by slug_for_story() below:
#        refs/heads/feature/<author>/user-identity-sync -> work item 23346
#          title "User identity sync (Phase A): ..." -> user-identity-sync
# 3. Otherwise the PR is skipped and you are notified (some PRs have neither an
#    id in the branch nor a linked work item).
#
# Azure repo name -> local clone directory: spaces become underscores, e.g.
# "My Repo" -> ~/source/repos/My_Repo. Anything else must match by
# name; a missing clone is reported, never guessed at.
#
# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------
# Every outcome that you would want to know about — review worktree created,
# story cleaned up, PR skipped, action failed — goes through `herdr notification
# show`, and is also written to the log. Quiet no-ops (a worktree that already
# exists, a story already gone) are logged only, so a five-minute cron does not
# nag. Notifications are best-effort: with no herdr session running they are
# logged and dropped.
#
set -euo pipefail

# ===========================================================================
# EDIT THESE FOR YOUR MACHINE
# ===========================================================================
SRC_ROOT="$HOME/source/repos"                        # primary clones live here
MAKE_WORKTREE="${HOME}/bin/make-worktree.sh"         # installed by install.sh
REMOVE_WORKTREE="${HOME}/bin/worktree-remove.sh"     # installed by install.sh
SLUG_WORDS=4                 # words kept when a slug comes from a work item title
PR_TOP=50                    # PRs fetched per query (newest first)
WINDOW_DEFAULT=5             # minutes; must match the cron interval
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/az-watcher.lock"

# Optional env overrides:
#   AZDO_ORG / AZDO_PROJECT  passed to az as --org/--project (else `az devops
#                            configure -d` defaults are used)
#   AZ_WATCHER_ME            identity for --reviewer/--creator (else az account)

# ===========================================================================
# Logging — fd 3 is the real stdout, so log lines never pollute the stdout of a
# function whose output is being captured.
# ===========================================================================
exec 3>&1
ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { printf '%s %s\n' "$(ts)" "$*" >&3; }

usage() {
  cat <<'EOF'
usage: az-watcher [new-review|remove-merged|run] [options]

  new-review      create review worktrees for PRs assigned to me
  remove-merged   remove local worktrees for PRs of mine that closed
  run             both (default)

options:
  --window N      only act on PRs created/closed in the last N minutes
                  (default 5, matching the cron interval). N=0 disables the
                  time filter entirely — use it for a one-off backfill.
  --dry-run       print the intended actions; create and remove nothing
  --force-dirty   allow removal of worktrees with uncommitted changes
                  (default: keep them and notify)
  --me <identity> Azure identity to match (default: az account show)
  -h, --help      this text
EOF
}

# ===========================================================================
# Single-instance lock, taken before anything else so cron runs cannot overlap.
# flock -E 99 lets us tell "already running" apart from a real failure.
# ===========================================================================
if [[ "${AZ_WATCHER_LOCKED:-}" != "1" ]] && command -v flock >/dev/null 2>&1; then
  export AZ_WATCHER_LOCKED=1
  set +e
  # Re-run through the current interpreter rather than exec'ing $0 directly, so
  # the lock also works when the script is invoked as `bash az-watcher.sh`.
  flock -n -E 99 "$LOCK_FILE" "${BASH:-bash}" "$0" "$@"
  rc=$?
  set -e
  if (( rc == 99 )); then
    log "another az-watcher run is in progress; exiting"
    exit 0
  fi
  exit "$rc"
fi

# ===========================================================================
# CLI
# ===========================================================================
ACTION=""
WINDOW="$WINDOW_DEFAULT"
DRY_RUN=0
FORCE_DIRTY=0
ME="${AZ_WATCHER_ME:-}"

while (( $# )); do
  case "$1" in
    new-review|remove-merged|run) ACTION="$1"; shift ;;
    --window)      WINDOW="${2:-}"; shift 2 ;;
    --window=*)    WINDOW="${1#*=}"; shift ;;
    --me)          ME="${2:-}"; shift 2 ;;
    --me=*)        ME="${1#*=}"; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --force-dirty) FORCE_DIRTY=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done
ACTION="${ACTION:-run}"
[[ "$WINDOW" =~ ^[0-9]+$ ]] || { echo "--window takes a non-negative integer" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need az; need git; need jq; need date

# ===========================================================================
# az plumbing
# ===========================================================================
# The Azure CLI on this box may be the Windows build reached through /mnt/c.
# Without PYTHONIOENCODING it tries to encode output as cp1252 and silently
# truncates JSON containing non-ASCII; it also emits CRLF. Both are handled here
# so no caller has to think about it.
declare -a AZ_DEVOPS_ARGS=()
[[ -n "${AZDO_ORG:-}" ]]     && AZ_DEVOPS_ARGS+=(--org "$AZDO_ORG")
[[ -n "${AZDO_PROJECT:-}" ]] && AZ_DEVOPS_ARGS+=(--project "$AZDO_PROJECT")

# NOTE the `</dev/null`: az reads stdin, and these calls happen inside `while
# read` loops. Without it az swallows the rest of the loop's input and the loop
# silently stops after the first PR that needs an az lookup.
az_run() {
  local out err rc
  out="$(mktemp)"; err="$(mktemp)"
  set +e
  PYTHONIOENCODING=utf-8 az "$@" ${AZ_DEVOPS_ARGS[@]+"${AZ_DEVOPS_ARGS[@]}"} \
    >"$out" 2>"$err" </dev/null
  rc=$?
  set -e
  if (( rc != 0 )); then
    log "ERROR: az $* failed (exit ${rc}): $(head -n 3 "$err" | tr -d '\r' | tr '\n' ' ')"
  fi
  tr -d '\r' <"$out"
  rm -f "$out" "$err"
  return "$rc"
}

# Signed-in identity, used as the default --reviewer/--creator value.
resolve_me() {
  local u
  u="$(PYTHONIOENCODING=utf-8 az account show --query user.name -o tsv </dev/null 2>/dev/null | tr -d '\r')" || u=""
  printf '%s\n' "${u%%$'\n'*}"
}

# PRs for one role/status, newest first. Roles: reviewer, creator. $3 is the
# date field the caller will filter on (creationDate / closedDate).
#
# A full page means older PRs went unread. That only *hides* anything when the
# oldest PR on the page is still inside the window, so the warning is limited to
# that case — otherwise a 5-minute cron would log it forever for no reason.
pr_list() {
  local role="$1" status="$2" field="$3" json n oldest
  json="$(az_run repos pr list "--${role}" "$ME" --status "$status" --top "$PR_TOP" -o json)" \
    || return 1
  n="$(jq -r 'length' <<<"$json" 2>/dev/null || echo 0)"
  if [[ "$n" == "$PR_TOP" ]]; then
    oldest="$(jq -r --arg f "$field" '[.[] | .[$f] // empty] | last // empty' <<<"$json")"
    if in_window "$oldest"; then
      log "note: ${role}/${status} returned a full ${PR_TOP}-PR page and its oldest entry is still inside the ${WINDOW}m window — older PRs were not examined; raise PR_TOP"
    fi
  fi
  printf '%s' "$json"
}

# JSON array of PRs -> tab-separated rows. $1 selects the date column, so the
# same reader serves creationDate (new-review) and closedDate (remove-merged).
# Repo names contain spaces, hence tabs rather than whitespace splitting.
prs_tsv() {
  jq -r --arg f "$1" '
    .[]? | [ (.pullRequestId|tostring),
             .repository.name,
             .sourceRefName,
             (.[$f] // ""),
             (.createdBy.uniqueName // "") ] | @tsv'
}

# ===========================================================================
# Story identification
# ===========================================================================
# Anything -> a filesystem-safe, lowercase, hyphenated slug.
sanitize_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-*//' -e 's/-*$//'
}

# EDIT ME: the one place a work-item title becomes a folder slug. Only used when
# the branch name carries no <id>-<slug> suffix. Deterministic on purpose — two
# PRs of the same story in different repos must land in the same story folder.
slug_for_story() {
  local id="$1" title s
  title="$(az_run boards work-item show --id "$id" \
             --query 'fields."System.Title"' -o tsv)" || return 1
  title="${title%%$'\n'*}"
  [[ -n "$title" ]] || return 1
  s="$(sanitize_slug "$title" | cut -d- -f1-"$SLUG_WORDS")"
  [[ -n "$s" ]] || return 1
  printf '%s\n' "$s"
}

# "<id> <slug>" for a PR, or non-zero when neither source can supply an id.
story_for_pr() {
  local pr="$1" branch="$2" seg id slug
  seg="${branch##*/}"
  if [[ "$seg" =~ ^([0-9]+)-(.+)$ ]]; then
    printf '%s %s\n' "${BASH_REMATCH[1]}" "$(sanitize_slug "${BASH_REMATCH[2]}")"
    return 0
  fi
  id="$(az_run repos pr work-item list --id "$pr" -o json | jq -r '.[0].id // empty')" || return 1
  [[ -n "$id" ]] || return 1
  slug="$(slug_for_story "$id")" || return 1
  printf '%s %s\n' "$id" "$slug"
}

# Azure repo name -> local clone directory name.
local_repo_dir() { printf '%s\n' "${1// /_}"; }

# ===========================================================================
# Window filter (stateless: the timestamp in Azure is the only state)
# ===========================================================================
in_window() {
  local iso="$1" t now
  (( WINDOW == 0 )) && return 0
  [[ -n "$iso" ]] || return 1
  t="$(date -d "$iso" +%s 2>/dev/null)" || return 1
  now="$(date -u +%s)"
  (( now - t <= WINDOW * 60 ))
}

# ===========================================================================
# Notifications
# ===========================================================================
notify() {
  local title="$1" body="${2:-}"
  log "NOTIFY ${title}${body:+ | ${body}}"
  (( DRY_RUN )) && return 0
  local args=(notification show "$title" --sound done)
  [[ -n "$body" ]] && args+=(--body "$body")
  herdr "${args[@]}" >/dev/null 2>&1 \
    || log "  (notification not delivered — no herdr session)"
  return 0
}

herdr_up() { herdr workspace list >/dev/null 2>&1; }

# ===========================================================================
# new-review
# ===========================================================================
cmd_new_review() {
  log "new-review: window=${WINDOW}m me=${ME}$( ((DRY_RUN)) && echo ' [dry-run]' )"
  if ! (( DRY_RUN )) && ! herdr_up; then
    log "no herdr session is running — worktree creation needs one; skipping new-review"
    notify "az-watcher: no herdr session" "Start herdr, then re-run az-watcher new-review."
    return 0
  fi

  local json seen=0 created=0
  json="$(pr_list reviewer active creationDate)" || return 1

  # Read on fd 4, not stdin: the body shells out to az and to make-worktree.sh,
  # and anything of theirs that reads stdin would eat the rest of the PR list.
  local pr repo srcref created_at by branch repo_dir story id slug tmp rc
  while IFS=$'\t' read -r pr repo srcref created_at by <&4; do
    [[ -n "$pr" ]] || continue
    # A PR I raised is already covered by its development worktree.
    if [[ "${by,,}" == "${ME,,}" ]]; then
      log "PR ${pr} (${repo}): mine, not a review; skipping"
      continue
    fi
    if ! in_window "$created_at"; then
      log "PR ${pr} (${repo}): created ${created_at}, outside the ${WINDOW}m window"
      continue
    fi
    seen=$((seen + 1))
    branch="${srcref#refs/heads/}"
    repo_dir="$(local_repo_dir "$repo")"

    if ! story="$(story_for_pr "$pr" "$branch")"; then
      log "PR ${pr} (${repo}): no story id in branch '${branch}' and no linked work item"
      notify "Review not created: PR ${pr}" \
             "${repo} · ${branch} — no work item id. Create the worktree by hand if you want one."
      continue
    fi
    id="${story%% *}"; slug="${story#* }"

    if (( DRY_RUN )); then
      log "DRY-RUN would create review worktree ${id}-${slug} for ${repo_dir} @ ${branch} (PR ${pr})"
      continue
    fi

    if [[ ! -e "${SRC_ROOT}/${repo_dir}/.git" ]]; then
      log "PR ${pr}: no local clone at ${SRC_ROOT}/${repo_dir}"
      notify "Review not created: PR ${pr}" \
             "No local clone ${repo_dir} under ${SRC_ROOT} (Azure repo '${repo}')."
      continue
    fi

    tmp="$(mktemp)"
    printf '%s:%s\n' "$repo_dir" "$branch" >"$tmp"
    log "PR ${pr}: creating review worktree ${id}-${slug} for ${repo_dir} @ ${branch}"
    set +e
    WT_ID="$id" WT_SLUG="$slug" WT_BRANCHES_FILE="$tmp" \
      "$MAKE_WORKTREE" review >&3 2>&3 </dev/null
    rc=$?
    set -e
    rm -f "$tmp"
    case "$rc" in
      0) created=$((created + 1))
         notify "Review ready: ${id}-${slug}" "PR ${pr} · ${repo} · ${branch}" ;;
      3) log "PR ${pr}: worktree for ${id}-${slug}/${repo_dir} already exists — nothing to do" ;;
      *) notify "Review FAILED: ${id}-${slug}" \
                "PR ${pr} · ${repo} · ${branch} — make-worktree.sh exited ${rc}. See the az-watcher log." ;;
    esac
  done 4< <(printf '%s' "$json" | prs_tsv creationDate)

  log "new-review: ${seen} PR(s) in window, ${created} worktree(s) created"
}

# ===========================================================================
# remove-merged
# ===========================================================================
# Closed PRs across both roles and both terminal statuses, deduplicated by PR
# id. Reviewer PRs retire review worktrees; my own PRs retire the development
# worktrees they were raised from.
closed_prs_tsv() {
  local role status
  for role in creator reviewer; do
    for status in completed abandoned; do
      pr_list "$role" "$status" closedDate | prs_tsv closedDate || true
    done
  # Dedupe by PR id (a PR can be both mine and one I reviewed), newest first.
  done | sort -t$'\t' -k1,1 -nru
}

cmd_remove_merged() {
  log "remove-merged: window=${WINDOW}m me=${ME}$( ((DRY_RUN)) && echo ' [dry-run]' )"
  local seen=0 removed=0
  local pr repo srcref closed_at by branch repo_dir story id rc skip_dirty

  skip_dirty=1
  (( FORCE_DIRTY )) && skip_dirty=0

  # fd 4, see cmd_new_review.
  while IFS=$'\t' read -r pr repo srcref closed_at by <&4; do
    [[ -n "$pr" ]] || continue
    if ! in_window "$closed_at"; then
      continue
    fi
    seen=$((seen + 1))
    branch="${srcref#refs/heads/}"
    repo_dir="$(local_repo_dir "$repo")"

    if ! story="$(story_for_pr "$pr" "$branch")"; then
      log "PR ${pr} (${repo}): closed but no story id in branch '${branch}' and no linked work item"
      notify "Cleanup skipped: PR ${pr}" \
             "${repo} · ${branch} — no work item id, so no story folder to match. Remove it by hand if it has one."
      continue
    fi
    id="${story%% *}"

    if (( DRY_RUN )); then
      log "DRY-RUN would remove story ${id} repo ${repo_dir} (PR ${pr}, closed ${closed_at})"
      log "         WT_ID=${id} WT_REPO=${repo_dir} WT_ASSUME_YES=1 WT_SKIP_DIRTY=${skip_dirty} ${REMOVE_WORKTREE}"
      continue
    fi

    log "PR ${pr}: removing story ${id} repo ${repo_dir} (closed ${closed_at})"
    set +e
    WT_ID="$id" WT_REPO="$repo_dir" WT_ASSUME_YES=1 WT_SKIP_DIRTY="$skip_dirty" \
      "$REMOVE_WORKTREE" >&3 2>&3 </dev/null
    rc=$?
    set -e
    case "$rc" in
      0) removed=$((removed + 1))
         notify "Story cleaned up: ${id}" "${repo} worktree, branch and notes removed (PR ${pr})" ;;
      3) log "PR ${pr}: nothing local for story ${id}/${repo_dir} — already gone" ;;
      5) notify "Cleanup held back: ${id}" \
                "${repo_dir} has uncommitted changes. Commit/discard, then re-run or use --force-dirty." ;;
      *) notify "Cleanup FAILED: ${id}" \
                "${repo_dir} (PR ${pr}) — worktree-remove.sh exited ${rc}. See the az-watcher log." ;;
    esac
  done 4< <(closed_prs_tsv)

  log "remove-merged: ${seen} closed PR(s) in window, ${removed} story removal(s)"
}

# ===========================================================================
# main
# ===========================================================================
[[ -x "$MAKE_WORKTREE" || -f "$MAKE_WORKTREE" ]] || {
  echo "missing ${MAKE_WORKTREE} (run wsl/herdr/install.sh)" >&2; exit 1; }
[[ -x "$REMOVE_WORKTREE" || -f "$REMOVE_WORKTREE" ]] || {
  echo "missing ${REMOVE_WORKTREE} (run wsl/herdr/install.sh)" >&2; exit 1; }

[[ -n "$ME" ]] || ME="$(resolve_me)"
[[ -n "$ME" ]] || {
  log "cannot determine the signed-in Azure identity — run 'az login' (or pass --me)"
  notify "az-watcher: not signed in" "Run 'az login' in WSL, then re-run az-watcher."
  exit 1
}

case "$ACTION" in
  new-review)    cmd_new_review ;;
  remove-merged) cmd_remove_merged ;;
  run)           cmd_new_review; cmd_remove_merged ;;
esac
