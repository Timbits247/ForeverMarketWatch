<#
.SYNOPSIS
    Silent background updater for ForeverMarketWatch (Prices + Automatic Addon Updates).
    Installed to %LOCALAPPDATA%\ForeverMarketWatchUpdater\ and run every 15 minutes
    via Windows Task Scheduler (hidden, zero console windows).
    Hardened with strict HTTPS GitHub origin validation, canonical path containment,
    and SHA-256 cryptographic integrity checks before swapping files.
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
$rawBase = ([string]$cfg.rawBaseUrl).Trim().TrimEnd("/")

# Security: strictly allowlist HTTPS raw.githubusercontent.com origins only
if ($rawBase -notmatch '^https://raw\.githubusercontent\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+$') {
    Write-UpdateLog "SECURITY ERROR: Refusing untrusted or non-HTTPS rawBaseUrl: $rawBase"
    exit 1
}

if (-not $wowPath -or -not (Test-Path $wowPath)) {
    Write-UpdateLog "ERROR: WoW folder not found: $wowPath"
    exit 1
}

$addonDir = Join-Path $wowPath "Interface\AddOns\ForeverMarketWatch"
if (-not (Test-Path $addonDir)) {
    New-Item -ItemType Directory -Path $addonDir -Force | Out-Null
}
$addonDirFull = [IO.Path]::GetFullPath($addonDir).TrimEnd('\') + '\'

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
    $wc.Headers.Add("User-Agent", "ForeverMarketWatch-Updater/2.6")
    $manifestRaw = $wc.DownloadString($manifestUrl)
    $manifest = $manifestRaw | ConvertFrom-Json
} catch {
    Write-UpdateLog "Network check skipped (offline or repo unreachable): $_"
    exit 0
}

if (-not $manifest -or $manifest.addonName -ne "ForeverMarketWatch" -or -not $manifest.addonHash -or ($manifest.addonHash -notmatch '^[0-9a-f]{16,64}$')) {
    Write-UpdateLog "SECURITY WARNING: Invalid manifest payload received (possible captive portal); aborting update."
    exit 0
}

function Download-ToFile([string]$Url, [string]$DestFile) {
    $dl = New-Object System.Net.WebClient
    $dl.Headers.Add("User-Agent", "ForeverMarketWatch-Updater/2.6")
    $dl.DownloadFile($Url, $DestFile)
}

function Get-NormalizedLfBytes([string]$Path) {
    $iso = [System.Text.Encoding]::GetEncoding("iso-8859-1")
    $s = $iso.GetString([System.IO.File]::ReadAllBytes($Path)).Replace("`r`n", "`n")
    return $iso.GetBytes($s)
}

function Compute-NormalizedSha256Short([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = Get-NormalizedLfBytes $Path
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", "").ToLower().Substring(0, 16)
    } finally {
        $sha.Dispose()
    }
}

function Compute-StagedAddonHash([string]$DirPath) {
    $rawFiles = @(Get-ChildItem -Path $DirPath -File |
        Where-Object { $_.Extension -in @(".lua", ".toc") -and $_.Name -ne "MarketFeedData.lua" })
    $sortedNames = New-Object System.Collections.Generic.List[string]
    foreach ($rf in $rawFiles) { $sortedNames.Add($rf.Name) }
    $sortedNames.Sort([System.StringComparer]::Ordinal)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $ms  = New-Object System.IO.MemoryStream
    $nul = [byte[]]@(0)
    try {
        foreach ($fName in $sortedNames) {
            $nameBytes = [Text.Encoding]::UTF8.GetBytes($fName)
            $fileBytes = Get-NormalizedLfBytes (Join-Path $DirPath $fName)
            $ms.Write($nameBytes, 0, $nameBytes.Length)
            $ms.Write($nul, 0, 1)
            $ms.Write($fileBytes, 0, $fileBytes.Length)
            $ms.Write($nul, 0, 1)
        }
        $hashBytes = $sha.ComputeHash($ms.ToArray())
        return ([BitConverter]::ToString($hashBytes) -replace "-", "").ToLower().Substring(0, 16)
    } finally {
        $ms.Dispose()
        $sha.Dispose()
    }
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
    $stageDir = Join-Path $UpdaterDir "stage_code"
    if (Test-Path $stageDir) {
        Remove-Item -Path $stageDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    try {
        $validFiles = New-Object System.Collections.Generic.List[string]
        foreach ($rawName in $manifest.files) {
            $fName = [string]$rawName
            if ($fName -eq "MarketFeedData.lua") { continue }
            # Strict filename allowlist: must start with alphanumeric, single filename only, .lua/.toc
            if ($fName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*\.(lua|toc)$') {
                throw "Rejected unsafe filename in manifest: $fName"
            }
            $destCandidate = [IO.Path]::GetFullPath((Join-Path $addonDir $fName))
            if (-not $destCandidate.StartsWith($addonDirFull, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Rejected path traversal candidate: $fName"
            }
            $fileUrl = "$rawBase/addon/ForeverMarketWatch/${fName}?t=$bust"
            Download-ToFile $fileUrl (Join-Path $stageDir $fName)
            $validFiles.Add($fName)
        }

        # Verify cryptographic SHA-256 hash of staged code matches manifest before installing
        $expectedLen = ([string]$manifest.addonHash).Length
        $actualHash = Compute-StagedAddonHash $stageDir
        if ($actualHash -ne ([string]$manifest.addonHash).ToLower().Substring(0, [Math]::Min(16, $expectedLen))) {
            throw "SHA-256 addonHash mismatch (expected $($manifest.addonHash), got $actualHash)"
        }

        foreach ($fName in $validFiles) {
            $stagedFile = Join-Path $stageDir $fName
            $destFile   = Join-Path $addonDir $fName
            Copy-Item -Path $stagedFile -Destination $destFile -Force
            $updatedCount++
        }
        $state.addonHash = [string]$manifest.addonHash
    } catch {
        Write-UpdateLog "WARNING: Code update aborted safely (existing addon preserved): $_"
    } finally {
        if (Test-Path $stageDir) {
            Remove-Item -Path $stageDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($needFeed) {
    Write-UpdateLog "Downloading latest AH prices (syncedAt $($manifest.feedSyncedAt))..."
    $feedTmp = "$feedPath.tmp"
    try {
        $feedUrl = "$rawBase/addon/ForeverMarketWatch/MarketFeedData.lua?t=$bust"
        Download-ToFile $feedUrl $feedTmp

        if ($manifest.feedHash) {
            $actualFeedHash = Compute-NormalizedSha256Short $feedTmp
            if ($actualFeedHash -ne ([string]$manifest.feedHash).ToLower().Substring(0, 16)) {
                throw "SHA-256 feedHash mismatch (expected $($manifest.feedHash), got $actualFeedHash)"
            }
        }
        $firstLine = (Get-Content -Path $feedTmp -TotalCount 1 -ErrorAction Stop)
        if ($firstLine -notmatch '^--\s*MarketFeedData\.lua') {
            throw "Unexpected MarketFeedData.lua header"
        }

        if (Test-Path $feedPath) {
            Remove-Item -Path $feedPath -Force
        }
        Move-Item -Path $feedTmp -Destination $feedPath -Force
        $state.feedSyncedAt = [long]$manifest.feedSyncedAt
        $state.feedHash = [string]$manifest.feedHash
        $updatedCount++
    } catch {
        Write-UpdateLog "WARNING: Price feed update skipped safely: $_"
        if (Test-Path $feedTmp) {
            Remove-Item -Path $feedTmp -Force -ErrorAction SilentlyContinue
        }
    }
}

$state | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
if ($updatedCount -gt 0) {
    Write-UpdateLog "Sync complete ($updatedCount file(s) verified & updated)."
}

# Keep log small (last 150 lines)
if (Test-Path $LogPath) {
    try {
        $tail = Get-Content -Path $LogPath -Tail 150
        Set-Content -Path $LogPath -Value $tail -Encoding UTF8
    } catch {}
}
