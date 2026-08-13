# manual-checks — run these on purpose, never automatically

These files check `review-make.sh`, `review-remove.sh` and `story-reap.sh`. They are
**not** in `tests/` and are **not** named `test-*.sh`, and that is deliberate.

They are the bash counterpart of `win/herdr/manual-checks/`, and are kept at the
same coverage. If you add a scenario to one side, add it to the other.

## Why they are quarantined

The scripts they cover talk to **Azure DevOps**. Even though every call they make
is a read, a test suite that reaches a real work tracker is the wrong thing to
have sitting in a folder that some future runner — a CI job, a pre-commit hook,
an agent told to "run the tests" — might sweep up and execute unattended. The
naming and the location are the guard:

* not `tests/`, so a runner pointed at that folder finds nothing here
* not `test-*.sh`, so a glob for test files does not match
* `check-*.sh`, which no convention treats as automatically runnable

If you add a file here, keep both properties. If you ever move one of these into
`tests/`, you have removed the guard.

## What they actually touch

| | |
|---|---|
| **Azure DevOps** | **Nothing.** Every suite runs the scripts against a **stub `az`** injected through `WT_REVIEW_AZ`. The stub serves canned JSON from a temp directory and logs every argument list it receives. There is no network call and no credential use anywhere in these files. |
| **git** | Throwaway bare repos and clones under `$TMPDIR/herdr-review-checks/<pid>/`, `$TMPDIR/herdr-review-rm-checks/<pid>/` and `/tmp/herdr-story-reap-checks/<pid>/`. Nothing under `~/source` is read or written. |
| **herdr** | The two review suites create workspaces in your **live** session and close them again. Cleanup matches on the fixture path, never on a workspace label, so your own rows cannot be caught by it. `check-story-reap.sh` touches herdr **not at all** — see below. |
| **your files** | Nothing. No config, no notes, no repos. `HERDR_CONFIG_PATH` and `WT_REVIEW_SRC_ROOT` are pointed at fixture copies for the child process only. |

They do not just avoid writing to Azure DevOps — they **prove** the scripts
cannot. Both suites:

* assert `az_read_only` rejects `boards work-item update`, `repos pr set-vote`,
  `repos pr update`, `repos pr reviewer add`, `devops invoke --http-method PATCH`,
  `--in-file`, `--body`, and friends
* source that guard out of the real script rather than re-implementing it, so a
  change to the guard is what is being tested
* replay the stub's own call log through the guard afterwards, so a write that
  slipped through by some other route would still be caught

## Running them

All stub suites at once:

```bash
cd wsl/herdr/manual-checks
bash run-all.sh
```

Or one at a time:

```bash
cd wsl/herdr/manual-checks
bash check-review-make.sh
bash check-review-remove.sh
bash check-story-reap.sh
```

Exit 0 means everything passed; exit 1 prints the failures at the end. The two
review suites take a few minutes each, mostly waiting on herdr;
`check-story-reap.sh` finishes in seconds.

### Live smoke against existing clones (opt-in)

`smoke-live-review.sh` is **not** part of `run-all.sh`. It calls real `az` and
your real `SRC_ROOT` clones. You must pass a work item id:

```bash
bash smoke-live-review.sh 23597
# optional: WT_REVIEW_SRC_ROOT=$HOME/source/repos bash smoke-live-review.sh 23597
```

Cleanup when finished: `bash ../review-remove.sh <id> --yes`.

**Start herdr first** for the two review suites. They create real workspaces, so
without a running session the herdr assertions fail for a reason that has nothing
to do with the code under test. If you use a **named** session, export
`HERDR_SESSION` first — the scripts resolve `sessions/<name>/herdr.sock` from it,
and without it the sidebar-ordering assertions have nothing to talk to.

`check-story-reap.sh` needs no herdr session and creates no workspace. On top of the
stub `az` it also replaces **`worktree-remove.sh`** with a stub
(`WT_REMOVE_SCRIPT`) that only records the story id it was handed, so nothing is
ever deleted. What it checks is which stories `story-reap.sh` *decides* to reap —
the removal itself is `worktree-remove.sh`'s own business, covered by
`tests/test-worktree-remove.sh`. Its lock file is redirected into the fixture
(`STORY_REAP_LOCK`) so a real cron run cannot make a check exit early, and it does
not need `gum` either, since every invocation passes `--yes`.

Every `review-remove.sh` invocation inside `check-review-remove.sh` passes
`--yes`. Without it, `gum confirm` sits waiting for a keypress nobody is there to
give and the suite hangs.

## If a run is interrupted

Ctrl-C skips the cleanup at the end. To tidy up by hand:

```bash
# close any leaked fixture rows (matched on the pane's cwd, not on a label)
herdr workspace list | jq -r '.result.workspaces[]?.workspace_id' | while read -r ws; do
  herdr pane list --workspace "$ws" \
    | jq -e '[.result.panes[]? | select((.cwd // "") | test("herdr-review-(rm-)?checks"))] | length > 0' \
    >/dev/null 2>&1 && herdr workspace close "$ws"
done

# prune the throwaway clones, then delete the fixtures
find "${TMPDIR:-/tmp}"/herdr-review-checks "${TMPDIR:-/tmp}"/herdr-review-rm-checks \
     -name .git -type d -printf '%h\n' 2>/dev/null |
  while read -r d; do git -C "$d" worktree prune; done
rm -rf "${TMPDIR:-/tmp}"/herdr-review-checks "${TMPDIR:-/tmp}"/herdr-review-rm-checks
```

## What is covered

`check-review-make.sh`

* the read-only `az` guard, positively and negatively
* work item HTML flattened to readable text; images named rather than dropped
* PR ids parsed out of artifact links, both `%2F` and `%2f`, build and commit
  links ignored, duplicates dropped
* folder naming: `{author}-{repo}`, spaces to underscores, no path separators
* one PR end to end: detached `HEAD` at the PR head, no local branch, no
  upstream, checkout clean, generated files kept outside it
* the context file: title, flattened description, diff commands, detached note
* the prompt: constraints first and unremovable, adversarial default, DevOps
  context appended, a repo-supplied prompt used but unable to lift the constraints
* the `Claude Review` command: one line, Fable model, non-editing permission mode,
  commit/push denied, deny list as one comma-joined argument so it cannot swallow
  the prompt, oversized prompts pointed at the file instead of truncated
* the sidebar: `Review` → `{id}` → `{author}-{repo}`, tab sets, connector tokens
  including the third-level indent that herdr's token trim used to eat
* sidebar **order**: a PR linked after the review was built is pulled back under
  its review instead of being left at the bottom, with the connectors redrawn from
  the new order — and a run with nothing new leaves the order alone. The scenario
  deliberately creates a second review first, so the first review's block is not
  already last and the assertion cannot pass by accident.
* idempotence (exit 3, rows reused)
* abandoned PRs skipped; a work item with no PRs refused rather than half-built

`check-review-remove.sh`

* the read-only `az` guard again, and that `completed` is the only finished status
  by default
* the owning clone read out of the worktree's own `.git`, not guessed
* `--dry-run` changes nothing
* a completed PR removed for real: folder gone, worktree deregistered, rows
  closed, **shared `Review` row left open**, clone untouched, no branch touched
* one PR still active holds the whole review — including the finished half
* a PR whose status cannot be read is **not** treated as finished
* `abandoned` ignored by default, honoured with `--include-abandoned`
* uncommitted changes hold a review back (exit 5) and survive; `--force-dirty`
  overrides and says so
* notes with content archived to `_notes/`, empty notes not archived,
  `--discard-notes` opts out
* scanning them all removes only the finished one and redraws the survivors'
  connectors
* a review whose PR index and work item are both unreadable is left alone; with
  only the index missing it re-derives from Azure DevOps
