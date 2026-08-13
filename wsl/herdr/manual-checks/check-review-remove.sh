#!/usr/bin/env bash
# Checks for wsl/herdr/review-remove.sh.
#
# READ manual-checks/README.md BEFORE RUNNING. This is deliberately not in
# tests/ and deliberately not named test-*.sh.
#
# Azure DevOps is never contacted: both review-make.sh (used to build the
# fixtures) and review-remove.sh run with WT_REVIEW_AZ pointing at a stub `az`
# that serves canned JSON and logs every argument list. Every review-remove.sh
# invocation passes --yes; without it gum sits waiting for a keypress nobody is
# there to give and the suite hangs.
set -uo pipefail

MARKER="herdr-review-rm-checks"
BASE="${TMPDIR:-/tmp}/${MARKER}/$$"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKE="$HERE/review-make.sh"
REAL="$HERE/review-remove.sh"
PASS=0; FAIL=0; FAILED_NAMES=()
RUN=0

INDENT_CH=$'⠀ '
TREE_TEE=$'├─'
TREE_ELL=$'└─'

check() {
  if [[ "$2" == "0" ]]; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1")
    printf '  FAIL  %s :: %s\n' "$1" "$3"
  fi
}
ok() { [[ "$1" == "$2" ]] && echo 0 || echo 1; }
yes() { if "$@" >/dev/null 2>&1; then echo 0; else echo 1; fi; }
no()  { if "$@" >/dev/null 2>&1; then echo 1; else echo 0; fi; }

pkey() {
  local p="$1"
  while [[ "$p" == *"//"* ]]; do p="${p//\/\//\/}"; done
  [[ "$p" == "/" ]] || p="${p%/}"
  printf '%s\n' "$p"
}

close_workspaces() {
  local json ws panes
  json="$(herdr workspace list 2>/dev/null || true)"
  [[ -n "$json" ]] || return 0
  while read -r ws; do
    [[ -n "$ws" ]] || continue
    panes="$(herdr pane list --workspace "$ws" 2>/dev/null || true)"
    [[ -n "$panes" ]] || continue
    if jq -e --arg m "$MARKER" \
         '[.result.panes[]? | select((.cwd // "") | contains($m))] | length > 0' \
         >/dev/null 2>&1 <<<"$panes"; then
      herdr workspace close "$ws" >/dev/null 2>&1 || true
    fi
  done < <(jq -r '.result.workspaces[]?.workspace_id // empty' <<<"$json" 2>/dev/null)
}

write_stub_az() {
  cat > "$AZ" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AZ_LOG"
args=()
for a in "$@"; do [[ "$a" == -* ]] && break; args+=("$a"); done
path="${args[*]}"
case "$path" in
  'boards work-item show')
    id=""
    for ((i = 1; i <= $#; i++)); do
      [[ "${!i}" == "--id" ]] && { j=$((i + 1)); id="${!j}"; }
    done
    f="$AZ_DIR/wi-$id.json"
    [[ -f "$f" ]] || { echo "no such work item" >&2; exit 1; }
    cat "$f" ;;
  'repos pr show')
    id=""
    for ((i = 1; i <= $#; i++)); do
      [[ "${!i}" == "--id" ]] && { j=$((i + 1)); id="${!j}"; }
    done
    f="$AZ_DIR/pr-$id.json"
    [[ -f "$f" ]] || { echo "no such pr" >&2; exit 1; }
    cat "$f" ;;
  'devops invoke') echo '{"comments":[]}' ;;
  *) echo "stub az: unexpected command: $path" >&2; exit 9 ;;
esac
STUB
  chmod +x "$AZ"
}

reset_fixture() {
  close_workspaces
  RUN=$((RUN + 1))
  ROOT="$BASE/run$RUN"
  REPOS="$ROOT/repos"; TREES="$ROOT/worktrees"; CFG="$ROOT/config.toml"
  AZ_DIR="$ROOT/az"; AZ_LOG="$ROOT/az-calls.log"; AZ="$ROOT/az-stub.sh"
  REVIEW_ROOT="$TREES/review"
  mkdir -p "$REPOS" "$TREES" "$AZ_DIR"
  : > "$AZ_LOG"
  printf '[worktrees]\ndirectory = "%s"\n[ui.sidebar.spaces]\nrows = [["$tree", "state_icon", "workspace"]]\n' \
    "$TREES" > "$CFG"
  write_stub_az
}

new_repo_with_pr() {   # <dir-name> <branch>
  local name="$1" branch="$2" up work clone
  up="$ROOT/$name.git"; work="$ROOT/$name.work"; clone="$REPOS/$name"
  git init -q --bare "$up"
  git -C "$up" symbolic-ref HEAD refs/heads/main
  git init -q "$work"
  git -C "$work" config user.email t@t.t; git -C "$work" config user.name T
  echo base > "$work/f.txt"
  git -C "$work" add -A; git -C "$work" commit -qm c1
  git -C "$work" branch -M main
  git -C "$work" remote add origin "$up"
  git -C "$work" push -q -u origin main
  BASE_TIP="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" checkout -q -b "$branch"
  echo change > "$work/f.txt"
  git -C "$work" commit -qam 'the change'
  git -C "$work" push -q origin "$branch"
  BRANCH_TIP="$(git -C "$work" rev-parse HEAD)"
  git clone -q "$up" "$clone"
  git -C "$clone" config user.email t@t.t; git -C "$clone" config user.name T
  git -C "$clone" fetch -q origin
}

write_work_item() {
  local id="$1"; shift
  local rels="" l
  for l in "$@"; do
    [[ -n "$rels" ]] && rels+=","
    rels+="$(jq -cn --arg u "$l" '{rel:"ArtifactLink", url:$u}')"
  done
  cat > "$AZ_DIR/wi-$id.json" <<EOF
{ "id": $id,
  "fields": { "System.Title": "A change", "System.WorkItemType": "Bug",
              "System.State": "Active", "System.TeamProject": "My Project",
              "System.Description": "<div>text</div>" },
  "relations": [ $rels ] }
EOF
}

write_pr() {   # <prId> <repoName> <author> <srcBranch> <headSha> <baseSha> <status>
  cat > "$AZ_DIR/pr-$1.json" <<EOF
{ "pullRequestId": $1, "title": "PR $1", "status": "$7", "isDraft": false,
  "repository": { "name": "$2" },
  "createdBy": { "uniqueName": "$3@example.com", "displayName": "Dev $3" },
  "sourceRefName": "refs/heads/$4", "targetRefName": "refs/heads/main",
  "lastMergeSourceCommit": { "commitId": "$5" },
  "lastMergeTargetCommit": { "commitId": "$6" } }
EOF
}

set_pr_status() { local f="$AZ_DIR/pr-$1.json"; jq --arg s "$2" '.status = $s' "$f" > "$f.t" && mv "$f.t" "$f"; }
break_pr()      { rm -f "$AZ_DIR/pr-$1.json"; }

run_make() {
  local id="$1"; shift
  set +e
  OUT="$(env HERDR_CONFIG_PATH="$CFG" WT_REVIEW_AZ="$AZ" AZ_DIR="$AZ_DIR" AZ_LOG="$AZ_LOG" \
         WT_REVIEW_SRC_ROOT="$REPOS" "$@" bash "$MAKE" "$id" 2>&1)"
  RC=$?
  set -e
}

run_remove() {   # run_remove [args...]  -- always passes --yes
  set +e
  OUT="$(env HERDR_CONFIG_PATH="$CFG" WT_REVIEW_AZ="$AZ" AZ_DIR="$AZ_DIR" AZ_LOG="$AZ_LOG" \
         WT_REVIEW_SRC_ROOT="$REPOS" bash "$REAL" "$@" --yes 2>&1)"
  RC=$?
  set -e
}

WSJSON='{}'
snapshot() { WSJSON="$(herdr workspace list 2>/dev/null || echo '{}')"; }
ws_at() {
  local want ws panes cwd
  want="$(pkey "$1")"
  while read -r ws; do
    [[ -n "$ws" ]] || continue
    panes="$(herdr pane list --workspace "$ws" 2>/dev/null || true)"
    [[ -n "$panes" ]] || continue
    while read -r cwd; do
      [[ "$(pkey "$cwd")" == "$want" ]] && { printf '%s\n' "$ws"; return 0; }
    done < <(jq -r '.result.panes[]?.cwd // empty' <<<"$panes" 2>/dev/null)
  done < <(jq -r '.result.workspaces[]? | select(.worktree == null) | .workspace_id' \
             <<<"$WSJSON" 2>/dev/null)
}
ws_tree() { jq -r --arg w "$1" '.result.workspaces[]? | select(.workspace_id==$w) | .tokens.tree // ""' <<<"$WSJSON" 2>/dev/null | head -n1; }

echo
echo '================ review-remove.sh checks ================'

# ---------------------------------------------------------------------------
echo
echo '1. the read-only az guard, and completed is the only finished status'
reset_fixture
GTMP="$(mktemp -d)"
sed -n '/^AZ_READ_ONLY=(/,/^)$/p' "$REAL" > "$GTMP/g.sh"
sed -n '/^az_command_path()/,/^}/p' "$REAL" >> "$GTMP/g.sh"
sed -n '/^az_read_only()/,/^}/p' "$REAL" >> "$GTMP/g.sh"
# shellcheck disable=SC1090
source "$GTMP/g.sh"
check 'allows repos pr show'            "$(yes az_read_only repos pr show --id 1)" 'refused a read'
check 'refuses boards work-item update' "$(no az_read_only boards work-item update --id 1)" 'ALLOWED A WRITE'
check 'refuses repos pr set-vote'       "$(no az_read_only repos pr set-vote --id 1)" 'ALLOWED A WRITE'
check 'refuses devops invoke POST'      "$(no az_read_only devops invoke --http-method POST)" 'ALLOWED A WRITE'
check 'the default finished set is completed only' \
  "$(yes grep -qE '^DONE_STATUS=\(completed\)$' "$REAL")" 'default changed'

# ---------------------------------------------------------------------------
echo
echo '2. a completed PR is removed for real; the shared Review row survives'
reset_fixture
new_repo_with_pr 'repo_a' 'feature/x/24001-a'
write_work_item 24001 "vstfs:///Git/PullRequestId/p%2Fr%2F8001"
write_pr 8001 'repo_a' 'ann.b' 'feature/x/24001-a' "$BRANCH_TIP" "$BASE_TIP" active
run_make 24001
ITEM="$REVIEW_ROOT/24001"; WT="$ITEM/ann.b-repo_a"
check 'fixture built' "$(ok "$RC" 0)" "rc=$RC
$OUT"
snapshot; ROOT_WS="$(ws_at "$REVIEW_ROOT")"; ITEM_WS="$(ws_at "$ITEM")"; PR_WS="$(ws_at "$WT")"
echo 'the owning clone is read out of the worktree, not guessed'
OWNTMP="$(mktemp -d)"
sed -n '/^worktree_owner()/,/^}/p' "$REAL" > "$OWNTMP/o.sh"
# shellcheck disable=SC1090
source "$OWNTMP/o.sh"
check 'worktree_owner names the real clone' \
  "$(ok "$(worktree_owner "$WT")" "$REPOS/repo_a")" "got=$(worktree_owner "$WT")"

echo 'still active -> the whole review is held'
run_remove 24001
check 'exit 3 (nothing ready)' "$(ok "$RC" 3)" "rc=$RC
$OUT"
check 'the checkout survives' "$([[ -e "$WT/.git" ]] && echo 0 || echo 1)" 'it was removed!'

echo 'completed, but --dry-run changes nothing'
set_pr_status 8001 completed
run_remove 24001 --dry-run
check 'dry run exits 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'says what it would close' "$(yes grep -qF 'would close herdr row' <<<"$OUT")" "$OUT"
check 'the checkout is still there' "$([[ -e "$WT/.git" ]] && echo 0 || echo 1)" 'dry run deleted it'
check 'the folder is still there' "$([[ -d "$ITEM" ]] && echo 0 || echo 1)" 'dry run deleted it'

echo 'and now for real'
run_remove 24001
snapshot
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'the review folder is gone' "$([[ -e "$ITEM" ]] && echo 1 || echo 0)" 'folder survived'
check 'git no longer lists the worktree' \
  "$(git -C "$REPOS/repo_a" worktree list --porcelain 2>/dev/null | grep -qF "$WT" && echo 1 || echo 0)" \
  'still registered'
check 'the review row is closed' "$([[ -z "$(ws_at "$ITEM")" ]] && echo 0 || echo 1)" 'row survived'
check 'the PR row is closed' "$([[ -z "$(ws_at "$WT")" ]] && echo 0 || echo 1)" 'row survived'
check 'the shared Review row is LEFT OPEN' \
  "$(ok "$(ws_at "$REVIEW_ROOT")" "$ROOT_WS")" 'it closed the shared root'
check 'the clone itself is untouched' \
  "$([[ -d "$REPOS/repo_a/.git" ]] && echo 0 || echo 1)" 'the clone was damaged'
check 'no branch was created or deleted (the checkout was detached)' \
  "$(ok "$(git -C "$REPOS/repo_a" branch --list --format='%(refname:short)' | tr '\n' ' ' | xargs)" 'main')" \
  "branches=$(git -C "$REPOS/repo_a" branch --list | tr '\n' ' ')"

# ---------------------------------------------------------------------------
echo
echo '3. one PR still active holds the whole review, including the finished half'
reset_fixture
new_repo_with_pr 'repo_p' 'feature/x/24002-p'; P_TIP="$BRANCH_TIP"; P_BASE="$BASE_TIP"
new_repo_with_pr 'repo_q' 'feature/x/24002-q'; Q_TIP="$BRANCH_TIP"; Q_BASE="$BASE_TIP"
write_work_item 24002 "vstfs:///Git/PullRequestId/p%2Fr%2F8002" "vstfs:///Git/PullRequestId/p%2Fr%2F8003"
write_pr 8002 'repo_p' 'ann.b' 'feature/x/24002-p' "$P_TIP" "$P_BASE" active
write_pr 8003 'repo_q' 'ann.b' 'feature/x/24002-q' "$Q_TIP" "$Q_BASE" active
run_make 24002
set_pr_status 8002 completed
run_remove 24002
check 'exit 3' "$(ok "$RC" 3)" "rc=$RC
$OUT"
check 'says how many are finished' "$(yes grep -qF 'holding: 1/2 finished' <<<"$OUT")" "$OUT"
check 'the finished half is kept too' \
  "$([[ -e "$REVIEW_ROOT/24002/ann.b-repo_p/.git" ]] && echo 0 || echo 1)" 'half-removed!'

echo
echo '3b. a PR whose status cannot be read is NOT treated as finished'
set_pr_status 8003 completed
break_pr 8002
run_remove 24002
check 'exit 3' "$(ok "$RC" 3)" "rc=$RC
$OUT"
check 'reports it as unreadable' "$(yes grep -qF 'unreadable' <<<"$OUT")" "$OUT"
check 'the review survives' "$([[ -d "$REVIEW_ROOT/24002" ]] && echo 0 || echo 1)" 'deleted on an unreadable status'

# ---------------------------------------------------------------------------
echo
echo '4. abandoned is ignored by default, honoured with --include-abandoned'
reset_fixture
new_repo_with_pr 'repo_z' 'feature/x/24003-z'
write_work_item 24003 "vstfs:///Git/PullRequestId/p%2Fr%2F8010"
write_pr 8010 'repo_z' 'ann.b' 'feature/x/24003-z' "$BRANCH_TIP" "$BASE_TIP" active
run_make 24003
set_pr_status 8010 abandoned
run_remove 24003
check 'exit 3 by default' "$(ok "$RC" 3)" "rc=$RC
$OUT"
check 'the review survives' "$([[ -d "$REVIEW_ROOT/24003" ]] && echo 0 || echo 1)" 'removed an abandoned PR by default'
run_remove 24003 --include-abandoned
check 'exit 0 with --include-abandoned' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'and it is gone' "$([[ -e "$REVIEW_ROOT/24003" ]] && echo 1 || echo 0)" 'still there'

# ---------------------------------------------------------------------------
echo
echo '5. uncommitted changes hold a review back (exit 5); --force-dirty overrides'
reset_fixture
new_repo_with_pr 'repo_d' 'feature/x/24004-d'
write_work_item 24004 "vstfs:///Git/PullRequestId/p%2Fr%2F8020"
write_pr 8020 'repo_d' 'ann.b' 'feature/x/24004-d' "$BRANCH_TIP" "$BASE_TIP" completed
run_make 24004
echo 'work in progress' >> "$REVIEW_ROOT/24004/ann.b-repo_d/f.txt"
run_remove 24004
check 'exit 5' "$(ok "$RC" 5)" "rc=$RC
$OUT"
check 'names the dirty checkout' "$(yes grep -qF 'HELD BACK: uncommitted changes' <<<"$OUT")" "$OUT"
check 'the work survives' \
  "$(yes grep -qF 'work in progress' "$REVIEW_ROOT/24004/ann.b-repo_d/f.txt")" 'DELETED USER WORK'
run_remove 24004 --force-dirty
check 'exit 0 with --force-dirty' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'and says it discarded them' "$(yes grep -qF 'force-dirty' <<<"$OUT")" "$OUT"
check 'the review is gone' "$([[ -e "$REVIEW_ROOT/24004" ]] && echo 1 || echo 0)" 'still there'

# ---------------------------------------------------------------------------
echo
echo '6. notes: content archived, empty not, --discard-notes opts out'
reset_fixture
new_repo_with_pr 'repo_n' 'feature/x/24005-n'
write_work_item 24005 "vstfs:///Git/PullRequestId/p%2Fr%2F8030"
write_pr 8030 'repo_n' 'ann.b' 'feature/x/24005-n' "$BRANCH_TIP" "$BASE_TIP" completed
run_make 24005
echo 'my findings' > "$REVIEW_ROOT/24005/review-24005-notes.txt"
: > "$REVIEW_ROOT/24005/review-24005-ann.b-repo_n-notes.txt"
run_remove 24005
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'the notes with content were archived' \
  "$(yes grep -qF 'my findings' "$REVIEW_ROOT/_notes/review-24005-notes.txt")" \
  "archive: $(ls "$REVIEW_ROOT/_notes" 2>/dev/null | tr '\n' ' ')"
check 'the empty notes file was not archived' \
  "$([[ -e "$REVIEW_ROOT/_notes/review-24005-ann.b-repo_n-notes.txt" ]] && echo 1 || echo 0)" \
  'archived an empty file'

echo
echo '6b. --discard-notes deletes them instead'
reset_fixture
new_repo_with_pr 'repo_m' 'feature/x/24006-m'
write_work_item 24006 "vstfs:///Git/PullRequestId/p%2Fr%2F8040"
write_pr 8040 'repo_m' 'ann.b' 'feature/x/24006-m' "$BRANCH_TIP" "$BASE_TIP" completed
run_make 24006
echo 'throwaway' > "$REVIEW_ROOT/24006/review-24006-notes.txt"
run_remove 24006 --discard-notes
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'nothing was archived' "$([[ -e "$REVIEW_ROOT/_notes" ]] && echo 1 || echo 0)" 'archive created anyway'
check 'said it discarded them' "$(yes grep -qF 'discarding notes' <<<"$OUT")" "$OUT"

# ---------------------------------------------------------------------------
echo
echo '7. scanning them all removes only the finished one, and redraws the rest'
reset_fixture
new_repo_with_pr 'repo_1' 'feature/x/24010-a'; T1="$BRANCH_TIP"; B1="$BASE_TIP"
new_repo_with_pr 'repo_2' 'feature/x/24011-b'; T2="$BRANCH_TIP"; B2="$BASE_TIP"
new_repo_with_pr 'repo_3' 'feature/x/24012-c'; T3="$BRANCH_TIP"; B3="$BASE_TIP"
write_work_item 24010 "vstfs:///Git/PullRequestId/p%2Fr%2F8050"
write_pr 8050 'repo_1' 'ann.b' 'feature/x/24010-a' "$T1" "$B1" completed
write_work_item 24011 "vstfs:///Git/PullRequestId/p%2Fr%2F8051"
write_pr 8051 'repo_2' 'ann.b' 'feature/x/24011-b' "$T2" "$B2" active
write_work_item 24012 "vstfs:///Git/PullRequestId/p%2Fr%2F8052"
write_pr 8052 'repo_3' 'ann.b' 'feature/x/24012-c' "$T3" "$B3" active
run_make 24010; run_make 24011; run_make 24012
run_remove
snapshot
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'examined all three' "$(yes grep -qF 'examined 3' <<<"$OUT")" "$OUT"
check 'only the finished one is gone' \
  "$([[ ! -e "$REVIEW_ROOT/24010" && -d "$REVIEW_ROOT/24011" && -d "$REVIEW_ROOT/24012" ]] && echo 0 || echo 1)" \
  "24010=$([[ -e "$REVIEW_ROOT/24010" ]] && echo present || echo gone)"
I11="$(ws_at "$REVIEW_ROOT/24011")"; I12="$(ws_at "$REVIEW_ROOT/24012")"
check 'the survivors got their connectors redrawn: first keeps the tee' \
  "$(ok "$(ws_tree "$I11")" "${INDENT_CH}${TREE_TEE}")" "token=[$(ws_tree "$I11")]"
check 'and the new last one takes the corner' \
  "$(ok "$(ws_tree "$I12")" "${INDENT_CH}${TREE_ELL}")" "token=[$(ws_tree "$I12")]"

# ---------------------------------------------------------------------------
echo
echo '8. an unreadable review is left alone; a missing index is re-derived'
reset_fixture
new_repo_with_pr 'repo_i' 'feature/x/24020-i'
write_work_item 24020 "vstfs:///Git/PullRequestId/p%2Fr%2F8060"
write_pr 8060 'repo_i' 'ann.b' 'feature/x/24020-i' "$BRANCH_TIP" "$BASE_TIP" completed
run_make 24020
rm -f "$REVIEW_ROOT/24020/review-24020-prs.json"
rm -f "$AZ_DIR/wi-24020.json"
run_remove 24020
check 'exit 3 when neither the index nor the work item can be read' "$(ok "$RC" 3)" "rc=$RC
$OUT"
check 'says it cannot tell' "$(yes grep -qF 'cannot tell which PRs' <<<"$OUT")" "$OUT"
check 'the review survives' "$([[ -d "$REVIEW_ROOT/24020" ]] && echo 0 || echo 1)" 'deleted a review it could not identify'

echo
echo '8b. with only the index missing it re-derives from Azure DevOps'
write_work_item 24020 "vstfs:///Git/PullRequestId/p%2Fr%2F8060"
run_remove 24020
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'it said the PR list came from azure' "$(yes grep -qF 'from azure' <<<"$OUT")" "$OUT"
check 'and the review is gone' "$([[ -e "$REVIEW_ROOT/24020" ]] && echo 1 || echo 0)" 'still there'

# ---------------------------------------------------------------------------
echo
echo '9. everything the stub was actually asked to run is a read'
BAD=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  # shellcheck disable=SC2086
  az_read_only $line || { BAD=$((BAD + 1)); echo "      WRITE ATTEMPT: az $line"; }
done < <(cat "$BASE"/run*/az-calls.log 2>/dev/null)
TOTAL="$(cat "$BASE"/run*/az-calls.log 2>/dev/null | grep -c . || echo 0)"
check "all ${TOTAL} recorded az calls pass the read-only guard" "$(ok "$BAD" 0)" \
  "${BAD} call(s) would have written"

# ---------------------------------------------------------------------------
for _round in 1 2 3 4 5 6; do
  close_workspaces
  while IFS= read -r g; do
    git -C "$(dirname "$g")" worktree prune >/dev/null 2>&1 || true
  done < <(find "$BASE" -maxdepth 4 -name '.git' -type d -printf '%h\n' 2>/dev/null)
  rm -rf "$BASE" 2>/dev/null || true
  [[ ! -e "$BASE" ]] && break
  sleep 2
done
rm -rf "${GTMP:-}" "${OWNTMP:-}" 2>/dev/null || true
[[ -e "$BASE" ]] && echo "note: could not fully delete ${BASE}" >&2

echo
echo '================ summary ================'
echo "PASS: $PASS   FAIL: $FAIL"
if (( FAIL > 0 )); then
  printf 'failed checks:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
exit 0
