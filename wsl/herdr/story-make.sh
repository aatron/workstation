#!/usr/bin/env bash
#
# story-make.sh
# Non-interactive development story scaffold: git worktrees + herdr layout +
# approve-first Claude handoff. Thin wrapper around make-worktree.sh development.
#
# usage:
#   story-make.sh <ado-id> <slug> [repo ...]
#   WT_STORY_ID=123 WT_STORY_SLUG=slug WT_STORY_REPOS=a,b story-make.sh
#
# Also accepts WT_ID / WT_SLUG / WT_REPOS (same as worktree-make.sh).
#
# Exit codes (same as worktree-make for the worktree phase):
#   0  created or ready (worktrees new or agent brief loaded)
#   1  usage error or worktree-make failed
#   3  all requested worktrees already existed
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAKE_WORKTREE="${STORY_MAKE_WORKTREE:-${HOME}/bin/make-worktree.sh}"
[[ -x "$MAKE_WORKTREE" ]] || MAKE_WORKTREE="${SCRIPT_DIR}/worktree-make.sh"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
need jq

sh_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

herdr_json() {
  local out errfile
  errfile="$(mktemp)"
  out="$(herdr "$@" 2>"$errfile")" || out=""
  rm -f "$errfile"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}

herdr_config_path() {
  printf '%s\n' "${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"
}

resolve_worktree_root() {
  local cfg dir
  cfg="$(herdr_config_path)"
  dir=""
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
  printf '%s\n' "$dir"
}

usage() {
  echo "usage: $0 <ado-id> <slug> [repo ...]" >&2
  echo "   or: WT_STORY_ID WT_STORY_SLUG WT_STORY_REPOS (csv) $0" >&2
  exit 1
}

find_story_workspace() {
  local json want ws label panes cwd
  want="$(readlink -f "$STORY_DIR" 2>/dev/null || printf '%s' "$STORY_DIR")"
  while [[ "$want" == *"//"* ]]; do want="${want//\/\//\/}"; done
  [[ "$want" == "/" ]] || want="${want%/}"

  json="$(herdr_json workspace list 2>/dev/null)" || return 1
  [[ -n "$json" ]] || return 1

  while IFS=$'\t' read -r ws label; do
    [[ -n "$ws" ]] || continue
    [[ "$label" == "${ID}-${SLUG}" ]] || continue
    panes="$(herdr_json pane list --workspace "$ws" 2>/dev/null)" || continue
    while read -r cwd; do
      cwd="$(readlink -f "$cwd" 2>/dev/null || printf '%s' "$cwd")"
      while [[ "$cwd" == *"//"* ]]; do cwd="${cwd//\/\//\/}"; done
      [[ "$cwd" == "/" ]] || cwd="${cwd%/}"
      if [[ "$cwd" == "$want" ]]; then
        printf '%s\n' "$ws"
        return 0
      fi
    done < <(jq -r '.result.panes[]?.cwd // empty' <<<"$panes")
  done < <(jq -r '.result.workspaces[]? | select(.worktree == null)
                  | [.workspace_id, (.label // "")] | @tsv' <<<"$json")
  return 1
}

seed_claude_handoff() {
  local ws pane tab_id prompt_line
  ws="$(find_story_workspace)" || true
  [[ -n "$ws" ]] || { echo "-> agent:  no herdr workspace at ${STORY_DIR} (open story row by hand)" >&2; return 0; }

  tab_id="$(herdr_json tab list --workspace "$ws" 2>/dev/null \
    | jq -r '.result.tabs[]? | select(.label=="claude") | .tab_id' | head -n1)" || tab_id=""
  [[ -n "$tab_id" ]] || { echo "-> agent:  no claude tab in workspace ${ws}" >&2; return 0; }

  pane="$(herdr_json pane list --workspace "$ws" 2>/dev/null \
    | jq -r --arg t "$tab_id" '.result.panes[]? | select(.tab_id==$t) | .pane_id' | head -n1)" || pane=""
  [[ -n "$pane" ]] || return 0

  local status=""
  status="$(herdr_json agent get "$pane" 2>/dev/null \
    | jq -r '.result.agent.agent_status // ""' 2>/dev/null)" || status=""
  if [[ -n "$status" && "$status" != "idle" && "$status" != "done" ]]; then
    echo "-> agent:  Claude pane busy (${status}); prompt file is ${PROMPT_FILE}"
    echo "           manual: cat $(printf '%q' "$PROMPT_FILE")"
    return 0
  fi

  prompt_line="Read ${PROMPT_FILE} in full and follow it exactly. Do NOT start implementation until a human has approved your plan in this thread."
  if herdr agent prompt "$pane" "$prompt_line" >/dev/null 2>&1; then
    sleep 0.5
    herdr agent send-keys "$pane" enter >/dev/null 2>&1 || true
    echo "-> agent:  submitted approve-first brief to Claude tab"
  else
    echo "-> agent:  could not prompt Claude pane; read: cat $(printf '%q' "$PROMPT_FILE")" >&2
  fi
}

ID="${1:-${WT_STORY_ID:-${WT_ID:-}}}"
SLUG="${2:-${WT_STORY_SLUG:-${WT_SLUG:-}}}"
shift 2 2>/dev/null || true

REPOS="${WT_STORY_REPOS:-${WT_REPOS:-}}"
if [[ $# -gt 0 ]]; then
  REPOS="$(IFS=,; echo "$*")"
fi

[[ -n "$ID" && -n "$SLUG" ]] || usage
[[ "$ID" =~ ^[0-9]+$ ]] || { echo "ado id must be numeric: $ID" >&2; exit 1; }
[[ -n "$REPOS" ]] || { echo "repos required (positional or WT_STORY_REPOS / WT_REPOS)" >&2; exit 1; }

WORKTREE_ROOT="$(resolve_worktree_root)"
STORY_DIR="${WORKTREE_ROOT}/development/${ID}-${SLUG}"
PROMPT_FILE="${STORY_DIR}/story-${ID}-prompt.md"
PROGRESS_FILE="${STORY_DIR}/story-${ID}-progress.md"
CONTEXT_FILE="${STORY_DIR}/story-${ID}-context.md"

mkdir -p "$STORY_DIR"

ADO_URL="${WT_STORY_URL:-}"
CONTEXT_BODY=""
if command -v az >/dev/null 2>&1; then
  WI="$(PYTHONIOENCODING=utf-8 PYTHONUTF8=1 az boards work-item show --id "$ID" -o json 2>/dev/null)" || WI=""
  if [[ -n "$WI" ]] && jq -e . >/dev/null 2>&1 <<<"$WI"; then
    title="$(jq -r '.fields["System.Title"] // ""' <<<"$WI")"
    wtype="$(jq -r '.fields["System.WorkItemType"] // ""' <<<"$WI")"
    state="$(jq -r '.fields["System.State"] // ""' <<<"$WI")"
    assigned="$(jq -r '.fields["System.AssignedTo"].displayName // .fields["System.AssignedTo"] // ""' <<<"$WI")"
    desc="$(jq -r '.fields["System.Description"] // ""' <<<"$WI")"
    [[ -z "$ADO_URL" ]] && ADO_URL="$(jq -r '._links.html.href // ""' <<<"$WI")"
    CONTEXT_BODY="# ADO ${ID} — ${SLUG}

- **Type:** ${wtype}
- **State:** ${state}
- **Assigned:** ${assigned}
- **Title:** ${title}

## Description

${desc}
"
  fi
fi
if [[ -z "$CONTEXT_BODY" ]]; then
  CONTEXT_BODY="# ADO ${ID} — ${SLUG}

(Azure context unavailable — open the work item in the browser.)
"
fi
printf '%s\n' "$CONTEXT_BODY" > "$CONTEXT_FILE"
echo "-> context: ${CONTEXT_FILE}"

if [[ ! -f "$PROGRESS_FILE" ]]; then
  cat > "$PROGRESS_FILE" <<EOF
# Progress — ${ID}-${SLUG}

| Step / stream | Status | Note | Updated (UTC) |
|---------------|--------|------|---------------|
EOF
  echo "-> progress: ${PROGRESS_FILE}"
fi

cat > "$PROMPT_FILE" <<EOF
# Story ${ID} — ${SLUG}

You are the lead agent for this Azure DevOps story. **Do not write or change production code until a human explicitly approves your plan in this chat.**

## Hard gate

1. **View the ADO story** — read \`${CONTEXT_FILE}\` and open the work item: ${ADO_URL:-"(set WT_STORY_URL or configure az for the link)"}
2. Inspect every repo under this story folder: \`${STORY_DIR}/<repo>/\`.
3. **Create a plan** in this terminal: scope, files, tests, risks, and parallel streams with **disjoint file ownership**.
4. Maintain a **progress log** at \`${PROGRESS_FILE}\` — update as streams move (\`pending\` / \`in_progress\` / \`done\` / \`blocked\` with UTC timestamps) so an interrupted run can resume.
5. **Stop and wait** for human approval. Do not start implementation until the human approves the plan here.

## After approval

- **Ponytail:** smallest complete change; keep the solution simple and idiomatic for this codebase.
- **Parallel work:** offload independent streams to parallel Sonnet subagents when possible; parent orchestrates only.
- **Commits:** commit throughout in coherent steps; **push at the end** of the story.
- **Bug fixes:** tests first — reproduce, then fix.
- **UI bug or feature:** capture screenshots at the start and end for the PR description.
- Stay in manual permission mode until the human widens it.

## Story link

${ADO_URL:-"(no URL — view work item ${ID} in Azure DevOps)"}
EOF
echo "-> prompt:  ${PROMPT_FILE}"

# Claude tab: manual mode, load brief from disk (no auto-implementation before human approval).
lit="$(sh_quote "$PROMPT_FILE")"
WT_CLAUDE_CMD="claude --permission-mode manual \"\$(cat ${lit})\""

export WT_ID="$ID" WT_SLUG="$SLUG" WT_REPOS="$REPOS" WT_CLAUDE_CMD
[[ -n "${WT_BRANCH:-}" ]] && export WT_BRANCH

echo "-> run:     ${MAKE_WORKTREE} development"
set +e
WT_OUT="$("$MAKE_WORKTREE" development 2>&1)"
WT_RC=$?
set -e
printf '%s\n' "$WT_OUT"

if (( WT_RC == 1 )); then
  exit 1
fi
if (( WT_RC != 0 && WT_RC != 3 )); then
  echo "unexpected exit from make-worktree.sh: ${WT_RC}" >&2
  exit 1
fi

CREATED=0
(( WT_RC == 0 )) && CREATED=1

# If the Claude tab already existed, worktree-make does not re-submit the command.
# Send a one-line handoff only (loads the brief; does not start implementation).
if [[ "${WT_SKIP_AGENT:-}" != "1" ]]; then
  seed_claude_handoff || true
fi

BRANCH="${WT_BRANCH:-feature/YOU/${ID}-${SLUG}}"
echo "STORY_MAKE rc=${WT_RC} story_dir=${STORY_DIR} branch=${BRANCH} created=${CREATED} prompt=${PROMPT_FILE}"
exit "$WT_RC"
