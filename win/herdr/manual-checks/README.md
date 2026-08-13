# manual-checks — run these on purpose, never automatically

These files check `review-make.ps1`, `review-remove.ps1` and `story-reap.ps1`. They
are **not** in `tests/` and are **not** named `test-*.ps1`, and that is deliberate.

## Why they are quarantined

The scripts they cover talk to **Azure DevOps**. Even though every call they make
is a read, a test suite that reaches a real work tracker is the wrong thing to
have sitting in a folder that some future runner — a CI job, a pre-commit hook,
an agent told to "run the tests" — might sweep up and execute unattended. The
naming and the location are the guard:

* not `tests/`, so a runner pointed at that folder finds nothing here
* not `test-*.ps1`, so a glob for test files does not match
* `check-*.ps1`, which no convention treats as automatically runnable

If you add a file here, keep both properties. If you ever move one of these into
`tests/`, you have removed the guard.

## What they actually touch

| | |
|---|---|
| **Azure DevOps** | **Nothing.** Both suites run the scripts against a **stub `az`** injected through `WT_REVIEW_AZ`. The stub serves canned JSON from a temp directory and logs every argument list it receives. There is no network call and no credential use anywhere in these files. |
| **git** | Throwaway bare repos and clones under `%TEMP%\herdr-review-checks\<pid>\`, `%TEMP%\herdr-review-rm-checks\<pid>\` and `%TEMP%\herdr-story-reap-checks\<pid>\`. Nothing under `~/source` is read or written. |
| **herdr** | The two review suites create workspaces in your **live** session and close them again. Cleanup matches on the fixture path, never on a workspace label, so your own rows cannot be caught by it. Each suite's last check asserts the workspace count is back to where it started. `check-story-reap.ps1` touches herdr **not at all** — see below. |
| **your files** | Nothing. No config, no notes, no repos. `HERDR_CONFIG_PATH` and `USERPROFILE` are pointed at fixture copies for the child process only. |

They do not just avoid writing to Azure DevOps — they **prove** the scripts
cannot. Both suites:

* assert `Test-AzReadOnly` rejects `boards work-item update`, `repos pr set-vote`,
  `repos pr update`, `repos pr reviewer add`, `devops invoke --http-method PATCH`,
  `--in-file`, `--body`, and friends
* assert `Invoke-AzRead` *throws* on such a call rather than running it, so the
  guard is wired into the call path and not merely available
* replay the stub's own call log through the guard afterwards, so a write that
  slipped through by some other route would still be caught

## Running them

All stub suites at once:

```powershell
cd win\herdr\manual-checks
powershell -NoProfile -ExecutionPolicy Bypass -File run-all.ps1
```

Or one at a time:

```powershell
cd win\herdr\manual-checks
powershell -NoProfile -ExecutionPolicy Bypass -File check-review-make.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File check-review-remove.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File check-story-reap.ps1
```

Exit 0 means everything passed; exit 1 prints the failures at the end. The two
review suites take a few minutes each, mostly waiting on herdr;
`check-story-reap.ps1` finishes in well under a minute.

### Live smoke against existing clones (opt-in)

`smoke-live-review.ps1` is **not** part of `run-all.ps1`. It calls real `az` and
your real `SRC_ROOT` clones. You must pass a work item id:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File smoke-live-review.ps1 23597
# optional: $env:WT_REVIEW_SRC_ROOT = "$env:USERPROFILE\source\repos"
```

Cleanup when finished: `review-remove.ps1 <id> --yes`.

**Start herdr first** for the two review suites. They create real workspaces, so
without a running session the herdr assertions fail for a reason that has nothing
to do with the code under test.

`check-story-reap.ps1` needs no herdr session and creates no workspace. On top of
the stub `az` it also replaces **`worktree-remove.ps1`** with a stub
(`WT_REMOVE_SCRIPT`) that only records the story id it was handed, so nothing is
ever deleted. What it checks is which stories `story-reap.ps1` *decides* to reap —
the removal itself is `worktree-remove.ps1`'s own business, covered by
`tests\test-worktree-remove.ps1`. Its lock file is redirected into the fixture
(`LOCALAPPDATA`) so a real scheduled run cannot make a check exit early.

Every `review-remove.ps1` invocation inside `check-review-remove.ps1` passes
`--yes`. Without it, `gum confirm` sits waiting for a keypress nobody is there to
give and the suite hangs.

## If a run is interrupted

Ctrl-C skips the cleanup at the end. To tidy up by hand:

```powershell
# close any leaked fixture rows
herdr workspace list | ConvertFrom-Json |
  ForEach-Object { $_.result.workspaces } |
  ForEach-Object {
    $cwds = (herdr pane list --workspace $_.workspace_id | ConvertFrom-Json).result.panes.cwd
    if ($cwds -match 'herdr-review-(rm-)?checks') { herdr workspace close $_.workspace_id }
  }

# prune the throwaway clones, then delete the fixtures
Get-ChildItem "$env:TEMP\herdr-review-checks","$env:TEMP\herdr-review-rm-checks" -Recurse -Filter '.git' -Force -ErrorAction SilentlyContinue |
  ForEach-Object { git -C $_.Directory.Parent.FullName worktree prune }
Remove-Item "$env:TEMP\herdr-review-checks","$env:TEMP\herdr-review-rm-checks" -Recurse -Force -ErrorAction SilentlyContinue
```

## What is covered

`check-review-make.ps1`

* the read-only `az` guard, positively and negatively
* work item HTML flattened to readable text; images named rather than dropped
* PR ids parsed out of artifact links, both `%2F` and `%2f`, build and commit
  links ignored, duplicates dropped
* folder naming: `{author}-{repo}`, spaces to underscores, no path separators
* one PR end to end: detached `HEAD` at the PR head, no local branch, no
  upstream, no commits added to the clone, checkout clean, generated files kept
  outside it
* the context file: title, flattened description, comments, diff commands
* the prompt: constraints first and unremovable, adversarial default, DevOps
  context appended, a repo-supplied prompt used but unable to lift the constraints
* the `Claude Review` command: one line, Fable model, non-editing permission mode,
  commit/push denied, deny list as one comma-joined argument so it cannot swallow
  the prompt, oversized prompts pointed at the file instead of truncated
* the sidebar: `Review` → `{id}` → `{author}-{repo}`, tab sets, connector tokens
  including the third-level indent that herdr's token trim used to eat, corner
  reassignment when a newer review arrives, and no duplicate rows
* sidebar **order**: a PR linked after the review was built is pulled back under
  its review instead of being left at the bottom, with the connectors redrawn from
  the new order — and a run with nothing new leaves the order alone. The scenario
  deliberately creates a second review first, so the first review's block is not
  already last and the assertion cannot pass by accident.
* idempotence (exit 3, rows reused, tabs not typed into again)
* abandoned PRs skipped; a work item with no PRs refused rather than half-built
* the head found by branch when the PR reports no merge commit
* rows left by the label-era version of the script adopted and renamed

`check-review-remove.ps1`

* the read-only `az` guard again, and that `completed` is the only finished status
  by default
* the owning clone read out of the worktree's own `.git`, not guessed
* `--dry-run` changes nothing
* a completed PR removed for real: folder gone, worktree deregistered, rows
  closed, **shared `Review` row left open**, clone untouched
* one PR still active holds the whole review — including the finished half
* a PR whose status cannot be read is **not** treated as finished
* `abandoned` ignored by default, honoured with `--include-abandoned`
* uncommitted changes hold a review back (exit 5) and survive; `--force-dirty`
  overrides and says so
* notes with content archived to `_notes\`, empty notes not archived,
  `--discard-notes` opts out
* scanning them all removes only the finished one and redraws the survivors'
  connectors
* a review whose PR index and work item are both unreadable is left alone; with
  only the index missing it re-derives from Azure DevOps
