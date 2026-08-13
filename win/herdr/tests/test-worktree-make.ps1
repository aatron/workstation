# Test harness for win/herdr/worktree-make.ps1
# Builds a throwaway upstream + clone per scenario, points a copy of the real
# script at it (SRC_ROOT) and at a throwaway herdr [worktrees].directory, runs
# it non-interactively, and asserts on the resulting worktree.
$ErrorActionPreference = 'Stop'

$FixtureMarker = 'herdr-wt-tests'
$Base = Join-Path ([IO.Path]::GetTempPath()) "$FixtureMarker\$PID\make"
$RealScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'worktree-make.ps1'
$script:Run = 0
$Root = ''; $Script = ''; $Repos = ''; $Trees = ''; $Cfg = ''
$script:Pass = 0
$script:Fail = 0
$script:Names = @()

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

# The fixture herdr config. -WithTreeToken lays the sidebar rows out so the
# $tree connector renders, which is what makes worktree-make label the repo rows
# with their bare name instead of a plain indent.
function Write-FixtureConfig([switch]$WithTreeToken) {
  # TOML basic string, backslashes escaped exactly as the README tells the user
  # to write them: directory = "C:\\Users\\me\\source\\worktrees"
  $lines = @(
    '[worktrees]'
    ('directory = "' + $script:Trees.Replace('\', '\\') + '"')
  )
  if ($WithTreeToken) {
    $lines += @(
      '[ui.sidebar.spaces]'
      'rows = [["$tree", "state_icon", "workspace"]]'
    )
  }
  Set-Content -LiteralPath $script:Cfg -Encoding utf8 -Value $lines
}

function Reset-Fixture {
  # Close the workspaces this harness created, then move to a brand-new
  # directory: herdr panes keep handles open on old worktrees, so reusing one
  # path makes cleanup (not the code under test) the thing that fails.
  Close-Workspaces
  $script:Run++
  $script:Root = Join-Path $Base "run$($script:Run)"
  $script:Script = Join-Path $script:Root 'make-worktree.ps1'
  $script:Repos = Join-Path $script:Root 'repos'
  $script:Trees = Join-Path $script:Root 'worktrees'
  $script:Cfg = Join-Path $script:Root 'config.toml'
  $Root = $script:Root; $Script = $script:Script
  $Repos = $script:Repos; $Trees = $script:Trees; $Cfg = $script:Cfg
  New-Item -ItemType Directory -Force -Path $Root, $Repos, $Trees | Out-Null
  Write-FixtureConfig
  # A copy of the real script with SRC_ROOT repointed at the fixture.
  $lines = Get-Content -LiteralPath $RealScript
  $out = foreach ($l in $lines) {
    if ($l -match '^\$SRC_ROOT = ') { "`$SRC_ROOT = '$Repos'" } else { $l }
  }
  Set-Content -LiteralPath $Script -Value $out -Encoding utf8
}

# upstream bare repo + a clone under $Repos, upstream advanced past the clone.
function New-Repo([string]$Name, [string]$DefBranch, [int]$Extra) {
  $up = Join-Path $Root "$Name.git"
  $work = Join-Path $Root "$Name.work"
  $clone = Join-Path $Repos $Name
  Git $Root @('init', '-q', '--bare', $up) | Out-Null
  Git $up @('symbolic-ref', 'HEAD', "refs/heads/$DefBranch") | Out-Null
  Git $Root @('init', '-q', $work) | Out-Null
  Git $work @('config', 'user.email', 't@t.t') | Out-Null
  Git $work @('config', 'user.name', 'T') | Out-Null
  Set-Content -LiteralPath (Join-Path $work 'f.txt') -Value 'base'
  Git $work @('add', '-A') | Out-Null
  Git $work @('commit', '-qm', 'c1') | Out-Null
  Git $work @('branch', '-M', $DefBranch) | Out-Null
  Git $work @('remote', 'add', 'origin', $up) | Out-Null
  Git $work @('push', '-q', '-u', 'origin', $DefBranch) | Out-Null
  Git $Root @('clone', '-q', $up, $clone) | Out-Null
  Git $clone @('config', 'user.email', 't@t.t') | Out-Null
  Git $clone @('config', 'user.name', 'T') | Out-Null
  for ($i = 1; $i -le $Extra; $i++) {
    Add-Content -LiteralPath (Join-Path $work 'f.txt') -Value "up$i"
    Git $work @('commit', '-qam', "upstream$i") | Out-Null
  }
  if ($Extra -gt 0) { Git $work @('push', '-q', 'origin', $DefBranch) | Out-Null }
  return [pscustomobject]@{
    Name = $Name; Up = $up; Work = $work; Clone = $clone; Def = $DefBranch
    Tip = (GitLine $work @('rev-parse', 'HEAD'))
  }
}

function Invoke-Make([string]$Type, [hashtable]$Env) {
  $saved = @{}
  foreach ($k in $Env.Keys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
    [Environment]::SetEnvironmentVariable($k, $Env[$k])
  }
  $savedCfg = $env:HERDR_CONFIG_PATH
  $env:HERDR_CONFIG_PATH = $Cfg
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script $Type 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
  } finally {
    $ErrorActionPreference = $prevEap
    foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    $env:HERDR_CONFIG_PATH = $savedCfg
  }
}

# Close every workspace this harness created. Matching is by PATH, not label:
# herdr does not always keep the --label we passed, so a label filter silently
# leaves fixture workspaces behind in the user's real herdr session.
#
# Both shapes have to be swept. worktree-make now creates a PLAIN workspace per
# story (no worktree metadata, panes rooted at the story folder) - matching only
# on .worktree, as this did originally, leaked one of those per test run.
function Close-Workspaces {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $json = (& herdr workspace list 2>$null | Out-String)
    if (-not $json) { return }
    $obj = $null
    try { $obj = $json | ConvertFrom-Json } catch { return }
    # Match on the fixture marker rather than the full path: herdr normalises
    # separators inconsistently, and the marker appears in neither a real repo
    # nor a real worktree.
    foreach ($w in @($obj.result.workspaces)) {
      if ($null -eq $w) { continue }
      $paths = @()
      if ($null -ne $w.worktree) {
        $paths = @("$($w.worktree.repo_root)", "$($w.worktree.checkout_path)")
      } else {
        # A plain workspace only reveals where it lives through its panes.
        $pj = (& herdr pane list --workspace $w.workspace_id 2>$null | Out-String)
        if ($pj) {
          try { $paths = @(($pj | ConvertFrom-Json).result.panes | ForEach-Object { "$($_.cwd)" }) } catch { }
        }
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

# Plain workspaces whose panes sit at $Path (-Exact) or anywhere under it.
# Used to assert the story topology: the story row at the story folder, and one
# repo row rooted at each repo inside it.
function Get-FixtureWorkspaces([string]$Path, [switch]$Exact) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $found = @()
  try {
    $json = (& herdr workspace list 2>$null | Out-String)
    if (-not $json) { return @() }
    $obj = $null
    try { $obj = $json | ConvertFrom-Json } catch { return @() }
    $want = ($Path -replace '\\+', '/').TrimEnd('/').ToLowerInvariant()
    foreach ($w in @($obj.result.workspaces)) {
      if ($null -eq $w -or $null -ne $w.worktree) { continue }
      $pj = (& herdr pane list --workspace $w.workspace_id 2>$null | Out-String)
      if (-not $pj) { continue }
      $panes = @()
      try { $panes = @(($pj | ConvertFrom-Json).result.panes) } catch { continue }
      foreach ($p in $panes) {
        if ($null -eq $p) { continue }
        $have = ("$($p.cwd)" -replace '\\+', '/').TrimEnd('/').ToLowerInvariant()
        $hit = if ($Exact) { $have -eq $want } else { $have -eq $want -or $have.StartsWith("$want/") }
        if ($hit) { $found += $w; break }
      }
    }
  } catch { } finally { $ErrorActionPreference = $prev }
  return @($found)
}

# herdr-registered worktree workspaces whose checkout sits inside $Path. These
# are what `herdr worktree create` used to leave behind - one per repo, each
# nested under its primary clone in the sidebar. There should now be none.
function Get-WorktreeWorkspacesUnder([string]$Path) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $found = @()
  try {
    $json = (& herdr workspace list 2>$null | Out-String)
    if (-not $json) { return @() }
    $obj = $null
    try { $obj = $json | ConvertFrom-Json } catch { return @() }
    $want = ($Path -replace '\\+', '/').TrimEnd('/').ToLowerInvariant()
    foreach ($w in @($obj.result.workspaces)) {
      if ($null -eq $w -or $null -eq $w.worktree) { continue }
      $have = ("$($w.worktree.checkout_path)" -replace '\\+', '/').TrimEnd('/').ToLowerInvariant()
      if ($have.StartsWith("$want/")) { $found += $w }
    }
  } catch { } finally { $ErrorActionPreference = $prev }
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

function Story([string]$Id, [string]$Slug, [string]$Repo, [string]$Type = 'development') {
  $sub = if ($Type -eq 'review') { 'review' } else { 'development' }
  Join-Path (Join-Path (Join-Path $Trees $sub) "$Id-$Slug") $Repo
}

# The connectors worktree-make reports as each repo row's $tree sidebar token,
# behind two blank columns so the connector sits inside its story rather than
# flush under the story's own bullet. The indent leads with U+2800 because herdr
# trims leading whitespace off a token value - plain spaces would be eaten.
$INDENT_CH = -join @([char]0x2800, ' ')
$BRANCH_CH = $INDENT_CH + (-join @([char]0x251C, [char]0x2500))   # |- not the last repo
$LAST_CH = $INDENT_CH + (-join @([char]0x2514, [char]0x2500))     # `- the last repo
function TreeToken($Ws) {
  if ($null -eq $Ws.tokens) { return '' }
  return "$($Ws.tokens.tree)"
}
function HasTreeToken($Ws) {
  return [bool](TreeToken $Ws)
}

Write-Host ''
Write-Host '================ worktree-make.ps1 test run ================'

# Matches worktree-make.ps1's $BRANCH_PREFIX default. Arrange leftover branches
# and assert names against this so a prefix rename only needs one edit here.
$Prefix = 'feature/YOU'
$DefBranch = 'develop'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '1. happy path: new branch lands on the LATEST default branch'
Reset-Fixture
$r = New-Repo 'mono' $DefBranch 4
$branch = "$Prefix/99001-zz-happy"
$res = Invoke-Make 'development' @{ WT_ID = '99001'; WT_SLUG = 'zz-happy'; WT_REPOS = 'mono' }
$wt = Story '99001' 'zz-happy' 'mono'
$head = GitLine $wt @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == upstream tip' ($head -eq $r.Tip) "head=$head want=$($r.Tip)`n$($res.Out)"
Check 'branch name correct' ((GitLine $wt @('rev-parse', '--abbrev-ref', 'HEAD')) -eq $branch) 'branch'
Check 'push upstream is own branch' `
  ((GitLine $wt @('config', '--get', "branch.$branch.merge")) -eq "refs/heads/$branch") 'upstream'
Check 'verify line printed' ($res.Out -match 'verify: HEAD') 'no verify line'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '2. stale remote-tracking ref is refreshed by the fetch'
Reset-Fixture
$r = New-Repo 'mono' 'main' 5
# roll the clone''s origin/main back to the first commit, as a broken/skipped fetch would leave it
$first = GitLine $r.Clone @('rev-list', '--max-parents=0', 'HEAD')
Git $r.Clone @('update-ref', 'refs/remotes/origin/main', $first) | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99002'; WT_SLUG = 'zz-stale'; WT_REPOS = 'mono' }
$head = GitLine (Story '99002' 'zz-stale' 'mono') @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == upstream tip (not the stale ref)' ($head -eq $r.Tip) "head=$head want=$($r.Tip)`n$($res.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '3. THE BUG: leftover branch with no unique commits is moved to the base'
Reset-Fixture
$r = New-Repo 'mono' 'main' 6
$old = GitLine $r.Clone @('rev-parse', 'origin/main')   # stale, pre-fetch tip
Git $r.Clone @('branch', "$Prefix/99003-zz-left", $old) | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99003'; WT_SLUG = 'zz-left'; WT_REPOS = 'mono' }
$head = GitLine (Story '99003' 'zz-left' 'mono') @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == upstream tip (was the stale branch tip before the fix)' ($head -eq $r.Tip) "head=$head want=$($r.Tip)`n$($res.Out)"
Check 'reported the move' ($res.Out -match 'no commits of its own') 'no move message'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '4. leftover branch WITH unique commits: refuse, create nothing'
Reset-Fixture
$r = New-Repo 'mono' 'main' 3
$old = GitLine $r.Clone @('rev-parse', 'origin/main')
$leftover = "$Prefix/99004-zz-work"
Git $r.Clone @('branch', $leftover, $old) | Out-Null
# give the leftover branch a commit of its own, without checking it out
$tree = GitLine $r.Clone @('rev-parse', "$old^{tree}")
$newc = GitLine $r.Clone @('commit-tree', $tree, '-p', $old, '-m', 'my local work')
Git $r.Clone @('update-ref', "refs/heads/$leftover", $newc) | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99004'; WT_SLUG = 'zz-work'; WT_REPOS = 'mono' }
Check 'exit 1' ($res.Code -eq 1) "exit=$($res.Code)`n$($res.Out)"
Check 'no worktree created' (-not (Test-Path -LiteralPath (Join-Path (Story '99004' 'zz-work' 'mono') '.git'))) 'worktree exists'
Check 'explains the overrides' (($res.Out -match 'WT_REUSE_BRANCH') -and ($res.Out -match 'WT_RESET_BRANCH')) 'no override hint'
Check 'branch left untouched' ((GitLine $r.Clone @('rev-parse', "refs/heads/$leftover")) -eq $newc) 'branch moved'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '5. WT_RESET_BRANCH=1 discards the unique commits and uses the base'
$res = Invoke-Make 'development' @{ WT_ID = '99004'; WT_SLUG = 'zz-work'; WT_REPOS = 'mono'; WT_RESET_BRANCH = '1' }
$head = GitLine (Story '99004' 'zz-work' 'mono') @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == upstream tip' ($head -eq $r.Tip) "head=$head want=$($r.Tip)`n$($res.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '6. WT_REUSE_BRANCH=1 keeps the existing branch and says how far behind'
Reset-Fixture
$r = New-Repo 'mono' 'main' 3
$old = GitLine $r.Clone @('rev-parse', 'origin/main')
$tree = GitLine $r.Clone @('rev-parse', "$old^{tree}")
$newc = GitLine $r.Clone @('commit-tree', $tree, '-p', $old, '-m', 'my local work')
Git $r.Clone @('update-ref', "refs/heads/$Prefix/99006-zz-reuse", $newc) | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99006'; WT_SLUG = 'zz-reuse'; WT_REPOS = 'mono'; WT_REUSE_BRANCH = '1' }
$head = GitLine (Story '99006' 'zz-reuse' 'mono') @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == existing branch tip' ($head -eq $newc) "head=$head want=$newc`n$($res.Out)"
Check 'warns it is behind' ($res.Out -match 'behind origin/main') 'no behind warning'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '7. branch already checked out elsewhere: refuse'
Reset-Fixture
$r = New-Repo 'mono' 'main' 2
$other = Join-Path $Root 'other-wt'
Git $r.Clone @('worktree', 'add', '-b', "$Prefix/99007-zz-dup", $other, 'origin/main') | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99007'; WT_SLUG = 'zz-dup'; WT_REPOS = 'mono' }
Check 'exit 1' ($res.Code -eq 1) "exit=$($res.Code)`n$($res.Out)"
Check 'names the conflicting worktree' ($res.Out -match 'already checked out at') "no message`n$($res.Out)"
Check 'no worktree created' (-not (Test-Path -LiteralPath (Join-Path (Story '99007' 'zz-dup' 'mono') '.git'))) 'worktree exists'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '8. fetch failure: refuse rather than use a stale origin'
Reset-Fixture
$r = New-Repo 'mono' 'main' 4
Git $r.Clone @('remote', 'set-url', 'origin', (Join-Path $Root 'does-not-exist.git')) | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99008'; WT_SLUG = 'zz-nofetch'; WT_REPOS = 'mono' }
Check 'exit 1' ($res.Code -eq 1) "exit=$($res.Code)`n$($res.Out)"
Check 'says the fetch failed' ($res.Out -match 'fetch failed') "no message`n$($res.Out)"
Check 'no worktree created' (-not (Test-Path -LiteralPath (Join-Path (Story '99008' 'zz-nofetch' 'mono') '.git'))) 'worktree exists'
Check 'retried once' (([regex]::Matches($res.Out, 'git fetch --prune origin in')).Count -eq 2) 'no retry'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '9. missing origin/HEAD is recovered from the remote'
Reset-Fixture
$r = New-Repo 'mono' $DefBranch 3
# origin/HEAD is a SYMBOLIC ref: update-ref -d does not remove it.
Git $r.Clone @('symbolic-ref', '-d', 'refs/remotes/origin/HEAD') | Out-Null
Check 'origin/HEAD really gone' ((GitLine $r.Clone @('symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD')) -eq '') 'still there'
$res = Invoke-Make 'development' @{ WT_ID = '99009'; WT_SLUG = 'zz-nohead'; WT_REPOS = 'mono' }
$head = GitLine (Story '99009' 'zz-nohead' 'mono') @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == upstream tip of the real default branch' ($head -eq $r.Tip) "head=$head want=$($r.Tip)`n$($res.Out)"
Check 'base label names the real default' ($res.Out -match "origin/$DefBranch @") "no base line`n$($res.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '10. empty leftover directory at the worktree path is cleaned up'
Reset-Fixture
$r = New-Repo 'mono' 'main' 2
New-Item -ItemType Directory -Force -Path (Story '99010' 'zz-empty' 'mono') | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99010'; WT_SLUG = 'zz-empty'; WT_REPOS = 'mono' }
$head = GitLine (Story '99010' 'zz-empty' 'mono') @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == upstream tip' ($head -eq $r.Tip) "head=$head want=$($r.Tip)`n$($res.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '11. re-run is idempotent (exit 3, nothing touched)'
$before = GitLine (Story '99010' 'zz-empty' 'mono') @('rev-parse', 'HEAD')
$res = Invoke-Make 'development' @{ WT_ID = '99010'; WT_SLUG = 'zz-empty'; WT_REPOS = 'mono' }
$after = GitLine (Story '99010' 'zz-empty' 'mono') @('rev-parse', 'HEAD')
Check 'exit 3' ($res.Code -eq 3) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD unchanged' ($before -eq $after) "before=$before after=$after"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '12. review: worktree lands on origin/<linked branch>, stale local branch fixed'
Reset-Fixture
$r = New-Repo 'mono' 'main' 2
# a PR branch on the remote with 2 commits, and a stale local branch of the same name
Git $r.Work @('checkout', '-q', '-b', 'feature/someone/99012-pr') | Out-Null
Add-Content -LiteralPath (Join-Path $r.Work 'f.txt') -Value 'pr1'
Git $r.Work @('commit', '-qam', 'pr1') | Out-Null
Git $r.Work @('push', '-q', 'origin', 'feature/someone/99012-pr') | Out-Null
$prMid = GitLine $r.Work @('rev-parse', 'HEAD')
Add-Content -LiteralPath (Join-Path $r.Work 'f.txt') -Value 'pr2'
Git $r.Work @('commit', '-qam', 'pr2') | Out-Null
Git $r.Work @('push', '-q', 'origin', 'feature/someone/99012-pr') | Out-Null
$prTip = GitLine $r.Work @('rev-parse', 'HEAD')
Git $r.Clone @('fetch', '-q', 'origin') | Out-Null
Git $r.Clone @('update-ref', 'refs/heads/feature/someone/99012-pr', $prMid) | Out-Null
Git $r.Clone @('update-ref', 'refs/remotes/origin/feature/someone/99012-pr', $prMid) | Out-Null
$bf = Join-Path $Root 'branches.txt'
Set-Content -LiteralPath $bf -Value 'mono:feature/someone/99012-pr' -NoNewline
$res = Invoke-Make 'review' @{ WT_ID = '99012'; WT_SLUG = 'zz-review'; WT_BRANCHES_FILE = $bf }
$wt = Story '99012' 'zz-review' 'mono' 'review'
$head = GitLine $wt @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == origin PR tip (not the stale local branch)' ($head -eq $prTip) "head=$head want=$prTip mid=$prMid`n$($res.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '13. multi-repo run: one bad repo does not stop the good one'
Reset-Fixture
$a = New-Repo 'aaa' 'main' 3
$b = New-Repo 'bbb' 'main' 2
Git $b.Clone @('remote', 'set-url', 'origin', (Join-Path $Root 'nope.git')) | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99013'; WT_SLUG = 'zz-multi'; WT_REPOS = 'aaa, bbb' }
$headA = GitLine (Story '99013' 'zz-multi' 'aaa') @('rev-parse', 'HEAD')
Check 'exit 1 (a repo failed)' ($res.Code -eq 1) "exit=$($res.Code)`n$($res.Out)"
Check 'good repo still created at tip' ($headA -eq $a.Tip) "head=$headA want=$($a.Tip)`n$($res.Out)"
Check 'bad repo not created' (-not (Test-Path -LiteralPath (Join-Path (Story '99013' 'zz-multi' 'bbb') '.git'))) 'bbb exists'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '14. missing clone is reported, does not crash the run'
Reset-Fixture
$a = New-Repo 'aaa' 'main' 1
$res = Invoke-Make 'development' @{ WT_ID = '99014'; WT_SLUG = 'zz-missing'; WT_REPOS = 'aaa,ghost' }
Check 'exit 1' ($res.Code -eq 1) "exit=$($res.Code)`n$($res.Out)"
Check 'names the missing clone' ($res.Out -match 'missing clone') "no message`n$($res.Out)"
Check 'good repo created' (Test-Path -LiteralPath (Join-Path (Story '99014' 'zz-missing' 'aaa') '.git')) 'aaa missing'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '15. story topology: story row with four tabs, one repo row under it per repo'
Reset-Fixture
$a = New-Repo 'aaa' 'main' 1
$b = New-Repo 'bbb' 'main' 2
$res = Invoke-Make 'development' @{ WT_ID = '99015'; WT_SLUG = 'zz-topo'; WT_REPOS = 'aaa,bbb' }
$storyDir = Split-Path -Parent (Story '99015' 'zz-topo' 'aaa')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'both repos are folders inside the story' `
  ((Test-Path -LiteralPath (Join-Path (Story '99015' 'zz-topo' 'aaa') '.git')) -and
   (Test-Path -LiteralPath (Join-Path (Story '99015' 'zz-topo' 'bbb') '.git'))) 'a repo is missing'

# The story row is rooted at the story folder itself, not at any repo in it.
$story = @(Get-FixtureWorkspaces $storyDir -Exact)
Check 'exactly one story workspace' ($story.Count -eq 1) "count=$($story.Count)`n$($res.Out)"
if ($story.Count -eq 1) {
  Check 'labeled {id}-{slug}' ("$($story[0].label)" -eq '99015-zz-topo') "label=$($story[0].label)"
  # The whole point: a workspace with worktree metadata gets nested under its
  # primary clone, which is the repo-centric layout this replaced.
  Check 'not nested under a repo (no worktree metadata)' ($null -eq $story[0].worktree) 'it is a worktree workspace'
  $labels = @(Get-TabLabels $story[0].workspace_id)
  foreach ($want in @('notes', 'claude', 'cursor', 'pwsh')) {
    Check "story has a '$want' tab" ($labels -contains $want) "tabs=$($labels -join ',')"
  }
  Check 'story has no stray extra tab' ($labels.Count -eq 4) "tabs=$($labels -join ',')"
}

foreach ($repo in @('aaa', 'bbb')) {
  $rowDir = Story '99015' 'zz-topo' $repo
  $row = @(Get-FixtureWorkspaces $rowDir -Exact)
  Check "one workspace row for repo $repo" ($row.Count -eq 1) "count=$($row.Count)`n$($res.Out)"
  if ($row.Count -ne 1) { continue }
  # No $tree row spec in this fixture, so the indent falls back into the label.
  Check "$repo row label is indented" ("$($row[0].label)" -eq "  $repo") "label=[$($row[0].label)]"
  $rl = @(Get-TabLabels $row[0].workspace_id)
  foreach ($want in @('notes', 'claude', 'pwsh')) {
    Check "$repo row has a '$want' tab" ($rl -contains $want) "tabs=$($rl -join ',')"
  }
  Check "$repo row has exactly three tabs" ($rl.Count -eq 3) "tabs=$($rl -join ',')"
  Check "$repo row has no cursor tab" (-not ($rl -contains 'cursor')) "tabs=$($rl -join ',')"
}

# Sidebar order is creation order, so the repo rows have to follow their story
# row directly - that adjacency is the only thing making the indent read as
# nesting.
$all = @(Get-FixtureWorkspaces $storyDir)
Check 'three rows in total (story + 2 repos)' ($all.Count -eq 3) "count=$($all.Count)"
if ($all.Count -eq 3) {
  $byNum = @($all | Sort-Object number)
  Check 'story row comes first' ("$($byNum[0].label)" -eq '99015-zz-topo') "order=$(($byNum.label) -join ' | ')"
  Check 'repo rows follow it, in the order requested' `
    (("$($byNum[1].label)" -eq '  aaa') -and ("$($byNum[2].label)" -eq '  bbb')) `
    "order=$(($byNum.label) -join ' | ')"
  Check 'rows are consecutive (nothing wedged between them)' `
    (($byNum[2].number - $byNum[0].number) -eq 2) "numbers=$(($byNum.number) -join ',')"
}
Check 'no per-repo worktree workspace was registered' `
  ((Get-WorktreeWorkspacesUnder $storyDir).Count -eq 0) 'a repo-level worktree workspace exists'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '16. re-running the same story reuses every row (no duplicates)'
$res = Invoke-Make 'development' @{ WT_ID = '99015'; WT_SLUG = 'zz-topo'; WT_REPOS = 'aaa,bbb' }
$all2 = @(Get-FixtureWorkspaces $storyDir)
Check 'exit 3 (nothing to do)' ($res.Code -eq 3) "exit=$($res.Code)`n$($res.Out)"
Check 'still three rows' ($all2.Count -eq 3) "count=$($all2.Count)`n$($res.Out)"
Check 'same workspace ids' `
  ((($all.workspace_id | Sort-Object) -join ',') -eq (($all2.workspace_id | Sort-Object) -join ',')) `
  "before=$(($all.workspace_id) -join ',') after=$(($all2.workspace_id) -join ',')"
Check 'said it reused them' `
  (([regex]::Matches($res.Out, 'reusing workspace')).Count -eq 3) "reuse lines`n$($res.Out)"
Check 'tab counts unchanged' `
  ((@(Get-TabLabels ($all2 | Where-Object { $_.label -eq '99015-zz-topo' }).workspace_id).Count -eq 4) -and
   (@(Get-TabLabels ($all2 | Where-Object { $_.label -eq '  aaa' }).workspace_id).Count -eq 3)) 'tab count changed'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '17. a repo added to an existing story gets its own row'
$c = New-Repo 'ccc' 'main' 1
# A row created AFTER the story, so the story's block is no longer last in the
# sidebar. herdr appends every new workspace to the end, so without this decoy
# the new repo row would follow bbb by accident and the ordering checks below
# would pass whether or not Set-SidebarOrder did anything.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$decoy = (& herdr workspace create --cwd $script:Root --label 'zz-decoy' --no-focus 2>$null |
  Out-String | ConvertFrom-Json).result.workspace.workspace_id
$ErrorActionPreference = $prevEap
Check 'a decoy row now sits below the story' ([bool]$decoy) 'could not create it'
$res = Invoke-Make 'development' @{ WT_ID = '99015'; WT_SLUG = 'zz-topo'; WT_REPOS = 'aaa,bbb,ccc' }
$all3 = @(Get-FixtureWorkspaces $storyDir)
Check 'exit 0 (one repo created)' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'four rows now' ($all3.Count -eq 4) "count=$($all3.Count)`n$($res.Out)"
$ccc = @($all3 | Where-Object { $_.label -eq '  ccc' })
Check 'ccc has its own row' ($ccc.Count -eq 1) "count=$($ccc.Count)`nlabels=$(($all3.label) -join ' | ')"
if ($ccc.Count -eq 1) {
  Check 'ccc row has three tabs' ((@(Get-TabLabels $ccc[0].workspace_id)).Count -eq 3) 'wrong tab count'
}
if ($all3.Count -eq 4 -and $decoy) {
  $byNum = @($all3 | Sort-Object number)
  Check 'the new repo row joined its story rather than the sidebar bottom' `
    ((($byNum.label) -join '|') -eq '99015-zz-topo|  aaa|  bbb|  ccc') `
    "order=$(($byNum.label) -join ' | ')"
  Check 'the four rows are consecutive' `
    (($byNum[3].number - $byNum[0].number) -eq 3) "numbers=$(($byNum.number) -join ',')"
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $decoyRow = @((& herdr workspace list 2>$null | Out-String | ConvertFrom-Json).result.workspaces |
    Where-Object { $_.workspace_id -eq $decoy })
  $ErrorActionPreference = $prevEap
  if ($decoyRow.Count -eq 1) {
    Check 'and above the row that was created after the story' `
      ($byNum[3].number -lt $decoyRow[0].number) `
      "ccc at $($byNum[3].number), decoy at $($decoyRow[0].number)"
  }
}
if ($decoy) {
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & herdr workspace close $decoy 2>$null | Out-Null
  $ErrorActionPreference = $prevEap
}
Check 'prints the config hint when $tree is not configured' `
  ($res.Out -match '\[ui\.sidebar\.spaces\]') "no hint`n$($res.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '18. $tree token: connectors reported, labels un-indented, last repo gets the corner'
Reset-Fixture
Write-FixtureConfig -WithTreeToken
$a = New-Repo 'aaa' 'main' 1
$b = New-Repo 'bbb' 'main' 1
$res = Invoke-Make 'development' @{ WT_ID = '99018'; WT_SLUG = 'zz-tree'; WT_REPOS = 'aaa,bbb' }
$storyDir = Split-Path -Parent (Story '99018' 'zz-tree' 'aaa')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'no config hint (it is configured)' `
  (-not ($res.Out -match '\[ui\.sidebar\.spaces\]')) "hint printed anyway`n$($res.Out)"

$story = @(Get-FixtureWorkspaces $storyDir -Exact)
Check 'story row exists' ($story.Count -eq 1) "count=$($story.Count)"
if ($story.Count -eq 1) {
  # The trunk carries no connector; an absent token renders as nothing, which is
  # also why the story row shows no separator dot.
  Check 'story row has no tree token' (-not (HasTreeToken $story[0])) `
    "tokens=$($story[0].tokens | ConvertTo-Json -Compress)"
}

$rowA = @(Get-FixtureWorkspaces (Story '99018' 'zz-tree' 'aaa') -Exact)
$rowB = @(Get-FixtureWorkspaces (Story '99018' 'zz-tree' 'bbb') -Exact)
Check 'both repo rows exist' (($rowA.Count -eq 1) -and ($rowB.Count -eq 1)) "a=$($rowA.Count) b=$($rowB.Count)"
if (($rowA.Count -eq 1) -and ($rowB.Count -eq 1)) {
  Check 'labels are the bare repo name (no label indent)' `
    (("$($rowA[0].label)" -eq 'aaa') -and ("$($rowB[0].label)" -eq 'bbb')) `
    "a=[$($rowA[0].label)] b=[$($rowB[0].label)]"
  Check 'first repo gets the tee connector' ((TreeToken $rowA[0]) -eq $BRANCH_CH) `
    "got=[$(TreeToken $rowA[0])]"
  Check 'last repo gets the corner connector' ((TreeToken $rowB[0]) -eq $LAST_CH) `
    "got=[$(TreeToken $rowB[0])]"
}

Write-Host ''
Write-Host '18b. adding a repo moves the corner down to the new last one'
$c = New-Repo 'ccc' 'main' 1
$res = Invoke-Make 'development' @{ WT_ID = '99018'; WT_SLUG = 'zz-tree'; WT_REPOS = 'aaa,bbb,ccc' }
$rowB = @(Get-FixtureWorkspaces (Story '99018' 'zz-tree' 'bbb') -Exact)
$rowC = @(Get-FixtureWorkspaces (Story '99018' 'zz-tree' 'ccc') -Exact)
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'bbb gave up the corner' `
  (($rowB.Count -eq 1) -and ((TreeToken $rowB[0]) -eq $BRANCH_CH)) "got=[$(TreeToken $rowB[0])]"
Check 'ccc took it' `
  (($rowC.Count -eq 1) -and ((TreeToken $rowC[0]) -eq $LAST_CH)) "got=[$(TreeToken $rowC[0])]"

Write-Host ''
Write-Host '18c. a row labelled by the label-era script is adopted, not duplicated'
# For one release the connectors were drawn in the label. Such a row must be
# recognised by its bare name and renamed, or a re-run would leave two rows for
# the same repo sitting next to each other.
$cccRow = @(Get-FixtureWorkspaces (Story '99018' 'zz-tree' 'ccc') -Exact)
if ($cccRow.Count -eq 1) {
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & herdr workspace rename $cccRow[0].workspace_id "$LAST_CH ccc" 2>$null | Out-Null
  $ErrorActionPreference = $prevEap
  $res = Invoke-Make 'development' @{ WT_ID = '99018'; WT_SLUG = 'zz-tree'; WT_REPOS = 'aaa,bbb,ccc' }
  $after = @(Get-FixtureWorkspaces (Story '99018' 'zz-tree' 'ccc') -Exact)
  Check 'still exactly one row for ccc' ($after.Count -eq 1) "count=$($after.Count)`n$($res.Out)"
  if ($after.Count -eq 1) {
    Check 'it kept the same workspace id' ("$($after[0].workspace_id)" -eq "$($cccRow[0].workspace_id)") `
      "was $($cccRow[0].workspace_id) now $($after[0].workspace_id)"
    Check 'and was renamed back to the bare name' ("$($after[0].label)" -eq 'ccc') `
      "label=[$($after[0].label)]"
  }
} else {
  Check 'ccc row available to rename' $false "count=$($cccRow.Count)"
}

# ---------------------------------------------------------------------------
# Cleanup order matters, and one pass is not enough. herdr keeps a workspace for
# every fixture CLONE it has seen and re-lists it while the repo is still on
# disk, while its panes hold those directories open so the delete fails until
# they are closed. Each round closes what it can and deletes what it can, which
# frees the next round; in practice it converges in two or three.
$fixtureRoot = $Base
foreach ($round in 1..8) {
  Close-Workspaces
  if (Test-Path -LiteralPath $fixtureRoot) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  $remaining = 0
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $j = (& herdr workspace list 2>$null | Out-String)
    if ($j) {
      $o = $null
      try { $o = $j | ConvertFrom-Json } catch { }
      foreach ($w in @($o.result.workspaces)) {
        if ($null -ne $w -and $null -ne $w.worktree -and
            "$($w.worktree.repo_root)" -like "*$FixtureMarker*") { $remaining++ }
      }
    }
  } finally { $ErrorActionPreference = $prev }
  if ($remaining -eq 0 -and -not (Test-Path -LiteralPath $fixtureRoot)) { break }
  Start-Sleep -Seconds 2
}
if (Test-Path -LiteralPath $fixtureRoot) {
  Write-Host "note: could not fully delete fixture dir $fixtureRoot (herdr may still hold it)"
}
Write-Host ''
Write-Host '================ summary ================'
Write-Host "PASS: $script:Pass   FAIL: $script:Fail"
if ($script:Fail -gt 0) {
  Write-Host 'failed checks:'
  $script:Names | ForEach-Object { Write-Host "  - $_" }
  exit 1
}
exit 0



