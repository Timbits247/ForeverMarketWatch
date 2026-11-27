<#
.SYNOPSIS
    Static verification suite for ForeverMarketWatch (WoW: Forever 1.60.1 / Interface 16001).
    Checks TOC manifest integrity, Lua lexical/block/delimiter balance, zero GameTooltip hooks,
    and zero unsafe mutations of protected AuctionHouseFrame tables.
#>

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$AddonDir    = Join-Path $ProjectRoot "addon\ForeverMarketWatch"
$TocPath     = Join-Path $AddonDir "ForeverMarketWatch.toc"

$Failures = New-Object System.Collections.Generic.List[string]
$PassCount = 0

function Pass([string]$Msg) {
    $script:PassCount++
    Write-Host "[PASS] $Msg" -ForegroundColor Green
}

function Fail([string]$Msg) {
    $script:Failures.Add($Msg)
    Write-Host "[FAIL] $Msg" -ForegroundColor Red
}

Write-Host "=== ForeverMarketWatch Static Verification ===" -ForegroundColor Cyan

# 1. Verify TOC exists & metadata
if (-not (Test-Path $TocPath)) {
    Fail "Missing TOC file: $TocPath"
    exit 1
}

$TocLines = Get-Content -Path $TocPath
$InterfaceLine = $TocLines | Where-Object { $_ -match "^##\s*Interface:\s*(\d+)" } | Select-Object -First 1
if ($InterfaceLine -and $Matches[1] -eq "16001") {
    Pass "TOC Interface version is 16001 (WoW: Forever 1.60.1)"
} else {
    Fail "TOC Interface version is not 16001 (found: $InterfaceLine)"
}

$SavedVarsLine = $TocLines | Where-Object { $_ -match "^##\s*SavedVariables:\s*(.+)$" } | Select-Object -First 1
if ($SavedVarsLine -and $Matches[1].Trim() -eq "ForeverMarketWatchDB") {
    Pass "TOC SavedVariables declares ForeverMarketWatchDB"
} else {
    Fail "TOC SavedVariables mismatch (found: $SavedVarsLine)"
}

# Extract listed Lua files
$LuaFiles = @()
foreach ($line in $TocLines) {
    $t = $line.Trim()
    if ($t -eq "" -or $t.StartsWith("#")) { continue }
    $LuaFiles += $t
}

if ($LuaFiles.Count -ge 8) {
    Pass "TOC lists $($LuaFiles.Count) Lua modules in load order"
} else {
    Fail "Unexpectedly few Lua modules in TOC ($($LuaFiles.Count))"
}

# Verify every listed file exists & no orphan Lua files exist
foreach ($f in $LuaFiles) {
    $full = Join-Path $AddonDir $f
    if (Test-Path $full) {
        Pass "Module exists: $f"
    } else {
        Fail "TOC references missing file: $f"
    }
}

$ActualLua = Get-ChildItem -Path $AddonDir -Filter "*.lua" | ForEach-Object { $_.Name }
foreach ($f in $ActualLua) {
    if ($LuaFiles -notcontains $f) {
        Fail "Orphan Lua file not listed in TOC: $f"
    }
}

# 2. Strip Lua comments & strings helper for accurate block/delimiter balance checking
function Strip-LuaStringsAndComments([string]$Code) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    $len = $Code.Length
    while ($i -lt $len) {
        $ch = $Code[$i]
        # Line comment --
        if ($ch -eq '-' -and ($i + 1) -lt $len -and $Code[$i + 1] -eq '-') {
            # Long comment --[[ ... ]]
            if (($i + 3) -lt $len -and $Code[$i + 2] -eq '[' -and $Code[$i + 3] -eq '[') {
                $i += 4
                while ($i -lt ($len - 1) -and -not ($Code[$i] -eq ']' -and $Code[$i + 1] -eq ']')) {
                    if ($Code[$i] -eq "`n") { [void]$sb.Append("`n") }
                    $i++
                }
                $i += 2
                continue
            }
            while ($i -lt $len -and $Code[$i] -ne "`n") { $i++ }
            continue
        }
        # Quoted string
        if ($ch -eq '"' -or $ch -eq "'") {
            $quote = $ch
            [void]$sb.Append(' ')
            $i++
            while ($i -lt $len) {
                if ($Code[$i] -eq '\') {
                    $i += 2
                    continue
                }
                if ($Code[$i] -eq $quote) {
                    $i++
                    break
                }
                if ($Code[$i] -eq "`n") {
                    Fail "Unterminated string literal detected."
                    break
                }
                $i++
            }
            continue
        }
        [void]$sb.Append($ch)
        $i++
    }
    return $sb.ToString()
}

foreach ($f in $LuaFiles) {
    $full = Join-Path $AddonDir $f
    if (-not (Test-Path $full)) { continue }
    $raw = Get-Content -Path $full -Raw
    $clean = Strip-LuaStringsAndComments $raw

    # Check delimiter balance: (), {}, []
    $p = 0; $b = 0; $k = 0
    for ($idx = 0; $idx -lt $clean.Length; $idx++) {
        switch ($clean[$idx]) {
            '(' { $p++ }
            ')' { $p-- }
            '{' { $b++ }
            '}' { $b-- }
            '[' { $k++ }
            ']' { $k-- }
        }
        if ($p -lt 0 -or $b -lt 0 -or $k -lt 0) { break }
    }
    if ($p -eq 0 -and $b -eq 0 -and $k -eq 0) {
        Pass "Balanced delimiters (), {}, [] in $f"
    } else {
        Fail "Unbalanced delimiters in $f (parens=$p, braces=$b, brackets=$k)"
    }

    # Check Lua block keyword balance (function/if/for/while/do vs end, repeat vs until)
    # Note: 'for ... do' and 'while ... do' have ONE 'end', so we count:
    # openers: function, if, for, while (standalone 'do' blocks not preceded by for/while)
    $tokens = [regex]::Matches($clean, '\b(function|if|elseif|for|while|do|repeat|until|end)\b') | ForEach-Object { $_.Value }
    $depth = 0
    $expectDo = $false
    $blockError = $false
    foreach ($tok in $tokens) {
        switch ($tok) {
            'function' { $depth++ }
            'if'       { $depth++ }
            'for'      { $depth++; $expectDo = $true }
            'while'    { $depth++; $expectDo = $true }
            'do'       {
                if ($expectDo) {
                    $expectDo = $false
                } else {
                    $depth++
                }
            }
            'repeat'   { $depth++ }
            'until'    { $depth-- }
            'end'      { $depth-- }
        }
        if ($depth -lt 0) {
            $blockError = $true
            break
        }
    }
    if (-not $blockError -and $depth -eq 0) {
        Pass "Balanced Lua control blocks (depth=0) in $f"
    } else {
        Fail "Unbalanced Lua control blocks in $f (final depth=$depth)"
    }

    # Policy check 1: Zero GameTooltip hooks (per user requirement: "No tool tip")
    if ($clean -match "\bGameTooltip\b|\bTooltipDataProcessor\b|\bItemRefTooltip\b") {
        Fail "Forbidden tooltip reference found in $f"
    } else {
        Pass "Zero WoW item tooltip hooks in $f"
    }

    # Policy check 2: Zero direct mutation of protected AuctionHouseFrame.Tabs / DisplayMode
    if ($clean -match "AuctionHouseFrame\.Tabs\s*\[[^\]]+\]\s*=|table\.insert\s*\(\s*AuctionHouseFrame\.Tabs|AuctionHouseFrame\.numTabs\s*=|AuctionHouseFrame\.DisplayMode\s*=") {
        Fail "Unsafe direct mutation of protected AuctionHouseFrame table in $f"
    } else {
        Pass "Taint-safe AuctionHouseFrame handling in $f"
    }

    # API regression check: WoW Line:SetStartPoint / SetEndPoint takes 4 args (not 5)
    if ($raw -match 'Set(Start|End)Point\s*\([^)]*,\s*[^)]*,\s*"(TOP|BOTTOM|LEFT|RIGHT|CENTER)') {
        Fail "Invalid 5-arg SetStartPoint/SetEndPoint call in $f (WoW Line API expects 4 args)"
    } else {
        Pass "Valid WoW Line:SetStartPoint/SetEndPoint signature in $f"
    }

    # Security check 1: Zero dynamic Lua code evaluation
    if ($clean -match '\b(loadstring|RunScript)\b') {
        Fail "Forbidden dynamic code execution (loadstring/RunScript) in $f"
    } else {
        Pass "Zero dynamic code execution in $f"
    }

    # Security & ToS check 2: Zero automated Auction House purchasing/posting calls
    if ($clean -match 'C_AuctionHouse\s*\.\s*(PlaceBid|ConfirmCommoditiesPurchase|StartCommoditiesPurchase|PostCommodity|PostItem)\s*\(') {
        Fail "Forbidden automated C_AuctionHouse transaction call in $f"
    } else {
        Pass "ToS-compliant (zero automated AH buy/post calls) in $f"
    }

    # Security & ToS check 3: Zero unattended repeating timers (C_Timer.NewTicker / periodic AFK scan loops)
    if ($clean -match 'C_Timer\s*\.\s*NewTicker\b|\bReschedulePeriodicScan\b|\bperiodicScanTimer\b') {
        Fail "Forbidden unattended repeating timer in $f"
    } else {
        Pass "ToS-compliant (zero unattended AFK timer loops) in $f"
    }
}

Write-Host ""
if ($Failures.Count -eq 0) {
    Write-Host "ALL CHECKS PASSED ($PassCount checks verified, 0 failures)." -ForegroundColor Green
    exit 0
} else {
    Write-Host "VERIFICATION FAILED ($($Failures.Count) failure(s)):" -ForegroundColor Red
    foreach ($fail in $Failures) {
        Write-Host "  - $fail" -ForegroundColor Red
    }
    exit 1
}
