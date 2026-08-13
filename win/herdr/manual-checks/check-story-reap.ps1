# check-story-reap.ps1 - OPT-IN checks for win/herdr/story-reap.ps1
#
# NOT A TEST FILE. Deliberately not named test-*.ps1 and deliberately not in
# tests/, so that nothing sweeping this repo for tests picks it up. Run it by
# hand, on purpose:
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File check-story-reap.ps1
#
# See README.md in this folder for why.
#
# WHAT IT TOUCHES
#   Azure DevOps  nothing. story-reap.ps1 runs against a STUB az (WT_REVIEW_AZ)
#                 serving canned JSON from disk, which logs every argument list it
#                 is handed; a check reads that log back and fails if anything but
#                 a read was issued. No network call, no credential use.
#   git           throwaway repos under %TEMP%\herdr-story-reap-checks\<pid>\.
#   herdr         nothing. worktree-remove.ps1 is replaced by a STUB
#                 (WT_REMOVE_SCRIPT) that only records the story id it was handed,
#                 so no workspace is closed and no checkout is deleted. These
#                 checks are about which stories story-reap.ps1 DECIDES to reap;
#                 the removal itself is worktree-remove.ps1's own business.
#   your files    none.
#
# THE DECISION UNDER TEST
#   Reap a story only when it has AT LEAST ONE pull request and EVERY one of them
#   is closed. The no-PR case is the one that matters most: a brand-new story
#   looks exactly like a finished one to any test that only asks "is anything
#   still open?", and reaping it would delete work someone started minutes ago.
#
$ErrorActionPreference = 'Stop'

$FixtureMarker = 'herdr-story-reap-checks'
$Base = Join-Path ([IO.Path]::GetTempPath()) "$FixtureMarker\$PID"
$HerdrDir = Split-Path -Parent $PSScriptRoot
$ReapScript = Join-Path $HerdrDir 'story-reap.ps1'

$script:Run = 0
$script:Pass = 0
$script:Fail = 0
$script:Names = @()

if (-not (Test-Path -LiteralPath $ReapScript)) {
  Write-Error "cannot find $ReapScript"
  exit 1
}

function Check([string]$Name, [bool]$Ok, [string]$Detail) {
  if ($Ok) {
    $script:Pass++
    Write-Host "  PASS  $Name" -ForegroundColor Green
  } else {
    $script:Fail++
    $script:Names += $Name
    Write-Host "  FAIL  $Name  :: $Detail" -ForegroundColor Red
  }
}

function Git([string]$Repo, [string[]]$A) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $o = & git.exe -C $Repo @A 2>$null
    $global:GX = $LASTEXITCODE
    return @($o)
  } finally { $ErrorActionPreference = $prev }
}

function GitLine([string]$Repo, [string[]]$A) {
  $o = Git $Repo $A
  if ($global:GX -ne 0) { return '' }
  foreach ($l in $o) { $t = "$l".Trim(); if ($t) { return $t } }
  return ''
}

# ===========================================================================
# Fixture
# ===========================================================================

# The stub az. Serves canned JSON keyed by the command it was asked for, and logs
# every call so a check can prove nothing but reads were issued. A missing fixture
# file is an ERROR exit, which is how "unreadable work item" is staged.
function Write-StubAz {
  $body = @'
# STUB az - test double for check-story-reap.ps1. Canned JSON only, no network.
$ErrorActionPreference = 'Continue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Content -LiteralPath (Join-Path $dir 'az-calls.log') -Value ($args -join ' ')

function Emit([string]$Name) {
  $p = Join-Path $dir $Name
  if (-not (Test-Path -LiteralPath $p)) { exit 1 }
  Get-Content -LiteralPath $p -Raw
  exit 0
}

function Slug([string]$s) {
  return ([regex]::Replace($s, '[^A-Za-z0-9]+', '_')).Trim('_')
}

$joined = $args -join ' '
if ($joined -match '^boards work-item show --id (\d+)') { Emit "wi-$($Matches[1]).json" }
if ($joined -match '^repos pr show --id (\d+)') { Emit "pr-$($Matches[1]).json" }
if ($joined -match '^repos pr list --repository (.+?) --source-branch (\S+)') {
  Emit ("prlist-" + (Slug $Matches[1]) + "-" + (Slug $Matches[2]) + ".json")
}
Write-Error "stub az: unhandled command: $joined"
exit 1
'@
  Set-Content -LiteralPath $script:Stub -Value $body -Encoding utf8
}

# The stub worktree-remove.ps1. Records the story id it was handed and the env
# hooks it was given, then reports success. Nothing is deleted.
function Write-StubRemove {
  $body = @'
# STUB worktree-remove.ps1 - test double for check-story-reap.ps1.
$ErrorActionPreference = 'Continue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Content -LiteralPath (Join-Path $dir 'remove-calls.log') -Value `
  ("id=$($env:WT_ID) yes=$($env:WT_ASSUME_YES) skipdirty=$($env:WT_SKIP_DIRTY)")
exit 0
'@
  Set-Content -LiteralPath $script:RemoveStub -Value $body -Encoding utf8
}

function Write-FixtureConfig {
  Set-Content -LiteralPath $script:Cfg -Encoding utf8 -Value @(
    '[worktrees]'
    ('directory = "' + $script:Trees.Replace('\', '\\') + '"')
  )
}

function Reset-Fixture {
  $script:Run++
  $script:Root = Join-Path $Base "run$($script:Run)"
  $script:Repos = Join-Path $script:Root 'repos'
  $script:Trees = Join-Path $script:Root 'worktrees'
  $script:Dev = Join-Path $script:Trees 'development'
  $script:Cfg = Join-Path $script:Root 'config.toml'
  $script:AzDir = Join-Path $script:Root 'az'
  $script:Stub = Join-Path $script:AzDir 'az.ps1'
  $script:AzLog = Join-Path $script:AzDir 'az-calls.log'
  $script:RemoveStub = Join-Path $script:AzDir 'remove.ps1'
  $script:RemoveLog = Join-Path $script:AzDir 'remove-calls.log'
  New-Item -ItemType Directory -Force -Path `
    $script:Root, $script:Repos, $script:Trees, $script:Dev, $script:AzDir | Out-Null
  Write-FixtureConfig
  Write-StubAz
  Write-StubRemove
}

# A primary clone with an Azure-shaped origin URL, plus one commit on main.
function New-Clone([string]$AzName) {
  $dir = Join-Path $script:Repos ($AzName -replace ' ', '_')
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Git $dir @('init', '--initial-branch=main') | Out-Null
  Git $dir @('config', 'user.email', 'check@example.invalid') | Out-Null
  Git $dir @('config', 'user.name', 'Check') | Out-Null
  Git $dir @('config', 'commit.gpgsign', 'false') | Out-Null
  Set-Content -LiteralPath (Join-Path $dir 'README.md') -Value 'base' -Encoding utf8
  Git $dir @('add', '-A') | Out-Null
  Git $dir @('commit', '-m', 'base') | Out-Null
  Git $dir @('remote', 'add', 'origin', "https://dev.azure.com/org/proj/_git/$($AzName -replace ' ', '%20')") | Out-Null
  return $dir
}

# A story folder holding one checkout of $AzName on branch $Branch.
# Returns the worktree path.
function New-StoryCheckout([string]$StoryName, [string]$AzName, [string]$Branch, [string]$Clone) {
  $storyDir = Join-Path $script:Dev $StoryName
  New-Item -ItemType Directory -Force -Path $storyDir | Out-Null
  $wt = Join-Path $storyDir ($AzName -replace ' ', '_')
  Git $Clone @('branch', $Branch, 'main') | Out-Null
  Git $Clone @('worktree', 'add', $wt, $Branch) | Out-Null
  return $wt
}

function Add-Commit([string]$Wt, [string]$Text) {
  Set-Content -LiteralPath (Join-Path $Wt 'work.txt') -Value $Text -Encoding utf8
  Git $Wt @('add', '-A') | Out-Null
  Git $Wt @('commit', '-m', $Text) | Out-Null
  return (GitLine $Wt @('rev-parse', 'HEAD'))
}

# Pretend origin still carries this branch at this commit.
function Set-OriginRef([string]$Wt, [string]$Branch, [string]$Sha) {
  Git $Wt @('update-ref', "refs/remotes/origin/$Branch", $Sha) | Out-Null
}

function Write-Pr([string]$PrId, [string]$Status, [string]$AzRepo, [string]$Branch, [string]$SrcCommit) {
  $json = @{
    pullRequestId = [int]$PrId
    status = $Status
    repository = @{ name = $AzRepo }
    sourceRefName = "refs/heads/$Branch"
    lastMergeSourceCommit = @{ commitId = $SrcCommit }
  } | ConvertTo-Json -Depth 6
  Set-Content -LiteralPath (Join-Path $script:AzDir "pr-$PrId.json") -Value $json -Encoding utf8
  return $json
}

# The per-branch PR list the stub serves for `repos pr list --source-branch`.
function Write-PrList([string]$AzRepo, [string]$Branch, [string[]]$PrJson) {
  $slug = { param($s) ([regex]::Replace($s, '[^A-Za-z0-9]+', '_')).Trim('_') }
  $name = "prlist-$(& $slug $AzRepo)-$(& $slug $Branch).json"
  $body = '[' + ($PrJson -join ',') + ']'
  Set-Content -LiteralPath (Join-Path $script:AzDir $name) -Value $body -Encoding utf8
}

# A work item linking the given PR ids.
function Write-WorkItem([string]$Id, [string[]]$PrIds) {
  $rels = @()
  foreach ($p in $PrIds) {
    $rels += @{ rel = 'ArtifactLink'; url = "vstfs:///Git/PullRequestId/proj%2Frepo%2F$p" }
  }
  $json = @{ id = [int]$Id; relations = $rels } | ConvertTo-Json -Depth 6
  Set-Content -LiteralPath (Join-Path $script:AzDir "wi-$Id.json") -Value $json -Encoding utf8
}

# Run story-reap.ps1 against the fixture. Returns exit code + output text.
function Invoke-Reap([string[]]$ExtraArgs) {
  $prevCfg = $env:HERDR_CONFIG_PATH
  $prevAz = $env:WT_REVIEW_AZ
  $prevRm = $env:WT_REMOVE_SCRIPT
  $prevLocal = $env:LOCALAPPDATA
  $env:HERDR_CONFIG_PATH = $script:Cfg
  $env:WT_REVIEW_AZ = $script:Stub
  $env:WT_REMOVE_SCRIPT = $script:RemoveStub
  # Keep the single-instance lock inside the fixture so a real az-watcher-era lock
  # in the user's profile cannot make a check exit early.
  $env:LOCALAPPDATA = $script:Root
  try {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ReapScript @ExtraArgs 2>&1 |
      Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
  } finally {
    $env:HERDR_CONFIG_PATH = $prevCfg
    $env:WT_REVIEW_AZ = $prevAz
    $env:WT_REMOVE_SCRIPT = $prevRm
    $env:LOCALAPPDATA = $prevLocal
  }
}

function Get-RemovedIds {
  if (-not (Test-Path -LiteralPath $script:RemoveLog)) { return @() }
  $ids = @()
  foreach ($line in (Get-Content -LiteralPath $script:RemoveLog)) {
    if ("$line" -match 'id=(\d+)') { $ids += $Matches[1] }
  }
  return $ids
}

# ===========================================================================
# Checks
# ===========================================================================
Write-Host ''
Write-Host "=== check-story-reap.ps1 (fixtures under $Base) ==="

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- a story with NO pull requests is never reaped'
Reset-Fixture
$clone = New-Clone 'Alpha Repo'
$wt = New-StoryCheckout '1001-no-prs' 'Alpha Repo' '1001-no-prs' $clone
Set-OriginRef $wt '1001-no-prs' (GitLine $wt @('rev-parse', 'HEAD'))
Write-WorkItem '1001' @()
Write-PrList 'Alpha Repo' '1001-no-prs' @()
$r = Invoke-Reap @('--yes')
Check 'no PRs: exit 3 (nothing to do)' ($r.Code -eq 3) "exit $($r.Code)`n$($r.Out)"
Check 'no PRs: worktree-remove never called' ((Get-RemovedIds).Count -eq 0) "called for $((Get-RemovedIds) -join ',')"
Check 'no PRs: says so' ($r.Out -match 'no pull requests found') $r.Out

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- one active PR holds the story'
Reset-Fixture
$clone = New-Clone 'Alpha Repo'
$wt = New-StoryCheckout '1002-active' 'Alpha Repo' '1002-active' $clone
$head = GitLine $wt @('rev-parse', 'HEAD')
Set-OriginRef $wt '1002-active' $head
$pr = Write-Pr '5001' 'active' 'Alpha Repo' '1002-active' $head
Write-PrList 'Alpha Repo' '1002-active' @($pr)
Write-WorkItem '1002' @('5001')
$r = Invoke-Reap @('--yes')
Check 'active PR: exit 3' ($r.Code -eq 3) "exit $($r.Code)`n$($r.Out)"
Check 'active PR: not reaped' ((Get-RemovedIds).Count -eq 0) "called for $((Get-RemovedIds) -join ',')"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- every PR completed: reaped'
Reset-Fixture
$clone = New-Clone 'Alpha Repo'
$wt = New-StoryCheckout '1003-done' 'Alpha Repo' '1003-done' $clone
$head = GitLine $wt @('rev-parse', 'HEAD')
Set-OriginRef $wt '1003-done' $head
$pr = Write-Pr '5002' 'completed' 'Alpha Repo' '1003-done' $head
Write-PrList 'Alpha Repo' '1003-done' @($pr)
Write-WorkItem '1003' @('5002')
$r = Invoke-Reap @('--yes')
Check 'completed: exit 0' ($r.Code -eq 0) "exit $($r.Code)`n$($r.Out)"
Check 'completed: reaped 1003' ((Get-RemovedIds) -contains '1003') "called for $((Get-RemovedIds) -join ',')"
Check 'completed: WT_SKIP_DIRTY=1 passed' `
  ((Get-Content -LiteralPath $script:RemoveLog -Raw) -match 'skipdirty=1') `
  (Get-Content -LiteralPath $script:RemoveLog -Raw)

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- mixed: one completed, one active, in two repos -> held'
Reset-Fixture
$cloneA = New-Clone 'Alpha Repo'
$cloneB = New-Clone 'Beta Repo'
$wtA = New-StoryCheckout '1004-mixed' 'Alpha Repo' '1004-mixed' $cloneA
$wtB = New-StoryCheckout '1004-mixed' 'Beta Repo' '1004-mixed' $cloneB
$headA = GitLine $wtA @('rev-parse', 'HEAD')
$headB = GitLine $wtB @('rev-parse', 'HEAD')
Set-OriginRef $wtA '1004-mixed' $headA
Set-OriginRef $wtB '1004-mixed' $headB
$prA = Write-Pr '5003' 'completed' 'Alpha Repo' '1004-mixed' $headA
$prB = Write-Pr '5004' 'active' 'Beta Repo' '1004-mixed' $headB
Write-PrList 'Alpha Repo' '1004-mixed' @($prA)
Write-PrList 'Beta Repo' '1004-mixed' @($prB)
Write-WorkItem '1004' @('5003', '5004')
$r = Invoke-Reap @('--yes')
Check 'mixed: exit 3' ($r.Code -eq 3) "exit $($r.Code)`n$($r.Out)"
Check 'mixed: not reaped' ((Get-RemovedIds).Count -eq 0) "called for $((Get-RemovedIds) -join ',')"
Check 'mixed: names the open PR' ($r.Out -match 'still open: 5004') $r.Out

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- abandoned counts as closed by default, not with --completed-only'
Reset-Fixture
$clone = New-Clone 'Alpha Repo'
$wt = New-StoryCheckout '1005-aband' 'Alpha Repo' '1005-aband' $clone
$head = GitLine $wt @('rev-parse', 'HEAD')
Set-OriginRef $wt '1005-aband' $head
$pr = Write-Pr '5005' 'abandoned' 'Alpha Repo' '1005-aband' $head
Write-PrList 'Alpha Repo' '1005-aband' @($pr)
Write-WorkItem '1005' @('5005')
$r = Invoke-Reap @('--yes')
Check 'abandoned: reaped by default' ((Get-RemovedIds) -contains '1005') "exit $($r.Code)`n$($r.Out)"
Remove-Item -LiteralPath $script:RemoveLog -Force -ErrorAction SilentlyContinue
$r = Invoke-Reap @('--yes', '--completed-only')
Check '--completed-only: abandoned holds it' ((Get-RemovedIds).Count -eq 0) "exit $($r.Code)`n$($r.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- an unreadable work item holds the story (exit 5), it does not read as "no PRs"'
Reset-Fixture
$clone = New-Clone 'Alpha Repo'
$wt = New-StoryCheckout '1006-unreadable' 'Alpha Repo' '1006-unreadable' $clone
$head = GitLine $wt @('rev-parse', 'HEAD')
Set-OriginRef $wt '1006-unreadable' $head
Write-PrList 'Alpha Repo' '1006-unreadable' @()
# No wi-1006.json on disk -> the stub exits 1, standing in for an expired token.
$r = Invoke-Reap @('--yes')
Check 'unreadable work item: exit 5 (held)' ($r.Code -eq 5) "exit $($r.Code)`n$($r.Out)"
Check 'unreadable work item: not reaped' ((Get-RemovedIds).Count -eq 0) "called for $((Get-RemovedIds) -join ',')"
Check 'unreadable work item: says why' ($r.Out -match 'UNREADABLE') $r.Out

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- uncommitted changes hold the story'
Reset-Fixture
$clone = New-Clone 'Alpha Repo'
$wt = New-StoryCheckout '1007-dirty' 'Alpha Repo' '1007-dirty' $clone
$head = GitLine $wt @('rev-parse', 'HEAD')
Set-OriginRef $wt '1007-dirty' $head
$pr = Write-Pr '5007' 'completed' 'Alpha Repo' '1007-dirty' $head
Write-PrList 'Alpha Repo' '1007-dirty' @($pr)
Write-WorkItem '1007' @('5007')
Set-Content -LiteralPath (Join-Path $wt 'scratch.txt') -Value 'unsaved' -Encoding utf8
$r = Invoke-Reap @('--yes')
Check 'dirty: exit 5 (held)' ($r.Code -eq 5) "exit $($r.Code)`n$($r.Out)"
Check 'dirty: not reaped' ((Get-RemovedIds).Count -eq 0) "called for $((Get-RemovedIds) -join ',')"
$r = Invoke-Reap @('--yes', '--force-dirty')
Check '--force-dirty: reaped anyway' ((Get-RemovedIds) -contains '1007') "exit $($r.Code)`n$($r.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- commits the PR never saw hold the story'
Reset-Fixture
$clone = New-Clone 'Alpha Repo'
$wt = New-StoryCheckout '1008-ahead' 'Alpha Repo' '1008-ahead' $clone
$prSha = Add-Commit $wt 'what the PR saw'
Add-Commit $wt 'made after the PR closed' | Out-Null
# origin no longer carries the branch (deleted on completion), and the PR's
# high-water mark is the EARLIER commit.
$pr = Write-Pr '5008' 'completed' 'Alpha Repo' '1008-ahead' $prSha
Write-PrList 'Alpha Repo' '1008-ahead' @($pr)
Write-WorkItem '1008' @('5008')
$r = Invoke-Reap @('--yes')
Check 'ahead of PR: exit 5 (held)' ($r.Code -eq 5) "exit $($r.Code)`n$($r.Out)"
Check 'ahead of PR: not reaped' ((Get-RemovedIds).Count -eq 0) "called for $((Get-RemovedIds) -join ',')"
Check 'ahead of PR: says why' ($r.Out -match 'never saw|not on origin') $r.Out
$r = Invoke-Reap @('--yes', '--force-unpushed')
Check '--force-unpushed: reaped anyway' ((Get-RemovedIds) -contains '1008') "exit $($r.Code)`n$($r.Out)"

# ---------------------------------------------------------------------------
# The regression this guards: a squash merge rewrites history, so the local
# branch's commits are ancestors of nothing on origin, and the source branch is
# deleted on completion so origin/<branch> is gone too. A naive
# "is HEAD on origin/<branch>?" test calls that unpushed work and the story is
# never reaped. The PR's own lastMergeSourceCommit is what settles it.
Write-Host ''
Write-Host '-- squash-merged story (no origin/<branch>, HEAD == the PR source commit) is reaped'
Reset-Fixture
$clone = New-Clone 'Alpha Repo'
$wt = New-StoryCheckout '1009-squashed' 'Alpha Repo' '1009-squashed' $clone
$prSha = Add-Commit $wt 'the work'
$pr = Write-Pr '5009' 'completed' 'Alpha Repo' '1009-squashed' $prSha
Write-PrList 'Alpha Repo' '1009-squashed' @($pr)
Write-WorkItem '1009' @('5009')
Check 'squashed fixture really has no origin ref' `
  (-not (GitLine $wt @('rev-parse', '--verify', '--quiet', 'refs/remotes/origin/1009-squashed'))) 'origin ref present'
$r = Invoke-Reap @('--yes')
Check 'squashed: exit 0' ($r.Code -eq 0) "exit $($r.Code)`n$($r.Out)"
Check 'squashed: reaped 1009' ((Get-RemovedIds) -contains '1009') "called for $((Get-RemovedIds) -join ',')"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- a PR linked only to the work item still holds the story'
Reset-Fixture
$clone = New-Clone 'Alpha Repo'
$wt = New-StoryCheckout '1010-linked' 'Alpha Repo' '1010-linked' $clone
$head = GitLine $wt @('rev-parse', 'HEAD')
Set-OriginRef $wt '1010-linked' $head
# The branch query finds a completed PR; the work item links a SECOND, active PR
# in a repo that is not checked out here. The union has to notice it.
$prClosed = Write-Pr '5010' 'completed' 'Alpha Repo' '1010-linked' $head
Write-Pr '5011' 'active' 'Gamma Repo' '1010-other' 'deadbeef' | Out-Null
Write-PrList 'Alpha Repo' '1010-linked' @($prClosed)
Write-WorkItem '1010' @('5010', '5011')
$r = Invoke-Reap @('--yes')
Check 'work-item-only PR: exit 3' ($r.Code -eq 3) "exit $($r.Code)`n$($r.Out)"
Check 'work-item-only PR: not reaped' ((Get-RemovedIds).Count -eq 0) "called for $((Get-RemovedIds) -join ',')"
Check 'work-item-only PR: names 5011' ($r.Out -match 'still open: 5011') $r.Out

# ---------------------------------------------------------------------------
# The real disk layout that motivated grouping by id: 23573-finish-branch,
# 23573-improve-validation and 23573-read-path-fixes are all one work item, and
# `worktree-remove.ps1 23573` takes all three at once. Judging them one folder at
# a time would let the clean folder authorise a removal that also deletes the
# folder holding uncommitted work.
Write-Host ''
Write-Host '-- several folders for one id are judged together, not one at a time'
Reset-Fixture
$clone = New-Clone 'Alpha Repo'
$wtA = New-StoryCheckout '1020-first-slice' 'Alpha Repo' '1020-first-slice' $clone
$wtB = New-StoryCheckout '1020-second-slice' 'Alpha Repo' '1020-second-slice' $clone
$headA = GitLine $wtA @('rev-parse', 'HEAD')
$headB = GitLine $wtB @('rev-parse', 'HEAD')
Set-OriginRef $wtA '1020-first-slice' $headA
Set-OriginRef $wtB '1020-second-slice' $headB
$prA = Write-Pr '5020' 'completed' 'Alpha Repo' '1020-first-slice' $headA
$prB = Write-Pr '5021' 'completed' 'Alpha Repo' '1020-second-slice' $headB
Write-PrList 'Alpha Repo' '1020-first-slice' @($prA)
Write-PrList 'Alpha Repo' '1020-second-slice' @($prB)
Write-WorkItem '1020' @('5020', '5021')
# The SECOND folder has unsaved work. Grouped by id, that must hold the whole
# work item back - including the clean first folder.
Set-Content -LiteralPath (Join-Path $wtB 'scratch.txt') -Value 'unsaved' -Encoding utf8
$r = Invoke-Reap @('--yes')
Check 'multi-folder: dirty sibling holds the whole id' ((Get-RemovedIds).Count -eq 0) `
  "called for $((Get-RemovedIds) -join ',')`n$($r.Out)"
Check 'multi-folder: exit 5 (held)' ($r.Code -eq 5) "exit $($r.Code)`n$($r.Out)"
Check 'multi-folder: counted as ONE work item, not two' `
  (($r.Out -match 'examined 1 story') -and ($r.Out -match 'work item 1020 \(2 folder')) $r.Out
Check 'multi-folder: both folders listed' `
  (($r.Out -match '1020-first-slice') -and ($r.Out -match '1020-second-slice')) $r.Out
# Clean it up and both folders should go in a single removal call.
Remove-Item -LiteralPath (Join-Path $wtB 'scratch.txt') -Force
$r = Invoke-Reap @('--yes')
Check 'multi-folder: one removal call for the id' ((Get-RemovedIds).Count -eq 1) `
  "called $((Get-RemovedIds).Count) time(s): $((Get-RemovedIds) -join ',')`n$($r.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- a review copy of the same id is held to the same bar'
Reset-Fixture
$clone = New-Clone 'Alpha Repo'
$wt = New-StoryCheckout '1021-with-review' 'Alpha Repo' '1021-with-review' $clone
$head = GitLine $wt @('rev-parse', 'HEAD')
Set-OriginRef $wt '1021-with-review' $head
$pr = Write-Pr '5022' 'completed' 'Alpha Repo' '1021-with-review' $head
Write-PrList 'Alpha Repo' '1021-with-review' @($pr)
Write-WorkItem '1021' @('5022')
# A review\{id}-{slug} copy, detached, with unsaved work in it. Removal is by id
# so it would be deleted too; it therefore has to be able to hold the story back.
$revDir = Join-Path $script:Trees 'review\1021-with-review'
New-Item -ItemType Directory -Force -Path $revDir | Out-Null
$revWt = Join-Path $revDir 'Alpha_Repo'
Git $clone @('worktree', 'add', '--detach', $revWt, 'main') | Out-Null
Set-Content -LiteralPath (Join-Path $revWt 'scratch.txt') -Value 'unsaved review note' -Encoding utf8
$r = Invoke-Reap @('--yes')
Check 'review copy: dirty review holds the story' ((Get-RemovedIds).Count -eq 0) `
  "called for $((Get-RemovedIds) -join ',')`n$($r.Out)"
Check 'review copy: flagged in the report' ($r.Out -match 'review copy') $r.Out
# Clean: a DETACHED checkout has no branch to lose, so it must not be mistaken
# for unpushed work - that would hold the story back forever.
Remove-Item -LiteralPath (Join-Path $revWt 'scratch.txt') -Force
$r = Invoke-Reap @('--yes')
Check 'review copy: clean detached checkout does not block' ((Get-RemovedIds) -contains '1021') `
  "exit $($r.Code)`n$($r.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- --dry-run removes nothing'
Reset-Fixture
$clone = New-Clone 'Alpha Repo'
$wt = New-StoryCheckout '1011-dry' 'Alpha Repo' '1011-dry' $clone
$head = GitLine $wt @('rev-parse', 'HEAD')
Set-OriginRef $wt '1011-dry' $head
$pr = Write-Pr '5012' 'completed' 'Alpha Repo' '1011-dry' $head
Write-PrList 'Alpha Repo' '1011-dry' @($pr)
Write-WorkItem '1011' @('5012')
$r = Invoke-Reap @('--dry-run')
Check 'dry-run: exit 0' ($r.Code -eq 0) "exit $($r.Code)`n$($r.Out)"
Check 'dry-run: worktree-remove never called' ((Get-RemovedIds).Count -eq 0) "called for $((Get-RemovedIds) -join ',')"
Check 'dry-run: still lists the story' ($r.Out -match '1011-dry') $r.Out
Check 'dry-run: checkout still on disk' (Test-Path -LiteralPath $wt) "gone: $wt"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- --story scopes the sweep to one id'
Reset-Fixture
$clone = New-Clone 'Alpha Repo'
$wtA = New-StoryCheckout '1012-first' 'Alpha Repo' '1012-first' $clone
$wtB = New-StoryCheckout '1013-second' 'Alpha Repo' '1013-second' $clone
foreach ($pair in @(@('1012', '1012-first', '5013', $wtA), @('1013', '1013-second', '5014', $wtB))) {
  $head = GitLine $pair[3] @('rev-parse', 'HEAD')
  Set-OriginRef $pair[3] $pair[1] $head
  $pr = Write-Pr $pair[2] 'completed' 'Alpha Repo' $pair[1] $head
  Write-PrList 'Alpha Repo' $pair[1] @($pr)
  Write-WorkItem $pair[0] @($pair[2])
}
$r = Invoke-Reap @('--yes', '--story', '1012')
$ids = Get-RemovedIds
Check '--story: reaped 1012 only' (($ids -contains '1012') -and ($ids -notcontains '1013')) `
  "called for $($ids -join ',')`n$($r.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- Azure DevOps was only ever READ'
# Re-uses the last fixture's call log, which covers work-item show + pr list.
$writeVerbs = @()
if (Test-Path -LiteralPath $script:AzLog) {
  foreach ($line in (Get-Content -LiteralPath $script:AzLog)) {
    $l = "$line".Trim()
    if (-not $l) { continue }
    $ok = ($l -match '^boards work-item show ') -or
          ($l -match '^repos pr show ') -or
          ($l -match '^repos pr list ') -or
          ($l -match '^repos pr work-item list ') -or
          ($l -match '^account show') -or
          ($l -match '^devops configure')
    if (-not $ok) { $writeVerbs += $l }
  }
}
Check 'az log has calls in it' ((Test-Path -LiteralPath $script:AzLog) -and
  ((Get-Content -LiteralPath $script:AzLog).Count -gt 0)) 'no az calls were logged'
Check 'az: nothing but reads issued' ($writeVerbs.Count -eq 0) ($writeVerbs -join ' | ')

# The guard itself: ask the script to run a write and confirm it refuses.
$Reap = Get-Content -LiteralPath $ReapScript -Raw
Check 'AZ_READ_ONLY has no write verbs' `
  ($Reap -notmatch "'repos pr (create|update|complete|set-vote|reviewer)" ) 'a write verb is on the allowlist'
Check 'every az call goes through Invoke-AzRead' `
  ($Reap -notmatch '&\s+\$AZ_CMD' -or ($Reap -split '&\s+\$AZ_CMD').Count -eq 2) `
  'more than one direct $AZ_CMD invocation - one of them bypasses the guard'

# ===========================================================================
Write-Host ''
Write-Host '=== summary ==='
Write-Host "  passed $script:Pass, failed $script:Fail"
if ($script:Fail -gt 0) {
  Write-Host '  failed checks:' -ForegroundColor Red
  foreach ($n in $script:Names) { Write-Host "    - $n" -ForegroundColor Red }
}
Write-Host ''
Write-Host "Fixtures left in place for inspection: $Base"
Write-Host 'Remove them with:'
Write-Host "  Remove-Item -Recurse -Force '$Base'"
if ($script:Fail -gt 0) { exit 1 }
exit 0
