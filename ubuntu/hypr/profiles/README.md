# Hyprland profiles

A profile describes one physical monitor setup. Everything else (binds, rules,
look) lives in `../common/` and is shared.

| File | What |
|------|------|
| `default.conf` | Fallback: every monitor at its preferred mode, left to right |
| `_example.conf` | Template for your own profile (never selected) |
| `<name>.conf` | Monitors and the role variables for that setup |
| `wallpaper/<name>.conf` | hyprpaper template (`@WALLPAPERS@` is filled in); falls back to `wallpaper/default.conf` |

## Where profiles live

Real monitor descriptions contain serial numbers, so machine-specific profiles
are **not** kept in this repo. Put them in `~/.config/hypr/local-profiles/<name>.conf`
(and optionally `~/.config/hypr/local-profiles/wallpaper/<name>.conf`). Both
places are searched; a local profile of the same name wins. Start from
`_example.conf`.

## Use

```
hypr-profile             # list profiles, mark the current one
hypr-profile home        # switch: relinks, re-renders the wallpaper config, reloads
hypr-profile --auto      # pick by connected monitors (runs at every Hyprland start)
```

The profile lives in the symlink `~/.config/hypr/profile.conf`, so it is per
machine. Until you switch by name, `--auto` chooses at each start the profile
whose monitors are all connected, else `default`. Switching by name creates
`~/.config/hypr/profile.chosen`, which turns auto-detection off for that machine.
No machine name is stored anywhere.

## Rules for writing a profile

- Match monitors by `desc:` (see `hyprctl monitors`), not by `DP-1`.
- Declare each monitor as `$role = desc:...` on its own line; `--auto` matches a
  profile by these lines.
- Define the same role variables (`$left`, `$right`, ...) in every profile.
  Common files use roles only, never connector names.
- End with the catch-all `monitor = , preferred, auto, auto`.
- Profiles starting with `_` are shared fragments, not selectable. A future
  `work-a` and `work-b` can `source` a shared `_work.conf` and differ only in the
  `monitor =` positions.
- To add a profile: copy `_example.conf` to `local-profiles/<name>.conf`, optionally
  add `local-profiles/wallpaper/<name>.conf`, and run `hypr-profile <name>`.
