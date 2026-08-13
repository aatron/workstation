# install.ps1 - wire this folder's Herdr worktree workflow into the local machine.
# Run from Windows PowerShell. Safe to re-run (idempotent).
#
# Never overwrites an existing %APPDATA%\herdr\config.toml.
#
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BinDir = Join-Path $env:USERPROFILE 'bin'
$LocalBin = Join-Path $env:USERPROFILE '.local\bin'
$TargetScript = Join-Path $BinDir 'make-worktree.ps1'
$TargetLaunch = Join-Path $BinDir 'worktree-launch.ps1'
$TargetRemove = Join-Path $BinDir 'worktree-remove.ps1'
$TargetReview = Join-Path $BinDir 'review-make.ps1'
$TargetReviewRemove = Join-Path $BinDir 'review-remove.ps1'
$TargetStoryReap = Join-Path $BinDir 'story-reap.ps1'
$TargetAzWatcher = Join-Path $BinDir 'az-watcher.ps1'

function Test-Have([string]$Name) {
  [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-VersionGe([string]$A, [string]$B) {
  $parse = {
    param($v)
    ($v -split '\.') | ForEach-Object { ($_ -replace '[^0-9].*', '') -as [int] }
  }
  $aa = @(& $parse $A)
  $bb = @(& $parse $B)
  $n = [Math]::Max($aa.Count, $bb.Count)
  for ($i = 0; $i -lt $n; $i++) {
    $x = if ($i -lt $aa.Count -and $null -ne $aa[$i]) { $aa[$i] } else { 0 }
    $y = if ($i -lt $bb.Count -and $null -ne $bb[$i]) { $bb[$i] } else { 0 }
    if ($x -gt $y) { return $true }
    if ($x -lt $y) { return $false }
  }
  return $true
}

function Ensure-PathDirs {
  New-Item -ItemType Directory -Force -Path $BinDir, $LocalBin | Out-Null
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $userPath) { $userPath = '' }
  $parts = @($userPath -split ';' | Where-Object { $_ })
  $changed = $false
  foreach ($dir in @($BinDir, $LocalBin)) {
    $exists = $parts | Where-Object { $_.TrimEnd('\') -ieq $dir.TrimEnd('\') }
    if (-not $exists) {
      $parts = @($dir) + $parts
      $changed = $true
      Write-Host "-> PATH: prepended $dir to user PATH"
    }
  }
  if ($changed) {
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
  }
  $env:Path = "$BinDir;$LocalBin;$env:Path"
}

function Ensure-Herdr {
  $ver = ''
  if (Test-Have herdr) {
    $raw = & herdr --version 2>$null | Out-String
    if ($raw -match '(\d+\.\d+(?:\.\d+)?)') { $ver = $Matches[1] }
    if ($ver -and (Test-VersionGe $ver '0.7.5')) {
      Write-Host "-> herdr: $ver (>= 0.7.5)"
      return
    }
    Write-Host "-> herdr: found $(if ($ver) { $ver } else { 'unknown' }), need >= 0.7.5 - upgrading"
  } else {
    Write-Host '-> herdr: not found - installing'
  }
  # Official Windows installer: https://herdr.dev/docs/windows-beta/
  Invoke-RestMethod https://herdr.dev/install.ps1 | Invoke-Expression
  $env:Path = "$BinDir;$LocalBin;$env:LOCALAPPDATA\Programs\Herdr\bin;$env:Path"
  if (-not (Test-Have herdr)) {
    Write-Error "herdr install finished but 'herdr' is not on PATH"
    exit 1
  }
  $raw = & herdr --version 2>$null | Out-String
  if ($raw -match '(\d+\.\d+(?:\.\d+)?)') { $ver = $Matches[1] }
  Write-Host "-> herdr: $(if ($ver) { $ver } else { 'installed' })"
}

function Ensure-HerdrConfig {
  $cfg = if ($env:HERDR_CONFIG_PATH) { $env:HERDR_CONFIG_PATH } else {
    Join-Path $env:APPDATA 'herdr\config.toml'
  }
  if (Test-Path -LiteralPath $cfg) {
    Write-Host "-> config: exists (left unchanged): $cfg"
    return
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cfg) | Out-Null
  & herdr --default-config | Set-Content -LiteralPath $cfg -Encoding utf8
  Write-Host "-> config: created default at $cfg"
}

function Get-GithubLatestTag([string]$Repo) {
  $headers = @{ 'User-Agent' = 'vscodesettings-herdr-install' }
  $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers
  return $rel.tag_name
}

function Ensure-Gum {
  if (Test-Have gum) {
    Write-Host "-> gum: $((Get-Command gum).Source)"
    return
  }
  Write-Host "-> gum: installing from GitHub Releases into $BinDir"
  $arch = if ([Environment]::Is64BitOperatingSystem) { 'x86_64' } else { 'i386' }
  if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }
  $tag = Get-GithubLatestTag 'charmbracelet/gum'
  $ver = $tag.TrimStart('v')
  if (-not $ver) { Write-Error 'could not resolve latest gum version'; exit 1 }
  $asset = "gum_${ver}_Windows_${arch}.zip"
  $url = "https://github.com/charmbracelet/gum/releases/download/$tag/$asset"
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("gum-" + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    $zip = Join-Path $tmp 'gum.zip'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $gumBin = Get-ChildItem -Path $tmp -Recurse -Filter 'gum.exe' | Select-Object -First 1
    if (-not $gumBin) { Write-Error "gum binary missing from $asset"; exit 1 }
    Copy-Item -LiteralPath $gumBin.FullName -Destination (Join-Path $BinDir 'gum.exe') -Force
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Host "-> gum: $(Join-Path $BinDir 'gum.exe')"
}

function Ensure-Jq {
  if (Test-Have jq) {
    Write-Host "-> jq: $((Get-Command jq).Source)"
    return
  }
  Write-Host "-> jq: installing from GitHub Releases into $BinDir"
  $tag = Get-GithubLatestTag 'jqlang/jq'
  $asset = 'jq-windows-amd64.exe'
  $url = "https://github.com/jqlang/jq/releases/download/$tag/$asset"
  $dest = Join-Path $BinDir 'jq.exe'
  Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
  Write-Host "-> jq: $dest"
}

function Ensure-Micro {
  if (Test-Have micro) {
    Write-Host "-> micro: $((Get-Command micro).Source)"
    return
  }
  Write-Host "-> micro: installing from GitHub Releases into $BinDir"
  $tag = Get-GithubLatestTag 'zyedidia/micro'
  $ver = $tag.TrimStart('v')
  $asset = "micro-$ver-win64.zip"
  $url = "https://github.com/zyedidia/micro/releases/download/$tag/$asset"
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("micro-" + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    $zip = Join-Path $tmp 'micro.zip'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $microBin = Get-ChildItem -Path $tmp -Recurse -Filter 'micro.exe' | Select-Object -First 1
    if (-not $microBin) { Write-Error "micro binary missing from $asset"; exit 1 }
    Copy-Item -LiteralPath $microBin.FullName -Destination (Join-Path $BinDir 'micro.exe') -Force
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Host "-> micro: $(Join-Path $BinDir 'micro.exe')"
}

function Ensure-Git {
  if (Test-Have git) {
    Write-Host "-> git: $((Get-Command git).Source)"
    return
  }
  Write-Error 'git is required. Install Git for Windows: https://git-scm.com/download/win'
  exit 1
}

function Ensure-OptionalCli([string]$Name, [string]$Hint) {
  if (Test-Have $Name) {
    Write-Host "-> ${Name}: $((Get-Command $Name).Source)"
  } else {
    Write-Warning "${Name}: MISSING - $Hint"
  }
}

function Install-Plugin([string]$Spec) {
  Write-Host "-> plugin: herdr plugin install $Spec"
  # Non-interactive installs need --yes after the repo (herdr 0.7.5).
  & herdr plugin install $Spec --yes
}

function Install-File([string]$Src, [string]$Dest) {
  if ((Test-Path -LiteralPath $Dest) -and
      ((Get-FileHash -LiteralPath $Src).Hash -eq (Get-FileHash -LiteralPath $Dest).Hash)) {
    Write-Host "-> unchanged: $Dest"
    return
  }
  $parent = Split-Path -Parent $Dest
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Copy-Item -LiteralPath $Src -Destination $Dest -Force
  Write-Host "-> installed: $Dest"
}

# Install ~/bin/<name>.ps1 so it ALWAYS runs the current file in this repo.
#
# A symlink is ideal but needs Developer Mode or admin. The fallback is a
# generated forwarder, NOT a hardlink or a copy: a hardlink survives in-place
# writes but is silently broken by any editor that replaces the file (git
# checkout, VS Code, most tooling), after which ~/bin keeps running an old
# snapshot of the script while the repo shows the fix. That failure mode is
# invisible and was worth designing out. A forwarder cannot go stale.
function Install-Shim([string]$Src, [string]$Dest) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dest) | Out-Null
  if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
  try {
    New-Item -ItemType SymbolicLink -Path $Dest -Target $Src -ErrorAction Stop | Out-Null
    Write-Host "-> shim:  $Dest -> $Src (symlink)"
    return
  } catch {
    # fall through to the forwarder
  }
  $srcLit = "'" + ($Src -replace "'", "''") + "'"
  Set-Content -LiteralPath $Dest -Encoding utf8 -Value @(
    '# AUTO-GENERATED by install.ps1 - do not edit.'
    "# Forwards to the working copy so edits there take effect immediately:"
    "#   $Src"
    "`$ErrorActionPreference = 'Continue'"
    "if (-not (Test-Path -LiteralPath $srcLit)) {"
    "  Write-Error 'missing source script: $Src (re-run install.ps1)'"
    '  exit 1'
    '}'
    "& $srcLit @args"
    '# $LASTEXITCODE is $null when the target never ran a native command and'
    '# never called exit; that is a clean run, so report 0.'
    'if ($null -eq $LASTEXITCODE) { exit 0 }'
    'exit $LASTEXITCODE'
  )
  Write-Host "-> shim:  $Dest -> $Src (forwarder)"
}

function Ensure-ReviewrConfig {
  $pluginDir = (& herdr plugin config-dir persiyanov.reviewr 2>$null | Out-String).Trim()
  if (-not $pluginDir) {
    Write-Error 'reviewr config dir missing (plugin install may have failed)'
    exit 1
  }
  New-Item -ItemType Directory -Force -Path $pluginDir | Out-Null
  $cfg = Join-Path $pluginDir 'config.toml'
  $managed = @(
    '# BEGIN vscodesettings herdr-reviewr defaults'
    'auto_open = false'
    'toggle_placement = "overlay"'
    'toggle_direction = "right"'
    'default_scope = "branch"'
    '# END vscodesettings herdr-reviewr defaults'
    ''
  )
  $rest = @()
  if (Test-Path -LiteralPath $cfg) {
    $skip = $false
    $inTable = $false
    foreach ($line in Get-Content -LiteralPath $cfg) {
      if ($line -match '^# BEGIN vscodesettings herdr-reviewr defaults$') { $skip = $true; continue }
      if ($line -match '^# END vscodesettings herdr-reviewr defaults$') { $skip = $false; continue }
      if ($skip) { continue }
      if ($line -match '^\s*\[') { $inTable = $true }
      if (-not $inTable -and $line -match '^\s*(auto_open|toggle_placement|toggle_direction|default_scope)\s*=') {
        continue
      }
      $rest += $line
    }
  }
  $newContent = ($managed + $rest) -join "`n"
  if ((Test-Path -LiteralPath $cfg) -and ((Get-Content -LiteralPath $cfg -Raw) -replace "`r", '') -eq $newContent) {
    Write-Host "-> reviewr config: unchanged ($cfg)"
    return
  }
  Set-Content -LiteralPath $cfg -Value $newContent -Encoding utf8 -NoNewline
  Add-Content -LiteralPath $cfg -Value ''
  Write-Host "-> reviewr config: installed managed defaults ($cfg)"
}

# ===========================================================================
Write-Host '=== 1/3 Prerequisites ==='
Ensure-PathDirs
Ensure-Git
Ensure-Herdr
Ensure-HerdrConfig
Ensure-Gum
Ensure-Jq
Ensure-Micro
Ensure-OptionalCli claude 'Install Claude Code CLI for Windows'
Ensure-OptionalCli agent 'Install Cursor Agent CLI for Windows'
Ensure-OptionalCli az 'Install Azure CLI yourself (not auto-installed)'

Write-Host ''
Write-Host '=== 2/3 Herdr plugins ==='
Install-Plugin 'cloudmanic/herdr-plus'
Install-Plugin 'senna-lang/herdr-agent-usage'
Install-Plugin 'persiyanov/herdr-reviewr'
Ensure-ReviewrConfig

$PluginDir = (& herdr plugin config-dir cloudmanic.herdr-plus 2>$null | Out-String).Trim()
if (-not $PluginDir -or -not (Test-Path -LiteralPath $PluginDir)) {
  Write-Error "herdr-plus config dir missing (plugin install may have failed): '$PluginDir'"
  exit 1
}
$QaDir = Join-Path $PluginDir 'quick-actions'
$LayoutDir = Join-Path $PluginDir 'worktrees'
Write-Host "herdr-plus config: $PluginDir"
New-Item -ItemType Directory -Force -Path $QaDir, $LayoutDir | Out-Null

Write-Host ''
Write-Host '=== 3/3 Worktree workflow files ==='
Install-Shim (Join-Path $ScriptDir 'worktree-make.ps1') $TargetScript
Install-Shim (Join-Path $ScriptDir 'worktree-launch.ps1') $TargetLaunch
Install-Shim (Join-Path $ScriptDir 'worktree-remove.ps1') $TargetRemove
Install-Shim (Join-Path $ScriptDir 'review-make.ps1') $TargetReview
Install-Shim (Join-Path $ScriptDir 'review-remove.ps1') $TargetReviewRemove
Install-Shim (Join-Path $ScriptDir 'story-reap.ps1') $TargetStoryReap
Install-Shim (Join-Path $ScriptDir 'az-watcher\az-watcher.ps1') $TargetAzWatcher

Install-File (Join-Path $ScriptDir 'new-worktree-dev.toml') (Join-Path $QaDir 'new-worktree-dev.toml')
Install-File (Join-Path $ScriptDir 'remove-worktree.toml') (Join-Path $QaDir 'remove-worktree.toml')
Install-File (Join-Path $ScriptDir 'new-review.toml') (Join-Path $QaDir 'new-review.toml')
Install-File (Join-Path $ScriptDir 'remove-review.toml') (Join-Path $QaDir 'remove-review.toml')
Install-File (Join-Path $ScriptDir 'reap-stories.toml') (Join-Path $QaDir 'reap-stories.toml')
Install-File (Join-Path $ScriptDir 'az-watcher.toml') (Join-Path $QaDir 'az-watcher.toml')

# Retired quick actions. herdr-plus lists whatever TOMLs are in quick-actions/,
# so a copy left by an earlier install keeps showing in prefix+down forever.
#
# new-worktree-review.toml is gone because creating review worktrees by hand
# meant typing a story id, a slug and a <repo>:<branch> list - all of which
# az-watcher already derives from your Azure assignments. Use 'Sync Azure
# Reviews' instead. (make-worktree.ps1 review itself is still there; az-watcher
# is now its only caller.)
foreach ($retired in @('new-worktree-dev-windows.toml', 'new-worktree-review.toml')) {
  $RetiredQa = Join-Path $QaDir $retired
  if (Test-Path -LiteralPath $RetiredQa) {
    Remove-Item -LiteralPath $RetiredQa -Force
    Write-Host "-> removed:   $RetiredQa (retired quick action)"
  }
}
Install-File (Join-Path $ScriptDir 'worktree-layout.toml') (Join-Path $LayoutDir 'worktree-layout.toml')

$cfgPath = if ($env:HERDR_CONFIG_PATH) { $env:HERDR_CONFIG_PATH } else {
  Join-Path $env:APPDATA 'herdr\config.toml'
}

Write-Host ''
Write-Host '=== Automated install finished ==='
Write-Host '  (Existing root Herdr config.toml is never overwritten; defaults are written only if missing.)'
Write-Host ''
Write-Host 'Manual next steps - see README.md for full snippets:'
Write-Host "  1. Edit machine paths at the top of:"
Write-Host "       $(Join-Path $ScriptDir 'worktree-make.ps1')"
Write-Host '     (SRC_ROOT, BRANCH_PREFIX)'
Write-Host "       $(Join-Path $ScriptDir 'review-make.ps1')"
Write-Host '     (SRC_ROOT, REVIEW_MODEL, REVIEW_PERMISSION_MODE)'
Write-Host '  2. Merge README Herdr settings into config.toml by hand, including:'
Write-Host '       [worktrees] directory = "C:\\Users\\<you>\\source\\worktrees"'
Write-Host '       [ui.sidebar.spaces] rows = [["$tree", "state_icon", "workspace"]]'
Write-Host '         ($tree must precede state_icon - it is the connector drawn under a'
Write-Host '          story row for each of its repos, and under Review for each review;'
Write-Host '          without it the bullets stay left)'
Write-Host '       [theme.custom] accent = "#ffffff"   AND   [ui] accent = "#ffffff"'
Write-Host '         (herdr paints the SELECTED sidebar row, state icon included, in the'
Write-Host '          accent colour; the default pink turns a selected row icon magenta.'
Write-Host '          Set BOTH: [theme.custom] accent overrides the theme token, [ui]'
Write-Host '          accent is the chrome colour the selected row actually uses.'
Write-Host '          accent is NOT valid under [ui.sidebar.spaces] - herdr documents it'
Write-Host '          just below that table, so it strands easily - see README)'
Write-Host "       $cfgPath"
Write-Host '  3. Seed Agent Usage (prints snippets; does not rewrite herdr config.toml):'
Write-Host '       herdr plugin action invoke usagebar.setup'
Write-Host '     Paste any sidebar/toast/key snippets it prints if not already in config.'
Write-Host '  4. Optional toast delivery - prefer pasting the README [ui.toast] block'
Write-Host '     instead of usagebar.enable-toast (that command can append to config.toml).'
Write-Host '  5. herdr config check   # fix any unknown keys before continuing'
Write-Host '  6. herdr server reload-config'
Write-Host '     (named sessions: herdr --session <name> server reload-config;'
Write-Host "      bare 'herdr server reload-config' only hits the default session)"
Write-Host '  7. Dry-run: prefix+down -> New Dev Worktree'
Write-Host '     Code review: prefix+down -> New Code Review (asks for a work item id;'
Write-Host '     needs az login, reads Azure DevOps and never writes to it)'
Write-Host '     Cleanup:     prefix+down -> Clean Up Finished Reviews (blank id = all).'
Write-Host '     To run it on a schedule, dry-run it first, then:'
Write-Host "       review-remove.ps1 --yes    # from $TargetReviewRemove"
Write-Host '     Closed stories: prefix+down -> Clean Up Closed Stories. Removes a'
Write-Host '     development story only when it has >= 1 PR and all of them closed;'
Write-Host '     a story with no PRs is never touched. Dry-run it first:'
Write-Host "       story-reap.ps1 --dry-run   # from $TargetStoryReap"
Write-Host '     then, once trusted, a 10-minute scheduled task running:'
Write-Host '       story-reap.ps1 --yes'
Write-Host '  8. Azure sync (az-watcher) - NOT auto-installed, do this by hand:'
Write-Host '       install the Azure CLI, then:'
Write-Host '         az login'
Write-Host "         az devops configure -d organization=https://dev.azure.com/<org> project='<project>'"
Write-Host '       verify:  az-watcher.ps1 run --dry-run --window 0'
Write-Host "       details: $(Join-Path $ScriptDir 'az-watcher\README.md')"
Write-Host ''
Write-Host 'Windows beta: plugins are preview; herdr --remote is unsupported.'
Write-Host '  https://herdr.dev/docs/windows-beta/'
Write-Host 'If gum/jq/micro are missing in a new terminal, open a new PowerShell (PATH refresh).'
Write-Host 'Primary clones must exist under SRC_ROOT\<repo-name>.'
Write-Host ''
& herdr plugin list
Write-Host ''
Write-Host 'CLI check:'
foreach ($c in @('herdr', 'gum', 'git', 'micro', 'jq', 'claude', 'agent', 'az')) {
  $src = (Get-Command $c -ErrorAction SilentlyContinue).Source
  Write-Host ("  {0,-8} {1}" -f $c, $(if ($src) { $src } else { 'MISSING' }))
}
