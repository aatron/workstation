# `az-watcher` — Azure DevOps → herdr worktree sync

Headless driver that keeps local story worktrees in step with Azure DevOps pull
requests. It does not reimplement any worktree logic — it works out *what*
should happen and then calls the same `make-worktree.sh` / `worktree-remove.sh`
you use by hand, so tabs, notes, agents, branches and folders all come out
identical to a manual run.

Two scenarios:

| Action | Trigger | Effect |
| --- | --- | --- |
| `new-review` | a PR was assigned to you as a reviewer within the window | creates a **review** worktree for that PR's repo + source branch |
| `remove-merged` | a PR you created **or** reviewed was completed/abandoned within the window | removes that repo's worktree, its local branch and its notes file; drops the story folder once no worktrees remain |

`run` (the default) does both.

Built for `*/5 * * * *` cron: non-interactive, idempotent, and **stateless** —
nothing is remembered between runs, so a reboot loses nothing. The only "state"
is the PR timestamps in Azure.

## Prerequisites

`az` is **not** installed by `install.sh`. Install the Azure CLI yourself, then:

```bash
az login
az devops configure -d organization=https://dev.azure.com/<org> project='<project>'
```

The `azure-devops` extension auto-installs the first time `az repos` / `az boards`
runs. `git`, `jq` and `flock` are also needed; `install.sh` reports all of these
in its closing CLI check.

Org and project come from those `az devops configure` defaults. Override per-run
with `AZDO_ORG` / `AZDO_PROJECT` (passed through as `--org` / `--project`).

> **WSL note.** If `az` resolves to the Windows build under `/mnt/c`, it emits
> CRLF and tries to encode output as cp1252 — which silently truncates JSON
> containing non-ASCII characters. az-watcher sets `PYTHONIOENCODING=utf-8` and
> strips CR on every call, so this is already handled.

## Usage

```
az-watcher [new-review|remove-merged|run] [options]

  --window N      only act on PRs created/closed in the last N minutes
                  (default 5, matching the cron interval). N=0 disables the
                  time filter — use it for a one-off backfill.
  --dry-run       print the intended actions; create and remove nothing
  --force-dirty   allow removal of worktrees with uncommitted changes
                  (default: keep them and notify)
  --me <identity> Azure identity to match (default: az account show)
```

Start here, and read the output before running for real:

```bash
az-watcher run --dry-run --window 0      # everything currently open/closed
az-watcher run --dry-run                 # just the last 5 minutes
az-watcher run
```

> **`--window 0` is a big hammer for `remove-merged`.** It considers *every*
> closed PR it can see (~100 on this org), so it will clean up every local story
> whose PR has ever closed — not just recent ones. Stories you no longer have on
> disk are silent no-ops and worktrees with uncommitted changes are kept, but do
> read the `--dry-run` list first. `new-review --window 0` is harmless by
> comparison: it only backfills review worktrees for PRs still assigned to you.
>
> Each query fetches at most `PR_TOP` (50) PRs, newest first. If a query comes
> back completely full, az-watcher logs a `note:` line saying older PRs were not
> examined — it never truncates silently. At the default 5-minute window this
> cannot bite.

From inside herdr: quick action **Sync Azure Reviews** (`az-watcher.toml` →
`worktree-launch.sh az-sync`) runs `az-watcher run` in a visible tab.

## How a PR becomes a story folder (`{id}-{slug}`)

1. **The PR source branch**, when its last segment looks like `<id>-<slug>`:

   ```
   refs/heads/team/dev/22831-order-entry-forms
     -> review/22831-order-entry-forms
   refs/heads/feature/<you>/23334-cancel-posted-spot-rate
     -> development/23334-cancel-posted-spot-rate
   ```

   Free (no extra `az` call) and it matches the folder names this workflow
   already produces, because branch and folder share that suffix.

2. **The PR's linked work item**, when the branch carries no id — the id comes
   from `az repos pr work-item list`, the slug from the work item title via
   `slug_for_story()` (lowercase, hyphenated, first 4 words):

   ```
   refs/heads/feature/<author>/user-identity-sync   -> work item 23346
     title "User identity sync (Phase A): ..."
     -> review/23346-user-identity-sync
   ```

   `slug_for_story()` is the single function to edit if you want a different
   naming rule. Keep it deterministic: two PRs of one story in different repos
   must resolve to the same folder.

3. **Neither** — the PR is skipped and you get a notification saying so. Some
   PRs have no id in the branch and no linked work item at all.

**Repo names.** The Azure repo name maps to the local clone directory by
replacing spaces with underscores: `My Repo` → `~/source/repos/My_Repo`.
Everything else must match by name. A missing clone is reported, never guessed.

## Notifications

Anything worth knowing about goes to `herdr notification show` *and* the log:
review created, story cleaned up, PR skipped for want of a story id, action
failed, cleanup held back over uncommitted changes. Quiet no-ops — a worktree
that already exists, a story already gone — are logged only, so a five-minute
cron never nags. Notifications are best-effort: with no herdr session up they
are logged and dropped.

## Safety

* **Creation is idempotent.** An existing worktree is left completely alone: no
  fetch, no herdr call, no tab churn, no notification. Overlapping runs are safe.
* **Removal is local-only.** Worktrees, local branches, notes and story folders.
  Remote branches and other people's work are never touched.
* **Uncommitted changes are kept by default.** az-watcher passes
  `WT_SKIP_DIRTY=1`, so a worktree with uncommitted or untracked changes is left
  in place — and its story folder with it — and you get a notification. Pass
  `--force-dirty` to delete anyway. A manual `worktree-remove.sh` is unaffected
  (it has its own confirmation prompt).
* **One at a time.** `flock` on `$XDG_RUNTIME_DIR/az-watcher.lock`; a run that
  finds the lock held logs and exits 0.
* **A single bad PR cannot derail a run.** Per-PR failures are logged, notified
  and stepped over.

## Cron (once you trust it)

```cron
*/5 * * * * $HOME/bin/az-watcher run >> $HOME/.local/state/az-watcher.log 2>&1
```

`mkdir -p ~/.local/state` first. az-watcher already takes its own `flock`, so no
wrapper is needed. Cron has a minimal environment — if `az` or `herdr` is not on
the default `PATH`, set `PATH` at the top of the crontab.

## Assumptions and limitations

* **A herdr session must be running for `new-review`** (`herdr worktree create`
  plus herdr-plus auto-layout do the work). Without one, az-watcher logs, sends
  a notification, and leaves `new-review` for the next run. `remove-merged`
  needs no session — it falls back to `git worktree remove`.
* **`new-review` keys on the PR's `creationDate`.** Being added as a reviewer to
  an *older* PR is therefore not detected. That is the price of holding no
  state; `--window 0` backfills anything missed, and the idempotency guard means
  running it costs nothing for worktrees you already have.
* **The window should match the cron interval.** Overlap is harmless
  (idempotent creation, exit-3 no-op removal); a gap means missed PRs.
* **Multiple PRs for one story in the same repo** collide on
  `{story}/{repo}` — the first wins and the second is a no-op. Rare, and
  `worktree-make.sh` documents the same limitation for manual runs.
* **A story folder disappears when its last worktree does**, not when the story
  closes in Azure. Cleanup is per-PR, per-repo, which is what makes multi-repo
  stories work.

## Exit codes it relies on

az-watcher distinguishes real work from no-ops using the exit codes of the two
scripts it drives — this is what keeps cron quiet:

| Script | 0 | 3 | 5 |
| --- | --- | --- | --- |
| `worktree-make.sh` | created something | every requested worktree already existed | — |
| `worktree-remove.sh` | removed something | nothing matched | nothing removed; all matches dirty |
