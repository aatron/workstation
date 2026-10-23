#!/usr/bin/env bash
#
# story-reap.sh — remove development story worktrees whose Azure DevOps pull
# requests have all closed. Port of win/herdr/story-reap.ps1.
#
# usage: story-reap.sh [options]
#
#        --dry-run             print what would go, remove nothing
#        --yes                 skip the confirmation (for scheduled runs)
#        --story <id>          examine only that story
#        --completed-only      abandoned no longer counts as closed
#        --force-dirty         reap a story even with uncommitted changes
#        --force-unpushed      reap a story even with commits Azure never saw
#        -h, --help
#
# THE RULE: AT LEAST ONE PR, AND EVERY ONE OF THEM CLOSED
#   A story is reaped only when it has >= 1 associated pull request AND every one
#   of them is closed. Both halves matter, and the first is the one that is easy
#   to get wrong: a story with NO pull requests looks identical to a fully closed
#   one if you only test "nothing is open". That is a brand-new story someone
#   started ten minutes ago, and deleting it is the worst thing this script could
#   do. No PRs found => left alone, always.
#
#   A PR whose status cannot be read is NOT closed. An expired token, a network
#   blip or a renamed repo must never be the reason a story disappears, so
#   anything short of a definite closed status keeps the story.
#
# WHERE "ASSOCIATED PRs" COME FROM — TWO SOURCES, UNIONED
#   1. The work item's own links (`boards work-item show --expand relations`).
#      Catches PRs in repos that are not checked out under the story.
#   2. Per checked-out repo, the PRs for that repo's branch
#      (`repos pr list --source-branch`). Catches PRs nobody linked to the work
#      item, which is the common case — linking is a manual step people skip.
#
#   Neither source alone is complete, and a PR missed by both halves of the union
#   is a PR that cannot hold the story back. So they are unioned, and any single
#   open PR from either source keeps the story. If the work item itself cannot be
#   read the story is held back rather than judged on source 2 alone: an unreadable
#   work item means the PR list is unknown, not empty.
#
# WHAT IT WILL NOT DO
#   * touch Azure DevOps. Every az call goes through az_read, which refuses
#     anything not on $AZ_READ_ONLY. It reads PR and work item status; it never
#     votes, comments, completes a PR or changes a work item.
#   * delete work Azure never saw. A checkout with uncommitted changes holds its
#     story back, and so does one carrying commits that are not contained in what
#     its PR last showed — a squash merge leaves the local branch looking ahead of
#     origin forever, so the test is against the PR's own source commit rather
#     than a naive origin/<branch> comparison. See checkout_blocker.
#   * reap review worktrees on its own. It walks development/ only. A story that
#     also has a review/{id}-{slug} copy is called out in the plan and held to the
#     same bar, because worktree-remove.sh removes by id and will take both.
#   * decide anything twice. flock means an overlapping cron tick exits
#     immediately instead of racing the run already in progress.
#
# CRON
#   Built to be run unattended on a timer, which is why it logs with timestamps,
#   holds a single-instance lock, and needs no terminal once --yes is passed:
#
#     story-reap.sh --dry-run          # always start here
#     story-reap.sh --yes              # unattended
#
#   Until you trust it, leave --yes off: it prints the plan and asks. Removal
#   itself is delegated to worktree-remove.sh (WT_ASSUME_YES=1), so the rules
#   about closing herdr rows before deleting checkouts stay in one place.
#
# Exit codes:
#   0  at least one story was reaped
#   1  bad usage / a removal failed
#   3  nothing to do — no story had all of its PRs closed
#   5  a story was held back (uncommitted or unpushed work, unreadable status)
#
set -euo pipefail

# ===========================================================================
# EDIT THESE FOR YOUR MACHINE
# ===========================================================================
REMOVE_WORKTREE="${WT_REMOVE_SCRIPT:-${HOME}/bin/worktree-remove.sh}"

# Statuses that mean "this PR is closed". Azure DevOps also has 'notSet', which is
# deliberately absent: it is not a closed PR.
CLOSED_STATUS=(completed abandoned)

# Cap on a single per-branch PR query. A branch has one or two PRs in practice;
# this is only here so a pathological branch cannot pull down a huge page.
PR_TOP=50

LOCK_FILE="${STORY_REAP_LOCK:-${XDG_RUNTIME_DIR:-/tmp}/story-reap.lock}"

# ===========================================================================
# Single-instance lock
#
# A 10-minute timer plus a run that takes longer than 10 minutes — entirely
# possible, every PR query is a network round trip — would otherwise have two
# copies deciding the fate of the same story folder at once.
#
# flock -E 99 lets us tell "already running" apart from a real failure.
# ===========================================================================
if [[ "${STORY_REAP_LOCKED:-}" != "1" ]] && command -v flock >/dev/null 2>&1; then
  export STORY_REAP_LOCKED=1
  set +e
  flock -n -E 99 "$LOCK_FILE" "${BASH:-bash}" "$0" "$@"
  rc=$?
  set -e
  if (( rc == 99 )); then
    echo "$(date --iso-8601=seconds) another story-reap run is in progress; exiting"
    exit 0
  fi
  exit "$rc"
fi

# ===========================================================================
# CLI
# ===========================================================================
DRY_RUN=0
ASSUME_YES=0
[[ "${WT_ASSUME_YES:-}" == "1" ]] && ASSUME_YES=1
ONLY=''
FORCE_DIRTY=0
[[ "${WT_FORCE_DIRTY:-}" == "1" ]] && FORCE_DIRTY=1
FORCE_UNPUSHED=0

usage() {
  cat <<'EOF'
usage: story-reap.sh [options]

  --dry-run             print the intended actions; remove nothing
  --yes                 do not ask for confirmation (for scheduled runs)
  --story <id>          examine only that story
  --completed-only      treat only completed PRs as closed (not abandoned)
  --force-dirty         reap a story even if a checkout has uncommitted changes
  --force-unpushed      reap a story even if a checkout has commits Azure
                        DevOps never saw
  -h, --help            this text

A story is reaped only when it has at least one pull request AND every one of
them is closed. A story with no pull requests is always left alone.
Azure DevOps is read, never written.
EOF
}

while (( $# )); do
  case "$1" in
    --dry-run)        DRY_RUN=1; shift ;;
    --yes)            ASSUME_YES=1; shift ;;
    --story)          ONLY="${2:-}"; shift 2 ;;
    --story=*)        ONLY="${1#--story=}"; shift ;;
    --completed-only) CLOSED_STATUS=(completed); shift ;;
    --force-dirty)    FORCE_DIRTY=1; shift ;;
    --force-unpushed) FORCE_UNPUSHED=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done
if [[ -n "$ONLY" && ! "$ONLY" =~ ^[0-9]+$ ]]; then
  echo "--story takes a numeric work item id, got '$ONLY'" >&2
  exit 1
fi

# Timestamped because the point of this script is to end up in a cron log where
# "when" is the first question anyone asks.
log() { echo "$(date --iso-8601=seconds) $*"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }

AZ_CMD="${WT_REVIEW_AZ:-az}"

need git; need jq
[[ -n "${WT_REVIEW_AZ:-}" ]] || need az
[[ -f "$REMOVE_WORKTREE" ]] || {
  echo "missing $REMOVE_WORKTREE (run wsl/herdr/install.sh)" >&2
  exit 1
}

EXAMINED=0
REAPED=0
HELD=0
FAILED=0
SKIPPED=0

join_or() { local IFS='|'; local s="$*"; printf '%s\n' "${s//|/ or }"; }

# ===========================================================================
# Azure DevOps: read only, enforced.
#
# Same guard as review-make.sh / review-remove.sh. The check is on the leading
# non-flag words, which is exactly az's command path, so flag ordering cannot slip
# a write past it.
# ===========================================================================
AZ_READ_ONLY=(
  'account show'
  'boards work-item show'
  'devops configure'
  'repos pr list'
  'repos pr show'
  'repos pr work-item list'
)

az_command_path() {
  local a words=()
  for a in "$@"; do
    [[ "$a" == -* ]] && break
    words+=("$a")
  done
  printf '%s\n' "${words[*]:-}"
}

az_read_only() {
  local path entry found=0
  path="$(az_command_path "$@")"
  for entry in "${AZ_READ_ONLY[@]}"; do
    [[ "$entry" == "$path" ]] && { found=1; break; }
  done
  (( found )) || return 1
  return 0
}

AZ_EXIT=0

az_read() {
  if ! az_read_only "$@"; then
    echo "refusing to run a non-read-only az command: az $*. story-reap.sh only ever reads from Azure DevOps." >&2
    exit 1
  fi
  local out
  out="$(PYTHONIOENCODING=utf-8 PYTHONUTF8=1 "$AZ_CMD" "$@" 2>/dev/null)" || { AZ_EXIT=$?; printf ''; return 0; }
  AZ_EXIT=0
  printf '%s' "$out"
}

# Returns 1 when the call failed or the payload was not JSON. An EMPTY LIST is a
# success: `[]` is valid, non-empty JSON text, so "no PRs for this branch" comes
# back as data rather than as an error. (The PowerShell port needs a dedicated
# helper for this, because ConvertFrom-Json turns '[]' into $null and an empty
# array returned from a function becomes $null too — indistinguishable from a
# failed query, which would hold every fresh story back forever.)
az_json() {
  local out
  out="$(az_read "$@")"
  (( AZ_EXIT == 0 )) || return 1
  [[ -n "$out" ]] || return 1
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# git plumbing (never fatal; judged on exit codes)
# ---------------------------------------------------------------------------
GIT_EXIT=0

git_out() {
  local repo="$1"; shift
  local out
  if out="$(git -C "$repo" "$@" 2>/dev/null)"; then GIT_EXIT=0; else GIT_EXIT=$?; fi
  printf '%s' "$out"
}

git_line() {
  local out; out="$(git_out "$@")"
  (( GIT_EXIT == 0 )) || { printf ''; return 0; }
  printf '%s' "$out" | sed -n '/[^[:space:]]/{s/^[[:space:]]*//;s/[[:space:]]*$//;p;q}'
}

git_ok() {
  git_out "$@" >/dev/null
  return "$GIT_EXIT"
}

# ---------------------------------------------------------------------------
# Working out what a story is made of
# ---------------------------------------------------------------------------
herdr_config_path() {
  printf '%s\n' "${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"
}

resolve_worktree_root() {
  local cfg; cfg="$(herdr_config_path)"
  local dir=""
  if [[ -f "$cfg" ]]; then
    dir="$(awk '
      /^\[worktrees\]/ { in_section = 1; next }
      /^\[/ { in_section = 0 }
      in_section && $0 ~ /^[[:space:]]*directory[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, "")
        sub(/[[:space:]]+#.*$/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        gsub(/^["'\'']|["'\'']$/, "")
        print
        exit
      }
    ' "$cfg")"
  fi
  [[ -z "$dir" ]] && dir="~/source/worktrees"
  case "$dir" in
    "~/"*) dir="${HOME}/${dir#\~/}" ;;
    "~")   dir="${HOME}" ;;
  esac
  dir="${dir//\$HOME/$HOME}"
  dir="${dir//\$\{HOME\}/$HOME}"
  printf '%s\n' "$dir"
}

urldecode() {
  local s="${1//+/ }"
  printf '%b' "${s//%/\\x}"
}

# The Azure repo name for a checkout, read out of its own origin URL. Preferred
# over the directory name because worktree-make.sh turns spaces into underscores
# ("My Repo" -> My_Repo) and that is not reversible: a repo genuinely
# named with an underscore and one named with a space produce the same folder.
# The remote URL carries the real name, so --repository cannot be given a name
# Azure will not recognise.
az_repo_name() {
  local wt="$1" url name=''
  url="$(git_line "$wt" remote get-url origin)"
  [[ -n "$url" ]] || { printf ''; return 0; }
  url="${url%.git}"
  case "$url" in
    */_git/*) name="${url##*/_git/}"; name="${name%%/*}" ;;
    git@ssh.dev.azure.com:v3/*)
      # git@ssh.dev.azure.com:v3/{org}/{project}/{repo}
      name="${url##*/}" ;;
    *) name="${url##*/}" ;;
  esac
  [[ -n "$name" ]] || { printf ''; return 0; }
  urldecode "$name"
}

# Every repo checkout inside a story folder, one TSV row each:
#   path \t dirname \t azure repo name \t branch
story_checkouts() {
  local story="$1" d
  [[ -d "$story" ]] || return 0
  for d in "$story"/*; do
    [[ -d "$d" ]] || continue
    [[ -e "$d/.git" ]] || continue
    printf '%s\t%s\t%s\t%s\n' \
      "$d" "$(basename "$d")" "$(az_repo_name "$d")" \
      "$(git_line "$d" rev-parse --abbrev-ref HEAD)"
  done
}

linked_pr_ids() {
  jq -r '
    [ .relations[]? | .url // ""
      | select(startswith("vstfs:///Git/PullRequestId/"))
      | sub("^vstfs:///Git/PullRequestId/"; "")
      | gsub("%2[fF]"; "/")
      | split("/") | last
      | select(test("^[0-9]+$")) ] | unique | .[]
  ' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Per-story state. Parallel arrays rather than one structure, which is what bash
# has; reset for every story so nothing leaks between them.
# ---------------------------------------------------------------------------
declare -a PR_ID=() PR_STATUS=() PR_CLOSED=() PR_REPO=() PR_BRANCH=() PR_SRC=() PR_FROM=()
declare -a UNREADABLE=()
declare -a CO_PATH=() CO_DIR=() CO_REPO=() CO_BRANCH=()

pr_index_of() {
  local want="$1" i
  for i in "${!PR_ID[@]}"; do
    [[ "${PR_ID[$i]}" == "$want" ]] && { printf '%s' "$i"; return 0; }
  done
  printf ''
}

# Record a PR from a single-PR JSON object. A branch query carries
# lastMergeSourceCommit, which the unpushed test wants, so it is allowed to
# replace a bare work-item hit for the same PR.
add_pr() {
  local json="$1" from="$2"
  local id status repo branch src closed=0 idx s
  id="$(jq -r '.pullRequestId // "" | tostring' <<<"$json")"
  [[ -n "$id" && "$id" != "null" ]] || return 0
  status="$(jq -r '.status // ""' <<<"$json")"
  status="${status,,}"
  repo="$(jq -r '.repository.name // ""' <<<"$json")"
  branch="$(jq -r '.sourceRefName // ""' <<<"$json")"
  branch="${branch#refs/heads/}"
  src="$(jq -r '.lastMergeSourceCommit.commitId // ""' <<<"$json")"
  for s in "${CLOSED_STATUS[@]}"; do [[ "$s" == "$status" ]] && { closed=1; break; }; done
  idx="$(pr_index_of "$id")"
  if [[ -z "$idx" ]]; then
    idx="${#PR_ID[@]}"
  elif [[ "$from" != 'branch' ]]; then
    return 0
  fi
  PR_ID[$idx]="$id"
  PR_STATUS[$idx]="$status"
  PR_CLOSED[$idx]="$closed"
  PR_REPO[$idx]="$repo"
  PR_BRANCH[$idx]="$branch"
  PR_SRC[$idx]="$src"
  PR_FROM[$idx]="$from"
}

# Fill PR_* and UNREADABLE for one story from both sources.
collect_story_prs() {
  local id="$1"
  PR_ID=(); PR_STATUS=(); PR_CLOSED=(); PR_REPO=(); PR_BRANCH=(); PR_SRC=(); PR_FROM=()
  UNREADABLE=()
  local wi prId prj list n i co_i

  # Source 1: the work item's links.
  if ! wi="$(az_json boards work-item show --id "$id" --expand relations -o json)"; then
    UNREADABLE+=("work item $id could not be read (az exit $AZ_EXIT)")
  else
    while read -r prId; do
      [[ -n "$prId" ]] || continue
      if ! prj="$(az_json repos pr show --id "$prId" -o json)"; then
        UNREADABLE+=("PR $prId (linked to the work item) could not be read")
        continue
      fi
      add_pr "$prj" 'work-item'
    done < <(printf '%s' "$wi" | linked_pr_ids)
  fi

  # Source 2: the PRs on each checked-out branch.
  for co_i in "${!CO_PATH[@]}"; do
    # A detached checkout (what review-make.sh produces) has no branch to have PRs
    # for and no local branch that could be lost, so it is not a gap in the list —
    # source 1 covers it. Saying "unreadable" here would hold every story with a
    # review copy back forever.
    [[ -z "${CO_BRANCH[$co_i]}" || "${CO_BRANCH[$co_i]}" == "HEAD" ]] && continue
    if [[ -z "${CO_REPO[$co_i]}" ]]; then
      UNREADABLE+=("${CO_DIR[$co_i]}: origin repo name could not be read, so its PRs are unknown")
      continue
    fi
    if ! list="$(az_json repos pr list --repository "${CO_REPO[$co_i]}" \
        --source-branch "${CO_BRANCH[$co_i]}" --status all --top "$PR_TOP" -o json)"; then
      UNREADABLE+=("${CO_DIR[$co_i]}: PRs for branch '${CO_BRANCH[$co_i]}' could not be listed")
      continue
    fi
    n="$(jq -r 'length' <<<"$list" 2>/dev/null || echo 0)"
    for (( i = 0; i < n; i++ )); do
      add_pr "$(jq -c ".[$i]" <<<"$list")" 'branch'
    done
  done
}

# ---------------------------------------------------------------------------
# Is there local work Azure DevOps never saw?
#
# worktree-remove.sh deletes the checkout AND the local branch, so this is the
# last line of defence for anything not on the server. Echoes nothing when the
# checkout is safe to delete, or a human reason why it is not.
#
# The naive test — compare HEAD against origin/<branch> — is wrong here in both
# directions:
#   * After a SQUASH merge (the Azure DevOps default on many projects) the local
#     branch's commits are not ancestors of anything on origin, and the source
#     branch is usually deleted on completion, so origin/<branch> is gone as well.
#     A story that finished perfectly then looks like it has unpushed work
#     forever, and would never be reaped.
#   * A branch that was force-pushed over can look identical to one that is
#     behind.
# So the question asked instead is "is everything in this checkout contained in
# what its PR last showed Azure" — the PR's lastMergeSourceCommit. That is the
# high-water mark of what the server saw on this branch, whatever the merge
# strategy did afterwards.
# ---------------------------------------------------------------------------
checkout_blocker() {
  local i="$1"
  local wt="${CO_PATH[$i]}" dir="${CO_DIR[$i]}" branch="${CO_BRANCH[$i]}"
  local changes head originRef j

  changes="$(git_out "$wt" status --porcelain)"
  if (( GIT_EXIT != 0 )); then
    printf '%s' "could not read git status in $dir"
    return 0
  fi
  changes="$(printf '%s' "$changes" | sed '/^[[:space:]]*$/d')"
  if [[ -n "$changes" ]] && (( ! FORCE_DIRTY )); then
    printf '%s' "$dir has $(printf '%s\n' "$changes" | wc -l | tr -d ' ') uncommitted change(s)"
    return 0
  fi

  (( FORCE_UNPUSHED )) && { printf ''; return 0; }

  # Detached: there is no branch, so worktree-remove.sh deletes none, and nothing
  # here can be lost by name. The dirty test above is the whole check.
  [[ -z "$branch" || "$branch" == "HEAD" ]] && { printf ''; return 0; }

  head="$(git_line "$wt" rev-parse HEAD)"
  [[ -n "$head" ]] || { printf '%s' "could not resolve HEAD in $dir"; return 0; }

  # The PRs for this checkout's own branch: HEAD contained in what any of them
  # last showed => nothing local is at risk.
  local haveMine=0
  for j in "${!PR_ID[@]}"; do
    [[ "${PR_BRANCH[$j]}" == "$branch" ]] || continue
    haveMine=1
    [[ -n "${PR_SRC[$j]}" ]] || continue
    [[ "$head" == "${PR_SRC[$j]}" ]] && { printf ''; return 0; }
    if git_ok "$wt" merge-base --is-ancestor "$head" "${PR_SRC[$j]}"; then
      printf ''
      return 0
    fi
  done

  # No PR vouched for HEAD. Fall back to the remote-tracking branch: if origin
  # still has this branch and it contains HEAD, the work is on the server.
  originRef="refs/remotes/origin/${branch}"
  if git_ok "$wt" rev-parse --verify --quiet "$originRef"; then
    if git_ok "$wt" merge-base --is-ancestor "$head" "$originRef"; then
      printf ''
      return 0
    fi
    printf '%s' "$dir has commits on '$branch' that are not on origin"
    return 0
  fi

  if (( haveMine )); then
    printf '%s' "$dir has commits its PR never saw on '$branch'"
  else
    printf '%s' "$dir has no PR for branch '$branch' and no origin/$branch to vouch for it"
  fi
}

notify() {
  local title="$1" body="${2:-}"
  log "NOTIFY ${title}${body:+ | $body}"
  (( DRY_RUN )) && return 0
  command -v herdr >/dev/null 2>&1 || return 0
  if [[ -n "$body" ]]; then
    herdr notification show "$title" --sound done --body "$body" >/dev/null 2>&1 || true
  else
    herdr notification show "$title" --sound done >/dev/null 2>&1 || true
  fi
}

# ===========================================================================
# main
# ===========================================================================
WORKTREE_ROOT="$(resolve_worktree_root)"
DEV_ROOT="${WORKTREE_ROOT}/development"
REVIEW_ROOT="${WORKTREE_ROOT}/review"

log "story-reap: development root $DEV_ROOT"
log "closed means: $(join_or "${CLOSED_STATUS[@]}")"
(( DRY_RUN )) && log 'DRY RUN: nothing will be removed'

[[ -d "$DEV_ROOT" ]] || { log 'no development root on disk - nothing to do'; exit 3; }

# Grouped BY STORY ID, not by folder, because that is the unit worktree-remove.sh
# actually operates on. Two things make this essential rather than tidy:
#   * one work item can have several development folders — {id}-finish-branch,
#     {id}-improve-validation, {id}-read-path-fixes are all story 23573 — and
#     `worktree-remove.sh 23573` takes every one of them in a single pass.
#   * it also matches review/{id}-{slug} if az-watcher made one.
# Judging a folder on its own would let a clean folder authorise a removal that
# also deletes a sibling folder holding uncommitted work. So every folder and
# every checkout the removal will touch is gathered under the id first, and the
# whole group has to pass.
declare -a IDS=()
declare -A ID_FOLDERS=()     # id -> newline-separated "path<TAB>isreview"

add_story_folder() {
  local id="$1" path="$2" isreview="$3"
  if [[ -z "${ID_FOLDERS[$id]:-}" ]]; then
    IDS+=("$id")
    ID_FOLDERS[$id]="${path}	${isreview}"
  else
    ID_FOLDERS[$id]="${ID_FOLDERS[$id]}
${path}	${isreview}"
  fi
}

# Same shapes worktree-remove.sh matches: {id}-{slug} and legacy {id}_{slug}.
for d in "$DEV_ROOT"/*; do
  [[ -d "$d" ]] || continue
  name="$(basename "$d")"
  [[ "$name" =~ ^([0-9]+)[-_] ]] || continue
  sid="${BASH_REMATCH[1]}"
  [[ -n "$ONLY" && "$sid" != "$ONLY" ]] && continue
  add_story_folder "$sid" "$d" 0
done

if (( ${#IDS[@]} == 0 )); then
  if [[ -n "$ONLY" ]]; then log "no development story folder for $ONLY under $DEV_ROOT"
  else log 'no development story folders on disk - nothing to do'; fi
  exit 3
fi

# The review copies the same removal would take. Development is what this script
# sweeps, but these come along for the ride, so they are held to the same bar.
if [[ -d "$REVIEW_ROOT" ]]; then
  for d in "$REVIEW_ROOT"/*; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    [[ "$name" =~ ^([0-9]+)[-_] ]] || continue
    sid="${BASH_REMATCH[1]}"
    [[ -n "${ID_FOLDERS[$sid]:-}" ]] || continue
    add_story_folder "$sid" "$d" 1
  done
fi

declare -a PLAN_IDS=() PLAN_PRS=()

for id in "${IDS[@]}"; do
  EXAMINED=$(( EXAMINED + 1 ))
  CO_PATH=(); CO_DIR=(); CO_REPO=(); CO_BRANCH=()
  nfolders=0
  echo
  while IFS=$'\t' read -r fpath fisrev; do
    [[ -n "$fpath" ]] || continue
    nfolders=$(( nfolders + 1 ))
    while IFS=$'\t' read -r cpath cdir crepo cbranch; do
      [[ -n "$cpath" ]] || continue
      CO_PATH+=("$cpath"); CO_DIR+=("$cdir"); CO_REPO+=("$crepo"); CO_BRANCH+=("$cbranch")
    done < <(story_checkouts "$fpath")
  done <<<"${ID_FOLDERS[$id]}"

  log "-- work item $id ($nfolders folder(s), ${#CO_PATH[@]} checkout(s))"
  while IFS=$'\t' read -r fpath fisrev; do
    [[ -n "$fpath" ]] || continue
    if [[ "$fisrev" == "1" ]]; then
      echo "   folder   $(basename "$fpath")   [review copy - removal by id takes it too]"
    else
      echo "   folder   $(basename "$fpath")"
    fi
  done <<<"${ID_FOLDERS[$id]}"

  if (( ${#CO_PATH[@]} == 0 )); then
    echo '   no repo checkouts in these folders'
  else
    for i in "${!CO_PATH[@]}"; do
      echo "   checkout ${CO_DIR[$i]} [${CO_REPO[$i]:-<unknown repo>}] on ${CO_BRANCH[$i]:-<detached>}"
    done
  fi

  collect_story_prs "$id"

  # Incomplete list => cannot conclude "all closed". Held, not skipped: this is a
  # condition someone has to fix (az login, a renamed repo), not a normal state.
  if (( ${#UNREADABLE[@]} > 0 )); then
    for u in "${UNREADABLE[@]}"; do echo "   UNREADABLE: $u"; done
    echo '   HELD BACK: the PR list may be incomplete, so "all closed" cannot be proven'
    HELD=$(( HELD + 1 ))
    continue
  fi

  # The rule's first half. A story with no PRs is a story someone just started.
  if (( ${#PR_ID[@]} == 0 )); then
    echo '   no pull requests found - leaving it alone (a story with no PRs is never reaped)'
    SKIPPED=$(( SKIPPED + 1 ))
    continue
  fi

  openList=''
  nclosed=0
  for i in "${!PR_ID[@]}"; do
    echo "   PR ${PR_ID[$i]} (${PR_REPO[$i]} <- ${PR_BRANCH[$i]}): ${PR_STATUS[$i]} [${PR_FROM[$i]}]"
    if [[ "${PR_CLOSED[$i]}" == "1" ]]; then
      nclosed=$(( nclosed + 1 ))
    else
      openList="${openList:+$openList, }${PR_ID[$i]} (${PR_STATUS[$i]})"
    fi
  done
  if [[ -n "$openList" ]]; then
    echo "   holding: ${nclosed}/${#PR_ID[@]} closed - still open: $openList"
    SKIPPED=$(( SKIPPED + 1 ))
    continue
  fi

  # Every PR is closed. Now: is anything here not on the server?
  blockers=0
  for i in "${!CO_PATH[@]}"; do
    why="$(checkout_blocker "$i")"
    if [[ -n "$why" ]]; then
      echo "   HELD BACK: $why"
      blockers=$(( blockers + 1 ))
    fi
  done
  if (( blockers > 0 )); then
    echo '   commit and push, or re-run with --force-dirty / --force-unpushed'
    HELD=$(( HELD + 1 ))
    continue
  fi

  PLAN_IDS+=("$id")
  PLAN_PRS+=("${#PR_ID[@]}")
done

if (( ${#PLAN_IDS[@]} == 0 )); then
  echo
  log "examined $EXAMINED story/stories; none are ready to reap (skipped $SKIPPED, held back $HELD)"
  (( HELD > 0 )) && exit 5
  exit 3
fi

# --- warn ------------------------------------------------------------------
echo
echo "About to DELETE ${#PLAN_IDS[@]} story/stories whose pull requests have all closed:"
for k in "${!PLAN_IDS[@]}"; do
  id="${PLAN_IDS[$k]}"
  echo
  echo "  work item $id   (${PLAN_PRS[$k]} closed PR(s))"
  while IFS=$'\t' read -r fpath fisrev; do
    [[ -n "$fpath" ]] || continue
    if [[ "$fisrev" == "1" ]]; then echo "    folder    $fpath   [review copy]"
    else echo "    folder    $fpath"; fi
    while IFS=$'\t' read -r cpath cdir crepo cbranch; do
      [[ -n "$cpath" ]] || continue
      if [[ -n "$cbranch" && "$cbranch" != "HEAD" ]]; then
        echo "    worktree  $cdir on $cbranch (local branch will be deleted)"
      else
        echo "    worktree  $cdir detached (no branch to delete)"
      fi
    done < <(story_checkouts "$fpath")
  done <<<"${ID_FOLDERS[$id]}"
done
echo
echo 'WARNING: this deletes the worktree directories themselves, their local'
echo 'branches, their herdr workspaces, and their notes files. Remote branches'
echo 'and Azure DevOps are untouched.'
echo

if (( DRY_RUN )); then
  log "DRY RUN: would reap ${#PLAN_IDS[@]} story/stories; nothing was removed"
  log "examined $EXAMINED, skipped $SKIPPED, held back $HELD"
  (( HELD > 0 )) && exit 5
  exit 0
fi

if (( ! ASSUME_YES )); then
  if ! command -v gum >/dev/null 2>&1; then
    # No way to ask, so do not guess. A scheduled run passes --yes.
    echo 'gum is not installed, so there is no way to confirm. Re-run with --yes (or --dry-run first).' >&2
    exit 1
  fi
  # Do NOT redirect stderr: gum draws its prompt there and returns only the answer
  # on stdout, so a 2>/dev/null makes it look like a hang.
  if ! gum confirm "Delete ${#PLAN_IDS[@]} story worktree(s) listed above? This cannot be undone."; then
    log 'cancelled - nothing was removed'
    exit 3
  fi
fi

# --- execute ---------------------------------------------------------------
# Delegated to worktree-remove.sh so the hard-won rules about closing herdr rows
# before deleting checkouts, retrying locked directories and protecting default
# branches live in exactly one place.
for k in "${!PLAN_IDS[@]}"; do
  id="${PLAN_IDS[$k]}"
  echo
  folders=''
  while IFS=$'\t' read -r fpath fisrev; do
    [[ -n "$fpath" ]] || continue
    folders="${folders:+$folders, }$(basename "$fpath")"
  done <<<"${ID_FOLDERS[$id]}"
  log "reaping work item $id ($folders)"
  skipdirty=1
  (( FORCE_DIRTY )) && skipdirty=0
  set +e
  WT_ID="$id" WT_ASSUME_YES=1 WT_SKIP_DIRTY="$skipdirty" "$REMOVE_WORKTREE"
  rc=$?
  set -e
  case "$rc" in
    0)
      REAPED=$(( REAPED + 1 ))
      notify "Story reaped: $id" "All ${PLAN_PRS[$k]} PR(s) closed - worktrees, branches and rows removed." ;;
    3)
      log "nothing local left for story $id - already gone"
      SKIPPED=$(( SKIPPED + 1 )) ;;
    5)
      log "story $id held back by worktree-remove.sh (uncommitted changes)"
      HELD=$(( HELD + 1 )) ;;
    *)
      echo "WARNING: worktree-remove.sh exited $rc for story $id" >&2
      FAILED=$(( FAILED + 1 ))
      notify "Story reap FAILED: $id" "worktree-remove.sh exited $rc. See the story-reap log." ;;
  esac
done

echo
log "examined $EXAMINED, reaped $REAPED, skipped $SKIPPED, held back $HELD, failed $FAILED"
log 'nothing was written to Azure DevOps'

(( FAILED > 0 )) && exit 1
(( REAPED == 0 && HELD > 0 )) && exit 5
(( REAPED == 0 )) && exit 3
exit 0
