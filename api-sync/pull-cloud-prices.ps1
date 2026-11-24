<#
.SYNOPSIS
    Prices-only background puller for the addon author's PC.
    Downloads ONLY MarketFeedData.lua from your 24/7 GitHub Actions cloud feed
    directly into your live WoW: Forever AddOns folder — never touches your local
    addon code edits or Git working tree!
#>
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$WowPathFile = Join-Path $ProjectRoot "wow-path.txt"
$RepoCfgFile = Join-Path $ProjectRoot "friend-installer\repo-config.json"
$StatePath   = Join-Path $ScriptDir "cloud-pull-state.json"
$LogPath     = Join-Path $ScriptDir "sync.log"

function Write-PullLog([string]$Msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [CloudPull] $Msg"
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch {}
    if ($Force) { Write-Host $line -ForegroundColor Cyan }
}

if (-not (Test-Path $WowPathFile)) {
    Write-PullLog "ERROR: Missing wow-path.txt"
    exit 1
}
$wowPath = (Get-Content -Path $WowPathFile -Raw).Trim()
$addonDir = Join-Path $wowPath "Interface\AddOns\ForeverMarketWatch"
if (-not (Test-Path $addonDir)) {
    Write-PullLog "ERROR: Addon directory not found: $addonDir"
    exit 1
}

$rawBase = "https://raw.githubusercontent.com/Timbits247/ForeverMarketWatch/main"
if (Test-Path $RepoCfgFile) {
    try {
        $rc = Get-Content -Path $RepoCfgFile -Raw | ConvertFrom-Json
        if ($rc.rawBaseUrl) { $rawBase = ([string]$rc.rawBaseUrl).TrimEnd("/") }
    } catch {}
}

$state = @{ feedSyncedAt = 0; feedHash = "" }
if (Test-Path $StatePath) {
    try {
        $prev = Get-Content -Path $StatePath -Raw | ConvertFrom-Json
        if ($prev.feedSyncedAt) { $state.feedSyncedAt = [long]$prev.feedSyncedAt }
        if ($prev.feedHash)     { $state.feedHash     = [string]$prev.feedHash }
    } catch {}
}

$bust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
try {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers.Add("User-Agent", "ForeverMarketWatch-CloudPull/2.2")
    $manifest = ($wc.DownloadString("$rawBase/release/manifest.json?t=$bust")) | ConvertFrom-Json
} catch {
    Write-PullLog "Offline or GitHub unreachable, skipping tick."
    exit 0
}

$feedDest = Join-Path $addonDir "MarketFeedData.lua"
$needFeed = $Force -or (-not (Test-Path $feedDest)) -or ([long]$manifest.feedSyncedAt -gt [long]$state.feedSyncedAt) -or ($manifest.feedHash -and ($manifest.feedHash -ne $state.feedHash))

if (-not $needFeed) {
    exit 0
}

$tmp = "$feedDest.tmp"
$dl = New-Object System.Net.WebClient
$dl.Headers.Add("User-Agent", "ForeverMarketWatch-CloudPull/2.2")
$dl.DownloadFile("$rawBase/addon/ForeverMarketWatch/MarketFeedData.lua?t=$bust", $tmp)
if (Test-Path $feedDest) { Remove-Item -Path $feedDest -Force }
Move-Item -Path $tmp -Destination $feedDest -Force

$state.feedSyncedAt = [long]$manifest.feedSyncedAt
$state.feedHash     = [string]$manifest.feedHash
$state | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8

$dtLocal = [DateTimeOffset]::FromUnixTimeSeconds($state.feedSyncedAt).ToLocalTime().ToString("yyyy-MM-dd HH:mm")
Write-PullLog "Pulled 24/7 cloud MarketFeedData.lua (snapshot $dtLocal) into live WoW folder."
