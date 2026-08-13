# check-review-remove.ps1 - OPT-IN checks for win/herdr/review-remove.ps1
#
# NOT A TEST FILE. Deliberately not named test-*.ps1 and deliberately not in
# tests/, so that nothing sweeping this repo for tests picks it up. Run it by
# hand, on purpose:
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File check-review-remove.ps1
#
# See README.md in this folder for why.
#
# WHAT IT TOUCHES
#   Azure DevOps  nothing. review-make.ps1 and review-remove.ps1 both run against
#                 a STUB az (WT_REVIEW_AZ) serving canned JSON from disk, which
#                 logs every argument list it is handed; a check reads that log
#                 back and fails if anything but a read was issued. No network
#                 call, no credential use.
#   git           throwaway repos under %TEMP%\herdr-review-rm-checks\<pid>\.
#   herdr         creates workspaces in your live session and closes them again.
#                 Cleanup matches on the fixture path, never on a label, and the
#                 last check asserts the workspace count is back to baseline.
#   your files    none.
#
# Every review-remove run below passes --yes: gum would otherwise sit waiting for
# a confirmation nobody is there to give.
#
$ErrorActionPreference = 'Stop'

$FixtureMarker = 'herdr-review-rm-checks'
$Base = Join-Path ([IO.Path]::GetTempPath()) "$FixtureMarker\$PID"
$HerdrDir = Split-Path -Parent $PSScriptRoot
$MakeScript = Join-Path $HerdrDir 'review-make.ps1'
$RemoveScript = Join-Path $HerdrDir 'review-remove.ps1'
$script:Run = 0
$script:Pass = 0
$script:Fail = 0
$script:Names = @()

foreach ($s in @($MakeScript, $RemoveScript)) {
  if (-not (Test-Path -LiteralPath $s)) {
    Write-Error "cannot find $s"
    exit 1
  }
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
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & git.exe -C $Repo @A 2>$null; $global:GX = $LASTEXITCODE; return @($o) }
  finally { $ErrorActionPreference = $prev }
}
function GitLine([string]$Repo, [string[]]$A) {
  $o = Git $Repo $A
  if ($global:GX -ne 0) { return '' }
  foreach ($l in $o) { $t = "$l".Trim(); if ($t) { return $t } }
  return ''
}

# Load review-remove.ps1's functions and configuration without running it. Only
# function definitions (inert) and the named literal assignments are evaluated,
# so loading cannot make an az, git or herdr call. Values come from the real file
# so a check cannot keep passing against a stale copy of $AZ_READ_ONLY.
$WantedConfig = @('AZ_READ_ONLY', 'DONE_STATUS', 'NOTES_ARCHIVE',
  'TREE_TEE', 'TREE_ELL', 'TREE_PIPE', 'TREE_GAP', 'TREE_INDENT', 'TREE_CHARS')

function Get-LibText([string]$Path) {
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count -gt 0) {
    throw "$Path does not parse: $($errs[0].Message) (line $($errs[0].Extent.StartLineNumber))"
  }
  $parts = @()
  foreach ($st in $ast.EndBlock.Statements) {
    if ($st -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
      $parts += $st.Extent.Text
      continue
    }
    if ($st -is [System.Management.Automation.Language.AssignmentStatementAst]) {
      $left = $st.Left
      if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) {
        if ($WantedConfig -contains $left.VariablePath.UserPath) { $parts += $st.Extent.Text }
      }
    }
  }
  return ($parts -join "`n")
}

$LibText = Get-LibText $RemoveScript
# At script scope on purpose: inside a function these would be local.
Invoke-Expression $LibText

# ===========================================================================
# Fixture
# ===========================================================================
function Write-FixtureConfig {
  Set-Content -LiteralPath $script:Cfg -Encoding utf8 -Value @(
    '[worktrees]'
    ('directory = "' + $script:Trees.Replace('\', '\\') + '"')
    '[ui.sidebar.spaces]'
    'rows = [["$tree", "state_icon", "workspace"]]'
  )
}

function Write-StubAz {
  $body = @'
# STUB az - test double for check-review-remove.ps1. Canned JSON only, no network.
$ErrorActionPreference = 'Continue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Content -LiteralPath (Join-Path $dir 'az-calls.log') -Value ($args -join ' ')

function Emit([string]$Name) {
  $p = Join-Path $dir $Name
  if (-not (Test-Path -LiteralPath $p)) { exit 1 }
  Get-Content -LiteralPath $p -Raw
  exit 0
}

$joined = $args -join ' '
if ($joined -match '^boards work-item show --id (\d+)') { Emit "wi-$($Matches[1]).json" }
if ($joined -match '^repos pr show --id (\d+)') { Emit "pr-$($Matches[1]).json" }
if ($joined -match '^devops invoke .*workItemId=(\d+)') { Emit "comments-$($Matches[1]).json" }
Write-Error "stub az: unhandled command: $joined"
exit 1
'@
  Set-Content -LiteralPath $script:Stub -Value $body -Encoding utf8
}

function Reset-Fixture {
  Close-Workspaces
  $script:Run++
  $script:Root = Join-Path $Base "run$($script:Run)"
  $script:Repos = Join-Path $script:Root 'repos'
  $script:Trees = Join-Path $script:Root 'worktrees'
  $script:Cfg = Join-Path $script:Root 'config.toml'
  $script:AzDir = Join-Path $script:Root 'az'
  $script:Stub = Join-Path $script:AzDir 'az.ps1'
  $script:AzLog = Join-Path $script:AzDir 'az-calls.log'
  $script:Home2 = Join-Path $script:Root 'home'
  New-Item -ItemType Directory -Force -Path `
    $script:Root, $script:Repos, $script:Trees, $script:AzDir, $script:Home2 | Out-Null
  Write-FixtureConfig
  Write-StubAz
}

function New-Repo([string]$Name, [string]$Branch) {
  $up = Join-Path $script:Root "$Name.git"
  $work = Join-Path $script:Root "$Name.work"
  $clone = Join-Path $script:Repos $Name
  Git $script:Root @('init', '-q', '--bare', $up) | Out-Null
  Git $up @('symbolic-ref', 'HEAD', 'refs/heads/main') | Out-Null
  Git $script:Root @('init', '-q', $work) | Out-Null
  Git $work @('config', 'user.email', 't@t.t') | Out-Null
  Git $work @('config', 'user.name', 'T') | Out-Null
  Set-Content -LiteralPath (Join-Path $work 'f.txt') -Value 'base'
  Git $work @('add', '-A') | Out-Null
  Git $work @('commit', '-qm', 'c1') | Out-Null
  Git $work @('branch', '-M', 'main') | Out-Null
  Git $work @('remote', 'add', 'origin', $up) | Out-Null
  Git $work @('push', '-q', '-u', 'origin', 'main') | Out-Null
  $baseSha = GitLine $work @('rev-parse', 'HEAD')
  Git $work @('checkout', '-q', '-b', $Branch) | Out-Null
  Add-Content -LiteralPath (Join-Path $work 'f.txt') -Value 'the change'
  Git $work @('commit', '-qam', 'the PR commit') | Out-Null
  $headSha = GitLine $work @('rev-parse', 'HEAD')
  Git $work @('push', '-q', 'origin', $Branch) | Out-Null
  Git $script:Root @('clone', '-q', $up, $clone) | Out-Null
  Git $clone @('config', 'user.email', 't@t.t') | Out-Null
  Git $clone @('config', 'user.name', 'T') | Out-Null
  return [pscustomobject]@{
    Name = $Name; Clone = $clone; Branch = $Branch; HeadSha = $headSha; BaseSha = $baseSha
  }
}

function Set-WorkItem([string]$Id, [string]$Title, [string[]]$PrIds) {
  $rels = @()
  foreach ($pr in $PrIds) { $rels += @{ rel = 'ArtifactLink'; url = "vstfs:///Git/PullRequestId/p%2Fr%2F$pr" } }
  $obj = @{
    id = [int]$Id
    fields = @{
      'System.Title' = $Title
      'System.WorkItemType' = 'Bug'
      'System.State' = 'Review'
      'System.TeamProject' = 'Fixture Project'
      'System.Description' = '<div>a change to review</div>'
      'System.AssignedTo' = @{ uniqueName = 'someone@example.com'; displayName = 'Someone' }
    }
    relations = $rels
  }
  Set-Content -LiteralPath (Join-Path $script:AzDir "wi-$Id.json") -Encoding utf8 `
    -Value ($obj | ConvertTo-Json -Depth 8)
  Set-Content -LiteralPath (Join-Path $script:AzDir "comments-$Id.json") -Encoding utf8 `
    -Value (@{ count = 0; totalCount = 0; comments = @() } | ConvertTo-Json -Depth 4)
}

function Set-Pr([string]$PrId, [string]$Repo, [string]$Author, [string]$Branch,
  [string]$HeadSha, [string]$BaseSha, [string]$Status) {
  $obj = @{
    pullRequestId = [int]$PrId
    title = "change in $Repo"
    status = $Status
    isDraft = $false
    repository = @{ name = $Repo }
    createdBy = @{ uniqueName = $Author; displayName = 'A Dev' }
    sourceRefName = "refs/heads/$Branch"
    targetRefName = 'refs/heads/main'
    lastMergeSourceCommit = @{ commitId = $HeadSha }
    lastMergeTargetCommit = @{ commitId = $BaseSha }
  }
  Set-Content -LiteralPath (Join-Path $script:AzDir "pr-$PrId.json") -Encoding utf8 `
    -Value ($obj | ConvertTo-Json -Depth 8)
}

# Make the PR unreadable to the stub, standing in for an expired token or a
# network failure - the case that must NOT be read as "finished".
function Hide-Pr([string]$PrId) {
  Remove-Item -LiteralPath (Join-Path $script:AzDir "pr-$PrId.json") -Force -ErrorAction SilentlyContinue
}

function Invoke-Script([string]$Script, [string[]]$ScriptArgs) {
  $envVars = @{
    WT_REVIEW_AZ = $script:Stub
    WT_REVIEW_SRC_ROOT = $script:Repos
    HERDR_CONFIG_PATH = $script:Cfg
    USERPROFILE = $script:Home2
  }
  $saved = @{}
  foreach ($k in $envVars.Keys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
    [Environment]::SetEnvironmentVariable($k, $envVars[$k])
  }
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @ScriptArgs 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
  } finally {
    $ErrorActionPreference = $prevEap
    foreach ($k in $envVars.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
}

function Invoke-Make([string]$Id) { return (Invoke-Script $MakeScript @($Id)) }
function Invoke-Remove([string[]]$A) { return (Invoke-Script $RemoveScript $A) }

# ===========================================================================
# herdr inspection / cleanup (matches on the fixture PATH, never on a label)
# ===========================================================================
function Get-AllWorkspaces {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $json = (& herdr workspace list 2>$null | Out-String)
    if (-not $json) { return @() }
    return @(($json | ConvertFrom-Json).result.workspaces)
  } catch { return @() } finally { $ErrorActionPreference = $prev }
}

function Get-WsCwds([string]$Ws) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $json = (& herdr pane list --workspace $Ws 2>$null | Out-String)
    if (-not $json) { return @() }
    return @(($json | ConvertFrom-Json).result.panes | ForEach-Object { "$($_.cwd)" })
  } catch { return @() } finally { $ErrorActionPreference = $prev }
}

function Close-Workspaces {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    foreach ($w in (Get-AllWorkspaces)) {
      if ($null -eq $w) { continue }
      $paths = if ($null -ne $w.worktree) {
        @("$($w.worktree.repo_root)", "$($w.worktree.checkout_path)")
      } else { Get-WsCwds $w.workspace_id }
      $isMine = $false
      foreach ($p in $paths) { if ($p -like "*$FixtureMarker*") { $isMine = $true } }
      if (-not $isMine) { continue }
      if ($null -ne $w.worktree) {
        & herdr worktree remove --workspace $w.workspace_id --force 2>$null | Out-Null
      }
      & herdr workspace close $w.workspace_id 2>$null | Out-Null
    }
  } catch { } finally { $ErrorActionPreference = $prev }
}

function Norm([string]$P) {
  if (-not $P) { return '' }
  return ($P -replace '\\+', '/').TrimEnd('/').ToLowerInvariant()
}

function Get-RowsAt([string]$Path) {
  $want = Norm $Path
  $found = @()
  foreach ($w in (Get-AllWorkspaces)) {
    if ($null -eq $w -or $null -ne $w.worktree) { continue }
    foreach ($c in (Get-WsCwds $w.workspace_id)) {
      if ((Norm $c) -eq $want) { $found += $w; break }
    }
  }
  return @($found)
}

function ReviewRoot { Join-Path $script:Trees 'review' }
function ReviewDir([string]$Id) { Join-Path (ReviewRoot) $Id }
function PrDir([string]$Id, [string]$Folder) { Join-Path (ReviewDir $Id) $Folder }

# Is $Path still a registered worktree of $Clone?
function Test-WorktreeRegistered([string]$Clone, [string]$Path) {
  $want = Norm $Path
  foreach ($line in (Git $Clone @('worktree', 'list', '--porcelain'))) {
    if ("$line" -match '^worktree\s+(.+)$') {
      if ((Norm $Matches[1].Trim()) -eq $want) { return $true }
    }
  }
  return $false
}

function Get-AzCalls {
  return @(Get-Content -LiteralPath $script:AzLog -ErrorAction SilentlyContinue | Where-Object { $_ })
}

function Clear-AzCalls {
  Remove-Item -LiteralPath $script:AzLog -Force -ErrorAction SilentlyContinue
}

function TreeToken($Ws) {
  if ($null -eq $Ws.tokens) { return '' }
  return "$($Ws.tokens.tree)"
}

# Every nested row starts from $TREE_INDENT - two blank columns leading with
# U+2800, since herdr trims leading whitespace and plain spaces would be eaten.
function WantToken([string]$Lead, [bool]$IsLast) {
  $c = if ($IsLast) { $TREE_ELL } else { $TREE_TEE }
  return "$TREE_INDENT$Lead$c"
}

# ===========================================================================
Write-Host ''
Write-Host '======== review-remove.ps1 opt-in checks (no Azure writes) ========'
Write-Host "fixture root: $Base"
$Baseline = @(Get-AllWorkspaces).Count
Write-Host "workspaces before: $Baseline"
Write-Host ''

# ---------------------------------------------------------------------------
Write-Host '1. the az guard refuses anything that is not a read'
$badCases = New-Object System.Collections.ArrayList
foreach ($c in @(
    , @('boards', 'work-item', 'update', '--id', '1', '--state', 'Closed')
    , @('repos', 'pr', 'set-vote', '--id', '1', '--vote', 'approve')
    , @('repos', 'pr', 'update', '--id', '1', '--status', 'abandoned')
    , @('devops', 'invoke', '--area', 'git', '--http-method', 'PATCH')
    , @('devops', 'invoke', '--area', 'git', '--in-file', 'x.json')
  )) { [void]$badCases.Add([string[]]$c) }
foreach ($bad in $badCases) {
  Check "refuses: az $($bad -join ' ')" (-not (Test-AzReadOnly $bad)) 'the guard allowed it'
}
Check 'allows: repos pr show' (Test-AzReadOnly @('repos', 'pr', 'show', '--id', '1', '-o', 'json')) 'blocked a read'
Check 'allows: boards work-item show' `
  (Test-AzReadOnly @('boards', 'work-item', 'show', '--id', '1', '--expand', 'relations')) 'blocked a read'
$AZ_CMD = 'cmd.exe'
$threw = $false
try { Invoke-AzRead @('repos', 'pr', 'set-vote', '--id', '1') } catch { $threw = $true }
Check 'Invoke-AzRead throws on a write instead of running it' $threw 'it did not throw'
# The bar for deleting a review: only a definite completion counts.
Check "'completed' is the only finished status by default" (($DONE_STATUS -join ',') -eq 'completed') `
  "DONE_STATUS = $($DONE_STATUS -join ',')"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '2. the owning clone is read out of the worktree, not guessed'
Reset-Fixture
$r = New-Repo 'repo-own' 'feature/dev/30100-a'
Set-WorkItem '30100' 'owner lookup' @('8001')
Set-Pr '8001' 'repo-own' 'dev.one@example.com' $r.Branch $r.HeadSha $r.BaseSha 'completed'
$res = Invoke-Make '30100'
Check 'review created' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
$pd = PrDir '30100' 'dev.one-repo-own'
Check 'the .git file points back at the clone' `
  ((Norm (Get-WorktreeOwner $pd)) -eq (Norm $r.Clone)) "got '$(Get-WorktreeOwner $pd)' want '$($r.Clone)'"
Check 'a path with no .git yields nothing rather than a guess' `
  ((Get-WorktreeOwner (Join-Path $script:Root 'nope')) -eq '') 'it returned something'
Check 'review-make left a PR index for removal to use' `
  (Test-Path -LiteralPath (Join-Path (ReviewDir '30100') 'review-30100-prs.json')) 'no index file'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '3. dry run reports the removal and changes nothing'
Clear-AzCalls
$res = Invoke-Remove @('30100', '--dry-run', '--yes')
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Check 'says it would remove the review' ($res.Out -match 'would delete') "output:`n$($res.Out)"
# A single-PR review is the case where PowerShell unwraps the array on return and
# .Count comes back $null, so every count printed blank. Assert the number.
Check 'counts the single PR correctly' ($res.Out -match '1 PR\(s\), from index') "output:`n$($res.Out)"
Check 'and says so in the reason' ($res.Out -match 'all 1 PR\(s\) finished') "output:`n$($res.Out)"
Check 'says the Review row is left alone' ($res.Out -match 'left open') "output:`n$($res.Out)"
Check 'the review folder is still there' (Test-Path -LiteralPath (ReviewDir '30100')) 'folder gone'
Check 'the worktree is still registered' (Test-WorktreeRegistered $r.Clone $pd) 'deregistered'
Check 'the rows are still open' (@(Get-RowsAt (ReviewDir '30100')).Count -eq 1) 'row closed'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '4. a completed PR is removed for real'
$rootRowsBefore = @(Get-RowsAt (ReviewRoot)).Count
Clear-AzCalls
$res = Invoke-Remove @('30100', '--yes')
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Check 'the review folder is gone' (-not (Test-Path -LiteralPath (ReviewDir '30100'))) 'folder remains'
Check 'the worktree was deregistered from the clone' (-not (Test-WorktreeRegistered $r.Clone $pd)) `
  "still listed: $(@(Git $r.Clone @('worktree','list')) -join ' | ')"
Check 'the review row was closed' (@(Get-RowsAt (ReviewDir '30100')).Count -eq 0) 'row still open'
Check 'the PR row was closed' (@(Get-RowsAt $pd).Count -eq 0) 'row still open'
Check 'the shared Review row was NOT closed' (@(Get-RowsAt (ReviewRoot)).Count -eq $rootRowsBefore) `
  'the Review root was closed'
Check "the clone itself is untouched and clean" `
  (@(Git $r.Clone @('status', '--porcelain') | Where-Object { $_ }).Count -eq 0) 'clone is dirty'
$calls = Get-AzCalls
$allRead = $true; $offender = ''
foreach ($c in $calls) {
  $argv = @($c -split ' ' | Where-Object { $_ })
  if (-not (Test-AzReadOnly $argv)) { $allRead = $false; $offender = $c }
}
Check 'every az call the removal made was a read' $allRead "offender: $offender"
Check 'it did ask Azure DevOps for the PR status' `
  (@($calls | Where-Object { $_ -match '^repos pr show --id 8001' }).Count -ge 1) `
  "calls: $($calls -join ' | ')"
Check 'it used the index, so it did not re-read the work item' `
  (@($calls | Where-Object { $_ -match '^boards work-item show' }).Count -eq 0) `
  "calls: $($calls -join ' | ')"
$res = Invoke-Remove @('30100', '--yes')
Check 'a second run says there is nothing local (exit 3)' ($res.Code -eq 3) "exit $($res.Code)`n$($res.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '5. one PR still active holds the whole review in place'
Reset-Fixture
$r1 = New-Repo 'repo-a' 'feature/dev/30200-a'
$r2 = New-Repo 'repo-b' 'feature/dev/30200-b'
Set-WorkItem '30200' 'two repos, one still open' @('8101', '8102')
Set-Pr '8101' 'repo-a' 'alice@example.com' $r1.Branch $r1.HeadSha $r1.BaseSha 'completed'
Set-Pr '8102' 'repo-b' 'bob@example.com' $r2.Branch $r2.HeadSha $r2.BaseSha 'active'
$res = Invoke-Make '30200'
Check 'review created' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
$res = Invoke-Remove @('30200', '--yes')
Check 'exit 3 (nothing ready)' ($res.Code -eq 3) "exit $($res.Code)`n$($res.Out)"
Check 'says how many are finished' ($res.Out -match 'holding: 1/2 finished') "output:`n$($res.Out)"
Check 'the finished half was NOT removed on its own' `
  (Test-Path -LiteralPath (PrDir '30200' 'alice-repo-a')) 'it removed half the review'
Check 'the review folder survives' (Test-Path -LiteralPath (ReviewDir '30200')) 'folder gone'
Check 'the rows survive' (@(Get-RowsAt (ReviewDir '30200')).Count -eq 1) 'row closed'

Write-Host ''
Write-Host '   and goes once the last PR completes'
Set-Pr '8102' 'repo-b' 'bob@example.com' $r2.Branch $r2.HeadSha $r2.BaseSha 'completed'
$res = Invoke-Remove @('30200', '--yes')
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Check 'the whole review is gone' (-not (Test-Path -LiteralPath (ReviewDir '30200'))) 'folder remains'
Check 'both worktrees were deregistered' `
  ((-not (Test-WorktreeRegistered $r1.Clone (PrDir '30200' 'alice-repo-a'))) -and
   (-not (Test-WorktreeRegistered $r2.Clone (PrDir '30200' 'bob-repo-b')))) 'one is still registered'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '6. a status that cannot be read is not treated as finished'
Reset-Fixture
$r = New-Repo 'repo-unk' 'feature/dev/30300-a'
Set-WorkItem '30300' 'unreadable status' @('8201')
Set-Pr '8201' 'repo-unk' 'dev@example.com' $r.Branch $r.HeadSha $r.BaseSha 'completed'
$res = Invoke-Make '30300'
Check 'review created' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Hide-Pr '8201'
$res = Invoke-Remove @('30300', '--yes')
Check 'exit 3 (kept)' ($res.Code -eq 3) "exit $($res.Code)`n$($res.Out)"
Check 'says the status was unreadable' ($res.Out -match 'unreadable') "output:`n$($res.Out)"
Check 'the review survives an outage' (Test-Path -LiteralPath (ReviewDir '30300')) 'it was removed anyway'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '7. abandoned is only finished when you say so'
Reset-Fixture
$r = New-Repo 'repo-ab' 'feature/dev/30400-a'
Set-WorkItem '30400' 'abandoned pr' @('8301')
Set-Pr '8301' 'repo-ab' 'dev@example.com' $r.Branch $r.HeadSha $r.BaseSha 'active'
$res = Invoke-Make '30400'
Check 'review created' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Set-Pr '8301' 'repo-ab' 'dev@example.com' $r.Branch $r.HeadSha $r.BaseSha 'abandoned'
$res = Invoke-Remove @('30400', '--yes')
Check 'exit 3 by default' ($res.Code -eq 3) "exit $($res.Code)`n$($res.Out)"
Check 'the review is kept by default' (Test-Path -LiteralPath (ReviewDir '30400')) 'removed by default'
$res = Invoke-Remove @('30400', '--yes', '--include-abandoned')
Check 'exit 0 with --include-abandoned' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Check 'and then it is removed' (-not (Test-Path -LiteralPath (ReviewDir '30400'))) 'still there'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '8. uncommitted changes hold a review back'
Reset-Fixture
$r = New-Repo 'repo-dirty' 'feature/dev/30500-a'
Set-WorkItem '30500' 'dirty checkout' @('8401')
Set-Pr '8401' 'repo-dirty' 'dev@example.com' $r.Branch $r.HeadSha $r.BaseSha 'completed'
$res = Invoke-Make '30500'
Check 'review created' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
$pd = PrDir '30500' 'dev-repo-dirty'
Add-Content -LiteralPath (Join-Path $pd 'f.txt') -Value 'a change someone made while reviewing'
$res = Invoke-Remove @('30500', '--yes')
Check 'exit 5 (held back)' ($res.Code -eq 5) "exit $($res.Code)`n$($res.Out)"
Check 'says what is uncommitted' ($res.Out -match 'HELD BACK: uncommitted changes') "output:`n$($res.Out)"
Check 'suggests the way out' ($res.Out -match '--force-dirty') "output:`n$($res.Out)"
Check 'the checkout is untouched' (Test-Path -LiteralPath $pd) 'it was removed anyway'
Check 'the change is still there' `
  ((Get-Content -LiteralPath (Join-Path $pd 'f.txt') -Raw) -match 'while reviewing') 'change lost'
$res = Invoke-Remove @('30500', '--yes', '--force-dirty')
Check 'exit 0 with --force-dirty' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Check 'and it warns that it discarded them' ($res.Out -match 'discarding uncommitted changes') "output:`n$($res.Out)"
Check 'the review is gone' (-not (Test-Path -LiteralPath (ReviewDir '30500'))) 'still there'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '9. notes you wrote are archived, not deleted'
Reset-Fixture
$r = New-Repo 'repo-notes' 'feature/dev/30600-a'
Set-WorkItem '30600' 'notes survive' @('8501')
Set-Pr '8501' 'repo-notes' 'dev@example.com' $r.Branch $r.HeadSha $r.BaseSha 'completed'
$res = Invoke-Make '30600'
Check 'review created' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
$notes = Join-Path (ReviewDir '30600') 'review-30600-notes.txt'
$prNotes = Join-Path (ReviewDir '30600') 'review-30600-dev-repo-notes-notes.txt'
Set-Content -LiteralPath $notes -Value 'the caching change looks wrong on retry' -Encoding utf8
Check 'the per-PR notes file starts out empty' `
  ((Test-Path -LiteralPath $prNotes) -and ((Get-Item -LiteralPath $prNotes).Length -eq 0)) 'not empty'
$res = Invoke-Remove @('30600', '--yes')
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
$archive = Join-Path (ReviewRoot) $NOTES_ARCHIVE
$kept = Join-Path $archive 'review-30600-notes.txt'
Check 'the notes with content were archived' (Test-Path -LiteralPath $kept) `
  "not at $kept; archive holds: $(@(Get-ChildItem -LiteralPath $archive -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ',')"
if (Test-Path -LiteralPath $kept) {
  Check 'with their contents intact' `
    ((Get-Content -LiteralPath $kept -Raw) -match 'wrong on retry') 'contents changed'
}
Check 'the empty notes file was not archived' `
  (-not (Test-Path -LiteralPath (Join-Path $archive 'review-30600-dev-repo-notes-notes.txt'))) `
  'an empty file was archived'
Check 'the review folder is gone' (-not (Test-Path -LiteralPath (ReviewDir '30600'))) 'still there'
Check 'the archive is not mistaken for a review' `
  (-not ($res.Out -match "work item $NOTES_ARCHIVE")) "output:`n$($res.Out)"

Write-Host ''
Write-Host '   --discard-notes opts out'
Set-WorkItem '30601' 'notes discarded' @('8502')
$r2 = New-Repo 'repo-notes2' 'feature/dev/30601-a'
Set-Pr '8502' 'repo-notes2' 'dev@example.com' $r2.Branch $r2.HeadSha $r2.BaseSha 'completed'
$res = Invoke-Make '30601'
Set-Content -LiteralPath (Join-Path (ReviewDir '30601') 'review-30601-notes.txt') -Value 'throwaway' -Encoding utf8
$res = Invoke-Remove @('30601', '--yes', '--discard-notes')
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Check 'says it discarded them' ($res.Out -match 'discarding notes') "output:`n$($res.Out)"
Check 'and they are not in the archive' `
  (-not (Test-Path -LiteralPath (Join-Path $archive 'review-30601-notes.txt'))) 'archived anyway'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '10. scanning them all: only the finished one goes, and the tree redraws'
Reset-Fixture
$ra = New-Repo 'repo-x' 'feature/dev/30700-a'
$rb = New-Repo 'repo-y' 'feature/dev/30800-a'
Set-WorkItem '30700' 'this one is done' @('8601')
Set-WorkItem '30800' 'this one is not' @('8602')
Set-Pr '8601' 'repo-x' 'dev@example.com' $ra.Branch $ra.HeadSha $ra.BaseSha 'completed'
Set-Pr '8602' 'repo-y' 'dev@example.com' $rb.Branch $rb.HeadSha $rb.BaseSha 'active'
$res = Invoke-Make '30700'
Check 'first review created' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
$res = Invoke-Make '30800'
Check 'second review created' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
$i2 = @(Get-RowsAt (ReviewDir '30800'))
Check 'before cleanup the second review has the corner' `
  ($i2.Count -eq 1 -and (TreeToken $i2[0]) -eq (WantToken '' $true)) `
  "token '$(if ($i2.Count) { TreeToken $i2[0] })'"
$i1 = @(Get-RowsAt (ReviewDir '30700'))
Check 'and the first has the tee' `
  ($i1.Count -eq 1 -and (TreeToken $i1[0]) -eq (WantToken '' $false)) `
  "token '$(if ($i1.Count) { TreeToken $i1[0] })'"
# No id argument: examine every review.
$res = Invoke-Remove @('--yes')
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Check 'it examined both' ($res.Out -match 'examined 2') "output:`n$($res.Out)"
Check 'the finished review is gone' (-not (Test-Path -LiteralPath (ReviewDir '30700'))) 'still there'
Check 'the unfinished one is untouched' (Test-Path -LiteralPath (ReviewDir '30800')) 'it was removed'
$i2 = @(Get-RowsAt (ReviewDir '30800'))
Check 'the survivor keeps exactly one row' ($i2.Count -eq 1) "count $($i2.Count)"
if ($i2.Count -eq 1) {
  # It held the tee while 30700 was still there; now it is the only review left,
  # so the corner has to move onto it or the tree points at a closed row.
  Check 'and is redrawn with the corner' ((TreeToken $i2[0]) -eq (WantToken '' $true)) `
    "token '$(TreeToken $i2[0])'"
}
$c2 = @(Get-RowsAt (PrDir '30800' 'dev-repo-y'))
if ($c2.Count -eq 1) {
  Check "the survivor's PR row is redrawn under it" `
    ((TreeToken $c2[0]) -eq (WantToken $TREE_GAP $true)) "token '$(TreeToken $c2[0])'"
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '10b. an unrelated row sitting in the review folder is left open'
# The shared Review row has a shell tab. cd it into the review folder and its pane
# sits at exactly the path the review's own row does - a cwd-only match would close
# it, on a scheduled run, with nobody watching.
Reset-Fixture
$r = New-Repo 'repo-guard' 'feature/dev/30950-a'
Set-WorkItem '30950' 'row guard' @('8801')
Set-Pr '8801' 'repo-guard' 'dev@example.com' $r.Branch $r.HeadSha $r.BaseSha 'completed'
$res = Invoke-Make '30950'
Check 'review created' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
# A workspace of someone else's, parked at the review directory.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$intruder = (& herdr workspace create --cwd (ReviewDir '30950') --label 'my-own-scratch' --no-focus 2>$null | Out-String | ConvertFrom-Json).result.workspace.workspace_id
$ErrorActionPreference = $prevEap
Check 'the unrelated row was created for the check' ([bool]$intruder) 'could not create it'
$pdGuard = PrDir '30950' 'dev-repo-guard'
$res = Invoke-Remove @('30950', '--yes')
# Held back, NOT removed: that pane holds an open handle on the folder, so the
# delete would fail after the rows were already closed and the worktree already
# deregistered - the half-removed state this script exists to avoid.
Check 'exit 5 (held back)' ($res.Code -eq 5) "exit $($res.Code)`n$($res.Out)"
Check 'it names the workspace in the way' ($res.Out -match 'another workspace is parked') "output:`n$($res.Out)"
Check 'and says what to do about it' ($res.Out -match 'cd it somewhere else') "output:`n$($res.Out)"
Check 'nothing was half-removed: the folder is intact' (Test-Path -LiteralPath (ReviewDir '30950')) 'folder gone'
Check 'nothing was half-removed: the worktree is still registered' `
  (Test-WorktreeRegistered $r.Clone $pdGuard) 'deregistered anyway'
# Matched by label, not by count: the intruder was parked at this very path, so
# two rows legitimately sit here and a count of 1 would be the wrong assertion.
Check "nothing was half-removed: the review's own row is still open" `
  (@(Get-RowsAt (ReviewDir '30950') | Where-Object { $_.label -eq '30950' }).Count -eq 1) `
  "rows here: $(@(Get-RowsAt (ReviewDir '30950') | ForEach-Object { "[$($_.label)]" }) -join ' ')"
$stillThere = @(Get-AllWorkspaces | Where-Object { "$($_.workspace_id)" -eq $intruder })
Check 'and the unrelated row is still open' ($stillThere.Count -eq 1) 'it was closed'

Write-Host ''
Write-Host '   and goes once that workspace is out of the way'
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& herdr workspace close $intruder 2>$null | Out-Null
$ErrorActionPreference = $prevEap
Start-Sleep -Milliseconds 500
$res = Invoke-Remove @('30950', '--yes')
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Check 'the review is gone' (-not (Test-Path -LiteralPath (ReviewDir '30950'))) 'still there'
Check 'and the worktree was deregistered' (-not (Test-WorktreeRegistered $r.Clone $pdGuard)) 'still registered'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '11. a review with no PR index and no readable work item is left alone'
Reset-Fixture
$r = New-Repo 'repo-orphan' 'feature/dev/30900-a'
Set-WorkItem '30900' 'orphan' @('8701')
Set-Pr '8701' 'repo-orphan' 'dev@example.com' $r.Branch $r.HeadSha $r.BaseSha 'completed'
$res = Invoke-Make '30900'
Check 'review created' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Remove-Item -LiteralPath (Join-Path (ReviewDir '30900') 'review-30900-prs.json') -Force
Remove-Item -LiteralPath (Join-Path $script:AzDir 'wi-30900.json') -Force
$res = Invoke-Remove @('30900', '--yes')
Check 'exit 3 (left alone)' ($res.Code -eq 3) "exit $($res.Code)`n$($res.Out)"
Check 'says it cannot tell which PRs it covers' ($res.Out -match 'cannot tell which PRs') "output:`n$($res.Out)"
Check 'the folder survives' (Test-Path -LiteralPath (ReviewDir '30900')) 'it was removed'

Write-Host ''
Write-Host '   but re-derives from the work item when only the index is missing'
Set-WorkItem '30900' 'orphan' @('8701')
Set-Pr '8701' 'repo-orphan' 'dev@example.com' $r.Branch $r.HeadSha $r.BaseSha 'completed'
Clear-AzCalls
$res = Invoke-Remove @('30900', '--yes')
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Check 'it says the PRs came from Azure, not the index' ($res.Out -match 'from azure') "output:`n$($res.Out)"
Check 'so it had to read the work item' `
  (@(Get-AzCalls | Where-Object { $_ -match '^boards work-item show' }).Count -ge 1) 'never read it'
Check 'the review is gone' (-not (Test-Path -LiteralPath (ReviewDir '30900'))) 'still there'

# ===========================================================================
Write-Host ''
Write-Host '12. cleanup leaves your session as it was'
Close-Workspaces
Start-Sleep -Milliseconds 500
$after = @(Get-AllWorkspaces).Count
# Only an INCREASE can be a leak. The count legitimately drops if you close a
# workspace of your own while this is running.
Check "no net new workspaces (baseline $Baseline)" ($after -le $Baseline) "now $after"
if ($after -lt $Baseline) { Write-Host "  (count fell to $after - a workspace was closed during the run)" }
$leaked = @(Get-AllWorkspaces | Where-Object {
    $paths = if ($null -ne $_.worktree) { @("$($_.worktree.checkout_path)") } else { Get-WsCwds $_.workspace_id }
    $hit = $false
    foreach ($p in $paths) { if ($p -like "*$FixtureMarker*") { $hit = $true } }
    $hit
  })
Check 'no fixture workspace left open' ($leaked.Count -eq 0) `
  "leaked: $(@($leaked | ForEach-Object { $_.workspace_id }) -join ',')"

Get-ChildItem -LiteralPath $Base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
  $repoRoot = Join-Path $_.FullName 'repos'
  if (Test-Path -LiteralPath $repoRoot) {
    Get-ChildItem -LiteralPath $repoRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      Git $_.FullName @('worktree', 'prune') | Out-Null
    }
  }
}
foreach ($attempt in 1, 2, 3) {
  Remove-Item -LiteralPath $Base -Recurse -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $Base)) { break }
  Start-Sleep -Milliseconds 400
}
if (Test-Path -LiteralPath $Base) {
  Write-Warning "could not delete the fixture directory (herdr may still hold a handle): $Base"
} else {
  Write-Host "  fixture directory removed: $Base"
}

Write-Host ''
Write-Host "PASS: $($script:Pass)   FAIL: $($script:Fail)"
if ($script:Fail -gt 0) {
  Write-Host 'failed:'
  foreach ($n in $script:Names) { Write-Host "  - $n" }
  exit 1
}
exit 0
