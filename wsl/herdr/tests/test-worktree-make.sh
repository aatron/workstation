#!/usr/bin/env bash
# Test harness for wsl/herdr/worktree-make.sh
# Builds a throwaway upstream + clone per scenario, points a copy of the real
# script at it (SRC_ROOT) and at a throwaway herdr [worktrees].directory, runs it
# non-interactively, and asserts on the resulting worktree AND on the sidebar
# rows it draws.
#
# This is the bash counterpart of win/herdr/tests/test-worktree-make.ps1 and
# covers the same scenarios in the same order. Run it inside WSL, from a shell
# that can reach the herdr server (HERDR_SESSION set, or a default session).
#
# It creates real workspaces in your live session and closes them again.
# Cleanup matches on the fixture path, never on a workspace label, so your own
# rows cannot be caught by it.
set -uo pipefail

FIXTURE_MARKER="herdr-wt-tests"
BASE="${TMPDIR:-/tmp}/${FIXTURE_MARKER}/$$/make"
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/worktree-make.sh"
PREFIX="${WT_BRANCH_PREFIX:-feature/${USER:-YOU}}"   # must match BRANCH_PREFIX in worktree-make.sh
PASS=0; FAIL=0; FAILED_NAMES=()
RUN=0

# The connectors worktree-make reports as each repo row's $tree sidebar token,
# behind two blank columns so the connector sits inside its story rather than
# flush under the story's own bullet. The indent leads with U+2800 because herdr
# trims leading whitespace off a token value - plain spaces would be eaten.
INDENT_CH=$'⠀ '
BRANCH_CH="${INDENT_CH}"$'├─'    # |- not the last repo
LAST_CH="${INDENT_CH}"$'└─'      # `- the last repo

# Normalise a path the way the script under test does, so a cwd herdr hands back
# with doubled separators still compares equal. Case is NOT folded: Linux paths
# are case-sensitive.
pkey() {
  local p="$1"
  while [[ "$p" == *"//"* ]]; do p="${p//\/\//\/}"; done
  [[ "$p" == "/" ]] || p="${p%/}"
  printf '%s\n' "$p"
}

# Close every workspace this harness created. Matching is by PATH, not label:
# herdr does not always keep the --label we passed, so a label filter silently
# leaves fixture workspaces behind in the user's real herdr session.
#
# Both shapes have to be swept. worktree-make now creates a PLAIN workspace per
# story and per repo (no worktree metadata, panes rooted at the story folder) -
# matching only on .worktree, as this did originally, leaked one of those per
# test run.
close_workspaces() {
  local json ws panes
  json="$(herdr workspace list 2>/dev/null || true)"
  [[ -n "$json" ]] || return 0
  while read -r ws; do
    [[ -n "$ws" ]] || continue
    # Match on the fixture marker rather than the full path: it appears in
    # neither a real repo nor a real worktree.
    if jq -e --arg w "$ws" --arg m "$FIXTURE_MARKER" '
          .result.workspaces[]? | select(.workspace_id == $w)
          | select(.worktree != null)
          | select(((.worktree.repo_root // "") | contains($m))
                or ((.worktree.checkout_path // "") | contains($m)))
       ' >/dev/null 2>&1 <<<"$json"; then
      herdr worktree remove --workspace "$ws" --force >/dev/null 2>&1 || true
      herdr workspace close "$ws" >/dev/null 2>&1 || true
      continue
    fi
    # A plain workspace only reveals where it lives through its panes.
    panes="$(herdr pane list --workspace "$ws" 2>/dev/null || true)"
    [[ -n "$panes" ]] || continue
    if jq -e --arg m "$FIXTURE_MARKER" \
         '[.result.panes[]? | select((.cwd // "") | contains($m))] | length > 0' \
         >/dev/null 2>&1 <<<"$panes"; then
      herdr workspace close "$ws" >/dev/null 2>&1 || true
    fi
  done < <(jq -r '.result.workspaces[]?.workspace_id // empty' <<<"$json" 2>/dev/null)
}

# The fixture herdr config. "tree" as $1 lays the sidebar rows out so the $tree
# connector renders, which is what makes worktree-make label the repo rows with
# their bare name instead of a plain indent.
write_fixture_config() {
  printf '[worktrees]\ndirectory = "%s"\n' "$TREES" > "$CFG"
  if [[ "${1:-}" == "tree" ]]; then
    {
      echo '[ui.sidebar.spaces]'
      echo 'rows = [["$tree", "state_icon", "workspace"]]'
    } >> "$CFG"
  fi
}

reset_fixture() {
  # Close the workspaces this harness created, then move to a brand-new
  # directory: herdr panes keep handles open on old worktrees, so reusing one
  # path makes cleanup (not the code under test) the thing that fails.
  close_workspaces
  RUN=$((RUN + 1))
  ROOT="$BASE/run$RUN"
  REPOS="$ROOT/repos"; TREES="$ROOT/worktrees"; CFG="$ROOT/config.toml"
  SCRIPT="$ROOT/make-worktree.sh"
  mkdir -p "$REPOS" "$TREES"
  write_fixture_config
  # A copy of the real script with SRC_ROOT repointed at the fixture.
  sed "s|^SRC_ROOT=.*|SRC_ROOT=\"$REPOS\"|" "$REAL" > "$SCRIPT"
  chmod +x "$SCRIPT"
}

# $1 name  $2 default branch  $3 extra upstream commits
new_repo() {
  local name="$1" def="$2" extra="$3" i
  UP="$ROOT/$name.git"; WORK="$ROOT/$name.work"; CLONE="$REPOS/$name"
  git init -q --bare "$UP"
  git -C "$UP" symbolic-ref HEAD "refs/heads/$def"
  git init -q "$WORK"
  git -C "$WORK" config user.email t@t.t; git -C "$WORK" config user.name T
  echo base > "$WORK/f.txt"
  git -C "$WORK" add -A; git -C "$WORK" commit -qm c1
  git -C "$WORK" branch -M "$def"
  git -C "$WORK" remote add origin "$UP"
  git -C "$WORK" push -q -u origin "$def"
  git clone -q "$UP" "$CLONE"
  git -C "$CLONE" config user.email t@t.t; git -C "$CLONE" config user.name T
  for ((i = 1; i <= extra; i++)); do
    echo "up$i" >> "$WORK/f.txt"
    git -C "$WORK" commit -qam "upstream$i"
  done
  (( extra > 0 )) && git -C "$WORK" push -q origin "$def"
  TIP="$(git -C "$WORK" rev-parse HEAD)"
}

run_make() {   # run_make <type> [VAR=VAL ...]
  local type="$1"; shift
  local out rc
  set +e
  out="$(env HERDR_CONFIG_PATH="$CFG" "$@" bash "$SCRIPT" "$type" 2>&1)"
  rc=$?
  set -e
  OUT="$out"; RC=$rc
}

story() {   # story <id> <slug> <repo> [type]
  local sub="${4:-development}"
  [[ "$sub" == "review" ]] || sub="development"
  printf '%s/%s/%s-%s/%s\n' "$TREES" "$sub" "$1" "$2" "$3"
}

check() {   # check <name> <condition-result 0/1> <detail>
  if [[ "$2" == "0" ]]; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1")
    printf '  FAIL  %s :: %s\n' "$1" "$3"
  fi
}
ok() { [[ "$1" == "$2" ]] && echo 0 || echo 1; }

# ---------------------------------------------------------------------------
# Sidebar helpers. WSJSON is a snapshot of `workspace list` taken just before a
# block of assertions, so every field of a row is read from one consistent view.
# ---------------------------------------------------------------------------
WSJSON='{}'
snapshot() { WSJSON="$(herdr workspace list 2>/dev/null || echo '{}')"; }

ws_field() {   # ws_field <ws> <jq expression against the workspace object>
  jq -r --arg w "$1" ".result.workspaces[]? | select(.workspace_id==\$w) | $2" \
    <<<"$WSJSON" 2>/dev/null | head -n1
}
ws_label()  { ws_field "$1" '.label // ""'; }
ws_number() { ws_field "$1" '.number // 0'; }
ws_tree()   { ws_field "$1" '.tokens.tree // ""'; }

# Plain workspaces whose panes sit at $1 exactly, or - without "exact" - anywhere
# under it. Used to assert the story topology: the story row at the story folder,
# and one repo row rooted at each repo inside it.
fixture_workspaces() {   # fixture_workspaces <path> [exact]
  local want exact="${2:-}" ws panes cwd have
  want="$(pkey "$1")"
  [[ -n "$want" ]] || return 0
  while read -r ws; do
    [[ -n "$ws" ]] || continue
    panes="$(herdr pane list --workspace "$ws" 2>/dev/null || true)"
    [[ -n "$panes" ]] || continue
    while read -r cwd; do
      have="$(pkey "$cwd")"
      if [[ "$have" == "$want" ]] ||
         { [[ "$exact" != "exact" ]] && [[ "$have" == "$want"/* ]]; }; then
        printf '%s\n' "$ws"; break
      fi
    done < <(jq -r '.result.panes[]?.cwd // empty' <<<"$panes" 2>/dev/null)
  done < <(jq -r '.result.workspaces[]? | select(.worktree == null) | .workspace_id' \
             <<<"$WSJSON" 2>/dev/null)
}

# herdr-registered worktree workspaces whose checkout sits inside $1. These are
# what `herdr worktree create` used to leave behind - one per repo, each nested
# under its primary clone in the sidebar. There should now be none.
worktree_workspaces_under() {
  local want; want="$(pkey "$1")"
  jq -r --arg want "$want" '
    [.result.workspaces[]? | select(.worktree != null)
     | select(((.worktree.checkout_path // "") | startswith($want + "/")))] | length
  ' <<<"$WSJSON" 2>/dev/null || echo 0
}

tab_labels() {   # sorted, comma-joined
  herdr tab list --workspace "$1" 2>/dev/null \
    | jq -r '[.result.tabs[]?.label // ""] | sort | join(",")' 2>/dev/null || true
}
tab_count() {
  herdr tab list --workspace "$1" 2>/dev/null \
    | jq -r '[.result.tabs[]?] | length' 2>/dev/null || echo 0
}

# "label|label|label" for a set of workspace ids, ordered by sidebar position.
labels_by_number() {
  local ws
  for ws in "$@"; do printf '%s\t%s\n' "$(ws_number "$ws")" "$(ws_label "$ws")"; done \
    | sort -n -k1,1 | cut -f2- | paste -sd'|' -
}
numbers_sorted() {
  local ws
  for ws in "$@"; do ws_number "$ws"; done | sort -n | paste -sd',' -
}

echo
echo '================ worktree-make.sh test run ================'

echo
echo '1. happy path: new branch lands on the LATEST default branch'
reset_fixture; new_repo mono 'develop' 4
run_make development WT_ID=99301 WT_SLUG=zz-happy WT_REPOS=mono
WT="$(story 99301 zz-happy mono)"
HEAD="$(git -C "$WT" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == upstream tip' "$(ok "$HEAD" "$TIP")" "head=$HEAD want=$TIP
$OUT"
check 'verify line printed' "$(grep -q 'verify: HEAD' <<<"$OUT" && echo 0 || echo 1)" 'no verify line'

echo
echo '2. stale remote-tracking ref is refreshed by the fetch'
reset_fixture; new_repo mono main 5
FIRST="$(git -C "$CLONE" rev-list --max-parents=0 HEAD)"
git -C "$CLONE" update-ref refs/remotes/origin/main "$FIRST"
run_make development WT_ID=99302 WT_SLUG=zz-stale WT_REPOS=mono
HEAD="$(git -C "$(story 99302 zz-stale mono)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == upstream tip' "$(ok "$HEAD" "$TIP")" "head=$HEAD want=$TIP
$OUT"

echo
echo '3. THE BUG: leftover branch with no unique commits is moved to the base'
reset_fixture; new_repo mono main 6
STALE="$(git -C "$CLONE" rev-parse origin/main)"
git -C "$CLONE" branch "$PREFIX/99303-zz-left" "$STALE"
run_make development WT_ID=99303 WT_SLUG=zz-left WT_REPOS=mono
HEAD="$(git -C "$(story 99303 zz-left mono)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == upstream tip (not the stale branch tip)' "$(ok "$HEAD" "$TIP")" "head=$HEAD want=$TIP stale=$STALE
$OUT"
check 'reported the move' "$(grep -q 'no commits of its own' <<<"$OUT" && echo 0 || echo 1)" 'no move message'

echo
echo '4. leftover branch WITH unique commits: refuse, create nothing'
reset_fixture; new_repo mono main 3
STALE="$(git -C "$CLONE" rev-parse origin/main)"
TREE="$(git -C "$CLONE" rev-parse "$STALE^{tree}")"
MINE="$(git -C "$CLONE" commit-tree "$TREE" -p "$STALE" -m 'my local work')"
git -C "$CLONE" update-ref "refs/heads/$PREFIX/99304-zz-work" "$MINE"
run_make development WT_ID=99304 WT_SLUG=zz-work WT_REPOS=mono
check 'exit 1' "$(ok "$RC" 1)" "rc=$RC
$OUT"
check 'no worktree created' "$([[ -e "$(story 99304 zz-work mono)/.git" ]] && echo 1 || echo 0)" 'worktree exists'
check 'explains the overrides' "$(grep -q 'WT_REUSE_BRANCH' <<<"$OUT" && grep -q 'WT_RESET_BRANCH' <<<"$OUT" && echo 0 || echo 1)" "no hint
$OUT"
check 'branch left untouched' "$(ok "$(git -C "$CLONE" rev-parse "refs/heads/$PREFIX/99304-zz-work")" "$MINE")" 'branch moved'

echo
echo '5. WT_RESET_BRANCH=1 discards the unique commits and uses the base'
run_make development WT_ID=99304 WT_SLUG=zz-work WT_REPOS=mono WT_RESET_BRANCH=1
HEAD="$(git -C "$(story 99304 zz-work mono)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == upstream tip' "$(ok "$HEAD" "$TIP")" "head=$HEAD want=$TIP
$OUT"

echo
echo '6. WT_REUSE_BRANCH=1 keeps the existing branch and says how far behind'
reset_fixture; new_repo mono main 3
STALE="$(git -C "$CLONE" rev-parse origin/main)"
TREE="$(git -C "$CLONE" rev-parse "$STALE^{tree}")"
MINE="$(git -C "$CLONE" commit-tree "$TREE" -p "$STALE" -m 'my local work')"
git -C "$CLONE" update-ref "refs/heads/$PREFIX/99306-zz-reuse" "$MINE"
run_make development WT_ID=99306 WT_SLUG=zz-reuse WT_REPOS=mono WT_REUSE_BRANCH=1
HEAD="$(git -C "$(story 99306 zz-reuse mono)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == existing branch tip' "$(ok "$HEAD" "$MINE")" "head=$HEAD want=$MINE
$OUT"
check 'warns it is behind' "$(grep -q 'behind origin/main' <<<"$OUT" && echo 0 || echo 1)" 'no behind warning'

echo
echo '7. branch already checked out elsewhere: refuse'
reset_fixture; new_repo mono main 2
git -C "$CLONE" worktree add -q -b "$PREFIX/99307-zz-dup" "$ROOT/other-wt" origin/main >/dev/null 2>&1
run_make development WT_ID=99307 WT_SLUG=zz-dup WT_REPOS=mono
check 'exit 1' "$(ok "$RC" 1)" "rc=$RC
$OUT"
check 'names the conflicting worktree' "$(grep -q 'already checked out at' <<<"$OUT" && echo 0 || echo 1)" "no message
$OUT"

echo
echo '8. fetch failure: refuse rather than use a stale origin'
reset_fixture; new_repo mono main 4
git -C "$CLONE" remote set-url origin "$ROOT/nope.git"
run_make development WT_ID=99308 WT_SLUG=zz-nofetch WT_REPOS=mono
check 'exit 1' "$(ok "$RC" 1)" "rc=$RC
$OUT"
check 'says the fetch failed' "$(grep -q 'fetch failed' <<<"$OUT" && echo 0 || echo 1)" "no message
$OUT"
check 'no worktree created' "$([[ -e "$(story 99308 zz-nofetch mono)/.git" ]] && echo 1 || echo 0)" 'worktree exists'
check 'retried once' "$(ok "$(grep -c 'git fetch --prune origin in' <<<"$OUT")" 2)" 'no retry'

echo
echo '9. missing origin/HEAD is recovered from the remote'
reset_fixture; new_repo mono 'develop' 3
git -C "$CLONE" symbolic-ref -d refs/remotes/origin/HEAD
check 'origin/HEAD really gone' "$([[ -z "$(git -C "$CLONE" symbolic-ref -q --short refs/remotes/origin/HEAD || true)" ]] && echo 0 || echo 1)" 'still there'
run_make development WT_ID=99309 WT_SLUG=zz-nohead WT_REPOS=mono
HEAD="$(git -C "$(story 99309 zz-nohead mono)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == tip of the real default branch' "$(ok "$HEAD" "$TIP")" "head=$HEAD want=$TIP
$OUT"
check 'base label names the real default' "$(grep -q 'origin/develop @' <<<"$OUT" && echo 0 || echo 1)" "no base line
$OUT"

echo
echo '10. empty leftover directory at the worktree path is cleaned up'
reset_fixture; new_repo mono main 2
mkdir -p "$(story 99310 zz-empty mono)"
run_make development WT_ID=99310 WT_SLUG=zz-empty WT_REPOS=mono
HEAD="$(git -C "$(story 99310 zz-empty mono)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == upstream tip' "$(ok "$HEAD" "$TIP")" "head=$HEAD want=$TIP
$OUT"

echo
echo '11. re-run is idempotent (exit 3)'
run_make development WT_ID=99310 WT_SLUG=zz-empty WT_REPOS=mono
check 'exit 3' "$(ok "$RC" 3)" "rc=$RC
$OUT"

echo
echo '12. review: worktree lands on origin/<linked branch>, stale local branch fixed'
reset_fixture; new_repo mono main 2
git -C "$WORK" checkout -q -b feature/someone/99312-pr
echo pr1 >> "$WORK/f.txt"; git -C "$WORK" commit -qam pr1
git -C "$WORK" push -q origin feature/someone/99312-pr
PRMID="$(git -C "$WORK" rev-parse HEAD)"
echo pr2 >> "$WORK/f.txt"; git -C "$WORK" commit -qam pr2
git -C "$WORK" push -q origin feature/someone/99312-pr
PRTIP="$(git -C "$WORK" rev-parse HEAD)"
git -C "$CLONE" fetch -q origin
git -C "$CLONE" update-ref refs/heads/feature/someone/99312-pr "$PRMID"
git -C "$CLONE" update-ref refs/remotes/origin/feature/someone/99312-pr "$PRMID"
printf 'mono:feature/someone/99312-pr' > "$ROOT/branches.txt"
run_make review WT_ID=99312 WT_SLUG=zz-review WT_BRANCHES_FILE="$ROOT/branches.txt"
HEAD="$(git -C "$(story 99312 zz-review mono review)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == origin PR tip (not the stale local branch)' "$(ok "$HEAD" "$PRTIP")" "head=$HEAD want=$PRTIP mid=$PRMID
$OUT"

echo
echo '13. multi-repo: one bad repo does not stop the good one'
reset_fixture
new_repo aaa main 3; TIP_A="$TIP"
new_repo bbb main 2
git -C "$REPOS/bbb" remote set-url origin "$ROOT/nope.git"
run_make development WT_ID=99313 WT_SLUG=zz-multi WT_REPOS='aaa, bbb'
HEAD_A="$(git -C "$(story 99313 zz-multi aaa)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 1 (a repo failed)' "$(ok "$RC" 1)" "rc=$RC
$OUT"
check 'good repo created at tip' "$(ok "$HEAD_A" "$TIP_A")" "head=$HEAD_A want=$TIP_A
$OUT"
check 'bad repo not created' "$([[ -e "$(story 99313 zz-multi bbb)/.git" ]] && echo 1 || echo 0)" 'bbb exists'

echo
echo '14. missing clone is reported, does not crash the run'
reset_fixture; new_repo aaa main 1
run_make development WT_ID=99014 WT_SLUG=zz-missing WT_REPOS='aaa,ghost'
check 'exit 1' "$(ok "$RC" 1)" "rc=$RC
$OUT"
check 'names the missing clone' "$(grep -q 'missing clone' <<<"$OUT" && echo 0 || echo 1)" "no message
$OUT"
check 'good repo created' "$([[ -e "$(story 99014 zz-missing aaa)/.git" ]] && echo 0 || echo 1)" 'aaa missing'

echo
echo '15. one story workspace, repos.txt, no per-repo sidebar rows'
reset_fixture; new_repo aaa main 1; new_repo bbb main 2
run_make development WT_ID=99015 WT_SLUG=zz-topo WT_REPOS='aaa,bbb'
STORY_DIR_15="$(dirname "$(story 99015 zz-topo aaa)")"
REPOS_TXT_15="${STORY_DIR_15}/repos.txt"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'both repos are folders inside the story' \
  "$([[ -e "$(story 99015 zz-topo aaa)/.git" && -e "$(story 99015 zz-topo bbb)/.git" ]] && echo 0 || echo 1)" \
  'a repo is missing'
check 'repos.txt exists' "$([[ -f "$REPOS_TXT_15" ]] && echo 0 || echo 1)" "path=$REPOS_TXT_15"
check 'repos.txt lists aaa then bbb' \
  "$(ok "$(cat "$REPOS_TXT_15")" "$(printf 'aaa\nbbb\n')")" "content=$(cat "$REPOS_TXT_15" | od -c)"

snapshot
mapfile -t STORY15 < <(fixture_workspaces "$STORY_DIR_15" exact)
check 'exactly one story workspace' "$(ok "${#STORY15[@]}" 1)" "count=${#STORY15[@]}
$OUT"
if (( ${#STORY15[@]} == 1 )); then
  check 'labeled {id}-{slug}' "$(ok "$(ws_label "${STORY15[0]}")" '99015-zz-topo')" \
    "label=$(ws_label "${STORY15[0]}")"
  check 'not nested under a repo (no worktree metadata)' \
    "$(ok "$(ws_field "${STORY15[0]}" '.worktree // "null"')" 'null')" 'it is a worktree workspace'
  check 'story has notes, claude, cursor and bash tabs' \
    "$(ok "$(tab_labels "${STORY15[0]}")" 'bash,claude,cursor,notes')" \
    "tabs=$(tab_labels "${STORY15[0]}")"
  check 'story has exactly four tabs' "$(ok "$(tab_count "${STORY15[0]}")" 4)" \
    "tabs=$(tab_labels "${STORY15[0]}")"
fi
for repo in aaa bbb; do
  mapfile -t ROW < <(fixture_workspaces "$(story 99015 zz-topo "$repo")" exact)
  check "no workspace row for repo $repo" "$(ok "${#ROW[@]}" 0)" "count=${#ROW[@]}"
done
mapfile -t ALL15 < <(fixture_workspaces "$STORY_DIR_15")
check 'only one sidebar row for the story' "$(ok "${#ALL15[@]}" 1)" "count=${#ALL15[@]}"
check 'no per-repo worktree workspace was registered' \
  "$(ok "$(worktree_workspaces_under "$STORY_DIR_15")" 0)" 'a repo-level worktree workspace exists'

echo
echo '16. re-run reuses the story workspace (no duplicates)'
run_make development WT_ID=99015 WT_SLUG=zz-topo WT_REPOS='aaa,bbb'
snapshot
mapfile -t ALL16 < <(fixture_workspaces "$STORY_DIR_15" exact)
check 'exit 3 (nothing to do)' "$(ok "$RC" 3)" "rc=$RC
$OUT"
check 'still one story workspace' "$(ok "${#ALL16[@]}" 1)" "count=${#ALL16[@]}
$OUT"
check 'same workspace id' \
  "$(ok "${ALL16[0]}" "${STORY15[0]}")" "before=${STORY15[0]} after=${ALL16[0]}"
check 'said it reused the story workspace' "$(ok "$(grep -c 'reusing workspace' <<<"$OUT")" 1)" "reuse lines
$OUT"
check 'story still has four tabs' \
  "$(ok "$(tab_count "${ALL16[0]}")" 4)" "tabs=$(tab_labels "${ALL16[0]}")"

echo
echo '17. adding a repo updates repos.txt, still one story workspace'
new_repo ccc main 1
run_make development WT_ID=99015 WT_SLUG=zz-topo WT_REPOS='aaa,bbb,ccc'
snapshot
mapfile -t ALL17 < <(fixture_workspaces "$STORY_DIR_15" exact)
check 'exit 0 (one repo created)' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'repos.txt lists aaa, bbb, ccc' \
  "$(ok "$(cat "$REPOS_TXT_15")" "$(printf 'aaa\nbbb\nccc\n')")" "content=$(cat "$REPOS_TXT_15" | od -c)"
check 'still exactly one story workspace' "$(ok "${#ALL17[@]}" 1)" "count=${#ALL17[@]}
$OUT"
mapfile -t ROW_CCC < <(fixture_workspaces "$(story 99015 zz-topo ccc)" exact)
check 'no sidebar row for ccc' "$(ok "${#ROW_CCC[@]}" 0)" "count=${#ROW_CCC[@]}"
check 'ccc worktree exists on disk' \
  "$([[ -e "$(story 99015 zz-topo ccc)/.git" ]] && echo 0 || echo 1)" 'ccc missing'

echo
echo '18. repos.txt stays in sync with tree config; still no per-repo rows'
reset_fixture
write_fixture_config tree
new_repo aaa main 1; new_repo bbb main 1
run_make development WT_ID=99018 WT_SLUG=zz-tree WT_REPOS='aaa,bbb'
STORY_DIR_18="$(dirname "$(story 99018 zz-tree aaa)")"
REPOS_TXT_18="${STORY_DIR_18}/repos.txt"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'repos.txt lists aaa then bbb' \
  "$(ok "$(cat "$REPOS_TXT_18")" "$(printf 'aaa\nbbb\n')")" "content=$(cat "$REPOS_TXT_18" | od -c)"
mapfile -t STORY18 < <(fixture_workspaces "$STORY_DIR_18" exact)
check 'exactly one story workspace' "$(ok "${#STORY18[@]}" 1)" "count=${#STORY18[@]}"
check 'no per-repo workspace rows' \
  "$([[ $(fixture_workspaces "$(story 99018 zz-tree aaa)" exact | wc -l) -eq 0 &&
      $(fixture_workspaces "$(story 99018 zz-tree bbb)" exact | wc -l) -eq 0 ]] && echo 0 || echo 1)" \
  'a repo row exists'
new_repo ccc main 1
run_make development WT_ID=99018 WT_SLUG=zz-tree WT_REPOS='aaa,bbb,ccc'
check 'repos.txt updated to three lines' \
  "$(ok "$(cat "$REPOS_TXT_18")" "$(printf 'aaa\nbbb\nccc\n')")" "content=$(cat "$REPOS_TXT_18" | od -c)"
mapfile -t STORY18B < <(fixture_workspaces "$STORY_DIR_18" exact)
check 'still one story workspace after adding ccc' "$(ok "${#STORY18B[@]}" 1)" "count=${#STORY18B[@]}"

# ---------------------------------------------------------------------------
# Cleanup order matters, and one pass is not enough. herdr keeps a workspace for
# every fixture CLONE it has seen and re-lists it while the repo is still on
# disk, while its panes hold those directories open so the delete fails until
# they are closed. Each round closes what it can and deletes what it can, which
# frees the next round; in practice it converges in two or three.
for _round in 1 2 3 4 5 6 7 8; do
  close_workspaces
  rm -rf "$BASE" 2>/dev/null || true
  remaining="$(herdr workspace list 2>/dev/null \
    | jq -r --arg m "$FIXTURE_MARKER" '[.result.workspaces[]?
        | select(.worktree != null)
        | select(((.worktree.repo_root // "") | contains($m)))] | length' 2>/dev/null || echo 0)"
  [[ "$remaining" == "0" && ! -e "$BASE" ]] && break
  sleep 2
done
if [[ -e "$BASE" ]]; then
  echo "note: could not fully delete fixture dir ${BASE} (herdr may still hold it)" >&2
fi
echo
echo '================ summary ================'
echo "PASS: $PASS   FAIL: $FAIL"
if (( FAIL > 0 )); then
  printf 'failed checks:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
exit 0
