<#
.SYNOPSIS
    Interactive setup wizard for ForeverMarketWatch Blizzard API hourly sync.
    Authenticates with Battle.net, auto-discovers WoW: Forever rulesets & auction houses,
    saves api-config.json, runs an immediate sync, and optionally registers an hourly task.
#>

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir "api-config.json"
$SyncScript = Join-Path $ScriptDir "sync-blizzard-ah.ps1"
$RegScript  = Join-Path $ScriptDir "register-hourly-task.ps1"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  ForeverMarketWatch — Blizzard API Setup Wizard" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "To pull hourly Auction House data automatically (without sitting at the AH)," -ForegroundColor White
Write-Host "you need a FREE Battle.net API Client ID and Client Secret:" -ForegroundColor White
Write-Host "  1. Open: https://develop.battle.net/access/clients" -ForegroundColor Green
Write-Host "  2. Click '+ Create Client' (name: ForeverMarketWatch, Redirect URI: http://localhost)" -ForegroundColor Green
Write-Host "  3. Copy the Client ID and Client Secret below." -ForegroundColor Green
Write-Host ""

$clientId = (Read-Host "Enter Battle.net Client ID").Trim()
$secSecret = Read-Host "Enter Battle.net Client Secret" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secSecret)
try {
    $clientSecret = ([Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)).Trim()
} finally {
    if ($bstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}
$region = (Read-Host "Enter Region (us / eu / kr / tw) [default: us]").Trim().ToLower()
if (-not $region) { $region = "us" }
if ($region -notin @("us", "eu", "kr", "tw")) {
    Write-Error "Invalid region '$region'. Expected one of: us, eu, kr, tw."
    exit 1
}

if (-not $clientId -or -not $clientSecret) {
    Write-Error "Client ID and Client Secret are required."
    exit 1
}

# 1. Verify OAuth credentials
Write-Host "`nVerifying Battle.net credentials..." -ForegroundColor Cyan
$basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${clientId}:${clientSecret}"))
$tokenResp = Invoke-RestMethod -Method Post -Uri "https://oauth.battle.net/token" `
    -Headers @{ Authorization = "Basic $basicAuth" } `
    -ContentType "application/x-www-form-urlencoded" `
    -Body "grant_type=client_credentials"

$token = $tokenResp.access_token
if (-not $token) {
    Write-Error "Could not obtain OAuth token. Double-check your Client ID and Client Secret."
    exit 1
}
Write-Host "Authenticated successfully!" -ForegroundColor Green

$namespace = "dynamic-forever-$region"
$baseUrl   = "https://$region.api.blizzard.com"
$authHdr   = @{ Authorization = "Bearer $token" }

# 2. Discover WoW: Forever Rulesets
Write-Host "`nFetching WoW: Forever rulesets ($namespace)..." -ForegroundColor Cyan
$rulesets = @()
try {
    $rsResp = Invoke-RestMethod -Method Get -Uri "$baseUrl/data/wow/ruleset/index?namespace=$namespace&locale=en_US" -Headers $authHdr
    if ($rsResp.rulesets) {
        $rulesets = $rsResp.rulesets
    }
} catch {
    Write-Host "Could not fetch ruleset index automatically; using standard WoW: Forever ruleset IDs." -ForegroundColor Yellow
}

if ($rulesets.Count -gt 0) {
    Write-Host "`nAvailable Rulesets:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $rulesets.Count; $i++) {
        $rs = $rulesets[$i]
        $rsName = if ($rs.name -is [string]) { $rs.name } elseif ($rs.name.en_US) { $rs.name.en_US } else { "Ruleset #$($rs.id)" }
        Write-Host ("  [{0}] ID {1} — {2}" -f ($i + 1), $rs.id, $rsName)
    }
    $pick = Read-Host "`nSelect ruleset number (1-$($rulesets.Count))"
    $idx = [int]$pick - 1
    if ($idx -lt 0 -or $idx -ge $rulesets.Count) {
        Write-Error "Invalid selection."
        exit 1
    }
    $chosenRs = $rulesets[$idx]
    $rulesetId = [int]$chosenRs.id
    $rulesetName = if ($chosenRs.name -is [string]) { $chosenRs.name } elseif ($chosenRs.name.en_US) { $chosenRs.name.en_US } else { "Ruleset #$rulesetId" }
} else {
    Write-Host "  1 = PvP  |  2 = Normal  |  3 = RP  |  15 = RP-PvP"
    $rulesetId = [int](Read-Host "Enter Ruleset ID [default: 2]")
    if (-not $rulesetId) { $rulesetId = 2 }
    $rulesetName = "Ruleset #$rulesetId"
}

# 3. Discover Auction Houses in this Ruleset (trailing slash required!)
Write-Host "`nFetching Auction Houses for $rulesetName (ID $rulesetId)..." -ForegroundColor Cyan
$ahIndexUrl = "$baseUrl/data/wow/ruleset/$rulesetId/auctions/?namespace=$namespace&locale=en_US"
$ahResp = Invoke-RestMethod -Method Get -Uri $ahIndexUrl -Headers $authHdr

$ahList = @()
if ($ahResp.auctions) {
    $ahList = $ahResp.auctions
} elseif ($ahResp.houses) {
    $ahList = $ahResp.houses
}

if ($ahList.Count -eq 0) {
    Write-Error "No auction houses returned for ruleset $rulesetId. Check your region/ruleset."
    exit 1
}

Write-Host "`nAvailable Auction Houses:" -ForegroundColor Yellow
for ($i = 0; $i -lt $ahList.Count; $i++) {
    $h = $ahList[$i]
    $hName = if ($h.name -is [string]) { $h.name } elseif ($h.name.en_US) { $h.name.en_US } else { "House #$($h.id)" }
    Write-Host ("  [{0}] House ID {1} — {2}" -f ($i + 1), $h.id, $hName)
}

Write-Host "`nTip: You can pick ONE (e.g. 2) or MULTIPLE separated by commas (e.g. 1,2) to track both Horde & Alliance." -ForegroundColor Gray
$housePicks = (Read-Host "Select Auction House number(s)").Split(",")
$selectedHouses = @()

foreach ($p in $housePicks) {
    $n = $p.Trim()
    if (-not $n) { continue }
    $hi = [int]$n - 1
    if ($hi -lt 0 -or $hi -ge $ahList.Count) { continue }
    $h = $ahList[$hi]
    $hName = if ($h.name -is [string]) { $h.name } elseif ($h.name.en_US) { $h.name.en_US } else { "House #$($h.id)" }

    # Auto-infer faction from name, confirm if ambiguous
    $faction = "Neutral"
    if ($hName -match "Horde") {
        $faction = "Horde"
    } elseif ($hName -match "Alliance") {
        $faction = "Alliance"
    } elseif ($hName -match "Blackwater|Neutral|Goblin") {
        $faction = "Neutral"
    } else {
        $fIn = (Read-Host "Which faction is '$hName' (Horde / Alliance / Neutral)?").Trim()
        if ($fIn) { $faction = $fIn }
    }

    $selectedHouses += [ordered]@{
        houseId = [int]$h.id
        faction = $faction
        name    = $hName
    }
}

if ($selectedHouses.Count -eq 0) {
    Write-Error "No valid auction house selected."
    exit 1
}

# 4. Save api-config.json
$cfgObj = [ordered]@{
    clientId      = $clientId
    clientSecret  = $clientSecret
    region        = $region
    rulesetId     = $rulesetId
    rulesetName   = $rulesetName
    houses        = $selectedHouses
    trackAllItems = $false
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ConfigPath, ($cfgObj | ConvertTo-Json -Depth 5), $utf8NoBom)
try {
    & icacls $ConfigPath /inheritance:r /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(F)" "*S-1-5-18:(F)" "*S-1-5-32-544:(F)" | Out-Null
} catch {
    Write-Host "Warning: Could not restrict NTFS ACLs on api-config.json: $_" -ForegroundColor Yellow
}
Write-Host "`nSaved config (restricted to your Windows user) at: $ConfigPath" -ForegroundColor Green

# 5. Run first sync right now
Write-Host "`nRunning initial Blizzard API sync..." -ForegroundColor Cyan
& $SyncScript -Force

# 6. Offer silent hourly background task
Write-Host ""
$sched = (Read-Host "Install a silent Windows background task to sync automatically EVERY HOUR? (Y/N) [default: Y]").Trim().ToLower()
if ($sched -eq "" -or $sched -eq "y" -or $sched -eq "yes") {
    & $RegScript
}

Write-Host "`nAll done! Run /reload (or restart WoW once if you just updated the addon) to see your Blizzard API data in-game." -ForegroundColor Green
