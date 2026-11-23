<#
.SYNOPSIS
    1-Click Publisher for ForeverMarketWatch:
      1. Runs static verification (verify-addon.ps1)
      2. Pulls latest cloud price feed from GitHub cleanly (zero merge conflicts)
      3. Refreshes release/manifest.json
      4. Installs updated addon into your local WoW: Forever folder
      5. Commits & pushes to GitHub so all friends auto-update within 15 minutes!
#>
param(
    [string]$Message
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$VerifyScript   = Join-Path $ProjectRoot "scripts\verify-addon.ps1"
$ManifestScript = Join-Path $ProjectRoot "scripts\build-friend-installer.ps1"
$InstallScript  = Join-Path $ProjectRoot "install-addon.ps1"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ForeverMarketWatch — Verify, Install & Publish to GitHub" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Verify addon integrity first
Write-Host "[1/5] Running static verification..." -ForegroundColor Cyan
& $VerifyScript
if ($LASTEXITCODE -ne 0) {
    Write-Error "Verification failed! Fix errors before publishing."
    exit 1
}

# 2. Discard any local diff on cloud-managed files so git pull never conflicts
Write-Host "`n[2/5] Pulling latest cloud prices from GitHub..." -ForegroundColor Cyan
Push-Location $ProjectRoot
try {
    git checkout -- "addon/ForeverMarketWatch/MarketFeedData.lua" "cloud-sync/history.json" 2>$null | Out-Null
    git pull --rebase --autostash origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Error "git pull failed. Resolve any git issue before publishing."
        exit 1
    }

    # 3. Refresh release/manifest.json
    Write-Host "`n[3/5] Updating release/manifest.json..." -ForegroundColor Cyan
    & $ManifestScript -ManifestOnly

    # 4. Install into local WoW: Forever folder
    Write-Host "`n[4/5] Updating your local WoW: Forever addon..." -ForegroundColor Cyan
    if (Test-Path (Join-Path $ProjectRoot "wow-path.txt")) {
        & $InstallScript
    } else {
        Write-Host "Skipped local WoW install (wow-path.txt not found)." -ForegroundColor Yellow
    }

    # 5. Commit & push changes to GitHub
    Write-Host "`n[5/5] Publishing changes to GitHub..." -ForegroundColor Cyan
    $dirty = git status --porcelain
    if (-not $dirty) {
        Write-Host "Everything is already up to date on GitHub!" -ForegroundColor Green
        exit 0
    }

    if (-not $Message) {
        $Message = (Read-Host "Short update note (or press ENTER for default)").Trim()
        if (-not $Message) {
            $Message = "update: ForeverMarketWatch beta update ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
        }
    }

    git add .
    git commit -m $Message
    git push origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Error "git push failed."
        exit 1
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  PUBLISHED! Friends' PCs will auto-update within 15 min." -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
} finally {
    Pop-Location
}
