# worktree-remove.ps1
# Delete an entire story by id: for every repo worktree in each matching story
# folder it removes via herdr (with git fallback), deletes the local branch,
# then deletes notes and the story folder.
#
# Two herdr shapes have to be handled, because worktree-make.ps1 changed:
#   * story workspaces (current) - plain workspaces, no worktree metadata: the
#     story row rooted at the story folder plus one indented repo row rooted at
#     each repo inside it. ALL of them are closed FIRST, and only when every
#     worktree in that story is going away: their agents hold files in the
#     checkouts open, so removing a checkout underneath a live pane is what
#     leaves undeletable debris behind.
#   * per-repo worktree workspace (legacy) - one herdr-registered worktree
#     workspace per repo, matched by checkout path. Stories created before the
#     switch still look like this, so `herdr worktree remove` stays.
#
# Environment hooks (used by az-watcher; all optional):
#   WT_ID, WT_ASSUME_YES, WT_REPO, WT_SKIP_DIRTY
#
# Exit codes:
#   0  something was removed
#   3  nothing to do (no matching story folder / no matching repo worktree)
#   5  nothing removed because every match was dirty (WT_SKIP_DIRTY=1)
#
$ErrorActionPreference = 'Stop'

function Need-Cmd([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Write-Error "missing tool: $Name"
    exit 1
  }
}

Need-Cmd herdr
Need-Cmd git
if ($env:WT_ASSUME_YES -ne '1') { Need-Cmd gum }

# ---------------------------------------------------------------------------
# Native-command plumbing.
#
# $ErrorActionPreference = 'Stop' plus a redirected native stderr (2>$null) makes
# Windows PowerShell wrap every stderr line in a NativeCommandError and THROW.
# Removal is full of calls that fail routinely - `herdr worktree remove` hits
# "Permission denied" whenever a pane still holds the directory open, and
# `git branch -D` can refuse - and each throw aborted the whole removal partway
# through, *before* the fallbacks written to handle exactly those cases could
# run. Every native call now goes through these helpers and is judged on its
# exit code.
# ---------------------------------------------------------------------------
$script:NativeExit = 0

function Invoke-Native([string]$Exe, [string[]]$ExeArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $Exe @ExeArgs 2>$null
    $script:NativeExit = $LASTEXITCODE
    if ($null -eq $out) { return @() }
    return @($out)
  } catch {
    $script:NativeExit = 1
    return @()
  } finally { $ErrorActionPreference = $prev }
}

function Invoke-Git([string]$Repo, [string[]]$GitArgs) {
  return (Invoke-Native 'git' (@('-C', $Repo) + $GitArgs))
}

# $true when the command exited 0.
function Test-Git([string]$Repo, [string[]]$GitArgs) {
  Invoke-Git $Repo $GitArgs | Out-Null
  return ($script:NativeExit -eq 0)
}

function Test-Herdr([string[]]$HerdrArgs) {
  Invoke-Native 'herdr' $HerdrArgs | Out-Null
  return ($script:NativeExit -eq 0)
}

# Delete a directory, tolerating a transient holder. On Windows a freshly
# written checkout is routinely locked for a moment by an indexer, a virus
# scanner, or a pane that is still shutting down; one attempt then reporting
# "stuck" turns a wait-half-a-second problem into a failed removal.
# Returns $true when the path is gone.
function Remove-DirRetry([string]$Path) {
  foreach ($attempt in 1..4) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    if ($attempt -lt 4) { Start-Sleep -Milliseconds (250 * $attempt) }
  }
  return (-not (Test-Path -LiteralPath $Path))
}

function Ask-Gum([string]$Prompt, [string]$Placeholder) {
  & gum input --prompt "$Prompt > " --placeholder $Placeholder
}

# One-of-a-list prompt. Items are passed as ARGUMENTS rather than piped in:
# piping into gum on Windows PowerShell hands it whatever encoding the console
# happens to be in, and a mangled label cannot be mapped back to its story.
# Returns '' when gum errors or the user pressed esc.
#
# DO NOT redirect stderr here. gum draws its interactive menu on STDERR and
# returns only the chosen line on stdout (the same split fzf uses), so a `2>$null`
# silently discards the entire UI - gum then sits waiting for keystrokes on a menu
# that was never drawn, which reads exactly like a hang. Measured: with no tty,
# `gum choose a b c` wrote 0 bytes to stdout and the whole menu to stderr.
# Ask-Gum above works for the same reason - it never redirects either.
function Select-Gum([string]$Header, [string[]]$Items) {
  if ($Items.Count -eq 0) { return '' }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $height = [Math]::Min(12, [Math]::Max(3, $Items.Count))
    $out = & gum choose --header $Header --height $height @Items
    if ($LASTEXITCODE -ne 0) { return '' }
    return "$out".Trim()
  } catch { return '' } finally { $ErrorActionPreference = $prev }
}

# The stories that actually exist on disk, most recently touched first.
#
# Keyed by id, not by folder: removal is by id and takes the development AND
# review copies of a story together, so listing the same id twice would offer
# two entries that do exactly the same thing. The types it was found under are
# shown on the row instead.
function Get-StoryChoices {
  $byId = [ordered]@{}
  foreach ($type in @('development', 'review')) {
    $base = Join-Path $HERDR_ROOT $type
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
    foreach ($d in (Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
      # Same shapes Add-Glob matches: {id}-{slug} and legacy {id}_{slug}.
      if ($d.Name -notmatch '^(\d+)[-_]') { continue }
      $id = $Matches[1]
      if (-not $byId.Contains($id)) {
        $byId[$id] = [pscustomobject]@{
          Id = $id; Name = $d.Name; Types = @(); Latest = $d.LastWriteTime
        }
      }
      $entry = $byId[$id]
      if ($entry.Types -notcontains $type) { $entry.Types += $type }
      if ($d.LastWriteTime -gt $entry.Latest) { $entry.Latest = $d.LastWriteTime }
    }
  }
  return @($byId.Values | Sort-Object Latest -Descending)
}

# Pick a story to delete. Falls back to typing an id whenever the list cannot be
# offered - no stories on disk, or a gum that will not draw - so this is never a
# dead end on a machine where the picker does not work.
function Select-StoryId {
  $choices = @(Get-StoryChoices)
  if ($choices.Count -eq 0) {
    Write-Host "No story folders under $HERDR_ROOT\development|review - enter an id instead."
    return (Ask-Gum 'Story id' '12345')
  }
  $labels = @($choices | ForEach-Object { "$($_.Name)  [$($_.Types -join '+')]" })
  $picked = Select-Gum 'Story to delete (esc to cancel)' $labels
  if (-not $picked) { return '' }
  for ($i = 0; $i -lt $labels.Count; $i++) {
    if ($labels[$i] -eq $picked) { return $choices[$i].Id }
  }
  # Defensive: gum echoed something we did not offer. The id still leads.
  if ($picked -match '^(\d+)[-_]') { return $Matches[1] }
  return ''
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
        $dir = ($line -replace '^[^=]*=\s*', '' -replace '\s+#.*$', '').Trim().Trim('"').Trim("'")
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

# Names of refs that must never be deleted as a story branch. Blindly falling
# back to 'main' was unsafe here: in a repo whose default is something else
# (e.g. develop) the guard below would not recognise the real default.
function Get-ProtectedBranches([string]$Src) {
  $names = [System.Collections.Generic.List[string]]::new()
  foreach ($line in (Invoke-Git $Src @('symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD'))) {
    $d = "$line".Trim() -replace '^origin/', ''
    if ($d) { $names.Add($d) | Out-Null }
  }
  foreach ($line in (Invoke-Git $Src @('ls-remote', '--symref', 'origin', 'HEAD'))) {
    if ("$line" -match '^ref:\s+refs/heads/(\S+)') { $names.Add($Matches[1]) | Out-Null }
  }
  foreach ($n in @('main', 'master', 'trunk', 'develop', 'HEAD')) { $names.Add($n) | Out-Null }
  return $names
}

function Get-SlugFromStoryName([string]$Name, [string]$Id) {
  $s = $Name.Substring($Id.Length)
  if ($s.StartsWith('-') -or $s.StartsWith('_')) { $s = $s.Substring(1) }
  return $s
}

# herdr reports paths with either separator, and sometimes with doubled
# backslashes; Windows paths are also case-insensitive. Compare on this form.
function Get-PathKey([string]$Path) {
  if (-not $Path) { return '' }
  return ($Path -replace '\\+', '/').TrimEnd('/').ToLowerInvariant()
}

function Get-WorkspaceList {
  $lines = Invoke-Native 'herdr' @('workspace', 'list')
  if ($lines.Count -eq 0) { return @() }
  $obj = $null
  try { $obj = ($lines -join "`n") | ConvertFrom-Json } catch { return @() }
  return @($obj.result.workspaces)
}

# Legacy shape: the herdr-registered worktree workspace for one repo checkout.
function Get-WorkspaceIdForPath([string]$Path) {
  $norm = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue)
  if ($norm) { $Path = $norm.Path }
  $want = Get-PathKey $Path
  if (-not $want) { return '' }
  foreach ($w in (Get-WorkspaceList)) {
    if ($null -eq $w -or $null -eq $w.worktree) { continue }
    if ((Get-PathKey "$($w.worktree.checkout_path)") -eq $want) { return "$($w.workspace_id)" }
  }
  return ''
}

# Current shape: EVERY workspace belonging to the story - the story row itself
# plus the indented repo row worktree-make.ps1 creates for each repo under it.
# All of them are matched by the cwd of their panes rather than by label, since
# every one of those labels is a display name the user can change.
#
# "under" as well as "equal" is what picks up the repo rows (cwd = story\repo)
# and a pane the user cd'd somewhere deeper. Returns ids, story row first where
# it can tell - closing the shallowest last is not required, but it reads better
# in the plan.
function Get-StoryWorkspaceIds([string]$StoryDir) {
  $norm = (Resolve-Path -LiteralPath $StoryDir -ErrorAction SilentlyContinue)
  if ($norm) { $StoryDir = $norm.Path }
  $want = Get-PathKey $StoryDir
  $found = [System.Collections.Generic.List[string]]::new()
  if (-not $want) { return $found }
  foreach ($w in (Get-WorkspaceList)) {
    # A worktree workspace belongs to a repo checkout registered with herdr,
    # which is the legacy shape handled per repo further down.
    if ($null -eq $w -or $null -ne $w.worktree) { continue }
    $ws = "$($w.workspace_id)"
    $lines = Invoke-Native 'herdr' @('pane', 'list', '--workspace', $ws)
    if ($lines.Count -eq 0) { continue }
    $panes = $null
    try { $panes = (($lines -join "`n") | ConvertFrom-Json).result.panes } catch { continue }
    foreach ($p in @($panes)) {
      if ($null -eq $p) { continue }
      $have = Get-PathKey "$($p.cwd)"
      if ($have -eq $want -or $have.StartsWith("$want/")) {
        if (-not $found.Contains($ws)) { $found.Add($ws) | Out-Null }
        break
      }
    }
  }
  return $found
}

function Test-WorktreeDirty([string]$Wt) {
  $status = Invoke-Git $Wt @('status', '--porcelain')
  if ($script:NativeExit -ne 0) {
    # Cannot tell -> treat as dirty so WT_SKIP_DIRTY errs on the side of keeping.
    Write-Warning "could not read git status in $Wt; treating it as dirty"
    return $true
  }
  foreach ($line in $status) { if ("$line".Trim()) { return $true } }
  return $false
}

$HERDR_ROOT = Resolve-WorktreeRoot

# --- inputs ----------------------------------------------------------------
# An explicit arg or WT_ID always wins, so az-watcher and any other automation
# are unaffected. Only a human with nothing supplied gets the picker.
$ID = if ($args.Count -ge 1 -and $args[0]) { $args[0] } elseif ($env:WT_ID) { $env:WT_ID } else { '' }
if (-not $ID) {
  $ID = Select-StoryId
}
if (-not $ID) {
  Write-Error 'story id required'
  exit 1
}

$Candidates = [System.Collections.Generic.List[string]]::new()

function Add-Candidate([string]$D) {
  if (-not (Test-Path -LiteralPath $D -PathType Container)) { return }
  $full = (Resolve-Path -LiteralPath $D).Path
  if ($Candidates -contains $full) { return }
  $Candidates.Add($full) | Out-Null
}

function Add-Glob([string]$Base) {
  if (-not (Test-Path -LiteralPath $Base -PathType Container)) { return }
  Get-ChildItem -LiteralPath $Base -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "${ID}-*" -or $_.Name -like "${ID}_*" } |
    ForEach-Object { Add-Candidate $_.FullName }
}

Add-Glob (Join-Path $HERDR_ROOT 'development')
Add-Glob (Join-Path $HERDR_ROOT 'review')

if ($Candidates.Count -eq 0) {
  Write-Host "No story folder matching ${ID}-* under:"
  Write-Host "  $HERDR_ROOT\development|review"
  exit 3
}

# --- plan ------------------------------------------------------------------
$Plan = [System.Collections.Generic.List[string]]::new()
$WtDirs = [System.Collections.Generic.List[string]]::new()
$WtRepoNames = [System.Collections.Generic.List[string]]::new()
$WtBranches = [System.Collections.Generic.List[string]]::new()
$WtPrimaries = [System.Collections.Generic.List[string]]::new()
$WtWs = [System.Collections.Generic.List[string]]::new()
$WtStoryDirs = [System.Collections.Generic.List[string]]::new()
$WtSlugs = [System.Collections.Generic.List[string]]::new()
$Leftovers = [System.Collections.Generic.List[string]]::new()
# Story workspaces to close up front (parallel lists: story dir / workspace id).
$StoryWsDirs = [System.Collections.Generic.List[string]]::new()
$StoryWsIds = [System.Collections.Generic.List[string]]::new()
$DirtySkipped = 0
$Stuck = 0
$RemovedCount = 0

foreach ($storyDir in $Candidates) {
  $storyName = Split-Path -Leaf $storyDir
  $slug = Get-SlugFromStoryName $storyName $ID
  $Plan.Add("story ${storyName}:") | Out-Null
  # Worktrees this story has, versus the ones this run will take out. The story
  # workspace is only closed when those two agree - a WT_REPO-scoped removal, or
  # one held back by WT_SKIP_DIRTY, leaves the story (and its agents) alive.
  $wtTotal = 0
  $wtRemoving = 0

  foreach ($dirEnt in (Get-ChildItem -LiteralPath $storyDir -Directory -ErrorAction SilentlyContinue)) {
    $wt = $dirEnt.FullName
    $gitMarker = Join-Path $wt '.git'
    if (-not (Test-Path -LiteralPath $gitMarker)) {
      # Not a worktree. An EMPTY directory is the debris a half-finished removal
      # leaves behind (herdr unregisters the worktree, then cannot delete the
      # folder because a pane still holds it); collect it so the story can be
      # finished off. Anything with content in it is left strictly alone.
      if (-not $env:WT_REPO -or $dirEnt.Name -eq $env:WT_REPO) {
        if (@(Get-ChildItem -LiteralPath $wt -Force -ErrorAction SilentlyContinue).Count -eq 0) {
          $Leftovers.Add($wt) | Out-Null
          $Plan.Add("  leftover $wt (empty, not a worktree - will delete)") | Out-Null
        } else {
          $Plan.Add("  keep     $wt (not a worktree, and not empty)") | Out-Null
        }
      }
      continue
    }
    $repo = $dirEnt.Name
    $wtTotal++
    if ($env:WT_REPO -and $repo -ne $env:WT_REPO) {
      $Plan.Add("  keep     $wt (not $($env:WT_REPO))") | Out-Null
      continue
    }
    if ($env:WT_SKIP_DIRTY -eq '1' -and (Test-WorktreeDirty $wt)) {
      $Plan.Add("  KEEP     $wt (uncommitted/untracked changes)") | Out-Null
      $DirtySkipped++
      continue
    }
    $branch = ''
    foreach ($line in (Invoke-Git $wt @('rev-parse', '--abbrev-ref', 'HEAD'))) {
      $t = "$line".Trim()
      if ($t) { $branch = $t; break }
    }
    $primary = ''
    $porcelain = Invoke-Git $wt @('worktree', 'list', '--porcelain')
    foreach ($line in $porcelain) {
      if ($line -match '^worktree\s+(.+)$') {
        $primary = $Matches[1]
        break
      }
    }
    $ws = ''
    try { $ws = Get-WorkspaceIdForPath $wt } catch { $ws = '' }
    $wtRemoving++
    $WtDirs.Add($wt) | Out-Null
    $WtRepoNames.Add($repo) | Out-Null
    $WtBranches.Add($branch) | Out-Null
    $WtPrimaries.Add($primary) | Out-Null
    $WtWs.Add($(if ($ws) { $ws } else { '' })) | Out-Null
    $WtStoryDirs.Add($storyDir) | Out-Null
    $WtSlugs.Add($slug) | Out-Null
    $Plan.Add("  worktree $wt") | Out-Null
    $Plan.Add("    branch  $(if ($branch) { $branch } else { '<detached>' }) (in $(if ($primary) { $primary } else { '<unknown clone>' }))") | Out-Null
    $Plan.Add("    notes   $storyDir\${ID}-${slug}-${repo}.txt") | Out-Null
    if ($ws) { $Plan.Add("    herdr   remove worktree + workspace $ws") | Out-Null }
  }

  if ($wtRemoving -eq $wtTotal) {
    $swsIds = @()
    try { $swsIds = @(Get-StoryWorkspaceIds $storyDir) } catch { $swsIds = @() }
    foreach ($sws in $swsIds) {
      $StoryWsDirs.Add($storyDir) | Out-Null
      $StoryWsIds.Add($sws) | Out-Null
    }
    if ($swsIds.Count -gt 0) {
      $Plan.Add("  herdr    close $($swsIds.Count) story workspace(s): $($swsIds -join ', ')") | Out-Null
      $Plan.Add("           (the story row and its per-repo rows)") | Out-Null
    }
  } elseif ($wtTotal -gt 0) {
    $Plan.Add("  herdr    story workspaces left open ($($wtTotal - $wtRemoving) worktree(s) staying)") | Out-Null
  }

  if (-not $env:WT_REPO) {
    $typeDir = Split-Path -Parent $storyDir
    Get-ChildItem -LiteralPath $typeDir -Filter "${ID}-${slug}-*.txt" -File -ErrorAction SilentlyContinue |
      ForEach-Object { $Plan.Add("  notes    $($_.FullName)") | Out-Null }
  }
  $Plan.Add("  folder   $storyDir (only once no worktrees remain in it)") | Out-Null
}

if ($WtDirs.Count -eq 0 -and $Leftovers.Count -eq 0) {
  $Plan | ForEach-Object { Write-Host $_ }
  if ($DirtySkipped -gt 0) {
    Write-Host "Nothing removed for story ${ID}: $DirtySkipped worktree(s) have uncommitted changes."
    exit 5
  }
  $repoNote = if ($env:WT_REPO) { " (repo $($env:WT_REPO))" } else { '' }
  Write-Host "Nothing to remove for story ${ID}${repoNote}."
  exit 3
}

$repoOnly = if ($env:WT_REPO) { ", repo $($env:WT_REPO) only" } else { '' }
Write-Host "About to DELETE story id ${ID}${repoOnly} ($($Candidates.Count) folder(s)):"
$Plan | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host 'WARNING: this deletes the worktree directories themselves - including any'
Write-Host 'uncommitted changes and untracked files inside them - plus their local'
Write-Host 'branches, herdr workspaces, and notes files.'
Write-Host ''

if ($env:WT_ASSUME_YES -eq '1') {
  Write-Host 'WT_ASSUME_YES=1 - skipping confirmation'
} else {
  & gum confirm 'Delete all worktrees and files listed above? This cannot be undone.'
  if ($LASTEXITCODE -ne 0) {
    Write-Host 'aborted.'
    exit 0
  }
}

# --- execute ---------------------------------------------------------------
# Close a story's workspaces - the story row AND its per-repo rows - BEFORE
# touching any checkout. Their agents hold files inside the checkouts open, and
# a repo row is rooted in the checkout itself; pull it out from under a live
# pane and `git worktree remove` fails on locked files, leaving exactly the
# half-deleted debris this script then has to mop up.
for ($i = 0; $i -lt $StoryWsIds.Count; $i++) {
  $sws = $StoryWsIds[$i]
  $sname = Split-Path -Leaf $StoryWsDirs[$i]
  if (Test-Herdr @('workspace', 'close', $sws)) {
    Write-Host "-> closed herdr workspace $sws ($sname)"
  } else {
    Write-Warning "could not close herdr workspace $sws ($sname); carrying on"
  }
}
# Panes do not die the instant the workspace closes; give their handles a moment.
if ($StoryWsIds.Count -gt 0) { Start-Sleep -Milliseconds 500 }

# Empty non-worktree debris first, so the story folder can actually go away.
foreach ($leftover in $Leftovers) {
  $lws = ''
  try { $lws = Get-WorkspaceIdForPath $leftover } catch { $lws = '' }
  if ($lws) { Test-Herdr @('workspace', 'close', $lws) | Out-Null }
  if (Remove-DirRetry $leftover) {
    Write-Host "-> removed leftover directory $leftover"
  } else {
    Write-Warning "could not delete leftover directory $leftover"
    $Stuck++
  }
}

for ($i = 0; $i -lt $WtDirs.Count; $i++) {
  $wt = $WtDirs[$i]
  $repo = $WtRepoNames[$i]
  $branch = $WtBranches[$i]
  $primary = $WtPrimaries[$i]
  $ws = $WtWs[$i]
  $storyDir = $WtStoryDirs[$i]
  $slug = $WtSlugs[$i]

  if ($ws) {
    # Fails routinely (a pane still has the directory open) - that is what the
    # close-and-carry-on fallback is for, so it must not be able to throw.
    if (-not (Test-Herdr @('worktree', 'remove', '--workspace', $ws, '--force'))) {
      Write-Warning "herdr worktree remove failed for workspace $ws; closing it"
      Test-Herdr @('workspace', 'close', $ws) | Out-Null
    }
  }

  if (Test-Path -LiteralPath $wt) {
    if ($primary) {
      if (-not (Test-Git $primary @('worktree', 'remove', '--force', $wt))) {
        Write-Warning "git worktree remove failed for $wt; forcing Remove-Item"
        Remove-DirRetry $wt | Out-Null
      }
    } else {
      Write-Warning "no primary clone for $wt; removing dir only"
      Remove-DirRetry $wt | Out-Null
    }
  }
  # git may report success yet leave the directory behind if a file was locked.
  if (Test-Path -LiteralPath $wt) { Remove-DirRetry $wt | Out-Null }

  # Report honestly if the directory survived all of that, rather than going on
  # to delete the branch and the notes as though the worktree were gone.
  if (Test-Path -LiteralPath $wt) {
    Write-Warning ("could not delete $wt (something still has it open - a pane, " +
      'an editor, or a running agent). Close it and re-run; leaving the branch ' +
      'and notes in place.')
    $Stuck++
    continue
  }

  if ($primary) {
    Test-Git $primary @('worktree', 'prune') | Out-Null
    $protected = Get-ProtectedBranches $primary
    if ($branch -and $branch -ne 'HEAD' -and -not $protected.Contains($branch)) {
      if (-not (Test-Git $primary @('branch', '-D', $branch))) {
        Write-Warning "could not delete branch $branch in $primary (it will be reused by a future story of the same name, and worktree-make will fast-forward it)"
      }
    } else {
      Write-Host "  skip: not deleting branch '$(if ($branch) { $branch } else { '<detached>' })' (empty/detached/protected)"
    }
  }

  Remove-Item -LiteralPath (Join-Path $storyDir "${ID}-${slug}-${repo}.txt") -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $storyDir ".notespath-$repo") -Force -ErrorAction SilentlyContinue
  $RemovedCount++
}

function Test-StoryHasWorktrees([string]$StoryDir) {
  foreach ($d in (Get-ChildItem -LiteralPath $StoryDir -Directory -ErrorAction SilentlyContinue)) {
    if (Test-Path -LiteralPath (Join-Path $d.FullName '.git')) { return $true }
  }
  return $false
}

foreach ($storyDir in $Candidates) {
  $storyName = Split-Path -Leaf $storyDir
  $slug = Get-SlugFromStoryName $storyName $ID
  $typeDir = Split-Path -Parent $storyDir
  if (Test-StoryHasWorktrees $storyDir) {
    Write-Host "-> keeping $storyDir (worktrees still present)"
    continue
  }
  Get-ChildItem -LiteralPath $typeDir -Filter "${ID}-${slug}-*.txt" -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
  if ($storyName -like "${ID}-*" -or $storyName -like "${ID}_*") {
    # Retry: the story workspace was closed moments ago and its panes may still
    # be letting go of the folder they were rooted in.
    if (Remove-DirRetry $storyDir) {
      Write-Host "-> removed folder $storyDir"
    } else {
      Write-Warning "could not delete story folder $storyDir (something still has it open)"
      $Stuck++
    }
  }
}

$repoNote = if ($env:WT_REPO) { " (repo $($env:WT_REPO))" } else { '' }
$leftNote = if ($Leftovers.Count -gt 0) { " (plus $($Leftovers.Count) empty leftover dir(s))" } else { '' }
if ($DirtySkipped -gt 0) {
  Write-Host "OK removed $RemovedCount worktree(s) for story ${ID}${leftNote}; kept $DirtySkipped with uncommitted changes."
} else {
  Write-Host "OK removed $RemovedCount worktree(s) for story ${ID}${repoNote}${leftNote}."
}
# A worktree that could not be deleted must not report success: the story is
# still half there, and a later worktree-make would trip over it.
if ($Stuck -gt 0) {
  Write-Host "-> $Stuck worktree(s) could not be deleted - see the warnings above"
  exit 1
}
# Explicit: without this, $LASTEXITCODE still holds the status of the last native
# command run above (e.g. a benign `git branch -D` that could not delete a
# branch), and az-watcher reads that as "worktree-remove failed".
exit 0
