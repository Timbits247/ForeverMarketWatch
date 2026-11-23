<#
.SYNOPSIS
    Syncs hourly Auction House data from Blizzard's official WoW: Forever Battle.net API
    (dynamic-forever-{region}) and writes MarketFeedData.lua directly into ForeverMarketWatch.
.PARAMETER Force
    Ignore Last-Modified cache and re-download snapshots immediately.
.PARAMETER DryRunTest
    Runs an offline end-to-end self-test of the C# aggregator, history compaction,
    and MarketFeedData.lua generator without contacting Battle.net.
#>
param(
    [switch]$Force,
    [switch]$DryRunTest
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigPath  = Join-Path $ScriptDir "api-config.json"
$HistoryPath = Join-Path $ScriptDir "api-history.json"
$LogPath     = Join-Path $ScriptDir "sync.log"
$WowPathFile = Join-Path $ProjectRoot "wow-path.txt"
$CatalogLua  = Join-Path $ProjectRoot "addon\ForeverMarketWatch\ProfessionCatalog.lua"
$RepoFeedLua = Join-Path $ProjectRoot "addon\ForeverMarketWatch\MarketFeedData.lua"

function Write-SyncLog([string]$Msg, [string]$Color = "Gray") {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts] $Msg"
    Write-Host $line -ForegroundColor $Color
    if (-not $DryRunTest) {
        try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch {}
    }
}

#-------------------------------------------------------------------------------
# Fast Compiled C# Aggregator (parses 20MB+ Blizzard AH JSON in <0.5 seconds)
#-------------------------------------------------------------------------------
if (-not ("BlizzardAhAggregator" -as [type])) {
    Add-Type -ReferencedAssemblies "System.Web.Extensions" -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Web.Script.Serialization;

public class AggregatedPrice {
    public long MinPrice;
    public long AvgPrice;
    public long MaxPrice;
    public long TotalQty;
    public long WallQty;
    public long WallCost;
    public long NextPrice;
}

public class BlizzardAhAggregator {
    private class Entry {
        public long Price;
        public long Qty;
    }

    public static Dictionary<int, AggregatedPrice> Aggregate(string json, HashSet<int> filterIds, bool isCommodity) {
        var ser = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        var root = ser.DeserializeObject(json) as Dictionary<string, object>;
        var grouped = new Dictionary<int, List<Entry>>();

        if (root == null || !root.ContainsKey("auctions")) {
            return new Dictionary<int, AggregatedPrice>();
        }

        var auctions = root["auctions"] as object[];
        if (auctions == null) {
            return new Dictionary<int, AggregatedPrice>();
        }

        foreach (var rawObj in auctions) {
            var auc = rawObj as Dictionary<string, object>;
            if (auc == null || !auc.ContainsKey("item")) continue;

            var itemObj = auc["item"] as Dictionary<string, object>;
            if (itemObj == null || !itemObj.ContainsKey("id")) continue;

            int itemId = Convert.ToInt32(itemObj["id"]);
            if (filterIds != null && filterIds.Count > 0 && !filterIds.Contains(itemId)) {
                continue;
            }

            long qty = auc.ContainsKey("quantity") ? Convert.ToInt64(auc["quantity"]) : 1;
            if (qty <= 0) qty = 1;

            long unitPrice = 0;
            if (isCommodity) {
                if (auc.ContainsKey("unit_price")) {
                    unitPrice = Convert.ToInt64(auc["unit_price"]);
                } else if (auc.ContainsKey("buyout")) {
                    long b = Convert.ToInt64(auc["buyout"]);
                    unitPrice = (long)Math.Round((double)b / qty);
                }
            } else {
                if (auc.ContainsKey("buyout")) {
                    long b = Convert.ToInt64(auc["buyout"]);
                    if (b > 0) {
                        unitPrice = (long)Math.Round((double)b / qty);
                    }
                } else if (auc.ContainsKey("unit_price")) {
                    unitPrice = Convert.ToInt64(auc["unit_price"]);
                }
            }

            if (unitPrice <= 0) continue;

            List<Entry> list;
            if (!grouped.TryGetValue(itemId, out list)) {
                list = new List<Entry>();
                grouped[itemId] = list;
            }
            list.Add(new Entry { Price = unitPrice, Qty = qty });
        }

        var results = new Dictionary<int, AggregatedPrice>(grouped.Count);
        foreach (var kv in grouped) {
            var list = kv.Value;
            list.Sort((a, b) => a.Price.CompareTo(b.Price));

            long totalQty = 0;
            for (int i = 0; i < list.Count; i++) totalQty += list[i].Qty;
            if (totalQty <= 0) continue;

            long minPrice = list[0].Price;
            long coreTarget = Math.Max(1L, (long)Math.Ceiling(totalQty * 0.50));
            long p90Target  = Math.Max(1L, (long)Math.Ceiling(totalQty * 0.90));

            long coreQty = 0;
            double coreSum = 0;
            long p90Price = minPrice;
            long cumQty = 0;

            for (int i = 0; i < list.Count; i++) {
                var e = list[i];
                if (coreQty < coreTarget) {
                    long take = Math.Min(e.Qty, coreTarget - coreQty);
                    coreSum += (double)e.Price * take;
                    coreQty += take;
                }
                cumQty += e.Qty;
                if (cumQty >= p90Target && p90Price == minPrice && i > 0) {
                    p90Price = e.Price;
                }
            }

            long avgPrice = coreQty > 0 ? (long)Math.Round(coreSum / coreQty) : minPrice;
            long maxCap = minPrice * 5L;
            long maxPrice = Math.Min(p90Price, maxCap);
            if (maxPrice < minPrice) maxPrice = minPrice;

            // Dip Wall (+10% reset cost): total units & copper within +10% of lowest buyout
            long wallCeiling = (long)Math.Ceiling(minPrice * 1.10);
            long wallQty = 0;
            long wallCost = 0;
            long nextPrice = minPrice;
            for (int i = 0; i < list.Count; i++) {
                var e = list[i];
                if (e.Price <= wallCeiling) {
                    wallQty += e.Qty;
                    wallCost += e.Price * e.Qty;
                } else {
                    nextPrice = e.Price;
                    break;
                }
            }

            results[kv.Key] = new AggregatedPrice {
                MinPrice  = minPrice,
                AvgPrice  = avgPrice,
                MaxPrice  = maxPrice,
                TotalQty  = totalQty,
                WallQty   = wallQty,
                WallCost  = wallCost,
                NextPrice = nextPrice
            };
        }

        return results;
    }
}
"@
}

#-------------------------------------------------------------------------------
# Collect Tracked Item IDs (ProfessionCatalog.lua + Live SavedVariables Watchlist)
#-------------------------------------------------------------------------------
function Get-TrackedItemIdSet([string]$WowPath, [bool]$TrackAll) {
    $set = New-Object "System.Collections.Generic.HashSet[int]"
    if ($TrackAll) {
        return $set # Empty set tells aggregator to keep all items
    }

    # 1. All items from ProfessionCatalog.lua
    if (Test-Path $CatalogLua) {
        $catRaw = Get-Content -Path $CatalogLua -Raw
        $matches = [regex]::Matches($catRaw, '\{\s*(\d+)\s*,\s*"[^"]+"\s*,')
        foreach ($m in $matches) {
            [void]$set.Add([int]$m.Groups[1].Value)
        }
    }

    # 2. Any custom items added to ForeverMarketWatchDB in SavedVariables
    if ($WowPath -and (Test-Path $WowPath)) {
        $wtfAccount = Join-Path $WowPath "WTF\Account"
        if (Test-Path $wtfAccount) {
            $svFiles = Get-ChildItem -Path $wtfAccount -Filter "ForeverMarketWatch.lua" -Recurse -ErrorAction SilentlyContinue
            foreach ($sv in $svFiles) {
                $raw = Get-Content -Path $sv.FullName -Raw -ErrorAction SilentlyContinue
                if ($raw) {
                    $idMatches = [regex]::Matches($raw, '\["itemID"\]\s*=\s*(\d+)')
                    foreach ($m in $idMatches) {
                        [void]$set.Add([int]$m.Groups[1].Value)
                    }
                }
            }
        }
    }

    return $set
}

#-------------------------------------------------------------------------------
# History Management (7-Day Hourly Intraday + Automatic Daily Rollup)
#-------------------------------------------------------------------------------
function Get-DayKeyFromUnix([long]$UnixTs) {
    $dt = [DateTimeOffset]::FromUnixTimeSeconds($UnixTs).ToLocalTime()
    return [int]($dt.Year * 10000 + $dt.Month * 100 + $dt.Day)
}

function Update-ItemHistoryBucket([hashtable]$ItemHist, [long]$NowUnix, [AggregatedPrice]$Agg) {
    if (-not $ItemHist.ContainsKey("intraday")) { $ItemHist["intraday"] = New-Object System.Collections.ArrayList }
    if (-not $ItemHist.ContainsKey("daily"))    { $ItemHist["daily"]    = @{} }

    $intraday = $ItemHist["intraday"]
    $daily    = $ItemHist["daily"]

    # Deduplicate if synced within 5 minutes of previous point
    $merged = $false
    if ($intraday.Count -gt 0) {
        $last = $intraday[$intraday.Count - 1]
        if ([Math]::Abs($NowUnix - [long]$last[0]) -lt 300) {
            $last[0] = $NowUnix
            $last[1] = $Agg.MinPrice
            $last[2] = $Agg.AvgPrice
            $last[3] = [Math]::Max([long]$last[3], $Agg.MaxPrice)
            $last[4] = $Agg.TotalQty
            $merged = $true
        }
    }
    if (-not $merged) {
        [void]$intraday.Add(@($NowUnix, $Agg.MinPrice, $Agg.AvgPrice, $Agg.MaxPrice, $Agg.TotalQty))
    }

    # Roll points older than 7 days into daily buckets
    $cutoff = $NowUnix - (7 * 86400)
    $kept = New-Object System.Collections.ArrayList
    foreach ($pt in $intraday) {
        $ts = [long]$pt[0]
        if ($ts -lt $cutoff) {
            $dk = [string](Get-DayKeyFromUnix $ts)
            if (-not $daily.ContainsKey($dk)) {
                $daily[$dk] = @([long]$pt[1], [long]$pt[2], [long]$pt[3], [long]$pt[1], [long]$pt[4], 1)
            } else {
                $d = $daily[$dk]
                $cnt = [int]$d[5]
                $nc = $cnt + 1
                $d[0] = [Math]::Min([long]$d[0], [long]$pt[1])
                $d[1] = [long][Math]::Round((([double]$d[1] * $cnt) + [double]$pt[2]) / $nc)
                $d[2] = [Math]::Max([long]$d[2], [long]$pt[3])
                $d[3] = [long]$pt[1]
                $d[4] = [long][Math]::Round((([double]$d[4] * $cnt) + [double]$pt[4]) / $nc)
                $d[5] = $nc
            }
        } else {
            [void]$kept.Add($pt)
        }
    }
    $ItemHist["intraday"] = $kept
    $ItemHist["lastScan"] = $NowUnix
    $ItemHist["wall"]     = @($Agg.WallQty, $Agg.WallCost, $Agg.NextPrice)
}

#-------------------------------------------------------------------------------
# Lua Feed Generator (MarketFeedData.lua)
#-------------------------------------------------------------------------------
function Export-MarketFeedLua([hashtable]$HistoryRoot, [long]$SyncedAt, [string]$SourceLabel, [System.Collections.Generic.HashSet[int]]$PriorityIds) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("-- MarketFeedData.lua")
    [void]$sb.AppendLine("-- Auto-generated by api-sync\sync-blizzard-ah.ps1 from Blizzard's Battle.net API.")
    [void]$sb.AppendLine("-- Synced: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("local _, NS = ...")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("NS.ExternalFeed = {")
    [void]$sb.AppendLine("    syncedAt = $SyncedAt,")
    [void]$sb.AppendLine("    source = `"$($SourceLabel.Replace('"','\"'))`",")
    [void]$sb.AppendLine("    houses = {")

    foreach ($faction in $HistoryRoot.houses.Keys) {
        [void]$sb.AppendLine("        [`"$faction`"] = {")
        $houseMap = $HistoryRoot.houses[$faction]
        $sortedIds = $houseMap.Keys | Sort-Object { [int]$_ }
        foreach ($idKey in $sortedIds) {
            $ih = $houseMap[$idKey]
            $idInt = [int]$idKey
            $isPriority = ($null -eq $PriorityIds) -or ($PriorityIds.Count -eq 0) -or $PriorityIds.Contains($idInt)
            $lastScan = [long]$ih["lastScan"]
            [void]$sb.AppendLine("            [$idKey] = {")
            [void]$sb.AppendLine("                lastScan = $lastScan,")
            if ($ih.ContainsKey("wall") -and $ih["wall"] -and $ih["wall"].Count -ge 3) {
                $w = $ih["wall"]
                [void]$sb.AppendLine("                wall = {$($w[0]),$($w[1]),$($w[2])},")
            }

            # Keep full 7-day intraday for watched/catalog items, and last 36 intraday points for extra AH items
            # so MarketFeedData.lua stays compact and loads instantaneously in WoW even across 2,000+ items.
            [void]$sb.Append("                intraday = {")
            $pts = $ih["intraday"]
            $startIdx = 0
            if (-not $isPriority -and $pts.Count -gt 36) {
                $startIdx = $pts.Count - 36
            }
            for ($i = $startIdx; $i -lt $pts.Count; $i++) {
                $p = $pts[$i]
                if ($i -gt $startIdx) { [void]$sb.Append(",") }
                [void]$sb.Append("{$($p[0]),$($p[1]),$($p[2]),$($p[3]),$($p[4])}")
            }
            [void]$sb.AppendLine("},")

            # Daily map (keep up to 90 days for non-priority items, full for priority items)
            [void]$sb.Append("                daily = {")
            $daily = $ih["daily"]
            $dKeys = @($daily.Keys | Sort-Object { [int]$_ })
            $dStart = 0
            if (-not $isPriority -and $dKeys.Count -gt 90) {
                $dStart = $dKeys.Count - 90
            }
            $firstD = $true
            for ($di = $dStart; $di -lt $dKeys.Count; $di++) {
                $dk = $dKeys[$di]
                $d = $daily[$dk]
                if (-not $firstD) { [void]$sb.Append(",") }
                $firstD = $false
                [void]$sb.Append("[$dk]={$($d[0]),$($d[1]),$($d[2]),$($d[3]),$($d[4]),$($d[5])}")
            }
            [void]$sb.AppendLine("},")
            [void]$sb.AppendLine("            },")
        }
        [void]$sb.AppendLine("        },")
    }

    [void]$sb.AppendLine("    },")
    [void]$sb.AppendLine("}")
    return $sb.ToString()
}

#-------------------------------------------------------------------------------
# Offline Self-Test Mode (-DryRunTest)
#-------------------------------------------------------------------------------
if ($DryRunTest) {
    Write-SyncLog "Running offline DryRunTest for Blizzard API sync pipeline..." "Cyan"
    $sampleCommodities = '{"auctions":[{"id":1,"item":{"id":13468},"quantity":2,"unit_price":103950},{"id":2,"item":{"id":13468},"quantity":5,"unit_price":105000},{"id":3,"item":{"id":13468},"quantity":1,"unit_price":99999999},{"id":4,"item":{"id":2770},"quantity":20,"unit_price":145}]}'
    $sampleItems       = '{"auctions":[{"id":9,"item":{"id":12363},"quantity":1,"buyout":118476}]}'

    $filter = Get-TrackedItemIdSet "" $false
    if ($filter.Count -lt 100) {
        throw "Expected >=100 catalog item IDs, got $($filter.Count)"
    }

    $aggC = [BlizzardAhAggregator]::Aggregate($sampleCommodities, $filter, $true)
    $aggI = [BlizzardAhAggregator]::Aggregate($sampleItems, $filter, $false)

    if (-not $aggC.ContainsKey(13468) -or $aggC[13468].MinPrice -ne 103950 -or $aggC[13468].TotalQty -ne 8) {
        throw "Commodity aggregation failed for Black Lotus (13468)."
    }
    if ($aggC[13468].MaxPrice -gt (103950 * 5)) {
        throw "Outlier cap failed on 9999g troll listing."
    }
    if (-not $aggI.ContainsKey(12363) -or $aggI[12363].MinPrice -ne 118476) {
        throw "Regular item aggregation failed for Arcane Crystal (12363)."
    }

    $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $histRoot = @{ houses = @{ "Horde" = @{} } }
    $ih = @{
        intraday = (New-Object System.Collections.ArrayList)
        daily    = @{}
        lastScan = 0
    }
    # Add one old point (10 days ago) to verify daily rollup
    [void]$ih["intraday"].Add(@(($nowUnix - 10 * 86400), 99000, 101000, 110000, 12))
    Update-ItemHistoryBucket $ih $nowUnix $aggC[13468]
    $histRoot.houses["Horde"]["13468"] = $ih

    if ($ih["intraday"].Count -ne 1 -or $ih["daily"].Count -ne 1) {
        throw "History compaction check failed (intraday=$($ih['intraday'].Count), daily=$($ih['daily'].Count))"
    }

    $luaOut = Export-MarketFeedLua $histRoot $nowUnix "DryRunTest (dynamic-forever-us)"
    if (-not ($luaOut -match "NS\.ExternalFeed") -or -not ($luaOut -match "\[13468\]") -or -not ($luaOut -match "103950")) {
        throw "Generated MarketFeedData.lua output missing expected fields."
    }

    Write-SyncLog "DRY-RUN TEST PASSED: Catalog=$($filter.Count) IDs, C# aggregator, outlier cap, daily rollup, and Lua export verified." "Green"
    exit 0
}

#-------------------------------------------------------------------------------
# Live Blizzard Battle.net API Sync
#-------------------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
    Write-SyncLog "Missing api-config.json! Run 'Setup Blizzard API.bat' first." "Red"
    exit 1
}

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.clientId -or -not $config.clientSecret -or $config.clientId -eq "YOUR_BATTLENET_CLIENT_ID") {
    Write-SyncLog "Invalid Battle.net credentials in api-config.json. Run 'Setup Blizzard API.bat'." "Red"
    exit 1
}

$region    = if ($config.region) { $config.region.ToLower() } else { "us" }
$namespace = "dynamic-forever-$region"
$rulesetId = [int]$config.rulesetId
$baseUrl   = "https://$region.api.blizzard.com"

$wowPath = ""
if (Test-Path $WowPathFile) {
    $wowPath = (Get-Content -Path $WowPathFile -Raw).Trim()
}

# 1. Authenticate OAuth2 client_credentials
Write-SyncLog "Authenticating with Battle.net OAuth ($region / $namespace)..." "Cyan"
$basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($config.clientId):$($config.clientSecret)"))
$tokenResp = Invoke-RestMethod -Method Post -Uri "https://oauth.battle.net/token" `
    -Headers @{ Authorization = "Basic $basicAuth" } `
    -ContentType "application/x-www-form-urlencoded" `
    -Body "grant_type=client_credentials"

$accessToken = $tokenResp.access_token
if (-not $accessToken) {
    throw "Failed to obtain Battle.net OAuth access token."
}

# 2. Load existing local rolling history
$historyRoot = @{ houses = @{}; lastModified = @{} }
if (Test-Path $HistoryPath) {
    try {
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $loaded = $ser.DeserializeObject((Get-Content -Path $HistoryPath -Raw))
        if ($loaded -and $loaded.ContainsKey("houses")) {
            foreach ($fKey in $loaded["houses"].Keys) {
                $historyRoot.houses[$fKey] = @{}
                foreach ($idKey in $loaded["houses"][$fKey].Keys) {
                    $rawItem = $loaded["houses"][$fKey][$idKey]
                    $intraList = New-Object System.Collections.ArrayList
                    if ($rawItem.ContainsKey("intraday") -and $rawItem["intraday"]) {
                        foreach ($pt in $rawItem["intraday"]) {
                            [void]$intraList.Add(@([long]$pt[0], [long]$pt[1], [long]$pt[2], [long]$pt[3], [long]$pt[4]))
                        }
                    }
                    $dailyMap = @{}
                    if ($rawItem.ContainsKey("daily") -and $rawItem["daily"]) {
                        foreach ($dk in $rawItem["daily"].Keys) {
                            $d = $rawItem["daily"][$dk]
                            $dailyMap[[string]$dk] = @([long]$d[0], [long]$d[1], [long]$d[2], [long]$d[3], [long]$d[4], [int]$d[5])
                        }
                    }
                    $wallArr = $null
                    if ($rawItem.ContainsKey("wall") -and $rawItem["wall"] -and $rawItem["wall"].Length -ge 3) {
                        $wallArr = @([long]$rawItem["wall"][0], [long]$rawItem["wall"][1], [long]$rawItem["wall"][2])
                    }
                    $historyRoot.houses[$fKey][[string]$idKey] = @{
                        intraday = $intraList
                        daily    = $dailyMap
                        lastScan = [long]$rawItem["lastScan"]
                        wall     = $wallArr
                    }
                }
            }
        }
        if ($loaded -and $loaded.ContainsKey("lastModified")) {
            foreach ($k in $loaded["lastModified"].Keys) {
                $historyRoot.lastModified[$k] = [string]$loaded["lastModified"][$k]
            }
        }
    } catch {
        Write-SyncLog "Starting fresh history store (previous api-history.json unreadable): $_" "Yellow"
    }
}

$trackAll = [bool]$config.trackAllItems
$prioritySet = Get-TrackedItemIdSet $wowPath $false
$filterSet = Get-TrackedItemIdSet $wowPath $trackAll
Write-SyncLog "Tracking $(if ($trackAll) { 'ALL AH items (full market scan)' } else { "$($filterSet.Count) catalog + watchlist items" })..." "Gray"

function Invoke-BlizzardRawGet([string]$Url, [string]$Token, [string]$IfModSince) {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = "GET"
    $req.Headers.Add("Authorization", "Bearer $Token")
    $req.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $req.Timeout = 60000
    if ($IfModSince -and -not $Force) {
        try { $req.IfModifiedSince = [DateTime]::Parse($IfModSince) } catch {}
    }

    try {
        $resp = [System.Net.HttpWebResponse]$req.GetResponse()
        $lastMod = $resp.Headers["Last-Modified"]
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $body = $reader.ReadToEnd()
        $reader.Close()
        $resp.Close()
        return @{ NotModified = $false; Body = $body; LastModified = $lastMod }
    } catch [System.Net.WebException] {
        $httpResp = $_.Exception.Response
        if ($httpResp -and [int]$httpResp.StatusCode -eq 304) {
            return @{ NotModified = $true; Body = $null; LastModified = $IfModSince }
        }
        throw
    }
}

$nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$totalUpdated = 0

foreach ($house in $config.houses) {
    $houseId = [int]$house.houseId
    $faction = [string]$house.faction
    if (-not $historyRoot.houses.ContainsKey($faction)) {
        $historyRoot.houses[$faction] = @{}
    }
    $houseMap = $historyRoot.houses[$faction]

    # A. Commodities endpoint (stackables: herbs, ores, cloth, potions, enchanting mats)
    $commUrl = "$baseUrl/data/wow/ruleset/$rulesetId/auctions/$houseId/commodities?namespace=$namespace&locale=en_US"
    $commKey = "comm_$houseId"
    Write-SyncLog "Fetching commodities for $faction (House #$houseId)..." "Cyan"
    try {
        $cRes = Invoke-BlizzardRawGet $commUrl $accessToken $historyRoot.lastModified[$commKey]
        if ($cRes.NotModified) {
            Write-SyncLog "  Commodities unchanged (304 Not Modified)." "DarkGray"
        } else {
            if ($cRes.LastModified) { $historyRoot.lastModified[$commKey] = $cRes.LastModified }
            $aggC = [BlizzardAhAggregator]::Aggregate($cRes.Body, $filterSet, $true)
            foreach ($kv in $aggC.GetEnumerator()) {
                $idStr = [string]$kv.Key
                if (-not $houseMap.ContainsKey($idStr)) {
                    $houseMap[$idStr] = @{ intraday = (New-Object System.Collections.ArrayList); daily = @{}; lastScan = 0 }
                }
                Update-ItemHistoryBucket $houseMap[$idStr] $nowUnix $kv.Value
                $totalUpdated++
            }
            Write-SyncLog "  Aggregated $($aggC.Count) commodity items." "Green"
        }
    } catch {
        Write-SyncLog "  Warning: Commodities fetch failed for House #${houseId}: $_" "Yellow"
    }

    # B. Optional Non-Commodity Item Auctions endpoint (some WoW: Forever endpoints restrict non-commodities with 403)
    $itemUrl = "$baseUrl/data/wow/ruleset/$rulesetId/auctions/$houseId?namespace=$namespace&locale=en_US"
    $itemKey = "item_$houseId"
    try {
        $iRes = Invoke-BlizzardRawGet $itemUrl $accessToken $historyRoot.lastModified[$itemKey]
        if (-not $iRes.NotModified -and $iRes.Body) {
            if ($iRes.LastModified) { $historyRoot.lastModified[$itemKey] = $iRes.LastModified }
            $aggI = [BlizzardAhAggregator]::Aggregate($iRes.Body, $filterSet, $false)
            foreach ($kv in $aggI.GetEnumerator()) {
                $idStr = [string]$kv.Key
                if (-not $houseMap.ContainsKey($idStr)) {
                    $houseMap[$idStr] = @{ intraday = (New-Object System.Collections.ArrayList); daily = @{}; lastScan = 0 }
                }
                Update-ItemHistoryBucket $houseMap[$idStr] $nowUnix $kv.Value
                $totalUpdated++
            }
            if ($aggI.Count -gt 0) {
                Write-SyncLog "  Aggregated $($aggI.Count) non-commodity items." "Green"
            }
        }
    } catch {
        # Quietly skip if Blizzard restricts the non-commodity house endpoint on Forever
    }
}

if ($totalUpdated -eq 0 -and -not $Force) {
    Write-SyncLog "No new Blizzard snapshot yet (304 Not Modified). Skipping file write." "DarkGray"
    exit 0
}

# 3. Persist rolling local history JSON (native ConvertTo-Json avoids PSObject wrapper serialization quirks)
$historyRoot | ConvertTo-Json -Depth 8 -Compress | Set-Content -Path $HistoryPath -Encoding UTF8

# 4. Generate & write MarketFeedData.lua directly to the live WoW AddOns folder
#    (Leaves the Git repo's MarketFeedData.lua untouched so GitHub Actions stays the
#     single source of truth and `git pull` never hits merge conflicts.)
$sourceLabel = "Blizzard API ($namespace, Ruleset #$rulesetId)"
$luaContent = Export-MarketFeedLua $historyRoot $nowUnix $sourceLabel $prioritySet

if ($wowPath) {
    $liveAddonDir = Join-Path $wowPath "Interface\AddOns\ForeverMarketWatch"
    if (Test-Path $liveAddonDir) {
        $liveFeedLua = Join-Path $liveAddonDir "MarketFeedData.lua"
        Set-Content -Path $liveFeedLua -Value $luaContent -Encoding UTF8
        Write-SyncLog "Updated live WoW addon feed: $liveFeedLua" "Green"
    } else {
        Write-SyncLog "Note: Live addon folder not found at $liveAddonDir — run install-addon.ps1 first." "Yellow"
    }
} else {
    Set-Content -Path $RepoFeedLua -Value $luaContent -Encoding UTF8
}

# Keep sync.log bounded (last 300 lines)
if (Test-Path $LogPath) {
    try {
        $lines = Get-Content -Path $LogPath -Tail 300
        Set-Content -Path $LogPath -Value $lines -Encoding UTF8
    } catch {}
}

Write-SyncLog "Sync complete! Updated $totalUpdated item snapshots. Run /reload in WoW to load fresh charts." "Green"
