# Plan: `az-watcher` — Azure DevOps → herdr worktree automation

> Status: **implemented** (2026-07-28). Code in `wsl/herdr/az-watcher/`; usage docs in
> `wsl/herdr/az-watcher/README.md`. Verified offline against stubbed `az`/`herdr` and in a
> real-git sandbox; **not yet run live against Azure**, so do
> `az-watcher run --dry-run --window 0` first.

## Context

The `wsl/herdr` workflow can create/remove story worktrees interactively (herdr-plus quick
actions → `worktree-make.sh` / `worktree-remove.sh`). This adds a **headless** driver,
`az-watcher`, that keeps local worktrees in sync with Azure DevOps PRs:

- **New Review** — when a PR has been assigned to me (I'm a reviewer) in the last ~5 minutes,
  create a **review** worktree for that PR's repo + source branch.
- **Remove story** — when a PR of mine (as creator *or* reviewer) has been completed/abandoned
  in the last ~5 minutes, remove that repo's local worktree, local git branch and notes file;
  when a story folder empties, remove the folder too.

For now it's run manually; **eventually a cron job every 5 minutes**, so everything must be
non-interactive, idempotent, and stateless (the laptop can reboot with no state to lose).

### Decisions (confirmed with the user)
- **Story id + slug come from the PR source branch** when its last segment looks like
  `<id>-<slug>` (`refs/heads/team/dev/22831-order-entry-forms` → `22831` +
  `order-entry-forms`). This costs no extra `az` call and already matches the folder
  names this workflow produces, because branch and folder share that suffix. **Fallback:** the
  PR's linked work item id, with the slug derived from its title by `slug_for_story()`
  (lowercase, hyphenated, first 4 words) — the single function to override. Removal reads the
  slug from the on-disk folder name, so it needs no Azure call at all.
- **New Review scope = just the assigned PR** (one repo/branch per assignment). PRs *I*
  created are skipped even when I'm listed as a reviewer — they already have a dev worktree.
- **Removal scope = creator PRs *and* reviewer PRs.** Reviewer PRs retire review worktrees;
  my own PRs retire the development worktrees they were raised from. (The original plan had
  reviewer-only, which would never have cleaned up a single one of the dev worktrees actually
  on disk.)
- **PRs with no story id at all** (no `<id>-<slug>` in the branch, no linked work item — e.g.
  PR 4322 `adr-005-central-api-modular-monolith`) are **skipped and notified**, through the
  same channel that announces a created review.
- **Notifications = `herdr notification show`**, best-effort: created / cleaned up / skipped /
  failed / held-back all notify *and* log. Quiet no-ops (worktree already exists, story
  already gone) log only, so a 5-minute cron never nags.
- **Repo name → clone dir = spaces become underscores** (`My Repo` →
  `~/source/repos/My_Repo`). No lookup table; a missing clone is reported, never guessed.
- **Auth = `az login`** + `az devops configure -d organization=… project=…` defaults (org/
  project also overridable via `AZDO_ORG`/`AZDO_PROJECT`). No PAT file.
- **"Last 5 minutes" is stateless:** New Review filters active reviewer-PRs by `creationDate`;
  Remove filters closed PRs by `closedDate`. `--window <min>` (default 5); **`--window 0`
  disables the filter** for a one-off backfill. Idempotency makes overlapping runs safe.
- **Uncommitted changes are kept, not deleted.** az-watcher passes `WT_SKIP_DIRTY=1`, so a
  dirty worktree survives (and keeps its story folder) and you are notified; `--force-dirty`
  overrides. Manual `worktree-remove.sh` behaviour is unchanged.

### Verified (Azure CLI, azure-devops extension, live against the real org)
- `az repos pr list --reviewer|--creator <me> --status active|completed|abandoned -o json` →
  PRs with `pullRequestId`, `title`, `status`, `sourceRefName`, `repository.name`,
  `creationDate`, `closedDate`, `createdBy.uniqueName`. Sorted newest-first, so `--top N`
  yields the most recent N.
- `az repos pr work-item list --id <pr> -o json` → linked work item id(s); **can be empty**.
- `az boards work-item show --id <id> --query "fields.\"System.Title\"" -o tsv` → title→slug.
- `az account show --query user.name -o tsv` → signed-in user (default `--reviewer` value).
- **WSL gotcha:** `az` may resolve to the Windows build under `/mnt/c`. It emits CRLF and
  tries to encode output as cp1252, which *silently truncates* JSON containing non-ASCII.
  Every call therefore goes through a wrapper that sets `PYTHONIOENCODING=utf-8` and strips CR.
- **`az` reads stdin.** Calling it inside a `while read` loop makes it swallow the rest of the
  loop's input, so the loop stops after the first PR needing an az lookup. Found in the first
  live dry-run (1 of 4 PRs processed). Both loops now read from **fd 4**, and `az` plus the two
  driven scripts get an explicit `</dev/null`.

## New: `wsl/herdr/az-watcher/`

```
az-watcher/
  az-watcher.sh     # entry point (new-review + remove-merged), non-interactive
  README.md         # usage, az prereqs, manual run, cron instructions
```

### `az-watcher.sh`
- **Config / prereqs:** requires `az` (with `azure-devops` ext), `git`, `jq`, `flock`; herdr
  for creation. Reads optional env `AZDO_ORG`, `AZDO_PROJECT`, `AZ_WATCHER_ME`. Adds
  `--org/--project` to az calls only when set.
- **CLI:** `az-watcher [new-review|remove-merged|run] [--window N] [--dry-run] [--force-dirty]
  [--me <id>]`. Default `run` = both.
- **Locking:** `flock -n -E 99` on `${XDG_RUNTIME_DIR:-/tmp}/az-watcher.lock`, taken by
  re-exec before argument parsing; a run that finds it held logs and exits 0.
- **Logging:** timestamped lines on fd 3 (a dup of the real stdout), so log output can never
  contaminate the stdout of a function whose output is being captured.
- **new-review:** active reviewer PRs → drop mine → window filter → resolve story → verify the
  local clone exists → write a one-line `repo:branch` file → `WT_ID WT_SLUG WT_BRANCHES_FILE
  make-worktree.sh review`. Exit 3 from that script means "already existed" and stays silent.
  Bails out early (with a notification) when no herdr session is running.
- **remove-merged:** creator+reviewer × completed+abandoned, deduplicated by PR id → window
  filter → resolve story → `WT_ID WT_REPO WT_ASSUME_YES=1 WT_SKIP_DIRTY=1
  worktree-remove.sh`. Exit 3 = nothing local (silent), 5 = dirty (notify).

## Modifications to existing scripts (small, additive)

### `wsl/herdr/worktree-make.sh` — non-interactive hooks + idempotency
- `NONINTERACTIVE=1` when `WT_ID` and `WT_SLUG` are both set. When set: skip the tty-reattach
  block and `gum`; take `ID=$WT_ID`, `SLUG=$WT_SLUG`; dev repos from `WT_REPOS`; review
  branches from `WT_BRANCHES_FILE` (skipping the placeholder heredoc/warning).
- **Idempotency guard** (`worktree_present`): if `${STORY_DIR}/${repo}/.git` exists, log
  "exists, skipping" and return — no fetch, no herdr call, no tab churn.
- **Per-repo failures are non-fatal** in non-interactive mode (`repo_fail`), so one bad repo
  cannot abort a cron run; still fatal when a human asked for those exact repos.
- **Exit 3** when nothing was created but something already existed, so automation can tell a
  no-op re-run apart from real work or a failure.

### `wsl/herdr/worktree-remove.sh` — non-interactive + single-repo + dirty guard
- `WT_ID` / `WT_ASSUME_YES` / `${ID}-*` globbing were already in place.
- `WT_REPO` set ⇒ operate on **only** that repo's worktree (worktree + local branch + that
  repo's `${ID}-${SLUG}-${repo}.txt` and `.notespath-${repo}`). Unset ⇒ whole story.
- `WT_SKIP_DIRTY=1` ⇒ refuse to delete a worktree with uncommitted/untracked changes.
- **The story folder is deleted only once no worktrees remain in it** (`story_has_worktrees`),
  which is what makes single-repo removal and dirty-keeps correct for multi-repo stories.
- **Exit codes:** 0 removed something, 3 nothing matched, 5 nothing removed because every
  match was dirty.

### `wsl/herdr/worktree-launch.sh` — manual trigger from herdr
- `az-sync` action → `~/bin/az-watcher run`, label "Sync Azure Reviews".

### `wsl/herdr/az-watcher.toml` (new quick action)
- `name = "Sync Azure Reviews"`, `command = '"$HOME/bin/worktree-launch.sh" az-sync
  {{.WorkspaceId}} "{{.WorkDir}}"'`.

### `wsl/herdr/install.sh`
- `normalize_shell_script` + symlink `az-watcher/az-watcher.sh` → `~/bin/az-watcher`.
- `install_file` `az-watcher.toml` into herdr-plus `quick-actions/` (and exempt it from
  `fix_example_openers`).
- Azure prereq step in the "Manual next steps" echo (no auto-install of `az`); `az` and
  `flock` added to the closing CLI check.

### Docs
- `az-watcher/README.md` — prereqs, usage, story-naming rules, notifications, safety, cron
  line, assumptions, and the exit-code contract it relies on.
- `wsl/herdr/README.md` — "Azure sync (`az-watcher`)" section + two Daily-use bullets.

## Verification performed
1. `bash -n` on `az-watcher.sh` and the four edited scripts; grepped for username literals
   (none outside the pre-existing `BRANCH_PREFIX`).
2. **Offline unit check** — stubbed `az`/`herdr`/make/remove on `PATH` with canned JSON
   modelled on the real API responses. Confirmed: branch-derived ids, work-item fallback
   (`23346-user-identity-sync`), no-id PR skipped **and notified**, own PR excluded from
   review, window filter and `--window 0`, dedup across roles/statuses, exit-3 silence,
   exit-5 held-back notification, and the exact `WT_*` env handed to each script.
3. **Real-git sandbox** for the hooks themselves (`HERDR_CONFIG_PATH` + stub herdr whose
   `worktree create` really runs `git worktree add`): non-interactive review creation with
   stdin closed; second run → exit 3; dirty repo with `WT_SKIP_DIRTY=1` → exit 5, nothing
   removed; single-repo removal → only that repo goes, branch deleted, folder kept; repeat →
   exit 3; last repo removed → folder removed; unknown story → exit 3.
4. **Live dry-run against the real org** (read-only; creates, removes and notifies nothing).
   `run --dry-run --window 0`: all 4 active reviewer PRs resolved (including the work-item
   fallback `23376-passwordless-redis-service` for the id-less branch
   `feat/connection-string-credentials`), PR 4322 correctly skipped; on the removal side 100
   closed PRs deduped, 94 resolved to stories, 6 skipped for want of an id.
   `run --dry-run` at the default 5m window: correctly silent. This is also where the stdin bug
   above surfaced, and the run was repeated after fixing it.
5. **Still to do (live, for real):** `az-watcher run`. Then assign yourself a test PR →
   `new-review` creates the review worktree (tabs notes/claude/cursor/bash); complete/abandon
   it → `remove-merged` tears it down within a window.
6. **Not yet done:** `install.sh` has not been re-run, so `~/bin/az-watcher` and the
   **Sync Azure Reviews** quick action are not installed on this machine yet.

## Notes / assumptions / limitations
- **herdr session must be running** for creation; az-watcher detects this and notifies rather
  than failing. Removal needs no session (git fallback).
- **Stateless windowing trade-off:** New Review keys on PR `creationDate`, so being added as a
  reviewer to an *older* PR isn't detected. Accepted per "keep it simple, no state";
  `--window 0` backfills and the idempotency guard prevents duplicates.
- Removal only ever deletes **local** branches/worktrees/notes; remote branches and others'
  work are untouched. `--dry-run` shows exactly what would go.
- Multiple PRs for one story in the same repo collide on `{story}/{repo}`: first wins, second
  is a no-op — same limitation `worktree-make.sh` documents for manual runs.
- **No silent caps:** each query fetches at most `PR_TOP` (50) PRs newest-first. If a page comes
  back full *and* its oldest entry is still inside the window, a `note:` line says older PRs
  were not examined. Unreachable at a 5-minute window, so cron logs stay quiet.
- **`--window 0` is a big hammer for `remove-merged`** — it considers every closed PR (~100
  here) and so cleans up every local story whose PR has ever closed. Harmless for
  `new-review`. Dry-run it first; the dirty guard is the backstop.
- `az boards`/`az repos` are part of the `azure-devops` extension (auto-installs on first use).
