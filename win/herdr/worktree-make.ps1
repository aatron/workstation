# make-worktree.ps1
# Create a multi-repo herdr worktree structure for an Azure DevOps story.
# Two types: development and review.
#
# THE WORKSPACE IS THE STORY, NOT THE REPO:
#   herdr's sidebar groups workspaces by their source repository
#   (worktree.repo_key) and nests linked worktrees under their primary clone.
#   That grouping is built in - there is no config for it - so a workspace made
#   with `herdr worktree create` ALWAYS lands under its clone, and a story
#   spanning four repos became four unrelated rows in four different groups:
#       repo1 -> {id}-{slug}
#       repo2 -> {id}-{slug}
#   `herdr worktree create --workspace <ID>` is not a way out: --workspace and
#   --cwd are mutually exclusive, and --workspace only says which workspace to
#   take the SOURCE REPO from - it still creates a workspace of its own.
#   So this script adds the worktrees with plain `git worktree add` and builds
#   the rows itself. A workspace with no worktree metadata is not grouped at all,
#   so the sidebar reads story-first, one row per repo drawn beneath it:
#       {id}-{slug}            cwd = the story folder
#         |- repo1             cwd = {id}-{slug}/repo1
#         `- repo2             cwd = {id}-{slug}/repo2
#   The connectors need one line in config.toml - see Initialize-StoryWorkspace,
#   which prints it when it is missing.
#
#   The story row carries four tabs at the story root, where one agent sees every
#   repo in the story at once:
#       notes   micro on the notes file of the first repo requested
#       claude  $CLAUDE_CMD
#       cursor  $CURSOR_CMD
#       pwsh    bare shell
#   Each repo row carries three tabs at that repo's worktree root:
#       notes   micro on that repo's own notes file
#       claude  $CLAUDE_CMD
#       pwsh    bare shell
#
#   herdr has no real parent/child nesting - the sidebar is a flat list of
#   spaces - so the connector is a per-row token and the rows sit together
#   because they are created back to back (the sidebar orders by creation).
#   See Initialize-StoryWorkspace.
#
#   Re-running for the same story reuses every workspace it already has and adds
#   only the tabs that are missing. Commands are submitted ONLY into tabs the run
#   created, so a tab you are already working in is never typed into.
#
# Git behavior on create - THE SCRIPT OWNS THE BRANCH, NOT HERDR:
#   `herdr worktree create --base <ref>` silently IGNORED --base when the local
#   branch already existed: it just checked that branch out wherever it happened
#   to point and still reported success. A branch left behind by an earlier story
#   (removal that could not delete it, a worktree deleted by hand, another tool)
#   therefore produced a worktree pinned to an old commit - "you are N commits
#   behind" - with nothing in the output to say so. The script now runs
#   `git worktree add` itself, but it still owns the branch position outright:
#     1. `git fetch --prune origin`, WITH the exit code checked (one retry).
#        A failed fetch aborts the repo - never fall back to a stale origin.
#     2. `git remote set-head origin --auto` so refs/remotes/origin/HEAD (which
#        plain `git fetch` never updates) still names the real default branch.
#     3. Resolve the base to an explicit commit sha and verify it exists.
#     4. Put the local branch at exactly that sha - create it, fast-forward a
#        leftover branch that holds no unique commits, or refuse (see below).
#     5. `git worktree add`, then VERIFY the new worktree's HEAD is that sha,
#        repairing a clean worktree once with `git reset --hard` before giving up.
#   development -> base is origin/<default branch>
#   review      -> base is origin/<linked branch>
#   all types -> the branch's upstream is pointed at its OWN name on origin
#                (Set-PushUpstream), so a plain `git push` can never target the
#                default branch.
#
# When the local branch already exists AND holds commits that the base does not,
# the script refuses rather than silently hand back old code or silently discard
# work. It prints those commits and two opt-ins:
#   WT_REUSE_BRANCH=1  keep the existing branch as-is (resume the story; the
#                      script reports how far behind the base it is)
#   WT_RESET_BRANCH=1  discard the unique commits and start from the base
#
# Non-interactive mode (az-watcher / any automation):
#   Set BOTH WT_ID and WT_SLUG and every prompt is skipped - no gum.
#     WT_ID, WT_SLUG, WT_REPOS, WT_BRANCHES_FILE
#
# Exit codes:
#   0  at least one worktree was created and verified
#   1  bad usage / missing input / at least one repo failed
#   3  nothing to do - every requested repo already had a worktree
#
$ErrorActionPreference = 'Stop'

# ===========================================================================
# EDIT THESE FOR YOUR MACHINE
# ===========================================================================
$SRC_ROOT = Join-Path $env:USERPROFILE 'source\repos'
$BRANCH_PREFIX = 'feature/YOU'  # edit this: feature/<you>/<id>-<slug>
# Story worktree base comes from Herdr config [worktrees].directory
$CLAUDE_CMD = 'claude --permission-mode auto'
$CURSOR_CMD = 'agent --auto-review'

# The tabs of the story workspace, in the order they are created. All four open
# at the story root - the repos are sub-folders of it.
$STORY_TABS = @('notes', 'claude', 'cursor', 'pwsh')

# The tabs of each repo's own workspace, opened at that repo's worktree root.
$REPO_TABS = @('notes', 'claude', 'pwsh')

# Tree connectors, reported as each repo row's $tree sidebar token so they render
# to the LEFT of the state icon and the bullet indents with the tree:
#
#     *  23597-my-story
#       |- . *  repo-a
#       `- . *  repo-b
#
# This only renders if config.toml asks for it (see Test-TreeTokenConfigured):
#
#   [ui.sidebar.spaces]
#   rows = [["$tree", "state_icon", "workspace"]]
#
# ABOUT THAT DOT: herdr joins the segments of a sidebar row with a hardcoded
# " . " (a middle dot) and exposes no setting for it - not at [ui],
# [ui.sidebar] or [ui.sidebar.spaces], and a row element's object form only
# accepts token/bold/dim/fg. So a connector segment followed by state_icon always
# shows it. Putting the connector in the LABEL instead avoids the dot, but then
# the status bullet is stuck at the far left and stops reading as nested; that was
# tried and rejected. Keeping the live bullet inside the tree is worth the dot -
# do not "fix" this by moving the connector back into the label.
#
# Built from char codes rather than typed literally: Windows PowerShell 5.1
# reads a .ps1 as ANSI unless it has a BOM, which would mangle them on the way
# in. herdr itself stores and renders them as UTF-8 correctly.
$TREE_BRANCH = -join @([char]0x251C, [char]0x2500)   # |- for all but the last repo
$TREE_LAST = -join @([char]0x2514, [char]0x2500)     # `- for the last one
# Swap both for '|-' and '`-' if your terminal font has no box-drawing glyphs.

# Two blank columns in front of a repo row's connector, so it sits inside its
# story rather than flush under the story's own bullet.
#
# NOT two spaces: herdr TRIMS LEADING WHITESPACE off a token value, so '  |-'
# arrives as '|-' and the indent silently disappears. U+2800 BRAILLE PATTERN BLANK
# is blank on screen but is not whitespace to a trimmer, so it holds the first
# column open; the second can be an ordinary space because interior spaces are
# kept. If U+2800 shows as a box in your font, use two spaces and accept that the
# indent is lost, or pick another blank-but-not-whitespace glyph.
$TREE_INDENT = -join @([char]0x2800, ' ')

# Fallback indent, used only when config.toml does NOT render the $tree token.
# It goes in the label, so it shifts the text but not the bullet - which is
# exactly the limitation $tree exists to fix.
$CHILD_LABEL_PREFIX = '  '

# Characters a label may start with because an EARLIER version of this script put
# them there (it drew the connectors in the label for a while). Stripped when
# matching a row, so such a row is adopted and renamed rather than duplicated.
$TREE_CHARS = -join @([char]0x251C, [char]0x2514, [char]0x2502, [char]0x2500, [char]0x2800, ' ')

# ===========================================================================
$Type = if ($args.Count -ge 1) { $args[0] } else { '' }
if ($Type -notin @('development', 'review')) {
  Write-Error "usage: make-worktree.ps1 <development|review>"
  exit 1
}

$NonInteractive = ($env:WT_ID -and $env:WT_SLUG)
$script:Created = 0
$script:Skipped = 0
$script:Failed = 0

function Need-Cmd([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Write-Error "missing tool: $Name"
    exit 1
  }
}

Need-Cmd herdr
Need-Cmd git
if (-not $NonInteractive) { Need-Cmd gum }

# ---------------------------------------------------------------------------
# Native-command plumbing.
#
# $ErrorActionPreference = 'Stop' plus a redirected native stderr (2>&1) makes
# Windows PowerShell wrap every stderr line in a NativeCommandError and THROW -
# even when the tool exited 0. git and herdr both write ordinary progress to
# stderr, so all of their invocations run with the preference relaxed and are
# judged on $LASTEXITCODE alone.
# ---------------------------------------------------------------------------
$script:GitExit = 0

# Capture stdout lines. Never throws; sets $script:GitExit.
function Git-Out([string]$Repo, [string[]]$GitArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & git -C $Repo @GitArgs 2>$null
    $script:GitExit = $LASTEXITCODE
    if ($null -eq $out) { return @() }
    return @($out)
  } finally { $ErrorActionPreference = $prev }
}

# Run for effect, echoing git's own output (indented) to the console. Returns
# $true on exit 0. Emits nothing to the output stream, so the boolean is safe
# to capture.
function Git-Run([string]$Repo, [string[]]$GitArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & git -C $Repo @GitArgs 2>&1 | ForEach-Object { Write-Host "   $_" }
    $script:GitExit = $LASTEXITCODE
    return ($script:GitExit -eq 0)
  } finally { $ErrorActionPreference = $prev }
}

# First non-empty stdout line, or '' when the command failed / said nothing.
function Git-Line([string]$Repo, [string[]]$GitArgs) {
  $out = Git-Out $Repo $GitArgs
  if ($script:GitExit -ne 0) { return '' }
  foreach ($line in $out) {
    $t = "$line".Trim()
    if ($t) { return $t }
  }
  return ''
}

function Get-ShortSha([string]$Sha) {
  if ($Sha.Length -ge 9) { return $Sha.Substring(0, 9) }
  return $Sha
}

# herdr's stderr is kept OUT of the captured stdout: mixing the two corrupted
# the JSON, and a create that had actually succeeded was then reported as a
# failure. Stderr is stashed in $script:HerdrErr for the error path.
$script:HerdrErr = ''

function Invoke-HerdrCapture([string[]]$HerdrArgs) {
  $errFile = [IO.Path]::GetTempFileName()
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = (& herdr @HerdrArgs 2>$errFile | Out-String)
    $script:HerdrErr = "$(Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)"
    return $out
  } catch {
    $script:HerdrErr = "$_"
    return ''
  } finally {
    $ErrorActionPreference = $prev
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
  }
}

# Parsed herdr JSON, or $null. ConvertFrom-Json rather than jq: it cannot be
# tripped by a stray stderr line and it needs no external process (a `jq ... 2>$null`
# under $ErrorActionPreference='Stop' throws NativeCommandError on any warning).
function Invoke-HerdrJson([string[]]$HerdrArgs) {
  $out = Invoke-HerdrCapture $HerdrArgs
  if (-not $out) { return $null }
  try { return ($out | ConvertFrom-Json) } catch { return $null }
}

# Fire-and-forget herdr call (renames, closes, pane run): output discarded,
# stderr never allowed to throw.
function Invoke-HerdrQuiet([string[]]$HerdrArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & herdr @HerdrArgs 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $prev }
}

# ---------------------------------------------------------------------------
# Talking to the API socket directly
#
# herdr appends every new workspace to the END of the sidebar. That is fine when
# a story is built in one go, but adding a repo to a story that already exists
# drops the new row at the bottom of the sidebar, adrift from the story it
# belongs to - and no amount of connector drawing fixes a row that is thirty
# rows away from its parent.
#
# The protocol has the fix: workspace.move_block takes an ordered list of
# workspace ids plus an anchor to gather them in front of. `herdr workspace` has
# no move subcommand, so it is unreachable through the CLI and this has to speak
# to the socket itself.
#
# On Windows the "socket" is a named pipe whose NAME is the socket file's own
# path (\\.\pipe\C:\...\herdr.sock). The file at that path holds
# "<server-pid>:<token>", but the protocol never asks for the token: requests
# are plain newline-delimited JSON. Access control is the pipe's own ACL.
#
# This is a display nicety, so every failure here is swallowed - an unreachable
# socket, an older herdr without the method, a pipe we cannot open. The rows are
# already correct; only their order suffers.
# ---------------------------------------------------------------------------
# Two things this must NOT do.
#
# It must not derive the socket from HERDR_CONFIG_PATH. That variable names a
# config FILE, which can sit anywhere - the test harness points it at a fixture -
# whereas the socket always lives in herdr's own directory. herdr's CLI resolves
# it this way too, which is why every `herdr` command still reaches the server
# when HERDR_CONFIG_PATH is pointed somewhere else entirely.
#
# And it must not assume the default session. A NAMED session gets its own socket
# under sessions\<name>\; a script that ignored HERDR_SESSION would talk to the
# 'default' server (or to nothing at all) while every herdr command it ran went
# somewhere else. herdr sets HERDR_SESSION in the environment of every pane it
# starts, so a script launched from a quick action inherits the right one.
function Get-HerdrSocketPath {
  if ($env:HERDR_SOCKET_PATH) { return $env:HERDR_SOCKET_PATH }
  $dir = Join-Path $env:APPDATA 'herdr'
  if ($env:HERDR_SESSION) {
    return (Join-Path $dir "sessions\$($env:HERDR_SESSION)\herdr.sock")
  }
  return (Join-Path $dir 'herdr.sock')
}

function Invoke-HerdrSocket([string]$Method, $Params) {
  $sock = Get-HerdrSocketPath
  if (-not (Test-Path -LiteralPath $sock)) { return $null }
  $pipe = $null
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Stop'
  try {
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
      '.', $sock, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(3000)
    $enc = New-Object System.Text.UTF8Encoding($false)
    $req = @{ id = 'worktree-make'; method = $Method; params = $Params } |
      ConvertTo-Json -Depth 8 -Compress
    $bytes = $enc.GetBytes($req + "`n")
    $pipe.Write($bytes, 0, $bytes.Length)
    $pipe.Flush()
    # A pipe stream in byte mode does not support ReadTimeout, so the read is
    # done asynchronously and waited on. Without this a server that never
    # answers would hang the script instead of degrading.
    $sb = New-Object System.Text.StringBuilder
    $buf = New-Object byte[] 65536
    while ($true) {
      $ar = $pipe.BeginRead($buf, 0, $buf.Length, $null, $null)
      if (-not $ar.AsyncWaitHandle.WaitOne(5000)) { return $null }
      $n = $pipe.EndRead($ar)
      if ($n -le 0) { break }
      [void]$sb.Append($enc.GetString($buf, 0, $n))
      if ($sb.ToString().Contains("`n")) { break }
    }
    $text = $sb.ToString().Trim()
    if (-not $text) { return $null }
    return ($text | ConvertFrom-Json)
  } catch {
    return $null
  } finally {
    $ErrorActionPreference = $prev
    if ($pipe) { $pipe.Dispose() }
  }
}

# Every workspace id in sidebar order, worktree-backed rows included. Get-WsIndex
# deliberately drops those, but they still occupy sidebar positions, so ordering
# has to see the whole list to pick a correct anchor.
function Get-SidebarIds {
  $json = Invoke-HerdrJson @('workspace', 'list')
  if ($null -eq $json) { return @() }
  return @(@($json.result.workspaces) |
    Where-Object { $null -ne $_ } |
    ForEach-Object { "$($_.workspace_id)" })
}

# Move one workspace to an absolute 0-based position in the sidebar.
#
# workspace.move is used rather than the newer workspace.move_block because it is
# the only reordering call present on BOTH herdr builds this repo targets: this
# machine runs a 0.7.5 preview (protocol 18, which has move_block), the WSL side
# runs plain 0.7.5 (protocol 17, which does not - it rejects move_block outright
# with "unknown variant"). Driving the older, narrower call from both sides keeps
# the two behaving identically instead of quietly doing nothing on whichever
# machine is behind.
#
# Semantics, verified against a live server: the workspace is removed from the
# list and re-inserted so that it ends up AT insert_index in the resulting list.
function Move-Workspace([string]$Ws, [int]$Index) {
  $resp = Invoke-HerdrSocket 'workspace.move' @{ workspace_id = $Ws; insert_index = $Index }
  if ($null -eq $resp -or $null -ne $resp.error) { return $false }
  return $true
}

# Gather $OrderedIds into one contiguous run, in the order given, without moving
# the group as a whole: the run is anchored where its topmost member already sits.
# Returns $true when the sidebar was changed.
function Set-SidebarOrder([string[]]$OrderedIds) {
  $ids = @($OrderedIds | Where-Object { $_ } | Select-Object -Unique)
  if ($ids.Count -lt 2) { return $false }
  $current = Get-SidebarIds
  if ($current.Count -eq 0) { return $false }

  # Drop ids herdr does not know about - a row closed by hand since the last
  # refresh would otherwise poison the whole call.
  $ids = @($ids | Where-Object { $current -contains $_ })
  if ($ids.Count -lt 2) { return $false }

  # The run is anchored at the topmost member's current slot, so gathering the
  # group never slides the whole block up or down the sidebar.
  $start = -1
  for ($i = 0; $i -lt $current.Count; $i++) {
    if ($ids -contains $current[$i]) { $start = $i; break }
  }
  if ($start -lt 0) { return $false }

  # Already contiguous and already in this order? Then leave the sidebar alone
  # rather than emitting a reorder event every single run.
  $same = $true
  for ($i = 0; $i -lt $ids.Count; $i++) {
    if (($start + $i) -ge $current.Count -or $current[$start + $i] -ne $ids[$i]) {
      $same = $false; break
    }
  }
  if ($same) { return $false }

  # Place the members one at a time, simulating the resulting list as we go so
  # the next index is right without another round trip per move.
  $sim = [System.Collections.Generic.List[string]]::new()
  foreach ($c in $current) { [void]$sim.Add("$c") }
  $moved = $false
  for ($i = 0; $i -lt $ids.Count; $i++) {
    $target = $start + $i
    $at = $sim.IndexOf($ids[$i])
    if ($at -lt 0 -or $at -eq $target) { continue }
    if (-not (Move-Workspace $ids[$i] $target)) { return $false }
    $moved = $true
    $sim.RemoveAt($at)
    $sim.Insert($target, $ids[$i])
  }
  return $moved
}

function Get-PaneIdByTab([string]$Ws, [string]$Tab) {
  $json = Invoke-HerdrJson @('pane', 'list', '--workspace', $Ws)
  if ($null -eq $json) { return '' }
  foreach ($pane in @($json.result.panes)) {
    if ($null -eq $pane) { continue }
    if ($pane.tab_id -eq $Tab) { return "$($pane.pane_id)" }
  }
  return ''
}

function Test-PaneReadyAndIdle([string]$Pane) {
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  $names = @()
  while ([DateTime]::UtcNow -lt $deadline) {
    $info = Invoke-HerdrJson @('pane', 'process-info', '--pane', $Pane)
    if ($null -ne $info) {
      $names = @(@($info.result.process_info.foreground_processes) |
        Where-Object { $null -ne $_ } | ForEach-Object { "$($_.name)" })
    }
    if ($names.Count -gt 0) { break }
    Start-Sleep -Milliseconds 200
  }
  if ($names.Count -eq 0) { return $true }
  foreach ($n in $names) {
    # herdr reports Windows process names complete with their extension
    # ("powershell.exe"), which matched none of the shell names below - so every
    # freshly created pane looked BUSY and the script quietly skipped every
    # command it was supposed to start in it. Compare on the bare name.
    $n = [IO.Path]::GetFileNameWithoutExtension($n.Trim())
    if (-not $n) { continue }
    switch -Regex ($n) {
      '^(pwsh|powershell|powershell_ise|cmd|bash|sh|dash|zsh|fish|-bash|-sh|-zsh)$' { continue }
      default { return $false }
    }
  }
  return $true
}

function Invoke-InTab([string]$Ws, [string]$Tab, [string]$Dir, [string]$Cmd) {
  $pane = Get-PaneIdByTab $Ws $Tab
  if (-not $pane) {
    Write-Warning "no pane found for tab $Tab"
    return
  }
  if (-not (Test-PaneReadyAndIdle $pane)) {
    Write-Host "-> tab ${Tab}: pane busy, left as-is"
    return
  }
  $dirLit = "'" + ($Dir -replace "'", "''") + "'"
  $full = "Set-Location -LiteralPath $dirLit; $Cmd"
  Invoke-HerdrQuiet @('pane', 'run', $pane, $full)
}

function Get-RepoNotesPath([string]$Repo) {
  Join-Path $script:STORY_DIR "$($script:ID)-$($script:SLUG)-$Repo.txt"
}

function Write-RepoNotes([string]$Repo) {
  $notes = Get-RepoNotesPath $Repo
  if (-not (Test-Path -LiteralPath $notes)) {
    New-Item -ItemType File -Path $notes -Force | Out-Null
  }
  # Sidecar for the herdr-plus worktree layout. That layout no longer runs for
  # story worktrees (nothing registers them with herdr any more), but it still
  # fires if the worktree is later opened through herdr's own worktree UI.
  Set-Content -LiteralPath (Join-Path $script:STORY_DIR ".notespath-$Repo") -Value $notes -NoNewline
  Write-Host "-> notes:  $notes"
}

# The notes file the story's notes tab opens: the first repo that was asked for,
# falling back to the first one that actually ended up with a notes file (the
# first repo may have failed).
function Get-StoryNotesPath {
  foreach ($repo in $script:RepoOrder) {
    $p = Get-RepoNotesPath $repo
    if (Test-Path -LiteralPath $p) { return $p }
  }
  if ($script:RepoOrder.Count -gt 0) { return (Get-RepoNotesPath $script:RepoOrder[0]) }
  return ''
}

# Compare paths herdr reports against paths we built. herdr hands back either
# separator, and sometimes doubled backslashes; Windows paths are also
# case-insensitive.
function Get-PathKey([string]$Path) {
  if (-not $Path) { return '' }
  return ($Path -replace '\\+', '/').TrimEnd('/').ToLowerInvariant()
}

function ConvertTo-PsLiteral([string]$Value) {
  return "'" + ($Value -replace "'", "''") + "'"
}

function Get-HerdrConfigPath {
  if ($env:HERDR_CONFIG_PATH) { return $env:HERDR_CONFIG_PATH }
  return (Join-Path $env:APPDATA 'herdr\config.toml')
}

# Does the sidebar actually draw the $tree token?
#
# It is opt-in: herdr renders a space row from [ui.sidebar.spaces].rows, whose
# default is [["state_icon", "workspace"]] - state_icon first, so every bullet
# sits hard against the left edge and no connector is drawn at all. Only a row
# spec that puts $tree BEFORE state_icon draws the tree.
#
# install.ps1 never rewrites config.toml, so the script has to cope with both:
# with $tree the repo label is the bare repo name and the token supplies the
# drawing; without it the label carries a plain indent instead.
function Test-TreeTokenConfigured {
  $cfg = Get-HerdrConfigPath
  if (-not (Test-Path -LiteralPath $cfg)) { return $false }
  $inSection = $false
  foreach ($line in (Get-Content -LiteralPath $cfg -ErrorAction SilentlyContinue)) {
    if ($line -match '^\s*\[ui\.sidebar\.spaces\]') { $inSection = $true; continue }
    if ($line -match '^\s*\[') { $inSection = $false; continue }
    if (-not $inSection) { continue }
    # A commented-out sample line must not count as configured.
    if ($line -match '^\s*#') { continue }
    if ($line -match '\$tree') { return $true }
  }
  return $false
}

# Display-only sidebar token. Never fatal: a herdr that does not take it just
# leaves the row looking the way it does today.
function Set-TreeToken([string]$Ws, [string]$Value) {
  if (-not $Ws) { return }
  if ($Value) {
    Invoke-HerdrQuiet @('workspace', 'report-metadata', $Ws, '--source', 'worktree-make', '--token', "tree=$Value")
  } else {
    Invoke-HerdrQuiet @('workspace', 'report-metadata', $Ws, '--source', 'worktree-make', '--clear-token', 'tree')
  }
}

# The identity inside a label, with any tree drawing or indent stripped off the
# front. Rows are matched on this, not on the whole label, so that a row labelled
# by an earlier version of this script - which drew the connectors in the label,
# or indented them with spaces - is adopted and renamed instead of duplicated.
function Get-BareLabel([string]$Label) {
  if (-not $Label) { return '' }
  return $Label.TrimStart($TREE_CHARS.ToCharArray())
}

function Rename-Workspace([string]$Ws, [string]$Label) {
  if (-not $Ws -or -not $Label) { return }
  Invoke-HerdrQuiet @('workspace', 'rename', $Ws, $Label)
}

# The workspace sitting at $Dir whose label names $BareName, or '' when there is
# none.
#
# Both halves are required. Path alone is not enough now that a story has child
# workspaces one level down: a pane the user cd'd from the story root into a repo
# would otherwise look exactly like that repo's own workspace, and the repo's
# three tabs would be created in the story workspace instead. Name alone is not
# enough either - a development story and a review story of the same id share
# one. Together they are unambiguous.
#
# The comparison is against the BARE name, so the row is still found after the
# tree redraws its label (see Get-BareLabel).
#
# Worktree workspaces are skipped outright: they belong to a repo checkout
# registered with herdr, which is what this script stopped creating.
function Find-WorkspaceAt([string]$Dir, [string]$BareName) {
  $json = Invoke-HerdrJson @('workspace', 'list')
  if ($null -eq $json) { return '' }
  $want = Get-PathKey $Dir
  if (-not $want) { return '' }
  foreach ($w in @($json.result.workspaces)) {
    if ($null -eq $w -or $null -ne $w.worktree) { continue }
    if ((Get-BareLabel "$($w.label)") -ne $BareName) { continue }
    $ws = "$($w.workspace_id)"
    $panes = Invoke-HerdrJson @('pane', 'list', '--workspace', $ws)
    if ($null -eq $panes) { continue }
    foreach ($p in @($panes.result.panes)) {
      if ($null -eq $p) { continue }
      if ((Get-PathKey "$($p.cwd)") -eq $want) { return $ws }
    }
  }
  return ''
}

# The repos of this story: the ones that were asked for first (so the row order
# matches the order you typed), then anything else in the folder that turns out
# to be a worktree - a repo added to the story by an earlier run, or by hand.
function Get-StoryRepos {
  $seen = @{}
  $ordered = @()
  foreach ($repo in $script:RepoOrder) {
    if (-not $repo -or $seen.ContainsKey($repo)) { continue }
    if (Test-Path -LiteralPath (Join-Path (Join-Path $script:STORY_DIR $repo) '.git')) {
      $seen[$repo] = $true
      $ordered += $repo
    }
  }
  $extra = Get-ChildItem -LiteralPath $script:STORY_DIR -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name
  foreach ($d in $extra) {
    if ($seen.ContainsKey($d.Name)) { continue }
    if (Test-Path -LiteralPath (Join-Path $d.FullName '.git')) {
      $seen[$d.Name] = $true
      $ordered += $d.Name
    }
  }
  return $ordered
}

function Get-TabMap([string]$Ws) {
  $map = @{}
  $json = Invoke-HerdrJson @('tab', 'list', '--workspace', $Ws)
  if ($null -eq $json) { return $map }
  foreach ($tab in @($json.result.tabs)) {
    if ($null -eq $tab) { continue }
    $label = "$($tab.label)"
    if ($label -and -not $map.ContainsKey($label)) { $map[$label] = "$($tab.tab_id)" }
  }
  return $map
}

# Create-or-reuse the workspace at $Dir under $Label, holding exactly $TabNames,
# and start $Commands (tab name -> command line) in it. Returns the workspace id,
# or '' if herdr would not create it.
#
# Cosmetic relative to the worktrees themselves: every failure warns and carries
# on, because the checkouts on disk are already correct and usable either way.
#
# Commands are only ever submitted into tabs THIS CALL created. Test-PaneReadyAndIdle
# is not enough on its own: herdr reports claude.exe in a busy pane but reports
# only the shell for a pane sitting in micro, so a re-run that trusted the probe
# would type "micro <path>" straight into the open notes buffer.
function Initialize-Workspace([string]$Dir, [string]$Label, [string]$BareName,
  [string[]]$TabNames, [hashtable]$Commands) {
  $fresh = @{}
  $ws = Find-WorkspaceAt $Dir $BareName
  if ($ws) {
    Write-Host "-> herdr:  reusing workspace $ws ($BareName)"
    # The row may carry a label from an earlier version of this script, which drew
    # the connectors in the label instead of the token.
    Rename-Workspace $ws $Label
  } else {
    $created = Invoke-HerdrJson @(
      'workspace', 'create', '--cwd', $Dir, '--label', $Label, '--no-focus'
    )
    $ws = if ($null -ne $created) { "$($created.result.workspace.workspace_id)" } else { '' }
    if (-not $ws) {
      if ($script:HerdrErr) { Write-Host $script:HerdrErr }
      Write-Warning ("could not create the herdr workspace for '$Label' - the worktrees " +
        "are fine; open $Dir by hand")
      return ''
    }
    # A new workspace arrives with one numbered tab. Reuse it as the first tab
    # rather than leaving a stray "1" alongside the created ones.
    $rootTab = "$($created.result.tab.tab_id)"
    if ($rootTab -and $TabNames.Count -gt 0) {
      Invoke-HerdrQuiet @('tab', 'rename', $rootTab, $TabNames[0])
      $fresh[$TabNames[0]] = $true
    }
    Write-Host "-> herdr:  workspace $ws created ($Label) at $Dir"
  }

  $tabs = Get-TabMap $ws
  foreach ($name in $TabNames) {
    if ($tabs.ContainsKey($name)) { continue }
    $t = Invoke-HerdrJson @(
      'tab', 'create', '--workspace', $ws, '--cwd', $Dir, '--label', $name, '--no-focus'
    )
    $id = if ($null -ne $t) { "$($t.result.tab.tab_id)" } else { '' }
    if ($id) {
      $tabs[$name] = $id
      $fresh[$name] = $true
    } else {
      Write-Warning "could not create the '$name' tab in workspace $ws"
    }
  }

  foreach ($name in $TabNames) {
    if (-not $fresh[$name] -or -not $tabs[$name]) { continue }
    $cmd = "$($Commands[$name])"
    if (-not $cmd) { continue }
    Invoke-InTab $ws $tabs[$name] $Dir $cmd
  }

  $started = @($TabNames | Where-Object { $fresh[$_] })
  $kept = @($TabNames | Where-Object { -not $fresh[$_] })
  Write-Host "-> tabs:   $($TabNames -join ', ')"
  if ($started.Count -gt 0) { Write-Host "           started: $($started -join ', ')" }
  if ($kept.Count -gt 0) { Write-Host "           left as they were: $($kept -join ', ')" }
  return $ws
}

# The story row, then one row per repo drawn beneath it as its children.
#
#     {id}-{slug}          story workspace, cwd = story folder
#     |- repo1             repo workspace,  cwd = story/repo1
#     `- repo2
#
# herdr has NO parent/child nesting: its sidebar is a flat list of spaces (only
# worktree workspaces get grouped, and then always under their clone - the very
# thing this replaced). Two things stand in for it:
#
#   * the connector, reported as each repo row's $tree token so it renders to the
#     LEFT of the state icon and the bullet indents with the tree. Indenting the
#     label alone cannot do that - the bullet comes from state_icon, the first
#     thing in the row - which is why $CHILD_LABEL_PREFIX is only the fallback
#     for a config.toml that does not lay the row out that way. herdr also draws
#     its own " . " between segments, which no setting suppresses; that dot is
#     accepted deliberately, see the $TREE_BRANCH block.
#   * adjacency, from creating the repo rows immediately after their story row,
#     since the sidebar orders by creation. A repo added to an existing story
#     lands at the bottom of the list rather than under its story until herdr is
#     restarted.
function Initialize-StoryWorkspace {
  $notes = Get-StoryNotesPath
  $storyCmds = @{ claude = $CLAUDE_CMD; cursor = $CURSOR_CMD }
  if ($notes) { $storyCmds['notes'] = "micro $(ConvertTo-PsLiteral $notes)" }
  $notesName = if ($notes) { Split-Path -Leaf $notes } else { 'none' }
  Write-Host "-> story:  workspace tabs at the story root (notes -> $notesName)"

  $storyName = "$($script:ID)-$($script:SLUG)"
  $ws = Initialize-Workspace $script:STORY_DIR $storyName $storyName $STORY_TABS $storyCmds
  if (-not $ws) { return }
  # The story row is the trunk: no connector. An absent token renders as nothing -
  # no segment, so no separator dot either - the same way $jj_status does on a
  # workspace that is not a jj repo.
  Set-TreeToken $ws ''

  # The story row leads; each repo row follows in the order the story lists them.
  $ordered = @($ws)

  $tree = Test-TreeTokenConfigured
  $repos = @(Get-StoryRepos)
  for ($i = 0; $i -lt $repos.Count; $i++) {
    $repo = $repos[$i]
    $dir = Join-Path $script:STORY_DIR $repo
    $repoNotes = Get-RepoNotesPath $repo
    $repoCmds = @{ claude = $CLAUDE_CMD }
    if (Test-Path -LiteralPath $repoNotes) {
      $repoCmds['notes'] = "micro $(ConvertTo-PsLiteral $repoNotes)"
    }
    # Connectors are re-reported every run, so the repo that used to be last gives
    # up its corner when a new one is added after it.
    $connector = if ($i -eq $repos.Count - 1) { $TREE_LAST } else { $TREE_BRANCH }
    $label = if ($tree) { $repo } else { "$CHILD_LABEL_PREFIX$repo" }
    Write-Host "-> repo:   $repo"
    $rws = Initialize-Workspace $dir $label $repo $REPO_TABS $repoCmds
    Set-TreeToken $rws ($TREE_INDENT + $connector)
    if ($rws) { $ordered += $rws }
  }

  # A repo added to a story that already exists is created last, so herdr parks
  # it at the bottom of the sidebar instead of under its story. Pull the story's
  # rows back into one run. The connectors above are drawn from $repos, not from
  # sidebar position, so they are already right either way - this only fixes
  # where the rows physically sit.
  if (Set-SidebarOrder $ordered) {
    Write-Host ''
    Write-Host '-> sidebar: pulled the story rows back together'
  }

  if (-not $tree -and $repos.Count -gt 0) {
    Write-Host ''
    Write-Host 'NOTE: the repo rows are indented by their label, so their bullets still sit'
    Write-Host '      hard left and no connectors are drawn. To draw the tree, add this to'
    Write-Host "      $(Get-HerdrConfigPath) and run 'herdr server reload-config':"
    Write-Host ''
    Write-Host '        [ui.sidebar.spaces]'
    Write-Host '        rows = [["$tree", "state_icon", "workspace"]]'
    Write-Host ''
  }
}

function Ask-Gum([string]$Prompt, [string]$Placeholder) {
  & gum input --prompt "$Prompt > " --placeholder $Placeholder
}

# A repo-level problem. Fatal when a human is driving (they asked for exactly
# these repos); counted and reported in non-interactive mode so one bad repo
# cannot abort a cron run - but the run still exits non-zero at the end.
# Writes to the error stream only, so callers can `Repo-Fail ...; return`.
function Repo-Fail([string]$Msg) {
  $script:Failed++
  Write-Error $Msg -ErrorAction Continue
  if (-not $NonInteractive) { exit 1 }
}

function Test-WorktreePresent([string]$Repo) {
  $gitPath = Join-Path $script:STORY_DIR "$Repo\.git"
  if (Test-Path -LiteralPath $gitPath) {
    Write-Host "-> ${Repo}: worktree exists at $(Join-Path $script:STORY_DIR $Repo), skipping"
    $script:Skipped++
    return $true
  }
  return $false
}

function Resolve-WorktreeRoot {
  $cfg = if ($env:HERDR_CONFIG_PATH) { $env:HERDR_CONFIG_PATH } else {
    Join-Path $env:APPDATA 'herdr\config.toml'
  }
  $dir = ''
  if (Test-Path -LiteralPath $cfg) {
    $inSection = $false
    foreach ($line in Get-Content -LiteralPath $cfg) {
      if ($line -match '^\[worktrees\]') { $inSection = $true; continue }
      if ($line -match '^\[') { $inSection = $false; continue }
      if ($inSection -and $line -match '^\s*directory\s*=') {
        $dir = ($line -replace '^[^=]*=\s*', '' -replace '\s+#.*$', '').Trim()
        $quoted = $dir.StartsWith('"')
        $dir = $dir.Trim('"').Trim("'")
        # A TOML basic string escapes backslashes, which is how the README tells
        # you to write a Windows path: "C:\\Users\\me\\source\\worktrees".
        # Un-escape it so the value is a real path rather than one with doubled
        # separators (which then leaks into every message the script prints).
        if ($quoted) { $dir = $dir.Replace('\\', '\') }
        break
      }
    }
  }
  if (-not $dir) { $dir = '~/source/worktrees' }
  if ($dir -eq '~') {
    $dir = $env:USERPROFILE
  } elseif ($dir.StartsWith('~/')) {
    $dir = Join-Path $env:USERPROFILE $dir.Substring(2)
  }
  $dir = $dir.Replace('$HOME', $env:USERPROFILE).Replace('${HOME}', $env:USERPROFILE)
  $dir = $dir.Replace('%USERPROFILE%', $env:USERPROFILE)
  return $dir
}

# ---------------------------------------------------------------------------
# Git: getting the base right
# ---------------------------------------------------------------------------

# Fetch, and MEAN it. A fetch that fails (expired credentials, network, a
# stale index.lock, a concurrent gc) used to be ignored, after which the
# worktree was cut from whatever origin/<default> happened to be - the exact
# "N commits behind" symptom. One retry, then the caller aborts the repo.
function Update-Remote([string]$Src) {
  foreach ($attempt in 1, 2) {
    $label = if ($attempt -eq 1) { '' } else { " (retry $attempt)" }
    Write-Host "-> fetch:  git fetch --prune origin in $Src$label"
    if (Git-Run $Src @('fetch', '--prune', 'origin')) { return $true }
    Write-Warning "git fetch --prune origin failed in $Src (exit $script:GitExit)"
    if ($attempt -eq 1) { Start-Sleep -Seconds 3 }
  }
  return $false
}

# `git fetch` never updates refs/remotes/origin/HEAD, so a clone made before the
# remote's default branch was renamed - or one where the ref was never written -
# keeps pointing at the wrong branch forever. Re-derive it from the remote.
# Best effort: offline, the cached ref (or the fallbacks below) still works.
function Sync-OriginHead([string]$Src) {
  Git-Out $Src @('remote', 'set-head', 'origin', '--auto') | Out-Null
}

# Resolve a ref to a full commit sha, or '' when it does not exist.
function Resolve-Commit([string]$Repo, [string]$Ref) {
  return (Git-Line $Repo @('rev-parse', '--verify', '--quiet', "$Ref^{commit}"))
}

function Get-DefaultBranch([string]$Src) {
  $d = Git-Line $Src @('symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD')
  if ($d) { $d = $d -replace '^origin/', '' }
  if (-not $d) {
    foreach ($line in (Git-Out $Src @('ls-remote', '--symref', 'origin', 'HEAD'))) {
      if ("$line" -match '^ref:\s+refs/heads/(\S+)') {
        $d = $Matches[1]
        break
      }
    }
  }
  # Only trust it if the matching remote-tracking ref actually exists: the old
  # blind `main` fallback could name a branch that is real but is NOT the
  # default (or does not exist at all, which herdr then rejects outright).
  if ($d -and (Resolve-Commit $Src "refs/remotes/origin/$d")) { return $d }
  foreach ($candidate in @('main', 'master', 'trunk', 'develop')) {
    if (Resolve-Commit $Src "refs/remotes/origin/$candidate") {
      Write-Warning "origin/HEAD unusable in ${Src}; falling back to origin/$candidate"
      return $candidate
    }
  }
  return ''
}

# Path of the worktree that has $Branch checked out, or '' when it is free.
function Get-BranchWorktreePath([string]$Src, [string]$Branch) {
  $current = ''
  foreach ($line in (Git-Out $Src @('worktree', 'list', '--porcelain'))) {
    $t = "$line"
    if ($t -match '^worktree\s+(.+)$') { $current = $Matches[1].Trim(); continue }
    if ($t -match '^branch\s+(.+)$') {
      if ($Matches[1].Trim() -eq "refs/heads/$Branch") { return $current }
    }
  }
  return ''
}

function Get-CommitCount([string]$Repo, [string]$Range) {
  $n = Git-Line $Repo @('rev-list', '--count', $Range)
  if ($n -match '^\d+$') { return [int]$n }
  return 0
}

# Put the local branch at exactly $Base and return the sha the new worktree must
# end up on ('' means: do not create this worktree).
#
# This is the fix for the reported bug: herdr honours --base only when it has to
# create the branch, so the script guarantees the branch position itself.
function Set-BranchAtBase([string]$Src, [string]$Branch, [string]$Base, [string]$BaseLabel) {
  $existing = Resolve-Commit $Src "refs/heads/$Branch"

  if (-not $existing) {
    if (-not (Git-Run $Src @('branch', '--no-track', $Branch, $Base))) {
      Repo-Fail "could not create branch $Branch at $BaseLabel in $Src"
      return ''
    }
    Write-Host "-> branch: $Branch created at $BaseLabel ($(Get-ShortSha $Base))"
    return $Base
  }

  # An existing branch checked out somewhere else is a hard conflict: herdr
  # cannot check it out twice, and silently reusing it is what produced stale
  # worktrees before.
  $inUse = Get-BranchWorktreePath $Src $Branch
  if ($inUse) {
    Repo-Fail ("branch $Branch is already checked out at $inUse - " +
      'remove that worktree first, or use a different story slug')
    return ''
  }

  if ($existing -eq $Base) {
    Write-Host "-> branch: $Branch already at $BaseLabel ($(Get-ShortSha $Base))"
    return $Base
  }

  $unique = Get-CommitCount $Src "$Base..refs/heads/$Branch"
  $behind = Get-CommitCount $Src "refs/heads/$Branch..$Base"

  if ($unique -eq 0) {
    # Leftover branch with nothing of its own - the common case after a story
    # was removed. Nothing can be lost, so move it to the base.
    if (-not (Git-Run $Src @('branch', '--force', '--no-track', $Branch, $Base))) {
      Repo-Fail "could not move existing branch $Branch to $BaseLabel in $Src"
      return ''
    }
    Write-Host ("-> branch: $Branch was $behind commit(s) behind $BaseLabel " +
      "with no commits of its own - moved to $(Get-ShortSha $Base)")
    return $Base
  }

  if ($env:WT_RESET_BRANCH -eq '1') {
    Write-Warning "WT_RESET_BRANCH=1 - discarding $unique commit(s) on ${Branch}:"
    foreach ($line in (Git-Out $Src @('log', '--oneline', '--no-decorate', "$Base..refs/heads/$Branch"))) {
      Write-Host "     $line"
    }
    if (-not (Git-Run $Src @('branch', '--force', '--no-track', $Branch, $Base))) {
      Repo-Fail "could not reset branch $Branch to $BaseLabel in $Src"
      return ''
    }
    Write-Host "-> branch: $Branch reset to $BaseLabel ($(Get-ShortSha $Base))"
    return $Base
  }

  if ($env:WT_REUSE_BRANCH -eq '1') {
    Write-Warning ("WT_REUSE_BRANCH=1 - keeping existing $Branch at " +
      "$(Get-ShortSha $existing): $unique own commit(s), $behind behind $BaseLabel." +
      " Run 'git merge $BaseLabel' in the worktree to catch up.")
    return $existing
  }

  Repo-Fail (@(
    "branch $Branch already exists in $Src at $(Get-ShortSha $existing) with $unique commit(s)"
    "  that $BaseLabel does not have, and is $behind commit(s) behind it. Refusing to create"
    "  a worktree that would be out of date or to throw those commits away. Either:"
    "    WT_REUSE_BRANCH=1  keep the branch and resume the story on it"
    "    WT_RESET_BRANCH=1  discard its $unique commit(s) and start from $BaseLabel"
    "  or delete it yourself:  git -C `"$Src`" branch -D $Branch"
  ) -join "`n")
  foreach ($line in (Git-Out $Src @('log', '--oneline', '--no-decorate', "$Base..refs/heads/$Branch"))) {
    Write-Host "     $line"
  }
  return ''
}

# `git worktree add` refuses a path that is registered-but-missing (a worktree
# deleted by hand) or one that already has files in it. Prune the administrative
# leftovers and clear a directory that an earlier failed run left empty.
function Initialize-WorktreePath([string]$Src, [string]$Path) {
  Git-Out $Src @('worktree', 'prune') | Out-Null
  if (-not (Test-Path -LiteralPath $Path)) { return $true }
  $entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
  if ($entries.Count -eq 0) {
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    Write-Host "-> path:   removed empty leftover directory $Path"
    return $true
  }
  Repo-Fail ("$Path already exists, is not a worktree, and is not empty - " +
    'remove it or use a different story slug')
  return $false
}

# The safety net: whatever herdr did, the worktree must sit on $Expected.
function Assert-WorktreeAt([string]$Wt, [string]$Expected, [string]$Label) {
  $head = Resolve-Commit $Wt 'HEAD'
  if ($head -eq $Expected) {
    Write-Host "-> verify: HEAD $(Get-ShortSha $Expected) == $Label"
    return $true
  }
  Write-Warning ("worktree $Wt is at '$head' but should be at " +
    "$(Get-ShortSha $Expected) ($Label) - repairing")
  $dirty = @(Git-Out $Wt @('status', '--porcelain'))
  if ($dirty.Count -gt 0) {
    Repo-Fail "worktree $Wt is at the wrong commit and has local changes - fix it by hand"
    return $false
  }
  if (-not (Git-Run $Wt @('reset', '--hard', $Expected))) {
    Repo-Fail "could not reset $Wt to $(Get-ShortSha $Expected) ($Label)"
    return $false
  }
  $head = Resolve-Commit $Wt 'HEAD'
  if ($head -ne $Expected) {
    Repo-Fail "worktree $Wt still at '$head' after reset - expected $(Get-ShortSha $Expected)"
    return $false
  }
  Write-Host "-> verify: HEAD repaired to $(Get-ShortSha $Expected) == $Label"
  return $true
}

function Set-PushUpstream([string]$Wt, [string]$Branch) {
  Git-Out $Wt @('config', "branch.$Branch.remote", 'origin') | Out-Null
  Git-Out $Wt @('config', "branch.$Branch.merge", "refs/heads/$Branch") | Out-Null
  Write-Host "-> push:   git push targets origin/$Branch"
}

# ---------------------------------------------------------------------------
# One worktree, one shared code path.
#   development -> $BaseRef = "refs/remotes/origin/<default>"
#   review      -> $BaseRef = "refs/remotes/origin/<branch>"
# ---------------------------------------------------------------------------
function New-Worktree([string]$Repo, [string]$Branch, [string]$BaseKind) {
  if (Test-WorktreePresent $Repo) { return }

  $src = Join-Path $SRC_ROOT $Repo
  if (-not (Test-Path -LiteralPath (Join-Path $src '.git'))) {
    Repo-Fail "missing clone: $src (set SRC_ROOT or clone the repo there)"
    return
  }

  $path = Join-Path $script:STORY_DIR $Repo
  if (-not (Initialize-WorktreePath $src $path)) { return }

  if (-not (Update-Remote $src)) {
    Repo-Fail ("git fetch failed for $Repo - refusing to create a worktree from a " +
      'possibly stale origin. Check credentials/network and re-run.')
    return
  }
  Sync-OriginHead $src

  if ($BaseKind -eq 'default') {
    $def = Get-DefaultBranch $src
    if (-not $def) {
      Repo-Fail "cannot determine the default branch of $src (no usable origin/HEAD)"
      return
    }
    $baseLabel = "origin/$def"
  } else {
    $baseLabel = "origin/$Branch"
  }

  $base = Resolve-Commit $src "refs/remotes/$baseLabel"
  if (-not $base) {
    Repo-Fail "$baseLabel does not exist in $src after fetching - nothing to base $Branch on"
    return
  }
  Write-Host "-> base:   $baseLabel @ $(Get-ShortSha $base)"

  $expected = Set-BranchAtBase $src $Branch $base $baseLabel
  if (-not $expected) { return }

  # The branch is already sitting on $expected, so this only checks it out.
  if (-not (Git-Run $src @('worktree', 'add', $path, $Branch))) {
    Repo-Fail "git worktree add failed for $Repo at $path (exit $script:GitExit)"
    return
  }

  if (-not (Assert-WorktreeAt $path $expected $baseLabel)) { return }

  $script:Created++
  Set-PushUpstream $path $Branch
  Write-RepoNotes $Repo
}

# --- roots -----------------------------------------------------------------
$WORKTREE_ROOT = Resolve-WorktreeRoot
$SUBFOLDER = $Type
Write-Host "-> worktree root (from herdr [worktrees].directory): $WORKTREE_ROOT"

# --- shared inputs ---------------------------------------------------------
if ($NonInteractive) {
  $script:ID = $env:WT_ID
  $script:SLUG = $env:WT_SLUG
  Write-Host '-> non-interactive (WT_ID/WT_SLUG supplied)'
} else {
  $script:ID = Ask-Gum 'Story id' '12345'
  $script:SLUG = Ask-Gum 'Slug' 'slug-example'
}
if (-not $script:ID -or -not $script:SLUG) {
  Write-Error 'id and slug required'
  exit 1
}

$BRANCH = "$BRANCH_PREFIX/$($script:ID)-$($script:SLUG)"
$TYPE_DIR = Join-Path $WORKTREE_ROOT $SUBFOLDER
$script:STORY_DIR = Join-Path $TYPE_DIR "$($script:ID)-$($script:SLUG)"
# Repos in the order they were requested. The first one owns the notes file the
# story's notes tab opens.
$script:RepoOrder = @()

New-Item -ItemType Directory -Force -Path $script:STORY_DIR | Out-Null
Write-Host "-> story:  $($script:STORY_DIR)"
Write-Host "-> branch: $BRANCH"

# ===========================================================================
# DEVELOPMENT
# ===========================================================================
if ($Type -eq 'development') {
  if ($NonInteractive) {
    $REPOS = $env:WT_REPOS
    if (-not $REPOS) {
      Write-Error 'WT_REPOS required in non-interactive mode'
      exit 1
    }
  } else {
    $REPOS = Ask-Gum 'Repos (csv)' 'repo-a,repo-b,repo-c'
    if (-not $REPOS) {
      Write-Error 'repos required'
      exit 1
    }
  }

  foreach ($repo in ($REPOS -split ',')) {
    $repo = $repo.Trim()
    if (-not $repo) { continue }
    $script:RepoOrder += $repo
    try {
      New-Worktree $repo $BRANCH 'default'
    } catch {
      $script:Failed++
      Write-Warning "skipped ${repo}: $_"
    }
  }
}

# ===========================================================================
# REVIEW
# ===========================================================================
if ($Type -eq 'review') {
  if ($NonInteractive -and $env:WT_BRANCHES_FILE) {
    $BRANCHES = $env:WT_BRANCHES_FILE
    if (-not (Test-Path -LiteralPath $BRANCHES) -or (Get-Item -LiteralPath $BRANCHES).Length -eq 0) {
      Write-Error "WT_BRANCHES_FILE is empty: $BRANCHES"
      exit 1
    }
    Write-Host "-> branches from WT_BRANCHES_FILE: $BRANCHES"
  } else {
    $BRANCHES = Join-Path $script:STORY_DIR "branches-$($script:ID).txt"
    @"
repo-a:$BRANCH_PREFIX/$($script:ID)-$($script:SLUG)
repo-b:bugfix/$($script:ID)-example
repo-c:$BRANCH_PREFIX/$($script:ID)-$($script:SLUG)
"@ | Set-Content -LiteralPath $BRANCHES -Encoding utf8
    Write-Warning "placeholder branches in $BRANCHES -- replace with az output at work."
  }

  $attempted = 0
  foreach ($raw in (Get-Content -LiteralPath $BRANCHES)) {
    $line = "$raw".Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }
    $idx = $line.IndexOf(':')
    if ($idx -lt 1) { continue }
    $repo = $line.Substring(0, $idx).Trim()
    $branch = $line.Substring($idx + 1).Trim()
    if (-not $repo -or -not $branch) { continue }
    $attempted++
    $script:RepoOrder += $repo
    try {
      New-Worktree $repo $branch 'remote'
    } catch {
      $script:Failed++
      Write-Warning "skipped ${repo}: $_"
    }
  }
  # A branches file that yields nothing usable must not look like a clean run.
  if ($attempted -eq 0) {
    Write-Error "no usable '<repo>:<branch>' lines in $BRANCHES"
    exit 1
  }
}

# One workspace for the whole story, opened once the repos are in place: its
# tabs live at the story root and the notes tab has to know which notes files
# exist. Also runs on a pure re-run (Created 0, Skipped > 0) so a story whose
# workspace was closed gets it back instead of silently staying invisible.
if (($script:Created + $script:Skipped) -gt 0) {
  try {
    Initialize-StoryWorkspace
  } catch {
    Write-Warning "worktrees are ready, but the herdr workspace setup failed: $_"
  }
}

Write-Host "OK $Type ready at $($script:STORY_DIR)"

if ($script:Failed -gt 0) {
  Write-Host "-> $($script:Failed) repo(s) failed - see the errors above"
  exit 1
}
if ($script:Created -eq 0 -and $script:Skipped -gt 0) {
  Write-Host '-> nothing to do: all requested worktrees already exist'
  exit 3
}
# Explicit: falling off the end would leave $LASTEXITCODE holding the status of
# whatever native command ran last, which callers (az-watcher, the ~/bin
# forwarder) read as the script's own result.
exit 0
