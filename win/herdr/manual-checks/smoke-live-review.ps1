# Opt-in LIVE smoke: real az + clones under SRC_ROOT. Never called from run-all.
#
# usage: smoke-live-review.ps1 <work-item-id>
#        $env:WT_REVIEW_SRC_ROOT = "$env:USERPROFILE\source\repos"; .\smoke-live-review.ps1 23597
#
# Creates a review layout for the work item, then prints cleanup hints.
param(
  [Parameter(Position = 0)]
  [string]$WorkItemId = $env:WT_REVIEW_ID
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$id = "$WorkItemId".Trim()
if (-not $id -or $id -notmatch '^\d+$') {
  Write-Error "usage: smoke-live-review.ps1 <work-item-id>`nRefusing to run without an explicit numeric work item id."
  exit 2
}
if ($env:WT_REVIEW_AZ) {
  Write-Error 'WT_REVIEW_AZ is set; unset it for a live run against real az.'
  exit 2
}

$srcNote = if ($env:WT_REVIEW_SRC_ROOT) { $env:WT_REVIEW_SRC_ROOT } else { 'default from review-make.ps1' }
Write-Host "-> live review-make for work item $id (real az, SRC_ROOT=$srcNote)"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'review-make.ps1') $id
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ''
Write-Host "OK review created for $id."
Write-Host 'Cleanup when done:'
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File $(Join-Path $Root 'review-remove.ps1') $id --yes"
