# Ubuntu Set-up

## Install

Needs a fresh **Ubuntu 26.04 desktop**, internet, and an Ubuntu Pro token (`ntfy` is
installed from its esm-apps repo). Run everything from a terminal **inside the desktop
session** (not over SSH or a text console): the install uses your user D-Bus session.
`install.sh` checks all three before it starts and says what to fix.

```bash
sudo pro attach <token>   # token from ubuntu.com/pro/dashboard
sudo apt install -y git
git clone https://github.com/aatron/workstation.git
./workstation/ubuntu/install.sh
```

It asks for your sudo password once and keeps it valid. Expect a long run: Hyprland
and its libraries are compiled from source (see `extras.sh`). When it finishes, a test
notification pops up and `verify.sh` lists anything that failed.

Then log out and choose nothing: Hyprland is already the preselected session (GNOME
stays in the gear menu). Add a wallpaper by dropping `desktop.jpg` into
`ubuntu/wallpapers/` and running `./ubuntu/install.sh setup_wallpaper`.

Everything in the install is pinned or floats to the latest stable on purpose: apt
packages and the language toolchains (rust, node LTS, python, .NET) are the newest at
install time, the Hyprland stack is pinned in `extras.sh`.

## Sign-ins

Open a **new terminal** and paste:

```bash
{
read -rp "Git name: " name && git config --global user.name "$name"
read -rp "Git email: " email && git config --global user.email "$email"
agent login
claude   # sign in, then /exit
read -rp "Quit Firefox, then press Enter "
setsid -f cursor >/dev/null 2>&1
setsid -f firefox about:policies https://kagi.com/signin >/dev/null 2>&1
}
```

Then finish by hand:

- [ ] Cursor: sign in
- [ ] Firefox: `about:policies` shows Kagi and LastPass as active
- [ ] Kagi: sign in (tab already open)
- [ ] LastPass: sign in from the toolbar icon
- [ ] Azure CLI: `az login`
- [ ] OneDrive: run `onedrive`, open the sign-in link, then `systemctl --user enable --now onedrive`

## Themes

Two desktop themes, switched from a terminal (starts on `everforest`):

```bash
theme everforest   # woodsy greens and browns
theme nightfox     # muted Tron cyan on dark blue
```

Kitty, Waybar, Hyprland borders, the launcher, notifications and Zed change together. Not themed by this: Cursor (stays on Abyss), Firefox and GTK apps. Kitty windows already open reload at once; new windows pick it up anyway.

## Updates

A systemd timer runs `update.sh` Fridays at 6pm while the machine is on (a missed Friday
is skipped): apt, snap, rust, node, python, .NET and Hyprland patch releases. It reports
to the local ntfy server (`curl -d msg http://127.0.0.1:2586/workstation` sends a toast).
A new Hyprland starts at your next login. Run it by hand with `sudo ./ubuntu/update.sh --force`;
new Hyprland minor versions are reported, not installed: bump the pin in `extras.sh`.

## Verify and fix

`install.sh` ends by running `verify.sh`, which only reads and changes nothing. It checks the packages, commands, config links, the Hyprland config, the rendered theme and more. Each failure names the step that fixes it:

```bash
./ubuntu/verify.sh                      # check everything, any time
./ubuntu/install.sh setup_theme         # re-run just the failed step(s)
./ubuntu/verify.sh                      # confirm
./ubuntu/install.sh --list              # all step names, in order
```

A failed step doesn't stop the others, so one run shows every problem. The full output of each install run is logged to `~/.local/state/workstation-install.log`. To change something: edit the file in `ubuntu/`, re-run its step, then `verify.sh`.
