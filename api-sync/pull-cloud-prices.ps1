<#
.SYNOPSIS
    Prices-only background puller for the addon author's PC.
    Downloads ONLY MarketFeedData.lua from your 24/7 GitHub Actions cloud feed
    directly into your live WoW: Forever AddOns folder — never touches your local
    addon code edits or Git working tree!
    Hardened with strict HTTPS GitHub origin allowlisting & SHA-256 feedHash verification.
#>
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$tlsFlags = [Net.SecurityProtocolType]::Tls12
if ([Enum]::IsDefined([Net.SecurityProtocolType], "Tls13")) {
    $tlsFlags = $tlsFlags -bor [Net.SecurityProtocolType]::Tls13
}
[Net.ServicePointManager]::SecurityProtocol = $tlsFlags

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
        if ($rc.rawBaseUrl) { $rawBase = ([string]$rc.rawBaseUrl).Trim().TrimEnd("/") }
    } catch {}
}

if ($rawBase -notmatch '^https://raw\.githubusercontent\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+$') {
    Write-PullLog "SECURITY ERROR: Refusing untrusted or non-HTTPS rawBaseUrl: $rawBase"
    exit 1
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
    $wc.Headers.Add("User-Agent", "ForeverMarketWatch-CloudPull/2.6")
    $manifest = ($wc.DownloadString("$rawBase/release/manifest.json?t=$bust")) | ConvertFrom-Json
} catch {
    Write-PullLog "Offline or GitHub unreachable, skipping tick."
    exit 0
}

if (-not $manifest -or $manifest.addonName -ne "ForeverMarketWatch") {
    Write-PullLog "WARNING: Invalid manifest received; skipping."
    exit 0
}

$feedDest = Join-Path $addonDir "MarketFeedData.lua"
$needFeed = $Force -or (-not (Test-Path $feedDest)) -or ([long]$manifest.feedSyncedAt -gt [long]$state.feedSyncedAt) -or ($manifest.feedHash -and ($manifest.feedHash -ne $state.feedHash))

if (-not $needFeed) {
    exit 0
}

$tmp = "$feedDest.tmp"
try {
    $dl = New-Object System.Net.WebClient
    $dl.Headers.Add("User-Agent", "ForeverMarketWatch-CloudPull/2.6")
    $dl.DownloadFile("$rawBase/addon/ForeverMarketWatch/MarketFeedData.lua?t=$bust", $tmp)

    if ($manifest.feedHash) {
        $iso = [System.Text.Encoding]::GetEncoding("iso-8859-1")
        $normBytes = $iso.GetBytes($iso.GetString([System.IO.File]::ReadAllBytes($tmp)).Replace("`r`n", "`n"))
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $actualHash = ([BitConverter]::ToString($sha.ComputeHash($normBytes)) -replace "-", "").ToLower().Substring(0, 16)
        } finally {
            $sha.Dispose()
        }
        if ($actualHash -ne ([string]$manifest.feedHash).ToLower().Substring(0, 16)) {
            throw "SHA-256 feedHash mismatch (expected $($manifest.feedHash), got $actualHash)"
        }
    }
    $firstLine = Get-Content -Path $tmp -TotalCount 1 -ErrorAction Stop
    if ($firstLine -notmatch '^--\s*MarketFeedData\.lua') {
        throw "Invalid MarketFeedData.lua header"
    }

    if (Test-Path $feedDest) { Remove-Item -Path $feedDest -Force }
    Move-Item -Path $tmp -Destination $feedDest -Force

    $state.feedSyncedAt = [long]$manifest.feedSyncedAt
    $state.feedHash     = [string]$manifest.feedHash
    $state | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8

    $dtLocal = [DateTimeOffset]::FromUnixTimeSeconds($state.feedSyncedAt).ToLocalTime().ToString("yyyy-MM-dd HH:mm")
    Write-PullLog "Pulled & SHA-256 verified 24/7 cloud MarketFeedData.lua (snapshot $dtLocal) into live WoW folder."
} catch {
    Write-PullLog "WARNING: Cloud feed pull aborted safely: $_"
    if (Test-Path $tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
}
