# Herdr set-up (Windows)

Native Windows PowerShell port of the WSL Herdr + herdr-plus workflow for
multi-repo story worktrees (dev and review). Bash source of truth lives in
[`wsl/herdr/`](../../wsl/herdr/).

> **Diverged from `wsl/herdr/`.** The Windows scripts are now **task-centric**:
> the story is the root row in the sidebar, with one indented row per repo under
> it. The bash scripts are still repo-centric (one workspace per repo worktree,
> nested under its clone).
> See [Story navigation](#story-navigation-the-task-is-the-root-item).
>
> The Windows side also adds a read-only **code review** flow with no bash
> counterpart: `review-make.ps1` / `review-remove.ps1`. See
> [Code review](#code-review-review-makeps1--review-removeps1).

> **Windows beta.** Plugins are **preview**; `herdr --remote` is unsupported.
> See [Windows beta](https://herdr.dev/docs/windows-beta/).

## Installation

```powershell
cd C:\path\to\workstation\win\herdr
.\install.ps1
```

Idempotent. Installs herdr (≥ 0.7.5) + CLIs, creates `%APPDATA%\herdr\config.toml` **only if missing** (never overwrites an existing one), installs plugins, shims scripts into `%USERPROFILE%\bin`, and copies quick actions + `worktree-layout.toml`.

Then do the edits below.

## Values you must change

Placeholders are not defaults. Edit the repo copies under `win\herdr\` (shims point here).

### Scripts (`EDIT THESE FOR YOUR MACHINE`)

| File | Variable | Change to |
|------|----------|-----------|
| `worktree-make.ps1` | `$SRC_ROOT` | your primary clones dir, e.g. `$env:USERPROFILE\source\repos` |
| `worktree-make.ps1` | `$BRANCH_PREFIX` | e.g. `feature/jsmith` (ships as `feature/YOU`) |
| `review-make.ps1` | `$SRC_ROOT` | same as above |
| `review-make.ps1` | `$REVIEW_MODEL` | e.g. `claude-fable-5` |
| `review-make.ps1` | `$REVIEW_PERMISSION_MODE` | leave `plan` (read-only reviews) |

Clones must already exist at `$SRC_ROOT\<repo>` (`origin` + default branch). Azure repo spaces → underscores (`My Repo` → `My_Repo`).

### `%APPDATA%\herdr\config.toml`

Created by install when missing. Merge these by hand (install never does), then `herdr config check` and `herdr server reload-config`:

```toml
[worktrees]
directory = "C:\\Users\\<you>\\source\\worktrees"

[ui.sidebar.spaces]
rows = [["$tree", "state_icon", "workspace"]]
```

Also add herdr-plus keybinds with the **`-windows`** action ids (`prefix+up` / `prefix+down`) — see [Herdr Plus keybinds (Windows)](#herdr-plus-keybinds-windows).

### Azure DevOps (reviews / az-watcher / story-reap)

`az` is not installed by `install.ps1`:

```powershell
az login
az devops configure -d organization=https://dev.azure.com/<org> project='<project>'
```

## Herdr settings (manual `config.toml`)

`install.ps1` only writes a default `config.toml` when the file is missing; it
never merges the snippets below. Edit by hand:

```powershell
micro $env:APPDATA\herdr\config.toml
```

### Worktree directory

```toml
[worktrees]
directory = "C:\\Users\\<you>\\source\\worktrees"
```

### Sidebar rows (required for the story and review trees)

The one setting the worktree workflow genuinely depends on. `$tree` **must come
before `state_icon`**, or the nested rows get no connector and their bullets stay
hard against the left edge:

```toml
[ui.sidebar.spaces]
# $tree is reported per workspace by worktree-make.ps1 and review-make.ps1: the
# connector drawn under a story row for each of its repos, and under Review for
# each review. It must come BEFORE state_icon, or the bullet stays hard against
# the left edge and only the label indents.
rows = [["$tree", "state_icon", "workspace"]]
```

Apply with:

```powershell
herdr config check          # expect: config: ok
herdr server reload-config  # expect: "status":"applied"
```

Rows already created keep whatever they had — re-run `make-worktree.ps1` or
`review-make.ps1` to have the tokens reported. Full rationale in
[Drawing the connectors](#drawing-the-connectors).

> Avoid adding a `branch` / `git_status` second row here: a story row spans
> several repos, so it has no single branch to show.

#### The dot between the connector and the bullet

herdr joins the segments of a sidebar row with its own `·` and offers **no**
setting to change it — not at `[ui]`, `[ui.sidebar]` or `[ui.sidebar.spaces]`, and
a row element's object form only accepts `token` / `bold` / `dim` / `fg`. So a
nested row renders as:

```
  ├─ · ● 23597
```

That dot is accepted deliberately. The only way to remove it is to drop `$tree`
and put the connector in the workspace **label** instead — labels are a single
segment, so nothing is inserted — but then `state_icon` is first again and the
status bullet is pinned to the far left, outside the tree:

```
● ├─ 23597
```

Both were tried. Keeping the **live** status bullet inside the tree, where it
reads as belonging to the nested row, is worth one dot; a frozen bullet drawn into
the label would put the geometry right and throw away the only thing the bullet is
for. If you disagree, both scripts have the connector in one place
(`$TREE_BRANCH` / `$TREE_TEE`) — but do not "fix" it without reading the comment
block there first.

### Herdr Plus keybinds (Windows)

On Windows, herdr-plus exposes **platform-specific** action ids. The Linux/macOS
ids (`cloudmanic.herdr-plus.projects` / `...quick-actions`) are filtered to
`linux`/`macos` only. Use the `-windows` variants:

```toml
[[keys.command]]
key = "prefix+up"
type = "plugin_action"
command = "cloudmanic.herdr-plus.projects-windows"
description = "herdr-plus: projects"

[[keys.command]]
key = "prefix+down"
type = "plugin_action"
command = "cloudmanic.herdr-plus.quick-actions-windows"
description = "herdr-plus: quick actions"
```

If your existing config still binds the non-`-windows` ids, prefix+up/down will
not open the pickers on native Windows until you update them. `install.ps1` does
**not** rewrite your root `config.toml`.

Verify:

```powershell
herdr plugin action list --plugin cloudmanic.herdr-plus
herdr plugin action invoke projects-windows --plugin cloudmanic.herdr-plus
herdr plugin action invoke quick-actions-windows --plugin cloudmanic.herdr-plus
```

### Accent colour (the selected sidebar row)

herdr paints the selected sidebar row — **including its state icon** — in the
accent colour. The default is pink `#f5c2e7`, which reads as the icon turning
magenta whenever you select a nested review or repo row. There is no way to exempt
just the icon: `ui.selected_fg`, `ui.selection_accent`, `ui.sidebar.selected_fg`,
`ui.sidebar.accent` and `ui.sidebar.spaces.selected_fg` are all rejected as unknown
keys, so the accent itself is the only lever. White — **set it in both places**:

```toml
[theme.custom]
accent = "#ffffff"

[ui]
accent = "#ffffff"
```

These are two different settings that happen to share a name. `[theme.custom]
accent` overrides the accent **token** in the active theme; `[ui] accent` is the
colour herdr uses for "highlights, borders, and navigation UI", which is what the
selected sidebar row is drawn with. Setting only the theme token leaves a selected
row's state icon magenta.

```powershell
herdr config check          # expect: config: ok
herdr server reload-config  # expect: "status":"applied"
```

**Reloading is not optional.** Editing `config.toml` changes nothing in a running
session — the server holds the config it started with. If the accent still looks
wrong after an edit, run `reload-config` before assuming the key is wrong. On a
named session the bare command misses: use `herdr --session <name> server
reload-config` (plain `herdr server reload-config` only reaches `default`).
Confirm which sessions exist with `herdr session list`.

> **`accent` is valid under `[theme.custom]` and `[ui]`.** It is **not** valid
> under `[ui.sidebar.spaces]`; herdr's own default config prints its `# accent =
> "cyan"` documentation *after* the `[ui.sidebar.spaces]` block even though the key
> belongs to `[ui]`, so it ends up stranded inside that table once you add a `rows`
> line — and uncommenting it there silently does nothing. `herdr config check`
> reports it as `unknown config key ui.sidebar.spaces.accent`.

The alternative — pinning the icon's colour with
`{ token = "state_icon", fg = "..." }` — stops it reacting to selection but also
stops it reacting to **agent state**, so `working` / `blocked` / `idle` / `done`
all render alike. Not worth it; the accent is the right knob.

### Theme / navigation / reviewr / Agent Usage

Same snippets as the WSL README (`wsl/herdr/README.md`): theme, nav keys,
`persiyanov.reviewr.toggle`, Agent Usage sidebar rows, toast delivery. Config
path on Windows is `%APPDATA%\herdr\config.toml` (not `~/.config/herdr/`).

reviewr plugin config dir:

```powershell
herdr plugin config-dir persiyanov.reviewr
```

Manual reviewr invoke:

```powershell
herdr plugin action invoke toggle --plugin persiyanov.reviewr
```

### Plugin platform caveats (Windows beta)

`herdr-plus` ships Windows-native actions (`*-windows`). **Agent Usage** (`usagebar`)
and **reviewr** currently declare `platforms = ["macos","linux"]` only — their
`bash …` action commands will not run on native Windows until those plugins add
Windows variants. They still install; seeding/toggling from Windows may need WSL
or a future plugin update.

Seed Agent Usage when a Windows action exists (or from WSL):

```powershell
herdr plugin action invoke usagebar.setup
```

## Story navigation: the task is the root item

The story folder on disk has always been task-first:

```
<worktrees.directory>\development\{id}-{slug}\
    repo1\                      git worktree
    repo2\                      git worktree
    {id}-{slug}-repo1.txt       notes, one per repo
    {id}-{slug}-repo2.txt
```

herdr's sidebar used to read the other way round, because it groups workspaces
by their source repository (`worktree.repo_key`) and nests linked worktrees under
their primary clone — grouping that is built in, with no config for it:

```
repo1
  {id}-{slug}
repo2
  {id}-{slug}
```

A story across four repos was therefore four unrelated rows in four different
groups. `herdr worktree create --workspace <ID>` is not a way out: `--workspace`
and `--cwd` are mutually exclusive, and `--workspace` only says which workspace
to take the *source repo* from — it still creates a workspace of its own.

So `worktree-make.ps1` adds the worktrees with plain `git worktree add` and builds
the rows itself. A workspace with no worktree metadata is not grouped at all, so
the sidebar now reads task-first, matching the folders — a story row with one row
per repo drawn beneath it:

```
● {id}-{slug}                 cwd = the story folder
  ├─ ● repo1                  cwd = {id}-{slug}\repo1
  └─ ● repo2                  cwd = {id}-{slug}\repo2
● {other-id}-{other-slug}
  └─ ● repo1
```

**The connectors need one line in `config.toml`** — see
[Drawing the connectors](#drawing-the-connectors) below. Without it you still get
the rows, just with the bullets hard against the left edge.

### Tabs

The **story row** carries four tabs at the story root, where one agent sees every
repo in the story at once (`cd repo1` from any of them):

| Tab | Command |
|-----|---------|
| notes | `micro <notes file of the first repo requested>` |
| claude | `claude --permission-mode auto` |
| cursor | `agent --auto-review` |
| pwsh | bare PowerShell |

Each **repo row** carries three tabs at that repo's worktree root:

| Tab | Command |
|-----|---------|
| notes | `micro <that repo's own notes file>` |
| claude | `claude --permission-mode auto` |
| pwsh | bare PowerShell |

Repos are discovered by scanning the story folder for worktrees, so a repo added
to an existing story picks up its own row on the next run. Re-running reuses every
row it already has, creates only the tabs that are missing, and starts commands
**only in tabs it just created** — a tab you are already working in is never typed
into.

### Drawing the connectors

A sidebar row is built from the token list in `[ui.sidebar.spaces].rows`, and the
default puts `state_icon` first — so **every bullet sits hard against the left
edge**, and indenting a workspace's *label* only shifts the text after it:

```
● {id}-{slug}
●   repo1                   <- label indented, bullet is not
```

The fix is to render something *before* the icon. herdr supports custom
per-workspace tokens (`$name`, the same mechanism as the documented
`$jj_status`), so `worktree-make.ps1` reports a `tree` token — `├─` on each repo
row, `└─` on the last, nothing on the story row (an absent token renders as
nothing), each behind two blank columns so the connector sits *inside* its parent
instead of flush under the parent's own bullet. Putting `$tree` first in the row
spec then indents the bullet itself:

```toml
[ui.sidebar.spaces]
rows = [["$tree", "state_icon", "workspace"]]
```

`install.ps1` never rewrites the root `config.toml`, so this is a manual edit —
see [Sidebar rows](#sidebar-rows-required-for-the-story-and-review-trees) for the exact block
and how to apply it. `worktree-make.ps1` reads `config.toml`, notices when the
token is not configured, keeps using the old label indent, and prints the snippet
so you are never left in a silent half-state.

Connectors are re-reported on every run, so the repo that used to be last gives
up its corner when you add another one. They are set from char codes in the
script (`$TREE_BRANCH` / `$TREE_LAST`) rather than typed literally, because
Windows PowerShell 5.1 reads a `.ps1` as ANSI unless it has a BOM. Swap them for
`|-` and `` `- `` if your terminal font has no box-drawing glyphs.

herdr also inserts a `·` between the connector and the bullet, which nothing can
turn off — see [the dot](#the-dot-between-the-connector-and-the-bullet) for why
that was accepted rather than worked around.

**herdr trims leading whitespace off a token value.** A plain space is stripped,
and so is `U+00A0`. Every indent in these tokens therefore leads with `U+2800`
(braille blank — blank on screen, but not whitespace to a trimmer) and uses
ordinary spaces after it, since interior spaces survive. Two things depend on it:

* `$TREE_INDENT` — the two blank columns in front of every nested connector, so it
  sits inside its parent instead of flush under the parent's own bullet
* `$TREE_GAP` — the blank columns under a review with nothing after it, in the
  three-level review tree

Written with plain spaces both are silently eaten: the connectors snap back to the
left edge, and the review tree's third level collapses onto its second. The checks
assert token **lengths** as well as values for exactly this reason — the failure
mode is missing blanks, not a wrong glyph. If `U+2800` renders as a box in your
font, set `$TREE_INDENT = ''` and `$TREE_GAP = $TREE_PIPE`: you lose the indent and
the trunk runs one row long, but everything renders.

### The nesting is still cosmetic

herdr has no parent/child workspaces — its sidebar is a flat list of spaces, and
the only automatic grouping is the repo grouping described above. The connectors
draw the relationship; they do not create one. In particular:

* **Adjacency is maintained explicitly.** A new workspace is always appended to
  the end of the sidebar, so a repo added to a story that already exists would
  land at the bottom, far from its story row. Both `worktree-make.ps1` and
  `review-make.ps1` fix that up on every run by re-gathering the group — see
  [Keeping a group together](#keeping-a-group-together) below.
* Nothing stops you closing a story row and leaving its repo rows behind; they
  are independent spaces. `worktree-remove.ps1` closes all of them together.

### Keeping a group together

Reordering is **not** exposed by the `herdr workspace` CLI (its subcommands are
only list/create/get/focus/rename/report-metadata/close), so `Set-SidebarOrder`
— identical in `worktree-make.ps1` and `review-make.ps1` — talks to the API
socket directly.

On Windows the socket is a **named pipe whose name is the socket file's own
path** — `\\.\pipe\%APPDATA%\herdr\herdr.sock`. The regular file at that path
holds `<server-pid>:<token>`, but the protocol never asks for the token: requests
are plain newline-delimited JSON, and the pipe's ACL is the access control. So a
one-line request is enough, with no dependency beyond .NET's
`NamedPipeClientStream`:

```powershell
{"id":"x","method":"workspace.move","params":{"workspace_id":"wWC","insert_index":14}}
```

**Why `workspace.move` and not `workspace.move_block`.** The newer method takes a
whole ordered list plus an anchor and would do this in one call — but it only
exists from **protocol 18**. This machine runs a 0.7.5 *preview* (protocol 18);
the WSL side runs plain 0.7.5 (**protocol 17**), which rejects it outright with
`unknown variant "workspace.move_block"`. Using the older, narrower call on both
sides means the two behave identically instead of the ordering silently doing
nothing on whichever machine is behind. If you ever drop support for protocol 17,
`move_block` is the tidier call.

Semantics worth knowing, all verified against a live server:

* `insert_index` is **0-based and absolute**: the workspace is removed from the
  list and re-inserted so that it ends up *at* that index in the result.
* A workspace's `number` in `workspace list` is its **current sidebar position**,
  not its creation order — herdr renumbers on every move. That is why
  `review-make.ps1` re-reads the list between ordering and drawing connectors.

`Set-SidebarOrder` anchors the run at the slot its **topmost** member already
occupies, then places each member in turn, simulating the resulting list between
moves so the next index is right without another round trip. It compares against
the current order first and skips the whole thing when nothing needs to change,
and every failure is swallowed — an older herdr, an unreachable socket, a pipe it
cannot open. The rows are still correct; only their order would suffer.

> Resolve the socket from herdr's own directory, **not** from
> `HERDR_CONFIG_PATH`. That variable names a config *file*, which can live
> anywhere (the check harness points it at a fixture), while the socket always
> sits in `%APPDATA%\herdr` — or in `%APPDATA%\herdr\sessions\<name>` when
> `HERDR_SESSION` is set. herdr's CLI resolves it the same way, which is why
> every `herdr` command still works when the config path is pointed elsewhere.

> Read the pipe with `BeginRead` + `WaitOne`, not `ReadTimeout`. A pipe stream in
> byte mode throws `Timeouts are not supported on this stream`, and a plain
> blocking `Read` would hang the script against an unresponsive server.

If you would rather not rely on that, the alternative is one tab per repo inside
the single story workspace (`repo1 claude`, `repo2 claude`, …) — real containment,
but the grouping then only shows in the agent panel, not the space list.

### What this gives up

Story and repo workspaces are not registered with herdr as worktrees, so:

* `herdr worktree remove` / the worktree picker do not see them.
  `worktree-remove.ps1` closes every row of the story and uses `git worktree
  remove` instead (it still handles the old per-repo workspaces of existing
  stories).
* [`worktree-layout.toml`](worktree-layout.toml) no longer fires for them. It is
  still installed and still correct for worktrees opened through herdr's own UI.
* `branch` / `git_status` sidebar tokens are blank on a story row — there is no
  single branch for a four-repo story. (They would work on a repo row, but the
  same layout applies to every space.) Keep the one-row layout — see
  [Drawing the connectors](#drawing-the-connectors) for the exact `rows` value.

The checkouts themselves are ordinary git worktrees, unchanged.

## Code review: `review-make.ps1` / `review-remove.ps1`

A different shape from a story worktree, and a different purpose: given an Azure
DevOps **work item id**, find the pull requests linked to it, check each one out
locally, and open an agent on it that produces findings and nothing else.

```powershell
review-make.ps1 23597        # or: prefix+down -> New Code Review
review-remove.ps1 --dry-run  # or: prefix+down -> Clean Up Finished Reviews
```

> **Not** `make-worktree.ps1 review`. That one is branch-driven: you hand it a
> `<repo>:<branch>` list and it builds a story worktree you can commit on - and
> az-watcher is now its only caller, since the quick action for it was retired.
> This is work-item-driven, read-only, and every review lives under one shared root.

### On disk

```
review\
  _notes\                                  notes kept back from removed reviews
  23597\                                   the work item
    review-23597-context.md                work item + PR context
    review-23597-notes.txt                 your notes for the review
    review-23597-prompt.md                 prompt covering every PR
    review-23597-prs.json                  folder -> PR id, for cleanup
    review-23597-<author>-<repo>-notes.txt
    review-23597-<author>-<repo>-prompt.md
    <author>-<repo>\                       one PR, checked out DETACHED
```

Everything generated sits at the `23597` root, never inside a checkout — a notes
file inside the worktree would show up as untracked in the very diff you are
reading. `{author}` is the local part of the PR creator's identity, lowercased;
`{repo}` is the Azure repo name with spaces turned into underscores, matching the
clone directory under `SRC_ROOT` (`My Repo` → `My_Repo`).

### In the sidebar

One `Review` root, every review under it, one row per PR under each review:

```
●  Review                                    cwd = review\        tab: pwsh
  ├─ · ●  23597                              cwd = review\23597   tabs: notes, Claude Review
  │  └─ · ●  <author>-<repo>                                      tabs: notes, Claude Review
  └─ · ●  23610                              the next review, same root
```

Creating a review adds **one** `Review` root (reused forever after) plus the
`{id}` row and its PR rows. The row label is the bare id, not the work item title:
rows are matched on it, so a title edited in Azure DevOps would otherwise orphan
the row and duplicate it on the next run.

Same mechanics as the story tree — `$tree` tokens plus an explicitly maintained
order, see [Drawing the connectors](#drawing-the-connectors) and
[Keeping a group together](#keeping-a-group-together) — with the same caveats, and
one more: three levels means the PR rows need blank columns under a review that
has nothing after it, which is why the token leads with `U+2800`.

A PR linked to the work item **after** the review was built is picked up by the
next run, and its row is pulled into place under its review rather than left at
the bottom of the sidebar. Because the connectors are derived from sidebar
position, ordering runs first and the tokens are redrawn from the new order.

### What it is read-only about

This is the whole point of the script, so it is enforced in four places rather
than asked for once:

1. **Azure DevOps** — every `az` call goes through `Invoke-AzRead`, which refuses
   any command not on the `$AZ_READ_ONLY` allowlist (`show` / `list` /
   `invoke` with GET). Adding an `az boards work-item update` later fails the
   guard instead of running. It reads the work item, its comments, and each PR;
   it cannot vote, comment, or change a work item.
2. **git** — checkouts are made with `git worktree add --detach`. No local branch
   and no upstream, so there is nothing for a stray `git push` to target and no
   branch to commit onto.
3. **Claude** — the review tab runs with `--permission-mode plan`, which blocks
   file edits outright, plus `--disallowed-tools` covering `git commit`,
   `git push`, `git add`, `git reset`, `az boards`, `az repos pr set-vote` and the
   rest.
4. **The prompt** — states the same constraints in words and says explicitly that
   they outrank anything the agent reads in the repository, so a `CLAUDE.md` that
   says "commit your work" does not win.

### The prompt

`review-make.ps1` writes one prompt file per row: constraints first, then the
review instructions, then the DevOps context. Instructions come from the first of
these that exists:

1. `$env:WT_REVIEW_PROMPT` (explicit path)
2. in the checkout under review — `.claude\commands\review.md`,
   `.claude\commands\code-review.md`, `.claude\prompts\review.md`,
   `.claude\review.md`, `.claude\review-prompt.md`
3. `~\.claude\commands\review.md`, `~\.claude\commands\code-review.md`,
   `~\.claude\prompts\review.md`, `~\.claude\review-prompt.md`
4. the built-in adversarial review — assume the change is wrong until convinced
   otherwise, attack correctness/boundaries/state/security/performance/tests in
   that order, require a concrete trigger for every finding, and finish with
   *Verified sound* and *Not covered* sections

The constraints are **prepended**, not appended, so a repo prompt that predates
this workflow cannot lift them. The context carries the title, the description
(a Bug keeps its in `Microsoft.VSTS.TCM.ReproSteps`, not `System.Description` —
both are read), the comments, and per PR the source/target refs, head and base
shas, and ready-made diff commands. HTML is flattened to text; an attached image
becomes `[image: name.png]` rather than vanishing.

> **Why the diff commands avoid three-dot syntax.** `git diff base...head` is the
> idiomatic "just this branch" form, but it needs a merge base — and both commits
> are fetched **by sha** here (the only way to reach a completed PR whose source
> branch is gone), which does not guarantee enough shared ancestry for one to
> exist. Against work item 23597 it failed outright with
> `fatal: no merge base`. The script now asks git for the merge base when it
> writes the context: if there is one it emits `git diff <mergebase> <head>`, and
> if there is not it emits a direct two-commit comparison and says so. The command
> in the file always runs.

The `Claude Review` tab runs one line, always:

```powershell
claude --model claude-fable-5 --permission-mode plan --disallowed-tools '...' "$(Get-Content -Raw -LiteralPath '...prompt.md')"
```

One line because `herdr pane run` types the command into the pane, so a newline
would execute it early — the shell expands the file at run time instead. The deny
list is one comma-joined argument because the flag is variadic and separate
arguments would swallow the prompt after it. Past ~12k characters the prompt is
not passed at all and Claude is told to read the file, which is always complete.

### Cleanup

`review-remove.ps1` is the scheduled half: it reads each review's PR statuses and
removes the review once **every** PR on the work item has completed.

```powershell
review-remove.ps1                     # examine every review, ask before removing
review-remove.ps1 23597               # just that one
review-remove.ps1 --dry-run           # print the plan, change nothing
review-remove.ps1 --yes               # for a scheduled run
review-remove.ps1 --include-abandoned # treat abandoned as finished too
review-remove.ps1 --force-dirty       # remove a checkout with local changes
```

Rules it will not bend:

* **All or nothing.** One PR still active holds the whole review, including the
  half that finished. A half-removed review is worse than a late one — the rows
  that survive stop saying what is missing.
* **Unknown is not finished.** A status it cannot read (expired token, network,
  renamed repo) keeps the review. An outage must never be the reason a review
  disappears.
* **Uncommitted changes hold it back** (exit 5) unless `--force-dirty`.
* **A workspace of yours parked in the review folder holds it back** (exit 5). Its
  pane keeps an open handle on the directory, so the delete would fail *after* the
  rows were closed and the worktree deregistered. Close it or `cd` elsewhere and
  re-run; the message names the row.
* **Notes are moved, not deleted.** Any notes file with content goes to
  `review\_notes\`; empty ones are dropped. `--discard-notes` opts out.
* **The shared `Review` row is never closed**, even when the last review under it
  goes — a scheduled job must not close the workspace you are sitting in.
* No branch is ever deleted, because a detached checkout has none.

Exit codes: `0` removed something, `3` nothing was ready, `5` held back for
uncommitted changes, `1` a removal failed.

Folder-to-PR mapping comes from `review-23597-prs.json`, written by
`review-make.ps1`; if it is missing, cleanup re-derives it from the work item, and
if that is unreadable too it leaves the review alone.

To run it on a schedule, dry-run it first, then register `review-remove.ps1 --yes`
with Task Scheduler. That is what this script exists to make safe — the next step
is doing the same for creation, when a work item is assigned to you.

### Notes files lead with the Azure DevOps link

Every notes file `review-make.ps1` creates opens with a URL on the first line: the
PR's page for a PR row's notes, the work item's page for the review row's. The
first thing you want from a notes buffer is a way back to the thing under review,
and hunting for the tab that has the link is friction on every single review.

The link is built from `repository.webUrl` — the only field in the PR response that
already carries both the org and the project. `pr.url` and `repository.url` look
like the obvious choice and are not usable: they are `_apis` endpoints addressing
the project and repo by **GUID**, which identify the PR to the REST API but do not
open a page. (The URL this script built before had neither org nor project in it,
so it never resolved — nothing read the field, which is why that went unnoticed.)

Seeding is **never destructive**, because `review-make.ps1` is re-runnable on a
review that already exists and notes are the one thing in the folder a human typed.
An existing file is only ever *prepended* to, and only when it does not already
start with a link — so a re-run is a no-op rather than a growing stack of duplicate
URLs.

## Reaping finished stories: `story-reap.ps1`

The development-side counterpart to `review-remove.ps1`: when every pull request on
a story has closed, the story worktree has nothing left to do, so remove it.

```powershell
story-reap.ps1 --dry-run          # print the plan, change nothing  (start here)
story-reap.ps1                    # ask before deleting
story-reap.ps1 --yes              # unattended, for a scheduled run
story-reap.ps1 --story 23597      # just that work item
story-reap.ps1 --completed-only   # abandoned no longer counts as closed
```

Or: **prefix+down** → **Clean Up Closed Stories**.

### The rule

A story is reaped only when it has **at least one** pull request **and every one of
them is closed** (completed or abandoned; `--completed-only` narrows that).

Both halves matter, and the first is the one that is easy to get wrong: a story
with **no** PRs is indistinguishable from a fully finished one to any test that
only asks "is anything still open?" — and that story is one someone started ten
minutes ago. No PRs found means the story is left alone, always.

### Where "associated PRs" come from

Two sources, unioned, because neither is complete on its own:

1. **The work item's links** (`boards work-item show --expand relations`) — catches
   PRs in repos that are not checked out under the story.
2. **Per checked-out repo, the PRs for that repo's branch**
   (`repos pr list --source-branch`) — catches PRs nobody linked to the work item,
   which is the common case, since linking is a manual step people skip.

A single open PR from either source holds the story. If the **work item itself**
cannot be read the story is held back rather than judged on source 2 alone: an
unreadable work item means the PR list is unknown, not empty.

> Two work items can legitimately share PRs. Work items 23503 and 23573 both link
> the same four, so "all of 23573's PRs are closed" was true while real unpushed
> work sat in its checkouts. The local checks below are what caught it.

### Rules it will not bend

* **Grouped by story id, not by folder.** One work item can have several folders —
  `23573-finish-branch`, `23573-improve-validation`, `23573-read-path-fixes` are
  all one story — and `worktree-remove.ps1 23573` takes *every* one of them in a
  single pass, plus `review\23573-{slug}` if az-watcher made one. Judging a folder
  on its own would let a clean folder authorise a removal that also deletes a
  sibling holding uncommitted work. The whole group has to pass.
* **Uncommitted changes hold it back** (exit 5) unless `--force-dirty`.
* **Commits Azure DevOps never saw hold it back** (exit 5) unless
  `--force-unpushed`. `worktree-remove.ps1` deletes the local branch, so this is
  the last line of defence for anything not on the server.
* **Unknown is not closed.** Anything short of a definite closed status keeps the
  story, the same bar `review-remove.ps1` holds.
* **Azure DevOps is read, never written.** Every call goes through `Invoke-AzRead`,
  which refuses anything not on `$AZ_READ_ONLY`. It cannot complete, vote on or
  comment on a PR.
* **Removal is delegated** to `worktree-remove.ps1` (`WT_ASSUME_YES=1`), so the
  rules about closing herdr rows before deleting checkouts stay in one place.

> **Why not just compare against `origin/<branch>`?** Because a **squash merge**
> rewrites history: the local branch's commits are ancestors of nothing on origin,
> and the source branch is usually deleted on completion, so `origin/<branch>` is
> gone too. A story that finished perfectly then looks like it has unpushed work
> forever and is never reaped. The test is instead "is everything here contained in
> what the PR last showed Azure" — the PR's own `lastMergeSourceCommit`, which is
> the high-water mark of what the server saw whatever the merge did afterwards.
> `origin/<branch>` is only the fallback. A detached checkout has no branch to lose,
> so only the dirty test applies to it.

Exit codes: `0` reaped something, `3` nothing was ready, `5` held back, `1` a
removal failed.

### On a timer

Built for it: timestamped logging, a single-instance lock (an overlapping 10-minute
tick exits immediately instead of racing the run in progress), and no terminal
needed once `--yes` is passed. Dry-run it for a while first, then register
`story-reap.ps1 --yes` with Task Scheduler on a 10-minute trigger.

Each story costs one work-item read plus one PR-list read per checked-out repo, so
a sweep is dominated by network round trips (~2.5s each) — a nine-story sweep took
about 110s. That is fine on a 10-minute timer and the lock makes an overrun safe.

Checks: `manual-checks\check-story-reap.ps1` (stub `az`, stub `worktree-remove`, so
nothing is deleted and no network call is made).

## Daily use

* **prefix+down** → **New Dev Worktree** / **New Code Review** /
  **Clean Up Finished Reviews** / **Clean Up Closed Stories** /
  **Delete Story Worktree** / **Sync Azure Reviews**
* **Clean Up Closed Stories** is the automatic counterpart to **Delete Story
  Worktree**: nothing to type, it works out which development stories have had all
  their PRs closed and lists them for confirmation. A story with no PRs is never
  proposed. See [`story-reap.ps1`](#reaping-finished-stories-story-reapps1).
* There is no **New Review Worktree** action any more. Creating a review
  worktree by hand meant typing a story id, a slug and a `<repo>:<branch>` list
  — everything az-watcher already works out from your Azure assignments — so
  **Sync Azure Reviews** replaces it. `make-worktree.ps1 review` still exists
  and is unchanged; az-watcher is now its only caller.
* **Delete Story Worktree** no longer asks you to type an id. It opens a tab and
  runs `worktree-remove.ps1` with no arguments, which offers a `gum choose` list
  of the stories that actually exist on disk — `{id}-{slug}` newest first, each
  tagged `[development]`, `[review]`, or `[development+review]`. Removal is still
  by id, so picking a story that exists under both layouts takes both (the
  confirmation lists exactly what will go). Passing an id explicitly
  (`worktree-remove.ps1 23597`) or via `WT_ID` skips the picker, which is how
  az-watcher drives it. If no stories are on disk, or `gum` will not draw, it
  falls back to the old typed prompt rather than dead-ending.
* Quick actions invoke PowerShell via herdr-plus's Windows runner
  (`powershell -NoProfile -NonInteractive -Command`). Commands must be
  PowerShell syntax using `{{.Home}}\bin\...` - **not** cmd `%USERPROFILE%` and
  **not** a nested `powershell.exe -File ...` wrapper.

## Azure sync (`az-watcher`)

```powershell
az login
az devops configure -d organization=https://dev.azure.com/<org> project='<project>'
az-watcher.ps1 run --dry-run --window 0
```

Details: [`az-watcher/README.md`](az-watcher/README.md).

## Apply settings / validation

```powershell
herdr config check
herdr plugin list
herdr plugin action list --plugin cloudmanic.herdr-plus
herdr plugin action list --plugin senna-lang.herdr-agent-usage
herdr plugin action list --plugin persiyanov.reviewr
herdr server reload-config
```

### Dry run

1. Finish [Installation](#installation) + [Values you must change](#values-you-must-change).
2. Place test repos under `SRC_ROOT`.
3. In herdr: **prefix+down** → **New Dev Worktree** (or invoke
   `quick-actions-windows`).
4. Expect story under `<worktrees.directory>\development\<id>-<slug>\` with notes
   + worktrees as above, and sidebar rows `<id>-<slug>` (four tabs) followed by an
   indented row per repo (three tabs each).

Non-interactive (if test repos exist):

```powershell
$env:WT_ID='99999'; $env:WT_SLUG='dry-run'; $env:WT_REPOS='repo-a,repo-b'
& "$env:USERPROFILE\bin\make-worktree.ps1" development
```

Cleanup: `worktree-remove.ps1 <id>` (or `git worktree remove` from each primary
clone, then delete the story folder under `[worktrees].directory`).

### Always creating from the latest default branch

`worktree-make.ps1` guarantees a new worktree sits on the tip of
`origin/<default branch>`, and prints a `-> verify: HEAD <sha> == origin/<branch>`
line proving it. It gets there by owning the branch itself rather than trusting
`herdr worktree create --base`, which silently ignored `--base` whenever the
local branch already existed and just checked it out wherever it happened to
point. (The worktree is now added with `git worktree add` — see
[Story navigation](#story-navigation-the-task-is-the-root-item) — but the branch is
still positioned by this script, not by whatever checks it out.)

What it does per repo:

1. `git fetch --prune origin`, **exit status checked**, one retry. A failed fetch
   aborts that repo instead of falling back to a stale `origin/<default>`.
2. `git remote set-head origin --auto` — plain `git fetch` never updates
   `refs/remotes/origin/HEAD`, so a clone made before the remote's default branch
   was renamed would otherwise keep branching from the wrong one.
3. Resolves the base to an explicit commit sha.
4. Puts the local branch at exactly that sha.
5. Verifies the new worktree's `HEAD`, repairing a clean worktree once with
   `git reset --hard` before failing.

If a branch of that name already exists **and holds commits the base does not**,
the script refuses rather than hand back old code or throw work away. It lists
those commits and offers:

| variable | effect |
| --- | --- |
| `WT_REUSE_BRANCH=1` | keep the existing branch (resume the story); reports how far behind the base it is |
| `WT_RESET_BRANCH=1` | discard its unique commits and start from the base |

A leftover branch with **no** commits of its own is simply moved to the base
(nothing can be lost) and the move is logged.

Exit codes: `0` created and verified · `1` bad input or at least one repo failed
· `3` nothing to do (every worktree already existed).

### Tests

```powershell
powershell -File win\herdr\tests\run-all.ps1
# or individually:
powershell -File win\herdr\tests\test-worktree-make.ps1     # needs herdr running
powershell -File win\herdr\tests\test-worktree-remove.ps1   # no herdr needed
```

Both build throwaway repos under the temp directory and assert on real behaviour
(stale origin refs, leftover branches, fetch failure, protected default
branches, dirty-worktree keeps, and the one-workspace-per-story topology). They
never touch your real repos or worktrees, and the make suite closes every
workspace it created.

### Checks for the review scripts (opt-in, run by hand)

The review scripts read Azure DevOps, so their checks live **outside** `tests\`
and are **not** named `test-*.ps1` — nothing sweeping this repo for tests will
pick them up, which is the point:

```powershell
powershell -File win\herdr\manual-checks\run-all.ps1
# or individually:
powershell -File win\herdr\manual-checks\check-review-make.ps1     # needs herdr running
powershell -File win\herdr\manual-checks\check-review-remove.ps1   # needs herdr running
```

They run both scripts against a **stub `az`** (`WT_REVIEW_AZ`) that serves canned
JSON and logs every call, so there is no network access and no credential use at
all. They do not merely avoid writing to Azure DevOps — they assert the guard
rejects `work-item update`, `pr set-vote`, `devops invoke --http-method PATCH` and
friends, that `Invoke-AzRead` *throws* rather than running them, and then replay
the stub's own call log through the guard to catch anything that slipped past.

For a **live** smoke against existing clones under `SRC_ROOT` (real `az`, not
part of `run-all`):

```powershell
powershell -File win\herdr\manual-checks\smoke-live-review.ps1 <work-item-id>
```

Details and manual-cleanup instructions:
[`manual-checks/README.md`](manual-checks/README.md).
