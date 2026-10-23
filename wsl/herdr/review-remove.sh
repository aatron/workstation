#!/usr/bin/env bash
#
# review-remove.sh
# Clean up local code reviews whose pull requests have finished.
#
# usage: review-remove.sh [<work-item-id>] [options]
#          no id          examine every review under the review root
#          <id>           examine only that one
#
#        --dry-run             print what would go, remove nothing
#        --yes                 skip the confirmation (also WT_ASSUME_YES=1)
#        --include-abandoned   treat an abandoned PR as finished too
#        --force-dirty         remove a checkout that has uncommitted changes
#        --discard-notes       delete notes instead of archiving them
#        -h, --help
#
# This is the bash counterpart of win/herdr/review-remove.ps1. Fix a bug in one
# and fix it in the other.
#
# WHY THIS EXISTS SEPARATELY FROM worktree-remove.sh:
#   worktree-remove.sh takes a story id from a human and deletes it, branches
#   and all. This is the opposite: it is meant to run on a SCHEDULE with no one
#   watching, so it decides for itself what is safe to delete, and the bar it has
#   to clear is "the PR is finished, nothing here is unsaved". It is the cleanup
#   half of review-make.sh and the step before that cleanup runs automatically.
#
# THE RULE: A REVIEW GOES ONLY WHEN THE WHOLE REVIEW IS DONE
#   A work item can carry several PRs, in several repos. The item's folder and its
#   sidebar rows are removed only when EVERY one of those PRs has completed. One
#   PR still active holds the whole review in place, because a half-removed review
#   is worse than one that is late: the rows that survive no longer say what they
#   are missing.
#
#   A PR whose status cannot be read is NOT treated as finished. An expired
#   token, a network blip or a renamed repo must never be the reason a review
#   disappears, so anything short of a definite "completed" keeps it.
#
# WHAT IT WILL NOT DO
#   * touch Azure DevOps. Every az call goes through az_read, which refuses
#     anything not on $AZ_READ_ONLY. It reads PR status; it never votes, comments,
#     or changes a work item. This script cannot approve a review for you.
#   * delete work you typed. A checkout with uncommitted changes holds its review
#     back (exit 5) unless --force-dirty. Notes files with anything in them are
#     MOVED to <review root>/_notes/ rather than deleted - see save_notes.
#   * half-remove anything. A workspace of yours parked in the review folder also
#     holds the review back, because its pane keeps the directory open and the
#     delete would fail only after the rows were closed and the worktree
#     deregistered.
#   * close the "Review" root row. Every review shares it, and a scheduled job
#     yanking the workspace you are sitting in is not acceptable. It stays even
#     when the last review under it goes.
#   * delete a branch. Review checkouts are detached (review-make.sh uses
#     `git worktree add --detach`), so there is no branch to delete and no way
#     this can remove someone's work by name.
#
# Exit codes:
#   0  at least one review was removed
#   1  bad usage / a removal failed
#   3  nothing to do - no review had all of its PRs finished
#   5  a review was held back because a checkout has uncommitted changes
#
set -uo pipefail

# ===========================================================================
# EDIT THESE FOR YOUR MACHINE
# ===========================================================================
# Only used as a fallback: the clone a worktree belongs to is normally read out
# of the worktree's own .git file, which cannot be wrong.
SRC_ROOT="${WT_REVIEW_SRC_ROOT:-$HOME/source/repos}"

# Statuses that mean "this PR is finished". 'abandoned' is added by
# --include-abandoned: an abandoned PR is dead code, but deleting the review of
# one is a judgement call, so it is opt-in.
DONE_STATUS=(completed)

# Where a notes file with anything in it goes instead of the bin.
NOTES_ARCHIVE='_notes'

# Tree connectors, matching review-make.sh - they are reported as each row's
# $tree sidebar token, and removing a review means the survivors' connectors have
# to be re-reported so the corner lands on the new last one. TREE_GAP leads with
# U+2800 rather than a space because herdr trims leading whitespace off a token
# value.
TREE_C_TEE=$'├'
TREE_C_ELBOW=$'└'
TREE_C_PIPE=$'│'
TREE_C_DASH=$'─'
TREE_C_BLANK=$'⠀'
TREE_TEE="${TREE_C_TEE}${TREE_C_DASH}"
TREE_ELL="${TREE_C_ELBOW}${TREE_C_DASH}"
TREE_PIPE="${TREE_C_PIPE}  "
TREE_GAP="${TREE_C_BLANK}  "
TREE_INDENT="${TREE_C_BLANK} "

# ===========================================================================
REMOVED=0
HELD=0
FAILED=0
EXAMINED=0

ONLY=''
DRY_RUN=0
ASSUME_YES=0
[[ "${WT_ASSUME_YES:-}" == "1" ]] && ASSUME_YES=1
INCLUDE_ABANDONED=0
FORCE_DIRTY=0
[[ "${WT_FORCE_DIRTY:-}" == "1" ]] && FORCE_DIRTY=1
DISCARD_NOTES=0

show_usage() {
  cat <<'EOF'
usage: review-remove.sh [<work-item-id>] [options]

  no id                 examine every review under the review root
  <work-item-id>        examine only that review

options:
  --dry-run             print the intended actions; remove nothing
  --yes                 do not ask for confirmation (for scheduled runs)
  --include-abandoned   treat an abandoned PR as finished as well as completed
  --force-dirty         remove a checkout even if it has uncommitted changes
  --discard-notes       delete notes files instead of archiving them
  -h, --help            this text

A review is removed only when EVERY pull request on its work item has finished.
Azure DevOps is read, never written.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    ''|*[!0-9]*)
      case "$1" in
        --dry-run)           DRY_RUN=1 ;;
        --yes)               ASSUME_YES=1 ;;
        --include-abandoned) INCLUDE_ABANDONED=1 ;;
        --force-dirty)       FORCE_DIRTY=1 ;;
        --discard-notes)     DISCARD_NOTES=1 ;;
        -h|--help)           show_usage; exit 0 ;;
        *)
          echo "unknown argument: $1" >&2
          show_usage >&2
          exit 1
          ;;
      esac
      ;;
    *) ONLY="$1" ;;
  esac
  shift
done
(( INCLUDE_ABANDONED )) && DONE_STATUS+=(abandoned)

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }

AZ_CMD="${WT_REVIEW_AZ:-az}"

need herdr; need git; need jq
[[ -n "${WT_REVIEW_AZ:-}" ]] || need az

# ---------------------------------------------------------------------------
# Azure DevOps: read only, enforced. Same guard as review-make.sh - the check is
# on the leading non-flag words, which is exactly az's command path, so it cannot
# be slipped past with flag ordering.
# ---------------------------------------------------------------------------
AZ_READ_ONLY=(
  'account show'
  'boards work-item show'
  'devops configure'
  'devops invoke'
  'repos pr show'
  'repos pr list'
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
  local path found=0 entry a v i
  local -a args=("$@")
  path="$(az_command_path "$@")"
  for entry in "${AZ_READ_ONLY[@]}"; do
    [[ "$entry" == "$path" ]] && { found=1; break; }
  done
  (( found )) || return 1
  if [[ "$path" == 'devops invoke' ]]; then
    for i in "${!args[@]}"; do
      a="${args[$i]}"
      case "$a" in
        --in-file*|--body*) return 1 ;;
        --http-method)
          v="${args[$((i + 1))]:-}"
          [[ "${v^^}" == 'GET' ]] || return 1
          ;;
        --http-method=*)
          v="${a#--http-method=}"
          [[ "${v^^}" == 'GET' ]] || return 1
          ;;
      esac
    done
  fi
  return 0
}

AZ_EXIT=0

az_read() {
  if ! az_read_only "$@"; then
    echo "refusing to run a non-read-only az command: az $*. review-remove.sh only ever reads from Azure DevOps." >&2
    exit 1
  fi
  local out
  out="$(PYTHONIOENCODING=utf-8 PYTHONUTF8=1 "$AZ_CMD" "$@" 2>/dev/null)" || { AZ_EXIT=$?; printf ''; return 0; }
  AZ_EXIT=0
  printf '%s' "$out"
}

az_json() {
  local out
  out="$(az_read "$@")"
  (( AZ_EXIT == 0 )) || return 1
  [[ -n "$out" ]] || return 1
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# git / herdr plumbing (never fatal; judged on exit codes)
# ---------------------------------------------------------------------------
git_run() {
  local repo="$1"; shift
  git -C "$repo" "$@" 2>&1 | sed 's/^/   /'
  return "${PIPESTATUS[0]}"
}

herdr_json() {
  local out
  out="$(herdr "$@" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}

herdr_quiet() { herdr "$@" >/dev/null 2>&1 || true; }

# Unlike the Windows script this does NOT fold case: Linux paths are
# case-sensitive.
path_key() {
  local p="$1"
  [[ -n "$p" ]] || { printf '\n'; return 0; }
  while [[ "$p" == *"//"* ]]; do p="${p//\/\//\/}"; done
  [[ "$p" == "/" ]] || p="${p%/}"
  printf '%s\n' "$p"
}

herdr_config_path() {
  printf '%s\n' "${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"
}

# Reported under review-make's source id on purpose: it is the same token, and a
# second source would leave two competing values on the row.
set_tree_token() {
  local ws="$1" value="$2"
  [[ -n "$ws" ]] || return 0
  if [[ -n "$value" ]]; then
    herdr_quiet workspace report-metadata "$ws" --source review-make --token "tree=${value}"
  else
    herdr_quiet workspace report-metadata "$ws" --source review-make --clear-token tree
  fi
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

# ---------------------------------------------------------------------------
# Workspace index (plain workspaces only; worktree workspaces are not ours)
# ---------------------------------------------------------------------------
WSI_LOADED=0
declare -a WSI_ID=() WSI_LABEL=() WSI_NUM=() WSI_KEY=()

load_ws_index() {
  if (( WSI_LOADED )) && [[ "${1:-}" != "refresh" ]]; then return 0; fi
  WSI_ID=(); WSI_LABEL=(); WSI_NUM=(); WSI_KEY=()
  local json ws label num panes cwd
  json="$(herdr_json workspace list 2>/dev/null)" || json=""
  if [[ -n "$json" ]]; then
    while IFS=$'\t' read -r ws num label; do
      [[ -n "$ws" ]] || continue
      cwd=""
      panes="$(herdr_json pane list --workspace "$ws" 2>/dev/null)" || panes=""
      if [[ -n "$panes" ]]; then
        cwd="$(jq -r '[.result.panes[]?.cwd // empty] | map(select(. != "")) | .[0] // ""' <<<"$panes")"
      fi
      WSI_ID+=("$ws"); WSI_NUM+=("${num:-0}"); WSI_LABEL+=("$label")
      WSI_KEY+=("$(path_key "$cwd")")
    done < <(jq -r '.result.workspaces[]? | select(.worktree == null)
                    | [.workspace_id, (.number // 0), (.label // "")] | @tsv' <<<"$json")
  fi
  WSI_LOADED=1
}

bare_label() {
  local l="$1" prev="" c
  while [[ "$l" != "$prev" ]]; do
    prev="$l"
    for c in "$TREE_C_TEE" "$TREE_C_ELBOW" "$TREE_C_PIPE" "$TREE_C_DASH" "$TREE_C_BLANK" " "; do
      l="${l#"$c"}"
    done
  done
  printf '%s\n' "$l"
}

# Split the rows sitting in a review's folder into this review's own and everyone
# else's. Results land in ROWS_OURS / ROWS_FOREIGN as "id<TAB>label" lines.
#
# cwd alone is not a safe test for ownership. A pane belonging to the shared
# "Review" row that the user had cd'd down into the review folder sits at exactly
# the path the review's own row does - so a cwd-only match would close the Review
# root, which this script promises never to do, on a scheduled run with nobody
# watching. The row's name has to match the review or one of its PR folders too.
declare -a ROWS_OURS=() ROWS_FOREIGN=()
rows_under() {   # rows_under <dir> <name>...
  local dir="$1"; shift
  local want i name bare mine
  ROWS_OURS=(); ROWS_FOREIGN=()
  want="$(path_key "$dir")"
  [[ -n "$want" ]] || return 0
  load_ws_index
  for i in "${!WSI_ID[@]}"; do
    [[ -n "${WSI_KEY[$i]}" ]] || continue
    [[ "${WSI_KEY[$i]}" == "$want" || "${WSI_KEY[$i]}" == "$want"/* ]] || continue
    bare="$(bare_label "${WSI_LABEL[$i]}")"
    mine=0
    for name in "$@"; do [[ "$bare" == "$name" ]] && { mine=1; break; }; done
    if (( mine )); then
      ROWS_OURS+=("${WSI_ID[$i]}"$'\t'"${WSI_LABEL[$i]}")
    else
      ROWS_FOREIGN+=("${WSI_ID[$i]}"$'\t'"${WSI_LABEL[$i]}")
    fi
  done
}

# ---------------------------------------------------------------------------
# Working out what a review is made of
# ---------------------------------------------------------------------------

# The clone a worktree belongs to, read out of the worktree's own .git file:
#     gitdir: /home/me/source/repos/My_Repo/.git/worktrees/alice-repo
# Preferred over any recorded path because it is what git itself will use, so
# `git worktree remove` is guaranteed to be pointed at the right repository.
worktree_owner() {
  local wt="$1" dot line gitdir
  dot="${wt}/.git"
  [[ -f "$dot" ]] || return 0
  line="$(tr -d '\r' < "$dot" | head -n1)"
  [[ "$line" == gitdir:* ]] || return 0
  gitdir="${line#gitdir:}"
  gitdir="${gitdir#"${gitdir%%[![:space:]]*}"}"
  # .../<clone>/.git/worktrees/<name>  ->  <clone>
  [[ "$gitdir" == */.git/worktrees/* ]] || return 0
  printf '%s' "${gitdir%%/.git/worktrees/*}"
}

sanitize_segment() {
  local s="$1"
  s="$(sed -E 's/[^A-Za-z0-9._-]+/-/g' <<<"$s")"
  while [[ "$s" == [-.]* ]]; do s="${s#[-.]}"; done
  while [[ "$s" == *[-.] ]]; do s="${s%[-.]}"; done
  printf '%s' "$s"
}

local_repo_dir() { sanitize_segment "${1// /_}"; }

# folder -> PR id for one review, emitted as "prId<TAB>folder<TAB>repoDir<TAB>
# azRepo<TAB>from". The sidecar review-make.sh leaves behind is authoritative;
# re-deriving from the work item is the fallback for a review made before the
# sidecar existed, or one whose sidecar was deleted.
#
# Returns non-zero when it genuinely cannot tell, which is different from "no
# PRs": the caller must leave such a review alone rather than delete it.
review_prs() {   # review_prs <id> <item-dir>
  local id="$1" item_dir="$2" sidecar wi prj out="" prId repoDir author folder uniq
  local -A used=()
  sidecar="${item_dir}/review-${id}-prs.json"
  if [[ -f "$sidecar" ]]; then
    out="$(jq -r '.prs[]? | select((.prId // "") != "")
                  | [(.prId|tostring), (.folder // ""), (.repoDir // ""),
                     (.azRepo // ""), "index"] | @tsv' "$sidecar" 2>/dev/null || true)"
    if [[ -n "$out" ]]; then printf '%s\n' "$out"; return 0; fi
    echo "WARNING: could not read ${sidecar} - falling back to Azure DevOps" >&2
  fi
  wi="$(az_json boards work-item show --id "$id" --expand relations -o json)" || return 1
  while read -r prId; do
    [[ -n "$prId" ]] || continue
    prj="$(az_json repos pr show --id "$prId" -o json)" || return 1
    repoDir="$(local_repo_dir "$(jq -r '.repository.name // ""' <<<"$prj")")"
    uniq="$(jq -r '.createdBy.uniqueName // .createdBy.displayName // ""' <<<"$prj")"
    author=""
    [[ -n "$uniq" ]] && author="$(sanitize_segment "${uniq%%@*}")"
    author="${author,,}"
    [[ -n "$author" ]] || author='unknown'
    folder="${author}-${repoDir}"
    [[ -n "${used[$folder]:-}" ]] && folder="${folder}-pr${prId}"
    used["$folder"]=1
    printf '%s\t%s\t%s\t%s\t%s\n' "$prId" "$folder" "$repoDir" \
      "$(jq -r '.repository.name // ""' <<<"$prj")" 'azure'
  done < <(jq -r '
    [ .relations[]? | .url // ""
      | select(startswith("vstfs:///Git/PullRequestId/"))
      | sub("^vstfs:///Git/PullRequestId/"; "")
      | gsub("%2[fF]"; "/")
      | split("/") | last
      | select(test("^[0-9]+$")) ]
    | reduce .[] as $x ([]; if index($x) then . else . + [$x] end) | .[]' <<<"$wi" 2>/dev/null)
  return 0
}

# 'done' / 'open' / 'unknown' in PR_STATE, with a human string in PR_STATUS_TEXT.
# 'unknown' is deliberately NOT done: a status this script could not read must
# never be the reason a review is deleted.
PR_STATE=''
PR_STATUS_TEXT=''
pr_disposition() {
  local prId="$1" prj status s
  PR_STATE='unknown'
  prj="$(az_json repos pr show --id "$prId" -o json)" || {
    PR_STATUS_TEXT="unreadable (az exit ${AZ_EXIT})"; return 0; }
  status="$(jq -r '.status // "" | ascii_downcase' <<<"$prj")"
  if [[ -z "$status" ]]; then
    PR_STATUS_TEXT='no status in the response'; return 0
  fi
  PR_STATUS_TEXT="$status"
  PR_STATE='open'
  for s in "${DONE_STATUS[@]}"; do [[ "$s" == "$status" ]] && { PR_STATE='done'; break; }; done
  return 0
}

# ---------------------------------------------------------------------------
# Removal
# ---------------------------------------------------------------------------

# A directory herdr had a pane in does not always release immediately.
remove_dir_retry() {
  local path="$1" attempt
  for attempt in 1 2 3 4; do
    [[ -e "$path" ]] || return 0
    rm -rf "$path" 2>/dev/null || true
    [[ -e "$path" ]] || return 0
    sleep "0.$((2 * attempt))"
  done
  [[ -e "$path" ]] && return 1
  return 0
}

# Notes are the one thing here a human wrote. An empty file is noise and goes
# with the rest; anything with content is moved out to the archive, because a
# scheduled job silently deleting your review notes is not a trade worth making.
save_notes() {   # save_notes <item-dir> <review-root>
  local item_dir="$1" review_root="$2" n base archive dest stamp
  archive="${review_root}/${NOTES_ARCHIVE}"
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    [[ -s "$n" ]] || continue
    base="$(basename "$n")"
    if (( DISCARD_NOTES )); then
      echo "   discarding notes (--discard-notes): ${base}"
      continue
    fi
    (( DRY_RUN )) || mkdir -p "$archive"
    dest="${archive}/${base}"
    # Never overwrite an archived copy from an earlier review of the same id.
    if [[ -e "$dest" ]]; then
      stamp=2
      while [[ -e "$dest" ]]; do
        dest="${archive}/${base%.txt}-${stamp}.txt"
        stamp=$((stamp + 1))
      done
    fi
    if (( DRY_RUN )); then
      echo "   would archive notes: ${base} -> ${dest}"
    else
      mv -f "$n" "$dest"
      echo "   archived notes: ${dest}"
    fi
  done < <(find "$item_dir" -maxdepth 1 -type f -name '*-notes.txt' 2>/dev/null | LC_ALL=C sort)
}

# Re-report the connectors of whatever reviews are left, so the corner lands on
# the new last one instead of on a row that has just been closed.
update_tree_tokens() {   # update_tree_tokens <review-root>
  local review_root="$1" root_key rel first depth i
  local -a rows=() items=() prs=()
  local n d it id j is_last connector lead tail
  root_key="$(path_key "$review_root")"
  load_ws_index refresh
  for i in "${!WSI_ID[@]}"; do
    [[ -n "${WSI_KEY[$i]}" ]] || continue
    [[ "${WSI_KEY[$i]}" == "$root_key" ]] && continue
    [[ "${WSI_KEY[$i]}" == "$root_key"/* ]] || continue
    rel="${WSI_KEY[$i]#"$root_key"/}"
    first="${rel%%/*}"
    [[ "$first" =~ ^[0-9]+$ ]] || continue
    depth=1
    [[ "$rel" == */* ]] && depth=$(( $(tr -cd '/' <<<"$rel" | wc -c) + 1 ))
    rows+=("${WSI_NUM[$i]}"$'\t'"$depth"$'\t'"$first"$'\t'"${WSI_ID[$i]}")
  done
  (( ${#rows[@]} > 0 )) || return 0
  mapfile -t rows < <(printf '%s\n' "${rows[@]}" | sort -n -k1,1)
  mapfile -t items < <(printf '%s\n' "${rows[@]}" | awk -F'\t' '$2 == 1')
  for i in "${!items[@]}"; do
    IFS=$'\t' read -r n d it id <<<"${items[$i]}"
    is_last=0
    (( i == ${#items[@]} - 1 )) && is_last=1
    if (( is_last )); then connector="$TREE_ELL"; else connector="$TREE_TEE"; fi
    set_tree_token "$id" "${TREE_INDENT}${connector}"
    mapfile -t prs < <(printf '%s\n' "${rows[@]}" | awk -F'\t' -v it="$it" '$2 == 2 && $3 == it')
    if (( is_last )); then lead="$TREE_GAP"; else lead="$TREE_PIPE"; fi
    for j in "${!prs[@]}"; do
      if (( j == ${#prs[@]} - 1 )); then tail="$TREE_ELL"; else tail="$TREE_TEE"; fi
      set_tree_token "$(cut -f4 <<<"${prs[$j]}")" "${TREE_INDENT}${lead}${tail}"
    done
  done
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
WORKTREE_ROOT="$(resolve_worktree_root)"
REVIEW_ROOT="${WORKTREE_ROOT}/review"
echo "-> review root: ${REVIEW_ROOT}"
(( DRY_RUN )) && echo '-> DRY RUN: nothing will be removed'
join_or() {
  local out="" item
  for item in "$@"; do
    [[ -n "$out" ]] && out+=" or "
    out+="$item"
  done
  printf '%s' "$out"
}
echo "-> finished means: $(join_or "${DONE_STATUS[@]}")"

if [[ ! -d "$REVIEW_ROOT" ]]; then
  echo '-> no review root on disk - nothing to do'
  exit 3
fi

declare -a ITEM_DIRS=()
if [[ -n "$ONLY" ]]; then
  if [[ ! -d "${REVIEW_ROOT}/${ONLY}" ]]; then
    echo "-> no local review for work item ${ONLY} (${REVIEW_ROOT}/${ONLY})"
    exit 3
  fi
  ITEM_DIRS=("${REVIEW_ROOT}/${ONLY}")
else
  # Only numeric directories are reviews. This skips the notes archive and the
  # repo-centric folders an older worktree-make left directly under review/.
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    ITEM_DIRS+=("${REVIEW_ROOT}/${d}")
  done < <(find "$REVIEW_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
           | grep -E '^[0-9]+$' | LC_ALL=C sort)
fi
if (( ${#ITEM_DIRS[@]} == 0 )); then
  echo '-> no reviews on disk - nothing to do'
  exit 3
fi

# One plan per review, held as parallel arrays because bash has no object model.
# PLAN_WTS and PLAN_ROWS each hold a newline-joined blob of tab-separated records
# for that plan - "path<TAB>owner<TAB>folder" and "id<TAB>label" respectively.
declare -a PLAN_ID=() PLAN_DIR=() PLAN_REASON=()
declare -a PLAN_WTS=() PLAN_ROWS=()

for dir in "${ITEM_DIRS[@]}"; do
  id="$(basename "$dir")"
  EXAMINED=$((EXAMINED + 1))
  echo ''
  echo "-- work item ${id}"

  prs_out="$(review_prs "$id" "$dir")" || prs_out="__UNREADABLE__"
  if [[ "$prs_out" == "__UNREADABLE__" || -z "$prs_out" ]]; then
    echo '   cannot tell which PRs this review covers - leaving it alone'
    continue
  fi
  mapfile -t PRS < <(printf '%s\n' "$prs_out")
  froms="$(printf '%s\n' "${PRS[@]}" | cut -f5 | sort -u | paste -sd'/' -)"
  echo "   ${#PRS[@]} PR(s), from ${froms}"

  all_done=1
  done_count=0
  for line in "${PRS[@]}"; do
    IFS=$'\t' read -r prId folder repoDir azRepo from <<<"$line"
    pr_disposition "$prId"
    echo "   PR ${prId} (${azRepo}): ${PR_STATUS_TEXT}"
    if [[ "$PR_STATE" == "done" ]]; then
      done_count=$((done_count + 1))
    else
      all_done=0
    fi
  done
  if (( ! all_done )); then
    echo "   holding: ${done_count}/${#PRS[@]} finished - a review goes only when all of them have"
    continue
  fi

  # Everything on the item is finished. Now: is anything here unsaved?
  wts=""
  dirty=""
  names=("$id")
  for line in "${PRS[@]}"; do
    IFS=$'\t' read -r prId folder repoDir azRepo from <<<"$line"
    names+=("$folder")
    path="${dir}/${folder}"
    [[ -e "${path}/.git" ]] || continue
    changes="$(git -C "$path" status --porcelain 2>/dev/null | grep -c . || true)"
    [[ "$changes" =~ ^[0-9]+$ ]] || changes=0
    if (( changes > 0 )); then
      [[ -n "$dirty" ]] && dirty+=", "
      dirty+="${folder} (${changes} change(s))"
    fi
    owner="$(worktree_owner "$path")"
    if [[ -z "$owner" ]]; then
      owner="${SRC_ROOT}/${repoDir}"
      echo "WARNING: could not read the owning clone from ${path}/.git - falling back to ${owner}" >&2
    fi
    [[ -n "$wts" ]] && wts+=$'\n'
    wts+="${path}"$'\t'"${owner}"$'\t'"${folder}"
  done
  if [[ -n "$dirty" ]] && (( ! FORCE_DIRTY )); then
    echo "   HELD BACK: uncommitted changes in ${dirty}"
    echo '   commit or discard them, or re-run with --force-dirty'
    HELD=$((HELD + 1))
    continue
  fi
  if [[ -n "$dirty" ]]; then
    echo "WARNING: --force-dirty: discarding uncommitted changes in ${dirty}" >&2
  fi

  # The names this review's rows are allowed to have: the work item id, and one
  # per PR folder. Anything else sitting at these paths belongs to someone else.
  rows_under "$dir" "${names[@]}"

  # A workspace of yours parked in this folder is a hard stop, not a warning.
  # Its pane holds an open handle on the directory, so the delete fails - and it
  # fails AFTER the rows have been closed and the worktree deregistered, leaving
  # exactly the half-removed review this script refuses to produce elsewhere.
  # Held back instead: nothing is touched, and the message says what to do.
  if (( ${#ROWS_FOREIGN[@]} > 0 )); then
    foreign=""
    for line in "${ROWS_FOREIGN[@]}"; do
      IFS=$'\t' read -r rid rlabel <<<"$line"
      [[ -n "$foreign" ]] && foreign+=", "
      foreign+="${rid} [${rlabel}]"
    done
    echo "   HELD BACK: another workspace is parked in this folder: ${foreign}"
    echo '   close it (or cd it somewhere else), then re-run'
    HELD=$((HELD + 1))
    continue
  fi

  PLAN_ID+=("$id")
  PLAN_DIR+=("$dir")
  PLAN_REASON+=("all ${#PRS[@]} PR(s) finished")
  PLAN_WTS+=("$wts")
  PLAN_ROWS+=("$(printf '%s\n' "${ROWS_OURS[@]:-}")")
done

if (( ${#PLAN_ID[@]} == 0 )); then
  echo ''
  echo "-> examined ${EXAMINED} review(s); none are ready to remove"
  (( HELD > 0 )) && exit 5
  exit 3
fi

echo ''
echo 'Ready to remove:'
for i in "${!PLAN_ID[@]}"; do
  echo "  ${PLAN_ID[$i]}  ${PLAN_REASON[$i]}"
  while IFS=$'\t' read -r p o f; do
    [[ -n "$f" ]] && echo "    worktree  ${f}"
  done <<<"${PLAN_WTS[$i]}"
  while IFS=$'\t' read -r rid rlabel; do
    [[ -n "$rid" ]] && echo "    herdr row ${rid} [${rlabel}]"
  done <<<"${PLAN_ROWS[$i]}"
done
echo '  (the shared "Review" row is left open)'

if (( ! DRY_RUN )) && (( ! ASSUME_YES )); then
  if command -v gum >/dev/null 2>&1; then
    if ! gum confirm "Remove ${#PLAN_ID[@]} finished review(s)?"; then
      echo '-> cancelled'
      exit 3
    fi
  else
    # No way to ask, so do not guess. A scheduled run passes --yes.
    echo 'gum is not installed, so there is no way to confirm. Re-run with --yes (or --dry-run first).' >&2
    exit 1
  fi
fi

for i in "${!PLAN_ID[@]}"; do
  echo ''
  echo "== removing review ${PLAN_ID[$i]}: ${PLAN_REASON[$i]}"

  # Close the rows FIRST: a pane sitting in the directory keeps a handle on it,
  # and the delete then fails for a reason that has nothing to do with git.
  row_count=0
  while IFS=$'\t' read -r rid rlabel; do
    [[ -n "$rid" ]] || continue
    row_count=$((row_count + 1))
    if (( DRY_RUN )); then
      echo "   would close herdr row ${rid} [${rlabel}]"
    else
      herdr_quiet workspace close "$rid"
      echo "   closed herdr row ${rid} [${rlabel}]"
    fi
  done <<<"${PLAN_ROWS[$i]}"
  if (( ! DRY_RUN )) && (( row_count > 0 )); then sleep 0.5; fi

  ok=1
  while IFS=$'\t' read -r wpath wowner wfolder; do
    [[ -n "$wpath" ]] || continue
    if (( DRY_RUN )); then
      echo "   would remove worktree ${wpath} (owner ${wowner})"
      continue
    fi
    if (( FORCE_DIRTY )); then
      rm_ok=0; git_run "$wowner" worktree remove --force "$wpath" && rm_ok=1
    else
      rm_ok=0; git_run "$wowner" worktree remove "$wpath" && rm_ok=1
    fi
    if (( rm_ok )); then
      echo "   removed worktree ${wpath}"
    else
      # The registration is what matters; a directory git will not let go of is
      # dealt with by the recursive delete below, then pruned.
      echo "WARNING: git worktree remove failed for ${wpath} - deleting the directory and pruning" >&2
      remove_dir_retry "$wpath" || ok=0
    fi
    git -C "$wowner" worktree prune >/dev/null 2>&1 || true
  done <<<"${PLAN_WTS[$i]}"

  save_notes "${PLAN_DIR[$i]}" "$REVIEW_ROOT"

  if (( DRY_RUN )); then
    echo "   would delete ${PLAN_DIR[$i]}"
    REMOVED=$((REMOVED + 1))
    continue
  fi
  if remove_dir_retry "${PLAN_DIR[$i]}"; then
    echo "   deleted ${PLAN_DIR[$i]}"
  else
    echo "WARNING: could not delete ${PLAN_DIR[$i]} - something still holds it open" >&2
    ok=0
  fi
  if (( ok )); then REMOVED=$((REMOVED + 1)); else FAILED=$((FAILED + 1)); fi
done

if (( ! DRY_RUN )); then
  update_tree_tokens "$REVIEW_ROOT" \
    || echo "WARNING: the reviews were removed, but redrawing the remaining tree failed" >&2
fi

echo ''
echo "OK examined ${EXAMINED}, removed ${REMOVED}, held back ${HELD}, failed ${FAILED}"
echo '   nothing was written to Azure DevOps'

(( FAILED > 0 )) && exit 1
(( HELD > 0 && REMOVED == 0 )) && exit 5
(( REMOVED == 0 )) && exit 3
exit 0
