# Sourced by install.sh — non-apt installs and config.

have() { command -v "$1" >/dev/null 2>&1; }

# The weekly update service runs as root on behalf of WORKSTATION_USER; install.sh
# runs as that user. These let one function body work in both: as_root is sudo for
# a normal user, as_user is runuser for root.
WORKSTATION_USER="${WORKSTATION_USER:-${USER:-$(id -un)}}"
USER_HOME="$(getent passwd "$WORKSTATION_USER" | cut -d: -f6)"
as_root() { if ((EUID == 0)); then "$@"; else sudo "$@"; fi; }
as_user() {
	if ((EUID == 0)); then
		runuser -u "$WORKSTATION_USER" -- env HOME="$USER_HOME" "$@"
	else
		"$@"
	fi
}

# Append a line to ~/.bashrc unless it is already there.
bashrc_line() {
	grep -qxF "$1" "$HOME/.bashrc" 2>/dev/null || echo "$1" >> "$HOME/.bashrc"
}

# System packages: update, upgrade, then everything in apt-packages.txt.
apt_packages() {
	sudo apt-get update
	sudo apt-get upgrade -y
	grep -vE '^\s*(#|$)' "$SCRIPT_DIR/apt-packages.txt" | xargs sudo apt-get install -y
}

apt_cleanup() {
	sudo apt-get autoremove -y
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
	rustup update stable
}

# wallust renders one color scheme into every themed app; stable release from
# crates.io, built with cargo into ~/.local/bin. Needs install_rust first.
install_wallust() {
	have wallust || [[ -x "$HOME/.local/bin/wallust" ]] || cargo install --locked --version 3.5.1 --root "$HOME/.local" wallust
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

# Microsoft's apt repo for the current Ubuntu release (same layout as their install script).
install_azure_cli() {
	have az && return 0
	if [[ ! -f /etc/apt/keyrings/microsoft.gpg ]]; then
		sudo install -d -m 755 /etc/apt/keyrings
		curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg >/dev/null
	fi
	if [[ ! -f /etc/apt/sources.list.d/azure-cli.sources ]]; then
		sudo tee /etc/apt/sources.list.d/azure-cli.sources >/dev/null <<-SRC
			Types: deb
			URIs: https://packages.microsoft.com/repos/azure-cli/
			Suites: $(lsb_release -cs)
			Components: main
			Architectures: $(dpkg --print-architecture)
			Signed-By: /etc/apt/keyrings/microsoft.gpg
		SRC
		sudo apt-get update
	fi
	sudo apt-get install -y azure-cli
}

# Install the IDs listed in cursor/extensions.txt that Cursor doesn't have yet.
install_cursor_extensions() {
	local installed ext
	installed="$(cursor --list-extensions 2>/dev/null || true)"
	while read -r ext; do
		grep -qixF "$ext" <<<"$installed" || cursor --install-extension "$ext" || echo "warning: could not install Cursor extension $ext" >&2
	done < <(grep -vE '^\s*(#|$)' "$SCRIPT_DIR/cursor/extensions.txt")
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

# Link ubuntu/zed/settings.json (installs the C# and TOML extensions on first
# launch). An existing real file is kept as .bak.
setup_zed_settings() {
	local dir="${XDG_CONFIG_HOME:-$HOME/.config}/zed"
	mkdir -p "$dir"
	[[ -f "$dir/settings.json" && ! -L "$dir/settings.json" ]] && mv "$dir/settings.json" "$dir/settings.json.bak"
	ln -sfn "$SCRIPT_DIR/zed/settings.json" "$dir/settings.json"
}

setup_zoxide() {
	bashrc_line 'eval "$(zoxide init bash)"'
}

# Kagi + LastPass extensions and Kagi as default search, via enterprise policy.
# /etc/firefox/policies is read by both the snap and Mozilla's deb.
setup_firefox() {
	sudo install -D -m 644 "$SCRIPT_DIR/firefox/policies.json" /etc/firefox/policies/policies.json
}

# kitty from the official installer (-> ~/.local/kitty.app): apt's kitty comes
# from the Ubuntu Pro ESM source, which fails without a Pro subscription, and
# the package lags upstream. Re-run the installer to update.
install_kitty() {
	local app="$HOME/.local/kitty.app" apps="$HOME/.local/share/applications"
	[[ -x "$app/bin/kitty" ]] || curl -fsSL https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin launch=n

	mkdir -p "$HOME/.local/bin" "$apps"
	ln -sf "$app/bin/kitty" "$app/bin/kitten" "$HOME/.local/bin/"
	cp "$app/share/applications/kitty.desktop" "$app/share/applications/kitty-open.desktop" "$apps/"
	sed -i "s|Icon=kitty|Icon=$app/share/icons/hicolor/256x256/apps/kitty.png|g; s|Exec=kitty|Exec=$app/bin/kitty|g" "$apps"/kitty*.desktop
}

# kitty: repo config, default terminal (Ctrl+Alt+T on GNOME), and an ssh
# wrapper. Colors come from wallust (see setup_theme). Remote hosts and VMs
# usually lack kitty's terminfo (xterm-kitty), which breaks arrow keys and
# clear; the wrapper makes ssh present xterm-256color instead. (`kitten ssh` is
# kitty's alternative, but it copies files onto each remote host.)
setup_kitty() {
	local dir="${XDG_CONFIG_HOME:-$HOME/.config}/kitty"
	mkdir -p "$dir"
	[[ -f "$dir/kitty.conf" && ! -L "$dir/kitty.conf" ]] && mv "$dir/kitty.conf" "$dir/kitty.conf.bak"
	ln -sfn "$SCRIPT_DIR/kitty/kitty.conf" "$dir/kitty.conf"

	echo kitty.desktop > "${XDG_CONFIG_HOME:-$HOME/.config}/xdg-terminals.list"
	bashrc_line 'ssh() { TERM=xterm-256color command ssh "$@"; }'
}

# Super+Space toggles qwerty/dvorak (like Windows' Win+Space). GNOME already
# binds Super+Space to switch input source; it only needs Dvorak added.
# Hyprland does the same in hypr/hyprland.conf.
setup_keyboard() {
	gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('xkb', 'us+dvorak')]" ||
		echo "warning: could not set GNOME input sources (no desktop session?)" >&2
}

# The Hyprland stack is built from source (Ubuntu's packages are ~6 months behind
# and Hyprland 0.56 needs newer hyprutils, hyprgraphics and wayland-protocols than
# Ubuntu ships). hyprutils bumps its ABI (soname 10 -> 13), so everything linking it
# is rebuilt too, rather than mixing it with Ubuntu's copies.
#
# Each ref is the newest release line that satisfies the minimum versions in
# Hyprland 0.56.2's CMakeLists (and those of the tools built on it); Hyprland's
# flake.lock pins the hypr* libraries to untagged commits. Patch releases within a
# pinned line are picked up automatically (hypr_resolve_ref); a new minor line
# needs a bump here and is reported by the weekly update (hypr_newer_report).
#
# Everything installs under /usr/local, which pkg-config and ld.so search before
# /usr, so it wins over the -dev libraries apt installs as build dependencies.
# Source trees and build directories: ~/.local/src/hyprland/<name>.
HYPR_SRC="$USER_HOME/.local/src/hyprland"
HYPR_PREFIX=/usr/local
# Hyprland 0.56 uses std::ranges::starts_with, which libstdc++ only has from GCC 16
# (Ubuntu's default g++ is 15 and fails with "'starts_with' is not a member of
# 'std::ranges'"). The CMake projects are built with g++-16; the C++ ABI is shared,
# so they link fine with anything built by 15.
HYPR_CC=gcc-16
HYPR_CXX=g++-16
# name url ref [meson extra args]. wayland is built scanner-only: Ubuntu's
# wayland-scanner 1.24 rejects wayland-protocols 1.49's XML ("failed validation
# against built-in DTD"), and the runtime libraries stay Ubuntu's.
HYPR_BUILDS=(
	"wayland            https://gitlab.freedesktop.org/wayland/wayland.git            1.26.0  meson -Dlibraries=false -Ddocumentation=false"
	"wayland-protocols  https://gitlab.freedesktop.org/wayland/wayland-protocols.git  1.49    meson"
	"hyprutils          https://github.com/hyprwm/hyprutils.git                       v0.14.2"
	"hyprlang           https://github.com/hyprwm/hyprlang.git                        v0.6.8"
	"hyprcursor         https://github.com/hyprwm/hyprcursor.git                      v0.1.13"
	"hyprgraphics       https://github.com/hyprwm/hyprgraphics.git                    v0.5.1"
	"hyprwire           https://github.com/hyprwm/hyprwire.git                        v0.3.1"
	"aquamarine         https://github.com/hyprwm/aquamarine.git                      v0.14.0"
	"hyprtoolkit        https://github.com/hyprwm/hyprtoolkit.git                     v0.6.0"
	"Hyprland           https://github.com/hyprwm/Hyprland.git                        v0.56.2"
	"hyprland-guiutils  https://github.com/hyprwm/hyprland-guiutils.git               v0.2.2"
	"xdg-desktop-portal-hyprland  https://github.com/hyprwm/xdg-desktop-portal-hyprland.git  v1.4.1"
	"hyprpolkitagent    https://github.com/hyprwm/hyprpolkitagent.git                 v0.2.0"
	"hyprpaper          https://github.com/hyprwm/hyprpaper.git                       v0.8.4"
	"hyprlock           https://github.com/hyprwm/hyprlock.git                        v0.9.6"
)
# Libraries each project links, from the stack. When any of these gets a new ref the
# project is rebuilt even if its own ref did not change: the hypr* libraries change
# ABI between releases (hyprutils 10 -> 13, hyprtoolkit 5 -> 6), so a program built
# against the old one breaks or misbehaves. Keep this in step with HYPR_BUILDS.
# Bump when the way the stack is built changes in a way that makes earlier builds
# wrong (r2: libraries had been linked against Ubuntu's old hyprutils); every
# project then rebuilds on the next run.
HYPR_BUILD_REV=2
declare -A HYPR_DEPS=(
	[hyprlang]="hyprutils"
	[hyprcursor]="hyprlang hyprutils"
	[hyprgraphics]="hyprutils"
	[hyprwire]="hyprutils"
	[aquamarine]="hyprutils"
	[hyprtoolkit]="hyprutils hyprlang hyprgraphics aquamarine"
	[Hyprland]="hyprutils hyprlang hyprcursor hyprgraphics aquamarine"
	[hyprland-guiutils]="hyprtoolkit hyprlang hyprutils"
	[xdg-desktop-portal-hyprland]="hyprlang hyprutils"
	[hyprpolkitagent]="hyprtoolkit hyprgraphics hyprlang hyprutils"
	[hyprpaper]="hyprtoolkit hyprwire hyprlang hyprutils"
	[hyprlock]="hyprlang hyprutils hyprgraphics"
)

# Ubuntu source packages whose build-dependencies the stack needs.
HYPR_BUILD_DEP_SOURCES=(
	wayland wayland-protocols hyprutils hyprlang libhyprcursor hyprgraphics hyprwire aquamarine
	hyprtoolkit hyprland hyprlock hyprpaper xdg-desktop-portal-hyprland hyprpolkitagent
)
# The apt versions of what is built here: same programs, removed once the build is in.
HYPR_APT_REMOVE=(hyprland hyprland-qtutils hyprlock hyprpaper hyprpolkitagent xdg-desktop-portal-hyprland)

# Parallel jobs: one per core, but at most one per 2 GB of RAM (Hyprland is C++26).
hypr_jobs() {
	local jobs mem
	jobs="$(nproc)"
	mem="$(awk '/MemTotal/ {print int($2 / 1048576)}' /proc/meminfo)"
	((mem / 2 < jobs)) && jobs=$((mem / 2))
	echo $((jobs > 0 ? jobs : 1))
}

# "v0.56.2" -> "v0.56", "1.49" -> "1.49": the release line a pin belongs to.
hypr_line() { sed -E 's/^(v?[0-9]+\.[0-9]+).*/\1/' <<<"$1"; }

# Release tags of a repo, newest last. Patch numbers of 90+ are release candidates
# (wayland tags 1.25.91 for the 1.26 rc) and are left out.
hypr_tags() {
	git ls-remote --tags --refs "$1" 2>/dev/null | sed 's#.*refs/tags/##' \
		| grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' | grep -v -E '\.9[0-9]$' | sort -V
}

# Newest tag in the pinned release line (the pin itself when offline).
hypr_resolve_ref() {
	local url="$1" pinned="$2" line best
	line="$(hypr_line "$pinned")"
	best="$( { echo "$pinned"; hypr_tags "$url" | grep -E "^${line//./\\.}(\.[0-9]+)?$"; } | sort -V | tail -1)"
	echo "${best:-$pinned}"
}

# One line per project whose upstream has a newer release line than its pin.
hypr_newer_report() {
	local entry name url pinned latest
	for entry in "${HYPR_BUILDS[@]}"; do
		read -r name url pinned _ <<<"$entry"
		latest="$(hypr_tags "$url" | tail -1)"
		[[ -n "$latest" && "$(hypr_line "$latest")" != "$(hypr_line "$pinned")" ]] || continue
		[[ "$(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -1)" == "$latest" ]] && echo "$name: pinned $pinned, newest $latest"
	done
}

# The ref a project was last installed at (first field of its stamp).
hypr_installed_ref() { { cut -d'|' -f1 < "$HYPR_SRC/$1/build/.installed-ref"; } 2>/dev/null; }

# What "up to date" means for $1 at $2: its own ref plus the installed refs of the
# libraries it links (HYPR_DEPS), e.g. "v0.2.2|hyprtoolkit=v0.6.0,hyprutils=v0.14.2,";
# "rN" is HYPR_BUILD_REV.
hypr_build_stamp() {
	local dep out="$2|r$HYPR_BUILD_REV|" deps="${HYPR_DEPS[$1]:-}"
	for dep in $deps; do
		out+="$dep=$(hypr_installed_ref "$dep"),"
	done
	echo "$out"
}

# Clone/update $name, build the newest tag in the pinned line ($3), install it under
# $HYPR_PREFIX. Builds run as the user; only the final copy is root. A fresh build
# tree each time, so a changed dependency is never mixed with stale configure results.
# Skipped when the ref recorded in the build tree is the one wanted.
#
# The install goes to a staging dir first and is copied over with --remove-destination,
# which unlinks each file and creates a new one. A running Hyprland session keeps the
# old files it already has open, so the stack can be updated while you are logged in;
# the new version starts at the next login.
build_hypr_project() {
	local name="$1" url="$2" pinned="$3" system="${4:-cmake}" src="$HYPR_SRC/$1" ref
	local extra=("${@:5}")
	ref="$(hypr_resolve_ref "$url" "$pinned")"
	local want
	want="$(hypr_build_stamp "$name" "$ref")"
	[[ "$(cat "$src/build/.installed-ref" 2>/dev/null)" == "$want" ]] && return 0
	echo "--> $name $ref"
	as_user mkdir -p "$HYPR_SRC"
	[[ -d "$src/.git" ]] || as_user git clone "$url" "$src"
	as_user git -C "$src" fetch --tags --quiet
	as_user git -C "$src" checkout --quiet "$ref"
	as_user git -C "$src" submodule update --init --recursive
	as_user rm -rf "$src/build"
	export LIBRARY_PATH="$HYPR_PREFIX/lib:$HYPR_PREFIX/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
	export PKG_CONFIG_PATH="$HYPR_PREFIX/lib/pkgconfig:$HYPR_PREFIX/lib/x86_64-linux-gnu/pkgconfig:$HYPR_PREFIX/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
	local stage
	stage="$(as_user mktemp -d)"
	if [[ "$system" == meson ]]; then
		as_user meson setup "$src/build" "$src" --prefix="$HYPR_PREFIX" --buildtype=release -Dtests=false "${extra[@]}"
		as_user ninja -C "$src/build" -j"$(hypr_jobs)"
		as_user env DESTDIR="$stage" meson install -C "$src/build" --no-rebuild
	else
		as_user cmake --no-warn-unused-cli -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$HYPR_CC" -DCMAKE_CXX_COMPILER="$HYPR_CXX" -DCMAKE_INSTALL_PREFIX="$HYPR_PREFIX" -DCMAKE_PREFIX_PATH="$HYPR_PREFIX" -S "$src" -B "$src/build"
		as_user cmake --build "$src/build" --config Release -j"$(hypr_jobs)"
		as_user env DESTDIR="$stage" cmake --install "$src/build"
	fi
	as_root cp -a --no-preserve=ownership --remove-destination "$stage$HYPR_PREFIX/." "$HYPR_PREFIX/"
	as_user rm -rf "$stage"
	as_root ldconfig
	as_user bash -c 'echo "$1" > "$2"' _ "$want" "$src/build/.installed-ref"
}

# Build dependencies: the -dev packages Ubuntu's own hypr* packages build with
# (needs deb-src enabled), plus the tools the builds themselves use.
install_hyprland_build_deps() {
	local src=/etc/apt/sources.list.d/ubuntu.sources pkg
	if [[ -f "$src" ]] && ! grep -q '^Types:.*deb-src' "$src"; then
		as_root sed -i 's/^Types: deb$/Types: deb deb-src/' "$src"
		as_root apt-get update
	fi
	# Tools, plus everything Hyprland 0.56's CMakeLists asks for: Ubuntu's build-deps
	# below are for its older 0.53 package and miss libeis, glslang and Lua 5.5.
	as_root apt-get install -y git cmake meson ninja-build pkg-config gcc-16 g++-16 hyprwayland-scanner hyprland-protocols \
		libeis-dev glslang-dev glslang-tools liblua5.5-dev libglaze-dev libre2-dev libmuparser-dev liblcms2-dev \
		libudis86-dev libsystemd-dev libgles-dev libegl-dev uuid-dev libxcursor-dev libpango1.0-dev libcairo2-dev \
		libgbm-dev libdrm-dev libinput-dev libxkbcommon-dev libpixman-1-dev libwayland-dev libglib2.0-dev \
		libxcb-errors-dev libxcb-icccm4-dev libxcb-composite0-dev libxcb-res0-dev libxcb-render0-dev libxcb-xfixes0-dev \
		libtomlplusplus-dev xwayland
	for pkg in "${HYPR_BUILD_DEP_SOURCES[@]}"; do
		as_root apt-get build-dep -y "$pkg" || echo "warning: build-dep $pkg failed" >&2
	done
	hypr_remove_apt_libs
}

# build-dep pulls in Ubuntu's own libhypr*-dev, libaquamarine-dev and runtime
# packages (older versions of the very libraries built here). Their
# /usr/lib/x86_64-linux-gnu/libhypr*.so symlinks win over /usr/local at link time,
# so a program ends up loading both hyprutils 10 and 13 and crashes. Remove them
# before every build (build-dep brings them back each run).
hypr_remove_apt_libs() {
	local pkgs
	pkgs="$(dpkg-query -W -f '${Package}\n' 'libhypr*' 'libaquamarine*' hyprwire-scanner 2>/dev/null | tr '\n' ' ')"
	[[ -z "${pkgs// /}" ]] || as_root apt-get remove -y $pkgs
	as_root ldconfig
}

# A library that moves to a new version leaves the old files behind (libhyprtoolkit
# 0.5.4 / .so.5 after the bump to 0.6.0), linked against libraries that are gone.
# Keep, per library, only the files its libX.so link points at.
# $1 = "dry" lists what would go.
hypr_prune_stale_libs() {
	local dev base soname real f
	for dev in "$HYPR_PREFIX"/lib/lib{hypr,aquamarine}*.so; do
		[[ -L "$dev" ]] || continue
		base="$(basename "$dev")"
		soname="$(readlink "$dev")"
		real="$(readlink "$HYPR_PREFIX/lib/$soname")"
		for f in "$HYPR_PREFIX/lib/$base".*; do
			[[ -e "$f" || -L "$f" ]] || continue
			case "$(basename "$f")" in
				"$soname" | "$real") ;;
				*) if [[ "${1:-}" == dry ]]; then echo "would remove $f"; else as_root rm -f "$f"; fi ;;
			esac
		done
	done
	[[ "${1:-}" == dry ]] || as_root ldconfig
}

# Fails (and names the offenders) if anything installed under $HYPR_PREFIX still
# loads a hypr* library from /usr/lib (Ubuntu's copy) instead of /usr/local.
hypr_check_abi() {
	local f bad=0 out
	for f in "$HYPR_PREFIX"/bin/* "$HYPR_PREFIX"/libexec/* "$HYPR_PREFIX"/lib/lib{hypr,aquamarine}*.so.*.*; do
		[[ -f "$f" ]] || continue
		out="$(ldd "$f" 2>/dev/null | grep -E '/usr/lib/.*/lib(hypr|aquamarine)|libhyprutils\.so\.10|libaquamarine\.so\.9' || true)"
		[[ -z "$out" ]] || { echo "$f loads Ubuntu's hypr libraries:"; echo "$out"; bad=1; }
	done
	return "$bad"
}

# Build the whole stack in order. Only once every build succeeded are the apt
# hypr* packages removed (a failed build leaves the working apt Hyprland alone),
# and the login session is linked where GDM looks for it.
install_hyprland() {
	install_hyprland_build_deps
	local pkg entry
	for entry in "${HYPR_BUILDS[@]}"; do
		# shellcheck disable=SC2086
		build_hypr_project $entry
	done
	hypr_prune_stale_libs
	# hyprlock authenticates through PAM service "hyprlock", and PAM reads only
	# /etc/pam.d. The build installs the file under /usr/local/etc, so without this
	# copy Super+L locks the screen and nothing can unlock it.
	if [[ -f "$HYPR_PREFIX/etc/pam.d/hyprlock" ]]; then
		as_root install -D -m 644 "$HYPR_PREFIX/etc/pam.d/hyprlock" /etc/pam.d/hyprlock
	fi
	hypr_check_abi || { echo "!! the stack links Ubuntu's hypr libraries (see above)" >&2; return 1; }
	for pkg in "${HYPR_APT_REMOVE[@]}"; do
		dpkg -s "$pkg" >/dev/null 2>&1 && as_root apt-get remove -y "$pkg"
	done
	if [[ -f "$HYPR_PREFIX/share/wayland-sessions/hyprland.desktop" ]]; then
		as_root install -d /usr/share/wayland-sessions
		as_root ln -sfn "$HYPR_PREFIX/share/wayland-sessions/hyprland.desktop" /usr/share/wayland-sessions/hyprland.desktop
	fi
}

# Local ntfy: a notification server on 127.0.0.1:2586, a user service that
# subscribes to it, and notify-send to turn each message into a desktop toast
# (shown by mako under Hyprland). Anything on this machine can publish with
#   curl -d "message" http://127.0.0.1:2586/$NTFY_TOPIC
NTFY_TOPIC=workstation
NTFY_URL=http://127.0.0.1:2586

# ntfy comes from Ubuntu's esm-apps repo, so the machine must be attached to
# Ubuntu Pro first (see MANUAL.md).
install_ntfy() {
	sudo apt-get install -y ntfy
	sudo install -D -m 644 "$SCRIPT_DIR/ntfy/server.yml" /etc/ntfy/server.yml
	sudo install -D -m 644 "$SCRIPT_DIR/ntfy/override.conf" /etc/systemd/system/ntfy.service.d/override.conf
	sudo systemctl daemon-reload
	sudo systemctl reset-failed ntfy.service 2>/dev/null || true
	sudo systemctl enable ntfy.service
	sudo systemctl restart ntfy.service
}

# Client: config rendered with the topic, user unit linked from the repo.
setup_ntfy_client() {
	local conf="${XDG_CONFIG_HOME:-$HOME/.config}/ntfy" units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
	mkdir -p "$conf" "$units"
	cat > "$conf/client.yml" <<-CONF
		default-host: $NTFY_URL
		subscribe:
		  - topic: $NTFY_TOPIC
		    command: 'notify-send --app-name=ntfy -t 0 "\${NTFY_TITLE:-ntfy}" "\$NTFY_MESSAGE"'
	CONF
	ln -sfn "$SCRIPT_DIR/ntfy/ntfy-client.service" "$units/ntfy-client.service"
	systemctl --user daemon-reload
	systemctl --user enable ntfy-client.service
	systemctl --user restart ntfy-client.service
}

# Last step of a full install: publish a message so you can see the toast arrive.
# It also fails the step if the server does not answer.
ntfy_test() {
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		curl -fsS "$NTFY_URL/v1/health" >/dev/null 2>&1 && break
		sleep 1
	done
	curl -fsS -H "Title: Workstation install finished" -d "ntfy works: this toast came from the local server at $NTFY_URL/$NTFY_TOPIC" "$NTFY_URL/$NTFY_TOPIC" >/dev/null
	echo "sent a test message to $NTFY_URL/$NTFY_TOPIC; look for the toast (makoctl history shows it if it already faded)"
}

# Claude Code skills, in ~/.claude/skills (per user, all projects).
# herdr: the official skill, printed by the installed binary so it always matches
# that version (re-run by the weekly update). It only activates inside a herdr pane.
install_herdr_skill() {
	local herdr dir="$HOME/.claude/skills/herdr"
	herdr="$(command -v herdr || echo "$HOME/.local/bin/herdr")"
	mkdir -p "$dir"
	"$herdr" --skill > "$dir/SKILL.md.new"
	[[ -s "$dir/SKILL.md.new" ]] || { rm -f "$dir/SKILL.md.new"; echo "herdr --skill printed nothing" >&2; return 1; }
	mv "$dir/SKILL.md.new" "$dir/SKILL.md"
}

# hyprland-control (third party, unlicensed, so pinned to a reviewed commit rather
# than followed): reads Hyprland state through hyprctl and, after asking each time,
# moves windows, switches workspaces and launches programs (e.g. a terminal on a
# given workspace). Bump the rev only after reading the new SKILL.md.
HYPRLAND_SKILL_REV=8b4875e328e0fbd73ed01ec82b0c5fe56114d7e2
install_hyprland_skill() {
	local dir="$HOME/.claude/skills/hyprland-control"
	mkdir -p "$dir"
	curl -fsSL "https://raw.githubusercontent.com/xingguangcuican6666/hyprland-control/$HYPRLAND_SKILL_REV/skills/hyprland-control/SKILL.md" -o "$dir/SKILL.md"
}

# Language toolchains, kept at the latest stable release. Each install_* is also its
# own update (the weekly update.sh re-runs them), and each lives in the user's home.
# Binaries are linked into ~/.local/bin so GUI apps started from Hyprland find them
# too (a ~/.bashrc PATH would not reach them).

# Node: fnm, newest LTS. NODE_CHANNEL=latest follows the Current release instead.
NODE_CHANNEL=lts
install_node() {
	local fnm="$HOME/.local/share/fnm/fnm" bin="$HOME/.local/share/fnm/aliases/default/bin" tool
	curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
	if [[ "$NODE_CHANNEL" == latest ]]; then
		"$fnm" install --latest && "$fnm" default latest
	else
		"$fnm" install --lts && "$fnm" default lts-latest
	fi
	mkdir -p "$HOME/.local/bin"
	ln -sfn "$fnm" "$HOME/.local/bin/fnm"
	for tool in node npm npx; do
		ln -sfn "$bin/$tool" "$HOME/.local/bin/$tool"
	done
}

# Python: uv manages the newest stable CPython beside the system python3 (which
# apt keeps for the OS); pipx apps are upgraded too.
install_python() {
	[[ -x "$HOME/.local/bin/uv" ]] || curl -LsSf https://astral.sh/uv/install.sh | sh
	"$HOME/.local/bin/uv" self update
	"$HOME/.local/bin/uv" python install
	"$HOME/.local/bin/uv" python upgrade
	pipx upgrade-all || true
}

# .NET: Microsoft's dotnet-install into ~/.dotnet, on the newest channel that is
# generally available (11.0 is still a release candidate, so 10.0 until it ships).
install_dotnet() {
	local tmp channel
	tmp="$(mktemp -d)"
	channel="$(curl -fsSL https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json \
		| jq -r '[."releases-index"[] | select(."support-phase" == "active")][0]."channel-version"')"
	[[ -n "$channel" && "$channel" != null ]] || { echo "could not determine the latest .NET channel" >&2; return 1; }
	curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$tmp/dotnet-install.sh"
	bash "$tmp/dotnet-install.sh" --channel "$channel" --install-dir "$HOME/.dotnet"
	rm -rf "$tmp"
	mkdir -p "$HOME/.local/bin"
	ln -sfn "$HOME/.dotnet/dotnet" "$HOME/.local/bin/dotnet"
}

# Weekly update steps (run by update.sh, as root unless noted).
update_apt() {
	as_root apt-get update
	as_root apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
	as_root apt-get -y autoremove
}
update_snap() {
	have snap && as_root snap refresh || true
}
# As the user: bring in pin and step changes pushed from another machine.
update_repo() {
	git -C "$SCRIPT_DIR" pull --ff-only
}

# Weekly update timer: update.sh on Fridays at 6pm while the machine is on (a
# missed Friday is skipped, not caught up).
setup_updates() {
	sed -e "s#@USER@#$WORKSTATION_USER#" -e "s#@SCRIPT_DIR@#$SCRIPT_DIR#" \
		"$SCRIPT_DIR/update/workstation-update.service" | sudo tee /etc/systemd/system/workstation-update.service >/dev/null
	sudo install -m 644 "$SCRIPT_DIR/update/workstation-update.timer" /etc/systemd/system/workstation-update.timer
	sed -e "s#@NTFY_URL@#$NTFY_URL#" -e "s#@NTFY_TOPIC@#$NTFY_TOPIC#" \
		"$SCRIPT_DIR/update/workstation-update-failed.service" | sudo tee /etc/systemd/system/workstation-update-failed.service >/dev/null
	sudo systemctl daemon-reload
	sudo systemctl enable --now workstation-update.timer
}

# Hyprland: repo config. Waybar uses its packaged default (/etc/xdg/waybar)
# until ~/.config/waybar exists. Hyprland shows up as a login-screen session
# alongside GNOME.
setup_hyprland() {
	local dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
	mkdir -p "$dir"
	[[ -f "$dir/hyprland.conf" && ! -L "$dir/hyprland.conf" ]] && mv "$dir/hyprland.conf" "$dir/hyprland.conf.bak"
	ln -sfn "$SCRIPT_DIR/hypr/hyprland.conf" "$dir/hyprland.conf"
	# hyprland.conf starts these itself; the packaged user units would also start
	# them in the GNOME session, where waybar fails (no layer-shell) and retries.
	systemctl --user disable waybar.service hyprpaper.service 2>/dev/null || true
}

# Make Hyprland the session GDM preselects for this user. This is the same
# per-user setting the login screen's gear menu writes, so GNOME stays one click
# away there. Takes effect at the next login.
set_default_session() {
	local uid path
	uid="$(id -u)"
	path="/org/freedesktop/Accounts/User$uid"
	sudo busctl call org.freedesktop.Accounts "$path" org.freedesktop.Accounts.User SetSession s hyprland
	sudo busctl call org.freedesktop.Accounts "$path" org.freedesktop.Accounts.User SetXSession s hyprland
}

# Desktop background from ubuntu/wallpapers/$WALLPAPER, for GNOME (light and dark)
# and Hyprland (hyprpaper). Skipped until the image is added.
WALLPAPER=desktop.jpg
setup_wallpaper() {
	local img="$SCRIPT_DIR/wallpapers/$WALLPAPER"
	if [[ ! -f "$img" ]]; then
		echo "note: $img not found; skipping wallpaper" >&2
		return 0
	fi

	gsettings set org.gnome.desktop.background picture-uri "file://$img"
	gsettings set org.gnome.desktop.background picture-uri-dark "file://$img"
	gsettings set org.gnome.desktop.background picture-options zoom

	mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
	cat > "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprpaper.conf" <<-CONF
		wallpaper {
		    monitor =
		    path = $img
		    fit_mode = cover
		}
	CONF
}

# Desktop theme: wallust config, templates and color schemes from theme/, the
# Waybar config, and the `theme` command (theme everforest | theme nightfox).
# Everything is linked from the repo; wallust writes the colors into
# ~/.config on each `theme` run. Starts on everforest if none was chosen yet.
setup_theme() {
	local cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
	mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/wallust" "$cfg/wallust" "$cfg/waybar" "$cfg/kitty" "$cfg/hypr" "$cfg/fuzzel" "$cfg/mako" "$cfg/zed/themes" "$HOME/.local/bin"
	ln -sfn "$SCRIPT_DIR/theme/wallust.toml" "$cfg/wallust/wallust.toml"
	ln -sfn "$SCRIPT_DIR/theme/templates" "$cfg/wallust/templates"
	ln -sfn "$SCRIPT_DIR/theme/colorschemes" "$cfg/wallust/colorschemes"
	ln -sfn "$SCRIPT_DIR/theme/theme" "$HOME/.local/bin/theme"
	ln -sfn "$SCRIPT_DIR/waybar/config.jsonc" "$cfg/waybar/config.jsonc"
	ln -sfn "$SCRIPT_DIR/waybar/style.css" "$cfg/waybar/style.css"

	gsettings set org.gnome.desktop.interface color-scheme prefer-dark ||
		echo "warning: could not set GNOME dark mode (no desktop session?)" >&2

	[[ -f "$HOME/.local/state/theme" ]] || "$HOME/.local/bin/theme" everforest
}
