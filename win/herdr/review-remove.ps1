# review-remove.ps1
# Clean up local code reviews whose pull requests have finished.
#
# usage: review-remove.ps1 [<work-item-id>] [options]
#          no id          examine every review under the review root
#          <id>           examine only that one
#
#        --dry-run             print what would go, remove nothing
#        --yes                 skip the confirmation (also WT_ASSUME_YES=1)
#        --include-abandoned   treat an abandoned PR as finished too
#        --force-dirty         remove a checkout that has uncommitted changes
#        --discard-notes       delete notes instead of archiving them
#        -h, --help
#
# WHY THIS EXISTS SEPARATELY FROM worktree-remove.ps1:
#   worktree-remove.ps1 takes a story id from a human and deletes it, branches
#   and all. This is the opposite: it is meant to run on a SCHEDULE with no one
#   watching, so it decides for itself what is safe to delete, and the bar it has
#   to clear is "the PR is finished, nothing here is unsaved". It is the cleanup
#   half of review-make.ps1 and the step before that cleanup runs automatically.
#
# THE RULE: A REVIEW GOES ONLY WHEN THE WHOLE REVIEW IS DONE
#   A work item can carry several PRs, in several repos. The item's folder and its
#   sidebar rows are removed only when EVERY one of those PRs has completed. One
#   PR still active holds the whole review in place, because a half-removed review
#   is worse than one that is late: the rows that survive no longer say what they
#   are missing.
#
#   A PR whose status cannot be read is NOT treated as finished. An expired
#   token, a network blip or a renamed repo must never be the reason a review
#   disappears, so anything short of a definite "completed" keeps it.
#
# WHAT IT WILL NOT DO
#   * touch Azure DevOps. Every az call goes through Invoke-AzRead, which refuses
#     anything not on $AZ_READ_ONLY. It reads PR status; it never votes, comments,
#     or changes a work item. This script cannot approve a review for you.
#   * delete work you typed. A checkout with uncommitted changes holds its review
#     back (exit 5) unless --force-dirty. Notes files with anything in them are
#     MOVED to <review root>\_notes\ rather than deleted - see Save-Notes.
#   * half-remove anything. A workspace of yours parked in the review folder also
#     holds the review back, because its pane keeps the directory open and the
#     delete would fail only after the rows were closed and the worktree
#     deregistered.
#   * close the "Review" root row. Every review shares it, and a scheduled job
#     yanking the workspace you are sitting in is not acceptable. It stays even
#     when the last review under it goes.
#   * delete a branch. Review checkouts are detached (review-make.ps1 uses
#     `git worktree add --detach`), so there is no branch to delete and no way
#     this can remove someone's work by name.
#
# Exit codes:
#   0  at least one review was removed
#   1  bad usage / a removal failed
#   3  nothing to do - no review had all of its PRs finished
#   5  a review was held back because a checkout has uncommitted changes
#
$ErrorActionPreference = 'Stop'

# ===========================================================================
# EDIT THESE FOR YOUR MACHINE
# ===========================================================================
# Only used as a fallback: the clone a worktree belongs to is normally read out
# of the worktree's own .git file, which cannot be wrong.
$SRC_ROOT = if ($env:WT_REVIEW_SRC_ROOT) { $env:WT_REVIEW_SRC_ROOT } else {
  Join-Path $env:USERPROFILE 'source\repos'
}

# Statuses that mean "this PR is finished". 'abandoned' is added by
# --include-abandoned: an abandoned PR is dead code, but deleting the review of
# one is a judgement call, so it is opt-in.
$DONE_STATUS = @('completed')

# Where a notes file with anything in it goes instead of the bin.
$NOTES_ARCHIVE = '_notes'

# Tree connectors, matching review-make.ps1 - they are reported as each row's
# $tree sidebar token, and removing a review means the survivors' connectors have
# to be re-reported so the corner lands on the new last one. $TREE_GAP leads with
# U+2800 rather than a space because herdr trims leading whitespace off a token
# value. Built from char codes because Windows PowerShell 5.1 reads a .ps1 as ANSI
# unless it has a BOM, which would mangle them on the way in.
$TREE_TEE = -join @([char]0x251C, [char]0x2500)
$TREE_ELL = -join @([char]0x2514, [char]0x2500)
$TREE_PIPE = -join @([char]0x2502, '  ')
$TREE_GAP = -join @([char]0x2800, '  ')
$TREE_INDENT = -join @([char]0x2800, ' ')
# Stripped off the front of a label to recover the bare name a row is known by.
$TREE_CHARS = -join @([char]0x251C, [char]0x2514, [char]0x2502, [char]0x2500, [char]0x2800, ' ')

# ===========================================================================
$script:Removed = 0
$script:Held = 0
$script:Failed = 0
$script:Examined = 0

$Only = ''
$DryRun = $false
$AssumeYes = ($env:WT_ASSUME_YES -eq '1')
$IncludeAbandoned = $false
$ForceDirty = ($env:WT_FORCE_DIRTY -eq '1')
$DiscardNotes = $false

function Show-Usage {
  @'
usage: review-remove.ps1 [<work-item-id>] [options]

  no id                 examine every review under the review root
  <work-item-id>        examine only that review

options:
  --dry-run             print the intended actions; remove nothing
  --yes                 do not ask for confirmation (for scheduled runs)
  --include-abandoned   treat an abandoned PR as finished as well as completed
  --force-dirty         remove a checkout even if it has uncommitted changes
  --discard-notes       delete notes files instead of archiving them
  -h, --help            this text

A review is removed only when EVERY pull request on its work item has finished.
Azure DevOps is read, never written.
'@
}

$i = 0
while ($i -lt $args.Count) {
  $a = "$($args[$i])"
  switch -Regex ($a) {
    '^\d+$' { $Only = $a; $i++; continue }
    '^--dry-run$' { $DryRun = $true; $i++; continue }
    '^--yes$' { $AssumeYes = $true; $i++; continue }
    '^--include-abandoned$' { $IncludeAbandoned = $true; $i++; continue }
    '^--force-dirty$' { $ForceDirty = $true; $i++; continue }
    '^--discard-notes$' { $DiscardNotes = $true; $i++; continue }
    '^(-h|--help)$' { Show-Usage; exit 0 }
    default {
      Write-Error "unknown argument: $a"
      Show-Usage
      exit 1
    }
  }
}
if ($IncludeAbandoned) { $DONE_STATUS += 'abandoned' }

function Need-Cmd([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Write-Error "missing tool: $Name"
    exit 1
  }
}

$AZ_CMD = if ($env:WT_REVIEW_AZ) { $env:WT_REVIEW_AZ } else { 'az' }

Need-Cmd herdr
Need-Cmd git
if (-not $env:WT_REVIEW_AZ) { Need-Cmd az }

# ---------------------------------------------------------------------------
# Azure DevOps: read only, enforced. Same guard as review-make.ps1 - the check is
# on the leading non-flag words, which is exactly az's command path, so it cannot
# be slipped past with flag ordering.
# ---------------------------------------------------------------------------
$AZ_READ_ONLY = @(
  'account show'
  'boards work-item show'
  'devops configure'
  'devops invoke'
  'repos pr show'
  'repos pr list'
  'repos pr work-item list'
)

function Get-AzCommandPath([string[]]$Arguments) {
  $words = @()
  foreach ($a in $Arguments) {
    if ("$a".StartsWith('-')) { break }
    $words += "$a"
  }
  return ($words -join ' ')
}

function Test-AzReadOnly([string[]]$Arguments) {
  $path = Get-AzCommandPath $Arguments
  if ($AZ_READ_ONLY -notcontains $path) { return $false }
  if ($path -eq 'devops invoke') {
    for ($j = 0; $j -lt $Arguments.Count; $j++) {
      $a = "$($Arguments[$j])"
      if ($a -match '^--(in-file|body)') { return $false }
      if ($a -eq '--http-method') {
        $v = if ($j + 1 -lt $Arguments.Count) { "$($Arguments[$j + 1])" } else { '' }
        if ($v.ToUpperInvariant() -ne 'GET') { return $false }
      }
      if ($a -match '^--http-method=(.+)$') {
        if ($Matches[1].ToUpperInvariant() -ne 'GET') { return $false }
      }
    }
  }
  return $true
}

$script:AzExit = 0

function Invoke-AzRead([string[]]$Arguments) {
  if (-not (Test-AzReadOnly $Arguments)) {
    throw ("refusing to run a non-read-only az command: az $($Arguments -join ' '). " +
      'review-remove.ps1 only ever reads from Azure DevOps.')
  }
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $prevIo = $env:PYTHONIOENCODING
  $prevUtf8 = $env:PYTHONUTF8
  $env:PYTHONIOENCODING = 'utf-8'
  $env:PYTHONUTF8 = '1'
  try {
    $out = & $AZ_CMD @Arguments 2>$null | Out-String
    $script:AzExit = $LASTEXITCODE
    return $out
  } catch {
    $script:AzExit = 1
    return ''
  } finally {
    $ErrorActionPreference = $prevEap
    if ($null -eq $prevIo) { Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue }
    else { $env:PYTHONIOENCODING = $prevIo }
    if ($null -eq $prevUtf8) { Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue }
    else { $env:PYTHONUTF8 = $prevUtf8 }
  }
}

function Invoke-AzJson([string[]]$Arguments) {
  $out = Invoke-AzRead $Arguments
  if ($script:AzExit -ne 0 -or -not $out) { return $null }
  try { return ($out | ConvertFrom-Json) } catch { return $null }
}

# ---------------------------------------------------------------------------
# git / herdr plumbing (never throws; judged on exit codes)
# ---------------------------------------------------------------------------
$script:GitExit = 0

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

function Git-Run([string]$Repo, [string[]]$GitArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & git -C $Repo @GitArgs 2>&1 | ForEach-Object { Write-Host "   $_" }
    $script:GitExit = $LASTEXITCODE
    return ($script:GitExit -eq 0)
  } finally { $ErrorActionPreference = $prev }
}

function Invoke-HerdrJson([string[]]$HerdrArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = (& herdr @HerdrArgs 2>$null | Out-String)
    if (-not $out) { return $null }
    return ($out | ConvertFrom-Json)
  } catch { return $null } finally { $ErrorActionPreference = $prev }
}

function Invoke-HerdrQuiet([string[]]$HerdrArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & herdr @HerdrArgs 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $prev }
}

function Get-PathKey([string]$Path) {
  if (-not $Path) { return '' }
  return ($Path -replace '\\+', '/').TrimEnd('/').ToLowerInvariant()
}

function Get-HerdrConfigPath {
  if ($env:HERDR_CONFIG_PATH) { return $env:HERDR_CONFIG_PATH }
  return (Join-Path $env:APPDATA 'herdr\config.toml')
}

function Set-TreeToken([string]$Ws, [string]$Value) {
  if (-not $Ws) { return }
  if ($Value) {
    Invoke-HerdrQuiet @('workspace', 'report-metadata', $Ws, '--source', 'review-make', '--token', "tree=$Value")
  } else {
    Invoke-HerdrQuiet @('workspace', 'report-metadata', $Ws, '--source', 'review-make', '--clear-token', 'tree')
  }
}

function Resolve-WorktreeRoot {
  $cfg = Get-HerdrConfigPath
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
# Workspace index (plain workspaces only; worktree workspaces are not ours)
# ---------------------------------------------------------------------------
$script:WsIndex = $null

function Get-WsIndex {
  param([switch]$Refresh)
  if ($null -ne $script:WsIndex -and -not $Refresh) { return $script:WsIndex }
  $rows = @()
  $json = Invoke-HerdrJson @('workspace', 'list')
  if ($null -ne $json) {
    foreach ($w in @($json.result.workspaces)) {
      if ($null -eq $w -or $null -ne $w.worktree) { continue }
      $ws = "$($w.workspace_id)"
      $cwd = ''
      $panes = Invoke-HerdrJson @('pane', 'list', '--workspace', $ws)
      if ($null -ne $panes) {
        foreach ($p in @($panes.result.panes)) {
          if ($null -eq $p) { continue }
          if ("$($p.cwd)") { $cwd = "$($p.cwd)"; break }
        }
      }
      $num = 0
      if ($null -ne $w.number) { $num = [int]$w.number }
      $rows += [pscustomobject]@{
        Id = $ws; Label = "$($w.label)"; Number = $num
        Cwd = $cwd; Key = (Get-PathKey $cwd)
      }
    }
  }
  $script:WsIndex = @($rows)
  return $script:WsIndex
}

function Get-BareLabel([string]$Label) {
  if (-not $Label) { return '' }
  return $Label.TrimStart($TREE_CHARS.ToCharArray())
}

# Split the rows sitting in a review's folder into this review's own and everyone
# else's. Returns a hashtable so a single-element result cannot be unrolled away.
#
# cwd alone is not a safe test for ownership. A pane belonging to the shared
# "Review" row that the user had cd'd down into the review folder sits at exactly
# the path the review's own row does - so a cwd-only match would close the Review
# root, which this script promises never to do, on a scheduled run with nobody
# watching. The row's name has to match the review or one of its PR folders too.
function Get-RowsUnder([string]$Dir, [string[]]$Names) {
  $result = @{ Ours = @(); Foreign = @() }
  $want = Get-PathKey $Dir
  if (-not $want) { return $result }
  $ours = @()
  $foreign = @()
  foreach ($w in (Get-WsIndex)) {
    if (-not $w.Key) { continue }
    if (-not ($w.Key -eq $want -or $w.Key.StartsWith("$want/"))) { continue }
    if ($Names -contains (Get-BareLabel $w.Label)) { $ours += $w } else { $foreign += $w }
  }
  $result.Ours = @($ours)
  $result.Foreign = @($foreign)
  return $result
}

# ---------------------------------------------------------------------------
# Working out what a review is made of
# ---------------------------------------------------------------------------

# The clone a worktree belongs to, read out of the worktree's own .git file:
#     gitdir: C:/Users/me/source/repos/My_Repo/.git/worktrees/alice-repo
# Preferred over any recorded path because it is what git itself will use, so
# `git worktree remove` is guaranteed to be pointed at the right repository.
function Get-WorktreeOwner([string]$WorktreePath) {
  $dotGit = Join-Path $WorktreePath '.git'
  if (-not (Test-Path -LiteralPath $dotGit -PathType Leaf)) { return '' }
  $line = "$(Get-Content -LiteralPath $dotGit -Raw -ErrorAction SilentlyContinue)".Trim()
  if ($line -notmatch '^gitdir:\s*(.+)$') { return '' }
  $gitDir = $Matches[1].Trim()
  # .../<clone>/.git/worktrees/<name>  ->  <clone>
  $idx = $gitDir.Replace('/', '\').ToLowerInvariant().IndexOf('\.git\worktrees\')
  if ($idx -lt 1) { return '' }
  return $gitDir.Replace('/', '\').Substring(0, $idx)
}

function Sanitize-Segment([string]$Value) {
  if (-not $Value) { return '' }
  $s = [regex]::Replace($Value, '[^A-Za-z0-9._-]+', '-')
  return $s.Trim('-.')
}

function Get-AuthorName($Identity) {
  $u = "$($Identity.uniqueName)"
  if (-not $u) { $u = "$($Identity.displayName)" }
  if (-not $u) { return '' }
  $u = ($u -split '@')[0]
  return (Sanitize-Segment $u).ToLowerInvariant()
}

function Get-LocalRepoDir([string]$AzureName) {
  return (Sanitize-Segment ($AzureName -replace ' ', '_'))
}

function Get-LinkedPrIds($WorkItem) {
  $ids = @()
  foreach ($rel in @($WorkItem.relations)) {
    if ($null -eq $rel) { continue }
    $url = "$($rel.url)"
    if ($url -notmatch '^vstfs:///Git/PullRequestId/') { continue }
    $tail = $url -replace '^vstfs:///Git/PullRequestId/', ''
    $parts = ($tail -replace '%2f', '/' -replace '%2F', '/') -split '/'
    $pr = "$($parts[-1])".Trim()
    if ($pr -match '^\d+$' -and $ids -notcontains $pr) { $ids += $pr }
  }
  return $ids
}

# folder -> PR id for one review. The sidecar review-make.ps1 leaves behind is
# authoritative; re-deriving from the work item is the fallback for a review made
# before the sidecar existed, or one whose sidecar was deleted.
function Get-ReviewPrs([string]$Id, [string]$ItemDir) {
  $sidecar = Join-Path $ItemDir "review-$Id-prs.json"
  if (Test-Path -LiteralPath $sidecar) {
    try {
      $obj = (Get-Content -LiteralPath $sidecar -Raw) | ConvertFrom-Json
      $out = @()
      foreach ($e in @($obj.prs)) {
        if ($null -eq $e -or -not "$($e.prId)") { continue }
        $out += [pscustomobject]@{
          PrId = "$($e.prId)"; Folder = "$($e.folder)"; RepoDir = "$($e.repoDir)"
          AzRepo = "$($e.azRepo)"; From = 'index'
        }
      }
      if ($out.Count -gt 0) { return $out }
    } catch {
      Write-Warning "could not read $sidecar - falling back to Azure DevOps: $_"
    }
  }
  $wi = Invoke-AzJson @('boards', 'work-item', 'show', '--id', $Id, '--expand', 'relations', '-o', 'json')
  if ($null -eq $wi) { return $null }
  $out = @()
  $used = @{}
  foreach ($prId in @(Get-LinkedPrIds $wi)) {
    $pr = Invoke-AzJson @('repos', 'pr', 'show', '--id', $prId, '-o', 'json')
    if ($null -eq $pr) { return $null }
    $repoDir = Get-LocalRepoDir "$($pr.repository.name)"
    $author = Get-AuthorName $pr.createdBy
    if (-not $author) { $author = 'unknown' }
    $folder = "$author-$repoDir"
    if ($used.ContainsKey($folder)) { $folder = "$folder-pr$prId" }
    $used[$folder] = $true
    $out += [pscustomobject]@{
      PrId = "$prId"; Folder = $folder; RepoDir = $repoDir
      AzRepo = "$($pr.repository.name)"; From = 'azure'
    }
  }
  return $out
}

# 'done' / 'open' / 'unknown'. 'unknown' is deliberately NOT done: a status this
# script could not read must never be the reason a review is deleted.
function Get-PrDisposition([string]$PrId) {
  $pr = Invoke-AzJson @('repos', 'pr', 'show', '--id', $PrId, '-o', 'json')
  if ($null -eq $pr) {
    return [pscustomobject]@{ State = 'unknown'; Status = "unreadable (az exit $script:AzExit)" }
  }
  $status = "$($pr.status)".ToLowerInvariant()
  if (-not $status) {
    return [pscustomobject]@{ State = 'unknown'; Status = 'no status in the response' }
  }
  $state = if ($DONE_STATUS -contains $status) { 'done' } else { 'open' }
  return [pscustomobject]@{ State = $state; Status = $status }
}

# ---------------------------------------------------------------------------
# Removal
# ---------------------------------------------------------------------------

# A directory herdr had a pane in does not always release immediately.
function Remove-DirRetry([string]$Path) {
  for ($attempt = 1; $attempt -le 4; $attempt++) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    Start-Sleep -Milliseconds (200 * $attempt)
  }
  return (-not (Test-Path -LiteralPath $Path))
}

# Notes are the one thing here a human wrote. An empty file is noise and goes
# with the rest; anything with content is moved out to the archive, because a
# scheduled job silently deleting your review notes is not a trade worth making.
function Save-Notes([string]$Id, [string]$ItemDir, [string]$ReviewRoot) {
  $kept = @()
  $notes = @(Get-ChildItem -LiteralPath $ItemDir -Filter '*-notes.txt' -File -ErrorAction SilentlyContinue)
  foreach ($n in $notes) {
    if ($n.Length -eq 0) { continue }
    if ($DiscardNotes) {
      Write-Host "   discarding notes (--discard-notes): $($n.Name)"
      continue
    }
    $archive = Join-Path $ReviewRoot $NOTES_ARCHIVE
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $archive | Out-Null }
    $dest = Join-Path $archive $n.Name
    # Never overwrite an archived copy from an earlier review of the same id.
    if (Test-Path -LiteralPath $dest) {
      $stamp = 2
      while (Test-Path -LiteralPath $dest) {
        $dest = Join-Path $archive ("$([IO.Path]::GetFileNameWithoutExtension($n.Name))-$stamp.txt")
        $stamp++
      }
    }
    if ($DryRun) {
      Write-Host "   would archive notes: $($n.Name) -> $dest"
    } else {
      Move-Item -LiteralPath $n.FullName -Destination $dest -Force
      Write-Host "   archived notes: $dest"
    }
    $kept += $dest
  }
  return $kept
}

# Re-report the connectors of whatever reviews are left, so the corner lands on
# the new last one instead of on a row that has just been closed.
function Update-TreeTokens([string]$ReviewRoot) {
  $rootKey = Get-PathKey $ReviewRoot
  $rows = @()
  foreach ($w in (Get-WsIndex -Refresh)) {
    if (-not $w.Key -or $w.Key -eq $rootKey) { continue }
    if (-not $w.Key.StartsWith("$rootKey/")) { continue }
    $segs = @($w.Key.Substring($rootKey.Length + 1) -split '/' | Where-Object { $_ })
    if ($segs.Count -lt 1 -or $segs[0] -notmatch '^\d+$') { continue }
    $rows += [pscustomobject]@{ Ws = $w; Depth = $segs.Count; Item = $segs[0] }
  }
  if ($rows.Count -eq 0) { return }
  $itemRows = @($rows | Where-Object { $_.Depth -eq 1 } | Sort-Object { $_.Ws.Number })
  for ($k = 0; $k -lt $itemRows.Count; $k++) {
    $isLast = ($k -eq $itemRows.Count - 1)
    $connector = if ($isLast) { $TREE_ELL } else { $TREE_TEE }
    Set-TreeToken $itemRows[$k].Ws.Id ($TREE_INDENT + $connector)
    $prRows = @($rows |
      Where-Object { $_.Depth -eq 2 -and $_.Item -eq $itemRows[$k].Item } |
      Sort-Object { $_.Ws.Number })
    $lead = if ($isLast) { $TREE_GAP } else { $TREE_PIPE }
    for ($m = 0; $m -lt $prRows.Count; $m++) {
      $tail = if ($m -eq $prRows.Count - 1) { $TREE_ELL } else { $TREE_TEE }
      Set-TreeToken $prRows[$m].Ws.Id ($TREE_INDENT + $lead + $tail)
    }
  }
}

function Remove-Review($Plan, [string]$ReviewRoot) {
  Write-Host ''
  Write-Host "== removing review $($Plan.Id): $($Plan.Reason)"

  # Close the rows FIRST: a pane sitting in the directory keeps a handle on it,
  # and the delete then fails for a reason that has nothing to do with git.
  foreach ($row in $Plan.Rows) {
    if ($DryRun) {
      Write-Host "   would close herdr row $($row.Id) [$($row.Label)]"
    } else {
      Invoke-HerdrQuiet @('workspace', 'close', $row.Id)
      Write-Host "   closed herdr row $($row.Id) [$($row.Label)]"
    }
  }
  if (-not $DryRun -and $Plan.Rows.Count -gt 0) { Start-Sleep -Milliseconds 500 }

  $ok = $true
  foreach ($wt in $Plan.Worktrees) {
    if ($DryRun) {
      Write-Host "   would remove worktree $($wt.Path) (owner $($wt.Owner))"
      continue
    }
    $removeArgs = @('worktree', 'remove')
    if ($ForceDirty) { $removeArgs += '--force' }
    $removeArgs += $wt.Path
    if (Git-Run $wt.Owner $removeArgs) {
      Write-Host "   removed worktree $($wt.Path)"
    } else {
      # The registration is what matters; a directory git will not let go of is
      # dealt with by the recursive delete below, then pruned.
      Write-Warning "git worktree remove failed for $($wt.Path) (exit $script:GitExit) - deleting the directory and pruning"
      $ok = (Remove-DirRetry $wt.Path) -and $ok
    }
    Git-Out $wt.Owner @('worktree', 'prune') | Out-Null
  }

  Save-Notes $Plan.Id $Plan.Dir $ReviewRoot | Out-Null

  if ($DryRun) {
    Write-Host "   would delete $($Plan.Dir)"
    $script:Removed++
    return
  }
  if (Remove-DirRetry $Plan.Dir) {
    Write-Host "   deleted $($Plan.Dir)"
  } else {
    Write-Warning "could not delete $($Plan.Dir) - something still holds it open"
    $ok = $false
  }
  if ($ok) { $script:Removed++ } else { $script:Failed++ }
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
$WORKTREE_ROOT = Resolve-WorktreeRoot
$REVIEW_ROOT = Join-Path $WORKTREE_ROOT 'review'
Write-Host "-> review root: $REVIEW_ROOT"
if ($DryRun) { Write-Host '-> DRY RUN: nothing will be removed' }
Write-Host "-> finished means: $($DONE_STATUS -join ' or ')"

if (-not (Test-Path -LiteralPath $REVIEW_ROOT)) {
  Write-Host '-> no review root on disk - nothing to do'
  exit 3
}

$itemDirs = @()
if ($Only) {
  $d = Join-Path $REVIEW_ROOT $Only
  if (-not (Test-Path -LiteralPath $d)) {
    Write-Host "-> no local review for work item $Only ($d)"
    exit 3
  }
  $itemDirs = @((Get-Item -LiteralPath $d))
} else {
  # Only numeric directories are reviews. This skips the notes archive and the
  # repo-centric folders an older worktree-make.ps1 left directly under review\.
  $itemDirs = @(Get-ChildItem -LiteralPath $REVIEW_ROOT -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d+$' } | Sort-Object Name)
}
if ($itemDirs.Count -eq 0) {
  Write-Host '-> no reviews on disk - nothing to do'
  exit 3
}

$plans = @()
foreach ($dir in $itemDirs) {
  $id = $dir.Name
  $script:Examined++
  Write-Host ''
  Write-Host "-- work item $id"
  # @() around the call, not just the null test: PowerShell unwraps a
  # single-element array on return, so a one-PR review arrived here as a lone
  # PSCustomObject whose .Count is $null - every "N PR(s)" message printed blank,
  # and "all N finished" read as "all  finished". The null test stays on the raw
  # value because @($null) is a one-element array holding $null, which would then
  # look like one unreadable PR.
  $prsRaw = Get-ReviewPrs $id $dir.FullName
  $prs = @()
  if ($null -ne $prsRaw) { $prs = @($prsRaw | Where-Object { $null -ne $_ }) }
  if ($prs.Count -eq 0) {
    Write-Host '   cannot tell which PRs this review covers - leaving it alone'
    continue
  }
  Write-Host "   $($prs.Count) PR(s), from $(@($prs | ForEach-Object { $_.From } | Select-Object -Unique) -join '/')"

  $allDone = $true
  $doneList = @()
  foreach ($pr in $prs) {
    $d = Get-PrDisposition $pr.PrId
    Write-Host "   PR $($pr.PrId) ($($pr.AzRepo)): $($d.Status)"
    if ($d.State -ne 'done') { $allDone = $false } else { $doneList += $pr.PrId }
  }
  if (-not $allDone) {
    Write-Host "   holding: $($doneList.Count)/$($prs.Count) finished - a review goes only when all of them have"
    continue
  }

  # Everything on the item is finished. Now: is anything here unsaved?
  $worktrees = @()
  $dirty = @()
  foreach ($pr in $prs) {
    $path = Join-Path $dir.FullName $pr.Folder
    if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { continue }
    $changes = @(Git-Out $path @('status', '--porcelain') | Where-Object { $_ })
    if ($changes.Count -gt 0) { $dirty += "$($pr.Folder) ($($changes.Count) change(s))" }
    $owner = Get-WorktreeOwner $path
    if (-not $owner) {
      $owner = Join-Path $SRC_ROOT $pr.RepoDir
      Write-Warning "could not read the owning clone from $path\.git - falling back to $owner"
    }
    $worktrees += [pscustomobject]@{ Path = $path; Owner = $owner; Folder = $pr.Folder }
  }
  if ($dirty.Count -gt 0 -and -not $ForceDirty) {
    Write-Host "   HELD BACK: uncommitted changes in $($dirty -join ', ')"
    Write-Host '   commit or discard them, or re-run with --force-dirty'
    $script:Held++
    continue
  }
  if ($dirty.Count -gt 0) {
    Write-Warning "--force-dirty: discarding uncommitted changes in $($dirty -join ', ')"
  }

  # The names this review's rows are allowed to have: the work item id, and one
  # per PR folder. Anything else sitting at these paths belongs to someone else.
  $rowNames = @($id) + @($prs | ForEach-Object { $_.Folder })
  $rows = Get-RowsUnder $dir.FullName $rowNames

  # A workspace of yours parked in this folder is a hard stop, not a warning.
  # Its pane holds an open handle on the directory, so the delete fails - and it
  # fails AFTER the rows have been closed and the worktree deregistered, leaving
  # exactly the half-removed review this script refuses to produce elsewhere.
  # Held back instead: nothing is touched, and the message says what to do.
  if ($rows.Foreign.Count -gt 0) {
    $names = @($rows.Foreign | ForEach-Object { "$($_.Id) [$($_.Label)]" }) -join ', '
    Write-Host "   HELD BACK: another workspace is parked in this folder: $names"
    Write-Host '   close it (or cd it somewhere else), then re-run'
    $script:Held++
    continue
  }

  $plans += [pscustomobject]@{
    Id = $id
    Dir = $dir.FullName
    Worktrees = @($worktrees)
    Rows = @($rows.Ours)
    Reason = "all $($prs.Count) PR(s) finished"
  }
}

if ($plans.Count -eq 0) {
  Write-Host ''
  Write-Host "-> examined $($script:Examined) review(s); none are ready to remove"
  if ($script:Held -gt 0) { exit 5 }
  exit 3
}

Write-Host ''
Write-Host 'Ready to remove:'
foreach ($p in $plans) {
  Write-Host "  $($p.Id)  $($p.Reason)"
  foreach ($wt in $p.Worktrees) { Write-Host "    worktree  $($wt.Folder)" }
  foreach ($row in $p.Rows) { Write-Host "    herdr row $($row.Id) [$($row.Label)]" }
}
Write-Host '  (the shared "Review" row is left open)'

if (-not $DryRun -and -not $AssumeYes) {
  if (Get-Command gum -ErrorAction SilentlyContinue) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $confirmed = $false
    try {
      & gum confirm "Remove $($plans.Count) finished review(s)?"
      $confirmed = ($LASTEXITCODE -eq 0)
    } catch { $confirmed = $false } finally { $ErrorActionPreference = $prev }
    if (-not $confirmed) {
      Write-Host '-> cancelled'
      exit 3
    }
  } else {
    # No way to ask, so do not guess. A scheduled run passes --yes.
    Write-Error 'gum is not installed, so there is no way to confirm. Re-run with --yes (or --dry-run first).'
    exit 1
  }
}

foreach ($p in $plans) {
  try {
    Remove-Review $p $REVIEW_ROOT
  } catch {
    $script:Failed++
    Write-Warning "failed to remove review $($p.Id): $_"
  }
}

if (-not $DryRun) {
  try {
    Update-TreeTokens $REVIEW_ROOT
  } catch {
    Write-Warning "the reviews were removed, but redrawing the remaining tree failed: $_"
  }
}

Write-Host ''
Write-Host "OK examined $($script:Examined), removed $($script:Removed), held back $($script:Held), failed $($script:Failed)"
Write-Host '   nothing was written to Azure DevOps'

if ($script:Failed -gt 0) { exit 1 }
if ($script:Held -gt 0 -and $script:Removed -eq 0) { exit 5 }
if ($script:Removed -eq 0) { exit 3 }
exit 0
