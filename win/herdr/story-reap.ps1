# story-reap.ps1
# Remove development story worktrees whose Azure DevOps pull requests have all closed.
#
# usage: story-reap.ps1 [options]
#
#        --dry-run             print what would go, remove nothing
#        --yes                 skip the confirmation (for scheduled runs)
#        --story <id>          examine only that story
#        --completed-only      abandoned no longer counts as closed
#        --force-dirty         reap a story even with uncommitted changes
#        --force-unpushed      reap a story even with commits Azure never saw
#        -h, --help
#
# THE RULE: AT LEAST ONE PR, AND EVERY ONE OF THEM CLOSED
#   A story is reaped only when it has >= 1 associated pull request AND every one
#   of them is closed. Both halves matter, and the first is the one that is easy
#   to get wrong: a story with NO pull requests looks identical to a fully closed
#   one if you only test "nothing is open". That is a brand-new story someone
#   started ten minutes ago, and deleting it is the worst thing this script could
#   do. No PRs found => left alone, always.
#
#   A PR whose status cannot be read is NOT closed. An expired token, a network
#   blip or a renamed repo must never be the reason a story disappears, so
#   anything short of a definite closed status keeps the story.
#
# WHERE "ASSOCIATED PRs" COME FROM - TWO SOURCES, UNIONED
#   1. The work item's own links (`boards work-item show --expand relations`).
#      Catches PRs in repos that are not checked out under the story.
#   2. Per checked-out repo, the PRs for that repo's branch
#      (`repos pr list --source-branch`). Catches PRs nobody linked to the work
#      item, which is the common case - linking is a manual step people skip.
#
#   Neither source alone is complete, and a PR missed by both halves of the union
#   is a PR that cannot hold the story back. So they are unioned, and any single
#   open PR from either source keeps the story. If the work item itself cannot be
#   read the story is held back rather than judged on source 2 alone: an unreadable
#   work item means the PR list is unknown, not empty.
#
# WHAT IT WILL NOT DO
#   * touch Azure DevOps. Every az call goes through Invoke-AzRead, which refuses
#     anything not on $AZ_READ_ONLY. It reads PR and work item status; it never
#     votes, comments, completes a PR or changes a work item.
#   * delete work Azure never saw. A checkout with uncommitted changes holds its
#     story back, and so does one carrying commits that are not contained in what
#     its PR last showed - a squash merge leaves the local branch looking ahead of
#     origin forever, so the test is against the PR's own source commit rather
#     than a naive origin/<branch> comparison. See Test-CheckoutSafe.
#   * reap review worktrees on its own. It walks development\ only. A story that
#     also has a review\{id}-{slug} copy is called out in the plan, because
#     worktree-remove.ps1 removes by id and will take both.
#   * decide anything twice. A lock file means an overlapping cron tick exits
#     immediately instead of racing the run already in progress.
#
# CRON / TASK SCHEDULER
#   Built to be run unattended on a timer, which is why it logs with timestamps,
#   holds a single-instance lock, and needs no terminal once --yes is passed:
#
#     story-reap.ps1 --dry-run          # always start here
#     story-reap.ps1 --yes              # unattended
#
#   Until you trust it, leave --yes off: it prints the plan and asks. Removal
#   itself is delegated to worktree-remove.ps1 (WT_ASSUME_YES=1), so the rules
#   about closing herdr rows before deleting checkouts stay in one place.
#
# Exit codes:
#   0  at least one story was reaped
#   1  bad usage / a removal failed
#   3  nothing to do - no story had all of its PRs closed
#   5  a story was held back (uncommitted or unpushed work, unreadable status)
#
$ErrorActionPreference = 'Stop'

# ===========================================================================
# EDIT THESE FOR YOUR MACHINE
# ===========================================================================
$REMOVE_WORKTREE = if ($env:WT_REMOVE_SCRIPT) { $env:WT_REMOVE_SCRIPT } else {
  Join-Path $env:USERPROFILE 'bin\worktree-remove.ps1'
}

# Statuses that mean "this PR is closed". Azure DevOps also has 'notSet', which is
# deliberately absent: it is not a closed PR.
$CLOSED_STATUS = @('completed', 'abandoned')

# Cap on a single per-branch PR query. A branch has one or two PRs in practice;
# this is only here so a pathological branch cannot pull down a huge page.
$PR_TOP = 50

$LockDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'story-reap' } else { $env:TEMP }
$LOCK_FILE = Join-Path $LockDir 'story-reap.lock'

# ===========================================================================
# CLI
# ===========================================================================
$DryRun = $false
$AssumeYes = ($env:WT_ASSUME_YES -eq '1')
$Only = ''
$ForceDirty = ($env:WT_FORCE_DIRTY -eq '1')
$ForceUnpushed = $false

function Show-Usage {
  @'
usage: story-reap.ps1 [options]

  --dry-run             print the intended actions; remove nothing
  --yes                 do not ask for confirmation (for scheduled runs)
  --story <id>          examine only that story
  --completed-only      treat only completed PRs as closed (not abandoned)
  --force-dirty         reap a story even if a checkout has uncommitted changes
  --force-unpushed      reap a story even if a checkout has commits Azure
                        DevOps never saw
  -h, --help            this text

A story is reaped only when it has at least one pull request AND every one of
them is closed. A story with no pull requests is always left alone.
Azure DevOps is read, never written.
'@
}

$i = 0
while ($i -lt $args.Count) {
  $a = "$($args[$i])"
  switch -Regex ($a) {
    '^--dry-run$' { $DryRun = $true; $i++; continue }
    '^--yes$' { $AssumeYes = $true; $i++; continue }
    '^--story$' {
      $i++
      $Only = if ($i -lt $args.Count) { "$($args[$i])" } else { '' }
      $i++
      continue
    }
    '^--story=(.+)$' { $Only = $Matches[1]; $i++; continue }
    '^--completed-only$' { $CLOSED_STATUS = @('completed'); $i++; continue }
    '^--force-dirty$' { $ForceDirty = $true; $i++; continue }
    '^--force-unpushed$' { $ForceUnpushed = $true; $i++; continue }
    '^(-h|--help)$' { Show-Usage; exit 0 }
    default {
      Write-Error "unknown argument: $a"
      Show-Usage
      exit 1
    }
  }
}
if ($Only -and $Only -notmatch '^\d+$') {
  Write-Error "--story takes a numeric work item id, got '$Only'"
  exit 1
}

function Get-Timestamp { Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz' }

# Timestamped because the point of this script is to end up in a cron log where
# "when" is the first question anyone asks.
function Write-Log([string]$Msg) { Write-Host "$(Get-Timestamp) $Msg" }

function Need-Cmd([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Write-Error "missing tool: $Name"
    exit 1
  }
}

$AZ_CMD = if ($env:WT_REVIEW_AZ) { $env:WT_REVIEW_AZ } else { 'az' }

Need-Cmd git
if (-not $env:WT_REVIEW_AZ) { Need-Cmd az }
if (-not (Test-Path -LiteralPath $REMOVE_WORKTREE)) {
  Write-Error "missing $REMOVE_WORKTREE (run win\herdr\install.ps1)"
  exit 1
}

$script:Examined = 0
$script:Reaped = 0
$script:Held = 0
$script:Failed = 0
$script:Skipped = 0

# ===========================================================================
# Single-instance lock (.NET exclusive FileStream; same approach as az-watcher)
#
# A 10-minute timer plus a run that takes longer than 10 minutes - entirely
# possible, every PR query is a network round trip - would otherwise have two
# copies deciding the fate of the same story folder at once.
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
  Write-Log 'another story-reap run is in progress; exiting'
  exit 0
}

try {

# ===========================================================================
# Azure DevOps: read only, enforced.
#
# Same guard as review-make.ps1 / review-remove.ps1. The check is on the leading
# non-flag words, which is exactly az's command path, so flag ordering cannot slip
# a write past it.
# ===========================================================================
$AZ_READ_ONLY = @(
  'account show'
  'boards work-item show'
  'devops configure'
  'repos pr list'
  'repos pr show'
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
  return ($AZ_READ_ONLY -contains (Get-AzCommandPath $Arguments))
}

$script:AzExit = 0

function Invoke-AzRead([string[]]$Arguments) {
  if (-not (Test-AzReadOnly $Arguments)) {
    throw ("refusing to run a non-read-only az command: az $($Arguments -join ' '). " +
      'story-reap.ps1 only ever reads from Azure DevOps.')
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

# For az commands that return a LIST. "empty" and "failed" have to be told apart,
# and $null cannot do it: ConvertFrom-Json on '[]' emits nothing, and a Windows
# PowerShell function returning an empty array hands back $null - so a branch with
# no pull requests at all would be indistinguishable from a query that errored.
# Read as "no PRs found", that is harmless; read as "unreadable", it would hold
# every freshly created story back forever. The exit code is the only reliable
# signal, so Ok is carried separately from Items.
function Get-AzJsonArray([string[]]$Arguments) {
  $out = Invoke-AzRead $Arguments
  if ($script:AzExit -ne 0) { return @{ Ok = $false; Items = @() } }
  $text = "$out".Trim()
  if (-not $text) { return @{ Ok = $true; Items = @() } }
  $obj = $null
  try { $obj = $text | ConvertFrom-Json } catch { return @{ Ok = $false; Items = @() } }
  if ($null -eq $obj) { return @{ Ok = $true; Items = @() } }
  return @{ Ok = $true; Items = @($obj) }
}

# ---------------------------------------------------------------------------
# git plumbing (never throws; judged on exit codes)
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
  } catch {
    $script:GitExit = 1
    return @()
  } finally { $ErrorActionPreference = $prev }
}

function Git-Line([string]$Repo, [string[]]$GitArgs) {
  foreach ($line in (Git-Out $Repo $GitArgs)) {
    $t = "$line".Trim()
    if ($t) { return $t }
  }
  return ''
}

function Test-GitOk([string]$Repo, [string[]]$GitArgs) {
  Git-Out $Repo $GitArgs | Out-Null
  return ($script:GitExit -eq 0)
}

# ---------------------------------------------------------------------------
# Working out what a story is made of
# ---------------------------------------------------------------------------
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

# The Azure repo name for a checkout, read out of its own origin URL. Preferred
# over the directory name because worktree-make.ps1 turns spaces into underscores
# ("My Repo" -> My_Repo) and that is not reversible: a repo genuinely
# named with an underscore and one named with a space produce the same folder.
# The remote URL carries the real name, so --repository cannot be given a name
# Azure will not recognise.
function Get-AzRepoName([string]$Wt) {
  $url = Git-Line $Wt @('remote', 'get-url', 'origin')
  if (-not $url) { return '' }
  $url = $url -replace '\.git$', ''
  $name = ''
  # https://dev.azure.com/{org}/{project}/_git/{repo}
  if ($url -match '/_git/([^/]+)/?$') {
    $name = $Matches[1]
  } elseif ($url -match '^git@ssh\.dev\.azure\.com:v3/[^/]+/[^/]+/(.+)$') {
    # git@ssh.dev.azure.com:v3/{org}/{project}/{repo}
    $name = $Matches[1]
  } elseif ($url -match '/([^/]+)/?$') {
    $name = $Matches[1]
  }
  if (-not $name) { return '' }
  try { $name = [System.Uri]::UnescapeDataString($name) } catch { }
  return $name.Trim()
}

# Every repo checkout inside a story folder: path, Azure repo name, branch.
function Get-StoryCheckouts([string]$StoryDir) {
  $out = @()
  foreach ($d in (Get-ChildItem -LiteralPath $StoryDir -Directory -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path -LiteralPath (Join-Path $d.FullName '.git'))) { continue }
    $out += [pscustomobject]@{
      Path = $d.FullName
      Dir = $d.Name
      AzRepo = (Get-AzRepoName $d.FullName)
      Branch = (Git-Line $d.FullName @('rev-parse', '--abbrev-ref', 'HEAD'))
    }
  }
  return $out
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

function New-PrRecord($Pr, [string]$Source) {
  $status = "$($Pr.status)".ToLowerInvariant()
  return [pscustomobject]@{
    PrId = "$($Pr.pullRequestId)"
    Status = $status
    Closed = ($CLOSED_STATUS -contains $status)
    AzRepo = "$($Pr.repository.name)"
    Branch = ("$($Pr.sourceRefName)" -replace '^refs/heads/', '')
    SrcCommit = "$($Pr.lastMergeSourceCommit.commitId)"
    Source = $Source
  }
}

# Every PR associated with a story, from both sources, deduped by PR id.
#
# Returns a hashtable: Prs (records) / Unreadable (why the list is incomplete).
# Unreadable being non-empty means "this list may be missing a PR", which the
# caller must treat as "do not reap" - not as "nothing found".
function Get-StoryPrs([string]$Id, $Checkouts) {
  $prs = [ordered]@{}
  $unreadable = @()

  # Source 1: the work item's links.
  $wi = Invoke-AzJson @('boards', 'work-item', 'show', '--id', $Id, '--expand', 'relations', '-o', 'json')
  if ($null -eq $wi) {
    $unreadable += "work item $Id could not be read (az exit $script:AzExit)"
  } else {
    foreach ($prId in @(Get-LinkedPrIds $wi)) {
      $pr = Invoke-AzJson @('repos', 'pr', 'show', '--id', $prId, '-o', 'json')
      if ($null -eq $pr) {
        $unreadable += "PR $prId (linked to the work item) could not be read"
        continue
      }
      $prs[$prId] = (New-PrRecord $pr 'work-item')
    }
  }

  # Source 2: the PRs on each checked-out branch.
  foreach ($co in $Checkouts) {
    # A detached checkout (what review-make.ps1 produces) has no branch to have
    # PRs for and no local branch that could be lost, so it is not a gap in the
    # list - source 1 covers it. Saying "unreadable" here would hold every story
    # with a review copy back forever.
    if (-not $co.Branch -or $co.Branch -eq 'HEAD') { continue }
    if (-not $co.AzRepo) {
      $unreadable += "$($co.Dir): origin repo name could not be read, so its PRs are unknown"
      continue
    }
    $list = Get-AzJsonArray @(
      'repos', 'pr', 'list', '--repository', $co.AzRepo,
      '--source-branch', $co.Branch, '--status', 'all', '--top', "$PR_TOP", '-o', 'json'
    )
    if (-not $list.Ok) {
      $unreadable += "$($co.Dir): PRs for branch '$($co.Branch)' could not be listed"
      continue
    }
    foreach ($pr in @($list.Items)) {
      if ($null -eq $pr -or -not "$($pr.pullRequestId)") { continue }
      $key = "$($pr.pullRequestId)"
      # A branch query carries lastMergeSourceCommit, which the unpushed test
      # wants, so let it replace a bare work-item hit for the same PR.
      $prs[$key] = (New-PrRecord $pr 'branch')
    }
  }

  return @{ Prs = @($prs.Values); Unreadable = @($unreadable) }
}

# ---------------------------------------------------------------------------
# Is there local work Azure DevOps never saw?
#
# worktree-remove.ps1 deletes the checkout AND the local branch, so this is the
# last line of defence for anything not on the server. Returns '' when the
# checkout is safe to delete, or a human reason why it is not.
#
# The naive test - compare HEAD against origin/<branch> - is wrong here in both
# directions:
#   * After a SQUASH merge (the Azure DevOps default on many projects) the local
#     branch's commits are not ancestors of anything on origin, and the source
#     branch is usually deleted on completion, so origin/<branch> is gone as well.
#     A story that finished perfectly then looks like it has unpushed work
#     forever, and would never be reaped.
#   * A branch that was force-pushed over can look identical to one that is
#     behind.
# So the question asked instead is "is everything in this checkout contained in
# what its PR last showed Azure" - the PR's lastMergeSourceCommit. That is the
# high-water mark of what the server saw on this branch, whatever the merge
# strategy did afterwards.
# ---------------------------------------------------------------------------
function Test-CheckoutSafe($Checkout, $Prs) {
  $wt = $Checkout.Path

  $changes = @(Git-Out $wt @('status', '--porcelain') | Where-Object { "$_".Trim() })
  if ($script:GitExit -ne 0) {
    return "could not read git status in $($Checkout.Dir)"
  }
  if ($changes.Count -gt 0 -and -not $ForceDirty) {
    return "$($Checkout.Dir) has $($changes.Count) uncommitted change(s)"
  }

  if ($ForceUnpushed) { return '' }

  # Detached: there is no branch, so worktree-remove.ps1 deletes none, and nothing
  # here can be lost by name. The dirty test above is the whole check.
  if (-not $Checkout.Branch -or $Checkout.Branch -eq 'HEAD') { return '' }

  $head = Git-Line $wt @('rev-parse', 'HEAD')
  if (-not $head) { return "could not resolve HEAD in $($Checkout.Dir)" }

  # The PRs for this checkout's own branch, newest first.
  $mine = @($Prs | Where-Object {
    $_.Branch -and $Checkout.Branch -and $_.Branch -eq $Checkout.Branch
  } | Sort-Object { [int]$_.PrId } -Descending)

  foreach ($pr in $mine) {
    if (-not $pr.SrcCommit) { continue }
    # HEAD contained in what the PR last showed => nothing local is at risk.
    if ($head -eq $pr.SrcCommit) { return '' }
    if (Test-GitOk $wt @('merge-base', '--is-ancestor', $head, $pr.SrcCommit)) { return '' }
  }

  # No PR vouched for HEAD. Fall back to the remote-tracking branch: if origin
  # still has this branch and it contains HEAD, the work is on the server.
  $originRef = "refs/remotes/origin/$($Checkout.Branch)"
  if ($Checkout.Branch -and (Test-GitOk $wt @('rev-parse', '--verify', '--quiet', $originRef))) {
    if (Test-GitOk $wt @('merge-base', '--is-ancestor', $head, $originRef)) { return '' }
    return "$($Checkout.Dir) has commits on '$($Checkout.Branch)' that are not on origin"
  }

  if ($mine.Count -eq 0) {
    return "$($Checkout.Dir) has no PR for branch '$($Checkout.Branch)' and no origin/$($Checkout.Branch) to vouch for it"
  }
  return "$($Checkout.Dir) has commits its PR never saw on '$($Checkout.Branch)'"
}

function Send-Notify([string]$Title, [string]$Body = '') {
  Write-Log "NOTIFY ${Title}$(if ($Body) { " | $Body" } else { '' })"
  if ($DryRun) { return }
  if (-not (Get-Command herdr -ErrorAction SilentlyContinue)) { return }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $nArgs = @('notification', 'show', $Title, '--sound', 'done')
    if ($Body) { $nArgs += @('--body', $Body) }
    & herdr @nArgs 2>$null | Out-Null
  } catch { } finally { $ErrorActionPreference = $prev }
}

# ===========================================================================
# main
# ===========================================================================
$WORKTREE_ROOT = Resolve-WorktreeRoot
$DEV_ROOT = Join-Path $WORKTREE_ROOT 'development'
$REVIEW_ROOT = Join-Path $WORKTREE_ROOT 'review'

Write-Log "story-reap: development root $DEV_ROOT"
Write-Log "closed means: $($CLOSED_STATUS -join ' or ')"
if ($DryRun) { Write-Log 'DRY RUN: nothing will be removed' }

if (-not (Test-Path -LiteralPath $DEV_ROOT -PathType Container)) {
  Write-Log 'no development root on disk - nothing to do'
  exit 3
}

# Grouped BY STORY ID, not by folder, because that is the unit worktree-remove.ps1
# actually operates on. Two things make this essential rather than tidy:
#   * one work item can have several development folders - {id}-finish-branch,
#     {id}-improve-validation, {id}-read-path-fixes are all story 23573 - and
#     `worktree-remove.ps1 23573` takes every one of them in a single pass.
#   * it also matches review\{id}-{slug} if az-watcher made one.
# Judging a folder on its own would let a clean folder authorise a removal that
# also deletes a sibling folder holding uncommitted work. So every folder and
# every checkout the removal will touch is gathered under the id first, and the
# whole group has to pass.
$byId = [ordered]@{}

function Add-StoryFolder([string]$Id, [string]$Path, [bool]$IsReview) {
  if (-not $byId.Contains($Id)) {
    $byId[$Id] = [pscustomobject]@{ Id = $Id; Folders = @(); Checkouts = @() }
  }
  $entry = $byId[$Id]
  $entry.Folders += [pscustomobject]@{
    Path = $Path; Name = (Split-Path -Leaf $Path); IsReview = $IsReview
  }
  $entry.Checkouts += @(Get-StoryCheckouts $Path)
}

# Same shapes worktree-remove.ps1 matches: {id}-{slug} and legacy {id}_{slug}.
foreach ($d in (Get-ChildItem -LiteralPath $DEV_ROOT -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name)) {
  if ($d.Name -notmatch '^(\d+)[-_]') { continue }
  $sid = $Matches[1]
  if ($Only -and $sid -ne $Only) { continue }
  Add-StoryFolder $sid $d.FullName $false
}

if ($byId.Count -eq 0) {
  if ($Only) { Write-Log "no development story folder for $Only under $DEV_ROOT" }
  else { Write-Log 'no development story folders on disk - nothing to do' }
  exit 3
}

# The review copies the same removal would take. Development is what this script
# sweeps, but these come along for the ride, so they are held to the same bar.
if (Test-Path -LiteralPath $REVIEW_ROOT -PathType Container) {
  foreach ($d in (Get-ChildItem -LiteralPath $REVIEW_ROOT -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name)) {
    if ($d.Name -notmatch '^(\d+)[-_]') { continue }
    $sid = $Matches[1]
    if (-not $byId.Contains($sid)) { continue }
    Add-StoryFolder $sid $d.FullName $true
  }
}

$plans = @()
foreach ($story in $byId.Values) {
  $id = $story.Id
  $script:Examined++
  $checkouts = @($story.Checkouts)
  Write-Host ''
  Write-Log "-- work item $id ($($story.Folders.Count) folder(s), $($checkouts.Count) checkout(s))"
  foreach ($f in $story.Folders) {
    Write-Host "   folder   $($f.Name)$(if ($f.IsReview) { '   [review copy - removal by id takes it too]' } else { '' })"
  }
  if ($checkouts.Count -eq 0) {
    Write-Host '   no repo checkouts in these folders'
  } else {
    foreach ($co in $checkouts) {
      Write-Host "   checkout $($co.Dir) [$(if ($co.AzRepo) { $co.AzRepo } else { '<unknown repo>' })] on $(if ($co.Branch) { $co.Branch } else { '<detached>' })"
    }
  }

  $found = Get-StoryPrs $id $checkouts
  $prs = @($found.Prs)

  # Incomplete list => cannot conclude "all closed". Held, not skipped: this is a
  # condition someone has to fix (az login, a renamed repo), not a normal state.
  if ($found.Unreadable.Count -gt 0) {
    foreach ($u in $found.Unreadable) { Write-Host "   UNREADABLE: $u" }
    Write-Host '   HELD BACK: the PR list may be incomplete, so "all closed" cannot be proven'
    $script:Held++
    continue
  }

  # The rule's first half. A story with no PRs is a story someone just started.
  if ($prs.Count -eq 0) {
    Write-Host '   no pull requests found - leaving it alone (a story with no PRs is never reaped)'
    $script:Skipped++
    continue
  }

  $open = @()
  foreach ($pr in ($prs | Sort-Object { [int]$_.PrId })) {
    Write-Host "   PR $($pr.PrId) ($($pr.AzRepo) <- $($pr.Branch)): $($pr.Status) [$($pr.Source)]"
    if (-not $pr.Closed) { $open += $pr }
  }
  if ($open.Count -gt 0) {
    $ids = ($open | ForEach-Object { "$($_.PrId) ($($_.Status))" }) -join ', '
    Write-Host "   holding: $($prs.Count - $open.Count)/$($prs.Count) closed - still open: $ids"
    $script:Skipped++
    continue
  }

  # Every PR is closed. Now: is anything here not on the server?
  $blockers = @()
  foreach ($co in $checkouts) {
    $why = Test-CheckoutSafe $co $prs
    if ($why) { $blockers += $why }
  }
  if ($blockers.Count -gt 0) {
    foreach ($b in $blockers) { Write-Host "   HELD BACK: $b" }
    Write-Host '   commit and push, or re-run with --force-dirty / --force-unpushed'
    $script:Held++
    continue
  }

  $plans += [pscustomobject]@{
    Id = $id
    Folders = @($story.Folders)
    Checkouts = @($checkouts)
    Prs = @($prs)
  }
}

if ($plans.Count -eq 0) {
  Write-Host ''
  Write-Log ("examined $($script:Examined) story/stories; none are ready to reap " +
    "(skipped $($script:Skipped), held back $($script:Held))")
  if ($script:Held -gt 0) { exit 5 }
  exit 3
}

# --- warn ------------------------------------------------------------------
Write-Host ''
Write-Host "About to DELETE $($plans.Count) story/stories whose pull requests have all closed:"
foreach ($p in $plans) {
  Write-Host ''
  Write-Host "  work item $($p.Id)   ($($p.Prs.Count) closed PR(s): $(($p.Prs | ForEach-Object { "$($_.PrId) $($_.Status)" }) -join ', '))"
  foreach ($f in $p.Folders) {
    Write-Host "    folder    $($f.Path)$(if ($f.IsReview) { '   [review copy]' } else { '' })"
  }
  foreach ($co in $p.Checkouts) {
    $branchNote = if ($co.Branch -and $co.Branch -ne 'HEAD') {
      "on $($co.Branch) (local branch will be deleted)"
    } else { 'detached (no branch to delete)' }
    Write-Host "    worktree  $($co.Dir) $branchNote"
  }
}
Write-Host ''
Write-Host 'WARNING: this deletes the worktree directories themselves, their local'
Write-Host 'branches, their herdr workspaces, and their notes files. Remote branches'
Write-Host 'and Azure DevOps are untouched.'
Write-Host ''

if ($DryRun) {
  Write-Log "DRY RUN: would reap $($plans.Count) story/stories; nothing was removed"
  Write-Log "examined $($script:Examined), skipped $($script:Skipped), held back $($script:Held)"
  if ($script:Held -gt 0) { exit 5 }
  exit 0
}

if (-not $AssumeYes) {
  if (-not (Get-Command gum -ErrorAction SilentlyContinue)) {
    # No way to ask, so do not guess. A scheduled run passes --yes.
    Write-Error 'gum is not installed, so there is no way to confirm. Re-run with --yes (or --dry-run first).'
    exit 1
  }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $confirmed = $false
  try {
    # Do NOT redirect stderr: gum draws its prompt there and returns only the
    # answer on stdout, so a 2>$null makes it look like a hang.
    & gum confirm "Delete $($plans.Count) story worktree(s) listed above? This cannot be undone."
    $confirmed = ($LASTEXITCODE -eq 0)
  } catch { $confirmed = $false } finally { $ErrorActionPreference = $prev }
  if (-not $confirmed) {
    Write-Log 'cancelled - nothing was removed'
    exit 3
  }
}

# --- execute ---------------------------------------------------------------
# Delegated to worktree-remove.ps1 so the hard-won rules about closing herdr rows
# before deleting checkouts, retrying locked directories and protecting default
# branches live in exactly one place.
foreach ($p in $plans) {
  Write-Host ''
  Write-Log "reaping work item $($p.Id) ($(($p.Folders | ForEach-Object { $_.Name }) -join ', '))"
  $env:WT_ID = $p.Id
  $env:WT_ASSUME_YES = '1'
  $env:WT_SKIP_DIRTY = if ($ForceDirty) { '0' } else { '1' }
  $rc = 0
  try {
    & $REMOVE_WORKTREE
    $rc = $LASTEXITCODE
    if ($null -eq $rc) { $rc = 0 }
  } catch {
    $rc = 1
    Write-Warning "worktree-remove.ps1 threw for story $($p.Id): $_"
  } finally {
    Remove-Item Env:WT_ID, Env:WT_ASSUME_YES, Env:WT_SKIP_DIRTY -ErrorAction SilentlyContinue
  }
  switch ($rc) {
    0 {
      $script:Reaped++
      Send-Notify "Story reaped: $($p.Id)" "All $($p.Prs.Count) PR(s) closed - worktrees, branches and rows removed."
    }
    3 {
      Write-Log "nothing local left for story $($p.Id) - already gone"
      $script:Skipped++
    }
    5 {
      Write-Log "story $($p.Id) held back by worktree-remove.ps1 (uncommitted changes)"
      $script:Held++
    }
    default {
      Write-Warning "worktree-remove.ps1 exited $rc for story $($p.Id)"
      $script:Failed++
      Send-Notify "Story reap FAILED: $($p.Id)" "worktree-remove.ps1 exited $rc. See the story-reap log."
    }
  }
}

Write-Host ''
Write-Log ("examined $($script:Examined), reaped $($script:Reaped), skipped $($script:Skipped), " +
  "held back $($script:Held), failed $($script:Failed)")
Write-Log 'nothing was written to Azure DevOps'

if ($script:Failed -gt 0) { exit 1 }
if ($script:Reaped -eq 0 -and $script:Held -gt 0) { exit 5 }
if ($script:Reaped -eq 0) { exit 3 }
exit 0

} finally {
  if ($script:LockStream) {
    $script:LockStream.Close()
    $script:LockStream.Dispose()
  }
}
