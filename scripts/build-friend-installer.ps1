<#
.SYNOPSIS
    Regenerates release/manifest.json, configures friend-installer/repo-config.json
    for your GitHub repo, and builds a tiny ForeverMarketWatch-Installer.zip ready to share.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build-friend-installer.ps1 -GitHubRepo "yourname/ForeverMarketWatch"
#>
param(
    [string]$GitHubRepo,
    [string]$Branch = "main",
    [switch]$ManifestOnly
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$AddonDir    = Join-Path $ProjectRoot "addon\ForeverMarketWatch"
$ReleaseDir  = Join-Path $ProjectRoot "release"
$ManifestOut = Join-Path $ReleaseDir "manifest.json"
$FriendDir   = Join-Path $ProjectRoot "friend-installer"
$DistDir     = Join-Path $ProjectRoot "dist"

# 1. Regenerate release/manifest.json (pure PowerShell, exact parity with sync_blizzard_ah.py)
if (-not (Test-Path $ReleaseDir)) {
    New-Item -ItemType Directory -Path $ReleaseDir -Force | Out-Null
}

function Get-NormalizedLfBytes([string]$Path) {
    $iso = [System.Text.Encoding]::GetEncoding("iso-8859-1")
    $s = $iso.GetString([System.IO.File]::ReadAllBytes($Path)).Replace("`r`n", "`n")
    return $iso.GetBytes($s)
}

$addonFilesUnsorted = @(Get-ChildItem -Path $AddonDir -File | Where-Object { $_.Extension -in @(".lua", ".toc") })
$sortedNames = New-Object System.Collections.Generic.List[string]
foreach ($item in $addonFilesUnsorted) { $sortedNames.Add($item.Name) }
$sortedNames.Sort([System.StringComparer]::Ordinal)

$tocPath = Join-Path $AddonDir "ForeverMarketWatch.toc"
$version = "2.1.0"
if (Test-Path $tocPath) {
    $vLine = Get-Content -Path $tocPath | Where-Object { $_ -match '^##\s*Version:\s*(.+)$' } | Select-Object -First 1
    if ($vLine -and $Matches[1]) { $version = $Matches[1].Trim() }
}

$sha = [System.Security.Cryptography.SHA256]::Create()
$feedPath = Join-Path $AddonDir "MarketFeedData.lua"
$feedSyncedAt = 0
$feedHash = ""
if (Test-Path $feedPath) {
    $head = (Get-Content -Path $feedPath -TotalCount 20) -join "`n"
    if ($head -match 'syncedAt\s*=\s*(\d+)') {
        $feedSyncedAt = [long]$Matches[1]
    }
    $feedBytes = Get-NormalizedLfBytes $feedPath
    $feedHash = ([BitConverter]::ToString($sha.ComputeHash($feedBytes)) -replace "-", "").ToLower().Substring(0, 16)
}

$ms  = New-Object System.IO.MemoryStream
$nul = [byte[]]@(0)
foreach ($fName in $sortedNames) {
    if ($fName -eq "MarketFeedData.lua") { continue }
    $nameBytes = [Text.Encoding]::UTF8.GetBytes($fName)
    $fileBytes = Get-NormalizedLfBytes (Join-Path $AddonDir $fName)
    $ms.Write($nameBytes, 0, $nameBytes.Length)
    $ms.Write($nul, 0, 1)
    $ms.Write($fileBytes, 0, $fileBytes.Length)
    $ms.Write($nul, 0, 1)
}
$addonHashBytes = $sha.ComputeHash($ms.ToArray())
$addonHash = ([BitConverter]::ToString($addonHashBytes) -replace "-", "").ToLower().Substring(0, 16)
$ms.Dispose()
$sha.Dispose()

$fileNames = @($sortedNames)
$manifestObj = [ordered]@{
    addonName    = "ForeverMarketWatch"
    addonVersion = $version
    addonHash    = $addonHash
    feedSyncedAt = $feedSyncedAt
    feedHash     = $feedHash
    generatedAt  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    files        = $fileNames
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ManifestOut, ($manifestObj | ConvertTo-Json -Depth 4) + "`n", $utf8NoBom)
Write-Host "Updated release/manifest.json (v$version, addonHash=$addonHash, feedSyncedAt=$feedSyncedAt, $($fileNames.Count) files)." -ForegroundColor Green

if ($ManifestOnly) {
    exit 0
}

# 2. Configure GitHub raw URL for friend-installer
if (-not $GitHubRepo) {
    $GitHubRepo = (Read-Host "Enter your GitHub repo (format: username/reponame)").Trim()
}
$GitHubRepo = $GitHubRepo.Trim("/") -replace '^https?://github\.com/', '' -replace '\.git$', ''
if (-not $GitHubRepo -or $GitHubRepo -notmatch '^[^/]+/[^/]+$') {
    Write-Error "Invalid GitHub repo format. Expected: username/reponame (example: tim/ForeverMarketWatch)"
    exit 1
}

$rawBaseUrl = "https://raw.githubusercontent.com/$GitHubRepo/$Branch"
$repoCfgObj = [ordered]@{
    rawBaseUrl = $rawBaseUrl
}
$repoCfgPath = Join-Path $FriendDir "repo-config.json"
$repoCfgObj | ConvertTo-Json | Set-Content -Path $repoCfgPath -Encoding UTF8
Write-Host "Configured friend-installer/repo-config.json -> $rawBaseUrl" -ForegroundColor Cyan

# 3. Package tiny 1-click installer ZIP into dist/ (and Downloads if writable)
if (-not (Test-Path $DistDir)) {
    New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
}
$zipPath = Join-Path $DistDir "ForeverMarketWatch-Installer.zip"
Compress-Archive -Path (Join-Path $FriendDir "*") -DestinationPath $zipPath -Force
Write-Host "Built installer ZIP: $zipPath" -ForegroundColor Green

$dlDir = Join-Path $env:USERPROFILE "Downloads"
try {
    if (Test-Path $dlDir) {
        $dlZip = Join-Path $dlDir "ForeverMarketWatch-Installer.zip"
        Copy-Item -Path $zipPath -Destination $dlZip -Force
        Write-Host "Also copied to Downloads: $dlZip" -ForegroundColor Green
    }
} catch {}
