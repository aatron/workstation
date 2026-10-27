#!/usr/bin/env bash
#
# review-remove.sh
# Clean up local code-review folders (and their herdr rows).
#
# usage: review-remove.sh [<work-item-id>...] [options]
#          no id, interactive   multi-select which reviews to remove now
#          no id, --yes         scheduled scan: only reviews whose PRs are done
#          <id> [...]           remove those reviews now (no PR-status gate)
#
#        --dry-run             print what would go, remove nothing
#        --yes                 skip the confirmation (also WT_ASSUME_YES=1)
#        --include-abandoned   treat an abandoned PR as finished too (scan mode)
#        --force-dirty         discard dirty checkouts (implied when ids given)
#        -h, --help
#
# TWO MODES
#   Explicit id(s) or interactive pick: remove now - open PRs, dirty checkouts,
#   and extra panes under that folder do not block. Notes stay in the review
#   folder and are deleted with it (no separate archive).
#
#   No id + --yes (scan / cron): only remove a review when EVERY linked PR is
#   finished (completed, plus abandoned if --include-abandoned). Dirty checkouts
#   and foreign panes still hold a review back unless --force-dirty.
#
# WHAT IT WILL NOT DO
#   * touch Azure DevOps. Every az call goes through az_read (read-only).
#   * close the shared "Review" root row.
#   * delete a branch (checkouts are detached).
#
# Exit codes:
#   0  at least one review was removed
#   1  bad usage / a removal failed
#   3  nothing to do
#   5  a review was held back (scan mode only)
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

declare -a ONLY_IDS=()
DRY_RUN=0
ASSUME_YES=0
[[ "${WT_ASSUME_YES:-}" == "1" ]] && ASSUME_YES=1
INCLUDE_ABANDONED=0
FORCE_DIRTY=0
[[ "${WT_FORCE_DIRTY:-}" == "1" ]] && FORCE_DIRTY=1

show_usage() {
  cat <<'EOF'
usage: review-remove.sh [<work-item-id>...] [options]

  no id (interactive)   multi-select reviews to remove now
  no id --yes           scan: remove only reviews whose PRs are all finished
  <work-item-id>...     remove those reviews now (ignores PR status)

options:
  --dry-run             print the intended actions; remove nothing
  --yes                 do not ask for confirmation (for scheduled runs)
  --include-abandoned   (scan) treat abandoned PRs as finished too
  --force-dirty         (scan) remove even if a checkout has local changes
                        (always on when ids are given / picked)
  -h, --help            this text

Notes live in each review/<id>/ folder and are removed with that folder.
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
        --discard-notes)
          # Legacy no-op: notes stay in the review folder and are deleted with it.
          ;;
        -h|--help)           show_usage; exit 0 ;;
        *)
          echo "unknown argument: $1" >&2
          show_usage >&2
          exit 1
          ;;
      esac
      ;;
    *) ONLY_IDS+=("$1") ;;
  esac
  shift
done
(( INCLUDE_ABANDONED )) && DONE_STATUS+=(abandoned)

# herdr-plus quick actions run with stdin = /dev/null. Prefer the pane PTY.
if [[ "$ASSUME_YES" != "1" && ! -t 0 ]]; then
  if [[ -t 1 ]]; then
    exec <&1
  elif [[ -r /dev/tty ]]; then
    exec </dev/tty
  fi
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }

AZ_CMD="${WT_REVIEW_AZ:-az}"

need herdr; need git; need jq
[[ -n "${WT_REVIEW_AZ:-}" ]] || need az
if (( ASSUME_YES == 0 )); then
  need gum
fi

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
# review-make.sh chmods PR checkouts read-only; restore write before rm -rf.
remove_dir_retry() {
  local path="$1" attempt
  for attempt in 1 2 3 4; do
    [[ -e "$path" ]] || return 0
    chmod -R u+w "$path" 2>/dev/null || true
    rm -rf "$path" 2>/dev/null || true
    [[ -e "$path" ]] || return 0
    sleep "0.$((2 * attempt))"
  done
  [[ -e "$path" ]] && return 1
  return 0
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
# Numeric review folders under REVIEW_ROOT, newest first.
list_review_ids() {
  local d
  [[ -d "$REVIEW_ROOT" ]] || return 0
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    printf '%s\t%s\n' "$(stat -c %Y "${REVIEW_ROOT}/${d}" 2>/dev/null || echo 0)" "$d"
  done < <(find "$REVIEW_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
           | grep -E '^[0-9]+$') \
    | sort -rn | cut -f2
}

# Interactive pick of bare work-item ids (newest first from list_review_ids).
# Prints selected ids (one per line) on stdout.
#
# Do NOT use gum --select-if-one: with one review it skips the UI and returns
# immediately. One review = single-select (Enter confirms). Several = multi-select
# (space toggles, Enter confirms).
pick_review_ids() {
  local -a ids=() selected=() out=()
  local height o
  mapfile -t ids < <(list_review_ids)
  (( ${#ids[@]} > 0 )) || {
    echo "no reviews under ${REVIEW_ROOT}" >&2
    return 1
  }
  height=${#ids[@]}
  (( height > 15 )) && height=15
  (( height < 3 )) && height=3
  if (( ${#ids[@]} == 1 )); then
    mapfile -t selected < <(
      gum choose \
        --header "Delete this review? (enter confirms, esc cancels)" \
        --height "$height" \
        "${ids[@]}"
    ) || return 1
  else
    mapfile -t selected < <(
      gum choose --no-limit --ordered \
        --header "Reviews to delete (space toggles, enter confirms, esc cancels)" \
        --height "$height" \
        "${ids[@]}"
    ) || return 1
  fi
  for o in "${selected[@]}"; do
    o="${o//$'\r'/}"
    o="${o#"${o%%[![:space:]]*}"}"
    o="${o%"${o##*[![:space:]]}"}"
    [[ "$o" =~ ^[0-9]+$ ]] || continue
    out+=("$o")
  done
  (( ${#out[@]} > 0 )) || {
    echo "no reviews selected" >&2
    return 1
  }
  printf '%s\n' "${out[@]}"
}

if [[ ! -d "$REVIEW_ROOT" ]]; then
  echo '-> no review root on disk - nothing to do'
  exit 3
fi

# Explicit id(s) or interactive pick => remove now. --yes with no ids => scan.
FORCE_NOW=0
declare -a ITEM_DIRS=()
if (( ${#ONLY_IDS[@]} > 0 )); then
  FORCE_NOW=1
  FORCE_DIRTY=1
  echo "-> mode: remove work item(s) now (no PR-status gate): ${ONLY_IDS[*]}"
  for id in "${ONLY_IDS[@]}"; do
    if [[ ! -d "${REVIEW_ROOT}/${id}" ]]; then
      echo "WARNING: no local review for work item ${id} (${REVIEW_ROOT}/${id})" >&2
      continue
    fi
    ITEM_DIRS+=("${REVIEW_ROOT}/${id}")
  done
elif (( ASSUME_YES )); then
  echo "-> mode: scan (remove only when every PR is finished)"
  echo "-> finished means: $(join_or "${DONE_STATUS[@]}")"
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    ITEM_DIRS+=("${REVIEW_ROOT}/${d}")
  done < <(list_review_ids)
else
  echo "-> mode: pick reviews to remove now"
  # Process substitution hides the picker's exit status — capture it explicitly.
  _pick_out="$(pick_review_ids)" || exit 1
  mapfile -t ONLY_IDS <<<"$_pick_out"
  unset _pick_out
  FORCE_NOW=1
  FORCE_DIRTY=1
  echo "-> selected: ${ONLY_IDS[*]}"
  for id in "${ONLY_IDS[@]}"; do
    [[ -n "$id" ]] || continue
    ITEM_DIRS+=("${REVIEW_ROOT}/${id}")
  done
fi
if (( ${#ITEM_DIRS[@]} == 0 )); then
  if (( FORCE_NOW )); then
    echo '-> nothing to remove' >&2
    exit 3
  fi
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
  declare -a PRS=()
  if [[ "$prs_out" == "__UNREADABLE__" || -z "$prs_out" ]]; then
    if (( ! FORCE_NOW )); then
      echo '   cannot tell which PRs this review covers - leaving it alone'
      continue
    fi
    echo '   WARNING: could not read linked PRs - removing the folder from disk anyway'
  else
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
    if (( ! all_done )) && (( ! FORCE_NOW )); then
      echo "   holding: ${done_count}/${#PRS[@]} finished - scan mode waits until all are done"
      echo '   (pass the work item id to remove this review now)'
      continue
    fi
    if (( ! all_done )) && (( FORCE_NOW )); then
      echo "   note: ${done_count}/${#PRS[@]} PR(s) finished - removing anyway (forced)"
    fi
  fi

  wts=""
  dirty=""
  names=("$id")
  declare -A seen_folder=()
  for line in "${PRS[@]:-}"; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r prId folder repoDir azRepo from <<<"$line"
    [[ -n "$folder" ]] || continue
    names+=("$folder")
    seen_folder["$folder"]=1
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
  # Also pick up checkout folders not listed in the PR index (forced remove /
  # stale layout).
  while IFS= read -r folder; do
    [[ -n "$folder" ]] || continue
    [[ -n "${seen_folder[$folder]:-}" ]] && continue
    path="${dir}/${folder}"
    [[ -e "${path}/.git" ]] || continue
    names+=("$folder")
    seen_folder["$folder"]=1
    changes="$(git -C "$path" status --porcelain 2>/dev/null | grep -c . || true)"
    [[ "$changes" =~ ^[0-9]+$ ]] || changes=0
    if (( changes > 0 )); then
      [[ -n "$dirty" ]] && dirty+=", "
      dirty+="${folder} (${changes} change(s))"
    fi
    owner="$(worktree_owner "$path")"
    if [[ -z "$owner" ]]; then
      owner="${SRC_ROOT}/${folder}"
      echo "WARNING: could not read the owning clone from ${path}/.git - falling back to ${owner}" >&2
    fi
    [[ -n "$wts" ]] && wts+=$'\n'
    wts+="${path}"$'\t'"${owner}"$'\t'"${folder}"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort)

  if [[ -n "$dirty" ]] && (( ! FORCE_DIRTY )); then
    echo "   HELD BACK: uncommitted changes in ${dirty}"
    echo '   commit or discard them, or re-run with --force-dirty'
    HELD=$((HELD + 1))
    continue
  fi
  if [[ -n "$dirty" ]]; then
    echo "WARNING: discarding uncommitted changes in ${dirty}" >&2
  fi

  rows_under "$dir" "${names[@]}"

  # Scan mode: a foreign pane in this folder is a hard stop (avoids half-delete).
  # Explicit id: close those rows too - you asked to remove this review now.
  if (( ${#ROWS_FOREIGN[@]} > 0 )) && (( ! FORCE_NOW )); then
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
  if (( ${#ROWS_FOREIGN[@]} > 0 )) && (( FORCE_NOW )); then
    echo "   note: closing extra workspace row(s) under this review (forced)"
    ROWS_OURS+=("${ROWS_FOREIGN[@]}")
  fi

  reason="all ${#PRS[@]} PR(s) finished"
  (( FORCE_NOW )) && reason="requested (work item ${id})"
  PLAN_ID+=("$id")
  PLAN_DIR+=("$dir")
  PLAN_REASON+=("$reason")
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
    confirm_msg="Remove ${#PLAN_ID[@]} review(s)?"
    if ! gum confirm "$confirm_msg"; then
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
    # review-make.sh chmods checkouts read-only; unlock so git can remove them.
    chmod -R u+w "$wpath" 2>/dev/null || true
    # Explicit id always force-removes; scan uses --force-dirty when set.
    if (( FORCE_DIRTY )) || (( FORCE_NOW )); then
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

  # Notes live under the review folder (review-<id>-*.txt) and go with it.
  if (( DRY_RUN )); then
    echo "   would delete ${PLAN_DIR[$i]} (notes included)"
    REMOVED=$((REMOVED + 1))
    continue
  fi
  if remove_dir_retry "${PLAN_DIR[$i]}"; then
    echo "   deleted ${PLAN_DIR[$i]} (notes included)"
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
