-- FlippingUI.lua
-- Quick-Snipe Flipping Tab (Dashboard-style card grid for targeted items ONLY):
--   * Shows ONLY items with a Buy Target and/or Sell Target set.
--   * Instant 1-second traffic-light color coding on the entire card & sparkline chart:
--       - GREEN  : Price <= Buy Target (SNIPE / BUY NOW!)
--       - YELLOW : Price in the middle between Buy and Sell targets
--       - RED    : Price >= Sell Target (SELL NOW!)
--   * Displays exact Under-Target Snipe quantity & total buyout cost (after AH scan),
--     7D Volatility (Swing%), Volume / Liquidity tier, and Net Flip Spread (after 5% cut)
--     so you can spot fast-moving quick flips at a glance.
--   * 1-click "Scan Targets" (fast scan of ONLY targeted items) and 1-click "Snipe <N>"
--     right on every card (jumps straight to Auctionator's Shopping tab + prints exact qty).

local _, NS = ...

local FlippingUI = {}
NS.FlippingUI = FlippingUI

local ZONE_STYLES = {
    BUY = {
        rank       = 1,
        cardBg     = { 0.075, 0.165, 0.105, 0.95 },
        cardBorder = { 0.220, 0.880, 0.460, 1.00 },
        chartBg    = { 0.045, 0.130, 0.075, 0.92 },
        lineColor  = { 0.220, 0.940, 0.480, 1.00 },
        textHex    = "|cFF22EB70",
    },
    SELL = {
        rank       = 2,
        cardBg     = { 0.185, 0.080, 0.080, 0.95 },
        cardBorder = { 0.960, 0.320, 0.300, 1.00 },
        chartBg    = { 0.140, 0.050, 0.050, 0.92 },
        lineColor  = { 0.980, 0.340, 0.320, 1.00 },
        textHex    = "|cFFFF4D4D",
    },
    MID = {
        rank       = 3,
        cardBg     = { 0.165, 0.135, 0.065, 0.95 },
        cardBorder = { 0.940, 0.760, 0.180, 0.95 },
        chartBg    = { 0.125, 0.100, 0.040, 0.92 },
        lineColor  = { 1.000, 0.820, 0.220, 1.00 },
        textHex    = "|cFFFFD100",
    },
}

local FLIP_SORT_OPTS = {
    { value = "priority", label = "Snipe Priority" },
    { value = "swing",    label = "Volatility (7D)" },
    { value = "volume",   label = "Volume (Fastest)" },
    { value = "spread",   label = "Target Spread %" },
}

local function ClassifyTargetZone(latestMin, buyTarget, sellTarget)
    if not latestMin or latestMin <= 0 then
        return "MID", "NO DATA", 999
    end

    if buyTarget and buyTarget > 0 and latestMin <= buyTarget then
        local pct = ((latestMin - buyTarget) / buyTarget) * 100
        local badge = (pct <= -0.1) and string.format("BUY %.1f%%", pct) or "BUY HIT"
        return "BUY", badge, pct
    end

    if sellTarget and sellTarget > 0 and latestMin >= sellTarget then
        local pct = ((latestMin - sellTarget) / sellTarget) * 100
        local badge = (pct >= 0.1) and string.format("SELL +%.1f%%", pct) or "SELL HIT"
        return "SELL", badge, -pct
    end

    local distBuy = (buyTarget and buyTarget > 0) and (((latestMin - buyTarget) / buyTarget) * 100) or nil
    local distSell = (sellTarget and sellTarget > 0) and (((sellTarget - latestMin) / sellTarget) * 100) or nil

    if distBuy and distSell then
        if distBuy <= distSell then
            return "MID", string.format("+%.1f%% >Buy", distBuy), distBuy
        else
            return "MID", string.format("-%.1f%% <Sell", distSell), distSell
        end
    elseif distBuy then
        return "MID", string.format("+%.1f%% >Buy", distBuy), distBuy
    elseif distSell then
        return "MID", string.format("-%.1f%% <Sell", distSell), distSell
    end

    return "MID", "WATCH", 500
end

-- Public helper so top nav bar can show a live green BUY count badge on the Flipping tab!
function FlippingUI.CountBuyHits()
    local ids = NS.DB:GetTargetedItemIDs()
    local hits = 0
    for i = 1, #ids do
        local entry = NS.DB:GetWatchItem(ids[i])
        if entry and entry.buyTarget and entry.buyTarget > 0 then
            local hist = NS.DB:GetItemHistory(ids[i])
            local latest = hist and NS.Analytics and NS.Analytics.GetLatestPoint(hist) or nil
            if latest and latest.min and latest.min > 0 and latest.min <= entry.buyTarget then
                hits = hits + 1
            end
        end
    end
    return hits
end

function FlippingUI.Create(parent, onOpenItem, onEditTargets)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    frame:Hide()

    local zoneFilter = "ALL"      -- "ALL", "BUY", "MID", "SELL"
    local sortMode   = "priority" -- "priority", "swing", "volume", "spread"
    local timeframe  = "1D"       -- "1D", "7D"

    ----------------------------------------------------------------------------
    -- 1. TOP QUICK-SNIPE CONTROL BAR
    ----------------------------------------------------------------------------
    local topBar = NS.CreatePanel(frame, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER_ACCENT, false)
    topBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    topBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    topBar:SetHeight(38)

    local filterBtns = {}
    local filterDefs = {
        { id = "ALL",  label = "All",  w = 64 },
        { id = "BUY",  label = "Buy",  w = 68 },
        { id = "MID",  label = "Mid",  w = 68 },
        { id = "SELL", label = "Sell", w = 68 },
    }
    local prev = nil
    for i = 1, #filterDefs do
        local def = filterDefs[i]
        local b = NS.CreateButton(topBar, def.label, def.w, 24, false)
        if not prev then
            b:SetPoint("LEFT", topBar, "LEFT", 8, 0)
        else
            b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        end
        b:SetScript("OnClick", function()
            zoneFilter = def.id
            frame:Refresh()
        end)
        filterBtns[def.id] = b
        prev = b
    end

    local sortDrop = NS.CreateDropdown(topBar, 128, 24, function(val)
        sortMode = val or "priority"
        frame:Refresh()
    end)
    sortDrop:SetPoint("LEFT", prev, "RIGHT", 10, 0)
    sortDrop:SetOptions(FLIP_SORT_OPTS)
    sortDrop:SetSelected(sortMode, false)

    local scanBtn = NS.CreateButton(topBar, "Scan Targets", 104, 24, true)
    scanBtn:SetPoint("RIGHT", topBar, "RIGHT", -8, 0)
    scanBtn:SetScript("OnClick", function()
        if NS.Scanner:IsScanning() then
            NS.Scanner:StopScan("USER_STOP")
        else
            NS.Scanner:StartTargetScan()
        end
    end)
    frame._scanBtn = scanBtn

    local tf7Btn = NS.CreateButton(topBar, "7D", 32, 24, false)
    tf7Btn:SetPoint("RIGHT", scanBtn, "LEFT", -8, 0)
    tf7Btn:SetScript("OnClick", function()
        timeframe = "7D"
        frame:Refresh()
    end)

    local tf1Btn = NS.CreateButton(topBar, "1D", 32, 24, false)
    tf1Btn:SetPoint("RIGHT", tf7Btn, "LEFT", -3, 0)
    tf1Btn:SetScript("OnClick", function()
        timeframe = "1D"
        frame:Refresh()
    end)

    ----------------------------------------------------------------------------
    -- 2. FULL-HEIGHT SNIPE CARDS GRID
    ----------------------------------------------------------------------------
    local gridPanel = NS.CreatePanel(frame, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, false)
    gridPanel:SetPoint("TOPLEFT", topBar, "BOTTOMLEFT", 0, -6)
    gridPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

    local scroll = CreateFrame("ScrollFrame", "ForeverMarketWatchFlipScroll", gridPanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", gridPanel, "TOPLEFT", 10, -10)
    scroll:SetPoint("BOTTOMRIGHT", gridPanel, "BOTTOMRIGHT", -28, 10)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(720)
    child:SetHeight(1)
    scroll:SetScrollChild(child)

    local emptyTxt = gridPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyTxt:SetPoint("CENTER", gridPanel, "CENTER", 0, 0)
    emptyTxt:SetJustifyH("CENTER")
    emptyTxt:SetTextColor(0.75, 0.68, 0.56, 1)
    emptyTxt:Hide()

    frame._cards = {}

    local function GetOrCreateCard(idx)
        if frame._cards[idx] then return frame._cards[idx] end
        local c = NS.CreatePanel(child, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER, true)
        c:SetSize(236, 168)

        -- Main clickable surface (opens full chart in Market & Charts)
        local clicker = CreateFrame("Button", nil, c)
        clicker:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0)
        clicker:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 29)
        local hl = clicker:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.16)
        c.clicker = clicker

        -- Row 1: Framed Icon + Item Name + Zone Badge
        local iconBg = c:CreateTexture(nil, "BORDER")
        iconBg:SetSize(26, 26)
        iconBg:SetPoint("TOPLEFT", 8, -7)
        iconBg:SetColorTexture(0.45, 0.36, 0.22, 0.9)

        local icon = c:CreateTexture(nil, "ARTWORK")
        icon:SetSize(24, 24)
        icon:SetPoint("CENTER", iconBg, "CENTER", 0, 0)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        c.icon = icon

        local badgeTxt = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        badgeTxt:SetPoint("TOPRIGHT", -8, -8)
        badgeTxt:SetJustifyH("RIGHT")
        c.badgeTxt = badgeTxt

        local nameTxt = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameTxt:SetPoint("TOPLEFT", iconBg, "TOPRIGHT", 6, 0)
        nameTxt:SetPoint("TOPRIGHT", badgeTxt, "TOPLEFT", -4, 1)
        nameTxt:SetHeight(14)
        nameTxt:SetJustifyH("LEFT")
        nameTxt:SetWordWrap(false)
        c.nameTxt = nameTxt

        -- Row 2: Live Price (left) + Under-Target Snipe Callout / Holdings (right)
        local priceTxt = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        priceTxt:SetPoint("BOTTOMLEFT", iconBg, "BOTTOMRIGHT", 6, -1)
        priceTxt:SetJustifyH("LEFT")
        c.priceTxt = priceTxt

        local snipeTxt = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        snipeTxt:SetPoint("BOTTOMRIGHT", c, "TOPRIGHT", -8, -33)
        snipeTxt:SetJustifyH("RIGHT")
        c.snipeTxt = snipeTxt

        -- Row 3: Color-coded target sparkline chart
        local spark = NS.Chart.CreateSparkline(c)
        spark:SetPoint("TOPLEFT", c, "TOPLEFT", 8, -39)
        spark:SetPoint("TOPRIGHT", c, "TOPRIGHT", -8, -39)
        spark:SetHeight(54)
        c.spark = spark

        -- Row 4: Volatility (7D Swing%) + Volume / Liquidity + Dip Wall Strip
        local metricsTxt = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        metricsTxt:SetPoint("TOPLEFT", spark, "BOTTOMLEFT", 1, -4)
        metricsTxt:SetPoint("TOPRIGHT", spark, "BOTTOMRIGHT", -1, -4)
        metricsTxt:SetHeight(13)
        metricsTxt:SetJustifyH("LEFT")
        metricsTxt:SetWordWrap(false)
        c.metricsTxt = metricsTxt

        -- Subtle divider above target & action footer
        local div = c:CreateTexture(nil, "ARTWORK")
        div:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 6, 50)
        div:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -6, 50)
        div:SetHeight(1)
        div:SetColorTexture(0.45, 0.38, 0.25, 0.35)

        -- Row 5A: Buy & Sell Targets (left) + Target Net Profit % after AH cut (right)
        local targetPctTxt = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        targetPctTxt:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -8, 32)
        targetPctTxt:SetJustifyH("RIGHT")
        c.targetPctTxt = targetPctTxt

        local targetsTxt = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        targetsTxt:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 8, 32)
        targetsTxt:SetPoint("BOTTOMRIGHT", targetPctTxt, "BOTTOMLEFT", -6, 0)
        targetsTxt:SetHeight(14)
        targetsTxt:SetJustifyH("LEFT")
        targetsTxt:SetWordWrap(false)
        c.targetsTxt = targetsTxt

        -- Row 5B: Per-Unit Target Net Profit (left) + Edit + 1-click Snipe/Buy (right)
        local buyBtn = NS.CreateButton(c, "Snipe", 68, 21, true)
        buyBtn:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -6, 5)
        c.buyBtn = buyBtn

        local editBtn = NS.CreateButton(c, "Edit", 36, 21, false)
        editBtn:SetPoint("RIGHT", buyBtn, "LEFT", -4, 0)
        c.editBtn = editBtn

        local targetSubTxt = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        targetSubTxt:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 8, 9)
        targetSubTxt:SetPoint("BOTTOMRIGHT", editBtn, "BOTTOMLEFT", -4, 4)
        targetSubTxt:SetHeight(13)
        targetSubTxt:SetJustifyH("LEFT")
        targetSubTxt:SetWordWrap(false)
        c.targetSubTxt = targetSubTxt

        frame._cards[idx] = c
        return c
    end

    scroll:SetScript("OnSizeChanged", function()
        if frame:IsShown() then
            frame:Refresh()
        end
    end)

    function frame:Refresh()
        -- 1. Update timeframe & scan buttons
        tf1Btn:SetActiveState(timeframe == "1D")
        tf7Btn:SetActiveState(timeframe == "7D")

        local ahOpen = NS.Scanner and NS.Scanner:IsAuctionHouseOpen()
        local scanning = NS.Scanner and NS.Scanner:IsScanning()
        local isDemo = NS.DB:IsDemoMode()
        if scanning then
            scanBtn:SetTextLabel("Stop")
            scanBtn:SetEnabledState(true)
        else
            scanBtn:SetTextLabel("Scan Targets")
            scanBtn:SetEnabledState(ahOpen and not isDemo)
        end

        -- 2. Gather ALL watchlist items that have Buy and/or Sell targets set
        local targetedIDs = NS.DB:GetTargetedItemIDs()
        local cutRate = (NS.Analytics and NS.Analytics.GetAHCutRate()) or 0.05
        local counts = { ALL = 0, BUY = 0, MID = 0, SELL = 0 }
        local items = {}

        for i = 1, #targetedIDs do
            local itemID = targetedIDs[i]
            local entry = NS.DB:GetWatchItem(itemID)
            if entry then
                local hist = NS.DB:GetItemHistory(itemID)
                local sum = NS.Analytics.GetItemSummary(entry, hist, timeframe)
                local dayCtx = (timeframe == "1D") and NS.Analytics.GetDayContext(hist) or nil
                local zone, badge, sortKey = ClassifyTargetZone(sum.latestMin, entry.buyTarget, entry.sellTarget)
                local underDepth = (zone == "BUY" and NS.Analytics.ComputeUnderTargetDepth)
                    and NS.Analytics.ComputeUnderTargetDepth(hist, entry.buyTarget) or nil

                local targetSpreadPct = nil
                local targetNetCopper = nil
                if entry.buyTarget and entry.buyTarget > 0 and entry.sellTarget and entry.sellTarget > 0 then
                    targetNetCopper = math.floor((entry.sellTarget * (1 - cutRate)) - entry.buyTarget + 0.5)
                    targetSpreadPct = (targetNetCopper / entry.buyTarget) * 100
                end

                counts.ALL = counts.ALL + 1
                counts[zone] = (counts[zone] or 0) + 1

                if zoneFilter == "ALL" or zoneFilter == zone then
                    table.insert(items, {
                        itemID          = itemID,
                        entry           = entry,
                        sum             = sum,
                        dayCtx          = dayCtx,
                        zone            = zone,
                        badge           = badge,
                        sortKey         = sortKey,
                        underDepth      = underDepth,
                        targetSpreadPct = targetSpreadPct,
                        targetNetCopper = targetNetCopper,
                        style           = ZONE_STYLES[zone] or ZONE_STYLES.MID,
                    })
                end
            end
        end

        filterBtns.ALL:SetTextLabel(string.format("All (%d)", counts.ALL))
        filterBtns.BUY:SetTextLabel(string.format("|cFF22EB70Buy (%d)|r", counts.BUY))
        filterBtns.MID:SetTextLabel(string.format("|cFFFFD100Mid (%d)|r", counts.MID))
        filterBtns.SELL:SetTextLabel(string.format("|cFFFF4D4DSell (%d)|r", counts.SELL))
        for id, btn in pairs(filterBtns) do
            btn:SetActiveState(id == zoneFilter)
        end

        table.sort(items, function(a, b)
            if sortMode == "swing" then
                local as = a.sum.swing7dPct or -1
                local bs = b.sum.swing7dPct or -1
                if as ~= bs then return as > bs end
            elseif sortMode == "volume" then
                local av = a.sum.latestQty or 0
                local bv = b.sum.latestQty or 0
                if av ~= bv then return av > bv end
            elseif sortMode == "spread" then
                local ap = a.targetSpreadPct or -999
                local bp = b.targetSpreadPct or -999
                if ap ~= bp then return ap > bp end
            end
            if a.style.rank ~= b.style.rank then
                return a.style.rank < b.style.rank
            end
            if a.sortKey ~= b.sortKey then
                return a.sortKey < b.sortKey
            end
            return (a.entry.name or ""):lower() < (b.entry.name or ""):lower()
        end)

        emptyTxt:SetShown(#items == 0)
        if #items == 0 then
            if counts.ALL == 0 then
                emptyTxt:SetText("No Buy/Sell targets set yet.\n\nGo to 'Market & Charts', pick any item you flip, and click 'Targets'\nto set Buy <= and/or Sell >= prices — they'll appear here as instant snipe cards!")
            else
                emptyTxt:SetText("No targeted items are currently in the '" .. zoneFilter .. "' zone.\n\nClick 'All' to view all targeted items or 'Scan Targets' at the AH for live prices.")
            end
        end

        -- 3. Render upgraded quick-snipe cards
        local viewW = math.max(360, scroll:GetWidth() or 720)
        child:SetWidth(viewW)
        local cols = (viewW >= 640) and 3 or 2
        local gap = 8
        local cardW = math.floor((viewW - gap * (cols - 1)) / cols)
        local cardH = 168

        for i = 1, #items do
            local d = items[i]
            local entry = d.entry
            local sum = d.sum
            local st = d.style
            local depth = d.underDepth
            local card = GetOrCreateCard(i)

            local r = math.floor((i - 1) / cols)
            local c = (i - 1) % cols
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", child, "TOPLEFT", c * (cardW + gap), -(r * (cardH + gap)))
            card:SetSize(cardW, cardH)

            if card.SetBackdropColor then
                card:SetBackdropColor(st.cardBg[1], st.cardBg[2], st.cardBg[3], st.cardBg[4])
            end
            if card.SetBackdropBorderColor then
                card:SetBackdropBorderColor(st.cardBorder[1], st.cardBorder[2], st.cardBorder[3], st.cardBorder[4])
            end

            card.icon:SetTexture(entry.icon or 134400)
            local qr, qg, qb = NS.Compat.GetQualityColor(entry.quality)
            card.nameTxt:SetTextColor(qr, qg, qb, 1)
            card.nameTxt:SetText(entry.name or ("Item #" .. tostring(d.itemID)))

            card.badgeTxt:SetText(st.textHex .. d.badge .. "|r")
            card.priceTxt:SetText(sum.latestMin and NS.FormatMoney(sum.latestMin, true) or "|cFF998C78No Data|r")

            -- Right-side Row 2 Callout: Under-Target Snipe Qty+Cost (BUY) | Held P&L | 7D Avg
            if d.zone == "BUY" then
                if depth and depth.qty and depth.qty > 0 then
                    local prefix = depth.exact and "" or "~"
                    card.snipeTxt:SetText(string.format("|cFF22EB70%s%dx <= Buy (%s)|r", prefix, depth.qty, NS.FormatMoney(depth.cost or 0, true)))
                elseif sum.wallQty and sum.wallQty > 0 then
                    card.snipeTxt:SetText(string.format("|cFF22EB70Wall: %d (%s)|r", sum.wallQty, NS.FormatMoney(sum.wallCost or 0, true)))
                else
                    card.snipeTxt:SetText("|cFF22EB70Scan for exact qty|r")
                end
            elseif sum.investQty and sum.investQty > 0 then
                card.snipeTxt:SetText(string.format("|cFFFFD100Inv %d|r %s",
                    sum.investQty, sum.investUnrealizedPnL and NS.FormatSignedMoney(sum.investUnrealizedPnL, true) or ""))
            elseif sum.avg7d and sum.avg7d > 0 then
                card.snipeTxt:SetText("|cFFB0A48E7D: " .. NS.FormatMoney(sum.avg7d, true) .. "|r")
            else
                card.snipeTxt:SetText("")
            end

            -- Render the entire sparkline chart in GREEN (Buy), YELLOW (Mid), or RED (Sell)
            card.spark:Render(sum.series, d.dayCtx, {
                lineColor    = st.lineColor,
                bgColor      = st.chartBg,
                buyTarget    = entry.buyTarget,
                sellTarget   = entry.sellTarget,
                hideBaseline = true,
                areaFill     = true,
                areaAlpha    = 0.18,
                lineWidth    = 2.1,
            })

            -- Row 4: Volatility (7D Swing%) + Volume/Liquidity + Dip Wall
            local swingStr
            if sum.swing7dPct ~= nil then
                local swClr = (sum.swing7dPct >= 20) and "|cFF38D972" or ((sum.swing7dPct >= 10) and "|cFFFFD100" or "|cFFB0A48E")
                swingStr = string.format("Swing: %s%.0f%%|r", swClr, sum.swing7dPct)
            else
                swingStr = "Swing: --"
            end

            local liqClr = (sum.liquidityTier == "High") and "|cFF38D972" or ((sum.liquidityTier == "Med") and "|cFFFFD100" or "|cFFF55954")
            local volStr = string.format("Vol: %d (%s%s|r)", sum.latestQty or 0, liqClr, sum.liquidityTier or "Low")
            local wallStr = (sum.wallQty and sum.wallQty > 0) and ("  |  Wall: " .. tostring(sum.wallQty)) or ""
            card.metricsTxt:SetText(swingStr .. "  |  " .. volStr .. wallStr)

            -- Row 5A: Buy & Sell Targets + Target Profit % (net of AH cut)
            local tParts = {}
            if entry.buyTarget and entry.buyTarget > 0 then
                table.insert(tParts, "|cFF22EB70B:|r" .. NS.FormatMoney(entry.buyTarget, true))
            end
            if entry.sellTarget and entry.sellTarget > 0 then
                table.insert(tParts, "|cFFFF4D4DS:|r" .. NS.FormatMoney(entry.sellTarget, true))
            end
            card.targetsTxt:SetText(table.concat(tParts, "  "))

            if d.targetSpreadPct ~= nil then
                local pctClr = (d.targetSpreadPct >= 10) and "|cFF38D972" or ((d.targetSpreadPct > 0) and "|cFFFFD100" or "|cFFF55954")
                card.targetPctTxt:SetText(string.format("%s%+.1f%% net|r", pctClr, d.targetSpreadPct))
            else
                card.targetPctTxt:SetText("")
            end

            -- Row 5B: Per-Unit Target Net Profit (or Break-Even) + Edit + Snipe/Buy
            if d.targetNetCopper ~= nil then
                card.targetSubTxt:SetText("Net: " .. NS.FormatSignedMoney(d.targetNetCopper, true) .. "/ea")
            elseif entry.buyTarget and entry.buyTarget > 0 then
                card.targetSubTxt:SetText("BE: " .. NS.FormatMoney(math.ceil(entry.buyTarget / (1 - cutRate)), true))
            elseif entry.sellTarget and entry.sellTarget > 0 then
                card.targetSubTxt:SetText("Net: " .. NS.FormatMoney(math.floor(entry.sellTarget * (1 - cutRate) + 0.5), true))
            else
                card.targetSubTxt:SetText("")
            end

            local buyLabel = "Buy"
            if d.zone == "BUY" then
                if depth and depth.qty and depth.qty > 0 then
                    buyLabel = "Snipe " .. tostring(depth.qty)
                else
                    buyLabel = "Snipe"
                end
            end
            card.buyBtn:SetTextLabel(buyLabel)
            card.buyBtn:SetEnabledState(ahOpen and not isDemo)
            card.buyBtn:SetActiveState(d.zone == "BUY")
            card.buyBtn:SetScript("OnClick", function()
                if NS.Scanner and NS.Scanner.JumpToItemInAH then
                    local snipeInfo = nil
                    if d.zone == "BUY" then
                        snipeInfo = {
                            buyTarget = entry.buyTarget,
                            underQty  = depth and depth.qty or nil,
                            underCost = depth and depth.cost or nil,
                        }
                    end
                    NS.Scanner:JumpToItemInAH(d.itemID, snipeInfo)
                end
            end)

            card.editBtn:SetScript("OnClick", function(btn)
                if onEditTargets then
                    onEditTargets(btn, d.itemID)
                end
            end)

            card.clicker:SetScript("OnClick", function()
                if onOpenItem then
                    onOpenItem(d.itemID)
                end
            end)

            card:Show()
        end

        for i = #items + 1, #self._cards do
            self._cards[i]:Hide()
        end

        local totalRows = math.ceil(#items / cols)
        child:SetHeight(math.max(1, totalRows * (cardH + gap)))
    end

    return frame
end
