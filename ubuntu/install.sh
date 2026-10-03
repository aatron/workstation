#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

if [[ $EUID -eq 0 ]]; then
	echo "Run as your normal user (sudo is used where needed)." >&2
	exit 1
fi

sudo apt-get update
sudo apt-get upgrade -y
grep -vE '^\s*(#|$)' "$SCRIPT_DIR/apt-packages.txt" | xargs sudo apt-get install -y

source "$SCRIPT_DIR/extras.sh"
install_rust
install_claude_code
install_cursor_agent
install_herdr
install_cursor
install_zed
setup_cursor_settings
setup_zoxide
setup_firefox
setup_ghostty
setup_hyprland

sudo apt-get autoremove -y
