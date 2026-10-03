#!/usr/bin/env bash
# Ptyxis (Ubuntu's default terminal) settings.
#
# Ctrl+C / Ctrl+V copy and paste. Ctrl+C still interrupts when nothing is
# selected: Ptyxis disables its copy action without a selection, so the key
# falls through to the shell.
set -euo pipefail

if ! gsettings list-schemas | grep -qx org.gnome.Ptyxis.Shortcuts; then
	echo "Ptyxis not installed, skipping terminal settings." >&2
	exit 0
fi

gsettings set org.gnome.Ptyxis.Shortcuts copy-clipboard '<ctrl>c'
gsettings set org.gnome.Ptyxis.Shortcuts paste-clipboard '<ctrl>v'
