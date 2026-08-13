#!/usr/bin/env bash
#
# install.sh — wire this folder's Herdr worktree workflow into the local machine.
# Run from WSL. Safe to re-run (idempotent).
#
# What it does (never overwrites an existing ~/.config/herdr/config.toml):
#   1. Installs CLI prerequisites: herdr, gum, git, micro, jq, claude, agent
#   2. Creates default config.toml if missing (herdr --default-config)
#   3. Installs herdr plugins (herdr-plus, herdr-agent-usage, herdr-reviewr)
#   4. Applies managed herdr-reviewr plugin config (not root Herdr config)
#   5. Symlinks worktree-make.sh -> ~/bin/make-worktree.sh,
#      worktree-launch.sh -> ~/bin/worktree-launch.sh,
#      worktree-remove.sh -> ~/bin/worktree-remove.sh,
#      review-make.sh -> ~/bin/review-make.sh,
#      review-remove.sh -> ~/bin/review-remove.sh,
#      story-reap.sh -> ~/bin/story-reap.sh, and
#      az-watcher/az-watcher.sh -> ~/bin/az-watcher
#   6. Installs quick-action TOMLs (dev + delete + new-review + remove-review +
#      reap + az-sync) into herdr-plus, and deletes retired ones
#   7. Installs the wildcard worktree auto-layout (repo = "*")
#
# The symlinks mean the working copy IS what runs: edit a script here and the
# next quick action picks the change up with no re-install.
#
# Manual config.toml edits are listed at the end and in README.md.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/bin"
LOCAL_BIN="${HOME}/.local/bin"
TARGET_SCRIPT="${BIN_DIR}/make-worktree.sh"
TARGET_LAUNCH="${BIN_DIR}/worktree-launch.sh"
TARGET_REMOVE="${BIN_DIR}/worktree-remove.sh"
TARGET_REVIEW_MAKE="${BIN_DIR}/review-make.sh"
TARGET_REVIEW_REMOVE="${BIN_DIR}/review-remove.sh"
TARGET_STORY_REAP="${BIN_DIR}/story-reap.sh"
TARGET_AZ_WATCHER="${BIN_DIR}/az-watcher"

have() { command -v "$1" >/dev/null 2>&1; }

ensure_path_dirs() {
  mkdir -p "$BIN_DIR" "$LOCAL_BIN"
  export PATH="${BIN_DIR}:${LOCAL_BIN}:${PATH}"

  local line='export PATH="$HOME/bin:$HOME/.local/bin:$PATH"'
  local rc="${HOME}/.bashrc"
  if [[ -f "$rc" ]] && ! grep -qF '$HOME/bin:$HOME/.local/bin' "$rc" 2>/dev/null; then
    {
      echo ""
      echo "# herdr workflow (added by wsl/herdr/install.sh)"
      echo "$line"
    } >> "$rc"
    echo "-> PATH: appended ~/bin and ~/.local/bin to ${rc}"
  fi
}

# Compare dotted versions: true if $1 >= $2 (numeric segments only).
version_ge() {
  local a="$1" b="$2"
  local IFS=.
  # shellcheck disable=SC2206
  local -a aa=($a) bb=($b)
  local i n="${#aa[@]}"
  (( ${#bb[@]} > n )) && n="${#bb[@]}"
  for ((i = 0; i < n; i++)); do
    local x="${aa[i]:-0}" y="${bb[i]:-0}"
    x="${x%%[^0-9]*}" y="${y%%[^0-9]*}"
    ((10#${x:-0} > 10#${y:-0})) && return 0
    ((10#${x:-0} < 10#${y:-0})) && return 1
  done
  return 0
}

ensure_apt_pkgs() {
  local pkgs=() p
  for p in "$@"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
      pkgs+=("$p")
    fi
  done
  if ((${#pkgs[@]} == 0)); then
    echo "-> apt: already present ($*)"
    return
  fi
  echo "-> apt: installing ${pkgs[*]}"
  sudo apt-get update -y
  sudo apt-get install -y "${pkgs[@]}"
}

ensure_herdr() {
  local ver=""
  if have herdr; then
    ver="$(herdr --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
    if [[ -n "$ver" ]] && version_ge "$ver" "0.7.5"; then
      echo "-> herdr: ${ver} (>= 0.7.5)"
      return
    fi
    echo "-> herdr: found ${ver:-unknown}, need >= 0.7.5 — upgrading"
  else
    echo "-> herdr: not found — installing"
  fi
  curl -fsSL https://herdr.dev/install.sh | sh
  hash -r 2>/dev/null || true
  export PATH="${BIN_DIR}:${LOCAL_BIN}:${PATH}"
  have herdr || { echo "herdr install finished but 'herdr' is not on PATH" >&2; exit 1; }
  ver="$(herdr --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
  echo "-> herdr: ${ver:-installed}"
}

# Official default: https://herdr.dev/docs/configuration/
#   herdr --default-config > ~/.config/herdr/config.toml
# Only create when missing — never overwrite an existing file.
ensure_herdr_config() {
  local cfg="${HERDR_CONFIG_PATH:-${HOME}/.config/herdr/config.toml}"
  if [[ -f "$cfg" ]]; then
    echo "-> config: exists (left unchanged): ${cfg}"
    return
  fi
  mkdir -p "$(dirname "$cfg")"
  herdr --default-config > "$cfg"
  echo "-> config: created default at ${cfg}"
}

ensure_gum() {
  if have gum; then
    echo "-> gum: $(command -v gum)"
    return
  fi
  echo "-> gum: installing from GitHub Releases into ${BIN_DIR}"
  local arch uname_m tag ver asset url tmp gum_bin
  uname_m="$(uname -m)"
  case "$uname_m" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "unsupported arch for gum: $uname_m" >&2; exit 1 ;;
  esac
  tag="$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest \
    | grep -oE '"tag_name":[[:space:]]*"v[^"]+"' | head -1 | grep -oE 'v[0-9.]+')"
  ver="${tag#v}"
  [[ -n "$ver" ]] || { echo "could not resolve latest gum version" >&2; exit 1; }
  asset="gum_${ver}_Linux_${arch}.tar.gz"
  url="https://github.com/charmbracelet/gum/releases/download/${tag}/${asset}"
  tmp="$(mktemp -d)"
  curl -fsSL "$url" | tar -xzf - -C "$tmp"
  gum_bin="$(find "$tmp" -type f -name gum | head -1)"
  [[ -n "$gum_bin" ]] || { echo "gum binary missing from ${asset}" >&2; exit 1; }
  install -m 755 "$gum_bin" "${BIN_DIR}/gum"
  rm -rf "$tmp"
  echo "-> gum: ${BIN_DIR}/gum"
}

ensure_claude() {
  if have claude; then
    echo "-> claude: $(command -v claude)"
    return
  fi
  echo "-> claude: installing (Claude Code CLI)"
  curl -fsSL https://claude.ai/install.sh | bash
  hash -r 2>/dev/null || true
  export PATH="${BIN_DIR}:${LOCAL_BIN}:${PATH}"
  have claude || {
    echo "claude install finished but 'claude' is not on PATH (open a new shell or check ~/.local/bin)" >&2
    exit 1
  }
  echo "-> claude: $(command -v claude)"
}

ensure_agent() {
  if have agent; then
    echo "-> agent: $(command -v agent)"
    return
  fi
  echo "-> agent: installing (Cursor Agent CLI)"
  curl -fsS https://cursor.com/install | bash
  hash -r 2>/dev/null || true
  export PATH="${BIN_DIR}:${LOCAL_BIN}:${PATH}"
  have agent || {
    echo "agent install finished but 'agent' is not on PATH (open a new shell or check ~/.local/bin)" >&2
    exit 1
  }
  echo "-> agent: $(command -v agent)"
}

# --- plugins (idempotent; does not touch root Herdr config.toml) -----------
install_plugin() {
  local spec="$1"
  echo "-> plugin: herdr plugin install ${spec}"
  # Non-interactive installs need --yes. It must come *after* the repo:
  # `herdr plugin install --yes owner/repo` and `-y owner/repo` both print
  # usage and do nothing (herdr 0.7.5). `owner/repo --yes` works.
  herdr plugin install "$spec" --yes
}

install_file() {
  local src="$1" dest="$2"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    echo "-> unchanged: ${dest}"
    return
  fi
  cp "$src" "$dest"
  # Windows checkouts can leave CRLF; strip so shebangs work in WSL.
  if [[ "$dest" == *.sh ]]; then
    sed -i 's/\r$//' "$dest"
  fi
  echo "-> installed: ${dest}"
}

ensure_reviewr_config() {
  local plugin_dir cfg tmp
  plugin_dir="$(herdr plugin config-dir persiyanov.reviewr)"
  if [[ -z "$plugin_dir" ]]; then
    echo "reviewr config dir missing (plugin install may have failed)" >&2
    exit 1
  fi
  mkdir -p "$plugin_dir"
  cfg="${plugin_dir}/config.toml"
  tmp="$(mktemp)"

  {
    echo "# BEGIN vscodesettings herdr-reviewr defaults"
    echo "auto_open = false"
    echo "toggle_placement = \"overlay\""
    echo "toggle_direction = \"right\""
    echo "default_scope = \"branch\""
    echo "# END vscodesettings herdr-reviewr defaults"
    echo
    if [[ -f "$cfg" ]]; then
      awk '
        /^# BEGIN vscodesettings herdr-reviewr defaults$/ { skip = 1; next }
        /^# END vscodesettings herdr-reviewr defaults$/ { skip = 0; next }
        skip { next }
        /^[[:space:]]*\[/ { in_table = 1 }
        !in_table && /^[[:space:]]*(auto_open|toggle_placement|toggle_direction|default_scope)[[:space:]]*=/ { next }
        { print }
      ' "$cfg"
    fi
  } > "$tmp"

  if [[ -f "$cfg" ]] && cmp -s "$tmp" "$cfg"; then
    rm -f "$tmp"
    echo "-> reviewr config: unchanged (${cfg})"
    return
  fi

  mv "$tmp" "$cfg"
  echo "-> reviewr config: installed managed defaults (${cfg})"
}

# Ensure a script path is executable and Unix-LF (safe for files we symlink to).
normalize_shell_script() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  sed -i 's/\r$//' "$f"
  chmod +x "$f"
}

# herdr-plus seeds examples with macOS `open`. On Linux/WSL those flash-fail.
# Rewrite to the cross-platform {{opener}} template helper.
fix_example_openers() {
  local dir="$1" f
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.toml; do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in
      new-worktree-*.toml|remove-worktree.toml|az-watcher.toml) continue ;;
      new-review.toml|remove-review.toml|reap-stories.toml) continue ;;
    esac
    if grep -qE 'command = "open ' "$f"; then
      sed -i 's/command = "open /command = "{{opener}} /g' "$f"
      echo "-> opener fix: ${f}"
    fi
  done
}

# ===========================================================================
echo "=== 1/3 Prerequisites ==="
ensure_path_dirs
ensure_apt_pkgs curl git micro jq
ensure_herdr
ensure_herdr_config
ensure_gum
ensure_claude
ensure_agent

echo
echo "=== 2/3 Herdr plugins ==="
install_plugin "cloudmanic/herdr-plus"
install_plugin "senna-lang/herdr-agent-usage"
install_plugin "persiyanov/herdr-reviewr"
ensure_reviewr_config

PLUGIN_DIR="$(herdr plugin config-dir cloudmanic.herdr-plus)"
if [[ -z "$PLUGIN_DIR" || ! -d "$PLUGIN_DIR" ]]; then
  echo "herdr-plus config dir missing (plugin install may have failed): '${PLUGIN_DIR}'" >&2
  exit 1
fi
QA_DIR="${PLUGIN_DIR}/quick-actions"
LAYOUT_DIR="${PLUGIN_DIR}/worktrees"

echo "herdr-plus config: ${PLUGIN_DIR}"
mkdir -p "$QA_DIR" "$LAYOUT_DIR"

echo
echo "=== 3/3 Worktree workflow files ==="
normalize_shell_script "${SCRIPT_DIR}/worktree-make.sh"
normalize_shell_script "${SCRIPT_DIR}/worktree-launch.sh"
normalize_shell_script "${SCRIPT_DIR}/worktree-remove.sh"
normalize_shell_script "${SCRIPT_DIR}/review-make.sh"
normalize_shell_script "${SCRIPT_DIR}/review-remove.sh"
normalize_shell_script "${SCRIPT_DIR}/story-reap.sh"
normalize_shell_script "${SCRIPT_DIR}/az-watcher/az-watcher.sh"
ln -sfn "${SCRIPT_DIR}/worktree-make.sh" "$TARGET_SCRIPT"
echo "-> script:  ${TARGET_SCRIPT} -> ${SCRIPT_DIR}/worktree-make.sh"

ln -sfn "${SCRIPT_DIR}/worktree-launch.sh" "$TARGET_LAUNCH"
echo "-> launch:  ${TARGET_LAUNCH} -> ${SCRIPT_DIR}/worktree-launch.sh"

ln -sfn "${SCRIPT_DIR}/worktree-remove.sh" "$TARGET_REMOVE"
echo "-> remove:  ${TARGET_REMOVE} -> ${SCRIPT_DIR}/worktree-remove.sh"

ln -sfn "${SCRIPT_DIR}/review-make.sh" "$TARGET_REVIEW_MAKE"
echo "-> review:  ${TARGET_REVIEW_MAKE} -> ${SCRIPT_DIR}/review-make.sh"

ln -sfn "${SCRIPT_DIR}/review-remove.sh" "$TARGET_REVIEW_REMOVE"
echo "-> cleanup: ${TARGET_REVIEW_REMOVE} -> ${SCRIPT_DIR}/review-remove.sh"

ln -sfn "${SCRIPT_DIR}/story-reap.sh" "$TARGET_STORY_REAP"
echo "-> reap:    ${TARGET_STORY_REAP} -> ${SCRIPT_DIR}/story-reap.sh"

ln -sfn "${SCRIPT_DIR}/az-watcher/az-watcher.sh" "$TARGET_AZ_WATCHER"
echo "-> az:      ${TARGET_AZ_WATCHER} -> ${SCRIPT_DIR}/az-watcher/az-watcher.sh"

install_file "${SCRIPT_DIR}/new-worktree-dev.toml"         "${QA_DIR}/new-worktree-dev.toml"
install_file "${SCRIPT_DIR}/remove-worktree.toml"          "${QA_DIR}/remove-worktree.toml"
install_file "${SCRIPT_DIR}/new-review.toml"               "${QA_DIR}/new-review.toml"
install_file "${SCRIPT_DIR}/remove-review.toml"            "${QA_DIR}/remove-review.toml"
install_file "${SCRIPT_DIR}/reap-stories.toml"             "${QA_DIR}/reap-stories.toml"
install_file "${SCRIPT_DIR}/az-watcher.toml"              "${QA_DIR}/az-watcher.toml"

# Retired quick actions. herdr-plus lists whatever TOMLs are in quick-actions/,
# so a copy left by an earlier install keeps showing in prefix+down forever.
#
# new-worktree-review.toml is gone because creating review worktrees by hand
# meant typing a story id, a slug and a <repo>:<branch> list — all of which
# az-watcher already derives from your Azure assignments. Use 'Sync Azure
# Reviews' instead. (make-worktree.sh review itself is still there; az-watcher
# is now its only caller.)
for retired in new-worktree-dev-windows.toml new-worktree-review.toml; do
  if [[ -e "${QA_DIR}/${retired}" ]]; then
    rm -f "${QA_DIR}/${retired}"
    echo "-> removed:   ${QA_DIR}/${retired} (retired quick action)"
  fi
done
install_file "${SCRIPT_DIR}/worktree-layout.toml"          "${LAYOUT_DIR}/worktree-layout.toml"

# Seeded herdr-plus examples use macOS `open`; rewrite to {{opener}} on Linux/WSL.
fix_example_openers "$QA_DIR"

echo
echo "=== Automated install finished ==="
echo "  (Existing root Herdr config.toml is never overwritten; defaults are written only if missing.)"
echo
echo "Manual next steps — see README.md for full snippets:"
echo "  1. Edit machine paths at the top of:"
echo "       ${SCRIPT_DIR}/worktree-make.sh"
echo "     (SRC_ROOT, BRANCH_PREFIX)"
echo "       ${SCRIPT_DIR}/review-make.sh"
echo "     (SRC_ROOT, REVIEW_MODEL, REVIEW_PERMISSION_MODE)"
echo "  2. Merge README Herdr settings into config.toml by hand, including:"
echo "       [worktrees] directory = \"~/source/worktrees\""
echo "       [ui.sidebar.spaces] rows = [[\"\$tree\", \"state_icon\", \"workspace\"]]"
echo "         (\$tree must precede state_icon - it is the connector drawn under a"
echo "          story row for each of its repos, and under Review for each review;"
echo "          without it the bullets stay left)"
echo "       [theme.custom] accent = \"#ffffff\"   AND   [ui] accent = \"#ffffff\""
echo "         (herdr paints the SELECTED sidebar row, state icon included, in the"
echo "          accent colour; the default pink turns a selected row icon magenta."
echo "          Set BOTH: [theme.custom] accent overrides the theme token, [ui]"
echo "          accent is the chrome colour the selected row actually uses."
echo "          accent is NOT valid under [ui.sidebar.spaces] - herdr documents it"
echo "          just below that table, so it strands easily - see README)"
echo "       ${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"
echo "  3. Seed Agent Usage (prints snippets; does not rewrite herdr config.toml):"
echo "       herdr plugin action invoke usagebar.setup"
echo "     Paste any sidebar/toast/key snippets it prints if not already in config."
echo "  4. Optional toast delivery — prefer pasting the README [ui.toast] block"
echo "     instead of usagebar.enable-toast (that command can append to config.toml)."
echo "  5. herdr config check   # fix any unknown keys before continuing"
echo "  6. herdr server reload-config"
echo "     (named sessions: herdr --session <name> server reload-config;"
echo "      bare 'herdr server reload-config' only hits the default session)"
echo "  7. Dry-run: prefix+down -> New Dev Worktree"
echo "     Code review: prefix+down -> New Code Review (asks for a work item id;"
echo "     needs az login, reads Azure DevOps and never writes to it)"
echo "     Cleanup:     prefix+down -> Clean Up Finished Reviews (blank id = all)."
echo "     To run it on a schedule, dry-run it first, then:"
echo "       review-remove.sh --yes    # from ${TARGET_REVIEW_REMOVE}"
echo "     Closed stories: prefix+down -> Clean Up Closed Stories. Removes a"
echo "     development story only when it has >= 1 PR and all of them closed;"
echo "     a story with no PRs is never touched. Dry-run it first:"
echo "       story-reap.sh --dry-run   # from ${TARGET_STORY_REAP}"
echo "     then, once trusted, a 10-minute cron entry running:"
echo "       story-reap.sh --yes"
echo "  8. Azure sync (az-watcher) — NOT auto-installed, do this by hand:"
echo "       install the Azure CLI, then:"
echo "         az login"
echo "         az devops configure -d organization=https://dev.azure.com/<org> project='<project>'"
echo "       verify:  az-watcher run --dry-run --window 0"
echo "       details: ${SCRIPT_DIR}/az-watcher/README.md"
echo
echo "If 'claude' or 'agent' is missing in a new terminal, source ~/.bashrc or reopen WSL."
echo "Primary clones must exist under SRC_ROOT/<repo-name>."
echo
herdr plugin list
echo
echo "CLI check:"
# python3 is not optional for review-make.sh: it flattens the HTML Azure DevOps
# stores descriptions in, and speaks to the herdr socket for sidebar ordering.
for c in herdr gum git micro jq python3 claude agent az flock; do
  printf "  %-8s %s\n" "$c" "$(command -v "$c" 2>/dev/null || echo MISSING)"
done
