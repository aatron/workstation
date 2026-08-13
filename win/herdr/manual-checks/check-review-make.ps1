# check-review-make.ps1 - OPT-IN checks for win/herdr/review-make.ps1
#
# NOT A TEST FILE. Deliberately not named test-*.ps1 and deliberately not in
# tests/, so that nothing sweeping this repo for tests picks it up. Run it by
# hand, on purpose:
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File check-review-make.ps1
#
# See README.md in this folder for why.
#
# WHAT IT TOUCHES
#   Azure DevOps  nothing. Every scenario runs review-make.ps1 against a STUB az
#                 (WT_REVIEW_AZ), which serves canned JSON from disk and logs
#                 every argument list it is handed. One check reads that log back
#                 and fails if anything but a read command was issued. There is
#                 no network call and no credential use anywhere in this file.
#   git           throwaway repos under %TEMP%\herdr-review-checks\<pid>\ only.
#   herdr         creates workspaces in your live session and closes them again.
#                 Matching for cleanup is on the fixture path, never on a label,
#                 so your own workspaces are never touched. The final check
#                 asserts the workspace count is back where it started.
#   your files    none.
#
$ErrorActionPreference = 'Stop'

$FixtureMarker = 'herdr-review-checks'
$Base = Join-Path ([IO.Path]::GetTempPath()) "$FixtureMarker\$PID"
$RealScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'review-make.ps1'
$script:Run = 0
$script:Pass = 0
$script:Fail = 0
$script:Names = @()
$Root = ''; $Repos = ''; $Trees = ''; $Cfg = ''; $Stub = ''; $AzLog = ''; $Home2 = ''

if (-not (Test-Path -LiteralPath $RealScript)) {
  Write-Error "cannot find review-make.ps1 next to this folder: $RealScript"
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

# ===========================================================================
# Load review-make.ps1's functions and configuration WITHOUT running it.
#
# The file is a script, not a module, so dot-sourcing it would execute the whole
# review. Instead its AST is walked and only two kinds of top-level statement are
# taken: function definitions (inert) and the named configuration assignments
# below (all literals). Nothing else is evaluated, so no az call, no git call and
# no herdr call can happen as a side effect of loading.
#
# Taking the values from the real file rather than restating them here is the
# point: a check that hard-coded its own copy of $AZ_READ_ONLY would keep passing
# after someone widened the real one.
# ===========================================================================
$WantedConfig = @(
  'AZ_READ_ONLY', 'REVIEW_MODEL', 'REVIEW_PERMISSION_MODE', 'REVIEW_DISALLOWED_TOOLS'
  'REVIEW_PR_STATUS', 'ROOT_TABS', 'REVIEW_TABS', 'PROMPT_MAX_CHARS'
  'TREE_TEE', 'TREE_ELL', 'TREE_PIPE', 'TREE_GAP', 'TREE_INDENT', 'TREE_CHARS'
  'PROMPT_CANDIDATES'
)

function Get-ReviewLibText {
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($RealScript, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count -gt 0) {
    throw "review-make.ps1 does not parse: $($errs[0].Message) (line $($errs[0].Extent.StartLineNumber))"
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

$LibText = Get-ReviewLibText
# At script scope on purpose: inside a function these would be local and the
# checks below could not see them.
Invoke-Expression $LibText

# ===========================================================================
# Fixture
# ===========================================================================
function Write-FixtureConfig([switch]$NoTreeToken) {
  # TOML basic string, backslashes escaped exactly as the README tells the user
  # to write them: directory = "C:\\Users\\me\\source\\worktrees"
  $lines = @(
    '[worktrees]'
    ('directory = "' + $script:Trees.Replace('\', '\\') + '"')
  )
  if (-not $NoTreeToken) {
    $lines += @(
      '[ui.sidebar.spaces]'
      'rows = [["$tree", "state_icon", "workspace"]]'
    )
  }
  Set-Content -LiteralPath $script:Cfg -Encoding utf8 -Value $lines
}

# The stub az. Serves whatever JSON the scenario wrote into $Root\az\, and
# appends every argument list it is given to az-calls.log so a check can prove
# only reads were issued.
function Write-StubAz {
  $body = @'
# STUB az - test double for check-review-make.ps1. Reads canned JSON, never talks
# to a network. Logs its argv so the checks can assert read-only behaviour.
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
  # A clean HOME so prompt discovery is deterministic: without it the result
  # would depend on whether the machine happens to have ~/.claude/commands/review.md.
  $script:Home2 = Join-Path $script:Root 'home'
  $Root = $script:Root; $Repos = $script:Repos; $Trees = $script:Trees; $Cfg = $script:Cfg
  New-Item -ItemType Directory -Force -Path $Root, $Repos, $Trees, $script:AzDir, $script:Home2 | Out-Null
  Write-FixtureConfig
  Write-StubAz
}

# upstream bare repo + a clone under $Repos, with a feature branch on top.
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
  Add-Content -LiteralPath (Join-Path $work 'f.txt') -Value 'the change under review'
  Git $work @('commit', '-qam', 'the PR commit') | Out-Null
  $headSha = GitLine $work @('rev-parse', 'HEAD')
  Git $work @('push', '-q', 'origin', $Branch) | Out-Null
  Git $script:Root @('clone', '-q', $up, $clone) | Out-Null
  Git $clone @('config', 'user.email', 't@t.t') | Out-Null
  Git $clone @('config', 'user.name', 'T') | Out-Null
  return [pscustomobject]@{
    Name = $Name; Up = $up; Clone = $clone; Branch = $Branch
    HeadSha = $headSha; BaseSha = $baseSha
  }
}

# --- canned Azure DevOps payloads -----------------------------------------
function Set-WorkItem([string]$Id, [string]$Title, [string]$Type, [hashtable]$Fields, [string[]]$PrIds) {
  $rels = @()
  foreach ($pr in $PrIds) {
    # Exercise both encodings the service uses for the separators.
    $sep = if ($rels.Count % 2 -eq 0) { '%2F' } else { '%2f' }
    $rels += @{
      rel = 'ArtifactLink'
      url = "vstfs:///Git/PullRequestId/proj-guid${sep}repo-guid${sep}$pr"
    }
  }
  # A build link and a commit link too: they must be ignored, not parsed as PRs.
  $rels += @{ rel = 'ArtifactLink'; url = 'vstfs:///Build/Build/20603' }
  $rels += @{ rel = 'ArtifactLink'; url = 'vstfs:///Git/Commit/a%2Fb%2Fdeadbeef' }
  $f = @{
    'System.Title' = $Title
    'System.WorkItemType' = $Type
    'System.State' = 'Review'
    'System.TeamProject' = 'Fixture Project'
    'System.AssignedTo' = @{ uniqueName = 'someone.else@example.com'; displayName = 'Someone Else' }
  }
  foreach ($k in $Fields.Keys) { $f[$k] = $Fields[$k] }
  $obj = @{ id = [int]$Id; fields = $f; relations = $rels }
  Set-Content -LiteralPath (Join-Path $script:AzDir "wi-$Id.json") -Encoding utf8 `
    -Value ($obj | ConvertTo-Json -Depth 8)
}

function Set-Pr([string]$PrId, [string]$Repo, [string]$Author, [string]$Display,
  [string]$Branch, [string]$HeadSha, [string]$BaseSha, [string]$Status = 'completed') {
  $obj = @{
    pullRequestId = [int]$PrId
    title = "fix the thing in $Repo"
    status = $Status
    isDraft = $false
    repository = @{ name = $Repo }
    createdBy = @{ uniqueName = $Author; displayName = $Display }
    sourceRefName = "refs/heads/$Branch"
    targetRefName = 'refs/heads/main'
    lastMergeSourceCommit = @{ commitId = $HeadSha }
    lastMergeTargetCommit = @{ commitId = $BaseSha }
  }
  Set-Content -LiteralPath (Join-Path $script:AzDir "pr-$PrId.json") -Encoding utf8 `
    -Value ($obj | ConvertTo-Json -Depth 8)
}

function Set-Comments([string]$Id, [string[]]$Texts) {
  $list = @()
  foreach ($t in $Texts) {
    $list += @{
      text = $t
      createdDate = '2026-08-01T00:00:00Z'
      createdBy = @{ displayName = 'Commenter One'; uniqueName = 'commenter.one@example.com' }
    }
  }
  $obj = @{ count = $list.Count; totalCount = $list.Count; comments = $list }
  Set-Content -LiteralPath (Join-Path $script:AzDir "comments-$Id.json") -Encoding utf8 `
    -Value ($obj | ConvertTo-Json -Depth 8)
}

function Invoke-Review([string]$Id, [hashtable]$Extra) {
  $envVars = @{
    WT_REVIEW_AZ = $script:Stub
    WT_REVIEW_SRC_ROOT = $script:Repos
    HERDR_CONFIG_PATH = $script:Cfg
    USERPROFILE = $script:Home2
  }
  if ($null -ne $Extra) { foreach ($k in $Extra.Keys) { $envVars[$k] = $Extra[$k] } }
  $saved = @{}
  foreach ($k in $envVars.Keys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
    [Environment]::SetEnvironmentVariable($k, $envVars[$k])
  }
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RealScript $Id 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
  } finally {
    $ErrorActionPreference = $prevEap
    foreach ($k in $envVars.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
}

# ===========================================================================
# herdr inspection / cleanup
#
# Matching is on the FIXTURE PATH, never on a label: herdr does not always keep
# the label we passed, and a label filter would risk closing one of the user's
# own workspaces. The marker cannot appear in a real repo or worktree.
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
      $paths = @()
      if ($null -ne $w.worktree) {
        $paths = @("$($w.worktree.repo_root)", "$($w.worktree.checkout_path)")
      } else {
        $paths = Get-WsCwds $w.workspace_id
      }
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

# Plain (non-worktree) workspaces whose panes sit exactly at $Path.
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

function Get-TabLabels([string]$Ws) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $json = (& herdr tab list --workspace $Ws 2>$null | Out-String)
    if (-not $json) { return @() }
    return @(($json | ConvertFrom-Json).result.tabs | ForEach-Object { "$($_.label)" })
  } catch { return @() } finally { $ErrorActionPreference = $prev }
}

# The connector review-make.ps1 reports as a row's $tree token. It renders to the
# left of the status bullet, which is the whole point - herdr also inserts its own
# " . " between the two and offers no way to suppress it, which is accepted.
function TreeToken($Ws) {
  if ($null -eq $Ws.tokens) { return '' }
  return "$($Ws.tokens.tree)"
}
function HasTreeToken($Ws) {
  return [bool](TreeToken $Ws)
}

# The token a row at this position should be carrying. Every nested row starts
# from $TREE_INDENT - two blank columns leading with U+2800, since herdr trims
# leading whitespace and plain spaces would be silently eaten.
function WantToken([string]$Lead, [bool]$IsLast) {
  $c = if ($IsLast) { $TREE_ELL } else { $TREE_TEE }
  return "$TREE_INDENT$Lead$c"
}

function ReviewDir([string]$Id) { Join-Path (Join-Path $script:Trees 'review') $Id }
function PrDir([string]$Id, [string]$Folder) { Join-Path (ReviewDir $Id) $Folder }

# ===========================================================================
Write-Host ''
Write-Host '=========== review-make.ps1 opt-in checks (no Azure writes) ==========='
Write-Host "fixture root: $Base"
$Baseline = @(Get-AllWorkspaces).Count
Write-Host "workspaces before: $Baseline"
Write-Host ''

# ---------------------------------------------------------------------------
Write-Host '1. the az guard refuses anything that is not a read'
# An ArrayList, not an array literal: @( @('a','b'), @('c') ) FLATTENS in
# PowerShell, so each case would arrive as a single word. A one-word command path
# is not on the allowlist, so every "refuses" check would have passed for the
# wrong reason - which is exactly what happened the first time this ran.
#
# Built inline rather than returned from a helper: `return $someEmptyArrayList`
# unrolls the collection into the pipeline, so the caller gets $null.
$badCases = New-Object System.Collections.ArrayList
foreach ($c in @(
    , @('boards', 'work-item', 'update', '--id', '1', '--state', 'Done')
    , @('repos', 'pr', 'set-vote', '--id', '1', '--vote', 'approve')
    , @('repos', 'pr', 'update', '--id', '1', '--status', 'completed')
    , @('repos', 'pr', 'reviewer', 'add', '--id', '1')
    , @('boards', 'work-item', 'relation', 'add', '--id', '1')
    , @('boards', 'work-item', 'delete', '--id', '1')
    , @('repos', 'pr', 'create', '--title', 'x')
    , @('devops', 'invoke', '--area', 'wit', '--http-method', 'PATCH')
    , @('devops', 'invoke', '--area', 'wit', '--http-method=POST')
    , @('devops', 'invoke', '--area', 'wit', '--in-file', 'x.json')
    , @('devops', 'invoke', '--area', 'wit', '--body', '{}')
  )) { [void]$badCases.Add([string[]]$c) }
foreach ($bad in $badCases) {
  Check "refuses: az $($bad -join ' ')" (-not (Test-AzReadOnly $bad)) 'the guard allowed it'
}
$goodCases = New-Object System.Collections.ArrayList
foreach ($c in @(
    , @('boards', 'work-item', 'show', '--id', '23597', '--expand', 'relations', '-o', 'json')
    , @('repos', 'pr', 'show', '--id', '6526', '-o', 'json')
    , @('repos', 'pr', 'work-item', 'list', '--id', '6526', '-o', 'json')
    , @('devops', 'invoke', '--area', 'wit', '--resource', 'comments', '--api-version', '7.1-preview')
    , @('devops', 'invoke', '--area', 'wit', '--http-method', 'GET')
  )) { [void]$goodCases.Add([string[]]$c) }
foreach ($good in $goodCases) {
  Check "allows: az $($good -join ' ')" (Test-AzReadOnly $good) 'the guard blocked a read'
}
# The guard must also be wired into the call path, not merely available.
$AZ_CMD = 'cmd.exe'
$threw = $false
try { Invoke-AzRead @('boards', 'work-item', 'update', '--id', '1') } catch { $threw = $true }
Check 'Invoke-AzRead throws on a write instead of running it' $threw 'it did not throw'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '2. work item HTML is flattened, not dumped'
$html = '<div><b>Steps:</b></div><div><ol><li>one</li><li>two</li></ol></div>' +
  '<div>a&nbsp;b &amp; c</div><div><img src="http://x/y?fileName=image.png" alt=Image><br></div>'
$flat = ConvertFrom-Html $html
Check 'tags are gone' ($flat -notmatch '<[a-zA-Z/]') "got: $flat"
Check 'list items survive as bullets' ($flat -match '- one' -and $flat -match '- two') "got: $flat"
Check 'entities are decoded' ($flat -match 'a b & c') "got: $flat"
Check 'an image is named, not silently dropped' ($flat -match '\[image: image\.png\]') "got: $flat"
Check 'no run of 3+ blank lines' ($flat -notmatch "`n`n`n") 'blank line runs remain'
Check 'empty in, empty out' ((ConvertFrom-Html '') -eq '') 'not empty'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '3. PR ids come off the work item links, and only PR links'
$fake = [pscustomobject]@{
  relations = @(
    [pscustomobject]@{ url = 'vstfs:///Git/PullRequestId/p%2Fr%2F6526' }
    [pscustomobject]@{ url = 'vstfs:///Git/PullRequestId/p%2fr%2f6527' }
    [pscustomobject]@{ url = 'vstfs:///Git/PullRequestId/p%2Fr%2F6526' }
    [pscustomobject]@{ url = 'vstfs:///Build/Build/20603' }
    [pscustomobject]@{ url = 'vstfs:///Git/Commit/p%2Fr%2Fabc123' }
  )
}
$ids = @(Get-LinkedPrIds $fake)
Check 'both encodings parsed, duplicate dropped' (($ids -join ',') -eq '6526,6527') "got: $($ids -join ',')"
Check 'no links at all yields nothing' (@(Get-LinkedPrIds ([pscustomobject]@{ relations = $null })).Count -eq 0) 'found something'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '4. folder naming'
$sampleRepo = 'My Repo'
$sampleRepoDir = 'My_Repo'
$sampleEmail = 'Alice.Smith@example.com'
$sampleAuthor = 'alice.smith'  # expected from uniqueName
$sampleDisplay = 'Alice Smith'
$sampleDisplaySlug = 'alice-smith'  # expected from displayName fallback

Check 'repo spaces become underscores' ((Get-LocalRepoDir $sampleRepo) -eq $sampleRepoDir) `
  "got: $(Get-LocalRepoDir $sampleRepo)"
Check 'author is the lowercased local part' `
  ((Get-AuthorName ([pscustomobject]@{ uniqueName = $sampleEmail })) -eq $sampleAuthor) `
  "got: $(Get-AuthorName ([pscustomobject]@{ uniqueName = $sampleEmail }))"
Check 'falls back to the display name' `
  ((Get-AuthorName ([pscustomobject]@{ displayName = $sampleDisplay })) -eq $sampleDisplaySlug) `
  "got: $(Get-AuthorName ([pscustomobject]@{ displayName = $sampleDisplay }))"
Check 'path separators cannot escape the folder name' `
  ((Sanitize-Segment 'a/../b\c') -notmatch '[\\/]') "got: $(Sanitize-Segment 'a/../b\c')"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '5. one PR: detached worktree, three rows, read-only throughout'
Reset-Fixture
$repoName = 'My Repo'
$repoDir = 'My_Repo'
$authorEmail = 'alice.smith@example.com'
$authorDisplay = 'Alice Smith'
$authorLocal = 'alice.smith'
$workItemId = '23597'
$prId = '6526'
$wiTitle = 'Mono repo - fix extra calls to the API'
$branch = 'feature/someone/23597-api-fix'
$prFolder = "$authorLocal-$repoDir"

$repo = New-Repo $repoDir $branch
Set-WorkItem $workItemId $wiTitle 'Bug' @{
  'Microsoft.VSTS.TCM.ReproSteps' = '<div><b>Steps to reproduce:</b></div><div><ol><li>Open browser tools</li></ol></div>'
} @($prId)
Set-Pr $prId $repoName $authorEmail $authorDisplay $repo.Branch $repo.HeadSha $repo.BaseSha
Set-Comments $workItemId @('<div>Please look at the caching.</div>')
$cloneCommitsBefore = (GitLine $repo.Clone @('rev-list', '--all', '--count'))
$cloneHeadBefore = (GitLine $repo.Clone @('rev-parse', 'HEAD'))

$res = Invoke-Review $workItemId $null
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
$prDir = PrDir $workItemId $prFolder
Check 'checkout at review\{id}\{author}-{repo}' (Test-Path -LiteralPath (Join-Path $prDir '.git')) "missing $prDir"
Check 'HEAD is the PR head commit' ((GitLine $prDir @('rev-parse', 'HEAD')) -eq $repo.HeadSha) `
  "got $(GitLine $prDir @('rev-parse','HEAD')) want $($repo.HeadSha)"
Check 'HEAD is DETACHED (no branch to commit onto)' `
  (-not (GitLine $prDir @('symbolic-ref', '-q', 'HEAD'))) `
  "on branch $(GitLine $prDir @('symbolic-ref','-q','HEAD'))"
Check 'no local branch was created for the PR' `
  (@(Git $repo.Clone @('branch', '--list', $repo.Branch) | Where-Object { $_ }).Count -eq 0) `
  'a local branch exists'
Check 'no upstream was configured' `
  (-not (GitLine $prDir @('config', "branch.$($repo.Branch).remote"))) 'an upstream is set'
Check 'no commits were added to the clone' `
  ((GitLine $repo.Clone @('rev-list', '--all', '--count')) -eq $cloneCommitsBefore) 'commit count changed'
Check "the clone's own HEAD did not move" `
  ((GitLine $repo.Clone @('rev-parse', 'HEAD')) -eq $cloneHeadBefore) 'HEAD moved'
Check 'the checkout is clean (no generated files inside it)' `
  (@(Git $prDir @('status', '--porcelain') | Where-Object { $_ }).Count -eq 0) `
  "dirty: $(@(Git $prDir @('status','--porcelain')) -join '; ')"

# --- what the stub was asked for ---
$calls = @(Get-Content -LiteralPath $script:AzLog -ErrorAction SilentlyContinue | Where-Object { $_ })
Check 'the stub az was actually used' ($calls.Count -ge 2) "calls: $($calls.Count)"
$allRead = $true
$offender = ''
foreach ($c in $calls) {
  $argv = @($c -split ' ' | Where-Object { $_ })
  if (-not (Test-AzReadOnly $argv)) { $allRead = $false; $offender = $c }
}
Check 'every az call issued was a read' $allRead "offender: $offender"
Check 'the work item was read' (@($calls | Where-Object { $_ -match '^boards work-item show' }).Count -ge 1) 'not read'
Check 'the comments were read' (@($calls | Where-Object { $_ -match 'resource comments' }).Count -ge 1) 'not read'

# --- context file ---
$ctx = Join-Path (ReviewDir $workItemId) "review-$workItemId-context.md"
Check 'context file written at the review root' (Test-Path -LiteralPath $ctx) "missing $ctx"
$ctxText = if (Test-Path -LiteralPath $ctx) { Get-Content -LiteralPath $ctx -Raw } else { '' }
Check 'context has the work item title' ($ctxText -match [regex]::Escape($wiTitle)) 'title missing'
Check 'context has the flattened description' ($ctxText -match 'Open browser tools') 'description missing'
Check 'context has no raw HTML left in it' ($ctxText -notmatch '<div>') 'raw html present'
Check 'context has the comment and its author' `
  ($ctxText -match 'Please look at the caching' -and $ctxText -match 'Commenter One') 'comment missing'
Check 'context names the PR and its author' `
  ($ctxText -match $prId -and $ctxText -match [regex]::Escape($authorDisplay)) 'PR details missing'
Check 'context gives a diff command' ($ctxText -match 'git diff [0-9a-f]{6,} [0-9a-f]{6,}') 'no diff command'
# Not just present - it has to RUN. The first version of this emitted three-dot
# syntax unconditionally, which dies with "fatal: no merge base" whenever the two
# commits were fetched by sha without enough shared ancestry - a broken command in
# the one file the reviewer is told to start from.
$diffCmd = ''
if ($ctxText -match 'git diff ([0-9a-f]{6,}) ([0-9a-f]{6,})') {
  $diffCmd = @($Matches[1], $Matches[2])
}
if ($diffCmd) {
  $out = @(Git $prDir (@('diff', '--stat') + $diffCmd))
  Check 'and the diff command actually succeeds' ($global:GX -eq 0) "git exit $($global:GX)"
  Check 'and it shows the change' (@($out | Where-Object { $_ }).Count -gt 0) 'empty diff'
} else {
  Check 'a runnable diff command was emitted' $false "context:`n$ctxText"
}
Check 'no three-dot diff is emitted' ($ctxText -notmatch 'git diff [0-9a-f]+\.\.\.') `
  'three-dot syntax present - it fails when there is no merge base'

# --- prompt file ---
$prompt = Join-Path (ReviewDir $workItemId) "review-$workItemId-$prFolder-prompt.md"
Check 'per-PR prompt file written' (Test-Path -LiteralPath $prompt) "missing $prompt"
$pText = if (Test-Path -LiteralPath $prompt) { Get-Content -LiteralPath $prompt -Raw } else { '' }
Check 'prompt forbids editing files' ($pText -match 'Do NOT create, edit, delete') 'no edit constraint'
Check 'prompt forbids commit and push' ($pText -match 'git commit' -and $pText -match 'git push') 'no git constraint'
Check 'prompt forbids changing Azure DevOps' ($pText -match 'Do NOT change anything in Azure DevOps') 'no ADO constraint'
Check 'prompt outranks repo instructions explicitly' ($pText -match 'does not apply here') 'no precedence statement'
Check 'prompt is the adversarial default' ($pText -match 'adversarial review') 'not the default prompt'
Check 'prompt carries the DevOps context' ($pText -match 'Open browser tools') 'context not appended'
Check 'output section asks for findings only' ($pText -match 'described, not applied') 'no output constraint'
Check 'no review prompt was found, and it said so' `
  ($res.Out -match 'no review prompt found') "output:`n$($res.Out)"

# --- the sidebar tree ---
$rootRows = @(Get-RowsAt (Join-Path $script:Trees 'review'))
$itemRows = @(Get-RowsAt (ReviewDir $workItemId))
$prRows = @(Get-RowsAt $prDir)
Check 'exactly one Review root row' ($rootRows.Count -eq 1) "count $($rootRows.Count)"
Check 'the root row is labelled Review' ($rootRows.Count -eq 1 -and $rootRows[0].label -eq 'Review') `
  "label '$(if ($rootRows.Count) { $rootRows[0].label })'"
Check 'exactly one row for the work item' ($itemRows.Count -eq 1) "count $($itemRows.Count)"
Check 'the item row is labelled with the bare id' `
  ($itemRows.Count -eq 1 -and $itemRows[0].label -eq $workItemId) `
  "label '$(if ($itemRows.Count) { $itemRows[0].label })'"
Check 'the item row is the only review, so it gets the corner' `
  ($itemRows.Count -eq 1 -and (TreeToken $itemRows[0]) -eq (WantToken '' $true)) `
  "token '$(if ($itemRows.Count) { TreeToken $itemRows[0] })'"
Check 'exactly one row for the PR' ($prRows.Count -eq 1) "count $($prRows.Count)"
Check 'the PR row is labelled {author}-{repo}' `
  ($prRows.Count -eq 1 -and $prRows[0].label -eq $prFolder) `
  "label '$(if ($prRows.Count) { $prRows[0].label })'"
# The bug this caught: herdr trims leading whitespace off a token, so a plain
# three-space lead collapsed the PR row onto its review's own indent level.
Check 'the PR row is indented one level past its review' `
  ($prRows.Count -eq 1 -and (TreeToken $prRows[0]) -eq (WantToken $TREE_GAP $true)) `
  "token '$(if ($prRows.Count) { TreeToken $prRows[0] })' want '$(WantToken $TREE_GAP $true)'"
# 2 (base indent) + 3 (clearing the review's connector) + 2 (own connector).
# Asserted as a length as well as a value, because the failure mode is silent
# truncation of the leading blanks rather than a wrong glyph.
Check "the PR row's indent survived herdr's token trim" `
  ($prRows.Count -eq 1 -and (TreeToken $prRows[0]).Length -eq 7) `
  "length $(if ($prRows.Count) { (TreeToken $prRows[0]).Length }) want 7"
Check "the review row's indent survived too" `
  ($itemRows.Count -eq 1 -and (TreeToken $itemRows[0]).Length -eq 4) `
  "length $(if ($itemRows.Count) { (TreeToken $itemRows[0]).Length }) want 4"
if ($rootRows.Count -eq 1) {
  Check 'root row tabs are just the shell' `
    ((@(Get-TabLabels $rootRows[0].workspace_id) -join ',') -eq ($ROOT_TABS -join ',')) `
    "tabs: $(@(Get-TabLabels $rootRows[0].workspace_id) -join ',')"
  # No token means no segment, which is also why the trunk shows no separator dot.
  Check 'the trunk carries no connector' (-not (HasTreeToken $rootRows[0])) `
    "token '$(TreeToken $rootRows[0])'"
}
$wantTabs = (($REVIEW_TABS | Sort-Object) -join ',')
if ($itemRows.Count -eq 1) {
  Check 'item row has notes + Claude Review' `
    (((@(Get-TabLabels $itemRows[0].workspace_id) | Sort-Object) -join ',') -eq $wantTabs) `
    "tabs: $(@(Get-TabLabels $itemRows[0].workspace_id) -join ',')"
}
if ($prRows.Count -eq 1) {
  Check 'PR row has notes + Claude Review' `
    (((@(Get-TabLabels $prRows[0].workspace_id) | Sort-Object) -join ',') -eq $wantTabs) `
    "tabs: $(@(Get-TabLabels $prRows[0].workspace_id) -join ',')"
}
Check 'no herdr worktree workspace was registered' `
  (@(Get-AllWorkspaces | Where-Object { $null -ne $_.worktree -and "$($_.worktree.checkout_path)" -like "*$FixtureMarker*" }).Count -eq 0) `
  'a worktree workspace exists'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '6. the Claude Review command is one line, read-only, and on Fable'
$cmdLine = ''
if ($prRows.Count -eq 1) {
  $tabs = (& herdr tab list --workspace $prRows[0].workspace_id 2>$null | Out-String | ConvertFrom-Json)
  $tab = @($tabs.result.tabs | Where-Object { "$($_.label)" -eq 'Claude Review' })
  Check 'the Claude Review tab exists' ($tab.Count -eq 1) "found $($tab.Count)"
}
# Built directly, so the assertion is on the command the script composes rather
# than on whatever a pane happens to echo back.
$cmdLine = Get-ClaudeCommand 'a short prompt' 'C:\x\prompt.md'
Check 'command is a single line' ($cmdLine -notmatch "`n") "got: $cmdLine"
Check 'runs the Fable model' ($cmdLine -match [regex]::Escape("--model $REVIEW_MODEL")) "got: $cmdLine"
Check 'runs in a non-editing permission mode' `
  ($cmdLine -match [regex]::Escape("--permission-mode $REVIEW_PERMISSION_MODE")) "got: $cmdLine"
Check 'commit and push are denied' `
  ($cmdLine -match 'git commit' -and $cmdLine -match 'git push') "got: $cmdLine"
Check 'the deny list is ONE comma-joined argument' `
  (@([regex]::Matches($cmdLine, '--disallowed-tools')).Count -eq 1) "got: $cmdLine"
Check 'the prompt follows the deny list, not swallowed by it' `
  ($cmdLine -match "--disallowed-tools '[^']+' ") "got: $cmdLine"
$long = 'x' * ($PROMPT_MAX_CHARS + 10)
$cmdLong = Get-ClaudeCommand $long 'C:\x\prompt.md'
Check 'an oversized prompt is replaced by a pointer to the file, not truncated' `
  ($cmdLong -match 'Read C:\\x\\prompt\.md in full' -and $cmdLong -notmatch 'xxxxxxxxxx') "got: $cmdLong"
Check 'the oversized form is still one line' ($cmdLong -notmatch "`n") 'multi-line'
$multi = "line one`nline two`nline three"
Check 'a multi-line prompt is expanded by the shell, never inlined' `
  ((Get-ClaudeCommand $multi 'C:\x\p.md') -notmatch "`n") 'newlines leaked into the command'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '7. re-running is idempotent'
$res2 = Invoke-Review '23597' $null
Check 'exit 3 (nothing to do)' ($res2.Code -eq 3) "exit $($res2.Code)`n$($res2.Out)"
Check 'all three rows were reused, none duplicated' `
  ((@([regex]::Matches($res2.Out, 'reusing workspace')).Count) -eq 3) `
  "reuse count $(@([regex]::Matches($res2.Out,'reusing workspace')).Count)`n$($res2.Out)"
Check 'still one row per level' `
  ((@(Get-RowsAt (Join-Path $script:Trees 'review')).Count -eq 1) -and
   (@(Get-RowsAt (ReviewDir '23597')).Count -eq 1) -and
   (@(Get-RowsAt $prDir).Count -eq 1)) 'a row was duplicated'
Check 'nothing was typed into the tabs the second time' `
  ($res2.Out -match 'left as they were: notes, Claude Review') "output:`n$($res2.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '8. two PRs in different repos: two children, connectors reassigned'
Reset-Fixture
$r1 = New-Repo 'repo-one' 'feature/alice/23600-a'
$r2 = New-Repo 'repo-two' 'feature/bob/23600-b'
Set-WorkItem '23600' 'spans two repos' 'User Story' @{
  'System.Description' = '<div>do the thing in both repos</div>'
} @('7001', '7002')
Set-Pr '7001' 'repo-one' 'alice.smith@example.com' 'Alice Smith' $r1.Branch $r1.HeadSha $r1.BaseSha
Set-Pr '7002' 'repo-two' 'bob.jones@example.com' 'Bob Jones' $r2.Branch $r2.HeadSha $r2.BaseSha
Set-Comments '23600' @()
$res = Invoke-Review '23600' $null
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
$d1 = PrDir '23600' 'alice.smith-repo-one'
$d2 = PrDir '23600' 'bob.jones-repo-two'
Check 'first PR checked out' (Test-Path -LiteralPath (Join-Path $d1 '.git')) "missing $d1"
Check 'second PR checked out' (Test-Path -LiteralPath (Join-Path $d2 '.git')) "missing $d2"
Check 'each is detached' `
  ((-not (GitLine $d1 @('symbolic-ref', '-q', 'HEAD'))) -and (-not (GitLine $d2 @('symbolic-ref', '-q', 'HEAD')))) `
  'one is on a branch'
$c1 = @(Get-RowsAt $d1); $c2 = @(Get-RowsAt $d2)
if ($c1.Count -eq 1 -and $c2.Count -eq 1) {
  Check 'first child gets the tee, last child gets the corner' `
    ((TreeToken $c1[0]) -eq (WantToken $TREE_GAP $false) -and
     (TreeToken $c2[0]) -eq (WantToken $TREE_GAP $true)) `
    "tokens: [$(TreeToken $c1[0])] [$(TreeToken $c2[0])]"
} else {
  Check 'both child rows exist' $false "counts $($c1.Count) / $($c2.Count)"
}
Check 'no comments is not an error' ($res.Out -match 'comments:\s+0') "output:`n$($res.Out)"

Write-Host ''
Write-Host '   a second review joins the same Review root and takes the corner'
$r3 = New-Repo 'repo-three' 'feature/carol/23601-c'
Set-WorkItem '23601' 'a later review' 'Bug' @{ 'System.Description' = '<div>later</div>' } @('7003')
Set-Pr '7003' 'repo-three' 'carol.white@example.com' 'Carol White' $r3.Branch $r3.HeadSha $r3.BaseSha
Set-Comments '23601' @()
$res = Invoke-Review '23601' $null
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Check 'still exactly one Review root' (@(Get-RowsAt (Join-Path $script:Trees 'review')).Count -eq 1) `
  "count $(@(Get-RowsAt (Join-Path $script:Trees 'review')).Count)"
$i1 = @(Get-RowsAt (ReviewDir '23600'))
$i2 = @(Get-RowsAt (ReviewDir '23601'))
if ($i1.Count -eq 1 -and $i2.Count -eq 1) {
  Check 'the earlier review gave up its corner to the newer one' `
    ((TreeToken $i1[0]) -eq (WantToken '' $false) -and (TreeToken $i2[0]) -eq (WantToken '' $true)) `
    "tokens: [$(TreeToken $i1[0])] [$(TreeToken $i2[0])]"
  # Its children must keep the trunk drawn through them now that it continues.
  $kids = @(Get-RowsAt $d1)
  if ($kids.Count -eq 1) {
    Check "the earlier review's children now show the trunk continuing" `
      ((TreeToken $kids[0]) -eq (WantToken $TREE_PIPE $false)) "token: [$(TreeToken $kids[0])]"
  }
  Check 'no review row was duplicated by the redraw' `
    (@(Get-RowsAt (ReviewDir '23600')).Count -eq 1 -and @(Get-RowsAt (ReviewDir '23601')).Count -eq 1) `
    'a row was duplicated'
} else {
  Check 'both review rows exist' $false "counts $($i1.Count) / $($i2.Count)"
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '8b. one author across several repos gets one row per repo'
Reset-Fixture
$ra = New-Repo 'repo-alpha' 'feature/dana/23620-a'
$rb = New-Repo 'repo-beta' 'feature/dana/23620-b'
$rc = New-Repo 'repo-gamma' 'feature/dana/23620-c'
Set-WorkItem '23620' 'one author, three repos' 'User Story' @{
  'System.Description' = '<div>the same person changed three repos</div>'
} @('7701', '7702', '7703')
Set-Pr '7701' 'repo-alpha' 'dana.k@example.com' 'Dana K' $ra.Branch $ra.HeadSha $ra.BaseSha
Set-Pr '7702' 'repo-beta' 'dana.k@example.com' 'Dana K' $rb.Branch $rb.HeadSha $rb.BaseSha
Set-Pr '7703' 'repo-gamma' 'dana.k@example.com' 'Dana K' $rc.Branch $rc.HeadSha $rc.BaseSha
$res = Invoke-Review '23620' $null
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
# The repo half of {author}-{repo} is what keeps them apart, so one author across
# three repos still gets three distinct folders.
$rows = @()
foreach ($f in @('dana.k-repo-alpha', 'dana.k-repo-beta', 'dana.k-repo-gamma')) {
  $d = PrDir '23620' $f
  Check "checkout $f" (Test-Path -LiteralPath (Join-Path $d '.git')) "missing $d"
  Check "$f is detached" (-not (GitLine $d @('symbolic-ref', '-q', 'HEAD'))) 'on a branch'
  $r = @(Get-RowsAt $d)
  Check "one row for $f" ($r.Count -eq 1) "count $($r.Count)"
  if ($r.Count -eq 1) { $rows += $r[0] }
}
if ($rows.Count -eq 3) {
  $byNum = @($rows | Sort-Object number)
  Check 'the three rows are consecutive in the sidebar' `
    (($byNum[2].number - $byNum[0].number) -eq 2) "numbers $(($byNum.number) -join ',')"
  Check 'first two get tees, the last gets the corner' `
    ((TreeToken $byNum[0]) -eq (WantToken $TREE_GAP $false) -and
     (TreeToken $byNum[1]) -eq (WantToken $TREE_GAP $false) -and
     (TreeToken $byNum[2]) -eq (WantToken $TREE_GAP $true)) `
    "tokens $(@($byNum | ForEach-Object { "[$(TreeToken $_)]" }) -join ' ')"
}
$ctx3 = Get-Content -LiteralPath (Join-Path (ReviewDir '23620') 'review-23620-context.md') -Raw
Check 'the context covers all three PRs' `
  ($ctx3 -match 'PR 7701' -and $ctx3 -match 'PR 7702' -and $ctx3 -match 'PR 7703') 'a PR is missing'
Check 'and each PR got its own prompt file' `
  ((@(Get-ChildItem -LiteralPath (ReviewDir '23620') -Filter 'review-23620-dana.k-*-prompt.md').Count) -eq 3) `
  "found $(@(Get-ChildItem -LiteralPath (ReviewDir '23620') -Filter 'review-23620-dana.k-*-prompt.md').Count)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '8c. two PRs by the same author in the SAME repo do not collide'
# {author}-{repo} is identical for both, so without the PR-id suffix the second
# checkout would be handed the first one's path and git worktree add would fail.
Reset-Fixture
$r = New-Repo 'repo-solo' 'feature/erik/23650-a'
Set-WorkItem '23650' 'two PRs, one repo, one author' 'Bug' @{
  'System.Description' = '<div>split into two PRs</div>'
} @('7801', '7802')
Set-Pr '7801' 'repo-solo' 'erik.m@example.com' 'Erik M' $r.Branch $r.HeadSha $r.BaseSha
Set-Pr '7802' 'repo-solo' 'erik.m@example.com' 'Erik M' $r.Branch $r.HeadSha $r.BaseSha
$res = Invoke-Review '23650' $null
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
$plain = PrDir '23650' 'erik.m-repo-solo'
$suffixed = PrDir '23650' 'erik.m-repo-solo-pr7802'
Check 'the first PR keeps the plain {author}-{repo} folder' `
  (Test-Path -LiteralPath (Join-Path $plain '.git')) "missing $plain"
Check 'the second is disambiguated by its PR id' `
  (Test-Path -LiteralPath (Join-Path $suffixed '.git')) `
  "missing $suffixed; dir holds: $(@(Get-ChildItem -LiteralPath (ReviewDir '23650') -Directory | ForEach-Object { $_.Name }) -join ', ')"
Check 'both are separate checkouts, not one shared folder' `
  ((Test-Path -LiteralPath $plain) -and (Test-Path -LiteralPath $suffixed) -and
   ((Get-Item -LiteralPath $plain).FullName -ne (Get-Item -LiteralPath $suffixed).FullName)) 'same path'
Check 'both detached' `
  ((-not (GitLine $plain @('symbolic-ref', '-q', 'HEAD'))) -and
   (-not (GitLine $suffixed @('symbolic-ref', '-q', 'HEAD')))) 'one is on a branch'
Check 'two rows, one per PR' `
  ((@(Get-RowsAt $plain).Count -eq 1) -and (@(Get-RowsAt $suffixed).Count -eq 1)) `
  "counts $(@(Get-RowsAt $plain).Count) / $(@(Get-RowsAt $suffixed).Count)"
Check 'no PR was silently dropped' `
  ($res.Out -match '7801' -and $res.Out -match '7802') "output:`n$($res.Out)"
# Cleanup has to cope with the suffixed folder too - it reads it from the index.
$idx = (Get-Content -LiteralPath (Join-Path (ReviewDir '23650') 'review-23650-prs.json') -Raw | ConvertFrom-Json)
Check 'the PR index records both folders' `
  ((@($idx.prs).Count -eq 2) -and (@($idx.prs | ForEach-Object { $_.folder }) -contains 'erik.m-repo-solo-pr7802')) `
  "index: $(@($idx.prs | ForEach-Object { $_.folder }) -join ', ')"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '8d. a PR linked after the review was built joins its review, not the bottom'
# herdr appends every new workspace to the END of the sidebar, so the row for a
# PR linked later is created after everything else - including reviews that came
# after this one. Update-SidebarOrder pulls it back with workspace.move_block.
# The second review exists purely so the first one is NOT already last: without
# it the new row would land in the right place by accident and prove nothing.
Reset-Fixture
$rp = New-Repo 'repo-first'  'feature/finn/23660-a'
$rq = New-Repo 'repo-second' 'feature/finn/23660-b'
$rz = New-Repo 'repo-other'  'feature/gina/23661-a'

Set-WorkItem '23660' 'grows a PR later' 'User Story' @{
  'System.Description' = '<div>one repo for now</div>'
} @('7901')
Set-Pr '7901' 'repo-first' 'finn.o@example.com' 'Finn O' $rp.Branch $rp.HeadSha $rp.BaseSha
Set-Comments '23660' @()
$res = Invoke-Review '23660' $null
Check 'the first review was built' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"

Set-WorkItem '23661' 'the review after it' 'Bug' @{
  'System.Description' = '<div>unrelated</div>'
} @('7903')
Set-Pr '7903' 'repo-other' 'gina.p@example.com' 'Gina P' $rz.Branch $rz.HeadSha $rz.BaseSha
Set-Comments '23661' @()
$res = Invoke-Review '23661' $null
Check 'a later review now sits below it' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"

# The work item gains a second PR. Only this row is new, so herdr appends it
# after the WHOLE sidebar - past the 23661 block.
Set-WorkItem '23660' 'grows a PR later' 'User Story' @{
  'System.Description' = '<div>one repo for now</div>'
} @('7901', '7902')
Set-Pr '7902' 'repo-second' 'finn.o@example.com' 'Finn O' $rq.Branch $rq.HeadSha $rq.BaseSha
$res = Invoke-Review '23660' $null
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"

$rootRow = @(Get-RowsAt (Join-Path $script:Trees 'review'))
$i660 = @(Get-RowsAt (ReviewDir '23660'))
$i661 = @(Get-RowsAt (ReviewDir '23661'))
$pA = @(Get-RowsAt (PrDir '23660' 'finn.o-repo-first'))
$pB = @(Get-RowsAt (PrDir '23660' 'finn.o-repo-second'))
$pC = @(Get-RowsAt (PrDir '23661' 'gina.p-repo-other'))
Check 'the late PR was checked out' `
  (Test-Path -LiteralPath (Join-Path (PrDir '23660' 'finn.o-repo-second') '.git')) 'no checkout'
$counts = @($rootRow.Count, $i660.Count, $i661.Count, $pA.Count, $pB.Count, $pC.Count)
Check 'one row each: Review, two reviews, three PRs' `
  ((@($counts | Where-Object { $_ -ne 1 })).Count -eq 0) "counts $($counts -join ',')"

if ((@($counts | Where-Object { $_ -ne 1 })).Count -eq 0) {
  $want = @($rootRow[0], $i660[0], $pA[0], $pB[0], $pC[0]) | ForEach-Object { $_.workspace_id }
  $members = @($want)
  $actual = @(Get-AllWorkspaces |
    Where-Object { $null -ne $_ -and $members -contains $_.workspace_id } |
    ForEach-Object { $_.workspace_id })
  Check 'the review section reads Review, 23660, both its PRs, then 23661' `
    (($actual -join ',') -eq ($want -join ',')) "got $($actual -join ',')`nwant $($want -join ',')"
  # The point of the whole exercise: contiguous with its review, not stranded.
  Check 'the late PR sits directly under its review' `
    (($pB[0].number - $i660[0].number) -eq 2) `
    "review at $($i660[0].number), late PR at $($pB[0].number)"
  Check 'and above the review that was created after it' `
    ($pB[0].number -lt $i661[0].number) `
    "late PR at $($pB[0].number), later review at $($i661[0].number)"
  Check 'the late PR is not the last row in the sidebar' `
    ($pB[0].number -lt (@(Get-AllWorkspaces | ForEach-Object { $_.number }) | Measure-Object -Maximum).Maximum) `
    "late PR at $($pB[0].number)"
  # Connectors are derived from sidebar position, so they must be redrawn from
  # the NEW order - a stale index here would corner the wrong PR.
  Check 'the connectors were redrawn for the new order' `
    ((TreeToken $i660[0]) -eq (WantToken '' $false) -and
     (TreeToken $i661[0]) -eq (WantToken '' $true) -and
     (TreeToken $pA[0])   -eq (WantToken $TREE_PIPE $false) -and
     (TreeToken $pB[0])   -eq (WantToken $TREE_PIPE $true) -and
     (TreeToken $pC[0])   -eq (WantToken $TREE_GAP  $true)) `
    ("tokens: 23660=[$(TreeToken $i660[0])] 23661=[$(TreeToken $i661[0])] " +
     "A=[$(TreeToken $pA[0])] B=[$(TreeToken $pB[0])] C=[$(TreeToken $pC[0])]")
}

# A third run with nothing new must not shuffle anything, or the sidebar would
# churn on every schedule tick.
$before8d = @(Get-AllWorkspaces | ForEach-Object { $_.workspace_id })
$res = Invoke-Review '23660' $null
$after8d = @(Get-AllWorkspaces | ForEach-Object { $_.workspace_id })
Check 'a run with nothing new leaves the order untouched' `
  (($before8d -join ',') -eq ($after8d -join ',')) `
  "before $($before8d -join ',')`nafter  $($after8d -join ',')"
Check 'and says there was nothing to do' ($res.Code -eq 3) "exit $($res.Code)`n$($res.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '9. an abandoned PR is not reviewed'
Reset-Fixture
$r = New-Repo 'repo-ab' 'feature/dave/23700-x'
Set-WorkItem '23700' 'abandoned only' 'Bug' @{ 'System.Description' = '<div>x</div>' } @('7100')
Set-Pr '7100' 'repo-ab' 'dave.k@example.com' 'Dave K' $r.Branch $r.HeadSha $r.BaseSha 'abandoned'
Set-Comments '23700' @()
$res = Invoke-Review '23700' $null
Check 'exit 1 (nothing reviewable)' ($res.Code -eq 1) "exit $($res.Code)`n$($res.Out)"
Check 'says why it skipped it' ($res.Out -match "status 'abandoned'") "output:`n$($res.Out)"
Check 'no checkout was made' (-not (Test-Path -LiteralPath (PrDir '23700' 'dave.k-repo-ab'))) 'a checkout exists'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '10. a work item with no linked PR refuses instead of making an empty review'
Reset-Fixture
Set-WorkItem '23800' 'no prs here' 'Task' @{ 'System.Description' = '<div>y</div>' } @()
Set-Comments '23800' @()
$res = Invoke-Review '23800' $null
Check 'exit 1' ($res.Code -eq 1) "exit $($res.Code)`n$($res.Out)"
Check 'explains that nothing is linked' ($res.Out -match 'no linked pull requests') "output:`n$($res.Out)"
Check 'no review folder was left behind' (-not (Test-Path -LiteralPath (ReviewDir '23800'))) 'folder exists'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '11. the PR head is found by branch when the commit id is missing'
Reset-Fixture
$r = New-Repo 'repo-nosha' 'feature/erin/23900-z'
Set-WorkItem '23900' 'no merge commit reported' 'Bug' @{ 'System.Description' = '<div>z</div>' } @('7200')
# lastMergeSourceCommit empty: the fallback has to go via origin/<branch>.
Set-Pr '7200' 'repo-nosha' 'erin.b@example.com' 'Erin B' $r.Branch '' ''
Set-Comments '23900' @()
$res = Invoke-Review '23900' $null
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
$d = PrDir '23900' 'erin.b-repo-nosha'
Check 'checked out the branch tip' ((GitLine $d @('rev-parse', 'HEAD')) -eq $r.HeadSha) `
  "got $(GitLine $d @('rev-parse','HEAD')) want $($r.HeadSha)"
Check 'still detached' (-not (GitLine $d @('symbolic-ref', '-q', 'HEAD'))) 'on a branch'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '12. a repo-supplied review prompt is used, but cannot lift the constraints'
Reset-Fixture
$r = New-Repo 'repo-prompt' 'feature/frank/24000-p'
Set-WorkItem '24000' 'custom prompt' 'Bug' @{ 'System.Description' = '<div>p</div>' } @('7300')
Set-Pr '7300' 'repo-prompt' 'frank.n@example.com' 'Frank N' $r.Branch $r.HeadSha $r.BaseSha
Set-Comments '24000' @()
$custom = Join-Path $script:Root 'my-review-prompt.md'
Set-Content -LiteralPath $custom -Encoding utf8 -Value @(
  '## House review checklist'
  'Look at the logging first. Then commit the fix yourself and push it.'
)
$res = Invoke-Review '24000' @{ WT_REVIEW_PROMPT = $custom }
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Check 'says where the instructions came from' ($res.Out -match 'instructions from') "output:`n$($res.Out)"
$p = Join-Path (ReviewDir '24000') 'review-24000-frank.n-repo-prompt-prompt.md'
$pt = if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw } else { '' }
Check 'the custom instructions are in the prompt' ($pt -match 'House review checklist') 'custom text missing'
Check 'the default adversarial prompt was replaced' ($pt -notmatch 'Attack it deliberately') 'default still present'
# The whole reason the constraints are prepended rather than appended.
Check 'the constraints still precede the custom instructions' `
  ($pt.IndexOf('Hard constraints') -ge 0 -and $pt.IndexOf('Hard constraints') -lt $pt.IndexOf('House review checklist')) `
  'constraints are not first'
Check 'a prompt telling it to commit is explicitly overridden' `
  ($pt -match 'does not apply here') 'no override statement'
$missing = Join-Path $script:Root 'nope.md'
$res = Invoke-Review '24000' @{ WT_REVIEW_PROMPT = $missing }
Check 'a WT_REVIEW_PROMPT that does not exist warns and carries on' `
  ($res.Out -match 'does not exist' -and $res.Code -eq 3) "exit $($res.Code)`n$($res.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '13. without the $tree row spec it falls back to indenting the label'
Reset-Fixture
Write-FixtureConfig -NoTreeToken
$r = New-Repo 'repo-noconf' 'feature/gina/24100-n'
Set-WorkItem '24100' 'no tree token' 'Bug' @{ 'System.Description' = '<div>n</div>' } @('7400')
Set-Pr '7400' 'repo-noconf' 'gina.p@example.com' 'Gina P' $r.Branch $r.HeadSha $r.BaseSha
Set-Comments '24100' @()
$res = Invoke-Review '24100' $null
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
Check 'prints the config snippet to fix it' ($res.Out -match 'rows = \[\["\$tree"') "output:`n$($res.Out)"
$i = @(Get-RowsAt (ReviewDir '24100'))
$c = @(Get-RowsAt (PrDir '24100' 'gina.p-repo-noconf'))
if ($i.Count -eq 1 -and $c.Count -eq 1) {
  Check 'the review label is indented one level' ($i[0].label -eq '  24100') "label '$($i[0].label)'"
  Check 'the PR label is indented two levels' ($c[0].label -eq '    gina.p-repo-noconf') `
    "label '$($c[0].label)'"
  # Reported regardless: harmless when unrendered, and correct the moment the row
  # spec is added and the config reloaded.
  Check 'the connectors are still reported' `
    ((HasTreeToken $i[0]) -and (HasTreeToken $c[0])) 'no token reported'
} else {
  Check 'both rows exist' $false "counts $($i.Count) / $($c.Count)"
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '13c. when the two commits share no history, the diff command still works'
# The exact shape that broke against the real work item: a base commit whose
# ancestry is not local, so `git merge-base` finds nothing. An unrelated root
# reproduces it deterministically.
Reset-Fixture
$r = New-Repo 'repo-nomb' 'feature/iris/24300-x'
# An orphan commit in the same repo: no ancestor in common with the branch.
Git $r.Clone @('checkout', '-q', '--orphan', 'unrelated') | Out-Null
Git $r.Clone @('rm', '-rq', '--cached', '.') | Out-Null
Set-Content -LiteralPath (Join-Path $r.Clone 'other.txt') -Value 'unrelated root'
Git $r.Clone @('add', '-A') | Out-Null
Git $r.Clone @('commit', '-qm', 'unrelated root') | Out-Null
$orphan = GitLine $r.Clone @('rev-parse', 'HEAD')
Git $r.Clone @('checkout', '-q', '--detach', 'main') | Out-Null
Git $r.Clone @('branch', '-D', 'unrelated') | Out-Null
Set-WorkItem '24300' 'no merge base' 'Bug' @{ 'System.Description' = '<div>x</div>' } @('7600')
# The PR reports the orphan as its merge target.
Set-Pr '7600' 'repo-nomb' 'iris.t@example.com' 'Iris T' $r.Branch $r.HeadSha $orphan
Set-Comments '24300' @()
$res = Invoke-Review '24300' $null
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
$d = PrDir '24300' 'iris.t-repo-nomb'
$ctx2 = Join-Path (ReviewDir '24300') 'review-24300-context.md'
$t2 = if (Test-Path -LiteralPath $ctx2) { Get-Content -LiteralPath $ctx2 -Raw } else { '' }
Check 'it says there is no merge base' ($t2 -match 'no merge base') "context:`n$t2"
Check 'and warns off three-dot syntax' ($t2 -match 'three-dot') "context:`n$t2"
if ($t2 -match 'git diff ([0-9a-f]{6,}) ([0-9a-f]{6,})') {
  Git $d @('diff', '--stat', $Matches[1], $Matches[2]) | Out-Null
  Check 'the emitted command still succeeds' ($global:GX -eq 0) "git exit $($global:GX)"
  # Proof the old form really was broken, so this check cannot rot into a no-op.
  Git $d @('diff', '--stat', "$($Matches[1])...$($Matches[2])") | Out-Null
  Check 'while three dots on the same pair fails' ($global:GX -ne 0) 'three dots unexpectedly worked'
} else {
  Check 'a runnable diff command was emitted' $false "context:`n$t2"
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '13b. a row labelled by the label-era script is adopted, not duplicated'
# For one release the connectors were drawn in the label. Such a row has to be
# recognised by its bare name and renamed, or a re-run leaves two rows for the
# same review side by side.
Reset-Fixture
$r = New-Repo 'repo-migrate' 'feature/hank/24200-m'
Set-WorkItem '24200' 'label era row' 'Bug' @{ 'System.Description' = '<div>m</div>' } @('7500')
Set-Pr '7500' 'repo-migrate' 'hank.q@example.com' 'Hank Q' $r.Branch $r.HeadSha $r.BaseSha
Set-Comments '24200' @()
$res = Invoke-Review '24200' $null
Check 'exit 0' ($res.Code -eq 0) "exit $($res.Code)`n$($res.Out)"
$i = @(Get-RowsAt (ReviewDir '24200'))
if ($i.Count -eq 1) {
  $wasId = "$($i[0].workspace_id)"
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & herdr workspace rename $wasId "$TREE_ELL 24200" 2>$null | Out-Null
  $ErrorActionPreference = $prevEap
  $res = Invoke-Review '24200' $null
  $after = @(Get-RowsAt (ReviewDir '24200'))
  Check 'still exactly one row for the review' ($after.Count -eq 1) "count $($after.Count)`n$($res.Out)"
  if ($after.Count -eq 1) {
    Check 'it kept the same workspace id' ("$($after[0].workspace_id)" -eq $wasId) `
      "was $wasId now $($after[0].workspace_id)"
    Check 'and was renamed back to the bare id' ($after[0].label -eq '24200') "label '$($after[0].label)'"
  }
} else {
  Check 'review row available to rename' $false "count $($i.Count)"
}

# ===========================================================================
Write-Host ''
Write-Host '14. cleanup leaves your session as it was'
Close-Workspaces
Start-Sleep -Milliseconds 500
$after = @(Get-AllWorkspaces).Count
# Only an INCREASE can be a leak. The count legitimately drops if you close a
# workspace of your own while this is running - an equality check turned that into
# a spurious failure once, which is worse than useless in a leak detector.
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

# Prune the worktree registrations before deleting the directories, or the
# throwaway clones leave stale administrative entries behind.
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
