# Sourced by install.sh — non-apt installs and config.

have() { command -v "$1" >/dev/null 2>&1; }

# Append a line to ~/.bashrc unless it is already there.
bashrc_line() {
	grep -qxF "$1" "$HOME/.bashrc" 2>/dev/null || echo "$1" >> "$HOME/.bashrc"
}

install_claude_code() {
	have claude || [[ -x "$HOME/.local/bin/claude" ]] || curl -fsSL https://claude.ai/install.sh | bash
}

install_cursor_agent() {
	have agent || [[ -x "$HOME/.local/bin/agent" ]] || curl -fsSL https://cursor.com/install | bash
}

install_herdr() {
	have herdr || [[ -x "$HOME/.local/bin/herdr" ]] || curl -fsSL https://herdr.dev/install.sh | sh
}

# apt's rustup puts the cargo/rustc proxies in /usr/bin; it ships no toolchain.
install_rust() {
	rustc --version >/dev/null 2>&1 || rustup default stable
}

# Zed has no apt/snap package; the official installer is per-user (~/.local/zed.app)
# and Zed updates itself.
install_zed() {
	have zed || [[ -x "$HOME/.local/bin/zed" ]] || curl -fsSL https://zed.dev/install.sh | sh
}

# Matches the repo file Cursor's own postinst writes, so the two never conflict.
install_cursor() {
	if [[ ! -f /usr/share/keyrings/anysphere.gpg ]]; then
		curl -fsSL https://downloads.cursor.com/keys/anysphere.asc | gpg --dearmor | sudo tee /usr/share/keyrings/anysphere.gpg >/dev/null
	fi
	if [[ ! -f /etc/apt/sources.list.d/cursor.sources ]]; then
		sudo tee /etc/apt/sources.list.d/cursor.sources >/dev/null <<-'SRC'
			Types: deb
			URIs: https://downloads.cursor.com/aptrepo
			Suites: stable
			Components: main
			Architectures: amd64,arm64
			Signed-By: /usr/share/keyrings/anysphere.gpg
		SRC
		sudo apt-get update
	fi
	sudo apt-get install -y cursor
}

# Link ubuntu/cursor/{settings,keybindings}.json into Cursor's User dir, so edits
# made in Cursor land in the repo. An existing real file is kept as .bak.
# (Separate from vscodesettings/, which is shared with Windows/WSL.)
setup_cursor_settings() {
	local dir f name
	dir="${XDG_CONFIG_HOME:-$HOME/.config}/Cursor/User"
	mkdir -p "$dir"
	for name in settings.json keybindings.json; do
		f="$dir/$name"
		[[ -f "$f" && ! -L "$f" ]] && mv "$f" "$f.bak"
		ln -sfn "$SCRIPT_DIR/cursor/$name" "$f"
	done
}

setup_zoxide() {
	bashrc_line 'eval "$(zoxide init bash)"'
}

# Kagi + LastPass extensions and Kagi as default search, via enterprise policy.
# /etc/firefox/policies is read by both the snap and Mozilla's deb.
setup_firefox() {
	sudo install -D -m 644 "$SCRIPT_DIR/firefox/policies.json" /etc/firefox/policies/policies.json
}

# Ghostty: repo config, Gogh color theme, and default terminal (Ctrl+Alt+T).
GOGH_THEME=nord
setup_ghostty() {
	local dir="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
	mkdir -p "$dir"
	[[ -f "$dir/config.ghostty" && ! -L "$dir/config.ghostty" ]] && mv "$dir/config.ghostty" "$dir/config.ghostty.bak"
	ln -sfn "$SCRIPT_DIR/ghostty/config.ghostty" "$dir/config.ghostty"

	local tmp
	tmp="$(mktemp -d)"
	curl -fsSL -o "$tmp/apply-colors.sh" https://github.com/Gogh-Co/Gogh/raw/master/apply-colors.sh
	curl -fsSL -o "$tmp/theme.sh" "https://github.com/Gogh-Co/Gogh/raw/master/installs/$GOGH_THEME.sh"
	TERMINAL=ghostty GOGH_NONINTERACTIVE=1 GOGH_APPLY_SCRIPT="$tmp/apply-colors.sh" bash "$tmp/theme.sh"
	rm -rf "$tmp"

	echo com.mitchellh.ghostty.desktop > "${XDG_CONFIG_HOME:-$HOME/.config}/xdg-terminals.list"
}

# Hyprland: repo config. Waybar uses its packaged default (/etc/xdg/waybar)
# until ~/.config/waybar exists. Hyprland shows up as a login-screen session
# alongside GNOME.
setup_hyprland() {
	local dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
	mkdir -p "$dir"
	[[ -f "$dir/hyprland.conf" && ! -L "$dir/hyprland.conf" ]] && mv "$dir/hyprland.conf" "$dir/hyprland.conf.bak"
	ln -sfn "$SCRIPT_DIR/hypr/hyprland.conf" "$dir/hyprland.conf"
}
