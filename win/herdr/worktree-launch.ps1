# worktree-launch.ps1 - herdr-plus quick-action entrypoint.
#
# herdr-plus runs actions inside the overlay picker (stdin redirected, TUI already
# tearing down). gum cannot prompt there. This opens a real tab and submits the
# target script into that pane via `herdr pane run`.
#
# Usage:
#   worktree-launch.ps1 development [ws] [cwd]                                    -> make-worktree.ps1 development
#   worktree-launch.ps1 remove [ws] [cwd] [story-id]                              -> worktree-remove.ps1
#   worktree-launch.ps1 new-review [ws] [cwd] [work-item-id]                      -> review-make.ps1 <id>
#   worktree-launch.ps1 remove-review [ws] [cwd] [work-item-id|empty]             -> review-remove.ps1 [<id>]
#   worktree-launch.ps1 reap [ws] [cwd]                                           -> story-reap.ps1
#   worktree-launch.ps1 az-sync [ws] [cwd]                                        -> az-watcher run
#
# There is deliberately NO 'review' action here. `make-worktree.ps1 review` still
# exists, but it is branch-driven: it wants a story id, a slug and a
# <repo>:<branch> list, which is a lot to type for something a tool can work out
# on its own. Only az-watcher drives it now - it reads your Azure assignments and
# supplies WT_ID / WT_SLUG / WT_BRANCHES_FILE itself. To create review worktrees
# by hand, run 'az-watcher.ps1 new-review' (or the 'Sync Azure Reviews' quick
# action). 'new-review' below is a different feature again: the read-only code
# review of a work item's pull requests (review-make.ps1).
#
$ErrorActionPreference = 'Stop'

$Action = if ($args.Count -ge 1) { $args[0] } else { '' }
$Ws = if ($args.Count -ge 2) { $args[1] } else { '' }
$Cwd = if ($args.Count -ge 3) { $args[2] } else { '' }
$StoryId = if ($args.Count -ge 4) { $args[3] } else { '' }

$BinDir = Join-Path $env:USERPROFILE 'bin'

switch ($Action) {
  'development' {
    $Script = Join-Path $BinDir 'make-worktree.ps1'
    $RunArgs = $Action
    $Label = 'New Dev Worktree'
  }
  'remove' {
    $Script = Join-Path $BinDir 'worktree-remove.ps1'
    $RunArgs = $StoryId
    $Label = 'Delete Story Worktree'
  }
  'new-review' {
    if (-not $StoryId) {
      Write-Error 'new-review needs the Azure DevOps work item id'
      exit 1
    }
    $Script = Join-Path $BinDir 'review-make.ps1'
    $RunArgs = $StoryId
    $Label = "Review $StoryId"
  }
  'remove-review' {
    # An empty id is meaningful here: it means "examine every review".
    $Script = Join-Path $BinDir 'review-remove.ps1'
    $RunArgs = $StoryId
    $Label = if ($StoryId) { "Clean Up Review $StoryId" } else { 'Clean Up Reviews' }
  }
  'reap' {
    # No args: the script finds the finished stories itself and asks before it
    # deletes anything. A scheduled run passes --yes instead, and never comes
    # through here.
    $Script = Join-Path $BinDir 'story-reap.ps1'
    $RunArgs = ''
    $Label = 'Clean Up Closed Stories'
  }
  'az-sync' {
    $Script = Join-Path $BinDir 'az-watcher.ps1'
    $RunArgs = 'run'
    $Label = 'Sync Azure Reviews'
  }
  default {
    Write-Error ('usage: worktree-launch.ps1 ' +
      '<development|new-review|remove-review|remove|reap|az-sync> ' +
      '[workspace_id] [cwd] [story-or-work-item-id]')
    exit 1
  }
}

function Need-Cmd([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Write-Error "missing tool: $Name"
    exit 1
  }
}

Need-Cmd herdr
Need-Cmd jq

if (-not (Test-Path -LiteralPath $Script)) {
  Write-Error "missing $Script (run install.ps1)"
  exit 1
}

$herdrArgs = @('tab', 'create', '--label', $Label, '--focus')
if ($Ws) { $herdrArgs += @('--workspace', $Ws) }
if ($Cwd) { $herdrArgs += @('--cwd', $Cwd) }

$out = & herdr @herdrArgs 2>&1 | Out-String
$pane = $out | jq -r '.result.root_pane.pane_id // empty'
if (-not $pane) {
  Write-Error "herdr tab create failed:`n$out"
  exit 1
}

# Quote for PowerShell pane: absolute path + optional args.
$scriptLit = "'" + ($Script -replace "'", "''") + "'"
$cmd = if ($RunArgs) {
  $argLit = "'" + ($RunArgs -replace "'", "''") + "'"
  "& $scriptLit $argLit"
} else {
  "& $scriptLit"
}

& herdr pane run $pane $cmd
if ($LASTEXITCODE -ne 0) {
  Write-Error "herdr pane run failed for pane $pane"
  exit 1
}
exit 0
