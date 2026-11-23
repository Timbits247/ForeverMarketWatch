-- Tests.lua
-- Built-in in-game unit test runner (/fmw test) and isolated 90-day Demo Preview
-- dataset generator (/fmw demo) that never modifies real realm SavedVariables.

local _, NS = ...

--------------------------------------------------------------------------------
-- 90-Day Synthetic Demo Dataset (Isolated In-Memory Preview)
--------------------------------------------------------------------------------

local DEMO_ITEMS = {
    {
        itemID = 13468, name = "Black Lotus", icon = 134208, quality = 2,
        group = "Herbalism", basePrice = 852435, volatility = 0.14, trend = 0.08,
        baseQty = 18, buyTarget = 790000, sellTarget = 980000, phase = 0.3,
    },
    {
        itemID = 13444, name = "Major Mana Potion", icon = 134851, quality = 1,
        group = "Alchemy", basePrice = 34275, volatility = 0.18, trend = -0.04,
        baseQty = 260, buyTarget = 31000, sellTarget = 42000, phase = 1.4,
    },
    {
        itemID = 12363, name = "Arcane Crystal", icon = 134118, quality = 2,
        group = "Mining", basePrice = 621580, volatility = 0.11, trend = 0.12,
        baseQty = 35, buyTarget = 590000, sellTarget = 670000, phase = 2.1,
    },
    {
        itemID = 14047, name = "Runecloth", icon = 132903, quality = 1,
        group = "Tailoring", basePrice = 1485, volatility = 0.20, trend = 0.05,
        baseQty = 640, buyTarget = 1250, sellTarget = 1900, phase = 0.9,
    },
    {
        itemID = 14344, name = "Large Brilliant Shard", icon = 132884, quality = 3,
        group = "Enchanting", basePrice = 42540, volatility = 0.15, trend = -0.05,
        baseQty = 48, buyTarget = 39000, sellTarget = 50000, phase = 2.8,
    },
    {
        itemID = 15417, name = "Devilsaur Leather", icon = 134254, quality = 2,
        group = "Skinning", basePrice = 118560, volatility = 0.16, trend = 0.06,
        baseQty = 42, buyTarget = 105000, sellTarget = 135000, phase = 1.9,
    },
}

local function BuildDemoMarket()
    local now = (time and time()) or 1763830000
    local market = {
        groups = {
            "Herbalism", "Mining", "Skinning", "Tailoring",
            "Enchanting", "Alchemy", "Blacksmithing & Eng", "Cooking & Fishing",
        },
        watchlist = {},
        history = {},
        investments = {
            [13468] = {
                qty = 12, avgCost = 815000, totalCost = 9780000,
                realizedProfit = 145000, holder = "Bankalt", notes = "Hold for Tue raid",
                name = "Black Lotus", icon = 134208, quality = 2,
                updatedAt = now - 86400,
            },
            [13444] = {
                qty = 80, avgCost = 29500, totalCost = 2360000,
                realizedProfit = 42000, holder = "Mainchar, Bankalt", notes = "Raid dips",
                name = "Major Mana Potion", icon = 134851, quality = 1,
                updatedAt = now - 43200,
            },
        },
        ledger = {
            {
                id = 1, ts = now - (3 * 86400), type = "BUY", itemID = 13468,
                name = "Black Lotus", icon = 134208, quality = 2, qty = 15,
                unitPrice = 815000, gross = 12225000, ahCut = 0, netTotal = 12225000,
                costBasis = 12225000, profit = nil, roiPct = nil, matched = "BUY",
                character = "Bankalt", counterparty = "", source = "AH",
            },
            {
                id = 2, ts = now - (2 * 86400), type = "SELL", itemID = 13468,
                name = "Black Lotus", icon = 134208, quality = 2, qty = 3, matchedQty = 3,
                unitPrice = 910000, gross = 2730000, ahCut = 136500, netTotal = 2593500,
                costBasis = 2445000, profit = 148500, roiPct = 6.07, matched = "FULL",
                character = "Bankalt", counterparty = "Raiderone", source = "MAIL",
            },
            {
                id = 3, ts = now - (1 * 86400), type = "BUY", itemID = 13444,
                name = "Major Mana Potion", icon = 134851, quality = 1, qty = 100,
                unitPrice = 29500, gross = 2950000, ahCut = 0, netTotal = 2950000,
                costBasis = 2950000, profit = nil, roiPct = nil, matched = "BUY",
                character = "Mainchar", counterparty = "", source = "AH",
            },
            {
                id = 4, ts = now - (6 * 3600), type = "SELL", itemID = 13444,
                name = "Major Mana Potion", icon = 134851, quality = 1, qty = 20, matchedQty = 20,
                unitPrice = 33200, gross = 664000, ahCut = 33200, netTotal = 630800,
                costBasis = 590000, profit = 40800, roiPct = 6.92, matched = "FULL",
                character = "Bankalt", counterparty = "Healbot", source = "MAIL",
            },
        },
        ledgerNextId = 5,
        pendingMailMatches = {},
        pinned = {
            [13468] = true,
            [13444] = true,
            [12363] = true,
            [14047] = true,
            [14344] = true,
            [15417] = true,
        },
        lastAutoScan = now,
    }

    for idx = 1, #DEMO_ITEMS do
        local spec = DEMO_ITEMS[idx]
        market.watchlist[spec.itemID] = {
            itemID     = spec.itemID,
            name       = spec.name,
            icon       = spec.icon,
            quality    = spec.quality,
            group      = spec.group,
            buyTarget  = spec.buyTarget,
            sellTarget = spec.sellTarget,
            addedAt    = now - (90 * 86400),
        }

        local daily = {}
        local intraday = {}

        for d = 90, 8, -1 do
            local ts = now - (d * 86400)
            local dayKey = NS.DayKeyFromTimestamp(ts)
            local progress = (90 - d) / 90
            local wave = math.sin((d * 0.85) + spec.phase) * spec.volatility
            local raidSpike = ((d % 7) == 2 or (d % 7) == 3) and 0.07 or -0.02
            local factor = 1 + (spec.trend * progress) + wave + raidSpike
            local minP = math.max(15, math.floor(spec.basePrice * factor) + ((d * 17) % 97))
            local avgP = math.floor(minP * 1.07)
            local maxP = math.floor(minP * (1.16 + (math.abs(math.cos(d)) * 0.12)))
            local qty  = math.max(2, math.floor(spec.baseQty * (1 - wave * 0.7)))
            daily[dayKey] = { minP, avgP, maxP, minP, qty, 5 }
        end

        for h = 168, 0, -6 do
            local ts = now - (h * 3600)
            local dayFloat = h / 24
            local wave = math.sin((dayFloat * 0.95) + spec.phase) * spec.volatility
            local micro = math.cos(h * 0.4 + idx) * 0.04
            local factor = 1 + spec.trend + wave + micro
            local minP = math.max(15, math.floor(spec.basePrice * factor) + ((h * 13) % 89))
            local avgP = math.floor(minP * 1.06)
            local maxP = math.floor(minP * 1.18)
            local qty  = math.max(2, math.floor(spec.baseQty * (1 - wave * 0.65)))
            table.insert(intraday, { ts, minP, avgP, maxP, qty })
        end

        if spec.itemID == 13444 then
            intraday[#intraday][2] = 24245 -- Below 31000 buyTarget AND 30-day low!
        elseif spec.itemID == 14047 then
            intraday[#intraday][2] = 1095  -- Triggers 7-day & 24h low!
        elseif spec.itemID == 14344 then
            intraday[#intraday][2] = 35120 -- Triggers 24h low!
        elseif spec.itemID == 12363 then
            intraday[#intraday][2] = 685420 -- Above 670000 sellTarget (68g 54s 20c)
        end

        local latestMin = intraday[#intraday][2]
        local demoWallQty = math.max(4, math.floor(spec.baseQty * 0.18))
        market.history[spec.itemID] = {
            name      = spec.name,
            icon      = spec.icon,
            quality   = spec.quality,
            daily     = daily,
            intraday  = intraday,
            orderBook = {
                wallQty   = demoWallQty,
                wallCost  = math.floor(demoWallQty * latestMin * 1.04),
                nextPrice = math.floor(latestMin * 1.12),
                updatedAt = now - 240,
            },
            lastScan  = now - 240,
        }
    end

    return market
end

function NS.ToggleDemoMode()
    if NS.DB:IsDemoMode() then
        NS.DB:SetDemoMode(false)
        NS.Print("Demo Preview OFF — switched back to live market: " .. NS.DB:GetActiveMarketKey())
    else
        NS.DB:SetDemoMode(true, BuildDemoMarket())
        NS.Print("Demo Preview ON — showing 90 days of isolated sample data (real AH data untouched). Run /fmw demo again to exit.")
    end
end

--------------------------------------------------------------------------------
-- In-Game Unit Self-Test Suite (/fmw test)
--------------------------------------------------------------------------------

function NS.RunSelfTests()
    local passed = 0
    local failed = 0

    local function AssertEq(label, actual, expected)
        if actual == expected then
            passed = passed + 1
        else
            failed = failed + 1
            NS.PrintError(string.format("FAIL [%s]: expected '%s', got '%s'", label, tostring(expected), tostring(actual)))
        end
    end

    local function AssertTrue(label, cond)
        if cond then
            passed = passed + 1
        else
            failed = failed + 1
            NS.PrintError("FAIL [" .. label .. "]: condition was false")
        end
    end

    -- 1. Money parsing & full Gold/Silver/Copper formatting
    AssertEq("ParseMoney 2g 50s 25c", NS.ParseMoney("2g 50s 25c"), 25025)
    AssertEq("ParseMoney 1.5g", NS.ParseMoney("1.5g"), 15000)
    AssertEq("ParseMoney plain gold", NS.ParseMoney("4.25"), 42500)
    AssertEq("ParseMoney 45s 12c", NS.ParseMoney("45s 12c"), 4512)
    AssertEq("ParseMoney blank", NS.ParseMoney("   "), nil)
    AssertEq("FormatMoneyPlain with copper", NS.FormatMoneyPlain(25025), "2g 50s 25c")
    AssertEq("FormatMoney compact includes copper", NS.FormatMoney(125432, true), "12g 54s 32c")
    AssertTrue("FormatMoney full includes Copper icon", (NS.FormatMoney(125432, false):find("UI%-CopperIcon") ~= nil))

    -- 2. Profession catalog & offline search
    AssertTrue("Catalog populated (>=100 mats)", NS.Catalog and #NS.Catalog.ITEMS >= 100)
    local lotusMatches = NS.Catalog.Search("lotus", 10)
    AssertTrue("Catalog search finds Black Lotus", #lotusMatches >= 1)

    -- 3. Item link & ID parsing
    AssertEq("ParseItemID numeric", NS.Compat.ParseItemID("13444"), 13444)
    AssertEq("ParseItemID link", NS.Compat.ParseItemID("|cffffffff|Hitem:13468::::::::60:::::::|h[Black Lotus]|h|r"), 13468)

    -- 4. Moving average calculation
    local pts = {
        { ts = 1, min = 100 },
        { ts = 2, min = 200 },
        { ts = 3, min = 300 },
        { ts = 4, min = 400 },
    }
    NS.Analytics.ApplyMovingAverage(pts, 2)
    AssertEq("SMA pt1", pts[1].ma, 100)
    AssertEq("SMA pt2", pts[2].ma, 150)
    AssertEq("SMA pt3", pts[3].ma, 250)
    AssertEq("SMA pt4", pts[4].ma, 350)

    -- 5. Target alert evaluation
    AssertEq("Alert BUY", NS.Analytics.EvaluateAlert(24000, 25000, 40000), "BUY")
    AssertEq("Alert SELL", NS.Analytics.EvaluateAlert(41000, 25000, 40000), "SELL")
    AssertEq("Alert NONE", NS.Analytics.EvaluateAlert(32000, 25000, 40000), "NONE")

    -- 6. Intraday -> Daily Compaction
    local baseNow = (time and time()) or 1795392000
    local oldTs1 = baseNow - (10 * 86400)
    local oldTs2 = oldTs1 + 3600
    local recentTs = baseNow - 3600
    local testHist = {
        intraday = {
            { oldTs1, 10000, 12000, 15000, 20 },
            { oldTs2, 14000, 16000, 18000, 40 },
            { recentTs, 11000, 11500, 13000, 30 },
        },
        daily = {},
    }
    NS.DB:CompactItemHistory(testHist, baseNow)
    AssertEq("Compaction kept recent intraday", #testHist.intraday, 1)
    local dayKey = NS.DayKeyFromTimestamp(oldTs1)
    local folded = testHist.daily[dayKey]
    AssertTrue("Compaction created daily bucket", folded ~= nil)
    if folded then
        AssertEq("Daily min", folded[1], 10000)
        AssertEq("Daily avg", folded[2], 14000)
        AssertEq("Daily max", folded[3], 18000)
        AssertEq("Daily avgQty", folded[5], 30)
        AssertEq("Daily samples", folded[6], 2)
    end

    -- 7. Series builder across timeframes
    local series30 = NS.Analytics.BuildSeries(testHist, "30D", baseNow)
    AssertEq("Series 30D combines daily + intraday", #series30, 2)
    local series1D = NS.Analytics.BuildSeries(testHist, "1D", baseNow)
    AssertEq("Series 1D only recent", #series1D, 1)

    -- 8. External Blizzard API Feed merge & deduplication
    local mockMarket = { watchlist = {}, history = {} }
    local factionKey = NS.DB:GetActiveMarketKey():match("%-([^-]+)$") or "Neutral"
    local mockFeed = {
        syncedAt = baseNow,
        houses = {
            [factionKey] = {
                [13468] = {
                    intraday = {
                        { baseNow - 7200, 100000, 105000, 115000, 20 },
                        { baseNow - 3600, 102000, 107000, 118000, 24 },
                    },
                    daily = {
                        [20261110] = { 95000, 101000, 112000, 99000, 19, 12 },
                    },
                    lastScan = baseNow - 3600,
                },
            },
        },
    }
    local merged1 = NS.DB:MergeExternalFeed(mockFeed, mockMarket)
    local merged2 = NS.DB:MergeExternalFeed(mockFeed, mockMarket) -- idempotent re-merge
    AssertEq("External feed merged 1 item", merged1, 1)
    AssertEq("External feed re-merge idempotent", merged2, 1)
    AssertEq("External feed intraday deduped", #mockMarket.history[13468].intraday, 2)
    AssertTrue("External feed daily merged", mockMarket.history[13468].daily[20261110] ~= nil)

    -- 9. 24h / 7d / 30d Low Filter Detection
    local lowHist = {
        intraday = {
            { baseNow - 5 * 86400, 12000, 12500, 13000, 40 },
            { baseNow - 12 * 3600, 11000, 11500, 12000, 35 },
            { baseNow - 1800,       9500, 10000, 10500, 50 }, -- Lowest in 24h, 7d, and 30d!
        },
        daily = {
            [NS.DayKeyFromTimestamp(baseNow - 20 * 86400)] = { 10500, 11000, 12000, 10800, 30, 5 },
        },
        lastScan = baseNow - 1800,
    }
    local lows = NS.Analytics.CheckPeriodLows(lowHist, baseNow)
    AssertTrue("Detects 24h Low", lows.low24h)
    AssertTrue("Detects 7d Low", lows.low7d)
    AssertTrue("Detects 30d Low", lows.low30d)

    local flatHist = {
        intraday = {
            { baseNow - 3600, 10000, 10000, 10000, 10 },
            { baseNow - 600,  10000, 10000, 10000, 10 },
        },
        daily = {},
        lastScan = baseNow - 600,
    }
    AssertTrue("Flat price is not a false 24h low", not NS.Analytics.IsAtPeriodLow(flatHist, "1D", baseNow))

    -- 10. Day-of-Week Seasonality & 5% AH-Cut Net Profit / Break-Even
    local cyc = NS.Analytics.ComputeDayOfWeekCycle(lowHist)
    AssertTrue("Weekday cycle computes valid days", cyc.validDays >= 2)
    local sumFlip = NS.Analytics.GetItemSummary({ itemID = 999999 }, lowHist, "7D", baseNow)
    AssertTrue("Break-even > latestMin (5% AH cut)", sumFlip.breakEven and sumFlip.breakEven > 9500)
    AssertTrue("Est ROI% computed", sumFlip.estRoiPct ~= nil)
    AssertTrue("7D Volatility swing% computed", sumFlip.swing7dPct and sumFlip.swing7dPct > 0)

    -- 11. Account-Wide Investment Ledger (weighted avg + realized profit after 5% cut)
    local testInvID = 999998
    NS.DB:ClearInvestment(testInvID)
    local okBuy1 = NS.DB:LogInvestmentBuy(testInvID, 10, 10000, "Bankalt", nil, true)
    local okBuy2 = NS.DB:LogInvestmentBuy(testInvID, 10, 20000, "Mainchar", nil, true)
    local inv = NS.DB:GetInvestment(testInvID)
    AssertTrue("Investment buys logged", okBuy1 and okBuy2 and inv ~= nil)
    if inv then
        AssertEq("Investment total qty", inv.qty, 20)
        AssertEq("Investment weighted avg cost", inv.avgCost, 15000)
    end
    local okSale, netProf = NS.DB:LogInvestmentSale(testInvID, 10, 20000, true) -- 10 @ 2g = 20g * 0.95 = 19g - 15g = +4g (40000c)
    AssertTrue("Investment sale booked", okSale)
    AssertEq("Investment net realized profit (5% cut)", netProf, 40000)
    NS.DB:ClearInvestment(testInvID)

    -- 12. Dashboard Pinning, Drag-and-Drop Reorder & Google Finance 1D Day Bounds
    local testPinB = 999997
    NS.DB:SetPinned(testInvID, true)
    NS.DB:SetPinned(testPinB, true)
    AssertTrue("Item pinned to Dashboard", NS.DB:IsPinned(testInvID))
    local moved = NS.DB:MovePinnedItem(testPinB, testInvID)
    AssertTrue("Pinned item reordered via MovePinnedItem", moved)
    NS.DB:SetPinned(testInvID, false)
    NS.DB:SetPinned(testPinB, false)
    AssertTrue("Item unpinned from Dashboard", not NS.DB:IsPinned(testInvID))
    local dayCtx = NS.Analytics.GetDayContext(lowHist, baseNow)
    AssertTrue("Day context spans 24h (86400s)", (dayCtx.dayEnd - dayCtx.dayStart) == 86400)

    -- 13. Crafted Item Underlying Mats & Craft Cost Overlay Lookup
    local fapRec = NS.Arbitrage and NS.Arbitrage.GetRecipeForProduct(5634)
    AssertTrue("Free Action Potion recipe exists", fapRec ~= nil and #fapRec.reagents == 2)

    -- 14. Auto-Ledger Buy/Sale Accounting & Mailbox Dedup
    local testLedID = 999996
    NS.DB:ClearInvestment(testLedID)
    local okLB, buyRec = NS.DB:RecordLedgerBuy(testLedID, 10, 100000, { name = "Test Lotus", source = "AH", ts = baseNow - 600 })
    AssertTrue("Auto-ledger BUY recorded", okLB and buyRec ~= nil)
    local invAfterBuy = NS.DB:GetInvestment(testLedID)
    AssertTrue("Auto-ledger BUY populated Inventory", invAfterBuy and invAfterBuy.qty == 10 and invAfterBuy.avgCost == 10000)

    NS.DB:AddPendingMailMatch(testLedID, 10, 100000, baseNow - 600)
    -- Test split commodity delivery (e.g. bought 10 at AH -> arrives as 6 + 4 in mailbox)
    local m1 = NS.DB:ConsumePendingMailMatch(testLedID, 6, 60000, baseNow)
    local m2 = NS.DB:ConsumePendingMailMatch(testLedID, 4, 40000, baseNow)
    local m3 = NS.DB:ConsumePendingMailMatch(testLedID, 4, 40000, baseNow)
    AssertTrue("Mailbox dedup consumes split delivery (6 + 4)", m1 and m2)
    AssertTrue("Mailbox dedup rejects extra duplicate after consumed", not m3)

    local okLS, sellRec = NS.DB:RecordLedgerSale(testLedID, 4, 60000, 3000, { name = "Test Lotus", source = "MAIL", ts = baseNow - 100 })
    AssertTrue("Auto-ledger SELL recorded", okLS and sellRec ~= nil)
    if sellRec then
        AssertEq("Auto-ledger SELL net profit (57000 - 40000)", sellRec.profit, 17000)
    end
    local invAfterSell = NS.DB:GetInvestment(testLedID)
    AssertEq("Inventory qty reduced after SELL", invAfterSell and invAfterSell.qty, 6)

    -- Clean up synthetic ledger test entries
    if buyRec and buyRec.id then NS.DB:DeleteLedgerEntry(buyRec.id, true) end
    if sellRec and sellRec.id then NS.DB:DeleteLedgerEntry(sellRec.id, true) end
    NS.DB:ClearInvestment(testLedID)

    -- 15. Flipping Tab Targeted Items Query
    AssertTrue("GetTargetedItemIDs returns table", type(NS.DB:GetTargetedItemIDs()) == "table")

    if failed == 0 then
        NS.Print(string.format("Self-tests complete: |cFF38D972%d PASSED|r, 0 failed.", passed))
    else
        NS.PrintError(string.format("Self-tests complete: %d passed, %d FAILED.", passed, failed))
    end
end
