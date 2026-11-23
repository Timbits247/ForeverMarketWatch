<#
.SYNOPSIS
    Installs or updates ForeverMarketWatch into your WoW: Forever AddOns folder.
#>
param(
    [string]$WowPath
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$AddonSource = Join-Path $ProjectRoot "addon\ForeverMarketWatch"
$PathFile    = Join-Path $ProjectRoot "wow-path.txt"

if (-not $WowPath) {
    if (Test-Path $PathFile) {
        $WowPath = (Get-Content -Path $PathFile -Raw).Trim()
    }
}

if (-not $WowPath) {
    Write-Error "Could not determine WoW: Forever path. Update wow-path.txt or pass -WowPath."
    exit 1
}

if (-not (Test-Path $WowPath)) {
    Write-Error "WoW: Forever path does not exist: $WowPath`nEdit wow-path.txt to point to your _forever_ directory."
    exit 1
}

$AddOnsRoot = Join-Path $WowPath "Interface\AddOns"
if (-not (Test-Path $AddOnsRoot)) {
    New-Item -ItemType Directory -Path $AddOnsRoot -Force | Out-Null
}

$TargetDir = Join-Path $AddOnsRoot "ForeverMarketWatch"
if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

# Copy files in place (without deleting $TargetDir) so WoW's /reload always picks up edits
Copy-Item -Path (Join-Path $AddonSource "*") -Destination $TargetDir -Recurse -Force
Write-Host "Installed ForeverMarketWatch to: $TargetDir" -ForegroundColor Green
Write-Host "If WoW: Forever is already open, run /reload (or restart the client if new files were added to the TOC)." -ForegroundColor Cyan
