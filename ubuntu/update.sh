#!/usr/bin/env bash
# Weekly update of everything install.sh set up: apt, snap, language toolchains
# (rust, node, python, dotnet) and the Hyprland source stack (patch releases;
# new minor versions are only reported). Run as root by workstation-update.timer
# on Fridays; by hand: sudo ./update.sh [--force]. Result goes to the local ntfy
# topic. The Hyprland stack is updated while you are logged in (see
# build_hypr_project); a new Hyprland starts at your next login.
#
# Runs from the repo checkout, so it runs whatever is in the repo as root: anyone
# who can write the repo can get root at the next run. It pulls the repo first so
# changes made on another machine (new pins, new steps) apply here too.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
export DEBIAN_FRONTEND=noninteractive

STATE=/var/lib/workstation-update
STAMP="$STATE/last-success"

main() {
	if [[ $EUID -ne 0 ]]; then
		echo "Run as root: sudo $0" >&2
		return 1
	fi
	export WORKSTATION_USER="${WORKSTATION_USER:-${SUDO_USER:-}}"
	[[ -n "$WORKSTATION_USER" ]] || { echo "WORKSTATION_USER is not set" >&2; return 1; }
	mkdir -p "$STATE"

	# Skip when a run succeeded in the last 6 days (a hand-run, or a repeat firing).
	if [[ ${1:-} != --force && -f "$STAMP" && -n "$(find "$STAMP" -mtime -6)" ]]; then
		echo "last successful update was under 6 days ago; nothing to do (--force overrides)"
		return 0
	fi

	source "$SCRIPT_DIR/extras.sh"
	local user_path="$USER_HOME/.local/bin:$USER_HOME/.cargo/bin:$PATH"
	local ok=() failed=() notes=() step

	# mode root: this shell; mode user: as $WORKSTATION_USER. Each step gets a fresh
	# shell that re-sources extras.sh, so a repo pull is picked up by later steps.
	run() {
		local mode="$1" step="$2"
		echo "==> $step"
		if [[ $mode == user ]]; then
			as_user env PATH="$user_path" SCRIPT_DIR="$SCRIPT_DIR" bash -euo pipefail -c 'source "$SCRIPT_DIR/extras.sh"; "$1"' _ "$step"
		else
			bash -euo pipefail -c 'source "$SCRIPT_DIR/extras.sh"; "$1"' _ "$step"
		fi
	}
	record() { if "$@"; then ok+=("$2"); else failed+=("$2"); fi; }

	record run user update_repo
	record run root update_apt
	record run root update_snap
	for step in install_rust install_node install_python install_dotnet install_herdr_skill; do
		record run user "$step"
	done

	record run root install_hyprland

	local newer
	newer="$(as_user env PATH="$user_path" SCRIPT_DIR="$SCRIPT_DIR" bash -c 'source "$SCRIPT_DIR/extras.sh"; hypr_newer_report' 2>/dev/null)"
	[[ -z "$newer" ]] || notes+=("New Hyprland minor versions (bump pins in extras.sh):" "$newer")
	[[ -f /var/run/reboot-required ]] && notes+=("Reboot required")

	local title body
	if ((${#failed[@]} == 0)); then
		title="Weekly update done"
		touch "$STAMP"
	else
		title="Weekly update: ${#failed[@]} step(s) failed"
	fi
	body="ok: ${ok[*]:-none}"
	((${#failed[@]} > 0)) && body+=$'\n'"failed: ${failed[*]} (journalctl -u workstation-update)"
	((${#notes[@]} > 0)) && body+=$'\n'"$(printf '%s\n' "${notes[@]}")"
	echo "$title"; echo "$body"
	# A delivered summary (success or failed steps) ends the run cleanly. Only a run
	# that could not report, or that never got this far, leaves the unit failed, and
	# workstation-update-failed.service (OnFailure=) sends the crash notice then.
	if curl -fsS -H "Title: $title" -H "Priority: $((${#failed[@]} > 0 ? 4 : 3))" -d "$body" "$NTFY_URL/$NTFY_TOPIC" >/dev/null; then
		return 0
	fi
	echo "could not reach ntfy" >&2
	((${#failed[@]} == 0))
}

main "$@"
exit
