#!/usr/bin/env bash
#
# worktree-make.sh
# Create a multi-repo herdr worktree structure for an Azure DevOps story.
# Two types: development and review.
#
# This is the bash counterpart of win/herdr/worktree-make.ps1 and is kept
# deliberately in step with it: same sidebar shape, same tab names (except the
# shell tab, which is 'bash' here and 'pwsh' there), same git guarantees, same
# exit codes. Fix a bug in one and fix it in the other.
#
# THE WORKSPACE IS THE STORY, NOT THE REPO:
#   herdr's sidebar groups workspaces by their source repository
#   (worktree.repo_key) and nests linked worktrees under their primary clone.
#   That grouping is built in - there is no config for it - so a workspace made
#   with `herdr worktree create` ALWAYS lands under its clone, and a story
#   spanning four repos became four unrelated rows in four different groups:
#       repo1 -> {id}-{slug}
#       repo2 -> {id}-{slug}
#   `herdr worktree create --workspace <ID>` is not a way out: --workspace and
#   --cwd are mutually exclusive, and --workspace only says which workspace to
#   take the SOURCE REPO from - it still creates a workspace of its own.
#   So this script adds the worktrees with plain `git worktree add` and builds
#   the rows itself. A workspace with no worktree metadata is not grouped at all,
#   so the sidebar reads story-first, one row per repo drawn beneath it:
#       {id}-{slug}            cwd = the story folder
#         |- repo1             cwd = {id}-{slug}/repo1
#         `- repo2             cwd = {id}-{slug}/repo2
#   The connectors need one line in config.toml - see init_story_workspace,
#   which prints it when it is missing.
#
#   The story row carries four tabs at the story root, where one agent sees every
#   repo in the story at once:
#       notes   micro on the notes file of the first repo requested
#       claude  $CLAUDE_CMD
#       cursor  $CURSOR_CMD
#       bash    bare shell
#   Each repo row carries three tabs at that repo's worktree root:
#       notes   micro on that repo's own notes file
#       claude  $CLAUDE_CMD
#       bash    bare shell
#
#   herdr has no real parent/child nesting - the sidebar is a flat list of
#   spaces - so the connector is a per-row token, and the rows are pulled into
#   one contiguous run explicitly (see set_sidebar_order).
#
#   Re-running for the same story reuses every workspace it already has and adds
#   only the tabs that are missing. Commands are submitted ONLY into tabs the run
#   created, so a tab you are already working in is never typed into.
#
# Git behavior on create - THE SCRIPT OWNS THE BRANCH, NOT HERDR:
#   `herdr worktree create --base <ref>` silently IGNORED --base when the local
#   branch already existed: it just checked that branch out wherever it happened
#   to point and still reported success. A branch left behind by an earlier story
#   (a removal that could not delete it, a worktree deleted by hand, another
#   tool) therefore produced a worktree pinned to an old commit - "you are N
#   commits behind" - with nothing in the output to say so. The script now runs
#   `git worktree add` itself, but it still owns the branch position outright:
#     1. `git fetch --prune origin`, WITH the exit status checked (one retry).
#        A failed fetch aborts the repo - never fall back to a stale origin.
#     2. `git remote set-head origin --auto` so refs/remotes/origin/HEAD (which
#        plain `git fetch` never updates) still names the real default branch.
#     3. Resolve the base to an explicit commit sha and verify it exists.
#     4. Put the local branch at exactly that sha - create it, fast-forward a
#        leftover branch that holds no unique commits, or refuse (see below).
#     5. `git worktree add`, then VERIFY the new worktree's HEAD is that sha,
#        repairing a clean worktree once with `git reset --hard` before giving up.
#   development -> base is origin/<default branch>
#   review      -> base is origin/<linked branch>
#   all types   -> the branch's upstream is pointed at its OWN name on origin
#                  (see set_push_upstream), so a plain `git push` from the
#                  worktree creates/updates origin/<branch> and can never
#                  target the default branch.
#
# When the local branch already exists AND holds commits that the base does not,
# the script refuses rather than silently hand back old code or silently discard
# work. It prints those commits and two opt-ins:
#   WT_REUSE_BRANCH=1  keep the existing branch as-is (resume the story; the
#                      script reports how far behind the base it is)
#   WT_RESET_BRANCH=1  discard the unique commits and start from the base
#
# Folder structure produced (no feature/<you> prefix on the path):
#   <herdr [worktrees].directory>/<type>/
#       <id>-<slug>/                 <- story folder
#           <id>-<slug>-<repo>.txt   <- per-repo notes (inside the story folder)
#           .notespath-<repo>        <- absolute path to that repo's notes file
#           <repo>/                  <- git worktree
#           <repo>/ ...
#
# Non-interactive mode (az-watcher / any automation):
#   Set BOTH WT_ID and WT_SLUG and every prompt is skipped - no tty, no gum.
#     WT_ID             story id            (required to enable this mode)
#     WT_SLUG           story slug          (required to enable this mode)
#     WT_REPOS          csv of repos        (development)
#     WT_BRANCHES_FILE  file of "<repo>:<branch>" lines (review; replaces the
#                       placeholder branch list)
#   Creating a worktree that already exists is a no-op ("exists, skipping"), and
#   a single repo failing is a warning rather than a fatal error, so re-runs from
#   cron are safe.
#
# Exit codes:
#   0  at least one worktree was created and verified
#   1  bad usage / missing input / at least one repo failed
#   3  nothing to do - every requested repo already had a worktree
#
set -euo pipefail

# ===========================================================================
# EDIT THESE FOR YOUR MACHINE
# ===========================================================================
SRC_ROOT="$HOME/source/repos"       # where your primary repo clones live
BRANCH_PREFIX="feature/YOU"         # edit this: feature/<you>/<id>-<slug>
# Story worktree base comes from Herdr config [worktrees].directory
# (this workflow uses ~/source/worktrees). Set that in ~/.config/herdr/config.toml.
#
# Commands the claude/cursor tabs start, both in their "auto" permission mode:
#   claude --permission-mode auto  -> auto-accepts safe work, still asks for the rest
#                                     (other modes: acceptEdits, dontAsk, plan,
#                                      bypassPermissions, manual)
#   agent --auto-review            -> Cursor "Smart Auto": auto-runs safe tool calls,
#                                     prompts for the rest (--force / --yolo runs
#                                     everything unless explicitly denied)
CLAUDE_CMD="claude --permission-mode auto"
CURSOR_CMD="agent --auto-review"

# The tabs of the story workspace, in the order they are created. All four open
# at the story root - the repos are sub-folders of it.
STORY_TABS=(notes claude cursor bash)

# The tabs of each repo's own workspace, opened at that repo's worktree root.
REPO_TABS=(notes claude bash)

# Tree connectors, reported as each repo row's $tree sidebar token so they render
# to the LEFT of the state icon and the bullet indents with the tree:
#
#     *  23597-my-story
#       |- . *  repo-a
#       `- . *  repo-b
#
# This only renders if config.toml asks for it (see tree_token_configured):
#
#   [ui.sidebar.spaces]
#   rows = [["$tree", "state_icon", "workspace"]]
#
# ABOUT THAT DOT: herdr joins the segments of a sidebar row with a hardcoded
# " . " (a middle dot) and exposes no setting for it - not at [ui],
# [ui.sidebar] or [ui.sidebar.spaces], and a row element's object form only
# accepts token/bold/dim/fg. So a connector segment followed by state_icon always
# shows it. Putting the connector in the LABEL instead avoids the dot, but then
# the status bullet is stuck at the far left and stops reading as nested; that was
# tried and rejected. Keeping the live bullet inside the tree is worth the dot -
# do not "fix" this by moving the connector back into the label.
#
# Held in $'...' so the bytes are fixed at parse time. The Windows script builds
# the same glyphs from char codes because PowerShell 5.1 reads a .ps1 as ANSI
# unless it has a BOM; bash has no such problem with a UTF-8 file, but keep them
# in one place here all the same so a swap only has to happen once.
TREE_C_TEE=$'├'     # the vertical-and-right of a mid-list connector
TREE_C_ELBOW=$'└'   # the up-and-right of the last one
TREE_C_PIPE=$'│'    # only ever seen on adopted labels, see bare_label
TREE_C_DASH=$'─'    # the horizontal arm of both
TREE_C_BLANK=$'⠀'   # braille pattern blank
TREE_BRANCH="${TREE_C_TEE}${TREE_C_DASH}"   # |- for all but the last repo
TREE_LAST="${TREE_C_ELBOW}${TREE_C_DASH}"   # `- for the last one
# Swap both for '|-' and '`-' if your terminal font has no box-drawing glyphs.

# Two blank columns in front of a repo row's connector, so it sits inside its
# story rather than flush under the story's own bullet.
#
# NOT two spaces: herdr TRIMS LEADING WHITESPACE off a token value, so '  |-'
# arrives as '|-' and the indent silently disappears. U+2800 BRAILLE PATTERN BLANK
# is blank on screen but is not whitespace to a trimmer, so it holds the first
# column open; the second can be an ordinary space because interior spaces are
# kept. If U+2800 shows as a box in your font, use two spaces and accept that the
# indent is lost, or pick another blank-but-not-whitespace glyph.
TREE_INDENT="${TREE_C_BLANK} "

# Fallback indent, used only when config.toml does NOT render the $tree token.
# It goes in the label, so it shifts the text but not the bullet - which is
# exactly the limitation $tree exists to fix.
CHILD_LABEL_PREFIX="  "

# ===========================================================================
TYPE="${1:-}"
if [[ "$TYPE" != "development" && "$TYPE" != "review" ]]; then
  echo "usage: $0 <development|review>" >&2
  exit 1
fi

# Non-interactive when the caller supplies both the id and the slug: no tty is
# reattached, gum is never needed, and per-repo failures are non-fatal.
NONINTERACTIVE=0
if [[ -n "${WT_ID:-}" && -n "${WT_SLUG:-}" ]]; then
  NONINTERACTIVE=1
fi

# Counters that decide the exit code (see header): a run that only re-found
# existing worktrees reports 3 so automation can stay quiet about it, and any
# repo-level failure makes the whole run exit non-zero so it cannot pass unnoticed.
CREATED=0
SKIPPED=0
FAILED=0

# herdr-plus quick actions run with stdin = /dev/null. Prefer duplicating the
# pane PTY from stdout (fd 1); fall back to the controlling tty.
if (( ! NONINTERACTIVE )) && [[ ! -t 0 ]]; then
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
(( NONINTERACTIVE )) || need gum

# ---------------------------------------------------------------------------
# herdr plumbing
#
# herdr writes ordinary progress to stderr, and mixing that into the captured
# stdout corrupts the JSON - a create that had actually succeeded then looks
# like a failure. Every capture keeps the two apart; the stderr of the last
# call is left in $HERDR_ERR for the error path.
# ---------------------------------------------------------------------------
HERDR_ERR=""

# Validated JSON on stdout, or nothing and a non-zero status.
herdr_json() {
  local out errfile
  errfile="$(mktemp)"
  out="$(herdr "$@" 2>"$errfile")" || out=""
  HERDR_ERR="$(cat "$errfile" 2>/dev/null || true)"
  rm -f "$errfile"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}

# Fire-and-forget herdr call (renames, closes, pane run, metadata): output
# discarded, never fatal.
herdr_quiet() { herdr "$@" >/dev/null 2>&1 || true; }

# "a, b, c" - written out rather than done with IFS and "${arr[*]}", which joins
# on a single character and would drop the space.
join_commas() {
  local out="" item
  for item in "$@"; do
    if [[ -n "$out" ]]; then out+=", "; fi
    out+="$item"
  done
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# Talking to the API socket directly
#
# herdr appends every new workspace to the END of the sidebar. That is fine when
# a story is built in one go, but adding a repo to a story that already exists
# drops the new row at the bottom of the sidebar, adrift from the story it
# belongs to - and no amount of connector drawing fixes a row that is thirty
# rows away from its parent.
#
# The protocol has the fix: workspace.move_block takes an ordered list of
# workspace ids plus an anchor to gather them in front of. `herdr workspace` has
# no move subcommand, so it is unreachable through the CLI and this has to speak
# to the socket itself.
#
# On Linux the socket is a real AF_UNIX stream socket and the protocol is plain
# newline-delimited JSON - no handshake, no token. (The Windows script does the
# same thing over a named pipe whose name is the socket file's own path; that is
# the only part of this that differs between the two.) python3 is used rather
# than socat or `nc -U` because it is the one of the three that is always there,
# and it can bound the read with a timeout.
#
# This is a display nicety, so every failure here is swallowed - no python3, an
# unreachable socket, an older herdr without the method. The rows are already
# correct; only their order suffers.
# ---------------------------------------------------------------------------
herdr_config_path() {
  printf '%s\n' "${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"
}

# Two things this must NOT do.
#
# It must not derive the socket from HERDR_CONFIG_PATH. That variable names a
# config FILE, which can sit anywhere - the test harness points it at a fixture -
# whereas the socket always lives in herdr's own directory. herdr's CLI resolves
# it this way too, which is why every `herdr` command still reaches the server
# when HERDR_CONFIG_PATH is pointed somewhere else entirely.
#
# And it must not assume the default session. A NAMED session gets its own socket
# under sessions/<name>/; a script that ignored HERDR_SESSION would talk to the
# 'default' server (or to nothing at all) while every herdr command it ran went
# somewhere else. herdr sets HERDR_SESSION in the environment of every pane it
# starts, so a script launched from a quick action inherits the right one.
herdr_socket_path() {
  if [[ -n "${HERDR_SOCKET_PATH:-}" ]]; then
    printf '%s\n' "$HERDR_SOCKET_PATH"; return 0
  fi
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
  if [[ -n "${HERDR_SESSION:-}" ]]; then
    printf '%s\n' "${dir}/sessions/${HERDR_SESSION}/herdr.sock"; return 0
  fi
  printf '%s\n' "${dir}/herdr.sock"
}

# One request, one response line. $2 is the params object as JSON text.
herdr_socket() {
  local method="$1" params="$2" sock
  sock="$(herdr_socket_path)"
  [[ -S "$sock" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$sock" "$method" "$params" <<'PY' 2>/dev/null
import json, socket, sys

sock_path, method, params = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(sock_path)
    req = {"id": "worktree-make", "method": method, "params": json.loads(params)}
    s.sendall((json.dumps(req) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
except Exception:
    sys.exit(1)
line = buf.decode("utf-8", "replace").split("\n", 1)[0].strip()
if not line:
    sys.exit(1)
sys.stdout.write(line)
PY
}

# Every workspace id in sidebar order, worktree-backed rows included. The rest of
# the script deliberately ignores those, but they still occupy sidebar positions,
# so ordering has to see the whole list to pick a correct anchor.
sidebar_ids() {
  herdr_json workspace list 2>/dev/null | jq -r '.result.workspaces[]?.workspace_id // empty'
}

# Move one workspace to an absolute 0-based position in the sidebar.
#
# workspace.move is used rather than the newer workspace.move_block because it is
# the only reordering call present on BOTH herdr builds this repo targets: the
# Windows machine runs a 0.7.5 preview (protocol 18, which has move_block), WSL
# runs plain 0.7.5 (protocol 17, which does not). Driving the older, narrower
# call from both sides keeps the two behaving identically instead of quietly
# doing nothing on whichever machine is behind.
#
# Semantics, verified against a live server: the workspace is removed from the
# list and re-inserted so that it ends up AT insert_index in the resulting list.
move_workspace() {
  local ws="$1" index="$2" resp params
  params="$(jq -cn --arg w "$ws" --argjson i "$index" \
    '{workspace_id: $w, insert_index: $i}')"
  resp="$(herdr_socket workspace.move "$params")" || return 1
  [[ -n "$resp" ]] || return 1
  jq -e '.error == null' >/dev/null 2>&1 <<<"$resp"
}

# Gather the given ids into one contiguous run, in the order given, without
# moving the group as a whole: the run is anchored where its topmost member
# already sits. Returns 0 only when the sidebar was actually changed.
set_sidebar_order() {
  local -a want=() current=() ids=() sim=() next=()
  local id i j seen=" " moved=0 start=-1 target at

  for id in "$@"; do
    [[ -n "$id" ]] || continue
    [[ "$seen" == *" $id "* ]] && continue
    seen+="$id "
    want+=("$id")
  done
  (( ${#want[@]} >= 2 )) || return 1

  mapfile -t current < <(sidebar_ids)
  (( ${#current[@]} > 0 )) || return 1

  # Drop ids herdr does not know about - a row closed by hand since the last
  # refresh would otherwise poison the whole call.
  local haystack=" ${current[*]} "
  for id in "${want[@]}"; do
    [[ "$haystack" == *" $id "* ]] && ids+=("$id")
  done
  (( ${#ids[@]} >= 2 )) || return 1

  # The run is anchored at the topmost member's current slot, so gathering the
  # group never slides the whole block up or down the sidebar.
  local group=" ${ids[*]} "
  for i in "${!current[@]}"; do
    if [[ "$group" == *" ${current[$i]} "* ]]; then start="$i"; break; fi
  done
  (( start >= 0 )) || return 1

  # Already contiguous and already in this order? Then leave the sidebar alone
  # rather than emitting a reorder event every single run.
  local same=1
  for i in "${!ids[@]}"; do
    if (( start + i >= ${#current[@]} )) || [[ "${current[$((start + i))]}" != "${ids[$i]}" ]]; then
      same=0; break
    fi
  done
  if (( same )); then return 1; fi

  # Place the members one at a time, simulating the resulting list as we go so
  # the next index is right without another round trip per move.
  sim=("${current[@]}")
  for i in "${!ids[@]}"; do
    target=$((start + i))
    at=-1
    for j in "${!sim[@]}"; do
      if [[ "${sim[$j]}" == "${ids[$i]}" ]]; then at="$j"; break; fi
    done
    (( at >= 0 )) || continue
    (( at == target )) && continue
    move_workspace "${ids[$i]}" "$target" || return 1
    moved=1
    next=()
    for j in "${!sim[@]}"; do
      (( j == at )) && continue
      next+=("${sim[$j]}")
    done
    sim=("${next[@]:0:target}" "${ids[$i]}" "${next[@]:target}")
  done

  (( moved )) || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Panes and tabs
# ---------------------------------------------------------------------------
pane_id_by_tab() {
  local ws="$1" tab="$2"
  herdr_json pane list --workspace "$ws" 2>/dev/null \
    | jq -r --arg tab "$tab" '.result.panes[]? | select(.tab_id==$tab) | .pane_id' \
    | head -n1
}

# Wait briefly for a pane's shell to come up, then report whether the pane is
# idle (foreground process is just the shell). Non-idle means something already
# started there, so we must not submit a second command on top of it.
pane_ready_and_idle() {
  local pane="$1" deadline=$((SECONDS + 5)) names="" n
  while (( SECONDS < deadline )); do
    names="$(herdr_json pane process-info --pane "$pane" 2>/dev/null \
             | jq -r '.result.process_info.foreground_processes[]?.name' || true)"
    [[ -n "$names" ]] && break
    sleep 0.2
  done
  [[ -n "$names" ]] || return 0        # cannot tell - assume idle and submit
  while read -r n; do
    case "$n" in ""|bash|sh|dash|zsh|fish|"-bash"|"-sh"|"-zsh") ;; *) return 1 ;; esac
  done <<<"$names"
  return 0
}

# Submit a command into a tab's pane, cd'd to the directory first so it runs
# there regardless of where the pane started.
run_in_tab() {
  local ws="$1" tab="$2" dir="$3" cmd="$4" pane
  pane="$(pane_id_by_tab "$ws" "$tab")"
  [[ -n "$pane" ]] || { echo "WARNING: no pane found for tab ${tab}" >&2; return 1; }
  if ! pane_ready_and_idle "$pane"; then
    echo "-> tab ${tab}: pane busy, left as-is"
    return 0
  fi
  herdr_quiet pane run "$pane" "cd $(printf '%q' "$dir") && ${cmd}"
}

# ---------------------------------------------------------------------------
# Notes files
#
# Per-repo notes file: <STORY_DIR>/<id>-<slug>-<repo>.txt - inside the story
# folder, next to the repo worktrees but never inside one, so it cannot dirty a
# repo. The sidecar ".notespath-<repo>" is kept so herdr's own worktree
# auto-layout (which reads "../.notespath-<repo>") still works if the worktree is
# later opened through herdr's worktree UI.
# ---------------------------------------------------------------------------
repo_notes_path() { printf '%s\n' "${STORY_DIR}/${ID}-${SLUG}-${1}.txt"; }

write_repo_notes() {
  local repo="$1" notes; notes="$(repo_notes_path "$repo")"
  [[ -e "$notes" ]] || : > "$notes"
  printf '%s' "$notes" > "${STORY_DIR}/.notespath-${repo}"
  echo "-> notes:  $notes"
}

# The notes file the story's notes tab opens: the first repo that was asked for,
# falling back to the first one that actually ended up with a notes file (the
# first repo may have failed).
story_notes_path() {
  local repo p
  for repo in "${REPO_ORDER[@]}"; do
    p="$(repo_notes_path "$repo")"
    [[ -e "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  if (( ${#REPO_ORDER[@]} > 0 )); then repo_notes_path "${REPO_ORDER[0]}"; fi
}

# ---------------------------------------------------------------------------
# Sidebar rows
# ---------------------------------------------------------------------------

# Compare paths herdr reports against paths we built. herdr sometimes hands back
# doubled separators. Unlike the Windows script this does NOT fold case: Linux
# paths are case-sensitive, and lowercasing them would make two genuinely
# different directories look like the same row.
path_key() {
  local p="$1"
  [[ -n "$p" ]] || { printf '\n'; return 0; }
  while [[ "$p" == *"//"* ]]; do p="${p//\/\//\/}"; done
  [[ "$p" == "/" ]] || p="${p%/}"
  printf '%s\n' "$p"
}

# Does the sidebar actually draw the $tree token?
#
# It is opt-in: herdr renders a space row from [ui.sidebar.spaces].rows, whose
# default is [["state_icon", "workspace"]] - state_icon first, so every bullet
# sits hard against the left edge and no connector is drawn at all. Only a row
# spec that puts $tree BEFORE state_icon draws the tree.
#
# install.sh never rewrites config.toml, so the script has to cope with both:
# with $tree the repo label is the bare repo name and the token supplies the
# drawing; without it the label carries a plain indent instead.
tree_token_configured() {
  local cfg; cfg="$(herdr_config_path)"
  [[ -f "$cfg" ]] || return 1
  awk '
    /^[[:space:]]*\[ui\.sidebar\.spaces\]/ { in_section = 1; next }
    /^[[:space:]]*\[/                      { in_section = 0; next }
    !in_section                            { next }
    /^[[:space:]]*#/                       { next }   # a commented sample does not count
    /\$tree/                               { found = 1; exit }
    END                                    { exit(found ? 0 : 1) }
  ' "$cfg"
}

# Display-only sidebar token. Never fatal: a herdr that does not take it just
# leaves the row looking the way it does today.
set_tree_token() {
  local ws="$1" value="$2"
  [[ -n "$ws" ]] || return 0
  if [[ -n "$value" ]]; then
    herdr_quiet workspace report-metadata "$ws" --source worktree-make --token "tree=${value}"
  else
    herdr_quiet workspace report-metadata "$ws" --source worktree-make --clear-token tree
  fi
}

# The identity inside a label, with any tree drawing or indent stripped off the
# front. Rows are matched on this, not on the whole label, so that a row labelled
# by an earlier version of this script - which drew the connectors in the label,
# or indented them with spaces - is adopted and renamed instead of duplicated.
#
# Stripped one whole multibyte glyph at a time rather than with a character
# class, so it behaves the same under LC_ALL=C as it does in a UTF-8 locale.
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

rename_workspace() {
  local ws="$1" label="$2"
  [[ -n "$ws" && -n "$label" ]] || return 0
  herdr_quiet workspace rename "$ws" "$label"
}

# The workspace sitting at $1 whose label names $2, or nothing when there is none.
#
# Both halves are required. Path alone is not enough now that a story has child
# workspaces one level down: a pane the user cd'd from the story root into a repo
# would otherwise look exactly like that repo's own workspace, and the repo's
# three tabs would be created in the story workspace instead. Name alone is not
# enough either - a development story and a review story of the same id share
# one. Together they are unambiguous.
#
# The comparison is against the BARE name, so the row is still found after the
# tree redraws its label (see bare_label).
#
# Worktree workspaces are skipped outright: they belong to a repo checkout
# registered with herdr, which is what this script stopped creating.
find_workspace_at() {
  local dir="$1" bare_name="$2" want ws label json panes cwd
  want="$(path_key "$dir")"
  [[ -n "$want" ]] || return 0
  json="$(herdr_json workspace list 2>/dev/null)" || return 0
  while IFS=$'\t' read -r ws label; do
    [[ -n "$ws" ]] || continue
    [[ "$(bare_label "$label")" == "$bare_name" ]] || continue
    panes="$(herdr_json pane list --workspace "$ws" 2>/dev/null)" || continue
    while read -r cwd; do
      if [[ "$(path_key "$cwd")" == "$want" ]]; then printf '%s\n' "$ws"; return 0; fi
    done < <(jq -r '.result.panes[]?.cwd // empty' <<<"$panes")
  done < <(jq -r '.result.workspaces[]? | select(.worktree == null)
                  | [.workspace_id, (.label // "")] | @tsv' <<<"$json")
}

# The repos of this story: the ones that were asked for first (so the row order
# matches the order you typed), then anything else in the folder that turns out
# to be a worktree - a repo added to the story by an earlier run, or by hand.
story_repos() {
  local -A seen=()
  local repo d
  for repo in "${REPO_ORDER[@]}"; do
    [[ -n "$repo" ]] || continue
    [[ -n "${seen[$repo]:-}" ]] && continue
    if [[ -e "${STORY_DIR}/${repo}/.git" ]]; then
      seen["$repo"]=1
      printf '%s\n' "$repo"
    fi
  done
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    [[ -n "${seen[$d]:-}" ]] && continue
    if [[ -e "${STORY_DIR}/${d}/.git" ]]; then
      seen["$d"]=1
      printf '%s\n' "$d"
    fi
  done < <(find "$STORY_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
}

# Create-or-reuse the workspace at $1 under label $2, holding exactly the tabs in
# the array named by $4, and start the commands in the associative array named by
# $5 (tab name -> command line). Sets NEW_WS to the workspace id, or '' if herdr
# would not create it.
#
# Cosmetic relative to the worktrees themselves: every failure warns and carries
# on, because the checkouts on disk are already correct and usable either way.
#
# Commands are only ever submitted into tabs THIS CALL created. pane_ready_and_idle
# is not enough on its own: herdr reports claude in a busy pane but reports only
# the shell for a pane sitting in micro, so a re-run that trusted the probe would
# type "micro <path>" straight into the open notes buffer.
NEW_WS=""
init_workspace() {
  local dir="$1" label="$2" bare_name="$3"
  local -n _wstabs="$4"
  local -n _wscmds="$5"
  local -A fresh=()
  local -A tabs=()
  local ws created root_tab name id t json
  local -a started=() kept=()

  NEW_WS=""
  ws="$(find_workspace_at "$dir" "$bare_name")"
  if [[ -n "$ws" ]]; then
    echo "-> herdr:  reusing workspace $ws ($bare_name)"
    # The row may carry a label from an earlier version of this script, which drew
    # the connectors in the label instead of the token.
    rename_workspace "$ws" "$label"
  else
    created="$(herdr_json workspace create --cwd "$dir" --label "$label" --no-focus)" || created=""
    ws=""
    [[ -n "$created" ]] && ws="$(jq -r '.result.workspace.workspace_id // empty' <<<"$created")"
    if [[ -z "$ws" ]]; then
      [[ -n "$HERDR_ERR" ]] && echo "$HERDR_ERR" >&2
      echo "WARNING: could not create the herdr workspace for '${label}' - the worktrees are fine; open ${dir} by hand" >&2
      return 0
    fi
    # A new workspace arrives with one numbered tab. Reuse it as the first tab
    # rather than leaving a stray "1" alongside the created ones.
    root_tab="$(jq -r '.result.tab.tab_id // empty' <<<"$created")"
    if [[ -n "$root_tab" && ${#_wstabs[@]} -gt 0 ]]; then
      herdr_quiet tab rename "$root_tab" "${_wstabs[0]}"
      fresh["${_wstabs[0]}"]=1
    fi
    echo "-> herdr:  workspace $ws created ($label) at $dir"
  fi

  json="$(herdr_json tab list --workspace "$ws" 2>/dev/null)" || json=""
  if [[ -n "$json" ]]; then
    while IFS=$'\t' read -r id name; do
      [[ -n "$name" ]] || continue
      [[ -n "${tabs[$name]:-}" ]] || tabs["$name"]="$id"
    done < <(jq -r '.result.tabs[]? | [.tab_id, (.label // "")] | @tsv' <<<"$json")
  fi

  for name in "${_wstabs[@]}"; do
    [[ -n "${tabs[$name]:-}" ]] && continue
    t="$(herdr_json tab create --workspace "$ws" --cwd "$dir" --label "$name" --no-focus)" || t=""
    id=""
    [[ -n "$t" ]] && id="$(jq -r '.result.tab.tab_id // empty' <<<"$t")"
    if [[ -n "$id" ]]; then
      tabs["$name"]="$id"
      fresh["$name"]=1
    else
      echo "WARNING: could not create the '${name}' tab in workspace ${ws}" >&2
    fi
  done

  for name in "${_wstabs[@]}"; do
    [[ -n "${fresh[$name]:-}" && -n "${tabs[$name]:-}" ]] || continue
    [[ -n "${_wscmds[$name]:-}" ]] || continue
    run_in_tab "$ws" "${tabs[$name]}" "$dir" "${_wscmds[$name]}" || true
  done

  for name in "${_wstabs[@]}"; do
    if [[ -n "${fresh[$name]:-}" ]]; then started+=("$name"); else kept+=("$name"); fi
  done
  echo "-> tabs:   $(join_commas "${_wstabs[@]}")"
  if (( ${#started[@]} )); then echo "           started: $(join_commas "${started[@]}")"; fi
  if (( ${#kept[@]} ));    then echo "           left as they were: $(join_commas "${kept[@]}")"; fi

  NEW_WS="$ws"
  return 0
}

# The story row, then one row per repo drawn beneath it as its children.
#
#     {id}-{slug}          story workspace, cwd = story folder
#     |- repo1             repo workspace,  cwd = story/repo1
#     `- repo2
#
# herdr has NO parent/child nesting: its sidebar is a flat list of spaces (only
# worktree workspaces get grouped, and then always under their clone - the very
# thing this replaced). Two things stand in for it:
#
#   * the connector, reported as each repo row's $tree token so it renders to the
#     LEFT of the state icon and the bullet indents with the tree. Indenting the
#     label alone cannot do that - the bullet comes from state_icon, the first
#     thing in the row - which is why $CHILD_LABEL_PREFIX is only the fallback
#     for a config.toml that does not lay the row out that way. herdr also draws
#     its own " . " between segments, which no setting suppresses; that dot is
#     accepted deliberately, see the $TREE_BRANCH block.
#   * adjacency, maintained explicitly through set_sidebar_order - a repo added
#     to an existing story is created last and would otherwise sit at the bottom
#     of the sidebar rather than under its story.
init_story_workspace() {
  local notes notes_name story_name ws dir repo_notes connector label rws
  local -a repos=() ordered=()
  local -A story_cmds=() repo_cmds=()
  local i tree=0

  notes="$(story_notes_path)"
  story_cmds[claude]="$CLAUDE_CMD"
  story_cmds[cursor]="$CURSOR_CMD"
  if [[ -n "$notes" ]]; then
    story_cmds[notes]="micro $(printf '%q' "$notes")"
    notes_name="$(basename "$notes")"
  else
    notes_name="none"
  fi
  echo "-> story:  workspace tabs at the story root (notes -> ${notes_name})"

  story_name="${ID}-${SLUG}"
  init_workspace "$STORY_DIR" "$story_name" "$story_name" STORY_TABS story_cmds
  ws="$NEW_WS"
  [[ -n "$ws" ]] || return 0
  # The story row is the trunk: no connector. An absent token renders as nothing -
  # no segment, so no separator dot either - the same way $jj_status does on a
  # workspace that is not a jj repo.
  set_tree_token "$ws" ''

  # The story row leads; each repo row follows in the order the story lists them.
  ordered=("$ws")

  tree_token_configured && tree=1
  mapfile -t repos < <(story_repos)
  for i in "${!repos[@]}"; do
    repo="${repos[$i]}"
    dir="${STORY_DIR}/${repo}"
    repo_notes="$(repo_notes_path "$repo")"
    repo_cmds=([claude]="$CLAUDE_CMD")
    if [[ -e "$repo_notes" ]]; then
      repo_cmds[notes]="micro $(printf '%q' "$repo_notes")"
    fi
    # Connectors are re-reported every run, so the repo that used to be last gives
    # up its corner when a new one is added after it.
    if (( i == ${#repos[@]} - 1 )); then connector="$TREE_LAST"; else connector="$TREE_BRANCH"; fi
    if (( tree )); then label="$repo"; else label="${CHILD_LABEL_PREFIX}${repo}"; fi
    echo "-> repo:   $repo"
    init_workspace "$dir" "$label" "$repo" REPO_TABS repo_cmds
    rws="$NEW_WS"
    set_tree_token "$rws" "${TREE_INDENT}${connector}"
    [[ -n "$rws" ]] && ordered+=("$rws")
  done

  # A repo added to a story that already exists is created last, so herdr parks
  # it at the bottom of the sidebar instead of under its story. Pull the story's
  # rows back into one run. The connectors above are drawn from $repos, not from
  # sidebar position, so they are already right either way - this only fixes
  # where the rows physically sit.
  if set_sidebar_order "${ordered[@]}"; then
    echo ''
    echo '-> sidebar: pulled the story rows back together'
  fi

  if (( ! tree )) && (( ${#repos[@]} > 0 )); then
    echo ''
    echo 'NOTE: the repo rows are indented by their label, so their bullets still sit'
    echo '      hard left and no connectors are drawn. To draw the tree, add this to'
    echo "      $(herdr_config_path) and run 'herdr server reload-config':"
    echo ''
    echo '        [ui.sidebar.spaces]'
    echo '        rows = [["$tree", "state_icon", "workspace"]]'
    echo ''
  fi
}

ask() { gum input --prompt "$1 > " --placeholder "$2"; }

# A repo-level problem. Fatal when a human is driving (they asked for exactly
# these repos); counted and reported in non-interactive mode so one bad repo
# cannot abort a cron run - but the run still exits non-zero at the end.
# Always returns 1, so every call site reads `repo_fail "..." || return 1`.
repo_fail() {
  FAILED=$((FAILED + 1))
  echo "ERROR: $1" >&2
  (( NONINTERACTIVE )) || exit 1
  return 1
}

# Idempotency: a worktree that is already checked out is left completely alone
# (no fetch, no herdr call, no tab churn). Makes re-runs - manual or every five
# minutes from cron - safe and silent.
worktree_present() {
  local repo="$1"
  if [[ -e "${STORY_DIR}/${repo}/.git" ]]; then
    echo "-> ${repo}: worktree exists at ${STORY_DIR}/${repo}, skipping"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  return 1
}

# Resolve story root from Herdr [worktrees].directory (see herdr.dev/docs/configuration).
# Falls back to Herdr's documented default when unset.
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
  # Escape ~ in ${var#pat}: an unescaped ~/ in the pattern is tilde-expanded to
  # $HOME/, so "${dir#~/}" would not strip a literal "~/..." prefix.
  case "$dir" in
    "~/"*) dir="${HOME}/${dir#\~/}" ;;
    "~")   dir="${HOME}" ;;
  esac
  dir="${dir//\$HOME/$HOME}"
  dir="${dir//\$\{HOME\}/$HOME}"
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# Git: getting the base right
# ---------------------------------------------------------------------------

# Resolve a ref to a full commit sha; prints nothing and fails when it does not
# exist.
resolve_commit() {
  git -C "$1" rev-parse --verify --quiet "$2^{commit}" 2>/dev/null
}

short_sha() { printf '%s\n' "${1:0:9}"; }

# Fetch, and MEAN it. A fetch that fails (expired credentials, network, a stale
# index.lock, a concurrent gc) used to be ignored, after which the worktree was
# cut from whatever origin/<default> happened to be - the exact "N commits
# behind" symptom. One retry, then the caller aborts the repo.
update_remote() {
  local src="$1" attempt
  for attempt in 1 2; do
    if (( attempt == 1 )); then
      echo "-> fetch:  git fetch --prune origin in ${src}"
    else
      echo "-> fetch:  git fetch --prune origin in ${src} (retry ${attempt})"
    fi
    if git -C "$src" fetch --prune origin; then
      return 0
    fi
    echo "WARNING: git fetch --prune origin failed in ${src}" >&2
    (( attempt == 1 )) && sleep 3
  done
  return 1
}

# `git fetch` never updates refs/remotes/origin/HEAD, so a clone made before the
# remote's default branch was renamed - or one where the ref was never written -
# keeps pointing at the wrong branch forever. Re-derive it from the remote.
# Best effort: offline, the cached ref (or the fallbacks below) still works.
sync_origin_head() {
  git -C "$1" remote set-head origin --auto >/dev/null 2>&1 || true
}

# Resolve a repo's default branch (main/master/...), locally if possible.
default_branch() {
  local src="$1" d candidate
  d="$(git -C "$src" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  d="${d#origin/}"
  if [[ -z "$d" ]]; then
    d="$(git -C "$src" ls-remote --symref origin HEAD 2>/dev/null \
         | awk '/^ref:/{sub("refs/heads/","",$2); print $2; exit}')"
  fi
  # Only trust it if the matching remote-tracking ref actually exists: the old
  # blind `main` fallback could name a branch that is real but is NOT the
  # default (or does not exist at all, which herdr then rejects outright).
  if [[ -n "$d" ]] && resolve_commit "$src" "refs/remotes/origin/${d}" >/dev/null; then
    printf '%s\n' "$d"; return 0
  fi
  for candidate in main master trunk develop; do
    if resolve_commit "$src" "refs/remotes/origin/${candidate}" >/dev/null; then
      echo "WARNING: origin/HEAD unusable in ${src}; falling back to origin/${candidate}" >&2
      printf '%s\n' "$candidate"; return 0
    fi
  done
  return 1
}

# Path of the worktree that has $2 checked out, or empty when it is free.
branch_worktree_path() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$2" '
    /^worktree /  { path = substr($0, 10) }
    $0 == "branch " b { print path; exit }
  '
}

commit_count() {
  local n
  n="$(git -C "$1" rev-list --count "$2" 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' "$n"
}

# Put the local branch at exactly $3 and set EXPECTED_SHA to the commit the new
# worktree must end up on. Returns non-zero to mean "do not create this one".
#
# This is the fix for the reported bug: herdr honours --base only when it has to
# create the branch, so the script guarantees the branch position itself.
EXPECTED_SHA=""
set_branch_at_base() {
  local src="$1" branch="$2" base="$3" base_label="$4"
  local existing in_use unique behind
  EXPECTED_SHA=""
  existing="$(resolve_commit "$src" "refs/heads/${branch}" || true)"

  if [[ -z "$existing" ]]; then
    git -C "$src" branch --no-track "$branch" "$base" \
      || repo_fail "could not create branch ${branch} at ${base_label} in ${src}" || return 1
    echo "-> branch: ${branch} created at ${base_label} ($(short_sha "$base"))"
    EXPECTED_SHA="$base"
    return 0
  fi

  # An existing branch checked out somewhere else is a hard conflict: git cannot
  # check it out twice, and silently reusing it is what produced stale worktrees
  # before.
  in_use="$(branch_worktree_path "$src" "$branch")"
  if [[ -n "$in_use" ]]; then
    repo_fail "branch ${branch} is already checked out at ${in_use} - remove that worktree first, or use a different story slug" || return 1
  fi

  if [[ "$existing" == "$base" ]]; then
    echo "-> branch: ${branch} already at ${base_label} ($(short_sha "$base"))"
    EXPECTED_SHA="$base"
    return 0
  fi

  unique="$(commit_count "$src" "${base}..refs/heads/${branch}")"
  behind="$(commit_count "$src" "refs/heads/${branch}..${base}")"

  if (( unique == 0 )); then
    # Leftover branch with nothing of its own - the common case after a story
    # was removed. Nothing can be lost, so move it to the base.
    git -C "$src" branch --force --no-track "$branch" "$base" \
      || repo_fail "could not move existing branch ${branch} to ${base_label} in ${src}" || return 1
    echo "-> branch: ${branch} was ${behind} commit(s) behind ${base_label} with no commits of its own - moved to $(short_sha "$base")"
    EXPECTED_SHA="$base"
    return 0
  fi

  if [[ "${WT_RESET_BRANCH:-}" == "1" ]]; then
    echo "WARNING: WT_RESET_BRANCH=1 - discarding ${unique} commit(s) on ${branch}:" >&2
    git -C "$src" log --oneline --no-decorate "${base}..refs/heads/${branch}" 2>/dev/null | sed 's/^/     /' || true
    git -C "$src" branch --force --no-track "$branch" "$base" \
      || repo_fail "could not reset branch ${branch} to ${base_label} in ${src}" || return 1
    echo "-> branch: ${branch} reset to ${base_label} ($(short_sha "$base"))"
    EXPECTED_SHA="$base"
    return 0
  fi

  if [[ "${WT_REUSE_BRANCH:-}" == "1" ]]; then
    echo "WARNING: WT_REUSE_BRANCH=1 - keeping existing ${branch} at $(short_sha "$existing"): ${unique} own commit(s), ${behind} behind ${base_label}. Run 'git merge ${base_label}' in the worktree to catch up." >&2
    EXPECTED_SHA="$existing"
    return 0
  fi

  git -C "$src" log --oneline --no-decorate "${base}..refs/heads/${branch}" 2>/dev/null | sed 's/^/     /' || true
  repo_fail "$(printf '%s\n' \
    "branch ${branch} already exists in ${src} at $(short_sha "$existing") with ${unique} commit(s)" \
    "  that ${base_label} does not have, and is ${behind} commit(s) behind it. Refusing to create" \
    "  a worktree that would be out of date or to throw those commits away. Either:" \
    "    WT_REUSE_BRANCH=1  keep the branch and resume the story on it" \
    "    WT_RESET_BRANCH=1  discard its ${unique} commit(s) and start from ${base_label}" \
    "  or delete it yourself:  git -C '${src}' branch -D ${branch}")" || return 1
}

# `git worktree add` refuses a path that is registered-but-missing (a worktree
# deleted by hand) or one that already has files in it. Prune the administrative
# leftovers and clear a directory an earlier failed run left empty.
init_worktree_path() {
  local src="$1" path="$2"
  git -C "$src" worktree prune >/dev/null 2>&1 || true
  [[ -e "$path" ]] || return 0
  if [[ -d "$path" ]] && [[ -z "$(ls -A "$path" 2>/dev/null)" ]]; then
    rmdir "$path" 2>/dev/null || true
    echo "-> path:   removed empty leftover directory ${path}"
    return 0
  fi
  repo_fail "${path} already exists, is not a worktree, and is not empty - remove it or use a different story slug" || return 1
}

# The safety net: whatever git did, the worktree must sit on $2.
assert_worktree_at() {
  local wt="$1" expected="$2" label="$3" head
  head="$(resolve_commit "$wt" HEAD || true)"
  if [[ "$head" == "$expected" ]]; then
    echo "-> verify: HEAD $(short_sha "$expected") == ${label}"
    return 0
  fi
  echo "WARNING: worktree ${wt} is at '${head}' but should be at $(short_sha "$expected") (${label}) - repairing" >&2
  if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null || true)" ]]; then
    repo_fail "worktree ${wt} is at the wrong commit and has local changes - fix it by hand" || return 1
  fi
  git -C "$wt" reset --hard "$expected" \
    || repo_fail "could not reset ${wt} to $(short_sha "$expected") (${label})" || return 1
  head="$(resolve_commit "$wt" HEAD || true)"
  if [[ "$head" != "$expected" ]]; then
    repo_fail "worktree ${wt} still at '${head}' after reset - expected $(short_sha "$expected")" || return 1
  fi
  echo "-> verify: HEAD repaired to $(short_sha "$expected") == ${label}"
}

# Point a branch's upstream at its own name on origin. Branching from
# origin/<default> makes git auto-track origin/<default>, so a plain
# `git push` either fails (push.default=simple: "upstream ... does not match
# the name of your current branch") or -- with push.default=upstream -- would
# push straight to the default branch. After this, `git push` from the
# worktree always creates/updates origin/<branch>, never origin/<default>.
# Idempotent, and branch config is per-branch so it cannot affect main.
# (Until the first push, `git pull` on the branch reports "no such ref" --
# expected: the remote branch does not exist yet; `git push` creates it.)
set_push_upstream() {
  local wt="$1" branch="$2"
  git -C "$wt" config "branch.${branch}.remote" origin
  git -C "$wt" config "branch.${branch}.merge" "refs/heads/${branch}"
  echo "-> push:   git push targets origin/${branch}"
}

# One worktree, one shared code path.
#   $3 = default -> base is origin/<default branch>   (development types)
#   $3 = remote  -> base is origin/<branch>           (review)
make_worktree() {
  local repo="$1" branch="$2" base_kind="$3"
  local src="${SRC_ROOT}/${repo}" path="${STORY_DIR}/${repo}"
  local base base_label def
  worktree_present "$repo" && return 0
  [[ -d "$src/.git" || -f "$src/.git" ]] || \
    repo_fail "missing clone: $src (set SRC_ROOT or clone the repo there)" || return 1

  init_worktree_path "$src" "$path" || return 1

  update_remote "$src" || \
    repo_fail "git fetch failed for ${repo} - refusing to create a worktree from a possibly stale origin. Check credentials/network and re-run." || return 1
  sync_origin_head "$src"

  if [[ "$base_kind" == "default" ]]; then
    def="$(default_branch "$src")" || \
      repo_fail "cannot determine the default branch of ${src} (no usable origin/HEAD)" || return 1
    base_label="origin/${def}"
  else
    base_label="origin/${branch}"
  fi

  base="$(resolve_commit "$src" "refs/remotes/${base_label}" || true)"
  [[ -n "$base" ]] || \
    repo_fail "${base_label} does not exist in ${src} after fetching - nothing to base ${branch} on" || return 1
  echo "-> base:   ${base_label} @ $(short_sha "$base")"

  set_branch_at_base "$src" "$branch" "$base" "$base_label" || return 1

  # The branch is already sitting on $EXPECTED_SHA, so this only checks it out.
  git -C "$src" worktree add "$path" "$branch" \
    || repo_fail "git worktree add failed for ${repo} at ${path}" || return 1

  assert_worktree_at "$path" "$EXPECTED_SHA" "$base_label" || return 1

  CREATED=$((CREATED + 1))
  set_push_upstream "$path" "$branch"
  write_repo_notes "$repo"
}

# --- roots -----------------------------------------------------------------
WORKTREE_ROOT="$(resolve_worktree_root)"
SUBFOLDER="$TYPE"
echo "-> worktree root (from herdr [worktrees].directory): ${WORKTREE_ROOT}"

# --- shared inputs ---------------------------------------------------------
if (( NONINTERACTIVE )); then
  ID="$WT_ID"
  SLUG="$WT_SLUG"
  echo "-> non-interactive (WT_ID/WT_SLUG supplied)"
else
  ID="$(ask 'Story id' '12345')"
  SLUG="$(ask 'Slug' 'slug-example')"
fi
[[ -n "$ID" && -n "$SLUG" ]] || { echo "id and slug required" >&2; exit 1; }

BRANCH="${BRANCH_PREFIX}/${ID}-${SLUG}"     # feature/<you>/<id>-<slug> (hyphen)
TYPE_DIR="${WORKTREE_ROOT}/${SUBFOLDER}"    # .../<subfolder>  (no feature/<you> prefix)
STORY_DIR="${TYPE_DIR}/${ID}-${SLUG}"       # parent of the repo worktrees
# Repos in the order they were requested. The first one owns the notes file the
# story's notes tab opens.
REPO_ORDER=()

mkdir -p "$STORY_DIR"
echo "-> story:  $STORY_DIR"
echo "-> branch: $BRANCH"

# ===========================================================================
# DEVELOPMENT
# ===========================================================================
if [[ "$TYPE" == "development" ]]; then
  if (( NONINTERACTIVE )); then
    REPOS="${WT_REPOS:-}"
    [[ -n "$REPOS" ]] || { echo "WT_REPOS required in non-interactive mode" >&2; exit 1; }
  else
    REPOS="$(ask 'Repos (csv)' 'repo-a,repo-b,repo-c')"
    [[ -n "$REPOS" ]] || { echo "repos required" >&2; exit 1; }
  fi

  # ----- AZURE PLACEHOLDER (development) -----------------------------------
  # At WORK, you can replace prompts / fetch story text via az boards here.
  # -------------------------------------------------------------------------

  IFS=',' read -ra LIST <<< "$REPOS"
  for repo in "${LIST[@]}"; do
    repo="$(echo "$repo" | xargs)"; [[ -n "$repo" ]] || continue
    REPO_ORDER+=("$repo")
    make_worktree "$repo" "$BRANCH" default || echo "WARNING: skipped ${repo}" >&2
  done
fi

# ===========================================================================
# REVIEW
# ===========================================================================
if [[ "$TYPE" == "review" ]]; then
  # az-watcher (or any caller) can hand over the real "<repo>:<branch>" list and
  # bypass the placeholder below entirely.
  if (( NONINTERACTIVE )) && [[ -n "${WT_BRANCHES_FILE:-}" ]]; then
    BRANCHES="$WT_BRANCHES_FILE"
    [[ -s "$BRANCHES" ]] || { echo "WT_BRANCHES_FILE is empty: ${BRANCHES}" >&2; exit 1; }
    echo "-> branches from WT_BRANCHES_FILE: ${BRANCHES}"
  else
  BRANCHES="${STORY_DIR}/branches-${ID}.txt"

  # ----- AZURE PLACEHOLDER (review) ----------------------------------------
  # At WORK, replace this block with a real az call that lists the branches
  # linked to the story, one "<repo>:<branch>" per line, into $BRANCHES.
  # Linked branches are vstfs:///Git/Ref artifact links in the work item's
  # relations, so expand relations and decode them. Sketch (needs jq):
  #
  #   az boards work-item show --id "$ID" --expand relations -o json \
  #     | jq -r '.relations[] | select(.rel=="ArtifactLink" and
  #              (.url|startswith("vstfs:///Git/Ref"))) | .url' \
  #     | while read -r u; do decode_vstfs_git_ref "$u"; done > "$BRANCHES"
  #
  cat > "$BRANCHES" <<EOF
repo-a:${BRANCH_PREFIX}/${ID}-${SLUG}
repo-b:bugfix/${ID}-example
repo-c:${BRANCH_PREFIX}/${ID}-${SLUG}
EOF
  echo "WARNING placeholder branches in ${BRANCHES} -- replace with az output at work."
  # -------------------------------------------------------------------------
  fi

  # One worktree per linked branch. Line format: <repo>:<branch>
  # NOTE: if one repo has several linked branches, give each a distinct path
  # (e.g. append the branch slug) so they don't collide on ${STORY_DIR}/${repo}.
  # Branches may contain ':' only in exotic names; split on the FIRST colon.
  # `|| [[ -n "$line" ]]` so a file whose LAST line has no trailing newline is
  # still processed: `read` returns non-zero at EOF, which silently dropped the
  # only line of a single-PR file (and the run then exited 0 having done nothing).
  ATTEMPTED=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                     # tolerate CRLF
    [[ -n "$line" && "${line:0:1}" != "#" ]] || continue
    repo="${line%%:*}"; branch="${line#*:}"
    repo="$(echo "$repo" | xargs)"; branch="$(echo "$branch" | xargs)"
    [[ -n "$repo" && -n "$branch" ]] || continue
    ATTEMPTED=$((ATTEMPTED + 1))
    REPO_ORDER+=("$repo")
    make_worktree "$repo" "$branch" remote || echo "WARNING: skipped ${repo}" >&2
  done < "$BRANCHES"
  # A branches file that yields nothing usable must not look like a clean run.
  if (( ATTEMPTED == 0 )); then
    echo "no usable '<repo>:<branch>' lines in ${BRANCHES}" >&2
    exit 1
  fi
fi

# One workspace for the whole story, opened once the repos are in place: its
# tabs live at the story root and the notes tab has to know which notes files
# exist. Also runs on a pure re-run (CREATED 0, SKIPPED > 0) so a story whose
# workspace was closed gets it back instead of silently staying invisible.
if (( CREATED + SKIPPED > 0 )); then
  init_story_workspace \
    || echo "WARNING: worktrees are ready, but the herdr workspace setup failed" >&2
fi

echo "OK ${TYPE} ready at ${STORY_DIR}"

# Any repo-level failure exits non-zero so automation notices - a partially
# successful run must never look like a clean one.
if (( FAILED > 0 )); then
  echo "-> ${FAILED} repo(s) failed - see the errors above"
  exit 1
fi

# Nothing created but something was already there -> "nothing to do" (exit 3),
# so automation can distinguish a no-op re-run from real work or a failure.
if (( CREATED == 0 && SKIPPED > 0 )); then
  echo "-> nothing to do: all requested worktrees already exist"
  exit 3
fi

exit 0
