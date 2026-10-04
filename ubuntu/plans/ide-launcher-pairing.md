# Plan: `ide` launcher with terminal pairing

Status: draft. Nothing here has been built or run yet.

## Goal

Run `ide` in a terminal and get an IDE window that is:

1. opened for the current folder (Cursor by default, Zed with a flag),
2. placed on the right-hand monitor, and
3. **paired** with the terminal window that launched it, recorded in a small registry that a later border-highlight daemon can read.

## Scope

In scope: the launcher, the pair registry, install wiring.

Out of scope (separate plans): the highlight daemon (focus events and border colors), browser pairing, and the kitty `open_url_with` script. The registry format below is the contract those will build on.

## Usage

```
ide              # Cursor, current folder
ide path/to/dir  # Cursor, that folder
ide -z [path]    # Zed instead (also --zed)
```

The launcher returns the prompt immediately. Pairing finishes in the background.

## Design

### Files

| File | Purpose |
|------|---------|
| `ubuntu/hypr/scripts/ide` | The launcher (bash) |
| `ubuntu/hypr/scripts/lib-pairs.sh` | Registry helpers (read, write, prune), sourced by the launcher and later by the daemon |
| `~/.local/bin/ide` | Symlink to the launcher, made by the install script |
| `$XDG_RUNTIME_DIR/hypr-pairs/pairs.tsv` | Registry (runtime only, never committed) |

Dependencies: `hyprctl`, `jq` (already in `apt-packages.txt`), `flock`.

### Registry format

One line per paired window, tab-separated:

```
<group>\t<window-address>\t<kind>\t<launched-epoch>
```

- `group`: address of the terminal window. One terminal can own several children (IDE now, browser later), so the group is the terminal.
- `kind`: `terminal`, `cursor`, `zed` (later `browser`).
- The terminal gets its own row (`kind=terminal`) so the daemon can look up membership from any window.
- Rows whose address is no longer in `hyprctl clients -j` are pruned on every read and write.
- The launcher does not pick colors. The daemon derives one from the group address.

### Launch flow

1. **Hyprland check.** If `HYPRLAND_INSTANCE_SIGNATURE` is unset, just exec the IDE and skip pairing, so the command still works over SSH or on WSL.
2. **Parse args.** Default is Cursor and `.`. Resolve the path to absolute. Fail early if the folder doesn't exist.
3. **Serialize.** Take a `flock` on `hypr-pairs/launch.lock` so two simultaneous launches can't claim each other's window.
4. **Identify the terminal window.**
   - Primary: walk the launcher's PPID chain and match against the `pid` of windows in `hyprctl clients -j`. This is correct even if focus has moved.
   - Fallback: `hyprctl activewindow -j`.
   - Abort pairing (still launch the IDE) if neither finds a window.
5. **Pick the target monitor.** The rightmost monitor, found as the highest `x` in `hyprctl monitors -j`. Override with `IDE_MONITOR=<name>`. This avoids hard-coding `DP-1`.
6. **Snapshot** the addresses of existing windows whose class matches the chosen IDE.
7. **Launch** with `hyprctl dispatch exec "[monitor <name>] <ide> <path>"`. Exec rules are not applied by Hyprland when the app is already running and hands the request to the existing process, so step 9 covers placement as well.
8. **Wait for the new window.** Poll `hyprctl clients -j` every 0.2 s for up to ~20 s (Electron cold starts are slow) for a matching class whose address is not in the snapshot.
9. **Place it.** If the window isn't on the target monitor, move it to that monitor's active workspace with `movetoworkspacesilent`.
10. **Register** the terminal row (if absent) and the IDE row.
11. **Existing-window case.** If the folder is already open, the IDE just focuses the old window and no new one appears. On timeout, look for an existing window of that class whose title contains the folder's basename, and re-pair that one to this terminal (replacing any older row for that window).

Steps 3 to 11 run in a detached subshell (`setsid`, output to `/dev/null`) so the terminal isn't blocked. Failures are logged to `$XDG_RUNTIME_DIR/hypr-pairs/ide.log`.

### Window classes

| IDE | Command | Class (to verify) |
|-----|---------|-------------------|
| Cursor | `cursor` | `Cursor` |
| Zed | `zed` | `dev.zed.Zed` |

The class values are my expectation, not confirmed. Confirm with `hyprctl clients | grep class` while each IDE is open, then match case-insensitively in a variable at the top of the script.

### Install wiring

- New `install_ide_launcher` in `extras.sh`: `ln -sfn` the launcher into `~/.local/bin/ide`, matching how the other config links are made.
- Add the call to `install.sh` after the IDE installs, and a check in `verify.sh` that `ide` resolves.
- `extras.sh` and `verify.sh` currently have uncommitted changes, so these edits must be made carefully on top of them.
- Write only. Per standing preference, the install scripts are not run or tested by the assistant.

## Open questions

1. **One terminal window per story?** If every story shares one kitty window (Herdr workspaces inside it), every IDE pairs with that one window and they'll share a color. Per-story colors need one terminal window per story. Decision needed before the daemon plan, not for the launcher.
2. **Name `ide`.** Not currently used on this machine (`command -v ide` is empty). Keep, or prefer something else?
3. **Zed on Wayland/XWayland.** Confirm it produces a normal Hyprland window with a stable class.

## Manual verification checklist (for you to run)

1. From a kitty window, `ide` in a project folder: Cursor opens on the right monitor, and `pairs.tsv` has two rows sharing a group.
2. Repeat with Cursor already running: a second window opens and is placed and paired correctly.
3. `ide -z`: same, with Zed.
4. `ide` on a folder already open: the existing window is re-paired, with no duplicate row.
5. Close the IDE, then run `ide` again: stale rows are pruned.
6. Run `ide` from a plain SSH session or WSL: the IDE launches and pairing is skipped without errors.
7. Launch two IDEs back to back from two terminals: each pairs with its own terminal.

## Next plans

1. Highlight daemon: `socket2` focus events, `setprop` border colors, per-group colors.
2. Browser pairing via kitty `open_url_with` and a dedicated browser window per group.
