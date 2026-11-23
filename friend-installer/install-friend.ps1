<#
.SYNOPSIS
    1-Click Hands-Off Installer for ForeverMarketWatch (Addon + Automatic Live Prices).
    Run ONCE: auto-detects WoW: Forever, downloads the addon + latest AH prices, and
    installs a silent Windows background task so you never have to click anything again.
#>

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoCfgPath = Join-Path $ScriptDir "repo-config.json"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ForeverMarketWatch — 1-Click Installer & Auto-Updater" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $RepoCfgPath)) {
    Write-Error "Missing repo-config.json next to installer."
    exit 1
}

$repoCfg = Get-Content -Path $RepoCfgPath -Raw | ConvertFrom-Json
$rawBaseUrl = ([string]$repoCfg.rawBaseUrl).Trim().TrimEnd("/")

if (-not $rawBaseUrl -or $rawBaseUrl -match "YOUR_GITHUB_USERNAME") {
    Write-Host "This installer has not been configured with a GitHub repo URL yet." -ForegroundColor Red
    Write-Host "Ask the addon author to run scripts\build-friend-installer.ps1 first." -ForegroundColor Yellow
    exit 1
}

# 1. Auto-detect World of Warcraft\_forever_ directory
function Find-WowForeverPath {
    $candidates = New-Object System.Collections.Generic.List[string]

    # Check common drives & paths
    foreach ($drive in @("C:", "D:", "E:", "F:", "G:", "H:")) {
        if (-not (Test-Path "$drive\")) { continue }
        $candidates.Add("$drive\Program Files (x86)\World of Warcraft\_forever_")
        $candidates.Add("$drive\Program Files\World of Warcraft\_forever_")
        $candidates.Add("$drive\World of Warcraft\_forever_")
        $candidates.Add("$drive\Games\World of Warcraft\_forever_")
        $candidates.Add("$drive\Blizzard\World of Warcraft\_forever_")
    }

    # Check Windows Registry for Blizzard WoW install location
    foreach ($regPath in @(
        "HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
        "HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft"
    )) {
        try {
            $val = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).InstallPath
            if ($val) {
                $base = Split-Path -Parent $val.TrimEnd("\")
                $candidates.Add((Join-Path $base "_forever_"))
                $candidates.Add((Join-Path $val.TrimEnd("\") "_forever_"))
            }
        } catch {}
    }

    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) {
            return $p
        }
    }
    return $null
}

$detected = Find-WowForeverPath
$wowPath = $null

if ($detected) {
    Write-Host "Detected WoW: Forever folder:" -ForegroundColor Green
    Write-Host "  $detected" -ForegroundColor White
    $ans = (Read-Host "`nPress ENTER to use this folder, or paste a different path").Trim()
    $wowPath = if ($ans) { $ans.Trim('"') } else { $detected }
} else {
    Write-Host "Could not auto-detect your WoW: Forever folder." -ForegroundColor Yellow
    Write-Host "Example: C:\Program Files (x86)\World of Warcraft\_forever_" -ForegroundColor Gray
    $wowPath = (Read-Host "Paste your World of Warcraft\_forever_ folder path").Trim().Trim('"')
}

# Allow pasting parent "World of Warcraft" folder too
if ($wowPath -and (Test-Path (Join-Path $wowPath "_forever_"))) {
    $wowPath = Join-Path $wowPath "_forever_"
}

if (-not $wowPath -or -not (Test-Path $wowPath)) {
    Write-Error "Folder does not exist: $wowPath"
    exit 1
}

# 2. Install persistent updater into %LOCALAPPDATA%\ForeverMarketWatchUpdater\
#    (Works even if the friend deletes this ZIP/folder afterward!)
$updaterDir = Join-Path $env:LOCALAPPDATA "ForeverMarketWatchUpdater"
if (-not (Test-Path $updaterDir)) {
    New-Item -ItemType Directory -Path $updaterDir -Force | Out-Null
}

Copy-Item -Path (Join-Path $ScriptDir "update-fmw.ps1") -Destination (Join-Path $updaterDir "update-fmw.ps1") -Force
Copy-Item -Path (Join-Path $ScriptDir "run-hidden.vbs") -Destination (Join-Path $updaterDir "run-hidden.vbs") -Force

$cfg = [ordered]@{
    wowPath    = $wowPath
    rawBaseUrl = $rawBaseUrl
}
$cfg | ConvertTo-Json | Set-Content -Path (Join-Path $updaterDir "config.json") -Encoding UTF8

# 3. Download addon + latest AH prices immediately
Write-Host "`nDownloading ForeverMarketWatch + latest AH prices..." -ForegroundColor Cyan
& (Join-Path $updaterDir "update-fmw.ps1") -Force

# 4. Register silent background task (every 15 minutes + at logon, zero popups)
Write-Host "`nSetting up automatic silent background updates (every 15 min)..." -ForegroundColor Cyan
$taskName = "ForeverMarketWatchAutoSync"
$vbsPath  = Join-Path $updaterDir "run-hidden.vbs"

try {
    $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbsPath`""
    $triggerRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
        -RepetitionInterval (New-TimeSpan -Minutes 15) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 3)

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger @($triggerRepeat, $triggerLogon) `
        -Settings $settings `
        -Description "Silently updates ForeverMarketWatch addon & hourly AH prices every 15 minutes." `
        -Force | Out-Null

    Write-Host "Silent background auto-updater installed!" -ForegroundColor Green
} catch {
    Write-Host "Note: Could not register Scheduled Task automatically: $_" -ForegroundColor Yellow
    Write-Host "The addon is still installed and ready to play!" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  ALL DONE! You never need to run this installer again." -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  * Addon installed to: $wowPath\Interface\AddOns\ForeverMarketWatch" -ForegroundColor White
Write-Host "  * Live AH prices & beta updates will sync silently every 15 min." -ForegroundColor White
Write-Host "  * Restart WoW: Forever once, then click the gold coin minimap button or type /fmw" -ForegroundColor Cyan
Write-Host ""
