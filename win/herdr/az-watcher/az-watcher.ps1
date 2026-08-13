# az-watcher.ps1
# Headless driver that keeps local herdr story worktrees in sync with Azure
# DevOps pull requests. Ports wsl/herdr/az-watcher/az-watcher.sh to PowerShell.
#
# Subcommands: new-review | remove-merged | run (default)
# Options: --window N, --dry-run, --force-dirty, --me <identity>, -h/--help
#
$ErrorActionPreference = 'Stop'

# ===========================================================================
# EDIT THESE FOR YOUR MACHINE
# ===========================================================================
$SRC_ROOT = Join-Path $env:USERPROFILE 'source\repos'
$MAKE_WORKTREE = Join-Path $env:USERPROFILE 'bin\make-worktree.ps1'
$REMOVE_WORKTREE = Join-Path $env:USERPROFILE 'bin\worktree-remove.ps1'
$SLUG_WORDS = 4
$PR_TOP = 50
$WINDOW_DEFAULT = 5
$LockDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'az-watcher' } else { $env:TEMP }
$LOCK_FILE = Join-Path $LockDir 'az-watcher.lock'

# Optional env overrides: AZDO_ORG / AZDO_PROJECT / AZ_WATCHER_ME

function Get-Timestamp {
  Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
}

function Write-Log([string]$Msg) {
  Write-Host "$(Get-Timestamp) $Msg"
}

function Show-Usage {
  @"
usage: az-watcher [new-review|remove-merged|run] [options]

  new-review      create review worktrees for PRs assigned to me
  remove-merged   remove local worktrees for PRs of mine that closed
  run             both (default)

options:
  --window N      only act on PRs created/closed in the last N minutes
                  (default 5). N=0 disables the time filter.
  --dry-run       print the intended actions; create and remove nothing
  --force-dirty   allow removal of worktrees with uncommitted changes
  --me <identity> Azure identity to match (default: az account show)
  -h, --help      this text
"@
}

# ===========================================================================
# Single-instance lock (.NET exclusive FileStream; replaces flock)
# ===========================================================================
New-Item -ItemType Directory -Force -Path $LockDir | Out-Null
$script:LockStream = $null
try {
  $script:LockStream = [System.IO.File]::Open(
    $LOCK_FILE,
    [System.IO.FileMode]::OpenOrCreate,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None
  )
} catch {
  Write-Log 'another az-watcher run is in progress; exiting'
  exit 0
}

try {
# ===========================================================================
# CLI
# ===========================================================================
$Action = ''
$Window = $WINDOW_DEFAULT
$DryRun = $false
$ForceDirty = $false
$Me = if ($env:AZ_WATCHER_ME) { $env:AZ_WATCHER_ME } else { '' }

$i = 0
while ($i -lt $args.Count) {
  $a = $args[$i]
  switch -Regex ($a) {
    '^(new-review|remove-merged|run)$' { $Action = $a; $i++; continue }
    '^--window$' {
      $i++; $Window = $args[$i]; $i++; continue
    }
    '^--window=(.+)$' { $Window = $Matches[1]; $i++; continue }
    '^--me$' { $i++; $Me = $args[$i]; $i++; continue }
    '^--me=(.+)$' { $Me = $Matches[1]; $i++; continue }
    '^--dry-run$' { $DryRun = $true; $i++; continue }
    '^--force-dirty$' { $ForceDirty = $true; $i++; continue }
    '^(-h|--help)$' { Show-Usage; exit 0 }
    default {
      Write-Error "unknown argument: $a"
      Show-Usage
      exit 1
    }
  }
}
if (-not $Action) { $Action = 'run' }
if ($Window -notmatch '^\d+$') {
  Write-Error '--window takes a non-negative integer'
  exit 1
}
$Window = [int]$Window

function Need-Cmd([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Write-Error "missing tool: $Name"
    exit 1
  }
}
Need-Cmd az
Need-Cmd git
Need-Cmd jq

$AzDevopsArgs = @()
if ($env:AZDO_ORG) { $AzDevopsArgs += @('--org', $env:AZDO_ORG) }
if ($env:AZDO_PROJECT) { $AzDevopsArgs += @('--project', $env:AZDO_PROJECT) }

function Invoke-AzCli {
  # Pass az argv as a single string[] so flags like -o are not bound as PS params.
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $prev = $env:PYTHONIOENCODING
  $env:PYTHONIOENCODING = 'utf-8'
  $prevUtf8 = $env:PYTHONUTF8
  $env:PYTHONUTF8 = '1'
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $all = @($Arguments) + $AzDevopsArgs
    $out = & az @all 2>&1
    $rc = $LASTEXITCODE
    # NativeCommandError records from az warnings must not abort the run.
    $lines = @(
      $out | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" }
      }
    )
    # Drop az encoding warnings; keep JSON / TSV payload.
    $payload = ($lines | Where-Object {
      $_ -and ($_ -notmatch '^WARNING:') -and ($_ -notmatch '^Unable to encode')
    }) -join "`n"
    $payload = $payload -replace "`r", ''
    if ($rc -ne 0) {
      $errPreview = (($payload -split "`n") | Select-Object -First 3) -join ' '
      Write-Log "ERROR: az $($Arguments -join ' ') failed (exit ${rc}): $errPreview"
    }
    return @{ ExitCode = $rc; Output = $payload.TrimEnd() }
  } finally {
    $ErrorActionPreference = $prevEap
    if ($null -eq $prev) { Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue }
    else { $env:PYTHONIOENCODING = $prev }
    if ($null -eq $prevUtf8) { Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue }
    else { $env:PYTHONUTF8 = $prevUtf8 }
  }
}

function Invoke-Jq {
  param(
    [Parameter(Mandatory = $true)][string]$InputText,
    [Parameter(Mandatory = $true)][string[]]$JqArgs
  )
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if (-not $InputText) { return '' }
    $result = $InputText | & jq @JqArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return ($result | Out-String).TrimEnd()
  } finally {
    $ErrorActionPreference = $prevEap
  }
}

function Resolve-Me {
  $r = Invoke-AzCli -Arguments @('account', 'show', '--query', 'user.name', '-o', 'tsv')
  if ($r.ExitCode -ne 0) { return '' }
  return (($r.Output -split "`n")[0]).Trim()
}

function Test-InWindow([string]$Iso) {
  if ($Window -eq 0) { return $true }
  if (-not $Iso) { return $false }
  try {
    $t = [DateTimeOffset]::Parse($Iso).ToUnixTimeSeconds()
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return (($now - $t) -le ($Window * 60))
  } catch {
    return $false
  }
}

function Get-PrList([string]$Role, [string]$Status, [string]$Field) {
  $r = Invoke-AzCli -Arguments @('repos', 'pr', 'list', "--$Role", $Me, '--status', $Status, '--top', "$PR_TOP", '-o', 'json')
  if ($r.ExitCode -ne 0) { return $null }
  $json = $r.Output.Trim()
  if ($json -notmatch '^\s*[\[{]') {
    Write-Log "note: ${Role}/${Status} returned non-JSON (len=$($json.Length)); treating as empty"
    return '[]'
  }
  $n = Invoke-Jq -InputText $json -JqArgs @('-r', 'length')
  if ($n -eq "$PR_TOP") {
    $oldest = Invoke-Jq -InputText $json -JqArgs @('-r', '--arg', 'f', $Field, '[.[] | .[$f] // empty] | last // empty')
    if (Test-InWindow $oldest) {
      Write-Log "note: ${Role}/${Status} returned a full ${PR_TOP}-PR page and its oldest entry is still inside the ${Window}m window - older PRs were not examined; raise PR_TOP"
    }
  }
  return $json
}

function Convert-PrsToRows([string]$Json, [string]$Field) {
  if (-not $Json) { return @() }
  $tsv = Invoke-Jq -InputText $Json -JqArgs @(
    '-r', '--arg', 'f', $Field,
    '.[]? | [ (.pullRequestId|tostring), .repository.name, .sourceRefName, (.[$f] // ""), (.createdBy.uniqueName // "") ] | @tsv'
  )
  $rows = @()
  foreach ($line in ($tsv -split "`n")) {
    $line = $line.TrimEnd("`r").TrimEnd()
    if (-not $line) { continue }
    # Do not Trim() fully - trailing empty @tsv fields are significant tabs.
    $parts = $line -split "`t", 5
    while ($parts.Count -lt 5) { $parts += '' }
    if (-not $parts[0]) { continue }
    $rows += [pscustomobject]@{
      Pr = $parts[0]; Repo = $parts[1]; SrcRef = $parts[2]
      Date = $parts[3]; By = $parts[4]
    }
  }
  return $rows
}

function Sanitize-Slug([string]$S) {
  $s = $S.ToLowerInvariant()
  $s = [regex]::Replace($s, '[^a-z0-9]+', '-')
  $s = $s.Trim('-')
  return $s
}

function Get-SlugForStory([string]$Id) {
  $r = Invoke-AzCli -Arguments @('boards', 'work-item', 'show', '--id', $Id, '--query', 'fields."System.Title"', '-o', 'tsv')
  if ($r.ExitCode -ne 0) { return $null }
  $title = (($r.Output -split "`n")[0]).Trim()
  if (-not $title) { return $null }
  $s = Sanitize-Slug $title
  $parts = $s -split '-' | Where-Object { $_ } | Select-Object -First $SLUG_WORDS
  $s = $parts -join '-'
  if (-not $s) { return $null }
  return $s
}

function Get-StoryForPr([string]$Pr, [string]$Branch) {
  $seg = Split-Path -Leaf ($Branch -replace '/', '\')
  # Prefer last path segment with regex on original branch
  $seg = ($Branch -split '/')[-1]
  if ($seg -match '^([0-9]+)-(.+)$') {
    return @{ Id = $Matches[1]; Slug = (Sanitize-Slug $Matches[2]) }
  }
  $r = Invoke-AzCli -Arguments @('repos', 'pr', 'work-item', 'list', '--id', $Pr, '-o', 'json')
  if ($r.ExitCode -ne 0) { return $null }
  $id = Invoke-Jq -InputText $r.Output -JqArgs @('-r', '.[0].id // empty')
  if (-not $id) { return $null }
  $slug = Get-SlugForStory $id
  if (-not $slug) { return $null }
  return @{ Id = "$id"; Slug = $slug }
}

function Get-LocalRepoDir([string]$AzureName) {
  $AzureName -replace ' ', '_'
}

function Send-Notify([string]$Title, [string]$Body = '') {
  Write-Log "NOTIFY ${Title}$(if ($Body) { " | $Body" } else { '' })"
  if ($DryRun) { return }
  $nArgs = @('notification', 'show', $Title, '--sound', 'done')
  if ($Body) { $nArgs += @('--body', $Body) }
  & herdr @nArgs 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Log '  (notification not delivered - no herdr session)'
  }
}

function Test-HerdrUp {
  & herdr workspace list 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Invoke-NewReview {
  $dryNote = if ($DryRun) { ' [dry-run]' } else { '' }
  Write-Log "new-review: window=${Window}m me=${Me}${dryNote}"
  if (-not $DryRun -and -not (Test-HerdrUp)) {
    Write-Log 'no herdr session is running - worktree creation needs one; skipping new-review'
    Send-Notify 'az-watcher: no herdr session' 'Start herdr, then re-run az-watcher new-review.'
    return
  }

  $json = Get-PrList reviewer active creationDate
  if ($null -eq $json) { return }
  $rows = Convert-PrsToRows $json creationDate
  $seen = 0
  $created = 0

  foreach ($row in $rows) {
    if (-not $row.Pr) { continue }
    if ($row.By.ToLowerInvariant() -eq $Me.ToLowerInvariant()) {
      Write-Log "PR $($row.Pr) ($($row.Repo)): mine, not a review; skipping"
      continue
    }
    if (-not (Test-InWindow $row.Date)) {
      Write-Log "PR $($row.Pr) ($($row.Repo)): created $($row.Date), outside the ${Window}m window"
      continue
    }
    $seen++
    $branch = $row.SrcRef -replace '^refs/heads/', ''
    $repoDir = Get-LocalRepoDir $row.Repo
    $story = Get-StoryForPr $row.Pr $branch
    if (-not $story) {
      Write-Log "PR $($row.Pr) ($($row.Repo)): no story id in branch '$branch' and no linked work item"
      Send-Notify "Review not created: PR $($row.Pr)" `
        "$($row.Repo) - $branch - no work item id. Create the worktree by hand if you want one."
      continue
    }
    $id = $story.Id
    $slug = $story.Slug

    if ($DryRun) {
      Write-Log "DRY-RUN would create review worktree ${id}-${slug} for ${repoDir} @ ${branch} (PR $($row.Pr))"
      continue
    }

    $cloneGit = Join-Path $SRC_ROOT "$repoDir\.git"
    if (-not (Test-Path -LiteralPath $cloneGit)) {
      Write-Log "PR $($row.Pr): no local clone at $(Join-Path $SRC_ROOT $repoDir)"
      Send-Notify "Review not created: PR $($row.Pr)" `
        "No local clone $repoDir under $SRC_ROOT (Azure repo '$($row.Repo)')."
      continue
    }

    $tmp = [IO.Path]::GetTempFileName()
    Set-Content -LiteralPath $tmp -Value "${repoDir}:${branch}" -NoNewline
    Write-Log "PR $($row.Pr): creating review worktree ${id}-${slug} for ${repoDir} @ ${branch}"
    $env:WT_ID = $id
    $env:WT_SLUG = $slug
    $env:WT_BRANCHES_FILE = $tmp
    $rc = 0
    try {
      & $MAKE_WORKTREE review
      $rc = $LASTEXITCODE
    } catch {
      $rc = 1
    } finally {
      Remove-Item Env:WT_ID, Env:WT_SLUG, Env:WT_BRANCHES_FILE -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    switch ($rc) {
      0 {
        $created++
        Send-Notify "Review ready: ${id}-${slug}" "PR $($row.Pr) - $($row.Repo) - $branch"
      }
      3 { Write-Log "PR $($row.Pr): worktree for ${id}-${slug}/${repoDir} already exists - nothing to do" }
      default {
        Send-Notify "Review FAILED: ${id}-${slug}" `
          "PR $($row.Pr) - $($row.Repo) - $branch - make-worktree.ps1 exited $rc. See the az-watcher log."
      }
    }
  }
  Write-Log "new-review: $seen PR(s) in window, $created worktree(s) created"
}

function Get-ClosedPrRows {
  $all = @()
  foreach ($role in @('creator', 'reviewer')) {
    foreach ($status in @('completed', 'abandoned')) {
      $json = Get-PrList $role $status closedDate
      if ($null -eq $json) { continue }
      $all += Convert-PrsToRows $json closedDate
    }
  }
  # Dedupe by PR id, newest first (assume list order is newest-first within each query)
  $seen = @{}
  $deduped = @()
  foreach ($row in ($all | Sort-Object { [int]$_.Pr } -Descending)) {
    if ($seen.ContainsKey($row.Pr)) { continue }
    $seen[$row.Pr] = $true
    $deduped += $row
  }
  return $deduped
}

function Invoke-RemoveMerged {
  $dryNote = if ($DryRun) { ' [dry-run]' } else { '' }
  Write-Log "remove-merged: window=${Window}m me=${Me}${dryNote}"
  $seen = 0
  $removed = 0
  $skipDirty = if ($ForceDirty) { '0' } else { '1' }

  foreach ($row in (Get-ClosedPrRows)) {
    if (-not $row.Pr) { continue }
    if (-not (Test-InWindow $row.Date)) { continue }
    $seen++
    $branch = $row.SrcRef -replace '^refs/heads/', ''
    $repoDir = Get-LocalRepoDir $row.Repo
    $story = Get-StoryForPr $row.Pr $branch
    if (-not $story) {
      Write-Log "PR $($row.Pr) ($($row.Repo)): closed but no story id in branch '$branch' and no linked work item"
      Send-Notify "Cleanup skipped: PR $($row.Pr)" `
        "$($row.Repo) - $branch - no work item id, so no story folder to match. Remove it by hand if it has one."
      continue
    }
    $id = $story.Id

    if ($DryRun) {
      Write-Log "DRY-RUN would remove story $id repo $repoDir (PR $($row.Pr), closed $($row.Date))"
      Write-Log "         WT_ID=$id WT_REPO=$repoDir WT_ASSUME_YES=1 WT_SKIP_DIRTY=$skipDirty $REMOVE_WORKTREE"
      continue
    }

    Write-Log "PR $($row.Pr): removing story $id repo $repoDir (closed $($row.Date))"
    $env:WT_ID = $id
    $env:WT_REPO = $repoDir
    $env:WT_ASSUME_YES = '1'
    $env:WT_SKIP_DIRTY = $skipDirty
    $rc = 0
    try {
      & $REMOVE_WORKTREE
      $rc = $LASTEXITCODE
    } catch {
      $rc = 1
    } finally {
      Remove-Item Env:WT_ID, Env:WT_REPO, Env:WT_ASSUME_YES, Env:WT_SKIP_DIRTY -ErrorAction SilentlyContinue
    }
    switch ($rc) {
      0 {
        $removed++
        Send-Notify "Story cleaned up: $id" "$($row.Repo) worktree, branch and notes removed (PR $($row.Pr))"
      }
      3 { Write-Log "PR $($row.Pr): nothing local for story ${id}/${repoDir} - already gone" }
      5 {
        Send-Notify "Cleanup held back: $id" `
          "$repoDir has uncommitted changes. Commit/discard, then re-run or use --force-dirty."
      }
      default {
        Send-Notify "Cleanup FAILED: $id" `
          "$repoDir (PR $($row.Pr)) - worktree-remove.ps1 exited $rc. See the az-watcher log."
      }
    }
  }
  Write-Log "remove-merged: $seen closed PR(s) in window, $removed story removal(s)"
}

# ===========================================================================
# main
# ===========================================================================
if (-not (Test-Path -LiteralPath $MAKE_WORKTREE)) {
  Write-Error "missing $MAKE_WORKTREE (run win/herdr/install.ps1)"
  exit 1
}
if (-not (Test-Path -LiteralPath $REMOVE_WORKTREE)) {
  Write-Error "missing $REMOVE_WORKTREE (run win/herdr/install.ps1)"
  exit 1
}

if (-not $Me) { $Me = Resolve-Me }
if (-not $Me) {
  Write-Log "cannot determine the signed-in Azure identity - run 'az login' (or pass --me)"
  Send-Notify 'az-watcher: not signed in' "Run 'az login', then re-run az-watcher."
  exit 1
}

switch ($Action) {
  'new-review' { Invoke-NewReview }
  'remove-merged' { Invoke-RemoveMerged }
  'run' { Invoke-NewReview; Invoke-RemoveMerged }
}

} finally {
  if ($script:LockStream) {
    $script:LockStream.Close()
    $script:LockStream.Dispose()
  }
}
