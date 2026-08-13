# Test harness for win/herdr/worktree-remove.ps1.
# Uses plain `git worktree add` (no herdr) so the runs are fast and hermetic:
# with no matching herdr workspace the script simply skips the herdr step.
$ErrorActionPreference = 'Stop'

$Base = Join-Path ([IO.Path]::GetTempPath()) "herdr-wt-tests\$PID\remove"
$RealScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'worktree-remove.ps1'
$script:Run = 0
$Root = ''; $Repos = ''; $Trees = ''; $Cfg = ''; $Script = ''
$script:Pass = 0; $script:Fail = 0; $script:Names = @()

function RGit([string]$Repo, [string[]]$A) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & git.exe -C $Repo @A 2>$null; $global:GX = $LASTEXITCODE; return @($o) }
  finally { $ErrorActionPreference = $prev }
}
function RGitLine([string]$Repo, [string[]]$A) {
  $o = RGit $Repo $A
  if ($global:GX -ne 0) { return '' }
  foreach ($l in $o) { $t = "$l".Trim(); if ($t) { return $t } }
  return ''
}
function BranchExists([string]$Repo, [string]$B) {
  RGit $Repo @('rev-parse', '--verify', '--quiet', "refs/heads/$B") | Out-Null
  return ($global:GX -eq 0)
}

function Reset-Fixture {
  $script:Run++
  $script:Root = Join-Path $Base "run$($script:Run)"
  $script:Repos = Join-Path $script:Root 'repos'
  $script:Trees = Join-Path $script:Root 'worktrees'
  $script:Cfg = Join-Path $script:Root 'config.toml'
  $script:Script = Join-Path $script:Root 'worktree-remove.ps1'
  $Root = $script:Root; $Repos = $script:Repos; $Trees = $script:Trees
  $Cfg = $script:Cfg; $Script = $script:Script
  New-Item -ItemType Directory -Force -Path $Root, $Repos, (Join-Path $Trees 'development') | Out-Null
  Set-Content -LiteralPath $Cfg -Encoding utf8 -Value @(
    '[worktrees]'
    ('directory = "' + $Trees.Replace('\', '\\') + '"')
  )
  Copy-Item -LiteralPath $RealScript -Destination $Script -Force
}

# A clone whose default branch is $DefBranch (origin/HEAD points at it).
function New-Repo([string]$Name, [string]$DefBranch) {
  $up = Join-Path $Root "$Name.git"
  $work = Join-Path $Root "$Name.work"
  $clone = Join-Path $Repos $Name
  RGit $Root @('init', '-q', '--bare', $up) | Out-Null
  RGit $up @('symbolic-ref', 'HEAD', "refs/heads/$DefBranch") | Out-Null
  RGit $Root @('init', '-q', $work) | Out-Null
  RGit $work @('config', 'user.email', 't@t.t') | Out-Null
  RGit $work @('config', 'user.name', 'T') | Out-Null
  Set-Content -LiteralPath (Join-Path $work 'f.txt') -Value 'base'
  RGit $work @('add', '-A') | Out-Null
  RGit $work @('commit', '-qm', 'c1') | Out-Null
  RGit $work @('branch', '-M', $DefBranch) | Out-Null
  RGit $work @('remote', 'add', 'origin', $up) | Out-Null
  RGit $work @('push', '-q', '-u', 'origin', $DefBranch) | Out-Null
  RGit $Root @('clone', '-q', $up, $clone) | Out-Null
  RGit $clone @('config', 'user.email', 't@t.t') | Out-Null
  RGit $clone @('config', 'user.name', 'T') | Out-Null
  return $clone
}

function Add-Worktree([string]$Clone, [string]$Story, [string]$Repo, [string]$Branch) {
  $dir = Join-Path (Join-Path (Join-Path $Trees 'development') $Story) $Repo
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dir) | Out-Null
  RGit $Clone @('worktree', 'add', '-q', '-b', $Branch, $dir, 'HEAD') | Out-Null
  return $dir
}

function Write-Notes([string]$Story, [string]$Id, [string]$Slug, [string]$Repo) {
  $sd = Join-Path (Join-Path $Trees 'development') $Story
  Set-Content -LiteralPath (Join-Path $sd "$Id-$Slug-$Repo.txt") -Value 'notes'
  Set-Content -LiteralPath (Join-Path $sd ".notespath-$Repo") -Value 'x' -NoNewline
}

function Invoke-Remove([hashtable]$Env) {
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
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
  } finally {
    $ErrorActionPreference = $prevEap
    foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    $env:HERDR_CONFIG_PATH = $savedCfg
  }
}

function Check([string]$Name, [bool]$Ok, [string]$Detail) {
  if ($Ok) { $script:Pass++; Write-Host "  PASS  $Name" }
  else { $script:Fail++; $script:Names += $Name; Write-Host "  FAIL  $Name :: $Detail" }
}
function StoryDir([string]$Story) { Join-Path (Join-Path $Trees 'development') $Story }

Write-Host ''
Write-Host '================ worktree-remove.ps1 test run ================'

# Matches worktree-make.ps1's $BRANCH_PREFIX default. Fixture branch names
# are built from this so a prefix rename only needs one edit here.
$Prefix = 'feature/YOU'
$DefBranch = 'develop'

Write-Host ''
Write-Host '1. normal removal: worktree, branch, notes and story folder all go'
Reset-Fixture
$c = New-Repo mono main
$branch = "$Prefix/77001-zz-norm"
$wt = Add-Worktree $c '77001-zz-norm' 'mono' $branch
Write-Notes '77001-zz-norm' '77001' 'zz-norm' 'mono'
$res = Invoke-Remove @{ WT_ID = '77001'; WT_ASSUME_YES = '1' }
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'worktree dir gone' (-not (Test-Path -LiteralPath $wt)) 'still there'
Check 'branch deleted' (-not (BranchExists $c $branch)) 'branch still there'
Check 'story folder gone' (-not (Test-Path -LiteralPath (StoryDir '77001-zz-norm'))) 'folder still there'
Check 'git no longer lists it' (-not ((RGit $c @('worktree', 'list')) -match '77001')) 'still registered'

Write-Host ''
Write-Host '2. a non-standard DEFAULT branch is protected from deletion'
Reset-Fixture
$c = New-Repo mono $DefBranch
# A worktree sitting on the default branch itself. Detach the main clone first,
# otherwise the branch cannot be checked out twice and the worktree would end up
# detached - which the script skips for a different reason, so the test would
# pass without exercising the protected-branch guard at all.
$wt = Join-Path (StoryDir '77002-zz-def') 'mono'
New-Item -ItemType Directory -Force -Path (StoryDir '77002-zz-def') | Out-Null
RGit $c @('checkout', '-q', '--detach') | Out-Null
RGit $c @('worktree', 'add', '-q', $wt, $DefBranch) | Out-Null
Check 'fixture: worktree really is on the default branch' `
  ((RGitLine $wt @('rev-parse', '--abbrev-ref', 'HEAD')) -eq $DefBranch) `
  "got $(RGitLine $wt @('rev-parse','--abbrev-ref','HEAD'))"
$res = Invoke-Remove @{ WT_ID = '77002'; WT_ASSUME_YES = '1' }
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'default branch NOT deleted' (BranchExists $c $DefBranch) "$DefBranch was deleted!`n$($res.Out)"
Check 'said it was protected' ($res.Out -match 'protected') "no protected note`n$($res.Out)"

Write-Host ''
Write-Host '2b. missing origin/HEAD: default branch STILL protected (via ls-remote)'
Reset-Fixture
$c = New-Repo mono $DefBranch
RGit $c @('symbolic-ref', '-d', 'refs/remotes/origin/HEAD') | Out-Null
$wt = Join-Path (StoryDir '77012-zz-nohead') 'mono'
New-Item -ItemType Directory -Force -Path (StoryDir '77012-zz-nohead') | Out-Null
RGit $c @('checkout', '-q', '--detach') | Out-Null
RGit $c @('worktree', 'add', '-q', $wt, $DefBranch) | Out-Null
Check 'fixture: on the default branch, origin/HEAD gone' `
  (((RGitLine $wt @('rev-parse', '--abbrev-ref', 'HEAD')) -eq $DefBranch) -and
   ((RGitLine $c @('symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD')) -eq '')) 'fixture wrong'
$res = Invoke-Remove @{ WT_ID = '77012'; WT_ASSUME_YES = '1' }
Check 'default branch NOT deleted' (BranchExists $c $DefBranch) "it was deleted!`n$($res.Out)"

Write-Host ''
Write-Host '3. empty leftover dir (half-finished removal) is cleaned up'
Reset-Fixture
$c = New-Repo mono main
New-Item -ItemType Directory -Force -Path (Join-Path (StoryDir '77003-zz-left') 'mono') | Out-Null
Write-Notes '77003-zz-left' '77003' 'zz-left' 'mono'
$res = Invoke-Remove @{ WT_ID = '77003'; WT_ASSUME_YES = '1' }
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'leftover dir gone' (-not (Test-Path -LiteralPath (Join-Path (StoryDir '77003-zz-left') 'mono'))) 'still there'
Check 'story folder gone' (-not (Test-Path -LiteralPath (StoryDir '77003-zz-left'))) 'folder still there'
Check 'named it a leftover' ($res.Out -match 'leftover') "no leftover line`n$($res.Out)"

Write-Host ''
Write-Host '4. a NON-empty non-worktree dir is left strictly alone'
Reset-Fixture
$c = New-Repo mono main
$junk = Join-Path (StoryDir '77004-zz-junk') 'mono'
New-Item -ItemType Directory -Force -Path $junk | Out-Null
Set-Content -LiteralPath (Join-Path $junk 'important.txt') -Value 'do not delete me'
$res = Invoke-Remove @{ WT_ID = '77004'; WT_ASSUME_YES = '1' }
Check 'file preserved' (Test-Path -LiteralPath (Join-Path $junk 'important.txt')) 'DELETED USER DATA'
Check 'reported as kept' ($res.Out -match 'not a worktree, and not empty') "no keep line`n$($res.Out)"
Check 'exit 3 (nothing removable)' ($res.Code -eq 3) "exit=$($res.Code)`n$($res.Out)"

Write-Host ''
Write-Host '5. WT_SKIP_DIRTY=1 keeps a worktree with uncommitted changes (exit 5)'
Reset-Fixture
$c = New-Repo mono main
$dirtyBranch = "$Prefix/77005-zz-dirty"
$wt = Add-Worktree $c '77005-zz-dirty' 'mono' $dirtyBranch
Set-Content -LiteralPath (Join-Path $wt 'f.txt') -Value 'uncommitted change'
$res = Invoke-Remove @{ WT_ID = '77005'; WT_ASSUME_YES = '1'; WT_SKIP_DIRTY = '1' }
Check 'exit 5' ($res.Code -eq 5) "exit=$($res.Code)`n$($res.Out)"
Check 'worktree kept' (Test-Path -LiteralPath (Join-Path $wt '.git')) 'deleted a dirty worktree!'
Check 'branch kept' (BranchExists $c $dirtyBranch) 'branch deleted'

Write-Host ''
Write-Host '6. WT_REPO scoping removes only that repo'
Reset-Fixture
$ca = New-Repo aaa main
$cb = New-Repo bbb main
$scopeBranch = "$Prefix/77006-zz-scope"
$wa = Add-Worktree $ca '77006-zz-scope' 'aaa' $scopeBranch
$wb = Add-Worktree $cb '77006-zz-scope' 'bbb' $scopeBranch
$res = Invoke-Remove @{ WT_ID = '77006'; WT_ASSUME_YES = '1'; WT_REPO = 'aaa' }
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'aaa removed' (-not (Test-Path -LiteralPath $wa)) 'aaa still there'
Check 'bbb kept' (Test-Path -LiteralPath (Join-Path $wb '.git')) 'bbb was removed!'
Check 'story folder kept (bbb still in it)' (Test-Path -LiteralPath (StoryDir '77006-zz-scope')) 'folder deleted'
Check 'bbb branch kept' (BranchExists $cb $scopeBranch) 'bbb branch deleted'

Write-Host ''
Write-Host '7. nothing matching the id -> exit 3'
Reset-Fixture
$c = New-Repo mono main
$res = Invoke-Remove @{ WT_ID = '77999'; WT_ASSUME_YES = '1' }
Check 'exit 3' ($res.Code -eq 3) "exit=$($res.Code)`n$($res.Out)"

$fixtureRoot = $Base
if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) {
  Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
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


