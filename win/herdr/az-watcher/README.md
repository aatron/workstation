# `az-watcher` - Azure DevOps → herdr worktree sync (Windows)

Headless driver that keeps local story worktrees in step with Azure DevOps pull
requests. PowerShell port of `wsl/herdr/az-watcher/`. It does not reimplement any
worktree logic - it works out *what* should happen and then calls the same
`make-worktree.ps1` / `worktree-remove.ps1` you use by hand.

Two scenarios:

| Action | Trigger | Effect |
| --- | --- | --- |
| `new-review` | a PR was assigned to you as a reviewer within the window | creates a **review** worktree for that PR's repo + source branch |
| `remove-merged` | a PR you created **or** reviewed was completed/abandoned within the window | removes that repo's worktree, its local branch and its notes file; drops the story folder once no worktrees remain |

`run` (the default) does both.

Built for a recurring Task Scheduler job (or manual runs): non-interactive,
idempotent, and **stateless**. Overlapping runs are blocked with a `.NET`
exclusive lock on `%LOCALAPPDATA%\az-watcher\az-watcher.lock` (replaces Linux
`flock`).

## Prerequisites

`az` is **not** installed by `install.ps1`. Install the Azure CLI yourself, then:

```powershell
az login
az devops configure -d organization=https://dev.azure.com/<org> project='<project>'
```

Org and project come from those `az devops configure` defaults. Override per-run
with `AZDO_ORG` / `AZDO_PROJECT`.

## Usage

```
az-watcher.ps1 [new-review|remove-merged|run] [options]

  --window N      only act on PRs created/closed in the last N minutes
                  (default 5). N=0 disables the time filter.
  --dry-run       print the intended actions; create and remove nothing
  --force-dirty   allow removal of worktrees with uncommitted changes
  --me <identity> Azure identity to match (default: az account show)
```

Start here:

```powershell
az-watcher.ps1 run --dry-run --window 0
az-watcher.ps1 run --dry-run
az-watcher.ps1 run
```

From inside herdr: quick action **Sync Azure Reviews** runs `az-watcher.ps1 run`
in a visible tab.

## Story mapping / safety

Same rules as the WSL version: branch suffix `{id}-{slug}` preferred, else linked
work item id + title slug; Azure repo spaces → underscores; uncommitted changes
kept by default (`WT_SKIP_DIRTY=1`); quiet no-ops for already-present/already-gone
worktrees. See [`../../wsl/herdr/az-watcher/README.md`](../../wsl/herdr/az-watcher/README.md)
for the full narrative.

## Exit codes it relies on

| Script | 0 | 3 | 5 |
| --- | --- | --- | --- |
| `make-worktree.ps1` | created something | every requested worktree already existed | - |
| `worktree-remove.ps1` | removed something | nothing matched | nothing removed; all matches dirty |
