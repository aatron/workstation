#!/usr/bin/env bash
#
# check-story-reap.sh — OPT-IN checks for wsl/herdr/story-reap.sh
#
# NOT A TEST FILE. Deliberately not named test-*.sh and deliberately not in
# tests/, so that nothing sweeping this repo for tests picks it up. Run it by
# hand, on purpose:
#
#     bash check-story-reap.sh
#
# See README.md in this folder for why.
#
# WHAT IT TOUCHES
#   Azure DevOps  nothing. story-reap.sh runs against a STUB az (WT_REVIEW_AZ)
#                 serving canned JSON from disk, which logs every argument list it
#                 is handed; a check reads that log back and fails if anything but
#                 a read was issued. No network call, no credential use.
#   git           throwaway repos under /tmp/herdr-story-reap-checks/<pid>/.
#   herdr         nothing. worktree-remove.sh is replaced by a STUB
#                 (WT_REMOVE_SCRIPT) that only records the story id it was handed,
#                 so no workspace is closed and no checkout is deleted. These
#                 checks are about which stories story-reap.sh DECIDES to reap;
#                 the removal itself is worktree-remove.sh's own business.
#   your files    none. The lock file is redirected into the fixture
#                 (STORY_REAP_LOCK) so a real cron run cannot make a check exit
#                 early, and vice versa.
#
# THE DECISION UNDER TEST
#   Reap a story only when it has AT LEAST ONE pull request and EVERY one of them
#   is closed. The no-PR case is the one that matters most: a brand-new story
#   looks exactly like a finished one to any test that only asks "is anything
#   still open?", and reaping it would delete work someone started minutes ago.
#
set -uo pipefail

MARKER='herdr-story-reap-checks'
BASE="/tmp/${MARKER}/$$"
HERDR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAP="${HERDR_DIR}/story-reap.sh"

RUN=0
PASS=0
FAIL=0
declare -a FAILED_NAMES=()

[[ -f "$REAP" ]] || { echo "cannot find $REAP" >&2; exit 1; }

check() {
  local name="$1" ok="$2" detail="${3:-}"
  if [[ "$ok" == "1" ]]; then
    PASS=$(( PASS + 1 ))
    printf '  \033[32mPASS\033[0m  %s\n' "$name"
  else
    FAIL=$(( FAIL + 1 ))
    FAILED_NAMES+=("$name")
    printf '  \033[31mFAIL\033[0m  %s  :: %s\n' "$name" "$detail"
  fi
}

# ===========================================================================
# Fixture
# ===========================================================================
write_stub_az() {
  cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
# STUB az — test double for check-story-reap.sh. Canned JSON only, no network.
dir="$(dirname "$0")"
printf '%s\n' "$*" >> "${dir}/az-calls.log"

emit() {
  [[ -f "${dir}/$1" ]] || exit 1
  cat "${dir}/$1"
  exit 0
}
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]\+/_/g; s/^_//; s/_$//'; }

joined="$*"
if [[ "$joined" =~ ^boards\ work-item\ show\ --id\ ([0-9]+) ]]; then
  emit "wi-${BASH_REMATCH[1]}.json"
fi
if [[ "$joined" =~ ^repos\ pr\ show\ --id\ ([0-9]+) ]]; then
  emit "pr-${BASH_REMATCH[1]}.json"
fi
if [[ "$joined" =~ ^repos\ pr\ list\ --repository\ (.+)\ --source-branch\ ([^ ]+) ]]; then
  emit "prlist-$(slug "${BASH_REMATCH[1]}")-$(slug "${BASH_REMATCH[2]}").json"
fi
echo "stub az: unhandled command: $joined" >&2
exit 1
EOS
  chmod +x "$STUB"
}

write_stub_remove() {
  cat > "$REMOVE_STUB" <<'EOS'
#!/usr/bin/env bash
# STUB worktree-remove.sh — test double for check-story-reap.sh.
dir="$(dirname "$0")"
echo "id=${WT_ID:-} yes=${WT_ASSUME_YES:-} skipdirty=${WT_SKIP_DIRTY:-}" >> "${dir}/remove-calls.log"
exit 0
EOS
  chmod +x "$REMOVE_STUB"
}

reset_fixture() {
  RUN=$(( RUN + 1 ))
  ROOT="${BASE}/run${RUN}"
  REPOS="${ROOT}/repos"
  TREES="${ROOT}/worktrees"
  DEV="${TREES}/development"
  CFG="${ROOT}/config.toml"
  AZDIR="${ROOT}/az"
  STUB="${AZDIR}/az"
  AZLOG="${AZDIR}/az-calls.log"
  REMOVE_STUB="${AZDIR}/remove.sh"
  REMOVE_LOG="${AZDIR}/remove-calls.log"
  mkdir -p "$ROOT" "$REPOS" "$TREES" "$DEV" "$AZDIR"
  printf '[worktrees]\ndirectory = "%s"\n' "$TREES" > "$CFG"
  write_stub_az
  write_stub_remove
}

# A primary clone with an Azure-shaped origin URL, plus one commit on main.
new_clone() {
  local azName="$1"
  local dir="${REPOS}/${azName// /_}"
  mkdir -p "$dir"
  git -C "$dir" init -q --initial-branch=main
  git -C "$dir" config user.email 'check@example.invalid'
  git -C "$dir" config user.name 'Check'
  git -C "$dir" config commit.gpgsign false
  echo base > "${dir}/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -qm base
  git -C "$dir" remote add origin "https://dev.azure.com/org/proj/_git/${azName// /%20}"
  printf '%s' "$dir"
}

new_story_checkout() {
  local storyName="$1" azName="$2" branch="$3" clone="$4"
  local storyDir="${DEV}/${storyName}"
  mkdir -p "$storyDir"
  local wt="${storyDir}/${azName// /_}"
  git -C "$clone" branch "$branch" main 2>/dev/null
  git -C "$clone" worktree add -q "$wt" "$branch"
  printf '%s' "$wt"
}

add_commit() {
  local wt="$1" text="$2"
  echo "$text" > "${wt}/work.txt"
  git -C "$wt" add -A
  git -C "$wt" commit -qm "$text"
  git -C "$wt" rev-parse HEAD
}

set_origin_ref() {
  git -C "$1" update-ref "refs/remotes/origin/$2" "$3"
}

write_pr() {
  local prId="$1" status="$2" azRepo="$3" branch="$4" src="$5"
  jq -nc --arg id "$prId" --arg st "$status" --arg r "$azRepo" \
        --arg b "refs/heads/$branch" --arg c "$src" \
    '{pullRequestId: ($id|tonumber), status: $st, repository: {name: $r},
      sourceRefName: $b, lastMergeSourceCommit: {commitId: $c}}' \
    | tee "${AZDIR}/pr-${prId}.json"
}

slugify() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]\+/_/g; s/^_//; s/_$//'; }

write_pr_list() {
  local azRepo="$1" branch="$2"; shift 2
  local name="prlist-$(slugify "$azRepo")-$(slugify "$branch").json"
  if (( $# == 0 )); then
    echo '[]' > "${AZDIR}/${name}"
  else
    printf '%s\n' "$@" | jq -sc '.' > "${AZDIR}/${name}"
  fi
}

write_work_item() {
  local id="$1"; shift
  local rels='[]'
  if (( $# > 0 )); then
    rels="$(printf '%s\n' "$@" | jq -R . | jq -sc \
      '[ .[] | {rel: "ArtifactLink", url: ("vstfs:///Git/PullRequestId/proj%2Frepo%2F" + .)} ]')"
  fi
  jq -nc --arg id "$id" --argjson r "$rels" '{id: ($id|tonumber), relations: $r}' \
    > "${AZDIR}/wi-${id}.json"
}

REAP_OUT=''
REAP_CODE=0
invoke_reap() {
  set +e
  REAP_OUT="$(HERDR_CONFIG_PATH="$CFG" WT_REVIEW_AZ="$STUB" WT_REMOVE_SCRIPT="$REMOVE_STUB" \
    STORY_REAP_LOCK="${ROOT}/story-reap.lock" \
    bash "$REAP" "$@" 2>&1)"
  REAP_CODE=$?
  set -e
}

removed_ids() {
  [[ -f "$REMOVE_LOG" ]] || return 0
  sed -n 's/^id=\([0-9]\+\).*/\1/p' "$REMOVE_LOG"
}
removed_count() { removed_ids | grep -c . || true; }
removed_has() { removed_ids | grep -qx "$1" && echo 1 || echo 0; }
bool() { if [[ -n "$1" ]] && eval "$1"; then echo 1; else echo 0; fi; }

# ===========================================================================
# Checks
# ===========================================================================
echo
echo "=== check-story-reap.sh (fixtures under ${BASE}) ==="

# ---------------------------------------------------------------------------
echo
echo '-- a story with NO pull requests is never reaped'
reset_fixture
clone="$(new_clone 'Alpha Repo')"
wt="$(new_story_checkout '1001-no-prs' 'Alpha Repo' '1001-no-prs' "$clone")"
set_origin_ref "$wt" '1001-no-prs' "$(git -C "$wt" rev-parse HEAD)"
write_work_item 1001
write_pr_list 'Alpha Repo' '1001-no-prs'
invoke_reap --yes
check 'no PRs: exit 3 (nothing to do)' "$([[ $REAP_CODE -eq 3 ]] && echo 1 || echo 0)" "exit $REAP_CODE
$REAP_OUT"
check 'no PRs: worktree-remove never called' "$([[ $(removed_count) -eq 0 ]] && echo 1 || echo 0)" "$(removed_ids | tr '\n' ',')"
check 'no PRs: says so' "$(grep -q 'no pull requests found' <<<"$REAP_OUT" && echo 1 || echo 0)" "$REAP_OUT"

# ---------------------------------------------------------------------------
echo
echo '-- one active PR holds the story'
reset_fixture
clone="$(new_clone 'Alpha Repo')"
wt="$(new_story_checkout '1002-active' 'Alpha Repo' '1002-active' "$clone")"
head="$(git -C "$wt" rev-parse HEAD)"
set_origin_ref "$wt" '1002-active' "$head"
pr="$(write_pr 5001 active 'Alpha Repo' '1002-active' "$head")"
write_pr_list 'Alpha Repo' '1002-active' "$pr"
write_work_item 1002 5001
invoke_reap --yes
check 'active PR: exit 3' "$([[ $REAP_CODE -eq 3 ]] && echo 1 || echo 0)" "exit $REAP_CODE
$REAP_OUT"
check 'active PR: not reaped' "$([[ $(removed_count) -eq 0 ]] && echo 1 || echo 0)" "$(removed_ids | tr '\n' ',')"

# ---------------------------------------------------------------------------
echo
echo '-- every PR completed: reaped'
reset_fixture
clone="$(new_clone 'Alpha Repo')"
wt="$(new_story_checkout '1003-done' 'Alpha Repo' '1003-done' "$clone")"
head="$(git -C "$wt" rev-parse HEAD)"
set_origin_ref "$wt" '1003-done' "$head"
pr="$(write_pr 5002 completed 'Alpha Repo' '1003-done' "$head")"
write_pr_list 'Alpha Repo' '1003-done' "$pr"
write_work_item 1003 5002
invoke_reap --yes
check 'completed: exit 0' "$([[ $REAP_CODE -eq 0 ]] && echo 1 || echo 0)" "exit $REAP_CODE
$REAP_OUT"
check 'completed: reaped 1003' "$(removed_has 1003)" "$(removed_ids | tr '\n' ',')"
check 'completed: WT_SKIP_DIRTY=1 passed' \
  "$(grep -q 'skipdirty=1' "$REMOVE_LOG" && echo 1 || echo 0)" "$(cat "$REMOVE_LOG")"

# ---------------------------------------------------------------------------
echo
echo '-- mixed: one completed, one active, in two repos -> held'
reset_fixture
cloneA="$(new_clone 'Alpha Repo')"
cloneB="$(new_clone 'Beta Repo')"
wtA="$(new_story_checkout '1004-mixed' 'Alpha Repo' '1004-mixed' "$cloneA")"
wtB="$(new_story_checkout '1004-mixed' 'Beta Repo' '1004-mixed' "$cloneB")"
headA="$(git -C "$wtA" rev-parse HEAD)"
headB="$(git -C "$wtB" rev-parse HEAD)"
set_origin_ref "$wtA" '1004-mixed' "$headA"
set_origin_ref "$wtB" '1004-mixed' "$headB"
prA="$(write_pr 5003 completed 'Alpha Repo' '1004-mixed' "$headA")"
prB="$(write_pr 5004 active 'Beta Repo' '1004-mixed' "$headB")"
write_pr_list 'Alpha Repo' '1004-mixed' "$prA"
write_pr_list 'Beta Repo' '1004-mixed' "$prB"
write_work_item 1004 5003 5004
invoke_reap --yes
check 'mixed: exit 3' "$([[ $REAP_CODE -eq 3 ]] && echo 1 || echo 0)" "exit $REAP_CODE
$REAP_OUT"
check 'mixed: not reaped' "$([[ $(removed_count) -eq 0 ]] && echo 1 || echo 0)" "$(removed_ids | tr '\n' ',')"
check 'mixed: names the open PR' "$(grep -q 'still open: 5004' <<<"$REAP_OUT" && echo 1 || echo 0)" "$REAP_OUT"

# ---------------------------------------------------------------------------
echo
echo '-- abandoned counts as closed by default, not with --completed-only'
reset_fixture
clone="$(new_clone 'Alpha Repo')"
wt="$(new_story_checkout '1005-aband' 'Alpha Repo' '1005-aband' "$clone")"
head="$(git -C "$wt" rev-parse HEAD)"
set_origin_ref "$wt" '1005-aband' "$head"
pr="$(write_pr 5005 abandoned 'Alpha Repo' '1005-aband' "$head")"
write_pr_list 'Alpha Repo' '1005-aband' "$pr"
write_work_item 1005 5005
invoke_reap --yes
check 'abandoned: reaped by default' "$(removed_has 1005)" "exit $REAP_CODE
$REAP_OUT"
rm -f "$REMOVE_LOG"
invoke_reap --yes --completed-only
check '--completed-only: abandoned holds it' "$([[ $(removed_count) -eq 0 ]] && echo 1 || echo 0)" "exit $REAP_CODE
$REAP_OUT"

# ---------------------------------------------------------------------------
echo
echo '-- an unreadable work item holds the story (exit 5), it does not read as "no PRs"'
reset_fixture
clone="$(new_clone 'Alpha Repo')"
wt="$(new_story_checkout '1006-unreadable' 'Alpha Repo' '1006-unreadable' "$clone")"
set_origin_ref "$wt" '1006-unreadable' "$(git -C "$wt" rev-parse HEAD)"
write_pr_list 'Alpha Repo' '1006-unreadable'
# No wi-1006.json on disk -> the stub exits 1, standing in for an expired token.
invoke_reap --yes
check 'unreadable work item: exit 5 (held)' "$([[ $REAP_CODE -eq 5 ]] && echo 1 || echo 0)" "exit $REAP_CODE
$REAP_OUT"
check 'unreadable work item: not reaped' "$([[ $(removed_count) -eq 0 ]] && echo 1 || echo 0)" "$(removed_ids | tr '\n' ',')"
check 'unreadable work item: says why' "$(grep -q 'UNREADABLE' <<<"$REAP_OUT" && echo 1 || echo 0)" "$REAP_OUT"

# ---------------------------------------------------------------------------
echo
echo '-- uncommitted changes hold the story'
reset_fixture
clone="$(new_clone 'Alpha Repo')"
wt="$(new_story_checkout '1007-dirty' 'Alpha Repo' '1007-dirty' "$clone")"
head="$(git -C "$wt" rev-parse HEAD)"
set_origin_ref "$wt" '1007-dirty' "$head"
pr="$(write_pr 5007 completed 'Alpha Repo' '1007-dirty' "$head")"
write_pr_list 'Alpha Repo' '1007-dirty' "$pr"
write_work_item 1007 5007
echo unsaved > "${wt}/scratch.txt"
invoke_reap --yes
check 'dirty: exit 5 (held)' "$([[ $REAP_CODE -eq 5 ]] && echo 1 || echo 0)" "exit $REAP_CODE
$REAP_OUT"
check 'dirty: not reaped' "$([[ $(removed_count) -eq 0 ]] && echo 1 || echo 0)" "$(removed_ids | tr '\n' ',')"
invoke_reap --yes --force-dirty
check '--force-dirty: reaped anyway' "$(removed_has 1007)" "exit $REAP_CODE
$REAP_OUT"

# ---------------------------------------------------------------------------
echo
echo '-- commits the PR never saw hold the story'
reset_fixture
clone="$(new_clone 'Alpha Repo')"
wt="$(new_story_checkout '1008-ahead' 'Alpha Repo' '1008-ahead' "$clone")"
prSha="$(add_commit "$wt" 'what the PR saw')"
add_commit "$wt" 'made after the PR closed' >/dev/null
# origin no longer carries the branch (deleted on completion), and the PR's
# high-water mark is the EARLIER commit.
pr="$(write_pr 5008 completed 'Alpha Repo' '1008-ahead' "$prSha")"
write_pr_list 'Alpha Repo' '1008-ahead' "$pr"
write_work_item 1008 5008
invoke_reap --yes
check 'ahead of PR: exit 5 (held)' "$([[ $REAP_CODE -eq 5 ]] && echo 1 || echo 0)" "exit $REAP_CODE
$REAP_OUT"
check 'ahead of PR: not reaped' "$([[ $(removed_count) -eq 0 ]] && echo 1 || echo 0)" "$(removed_ids | tr '\n' ',')"
check 'ahead of PR: says why' \
  "$(grep -qE 'never saw|not on origin' <<<"$REAP_OUT" && echo 1 || echo 0)" "$REAP_OUT"
invoke_reap --yes --force-unpushed
check '--force-unpushed: reaped anyway' "$(removed_has 1008)" "exit $REAP_CODE
$REAP_OUT"

# ---------------------------------------------------------------------------
# The regression this guards: a squash merge rewrites history, so the local
# branch's commits are ancestors of nothing on origin, and the source branch is
# deleted on completion so origin/<branch> is gone too. A naive
# "is HEAD on origin/<branch>?" test calls that unpushed work and the story is
# never reaped. The PR's own lastMergeSourceCommit is what settles it.
echo
echo '-- squash-merged story (no origin/<branch>, HEAD == the PR source commit) is reaped'
reset_fixture
clone="$(new_clone 'Alpha Repo')"
wt="$(new_story_checkout '1009-squashed' 'Alpha Repo' '1009-squashed' "$clone")"
prSha="$(add_commit "$wt" 'the work')"
pr="$(write_pr 5009 completed 'Alpha Repo' '1009-squashed' "$prSha")"
write_pr_list 'Alpha Repo' '1009-squashed' "$pr"
write_work_item 1009 5009
check 'squashed fixture really has no origin ref' \
  "$(git -C "$wt" rev-parse --verify --quiet refs/remotes/origin/1009-squashed >/dev/null 2>&1 && echo 0 || echo 1)" \
  'origin ref present'
invoke_reap --yes
check 'squashed: exit 0' "$([[ $REAP_CODE -eq 0 ]] && echo 1 || echo 0)" "exit $REAP_CODE
$REAP_OUT"
check 'squashed: reaped 1009' "$(removed_has 1009)" "$(removed_ids | tr '\n' ',')"

# ---------------------------------------------------------------------------
echo
echo '-- a PR linked only to the work item still holds the story'
reset_fixture
clone="$(new_clone 'Alpha Repo')"
wt="$(new_story_checkout '1010-linked' 'Alpha Repo' '1010-linked' "$clone")"
head="$(git -C "$wt" rev-parse HEAD)"
set_origin_ref "$wt" '1010-linked' "$head"
# The branch query finds a completed PR; the work item links a SECOND, active PR
# in a repo that is not checked out here. The union has to notice it.
prClosed="$(write_pr 5010 completed 'Alpha Repo' '1010-linked' "$head")"
write_pr 5011 active 'Gamma Repo' '1010-other' deadbeef >/dev/null
write_pr_list 'Alpha Repo' '1010-linked' "$prClosed"
write_work_item 1010 5010 5011
invoke_reap --yes
check 'work-item-only PR: exit 3' "$([[ $REAP_CODE -eq 3 ]] && echo 1 || echo 0)" "exit $REAP_CODE
$REAP_OUT"
check 'work-item-only PR: not reaped' "$([[ $(removed_count) -eq 0 ]] && echo 1 || echo 0)" "$(removed_ids | tr '\n' ',')"
check 'work-item-only PR: names 5011' "$(grep -q 'still open: 5011' <<<"$REAP_OUT" && echo 1 || echo 0)" "$REAP_OUT"

# ---------------------------------------------------------------------------
# The real disk layout that motivated grouping by id: 23573-finish-branch,
# 23573-improve-validation and 23573-read-path-fixes are all one work item, and
# `worktree-remove.sh 23573` takes all three at once. Judging them one folder at a
# time would let the clean folder authorise a removal that also deletes the folder
# holding uncommitted work.
echo
echo '-- several folders for one id are judged together, not one at a time'
reset_fixture
clone="$(new_clone 'Alpha Repo')"
wtA="$(new_story_checkout '1020-first-slice' 'Alpha Repo' '1020-first-slice' "$clone")"
wtB="$(new_story_checkout '1020-second-slice' 'Alpha Repo' '1020-second-slice' "$clone")"
headA="$(git -C "$wtA" rev-parse HEAD)"
headB="$(git -C "$wtB" rev-parse HEAD)"
set_origin_ref "$wtA" '1020-first-slice' "$headA"
set_origin_ref "$wtB" '1020-second-slice' "$headB"
prA="$(write_pr 5020 completed 'Alpha Repo' '1020-first-slice' "$headA")"
prB="$(write_pr 5021 completed 'Alpha Repo' '1020-second-slice' "$headB")"
write_pr_list 'Alpha Repo' '1020-first-slice' "$prA"
write_pr_list 'Alpha Repo' '1020-second-slice' "$prB"
write_work_item 1020 5020 5021
# The SECOND folder has unsaved work. Grouped by id, that must hold the whole work
# item back — including the clean first folder.
echo unsaved > "${wtB}/scratch.txt"
invoke_reap --yes
check 'multi-folder: dirty sibling holds the whole id' \
  "$([[ $(removed_count) -eq 0 ]] && echo 1 || echo 0)" "$(removed_ids | tr '\n' ',')
$REAP_OUT"
check 'multi-folder: exit 5 (held)' "$([[ $REAP_CODE -eq 5 ]] && echo 1 || echo 0)" "exit $REAP_CODE
$REAP_OUT"
check 'multi-folder: counted as ONE work item, not two' \
  "$(grep -q 'examined 1 story' <<<"$REAP_OUT" && grep -q 'work item 1020 (2 folder' <<<"$REAP_OUT" && echo 1 || echo 0)" \
  "$REAP_OUT"
check 'multi-folder: both folders listed' \
  "$(grep -q '1020-first-slice' <<<"$REAP_OUT" && grep -q '1020-second-slice' <<<"$REAP_OUT" && echo 1 || echo 0)" \
  "$REAP_OUT"
rm -f "${wtB}/scratch.txt"
invoke_reap --yes
check 'multi-folder: one removal call for the id' \
  "$([[ $(removed_count) -eq 1 ]] && echo 1 || echo 0)" "$(removed_ids | tr '\n' ',')
$REAP_OUT"

# ---------------------------------------------------------------------------
echo
echo '-- a review copy of the same id is held to the same bar'
reset_fixture
clone="$(new_clone 'Alpha Repo')"
wt="$(new_story_checkout '1021-with-review' 'Alpha Repo' '1021-with-review' "$clone")"
head="$(git -C "$wt" rev-parse HEAD)"
set_origin_ref "$wt" '1021-with-review' "$head"
pr="$(write_pr 5022 completed 'Alpha Repo' '1021-with-review' "$head")"
write_pr_list 'Alpha Repo' '1021-with-review' "$pr"
write_work_item 1021 5022
# A review/{id}-{slug} copy, detached, with unsaved work in it. Removal is by id so
# it would be deleted too; it therefore has to be able to hold the story back.
revWt="${TREES}/review/1021-with-review/Alpha_Repo"
mkdir -p "${TREES}/review/1021-with-review"
git -C "$clone" worktree add -q --detach "$revWt" main
echo 'unsaved review note' > "${revWt}/scratch.txt"
invoke_reap --yes
check 'review copy: dirty review holds the story' \
  "$([[ $(removed_count) -eq 0 ]] && echo 1 || echo 0)" "$(removed_ids | tr '\n' ',')
$REAP_OUT"
check 'review copy: flagged in the report' \
  "$(grep -q 'review copy' <<<"$REAP_OUT" && echo 1 || echo 0)" "$REAP_OUT"
# Clean: a DETACHED checkout has no branch to lose, so it must not be mistaken for
# unpushed work — that would hold the story back forever.
rm -f "${revWt}/scratch.txt"
invoke_reap --yes
check 'review copy: clean detached checkout does not block' "$(removed_has 1021)" "exit $REAP_CODE
$REAP_OUT"

# ---------------------------------------------------------------------------
echo
echo '-- --dry-run removes nothing'
reset_fixture
clone="$(new_clone 'Alpha Repo')"
wt="$(new_story_checkout '1011-dry' 'Alpha Repo' '1011-dry' "$clone")"
head="$(git -C "$wt" rev-parse HEAD)"
set_origin_ref "$wt" '1011-dry' "$head"
pr="$(write_pr 5012 completed 'Alpha Repo' '1011-dry' "$head")"
write_pr_list 'Alpha Repo' '1011-dry' "$pr"
write_work_item 1011 5012
invoke_reap --dry-run
check 'dry-run: exit 0' "$([[ $REAP_CODE -eq 0 ]] && echo 1 || echo 0)" "exit $REAP_CODE
$REAP_OUT"
check 'dry-run: worktree-remove never called' "$([[ $(removed_count) -eq 0 ]] && echo 1 || echo 0)" "$(removed_ids | tr '\n' ',')"
check 'dry-run: still lists the story' "$(grep -q '1011-dry' <<<"$REAP_OUT" && echo 1 || echo 0)" "$REAP_OUT"
check 'dry-run: checkout still on disk' "$([[ -d "$wt" ]] && echo 1 || echo 0)" "gone: $wt"

# ---------------------------------------------------------------------------
echo
echo '-- --story scopes the sweep to one id'
reset_fixture
clone="$(new_clone 'Alpha Repo')"
wtA="$(new_story_checkout '1012-first' 'Alpha Repo' '1012-first' "$clone")"
wtB="$(new_story_checkout '1013-second' 'Alpha Repo' '1013-second' "$clone")"
i=0
for spec in "1012:1012-first:5013:$wtA" "1013:1013-second:5014:$wtB"; do
  IFS=: read -r sid sbranch spr swt <<<"$spec"
  shead="$(git -C "$swt" rev-parse HEAD)"
  set_origin_ref "$swt" "$sbranch" "$shead"
  spr_json="$(write_pr "$spr" completed 'Alpha Repo' "$sbranch" "$shead")"
  write_pr_list 'Alpha Repo' "$sbranch" "$spr_json"
  write_work_item "$sid" "$spr"
done
invoke_reap --yes --story 1012
check '--story: reaped 1012 only' \
  "$([[ "$(removed_has 1012)" == "1" && "$(removed_has 1013)" == "0" ]] && echo 1 || echo 0)" \
  "$(removed_ids | tr '\n' ',')
$REAP_OUT"

# ---------------------------------------------------------------------------
echo
echo '-- Azure DevOps was only ever READ'
writes=''
if [[ -f "$AZLOG" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
      'boards work-item show '*|'repos pr show '*|'repos pr list '*|\
      'repos pr work-item list '*|'account show'*|'devops configure'*) ;;
      *) writes="${writes}${line} | " ;;
    esac
  done < "$AZLOG"
fi
check 'az log has calls in it' "$([[ -s "$AZLOG" ]] && echo 1 || echo 0)" 'no az calls were logged'
check 'az: nothing but reads issued' "$([[ -z "$writes" ]] && echo 1 || echo 0)" "$writes"
check 'AZ_READ_ONLY has no write verbs' \
  "$(grep -qE "^\s*'repos pr (create|update|complete|set-vote|reviewer)" "$REAP" && echo 0 || echo 1)" \
  'a write verb is on the allowlist'
check 'every az call goes through az_read' \
  "$([[ "$(grep -c '"\$AZ_CMD"' "$REAP")" -eq 1 ]] && echo 1 || echo 0)" \
  'more than one direct $AZ_CMD invocation - one of them bypasses the guard'

# ===========================================================================
echo
echo '=== summary ==='
echo "  passed ${PASS}, failed ${FAIL}"
if (( FAIL > 0 )); then
  echo '  failed checks:'
  for n in "${FAILED_NAMES[@]}"; do echo "    - $n"; done
fi
echo
echo "Fixtures left in place for inspection: ${BASE}"
echo 'Remove them with:'
echo "  rm -rf '${BASE}'"
(( FAIL > 0 )) && exit 1
exit 0
