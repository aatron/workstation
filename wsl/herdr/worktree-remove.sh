#!/usr/bin/env bash
#
# worktree-remove.sh
# Delete an entire story by id: for every repo worktree in each matching story
# folder it
#   1. removes the worktree through herdr (`herdr worktree remove --force`),
#      which closes the workspace, deletes the checkout, AND drops the entry
#      from herdr's registry/sidebar (a plain `workspace close` leaves the
#      worktree listed),
#   2. falls back to `git worktree remove --force` (then rm -rf) when herdr
#      is not running or did not remove the directory, and
#   3. deletes the local git branch that worktree was on,
# then deletes every per-repo notes file and the story folder.
#
# This is the bash counterpart of win/herdr/worktree-remove.ps1. Fix a bug in
# one and fix it in the other.
#
# Two herdr shapes have to be handled, because worktree-make.sh changed:
#   * story workspaces (current) - plain workspaces, no worktree metadata: the
#     story row rooted at the story folder plus one indented repo row rooted at
#     each repo inside it. ALL of them are closed FIRST, and only when every
#     worktree in that story is going away: their agents hold files in the
#     checkouts open, so removing a checkout underneath a live pane is what
#     leaves undeletable debris behind.
#   * per-repo worktree workspace (legacy) - one herdr-registered worktree
#     workspace per repo, matched by checkout path. Stories created before the
#     switch still look like this, so `herdr worktree remove` stays.
#
# Input: story id only (arg $1, or WT_ID, or gum prompt). Slug is read from
# on-disk folder names matching {id}-* (current naming) or {id}_* (folders made
# before the rename) under:
#   <herdr [worktrees].directory>/development/<id>-*/   (development)
#   <herdr [worktrees].directory>/review/<id>-*/        (review)
# Per-repo notes files now live inside the story folder; the old location (a
# sibling of the story folder, under the type dir) is still cleaned up.
#
# Nothing machine-specific is hardcoded. Primary clones are discovered from each
# worktree, so SRC_ROOT is not needed here. Destructive — asks for confirmation
# first (unless WT_ASSUME_YES=1).
#
# Environment hooks (used by az-watcher; all optional):
#   WT_ID           story id (same as $1) — skips the prompt
#   WT_ASSUME_YES   1 = skip the gum confirmation (no tty needed)
#   WT_REPO         operate on ONLY this repo's worktree inside the story
#                   folder(s): its worktree, local branch and notes file. Other
#                   repos are left alone; the story folder is deleted only once
#                   no worktrees remain in it. Unset = whole story.
#   WT_SKIP_DIRTY   1 = refuse to delete a worktree with uncommitted or
#                   untracked changes (leave it, and keep its story folder).
#                   Off by default: an explicit manual removal already warns.
#
# Exit codes:
#   0  something was removed
#   3  nothing to do (no matching story folder / no matching repo worktree)
#   5  nothing removed because every match was dirty (WT_SKIP_DIRTY=1)
#
set -euo pipefail

# herdr-plus quick actions run with stdin = /dev/null. Prefer the pane PTY from
# stdout (fd 1); fall back to the controlling tty. Skip when non-interactive.
if [[ "${WT_ASSUME_YES:-}" != "1" && ! -t 0 ]]; then
  if [[ -t 1 ]]; then
    exec <&1
  elif [[ -r /dev/tty ]]; then
    exec </dev/tty
  else
    echo "no tty available for prompts (run from a herdr pane or terminal)" >&2
    exit 1
  fi
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need herdr; need git; need jq
if [[ "${WT_ASSUME_YES:-}" != "1" ]]; then
  need gum
fi

ask() { gum input --prompt "$1 > " --placeholder "$2"; }

# One-of-a-list prompt. Items are passed as ARGUMENTS, not piped in, so the
# label that comes back is byte-identical to the one offered and can be mapped
# straight back to its story. Prints nothing when gum errors or the user
# pressed esc.
#
# DO NOT redirect stderr here. gum draws its interactive menu on STDERR and
# returns only the chosen line on stdout (the same split fzf uses), so a
# `2>/dev/null` silently discards the entire UI — gum then sits waiting for
# keystrokes on a menu that was never drawn, which reads exactly like a hang.
# Measured: with no tty, `gum choose a b c` wrote 0 bytes to stdout and the whole
# menu to stderr. ask() above works for the same reason — it never redirects.
select_one() {
  local header="$1"; shift
  (($# > 0)) || return 1
  local height=$(( $# > 12 ? 12 : ($# < 3 ? 3 : $#) ))
  gum choose --header "$header" --height "$height" "$@" || return 1
}

# The stories that actually exist on disk, most recently touched first, as
# "<id>\t<id>-<slug>  [types]" rows on stdout.
#
# Keyed by id, not by folder: removal is by id and takes the development AND
# review copies together, so the same id must not appear twice. The types it was
# found under go on the row instead.
story_rows() {
  local type base d name id
  {
    for type in development review; do
      base="${HERDR_ROOT}/${type}"
      [[ -d "$base" ]] || continue
      for d in "$base"/*/; do
        [[ -d "$d" ]] || continue
        name="$(basename "${d%/}")"
        # Same shapes add_glob matches: {id}-{slug} and legacy {id}_{slug}.
        [[ "$name" =~ ^([0-9]+)[-_] ]] || continue
        id="${BASH_REMATCH[1]}"
        printf '%s\t%s\t%s\t%s\n' "$(stat -c %Y "${d%/}" 2>/dev/null || echo 0)" "$id" "$name" "$type"
      done
    done
  } | sort -rn | awk -F'\t' '
      # Rows arrive newest-first, so the first sighting of an id fixes its
      # position and its displayed name. Types are flagged, not appended, so the
      # label reads "development+review" in that order no matter which copy of
      # the story happens to have the newer mtime.
      { if (!($2 in seen)) { seen[$2]=1; order[++n]=$2; nm[$2]=$3 }
        if ($4 == "development") { dev[$2]=1 } else if ($4 == "review") { rev[$2]=1 } }
      END { for (i=1; i<=n; i++) { id=order[i]
              t = (id in dev) ? "development" : ""
              if (id in rev) t = (t == "") ? "review" : t "+review"
              printf "%s\t%s  [%s]\n", id, nm[id], t } }'
}

# Pick a story to delete. Falls back to typing an id whenever the list cannot be
# offered — no stories on disk, or a gum that will not draw — so this is never a
# dead end on a machine where the picker does not work.
select_story_id() {
  local -a ids=() labels=()
  local line
  while IFS=$'\t' read -r sid label || [[ -n "$sid" ]]; do
    [[ -n "$sid" ]] || continue
    ids+=("$sid"); labels+=("$label")
  done < <(story_rows)

  if ((${#ids[@]} == 0)); then
    echo "No story folders under ${HERDR_ROOT}/development|review — enter an id instead." >&2
    ask 'Story id' '12345'
    return
  fi

  local picked i
  picked="$(select_one 'Story to delete (esc to cancel)' "${labels[@]}")" || return 0
  [[ -n "$picked" ]] || return 0
  for i in "${!labels[@]}"; do
    if [[ "${labels[$i]}" == "$picked" ]]; then printf '%s\n' "${ids[$i]}"; return 0; fi
  done
  # Defensive: gum echoed something we did not offer. The id still leads.
  [[ "$picked" =~ ^([0-9]+)[-_] ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  return 0
}

# Resolve story root from Herdr [worktrees].directory (mirrors worktree-make.sh).
resolve_worktree_root() {
  local cfg="${HERDR_CONFIG_PATH:-${HOME}/.config/herdr/config.toml}"
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

# Default branch of a clone (never deleted).
# Refs that must never be deleted as a story branch. Blindly falling back to
# 'main' was unsafe: in a repo whose default is something else (e.g.
# develop) the guard below would not recognise the real default.
# Delete a directory, tolerating a transient holder: a freshly written checkout
# is routinely locked for a moment by an indexer, a virus scanner (on /mnt/c), or
# a pane that is still shutting down. One attempt then reporting "stuck" turns a
# wait-half-a-second problem into a failed removal. Succeeds when the path is gone.
remove_dir_retry() {
  local path="$1" attempt
  for attempt in 1 2 3 4; do
    [[ -e "$path" ]] || return 0
    rm -rf "$path" 2>/dev/null || true
    [[ -e "$path" ]] || return 0
    (( attempt < 4 )) && sleep "0.$((25 * attempt))"
  done
  [[ -e "$path" ]] && return 1
  return 0
}

is_protected_branch() {
  local src="$1" branch="$2" d n
  case "$branch" in main|master|trunk|develop|HEAD) return 0 ;; esac
  d="$(git -C "$src" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  [[ "${d#origin/}" == "$branch" ]] && return 0
  n="$(git -C "$src" ls-remote --symref origin HEAD 2>/dev/null \
       | awk '/^ref:/{sub("refs/heads/","",$2); print $2; exit}' || true)"
  [[ -n "$n" && "$n" == "$branch" ]] && return 0
  return 1
}

# Candidate story dirs: every {id}-* (and legacy {id}_*) under both layouts (dedup).
HERDR_ROOT="$(resolve_worktree_root)"

# --- inputs ----------------------------------------------------------------
# An explicit arg or WT_ID always wins, so az-watcher and any other automation
# are unaffected. Only a human with nothing supplied gets the picker.
ID="${1:-${WT_ID:-}}"
if [[ -z "$ID" ]]; then
  ID="$(select_story_id)"
fi
[[ -n "$ID" ]] || { echo "story id required" >&2; exit 1; }

declare -a CANDIDATES=()
add_candidate() {
  local d="$1" c
  [[ -d "$d" ]] || return 0
  for c in "${CANDIDATES[@]:-}"; do [[ "$c" == "$d" ]] && return 0; done
  CANDIDATES+=("$d")
}
add_glob() {
  local base="$1" d
  [[ -d "$base" ]] || return 0
  # {id}-<slug> is the current naming; {id}_<slug> is the pre-rename layout.
  for d in "$base"/"${ID}"-*/ "$base"/"${ID}"_*/; do
    [[ -d "$d" ]] || continue
    add_candidate "${d%/}"
  done
}
add_glob "${HERDR_ROOT}/development"
add_glob "${HERDR_ROOT}/review"

if (( ${#CANDIDATES[@]} == 0 )); then
  echo "No story folder matching ${ID}-* under:"
  echo "  ${HERDR_ROOT}/development|review"
  exit 3
fi

# Story folder name -> slug (accepts the current "{id}-{slug}" and the older
# "{id}_{slug}" folders).
slug_from_story_name() {
  local s="${1#"${ID}"}"
  printf '%s\n' "${s#[-_]}"
}

# herdr hands paths back with a trailing slash or a doubled separator now and
# then. Compare on this form. Unlike the Windows script this does NOT fold case:
# Linux paths are case-sensitive, and lowercasing would make two genuinely
# different directories look like the same row.
path_key() {
  local p="$1"
  [[ -n "$p" ]] || { printf '\n'; return 0; }
  while [[ "$p" == *"//"* ]]; do p="${p//\/\//\/}"; done
  [[ "$p" == "/" ]] || p="${p%/}"
  printf '%s\n' "$p"
}

workspace_list_json() { herdr workspace list 2>/dev/null || true; }

# Legacy shape: the herdr-registered worktree workspace for one repo checkout.
# Matching on the path (not the label) is robust: worktree labels are now just
# "<id>-<slug>" and repeat across repos, so they can't identify a single workspace.
workspace_id_for_path() {
  local want json ws cp
  want="$(path_key "$1")"
  [[ -n "$want" ]] || return 0
  json="$(workspace_list_json)"
  [[ -n "$json" ]] || return 0
  while IFS=$'\t' read -r ws cp; do
    [[ -n "$ws" ]] || continue
    if [[ "$(path_key "$cp")" == "$want" ]]; then printf '%s\n' "$ws"; return 0; fi
  done < <(jq -r '.result.workspaces[]? | select(.worktree != null)
                  | [.workspace_id, (.worktree.checkout_path // "")] | @tsv' \
             <<<"$json" 2>/dev/null)
  return 0
}

# Current shape: EVERY workspace belonging to the story - the story row itself
# plus the indented repo row worktree-make.sh creates for each repo under it.
# All of them are matched by the cwd of their panes rather than by label, since
# every one of those labels is a display name the user can change.
#
# "under" as well as "equal" is what picks up the repo rows (cwd = story/repo)
# and a pane the user cd'd somewhere deeper.
story_workspace_ids() {
  local want json ws panes cwd
  want="$(path_key "$1")"
  [[ -n "$want" ]] || return 0
  json="$(workspace_list_json)"
  [[ -n "$json" ]] || return 0
  while read -r ws; do
    [[ -n "$ws" ]] || continue
    panes="$(herdr pane list --workspace "$ws" 2>/dev/null || true)"
    [[ -n "$panes" ]] || continue
    while read -r cwd; do
      cwd="$(path_key "$cwd")"
      if [[ "$cwd" == "$want" || "$cwd" == "$want"/* ]]; then
        printf '%s\n' "$ws"; break
      fi
    done < <(jq -r '.result.panes[]?.cwd // empty' <<<"$panes" 2>/dev/null)
  done < <(jq -r '.result.workspaces[]? | select(.worktree == null) | .workspace_id' \
             <<<"$json" 2>/dev/null)
  return 0
}

# True when a worktree has uncommitted or untracked changes.
worktree_dirty() {
  local wt="$1"
  [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]
}

# --- plan (gather + show, then confirm) ------------------------------------
declare -a PLAN=()          # human-readable lines
declare -a WT_DIRS=() WT_REPO_NAMES=() WT_BRANCHES=() WT_PRIMARIES=() WT_WS=()
declare -a WT_STORY_DIRS=() WT_SLUGS=()
declare -a LEFTOVERS=()     # empty non-worktree dirs from a half-finished removal
# Story workspaces to close up front (parallel arrays: story dir / workspace id).
declare -a STORY_WS_DIRS=() STORY_WS_IDS=()
DIRTY_SKIPPED=0
STUCK=0
REMOVED_COUNT=0

for story_dir in "${CANDIDATES[@]}"; do
  story_name="${story_dir##*/}"
  slug="$(slug_from_story_name "$story_name")"
  PLAN+=("story ${story_name}:")
  # Worktrees this story has, versus the ones this run will take out. The story
  # workspace is only closed when those two agree - a WT_REPO-scoped removal, or
  # one held back by WT_SKIP_DIRTY, leaves the story (and its agents) alive.
  wt_total=0
  wt_removing=0
  for wt in "$story_dir"/*/; do
    wt="${wt%/}"
    if [[ ! -e "$wt/.git" ]]; then
      # Not a worktree. An EMPTY directory is the debris a half-finished removal
      # leaves behind (herdr unregisters the worktree, then cannot delete the
      # folder because a pane still holds it); collect it so the story can be
      # finished off. Anything with content in it is left strictly alone.
      if [[ -d "$wt" ]] && { [[ -z "${WT_REPO:-}" ]] || [[ "${wt##*/}" == "${WT_REPO}" ]]; }; then
        if [[ -z "$(ls -A "$wt" 2>/dev/null)" ]]; then
          LEFTOVERS+=("$wt")
          PLAN+=("  leftover ${wt} (empty, not a worktree - will delete)")
        else
          PLAN+=("  keep     ${wt} (not a worktree, and not empty)")
        fi
      fi
      continue
    fi
    repo="${wt##*/}"
    wt_total=$((wt_total + 1))
    # Single-repo mode: every other repo in this story is left untouched.
    if [[ -n "${WT_REPO:-}" && "$repo" != "${WT_REPO}" ]]; then
      PLAN+=("  keep     ${wt} (not ${WT_REPO})")
      continue
    fi
    if [[ "${WT_SKIP_DIRTY:-}" == "1" ]] && worktree_dirty "$wt"; then
      PLAN+=("  KEEP     ${wt} (uncommitted/untracked changes)")
      DIRTY_SKIPPED=$((DIRTY_SKIPPED + 1))
      continue
    fi
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
    # The main working tree is the first entry of `git worktree list`.
    primary="$( { git -C "$wt" worktree list --porcelain 2>/dev/null \
                  | awk '/^worktree /{print $2; exit}'; } || true )"
    ws="$(workspace_id_for_path "$wt" || true)"
    wt_removing=$((wt_removing + 1))
    WT_DIRS+=("$wt"); WT_REPO_NAMES+=("$repo"); WT_BRANCHES+=("$branch")
    WT_PRIMARIES+=("$primary"); WT_WS+=("$ws")
    WT_STORY_DIRS+=("$story_dir"); WT_SLUGS+=("$slug")
    PLAN+=("  worktree ${wt}")
    PLAN+=("    branch  ${branch:-<detached>} (in ${primary:-<unknown clone>})")
    PLAN+=("    notes   ${story_dir}/${ID}-${slug}-${repo}.txt")
    [[ -n "$ws" ]] && PLAN+=("    herdr   remove worktree + workspace ${ws}")
  done

  if (( wt_removing == wt_total )); then
    declare -a sws_ids=()
    mapfile -t sws_ids < <(story_workspace_ids "$story_dir")
    for sws in "${sws_ids[@]:-}"; do
      [[ -n "$sws" ]] || continue
      STORY_WS_DIRS+=("$story_dir")
      STORY_WS_IDS+=("$sws")
    done
    if (( ${#sws_ids[@]} > 0 )) && [[ -n "${sws_ids[0]}" ]]; then
      PLAN+=("  herdr    close ${#sws_ids[@]} story workspace(s): ${sws_ids[*]}")
      PLAN+=("           (the story row and its per-repo rows)")
    fi
  elif (( wt_total > 0 )); then
    PLAN+=("  herdr    story workspaces left open ($((wt_total - wt_removing)) worktree(s) staying)")
  fi

  if [[ -z "${WT_REPO:-}" ]]; then
    # Whole-story mode also clears notes left in the pre-rename location.
    type_dir="${story_dir%/*}"
    for nf in "${type_dir}/${ID}-${slug}-"*.txt; do
      [[ -e "$nf" ]] && PLAN+=("  notes    ${nf}")
    done
  fi
  PLAN+=("  folder   ${story_dir} (only once no worktrees remain in it)")
done

# Nothing this invocation can act on: report "nothing to do" instead of falling
# through to the folder cleanup, so overlapping cron runs stay silent.
if (( ${#WT_DIRS[@]} == 0 && ${#LEFTOVERS[@]} == 0 )); then
  printf '%s\n' "${PLAN[@]}"
  if (( DIRTY_SKIPPED > 0 )); then
    echo "Nothing removed for story ${ID}: ${DIRTY_SKIPPED} worktree(s) have uncommitted changes."
    exit 5
  fi
  echo "Nothing to remove for story ${ID}${WT_REPO:+ (repo ${WT_REPO})}."
  exit 3
fi

echo "About to DELETE story id ${ID}${WT_REPO:+, repo ${WT_REPO} only} (${#CANDIDATES[@]} folder(s)):"
printf '%s\n' "${PLAN[@]}"
echo
echo "WARNING: this deletes the worktree directories themselves — including any"
echo "uncommitted changes and untracked files inside them — plus their local"
echo "branches, herdr workspaces, and notes files."
echo
if [[ "${WT_ASSUME_YES:-}" == "1" ]]; then
  echo "WT_ASSUME_YES=1 — skipping confirmation"
else
  gum confirm "Delete all worktrees and files listed above? This cannot be undone." \
    || { echo "aborted."; exit 0; }
fi

# --- execute ---------------------------------------------------------------
# Close a story's workspaces - the story row AND its per-repo rows - BEFORE
# touching any checkout. Their agents hold files inside the checkouts open, and
# a repo row is rooted in the checkout itself; pull it out from under a live
# pane and `git worktree remove` fails on locked files, leaving exactly the
# half-deleted debris this script then has to mop up.
for i in "${!STORY_WS_IDS[@]}"; do
  sws="${STORY_WS_IDS[$i]}"
  [[ -n "$sws" ]] || continue
  sname="${STORY_WS_DIRS[$i]##*/}"
  if herdr workspace close "$sws" >/dev/null 2>&1; then
    echo "-> closed herdr workspace ${sws} (${sname})"
  else
    echo "  warn: could not close herdr workspace ${sws} (${sname}); carrying on" >&2
  fi
done
# Panes do not die the instant the workspace closes; give their handles a moment.
(( ${#STORY_WS_IDS[@]} > 0 )) && sleep 0.5

# Empty non-worktree debris first, so the story folder can actually go away.
for leftover in "${LEFTOVERS[@]:-}"; do
  [[ -n "$leftover" ]] || continue
  lws="$(workspace_id_for_path "$leftover" || true)"
  if [[ -n "$lws" ]]; then
    herdr workspace close "$lws" >/dev/null 2>&1 || true
  fi
  if remove_dir_retry "$leftover"; then
    echo "-> removed leftover directory ${leftover}"
  else
    echo "  warn: could not delete leftover directory ${leftover}" >&2
    STUCK=$((STUCK + 1))
  fi
done

for i in "${!WT_DIRS[@]}"; do
  wt="${WT_DIRS[$i]}"; repo="${WT_REPO_NAMES[$i]}"; branch="${WT_BRANCHES[$i]}"
  primary="${WT_PRIMARIES[$i]}"; ws="${WT_WS[$i]}"
  story_dir="${WT_STORY_DIRS[$i]}"; slug="${WT_SLUGS[$i]}"

  # Remove through herdr first: `worktree remove` closes the workspace, deletes
  # the checkout, and unregisters it (so it disappears from the sidebar).
  # `workspace close` alone leaves the worktree registered — that is why deleted
  # stories kept showing up.
  if [[ -n "$ws" ]]; then
    herdr worktree remove --workspace "$ws" --force >/dev/null 2>&1 \
      || { echo "  warn: herdr worktree remove failed for workspace ${ws}; closing it" >&2
           herdr workspace close "$ws" >/dev/null 2>&1 || true; }
  fi

  # Belt-and-braces: make sure the git worktree itself is gone (herdr not
  # running, removal failed, or no workspace was found for this path).
  if [[ -e "$wt" ]]; then
    if [[ -n "$primary" ]]; then
      git -C "$primary" worktree remove --force "$wt" \
        || { echo "  warn: git worktree remove failed for ${wt}; forcing rm" >&2
             remove_dir_retry "$wt" || true; }
    else
      echo "  warn: no primary clone for ${wt}; removing dir only" >&2
      remove_dir_retry "$wt" || true
    fi
  fi
  # git may report success yet leave the directory behind if a file was locked.
  if [[ -e "$wt" ]]; then
    remove_dir_retry "$wt" || true
  fi

  # Report honestly if the directory survived all of that, rather than going on
  # to delete the branch and the notes as though the worktree were gone.
  if [[ -e "$wt" ]]; then
    echo "  warn: could not delete ${wt} (something still has it open - a pane, an editor, or a running agent). Close it and re-run; leaving the branch and notes in place." >&2
    STUCK=$((STUCK + 1))
    continue
  fi

  if [[ -n "$primary" ]]; then
    # Clear any stale worktree registration left after an rm -rf fallback.
    git -C "$primary" worktree prune >/dev/null 2>&1 || true
    if [[ -n "$branch" ]] && ! is_protected_branch "$primary" "$branch"; then
      git -C "$primary" branch -D "$branch" \
        || echo "  warn: could not delete branch ${branch} in ${primary} (a future story of the same name will reuse it; worktree-make fast-forwards it)" >&2
    else
      echo "  skip: not deleting branch '${branch:-<detached>}' (empty/detached/protected)"
    fi
  fi

  # That repo's notes file + notespath sidecar. Whole-story removals delete the
  # folder below anyway, but doing it here is what makes single-repo mode leave
  # the story folder correct for the repos that are still there.
  rm -f "${story_dir}/${ID}-${slug}-${repo}.txt" "${story_dir}/.notespath-${repo}"
  REMOVED_COUNT=$((REMOVED_COUNT + 1))
done

# True when any repo worktree is still checked out inside a story folder.
story_has_worktrees() {
  local story_dir="$1" d
  for d in "$story_dir"/*/; do
    [[ -e "${d}.git" ]] && return 0
  done
  return 1
}

# Delete the story folder only once it holds no worktrees. This is what makes
# single-repo removals (and WT_SKIP_DIRTY keeps) safe: the folder survives until
# the last repo goes, and then it and its leftover notes/sidecars go with it.
for story_dir in "${CANDIDATES[@]}"; do
  story_name="${story_dir##*/}"
  slug="$(slug_from_story_name "$story_name")"
  type_dir="${story_dir%/*}"
  if story_has_worktrees "$story_dir"; then
    echo "-> keeping ${story_dir} (worktrees still present)"
    continue
  fi
  # In-folder notes go with the story folder below; this clears the old location.
  rm -f "${type_dir}/${ID}-${slug}-"*.txt
  # Safety: only delete a path whose basename is {id}-* or {id}_*
  if [[ -n "$story_dir" && ( "$story_name" == "${ID}-"* || "$story_name" == "${ID}_"* ) ]]; then
    # Retry: the story workspace was closed moments ago and its panes may still
    # be letting go of the folder they were rooted in.
    if remove_dir_retry "$story_dir"; then
      echo "-> removed folder ${story_dir}"
    else
      echo "  warn: could not delete story folder ${story_dir} (something still has it open)" >&2
      STUCK=$((STUCK + 1))
    fi
  fi
done

LEFT_NOTE=""
(( ${#LEFTOVERS[@]} > 0 )) && LEFT_NOTE=" (plus ${#LEFTOVERS[@]} empty leftover dir(s))"
if (( DIRTY_SKIPPED > 0 )); then
  echo "OK removed ${REMOVED_COUNT} worktree(s) for story ${ID}${LEFT_NOTE}; kept ${DIRTY_SKIPPED} with uncommitted changes."
else
  echo "OK removed ${REMOVED_COUNT} worktree(s) for story ${ID}${WT_REPO:+ (repo ${WT_REPO})}${LEFT_NOTE}."
fi

# A worktree that could not be deleted must not report success: the story is
# still half there, and a later worktree-make would trip over it.
if (( STUCK > 0 )); then
  echo "-> ${STUCK} worktree(s) could not be deleted - see the warnings above"
  exit 1
fi

exit 0
