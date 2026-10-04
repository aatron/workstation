#!/usr/bin/env bash
# Read-only checks of this machine against what install.sh sets up. Changes
# nothing. Each failure names the step that fixes it:
#   ./verify.sh                 check everything
#   ./install.sh STEP...        fix, then run ./verify.sh again
# Exit status is 1 if any check failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"

pass=0
fail=0
fix_steps=()

# check STEP "label" command...   (quiet; the command's exit status decides)
check() {
	local step=$1 label=$2
	shift 2
	if "$@" >/dev/null 2>&1; then
		printf '  ok    %s\n' "$label"
		pass=$((pass + 1))
	else
		printf '  FAIL  %s   [fix: install.sh %s]\n' "$label" "$step"
		fail=$((fail + 1))
		[[ " ${fix_steps[*]:-} " == *" $step "* ]] || fix_steps+=("$step")
	fi
}

section() { printf '\n%s\n' "$1"; }

linked() { [[ -L "$1" && "$(readlink -f "$1")" == "$(readlink -f "$2")" ]]; }
has_text() { grep -qiF -- "$2" "$1"; }
nonempty() { [[ -s "$1" ]]; }

missing_packages() {
	local p out=()
	while read -r p; do
		dpkg -s "$p" >/dev/null 2>&1 || out+=("$p")
	done < <(grep -vE '^\s*(#|$)' "$SCRIPT_DIR/apt-packages.txt")
	((${#out[@]} == 0)) && return 0
	echo "    missing packages: ${out[*]}"
	return 1
}

missing_extensions() {
	local installed ext out=()
	installed="$(cursor --list-extensions 2>/dev/null)" || return 1
	while read -r ext; do
		grep -qixF "$ext" <<<"$installed" || out+=("$ext")
	done < <(grep -vE '^\s*(#|$)' "$SCRIPT_DIR/cursor/extensions.txt")
	((${#out[@]} == 0)) && return 0
	echo "    missing extensions: ${out[*]}"
	return 1
}

hyprland_config_ok() {
	XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}" Hyprland --verify-config -c "$CFG/hypr/hyprland.conf" 2>&1 | grep -q 'config ok'
}

scheme_background() {
	python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["special"]["background"])' "$CFG/wallust/colorschemes/$1.json"
}

theme_rendered() {
	local name bg
	name="$(cat "$HOME/.local/state/theme" 2>/dev/null)" || return 1
	bg="$(scheme_background "$name")" || return 1
	has_text "$CFG/kitty/colors.conf" "background $bg" &&
		has_text "$CFG/waybar/colors.css" "background $bg;"
}

# Failures here only mean "no desktop session", so they can't be fixed by a step.
gnome_dvorak() { gsettings get org.gnome.desktop.input-sources sources | grep -q 'us+dvorak'; }

section "Packages"
check apt_packages "all packages in apt-packages.txt" missing_packages

section "Commands"
for pair in \
	git:apt_packages gh:apt_packages vim:apt_packages micro:apt_packages curl:apt_packages jq:apt_packages \
	fzf:apt_packages zoxide:apt_packages gm:apt_packages python3:apt_packages pipx:apt_packages \
	node:install_node npm:install_node uv:install_python dotnet:install_dotnet cargo:install_rust go:install_go aspire:install_aspire \
	wallust:install_wallust claude:install_claude_code agent:install_cursor_agent \
	herdr:install_herdr playwright-cli:install_playwright_cli az:install_azure_cli cursor:install_cursor zed:install_zed \
	kitty:install_kitty kitten:install_kitty theme:setup_theme Hyprland:install_hyprland \
	waybar:apt_packages mako:apt_packages fuzzel:apt_packages firefox:setup_firefox; do
	check "${pair#*:}" "${pair%%:*} on PATH" command -v "${pair%%:*}"
done
check install_rust "a Rust toolchain is installed (rustc works)" rustc --version
check install_dotnet "a .NET SDK is installed" bash -c "dotnet --list-sdks | grep -q ."

section "Config links (repo -> home)"
while read -r link src step; do
	check "$step" "$link" linked "$link" "$SCRIPT_DIR/$src"
done <<EOF2
$CFG/kitty/kitty.conf kitty/kitty.conf setup_kitty
$CFG/hypr/hyprland.conf hypr/hyprland.conf setup_hyprland
$CFG/hypr/common hypr/common setup_hyprland
$CFG/hypr/profiles hypr/profiles setup_hyprland
$HOME/.local/bin/hypr-profile hypr/scripts/hypr-profile setup_hyprland
$CFG/Cursor/User/settings.json cursor/settings.json setup_cursor_settings
$CFG/Cursor/User/keybindings.json cursor/keybindings.json setup_cursor_settings
$CFG/zed/settings.json zed/settings.json setup_zed_settings
$CFG/wallust/wallust.toml theme/wallust.toml setup_theme
$CFG/wallust/templates theme/templates setup_theme
$CFG/wallust/colorschemes theme/colorschemes setup_theme
$CFG/waybar/config.jsonc waybar/config.jsonc setup_theme
$CFG/waybar/style.css waybar/style.css setup_theme
$HOME/.local/bin/theme theme/theme setup_theme
$HOME/.local/bin/ai-usage waybar/ai-usage setup_theme
EOF2

section "Theme (current: $(cat "$HOME/.local/state/theme" 2>/dev/null || echo none))"
check setup_theme "a theme has been applied" test -f "$HOME/.local/state/theme"
check setup_theme "kitty and Waybar colors match the current scheme" theme_rendered
for f in "$CFG/hypr/colors.conf" "$CFG/fuzzel/fuzzel.ini" "$CFG/mako/config" "$CFG/zed/themes/wallust.json"; do
	check setup_theme "rendered: $f" nonempty "$f"
done

section "Configs parse"
check install_herdr_plus "the herdr-plus plugin is installed" bash -c "herdr plugin list | grep -q cloudmanic.herdr-plus"
check install_herdr_navigator "the herdr-navigator plugin is installed" bash -c "herdr plugin list | grep -q herdr-navigator"
check setup_herdr_config "herdr keybindings are in config.toml" has_text "$CFG/herdr/config.toml" "BEGIN workstation herdr keys"
check setup_herdr_config "herdr theme is in config.toml" has_text "$CFG/herdr/config.toml" "BEGIN workstation herdr theme"
check setup_hyprland "a Hyprland monitor profile is selected (hypr-profile lists them)" test -e "$CFG/hypr/profile.conf"
check setup_hyprland "Hyprland accepts hyprland.conf (incl. profile, common/ and colors.conf)" hyprland_config_ok
check setup_firefox "Firefox policies deployed and identical to the repo" \
	bash -c "python3 -m json.tool /etc/firefox/policies/policies.json && cmp -s /etc/firefox/policies/policies.json '$SCRIPT_DIR/firefox/policies.json'"
check install_cursor_extensions "Cursor has every extension in cursor/extensions.txt" missing_extensions

section "Desktop"
check install_kitty "kitty menu entry points at an executable" \
	bash -c "grep '^Exec=' '$HOME/.local/share/applications/kitty.desktop' | head -1 | sed 's/^Exec=//; s/ .*//' | xargs test -x"
check setup_kitty "kitty is the default terminal (xdg-terminals.list)" has_text "$CFG/xdg-terminals.list" kitty.desktop
check setup_kitty "ssh wrapper in ~/.bashrc" has_text "$HOME/.bashrc" 'TERM=xterm-256color command ssh'
check install_hyprland "Hyprland login session installed" test -f /usr/share/wayland-sessions/hyprland.desktop
check install_hyprland "hyprland-guiutils installed (hyprland-dialog)" command -v hyprland-dialog
check setup_updates "weekly update timer is enabled" systemctl is-enabled --quiet workstation-update.timer
check install_ntfy "ntfy server answers on 127.0.0.1:2586" curl -fsS http://127.0.0.1:2586/v1/health
check setup_ntfy_client "ntfy client service is running" systemctl --user is-active --quiet ntfy-client.service
check install_hyprland "no Hyprland program loads Ubuntu's old hypr libraries" bash -c "source '$SCRIPT_DIR/extras.sh'; hypr_check_abi"
for skill in herdr:install_herdr_skill hyprland-control:install_hyprland_skill playwright-cli:install_playwright_skill; do
	check "${skill#*:}" "${skill%%:*} skill in ~/.agents/skills (Cursor)" test -s "$HOME/.agents/skills/${skill%%:*}/SKILL.md"
	check "${skill#*:}" "${skill%%:*} skill linked into ~/.claude/skills (Claude Code)" test -L "$HOME/.claude/skills/${skill%%:*}" -a -s "$HOME/.claude/skills/${skill%%:*}/SKILL.md"
done
check setup_hyprland "hyprlock has a config (else Super+L does nothing)" test -e "$HOME/.config/hypr/hyprlock.conf"
check install_hyprland "hyprlock has its PAM service (else it cannot unlock)" test -f /etc/pam.d/hyprlock
check install_hyprland "hyprlock and hyprpaper installed" bash -c "command -v hyprlock && command -v hyprpaper"
check setup_keyboard "GNOME has the Dvorak layout (needs a desktop session)" gnome_dvorak

echo
echo "=== $pass ok, $fail failed ==="
if ((fail > 0)); then
	echo "fix:  $SCRIPT_DIR/install.sh ${fix_steps[*]}"
	echo "then: $SCRIPT_DIR/verify.sh"
	exit 1
fi
