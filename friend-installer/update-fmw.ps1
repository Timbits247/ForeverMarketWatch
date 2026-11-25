<#
.SYNOPSIS
    Silent background updater for ForeverMarketWatch (Prices + Automatic Addon Updates).
    Installed to %LOCALAPPDATA%\ForeverMarketWatchUpdater\ and run every 15 minutes
    via Windows Task Scheduler (hidden, zero console windows).
#>
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$UpdaterDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $UpdaterDir "config.json"
$StatePath  = Join-Path $UpdaterDir "state.json"
$LogPath    = Join-Path $UpdaterDir "updater.log"

function Write-UpdateLog([string]$Msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg"
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch {}
    if ($Force) {
        Write-Host $line
    }
}

if (-not (Test-Path $ConfigPath)) {
    Write-UpdateLog "ERROR: Missing config.json"
    exit 1
}

$cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$wowPath = [string]$cfg.wowPath
$rawBase = ([string]$cfg.rawBaseUrl).TrimEnd("/")

if (-not $wowPath -or -not (Test-Path $wowPath)) {
    Write-UpdateLog "ERROR: WoW folder not found: $wowPath"
    exit 1
}

$addonDir = Join-Path $wowPath "Interface\AddOns\ForeverMarketWatch"
if (-not (Test-Path $addonDir)) {
    New-Item -ItemType Directory -Path $addonDir -Force | Out-Null
}

# Load previous sync state
$state = @{ addonHash = ""; feedSyncedAt = 0; feedHash = "" }
if (Test-Path $StatePath) {
    try {
        $prev = Get-Content -Path $StatePath -Raw | ConvertFrom-Json
        if ($prev.addonHash)    { $state.addonHash    = [string]$prev.addonHash }
        if ($prev.feedSyncedAt) { $state.feedSyncedAt = [long]$prev.feedSyncedAt }
        if ($prev.feedHash)     { $state.feedHash     = [string]$prev.feedHash }
    } catch {}
}

$bust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$manifestUrl = "$rawBase/release/manifest.json?t=$bust"

try {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers.Add("User-Agent", "ForeverMarketWatch-Updater/2.1")
    $manifestRaw = $wc.DownloadString($manifestUrl)
    $manifest = $manifestRaw | ConvertFrom-Json
} catch {
    Write-UpdateLog "Network check skipped (offline or repo unreachable): $_"
    exit 0
}

function Download-FileAtomic([string]$Url, [string]$DestPath) {
    $tmp = "$DestPath.tmp"
    $dl = New-Object System.Net.WebClient
    $dl.Headers.Add("User-Agent", "ForeverMarketWatch-Updater/2.1")
    $dl.DownloadFile($Url, $tmp)
    if (Test-Path $DestPath) {
        Remove-Item -Path $DestPath -Force
    }
    Move-Item -Path $tmp -Destination $DestPath -Force
}

$tocPath  = Join-Path $addonDir "ForeverMarketWatch.toc"
$feedPath = Join-Path $addonDir "MarketFeedData.lua"

$needCode = $Force -or (-not (Test-Path $tocPath)) -or ($manifest.addonHash -ne $state.addonHash)
$needFeed = $Force -or (-not (Test-Path $feedPath)) -or ([long]$manifest.feedSyncedAt -gt [long]$state.feedSyncedAt) -or ($manifest.feedHash -and ($manifest.feedHash -ne $state.feedHash))

if (-not $needCode -and -not $needFeed) {
    exit 0
}

$updatedCount = 0

if ($needCode) {
    Write-UpdateLog "Updating ForeverMarketWatch addon code (v$($manifest.addonVersion), hash $($manifest.addonHash))..."
    foreach ($fName in $manifest.files) {
        if ($fName -eq "MarketFeedData.lua") { continue }
        # Basic path-traversal safety check: only single-segment .lua/.toc filenames
        if ($fName -notmatch '^[A-Za-z0-9_\-\.]+\.(lua|toc)$') { continue }
        $fileUrl = "$rawBase/addon/ForeverMarketWatch/${fName}?t=$bust"
        $dest = Join-Path $addonDir $fName
        Download-FileAtomic $fileUrl $dest
        $updatedCount++
    }
    $state.addonHash = [string]$manifest.addonHash
}

if ($needFeed) {
    Write-UpdateLog "Downloading latest AH prices (syncedAt $($manifest.feedSyncedAt))..."
    $feedUrl = "$rawBase/addon/ForeverMarketWatch/MarketFeedData.lua?t=$bust"
    Download-FileAtomic $feedUrl $feedPath
    $state.feedSyncedAt = [long]$manifest.feedSyncedAt
    $state.feedHash = [string]$manifest.feedHash
    $updatedCount++
}

$state | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
Write-UpdateLog "Sync complete ($updatedCount file(s) updated)."

# Keep log small (last 150 lines)
if (Test-Path $LogPath) {
    try {
        $tail = Get-Content -Path $LogPath -Tail 150
        Set-Content -Path $LogPath -Value $tail -Encoding UTF8
    } catch {}
}
