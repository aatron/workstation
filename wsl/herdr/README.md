# Herdr set-up

Shared WSL Herdr + herdr-plus workflow for multi-repo story worktrees (dev and review).

## Prerequisites — values you must change

Placeholders are not defaults. Edit the repo copies under `wsl/herdr/` (install symlinks them into `~/bin`).

### Scripts (`EDIT THESE FOR YOUR MACHINE`)

| File | Variable | Change to |
|------|----------|-----------|
| `worktree-make.sh` | `SRC_ROOT` | your primary clones dir, e.g. `$HOME/source/repos` |
| `worktree-make.sh` | `BRANCH_PREFIX` | e.g. `feature/jsmith` (ships as `feature/YOU`) |
| `review-make.sh` | `SRC_ROOT` | same as above |
| `review-make.sh` | `REVIEW_MODEL` | e.g. `claude-fable-5` |
| `review-make.sh` | `REVIEW_PERMISSION_MODE` | leave `plan` (read-only reviews) |

Clones must already exist at `$SRC_ROOT/<repo>` (`origin` + default branch). Azure repo spaces → underscores (`My Repo` → `My_Repo`).

### Azure DevOps (reviews / az-watcher / story-reap)

`az` is not installed by `install.sh`:

```bash
az login
az devops configure -d organization=https://dev.azure.com/<org> project='<project>'
```

## Installation

```
cd /path/to/workstation/wsl/herdr
./install.sh
```

Idempotent. Installs herdr (≥ 0.7.5) + CLIs, creates `~/.config/herdr/config.toml` **only if missing** (never overwrites an existing one), installs plugins (`herdr-plus`, Agent Usage, reviewr), symlinks scripts into `~/bin`, and copies quick actions + `worktree-layout.toml`.

## After install — `config.toml`

Merge these by hand (install never does), then `herdr config check` and `herdr server reload-config`:

```toml
[worktrees]
directory = "~/source/worktrees"

[ui.sidebar.spaces]
rows = [["$tree", "state_icon", "workspace"]]
```

Also add herdr-plus keybinds (`prefix+up` / `prefix+down`) — see [Herdr Plus keybinds](#herdr-plus-keybinds).

## Herdr settings (manual `config.toml`)

`install.sh` only writes a default `config.toml` when the file is missing; it never merges the snippets below. Edit by hand:

```
micro ~/.config/herdr/config.toml
```

### Worktree directory

Used by Herdr’s built-in worktree actions **and** by `worktree-make.sh` for story folders (`development/…`, `review/…`). Set this (recommended for this workflow). If omitted, `worktree-make.sh` falls back to `~/source/worktrees`.

```
[worktrees]
directory = "~/source/worktrees"
```

### Theme

```
[theme]
# Built-in themes: catppuccin, terminal, tokyo-night, dracula, nord,
#                  gruvbox, one-dark, solarized, kanagawa, rose-pine,
#                  vesper
name = "solarized"
```

```
[theme.custom]
overlay0 = "#93a1a1" # Lighten secondary text
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

```bash
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

### Navigation keys

```
[keys]
# Move between tabs
previous_tab = "ctrl+alt+left"
next_tab     = "ctrl+alt+right"
# Move between workspaces
previous_workspace = "ctrl+alt+up"
next_workspace     = "ctrl+alt+down"
```

### Herdr Plus keybinds

```
[[keys.command]]
key = "prefix+up"
type = "plugin_action"
command = "cloudmanic.herdr-plus.projects"
description = "herdr-plus: projects"

[[keys.command]]
key = "prefix+down"
type = "plugin_action"
command = "cloudmanic.herdr-plus.quick-actions"
description = "herdr-plus: quick actions"
```

### herdr-reviewr keybinds

Bind one Herdr-level key to show/hide the review pane. This belongs in
`~/.config/herdr/config.toml` (not the plugin config):

```
[[keys.command]]
key = "prefix+r"
type = "plugin_action"
command = "persiyanov.reviewr.toggle"
description = "reviewr: toggle reviewer"
```

Use **prefix+r** to show/hide the reviewer. Inside reviewr, press **?** for the
active shortcut list. Common defaults:

* **u** / **b** / **t** — scopes: uncommitted / branch / last turn
* **1** / **2** / **3** — tabs: Changes / All files / PR
* **v** — select lines
* **c** — comment on the selection/current line
* **s** — send all comments to the agent
* **q** — quit the reviewer pane

Manual commands when a keybind is not available:

```
herdr plugin action invoke open --plugin persiyanov.reviewr
herdr plugin action invoke close --plugin persiyanov.reviewr
herdr plugin action invoke toggle --plugin persiyanov.reviewr
```

### herdr-reviewr config

reviewr has its own config file:

```
~/.config/herdr/plugins/config/persiyanov.reviewr/config.toml
```

`install.sh` writes this managed block automatically and preserves other plugin
settings such as `[keybindings]`:

```
# BEGIN vscodesettings herdr-reviewr defaults
auto_open = false
toggle_placement = "overlay" # split | overlay | zoomed | tab
toggle_direction = "right"   # right | down; split only
default_scope = "branch"
# END vscodesettings herdr-reviewr defaults
```

`auto_open = false` keeps reviewr from racing herdr-plus while a new worktree
layout is being built; open it explicitly with **prefix+r** when ready. Use
`toggle_placement = "split"` if you prefer a persistent side pane instead of an
overlay.

### Agent panel / pane labels (under `[ui]`, not sidebar)

These belong on the top-level `[ui]` table. Putting them under `[ui.sidebar.agents]` makes herdr warn `config.toml has unknown keys` (`herdr config check`).

```
[ui]
agent_panel_sort = "spaces"                 # or "priority"
show_agent_labels_on_pane_borders = true
sidebar_start_collapsed = false             # keep the story sidebar visible — it IS the worktree navigation
```

### Story navigation: the task is the root item

The left sidebar **is** the story navigation, and the row you want at the top is
the **story**, not the repo.

That is not what herdr does on its own. It groups every workspace by its **source
repository** (`worktree.repo_key`) and always nests linked worktrees under their
primary clone. The grouping is built in — there is no config for it — so a story
spanning four repos used to become four unrelated rows in four different groups:

```
repo1
  222-example-second
repo2
  222-example-second
```

`herdr worktree create --workspace <ID>` is not a way out either: `--workspace`
and `--cwd` are mutually exclusive, and `--workspace` only says which workspace to
take the *source repo* from — it still creates a workspace of its own.

So `worktree-make.sh` stopped using `herdr worktree create`. It adds the
worktrees with plain `git worktree add` and builds the rows itself. A workspace
with **no worktree metadata is not grouped at all**, so the panel finally reads
story-first:

```
 *  222-example-second          cwd = <worktrees>/development/222-example-second
   |- . *  repo1                cwd = .../222-example-second/repo1
   `- . *  repo2                cwd = .../222-example-second/repo2
```

`review-make.sh` does the same thing one level deeper, under a single shared
`Review` root:

```
 *  Review
   |- . *  23597
   |  `- . *  <author>-<repo>
   `- . *  23610
```

Keep the panel visible (`sidebar_start_collapsed = false`) and use
`previous_workspace` / `next_workspace` (below) to move within it.

### Drawing the connectors

The connectors are **not** in the label. They are reported per row as a `$tree`
metadata token, which only renders if the row spec asks for it — and `$tree` has
to come **before** `state_icon`, or the bullet stays hard against the left edge
and nothing reads as nested:

```
[ui.sidebar.spaces]
rows = [["$tree", "state_icon", "workspace"]]
```

Both scripts cope with the token being absent — they fall back to indenting the
label, which shifts the text but not the bullet — and print this snippet when
they notice it is missing.

> **The dot is deliberate.** herdr joins row segments with a hardcoded `" . "`
> and exposes no setting to suppress it (not at `[ui]`, `[ui.sidebar]` or
> `[ui.sidebar.spaces]`; a row element's object form only accepts
> token/bold/dim/fg), so a connector segment followed by `state_icon` always
> shows one: `|- . *  repo1`. Moving the connector into the label removes the dot
> but strands the status bullet at the far left. Keeping the live bullet inside
> the tree is worth the dot — do not "fix" it.

> **The indent is U+2800, not spaces.** herdr **trims leading whitespace** off a
> token value, so `"  |-"` arrives as `"|-"` and the indent silently disappears —
> which is what once collapsed the third level onto the second, with PR rows
> lining up beside their own review instead of under it. U+2800 BRAILLE PATTERN
> BLANK is blank on screen but is not whitespace to a trimmer. Interior spaces
> survive, so only the first column needs it.

### Keeping a group together

herdr appends every new workspace to the **end** of the sidebar. That is fine
when a story is built in one go, but a repo added to an existing story — or a PR
linked to a work item after its review was built — lands at the bottom, thirty
rows away from the group it belongs to. No amount of connector drawing fixes
that; the rows have to actually move.

Reordering is **not** exposed by the `herdr workspace` CLI, so `set_sidebar_order`
— identical in `worktree-make.sh` and `review-make.sh` — talks to the API socket
directly. On Linux that socket is a real **AF_UNIX** stream socket and the
protocol is plain newline-delimited JSON, with no handshake and no token:

```json
{"id":"x","method":"workspace.move","params":{"workspace_id":"w2W","insert_index":14}}
```

`python3` speaks it. That is a deliberate choice over `socat` (often absent) and
`nc -U` (present, but awkward to bound with a timeout); `review-make.sh` needs
python3 anyway for HTML flattening.

**Why `workspace.move` and not `workspace.move_block`.** The newer method takes a
whole ordered list plus an anchor and would do this in one call — but it only
exists from **protocol 18**. The herdr in WSL is plain 0.7.5, **protocol 17**,
which rejects it outright with `unknown variant "workspace.move_block"`. The
Windows side runs a 0.7.5 preview that *does* have it. Both sides drive the older
call so they behave identically instead of the ordering silently doing nothing on
whichever machine is behind.

Semantics worth knowing, verified against a live server:

* `insert_index` is **0-based and absolute**: the workspace is removed from the
  list and re-inserted so that it ends up *at* that index in the result.
* A workspace's `number` in `workspace list` is its **current sidebar position**,
  not its creation order — herdr renumbers on every move. That is why
  `review-make.sh` re-reads the list between ordering and drawing connectors.

`set_sidebar_order` anchors the run at the slot its **topmost** member already
occupies, then places each member in turn, simulating the resulting list between
moves so the next index is right without another round trip. It compares against
the current order first and skips the whole thing when nothing needs to change,
and every failure is swallowed — no python3, an unreachable socket, an older
herdr. The rows are still correct; only their order would suffer.

> Resolve the socket from herdr's own directory, **not** from
> `HERDR_CONFIG_PATH`. That variable names a config *file*, which can live
> anywhere (the check harness points it at a fixture), while the socket always
> sits in `~/.config/herdr` — or in `~/.config/herdr/sessions/<name>` when
> `HERDR_SESSION` is set. herdr's CLI resolves it the same way, which is why
> every `herdr` command still works when the config path is pointed elsewhere.
> Getting this wrong is silent: the ordering pass just never runs.

> Want per-worktree git ahead/behind? Add a second row:
> `rows = [["$tree", "state_icon", "workspace"], ["git_status"]]`. Avoid the
> `branch` token — on the old repo-grouped layout it printed a misleading `main`.

### Agent Usage sidebar (Herdr 0.7.5+)

Only `row_gap` / `rows` (and optional `rows_by_agent`) go here:

```
[ui.sidebar.agents]
row_gap = 0
rows = [
  ["state_icon", "tab", "pane"],
  ["$provider", "$limit"],
  ["$context"],
]
```

### Agent Usage keybinds (optional)

```
[[keys.command]]
key = "ctrl+shift+u"
type = "plugin_action"
command = "usagebar.open-limits"
description = "Agent Usage: open limits pane"

[[keys.command]]
key = "ctrl+shift+m"
type = "plugin_action"
command = "usagebar.refresh"
description = "Agent Usage: refresh sidebar meters"
```

### Toast delivery (optional, for low-allowance warnings)

Prefer pasting this by hand rather than running `usagebar.enable-toast` (that action can append to `config.toml`):

```
[ui.toast]
delivery = "herdr" # or "system" / "terminal"

[ui.toast.herdr]
position = "bottom-left"
```

### Claude global usage (5h / 7d) — where it shows

Agent Usage **cannot** draw on Herdr’s global bottom status bar (plugins have no hook there). Claude account usage shows in these places instead:

| Surface | What you see |
|---------|----------------|
| Agent sidebar `$limit` / `$provider` | Shortest remaining plan window for the focused Claude pane (needs the sidebar rows above) |
| **ctrl+shift+u** → limits pane | Full Claude 5h / 7d (and other providers) account windows |

On demand inside Claude: `/usage` shows the full plan windows without a persistent footer.

## Apply settings

1. Validate config after pasting snippets:

   ```
   herdr config check
   ```

   Fix any `unknown config key` lines before relying on keybinds or the sidebar.
2. Seed Agent Usage (resolves/builds the `usagebar` binary; prints paste snippets; does not rewrite herdr `config.toml`):

   ```
   herdr plugin action invoke usagebar.setup
   ```

   Paste any sidebar / toast / key snippets it prints if you have not already added them.
3. Reload Herdr after any `config.toml` edit (each named session has its own server — reload or restart that session too):

   ```
   herdr server reload-config
   # named session (required when that session is the one you are using):
   herdr --session three-repo-test server reload-config
   ```

   Bare `herdr server reload-config` only talks to the **default** session. If that session is stopped you get `No such file or directory` (missing socket) — pass `--session <name>` for the running session (`herdr session list`).
   On herdr ≥ 0.7.5, installed plugins are global across sessions. After upgrading from 0.7.4, restart named sessions so they pick up the shared plugin registry (`herdr session stop <name>` then `herdr --session <name>`).
4. Optional: install agent integrations from the Settings menu or CLI for better session matching.

### Settings menu

* `toasts`
    * popups - system notification
* `integrations`
    * Install agent interactions (recommended for Agent Usage session matching)

## Worktree tabs (no per-repo toml required)

Tabs come from **one** herdr-plus Worktree Auto-Layout file with `repo = "*"`. You do **not** need a toml per repository unless you want a repo-specific override.

The layout opens four tabs at that repo's worktree root. Layouts cannot interpolate the repo/story name, and their tab **commands do not reliably start** on create — so `make-worktree.sh` owns both the labels and the commands, submitting each one into the tab's pane with `herdr pane run` after `cd`-ing to the worktree (repo) root:

| Tab (layout name) | Renamed to | What the script runs (at the repo root) |
|-------------------|------------|-----------------------------------------|
| notes | `notes-{id}-{slug}` | `micro <id>-<slug>-<repo>.txt` (that repo's notes file, absolute path) |
| claude | `{repo} claude` | `claude --permission-mode auto` (`$CLAUDE_CMD`) |
| cursor | `{repo} cursor` | `agent --auto-review` (`$CURSOR_CMD`, Cursor Agent CLI) |
| bash | `{repo} bash` | nothing — bare shell |

Both agents start in their **auto** permission mode — Claude's `auto` mode, and Cursor's `--auto-review` ("Smart Auto"): safe tool calls run on their own, anything riskier still prompts. Change `CLAUDE_CMD` / `CURSOR_CMD` at the top of `worktree-make.sh` to adjust (e.g. `agent --yolo` / `claude --permission-mode bypassPermissions` to stop prompting entirely), and keep `worktree-layout.toml`'s tab commands in sync.

A pane that is already running something (i.e. the layout's own command did fire) is left alone, so nothing gets launched twice. Re-opening an existing worktree does not re-run the script, so those tabs keep the layout names `notes` / `claude` / `cursor` / `bash` and whatever the layout itself manages to start.

## Daily use

* **Navigate** between story worktrees from the left sidebar (grouped by repo; each worktree row is labeled `{id}-{slug}`), or with `previous_workspace` / `next_workspace`
* **prefix+down** → **New Dev Worktree**
* That opens a new tab and runs `make-worktree.sh` there (herdr-plus overlays cannot host interactive `gum` prompts)
* Dev prompts: story id, slug, comma-separated repo names
* **Commit & push**: from any worktree, a plain `git commit` + `git push` just works — the script points each branch's upstream at its **own name** on origin, so the first `git push` creates `origin/feature/<you>/{id}-{slug}` and can never target the default branch (even with `push.default=upstream`). Without this, git would auto-track `origin/main` (the branch's base) and a plain push would fail — or worse, aim at main.
* There is no **New Review Worktree** action any more. It prompted for id + slug and then fell back to a placeholder branch list, which is a lot of typing for something a tool can derive — let **az-watcher** create review worktrees from your Azure assignments instead (see below, or **Sync Azure Reviews**). `make-worktree.sh review` still exists and is unchanged; az-watcher is now its only caller
* **prefix+down** → **Delete Story Worktree** to tear a story down (pick it from a list; see below)
* **prefix+down** → **Clean Up Closed Stories** — the automatic counterpart: nothing to type, it works out which development stories have had all their PRs closed and lists them for confirmation. A story with no PRs is never proposed. See [`story-reap.sh`](#reaping-finished-stories-story-reapsh)
* **prefix+down** → **Sync Azure Reviews** to run az-watcher once in a visible tab
* **ctrl+shift+u** → Agent Usage limits pane (if you added the keybind)

## Delete a story

**prefix+down** → **Delete Story Worktree** opens a tab and runs `worktree-remove.sh` with no arguments, so the script offers a `gum choose` list of the stories that actually exist on disk — `{id}-{slug}` newest first, each tagged `[development]`, `[review]`, or `[development+review]`. Pick one and its id is what gets removed; there is nothing to type and nothing to remember. Passing an id explicitly (`worktree-remove.sh 23597`) or via `WT_ID` still skips the picker, which is how az-watcher drives it.

From there the behaviour is unchanged: the script globs every `{id}-*` folder (plus legacy `{id}_*` folders from before the rename) under both layouts a story can live in — `<[worktrees].directory>/development` and `<[worktrees].directory>/review` — and, after a `gum` confirmation, for each matching story:

* removes each repo worktree through herdr (`herdr worktree remove --force`) — this closes the workspace, deletes the checkout, **and unregisters the worktree from herdr's sidebar** (a plain `workspace close` leaves it listed),
* falls back to `git worktree remove --force` (then `rm -rf`) when herdr is not running or the directory survives, and prunes stale worktree registrations in the primary clone,
* deletes each worktree's **local** git branch (never the repo's default branch; a detached HEAD is skipped),
* deletes every per-repo notes file `<id>-<slug>-<repo>.txt` (slug taken from the folder name; inside the story folder, and in the old sibling location for pre-rename stories) and removes the story folder.

The confirmation prompt warns explicitly that the worktree directories themselves are deleted — including any **uncommitted changes and untracked files** inside them — along with branches, herdr workspaces, and notes.

The primary clone for each worktree is discovered from the worktree itself (`git rev-parse --git-common-dir`), so no `SRC_ROOT` is needed and it stays portable. It only deletes **local** branches — remote branches are untouched.

## Code review: `review-make.sh` / `review-remove.sh`

**prefix+down** → **New Code Review** asks for an Azure DevOps **work item id**
(not a PR id) and opens a read-only review of every pull request linked to it.
**Clean Up Finished Reviews** is the other half; leave its field blank to examine
every review.

This is a different shape from `worktree-make.sh review`, which is branch-driven
and gives you one story row per id. A review is driven by the work item alone —
the PRs are discovered from it — every review in flight hangs off a single shared
`Review` root, and nothing is ever written anywhere but your own disk.

### On disk

```
<[worktrees].directory>/review/
  23597/                                   the work item
    review-23597-context.md                work item + PR context
    review-23597-notes.txt
    review-23597-prompt.md
    review-23597-<author>-<repo>-notes.txt
    review-23597-<author>-<repo>-prompt.md
    <author>-<repo>/                       one PR, checked out DETACHED
```

Everything generated sits at the `23597` root, never inside a checkout — a notes
file inside the worktree would show up as untracked in the very diff the reviewer
is reading.

### What it is read-only about

1. **Azure DevOps.** Every `az` call goes through `az_read`, which refuses any
   command not on the allow-list (`show` / `list` / `invoke` with `GET`). A future
   edit reaching for `az boards work-item update` or `az repos pr set-vote` fails
   the guard instead of running. `devops invoke` is allow-listed but still
   rejected if it carries `--in-file`, `--body`, or a non-GET `--http-method`.
2. **Git.** Worktrees are added with `git worktree add --detach`. There is no
   local branch and no upstream, so there is nothing for a stray `git push` to
   push and no branch to accidentally commit onto.
3. **Claude.** The review tab runs `--permission-mode plan`, which blocks file
   edits outright, plus a `--disallowed-tools` list covering commit, push, and the
   `az` verbs that would write back. The prompt states the same constraints in
   words and says they outrank anything the model reads in the repository.

The `--disallowed-tools` patterns go in as **one comma-joined argument**. The flag
is variadic, so passing them separately would make it swallow the prompt that
follows as another tool name.

### Cleanup

`review-remove.sh` is built to run unattended, so the bar it has to clear is high:

* a review goes only when **every** PR on its work item has completed — one still
  active holds the whole thing, because a half-removed review is worse than a late
  one
* a PR whose status cannot be read is **not** finished; an expired token or a
  network blip must never be the reason a review disappears
* `abandoned` counts only with `--include-abandoned`
* uncommitted changes hold a review back (exit 5) unless `--force-dirty`
* notes with anything in them are **moved** to `review/_notes/`, not deleted
  (`--discard-notes` opts out)
* a workspace of yours parked in the folder holds it back too — its pane keeps the
  directory open, and the delete would otherwise fail *after* the rows were closed
* the shared `Review` row is never closed

Dry-run it first, then schedule `review-remove.sh --yes`.

### Notes files lead with the Azure DevOps link

Every notes file `review-make.sh` creates opens with a URL on the first line: the
PR's page for a PR row's notes, the work item's page for the review row's. The first
thing you want from a notes buffer is a way back to the thing under review, and
hunting for the tab that has the link is friction on every single review.

The link is built from `repository.webUrl` — the only field in the PR response that
already carries both the org and the project. `pr.url` and `repository.url` look
like the obvious choice and are not usable: they are `_apis` endpoints addressing
the project and repo by **GUID**, which identify the PR to the REST API but do not
open a page.

Seeding is **never destructive**, because `review-make.sh` is re-runnable on a
review that already exists and notes are the one thing in the folder a human typed.
An existing file is only ever *prepended* to, and only when it does not already
start with a link — so a re-run is a no-op rather than a growing stack of duplicate
URLs.

### Checks (opt-in, run by hand)

`manual-checks/` covers these scripts against a **stub `az`** — no network, no
credentials, nothing written to a real work tracker. They are deliberately not in
`tests/` and not named `test-*.sh`. Run `bash manual-checks/run-all.sh` (herdr
needed for the review suites) or see `manual-checks/README.md`. Live smoke against
existing clones: `bash manual-checks/smoke-live-review.sh <work-item-id>`.
Unit tests: `bash tests/run-all.sh`.

## Reaping finished stories: `story-reap.sh`

The development-side counterpart to `review-remove.sh`: when every pull request on a
story has closed, the story worktree has nothing left to do, so remove it.

```bash
story-reap.sh --dry-run          # print the plan, change nothing  (start here)
story-reap.sh                    # ask before deleting
story-reap.sh --yes              # unattended, for cron
story-reap.sh --story 23597      # just that work item
story-reap.sh --completed-only   # abandoned no longer counts as closed
```

Or: **prefix+down** → **Clean Up Closed Stories**.

### The rule

A story is reaped only when it has **at least one** pull request **and every one of
them is closed** (completed or abandoned; `--completed-only` narrows that).

Both halves matter, and the first is the one that is easy to get wrong: a story with
**no** PRs is indistinguishable from a fully finished one to any test that only asks
"is anything still open?" — and that story is one someone started ten minutes ago.
No PRs found means the story is left alone, always.

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
  `23573-finish-branch`, `23573-improve-validation`, `23573-read-path-fixes` are all
  one story — and `worktree-remove.sh 23573` takes *every* one of them in a single
  pass, plus `review/23573-{slug}` if az-watcher made one. Judging a folder on its
  own would let a clean folder authorise a removal that also deletes a sibling
  holding uncommitted work. The whole group has to pass.
* **Uncommitted changes hold it back** (exit 5) unless `--force-dirty`.
* **Commits Azure DevOps never saw hold it back** (exit 5) unless
  `--force-unpushed`. `worktree-remove.sh` deletes the local branch, so this is the
  last line of defence for anything not on the server.
* **Unknown is not closed.** Anything short of a definite closed status keeps the
  story, the same bar `review-remove.sh` holds.
* **Azure DevOps is read, never written.** Every call goes through `az_read`, which
  refuses anything not on `$AZ_READ_ONLY`.
* **Removal is delegated** to `worktree-remove.sh` (`WT_ASSUME_YES=1`), so the rules
  about closing herdr rows before deleting checkouts stay in one place.

> **Why not just compare against `origin/<branch>`?** Because a **squash merge**
> rewrites history: the local branch's commits are ancestors of nothing on origin,
> and the source branch is usually deleted on completion, so `origin/<branch>` is
> gone too. A story that finished perfectly then looks like it has unpushed work
> forever and is never reaped. The test is instead "is everything here contained in
> what the PR last showed Azure" — the PR's own `lastMergeSourceCommit`, which is the
> high-water mark of what the server saw whatever the merge did afterwards.
> `origin/<branch>` is only the fallback. A detached checkout has no branch to lose,
> so only the dirty test applies to it.

Exit codes: `0` reaped something, `3` nothing was ready, `5` held back, `1` a
removal failed.

### On a timer

Built for it: timestamped logging, a `flock` single-instance guard (an overlapping
tick exits immediately instead of racing the run in progress), and no terminal needed
once `--yes` is passed. Dry-run it for a while, then `*/10 * * * *` running
`story-reap.sh --yes`.

Each story costs one work-item read plus one PR-list read per checked-out repo, so a
sweep is dominated by network round trips (~2.5s each) — a nine-story sweep took
about 110s. That is fine on a 10-minute timer and the lock makes an overrun safe.

Checks: `manual-checks/check-story-reap.sh` (stub `az`, stub `worktree-remove`, so
nothing is deleted and no network call is made; needs no herdr session).

## Azure sync (`az-watcher`)

`az-watcher/` is a headless driver that keeps local worktrees in step with Azure DevOps pull requests, by calling the same two scripts you drive by hand:

* **A PR is assigned to you for review** → creates a **review** worktree for that PR's repo + source branch (`make-worktree.sh review`, non-interactively).
* **A PR you created or reviewed is completed/abandoned** → removes that repo's worktree, local branch and notes (`worktree-remove.sh`, single-repo), and drops the story folder once no worktrees remain in it.

The story folder comes from the PR source branch when its last segment looks like `{id}-{slug}` (`.../22831-order-entry-forms` → `22831-order-entry-forms`), otherwise from the linked work item id + title. Azure repo names map to clone directories by turning spaces into underscores (`My Repo` → `My_Repo`). Every outcome — created, cleaned up, skipped, failed — arrives as a `herdr notification` as well as a log line.

**prefix+down** → **Sync Azure Reviews** runs it once in a visible tab. It is built for `*/5 * * * *` cron: stateless, idempotent, `flock`-guarded, and it keeps (never deletes) worktrees with uncommitted changes.

`az` is **not** installed by `install.sh`. Set it up once, then dry-run before trusting it:

```bash
az login
az devops configure -d organization=https://dev.azure.com/<org> project='<project>'
az-watcher run --dry-run --window 0
```

Full details, cron line, and limitations: [`az-watcher/README.md`](az-watcher/README.md).

## Dry run (home, three repos)

Goal: confirm notes + three worktrees are created under `[worktrees].directory` with per-repo claude/cursor/bash tabs.

1. Finish [Prerequisites](#prerequisites--values-you-must-change), [Installation](#installation), and [After install — config.toml](#after-install--configtoml).
2. Clone (or place) three git repos under `SRC_ROOT`, e.g.:
   * `$SRC_ROOT/repo-a`
   * `$SRC_ROOT/repo-b`
   * `$SRC_ROOT/repo-c`
3. Ensure each has a remote `origin` and a default branch herdr can base from.
4. In herdr: **prefix+down** → **New Dev Worktree**
5. Enter a test id/slug (e.g. `99999` / `dry-run`) and repos `repo-a,repo-b,repo-c`
6. Expect (with `directory = "~/source/worktrees"` → `$HOME/source/worktrees`):
   * Story dir: `$HOME/source/worktrees/development/99999-dry-run/`
   * Per-repo notes **inside** the story dir: `99999-dry-run-repo-a.txt`, `99999-dry-run-repo-b.txt`, `99999-dry-run-repo-c.txt`
   * `.notespath-repo-a` (etc.) inside the story dir, each pointing at that repo's notes file
   * Worktrees: `repo-a/`, `repo-b/`, `repo-c/` on branch `feature/<you>/99999-dry-run`
   * Each worktree workspace opens with tabs `notes-99999-dry-run` (micro on that repo's notes file), `{repo} claude` (running `claude`), `{repo} cursor` (running `agent`), and `{repo} bash` — all at the worktree root

Cleanup after the dry run (from each primary clone): `git worktree list` then `git worktree remove <path>` as needed, and delete the story folder/notes under `[worktrees].directory`.
