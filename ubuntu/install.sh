#!/usr/bin/env bash
# Usage:
#   ./install.sh              run every step in order, then verify.sh
#   ./install.sh STEP...      re-run only these steps (e.g. setup_theme)
#   ./install.sh --list       print the step names
#
# Each step runs in its own shell. A failed step is reported and the rest
# still run, so one problem doesn't hide the others; apt_packages is the
# exception, since everything depends on it. The summary names the failed
# steps and the command to re-run them. Output is also logged to $LOG.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
export DEBIAN_FRONTEND=noninteractive
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

LOG="$HOME/.local/state/workstation-install.log"

# Order matters: languages before tools and IDEs, theme last.
STEPS=(
	apt_packages
	# Languages (the apt ones come from apt-packages.txt)
	install_rust
	install_node
	install_python
	install_dotnet
	install_aspire
	install_wallust
	# Agents and CLIs
	install_claude_code
	install_cursor_agent
	install_herdr
	install_herdr_skill
	install_hyprland_skill
	install_playwright_cli
	install_playwright_skill
	install_azure_cli
	# IDEs
	install_cursor
	install_cursor_extensions
	install_zed
	setup_cursor_settings
	setup_zed_settings
	# Desktop and terminal
	setup_zoxide
	setup_firefox
	install_kitty
	setup_kitty
	setup_keyboard
	install_ntfy
	setup_ntfy_client
	install_hyprland
	setup_hyprland
	set_default_session
	setup_wallpaper
	setup_theme
	apt_cleanup
	setup_updates
	# Last: sends the test notification
	ntfy_test
)

if [[ ${1:-} == --list ]]; then
	printf '%s\n' "${STEPS[@]}"
	exit 0
fi

if [[ $EUID -eq 0 ]]; then
	echo "Run as your normal user (sudo is used where needed)." >&2
	exit 1
fi

# Fail early, with the fix, instead of halfway through a long run on a new machine.
. /etc/os-release
if [[ ${VERSION_CODENAME:-} != resolute && -z ${ALLOW_OTHER_RELEASE:-} ]]; then
	echo "This setup is written for Ubuntu 26.04 (resolute); this is '${VERSION_CODENAME:-unknown}'." >&2
	echo "Set ALLOW_OTHER_RELEASE=1 to try anyway." >&2
	exit 1
fi
if ! pro status --format json 2>/dev/null | grep -Eq '"attached": ?true'; then
	echo "Attach Ubuntu Pro first (ntfy comes from its esm-apps repo): sudo pro attach <token>" >&2
	exit 1
fi
if [[ ! -S ${XDG_RUNTIME_DIR:-/nonexistent}/bus ]]; then
	echo "Run this from a terminal inside the desktop session (it needs your user D-Bus session)." >&2
	exit 1
fi

# Ask for the sudo password once and keep it valid: the Hyprland build alone runs
# longer than sudo's default 15 minute timeout. The loop ends when this script does.
sudo -v
(while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done) &

if (($# > 0)); then
	for want in "$@"; do
		[[ " ${STEPS[*]} " == *" $want "* ]] || { echo "unknown step: $want (see ./install.sh --list)" >&2; exit 1; }
	done
	run=("$@")
else
	run=("${STEPS[@]}")
fi

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "=== install $(date -Is) ==="

ok=()
failed=()
for step in "${run[@]}"; do
	echo "==> $step"
	if bash -euo pipefail -c 'source "$SCRIPT_DIR/extras.sh"; "$1"' _ "$step"; then
		ok+=("$step")
	else
		failed+=("$step")
		echo "!! $step failed"
		[[ $step == apt_packages ]] && { echo "Stopping: later steps need these packages." >&2; break; }
	fi
done

echo
echo "=== summary: ${#ok[@]} ok, ${#failed[@]} failed ==="
if ((${#failed[@]} > 0)); then
	echo "failed: ${failed[*]}"
	echo "re-run: $SCRIPT_DIR/install.sh ${failed[*]}"
	echo "log:    $LOG"
fi

# A full run ends with the read-only checks.
if (($# == 0)); then
	"$SCRIPT_DIR/verify.sh" || true
fi

((${#failed[@]} == 0))
