#!/usr/bin/env bash
# Covers the shell logic of wsl/herdr/worktree-remove.sh (protected branches,
# leftover cleanup, non-empty dirs left alone, WT_REPO scoping) with plain
# `git worktree add` fixtures and no herdr involvement.
set -uo pipefail

BASE="${TMPDIR:-/tmp}/herdr-wt-tests/$$/remove"
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/worktree-remove.sh"
PREFIX=feature/YOU   # must match BRANCH_PREFIX in worktree-make.sh
PASS=0; FAIL=0; NAMES=()
RUN=0

reset_fixture() {
  RUN=$((RUN + 1))
  ROOT="$BASE/run$RUN"; REPOS="$ROOT/repos"; TREES="$ROOT/worktrees"
  CFG="$ROOT/config.toml"; SCRIPT="$ROOT/worktree-remove.sh"
  mkdir -p "$REPOS" "$TREES/development"
  printf '[worktrees]\ndirectory = "%s"\n' "$TREES" > "$CFG"
  cp "$REAL" "$SCRIPT"; chmod +x "$SCRIPT"
}

new_repo() {   # new_repo <name> <default-branch>  -> sets CLONE
  local name="$1" def="$2"
  local up="$ROOT/$name.git" work="$ROOT/$name.work"
  CLONE="$REPOS/$name"
  git init -q --bare "$up"
  git -C "$up" symbolic-ref HEAD "refs/heads/$def"
  git init -q "$work"
  git -C "$work" config user.email t@t.t; git -C "$work" config user.name T
  echo base > "$work/f.txt"; git -C "$work" add -A; git -C "$work" commit -qm c1
  git -C "$work" branch -M "$def"
  git -C "$work" remote add origin "$up"; git -C "$work" push -q -u origin "$def"
  git clone -q "$up" "$CLONE"
  git -C "$CLONE" config user.email t@t.t; git -C "$CLONE" config user.name T
}

story_dir() { printf '%s/development/%s\n' "$TREES" "$1"; }

add_worktree() {   # add_worktree <clone> <story> <repo> <branch> -> sets WT
  WT="$(story_dir "$2")/$3"
  mkdir -p "$(story_dir "$2")"
  git -C "$1" worktree add -q -b "$4" "$WT" HEAD
}

run_remove() {   # run_remove <VAR=VAL ...>
  set +e
  OUT="$(env HERDR_CONFIG_PATH="$CFG" WT_ASSUME_YES=1 "$@" bash "$SCRIPT" 2>&1)"
  RC=$?
  set -e
}

branch_exists() { git -C "$1" rev-parse --verify --quiet "refs/heads/$2" >/dev/null 2>&1; }
check() { if [[ "$2" == "0" ]]; then PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; else FAIL=$((FAIL+1)); NAMES+=("$1"); printf '  FAIL  %s :: %s\n' "$1" "$3"; fi; }
ok() { [[ "$1" == "$2" ]] && echo 0 || echo 1; }
yes_no() { if "$@"; then echo 0; else echo 1; fi; }

echo
echo '================ worktree-remove.sh (shell logic) test run ================'

echo
echo '1. normal removal: worktree, branch, notes and story folder all go'
reset_fixture; new_repo mono main
add_worktree "$CLONE" 78001-zz-norm mono "$PREFIX/78001-zz-norm"
echo notes > "$(story_dir 78001-zz-norm)/78001-zz-norm-mono.txt"
run_remove WT_ID=78001
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'worktree dir gone' "$([[ -e "$WT" ]] && echo 1 || echo 0)" 'still there'
check 'branch deleted' "$(branch_exists "$CLONE" "$PREFIX/78001-zz-norm" && echo 1 || echo 0)" 'branch still there'
check 'story folder gone' "$([[ -e "$(story_dir 78001-zz-norm)" ]] && echo 1 || echo 0)" 'folder still there'
# An rm -rf that skipped `git worktree remove` leaves the registration behind,
# and the next story of the same name then trips over it.
check 'git no longer lists it' \
  "$(git -C "$CLONE" worktree list --porcelain 2>/dev/null | grep -qF "$WT" && echo 1 || echo 0)" \
  'still registered as a worktree'

echo
echo '2. a non-standard DEFAULT branch is protected from deletion'
reset_fixture; new_repo mono 'develop'
# Detach the main clone first, otherwise the default branch cannot be checked
# out in a second worktree and the test would silently fall back to detached
# HEAD (which the script skips for a different reason).
git -C "$CLONE" checkout -q --detach
WT="$(story_dir 78002-zz-def)/mono"; mkdir -p "$(story_dir 78002-zz-def)"
git -C "$CLONE" worktree add -q "$WT" 'develop'
check 'fixture: worktree really is on the default branch' \
  "$(ok "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" 'develop')" \
  "got $(git -C "$WT" rev-parse --abbrev-ref HEAD)"
run_remove WT_ID=78002
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'default branch NOT deleted' "$(branch_exists "$CLONE" 'develop' && echo 0 || echo 1)" "it was deleted!
$OUT"
check 'said it was protected' "$(grep -q 'protected' <<<"$OUT" && echo 0 || echo 1)" "no note
$OUT"

echo
echo '2b. missing origin/HEAD: default branch STILL protected (via ls-remote)'
reset_fixture; new_repo mono 'develop'
git -C "$CLONE" symbolic-ref -d refs/remotes/origin/HEAD
git -C "$CLONE" checkout -q --detach
WT="$(story_dir 78012-zz-nohead)/mono"; mkdir -p "$(story_dir 78012-zz-nohead)"
git -C "$CLONE" worktree add -q "$WT" 'develop'
check 'fixture: on the default branch, origin/HEAD gone' \
  "$(ok "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" 'develop')" \
  "got $(git -C "$WT" rev-parse --abbrev-ref HEAD)"
run_remove WT_ID=78012
check 'default branch NOT deleted' "$(branch_exists "$CLONE" 'develop' && echo 0 || echo 1)" "it was deleted!
$OUT"

echo
echo '3. empty leftover dir (half-finished removal) is cleaned up'
reset_fixture; new_repo mono main
mkdir -p "$(story_dir 78003-zz-left)/mono"
echo notes > "$(story_dir 78003-zz-left)/78003-zz-left-mono.txt"
run_remove WT_ID=78003
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'leftover dir gone' "$([[ -e "$(story_dir 78003-zz-left)/mono" ]] && echo 1 || echo 0)" 'still there'
check 'story folder gone' "$([[ -e "$(story_dir 78003-zz-left)" ]] && echo 1 || echo 0)" 'folder still there'
check 'named it a leftover' "$(grep -q 'leftover' <<<"$OUT" && echo 0 || echo 1)" "no leftover line
$OUT"

echo
echo '4. a NON-empty non-worktree dir is left strictly alone'
reset_fixture; new_repo mono main
mkdir -p "$(story_dir 78004-zz-junk)/mono"
echo 'do not delete me' > "$(story_dir 78004-zz-junk)/mono/important.txt"
run_remove WT_ID=78004
check 'file preserved' "$([[ -f "$(story_dir 78004-zz-junk)/mono/important.txt" ]] && echo 0 || echo 1)" 'DELETED USER DATA'
check 'reported as kept' "$(grep -q 'not a worktree, and not empty' <<<"$OUT" && echo 0 || echo 1)" "no keep line
$OUT"
check 'exit 3 (nothing removable)' "$(ok "$RC" 3)" "rc=$RC
$OUT"

echo
echo '5. WT_SKIP_DIRTY=1 keeps a worktree with uncommitted changes (exit 5)'
reset_fixture; new_repo mono main
add_worktree "$CLONE" 78005-zz-dirty mono "$PREFIX/78005-zz-dirty"
echo changed > "$WT/f.txt"
run_remove WT_ID=78005 WT_SKIP_DIRTY=1
check 'exit 5' "$(ok "$RC" 5)" "rc=$RC
$OUT"
check 'worktree kept' "$([[ -e "$WT/.git" ]] && echo 0 || echo 1)" 'deleted a dirty worktree!'
check 'branch kept' "$(branch_exists "$CLONE" "$PREFIX/78005-zz-dirty" && echo 0 || echo 1)" \
  'branch deleted under a kept worktree'

echo
echo '6. WT_REPO scoping removes only that repo'
reset_fixture
new_repo aaa main; CA="$CLONE"; add_worktree "$CA" 78006-zz-scope aaa "$PREFIX/78006-zz-scope"; WA="$WT"
new_repo bbb main; CB="$CLONE"; add_worktree "$CB" 78006-zz-scope bbb "$PREFIX/78006-zz-scope"; WB="$WT"
run_remove WT_ID=78006 WT_REPO=aaa
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'aaa removed' "$([[ -e "$WA" ]] && echo 1 || echo 0)" 'aaa still there'
check 'bbb kept' "$([[ -e "$WB/.git" ]] && echo 0 || echo 1)" 'bbb was removed!'
check 'bbb branch kept' "$(branch_exists "$CB" "$PREFIX/78006-zz-scope" && echo 0 || echo 1)" 'bbb branch deleted'
# The folder is what makes single-repo mode safe: it has to survive until the
# last repo in the story goes.
check 'story folder kept (bbb still in it)' \
  "$([[ -d "$(story_dir 78006-zz-scope)" ]] && echo 0 || echo 1)" 'story folder deleted early'

echo
echo '7. nothing matching the id -> exit 3'
reset_fixture; new_repo mono main
run_remove WT_ID=78999
check 'exit 3' "$(ok "$RC" 3)" "rc=$RC
$OUT"

rm -rf "$BASE" 2>/dev/null || true
echo
echo '================ summary ================'
echo "PASS: $PASS   FAIL: $FAIL"
if (( FAIL > 0 )); then
  printf 'failed checks:\n'
  for n in "${NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
exit 0
