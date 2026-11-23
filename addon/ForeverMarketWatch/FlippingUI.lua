-- FlippingUI.lua
-- Quick-Snipe Flipping Tab (Dashboard-style card grid for targeted items ONLY):
--   * Shows ONLY items with a Buy Target and/or Sell Target set.
--   * Instant 1-second traffic-light color coding on the entire card & sparkline chart:
--       - GREEN  : Price <= Buy Target (SNIPE / BUY NOW!)
--       - YELLOW : Price in the middle between Buy and Sell targets
--       - RED    : Price >= Sell Target (SELL NOW!)
--   * Auto-sorted by urgency (Green Buy snipes first -> Red Sell hits -> Yellow Mid).
--   * 1-click "Scan Targets" (fast scan of ONLY targeted items) and 1-click "Buy"
--     right on every card (jumps straight into Auctionator's Shopping tab).

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

local function ClassifyTargetZone(latestMin, buyTarget, sellTarget)
    if not latestMin or latestMin <= 0 then
        return "MID", "NO DATA", 999
    end

    if buyTarget and buyTarget > 0 and latestMin <= buyTarget then
        local pct = ((latestMin - buyTarget) / buyTarget) * 100
        local badge = (pct <= -0.1) and string.format("BUY %.1f%%", pct) or "BUY HIT"
        return "BUY", badge, pct -- More negative = deeper snipe, sorts first!
    end

    if sellTarget and sellTarget > 0 and latestMin >= sellTarget then
        local pct = ((latestMin - sellTarget) / sellTarget) * 100
        local badge = (pct >= 0.1) and string.format("SELL +%.1f%%", pct) or "SELL HIT"
        return "SELL", badge, -pct -- Higher above sell target sorts first!
    end

    -- In the middle: show distance to whichever target is closer
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

function FlippingUI.Create(parent, onOpenItem, onEditTargets)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    frame:Hide()

    local zoneFilter = "ALL" -- "ALL", "BUY", "MID", "SELL"
    local timeframe = "1D"   -- "1D", "7D"

    ----------------------------------------------------------------------------
    -- 1. TOP QUICK-SNIPE CONTROL BAR
    ----------------------------------------------------------------------------
    local topBar = NS.CreatePanel(frame, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER_ACCENT, false)
    topBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    topBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    topBar:SetHeight(38)

    local filterBtns = {}
    local filterDefs = {
        { id = "ALL",  label = "All",  w = 68 },
        { id = "BUY",  label = "Buy",  w = 72 },
        { id = "MID",  label = "Mid",  w = 72 },
        { id = "SELL", label = "Sell", w = 72 },
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

    local tf7Btn = NS.CreateButton(topBar, "7D", 34, 24, false)
    tf7Btn:SetPoint("RIGHT", scanBtn, "LEFT", -8, 0)
    tf7Btn:SetScript("OnClick", function()
        timeframe = "7D"
        frame:Refresh()
    end)

    local tf1Btn = NS.CreateButton(topBar, "1D", 34, 24, false)
    tf1Btn:SetPoint("RIGHT", tf7Btn, "LEFT", -3, 0)
    tf1Btn:SetScript("OnClick", function()
        timeframe = "1D"
        frame:Refresh()
    end)

    local legendTxt = topBar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    legendTxt:SetPoint("LEFT", prev, "RIGHT", 12, 0)
    legendTxt:SetPoint("RIGHT", tf1Btn, "LEFT", -8, 0)
    legendTxt:SetJustifyH("CENTER")
    legendTxt:SetWordWrap(false)
    legendTxt:SetText("|cFF22EB70Green: Buy|r  |  |cFFFFD100Yellow: Mid|r  |  |cFFFF4D4DRed: Sell|r")

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
        c:SetSize(232, 134)

        -- Main clickable surface (opens full chart in Market & Charts)
        local clicker = CreateFrame("Button", nil, c)
        clicker:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0)
        clicker:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 26)
        local hl = clicker:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.18)
        c.clicker = clicker

        local icon = c:CreateTexture(nil, "ARTWORK")
        icon:SetSize(24, 24)
        icon:SetPoint("TOPLEFT", 8, -8)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        c.icon = icon

        local badgeTxt = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        badgeTxt:SetPoint("TOPRIGHT", -8, -8)
        badgeTxt:SetJustifyH("RIGHT")
        c.badgeTxt = badgeTxt

        local nameTxt = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameTxt:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, 0)
        nameTxt:SetPoint("RIGHT", badgeTxt, "LEFT", -4, 0)
        nameTxt:SetJustifyH("LEFT")
        nameTxt:SetWordWrap(false)
        c.nameTxt = nameTxt

        local priceTxt = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        priceTxt:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 6, -1)
        priceTxt:SetJustifyH("LEFT")
        c.priceTxt = priceTxt

        local qtyTxt = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        qtyTxt:SetPoint("BOTTOMRIGHT", c, "TOPRIGHT", -8, -32)
        qtyTxt:SetJustifyH("RIGHT")
        c.qtyTxt = qtyTxt

        -- Color-coded target sparkline chart
        local spark = NS.Chart.CreateSparkline(c)
        spark:SetPoint("TOPLEFT", c, "TOPLEFT", 8, -37)
        spark:SetPoint("TOPRIGHT", c, "TOPRIGHT", -8, -37)
        spark:SetHeight(64)
        c.spark = spark

        -- Bottom Quick-Action Bar (Targets + 1-click Buy & Edit)
        local buyBtn = NS.CreateButton(c, "Buy", 42, 20, true)
        buyBtn:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -6, 5)
        c.buyBtn = buyBtn

        local editBtn = NS.CreateButton(c, "Edit", 38, 20, false)
        editBtn:SetPoint("RIGHT", buyBtn, "LEFT", -4, 0)
        c.editBtn = editBtn

        local targetsTxt = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        targetsTxt:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 8, 9)
        targetsTxt:SetPoint("RIGHT", editBtn, "LEFT", -6, 0)
        targetsTxt:SetJustifyH("LEFT")
        targetsTxt:SetWordWrap(false)
        c.targetsTxt = targetsTxt

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

                counts.ALL = counts.ALL + 1
                counts[zone] = (counts[zone] or 0) + 1

                if zoneFilter == "ALL" or zoneFilter == zone then
                    table.insert(items, {
                        itemID  = itemID,
                        entry   = entry,
                        sum     = sum,
                        dayCtx  = dayCtx,
                        zone    = zone,
                        badge   = badge,
                        sortKey = sortKey,
                        style   = ZONE_STYLES[zone] or ZONE_STYLES.MID,
                    })
                end
            end
        end

        -- Update top filter pill labels with live counts
        filterBtns.ALL:SetTextLabel(string.format("All (%d)", counts.ALL))
        filterBtns.BUY:SetTextLabel(string.format("|cFF22EB70Buy (%d)|r", counts.BUY))
        filterBtns.MID:SetTextLabel(string.format("|cFFFFD100Mid (%d)|r", counts.MID))
        filterBtns.SELL:SetTextLabel(string.format("|cFFFF4D4DSell (%d)|r", counts.SELL))
        for id, btn in pairs(filterBtns) do
            btn:SetActiveState(id == zoneFilter)
        end

        -- Auto-sort by urgency: Green BUY snipes first -> Red SELL targets -> Yellow MID (closest first)
        table.sort(items, function(a, b)
            if a.style.rank ~= b.style.rank then
                return a.style.rank < b.style.rank
            end
            if a.sortKey ~= b.sortKey then
                return a.sortKey < b.sortKey
            end
            return (a.entry.name or ""):lower() < (b.entry.name or ""):lower()
        end)

        -- Empty states
        emptyTxt:SetShown(#items == 0)
        if #items == 0 then
            if counts.ALL == 0 then
                emptyTxt:SetText("No Buy/Sell targets set yet.\n\nGo to 'Market & Charts', pick any item you flip, and click 'Targets'\nto set Buy <= and/or Sell >= prices — they'll appear here as instant snipe cards!")
            else
                emptyTxt:SetText("No targeted items are currently in the '" .. zoneFilter .. "' zone.\n\nClick 'All' to view all targeted items or 'Scan Targets' at the AH for live prices.")
            end
        end

        -- 3. Render color-coded card grid
        local viewW = math.max(360, scroll:GetWidth() or 720)
        child:SetWidth(viewW)
        local cols = (viewW >= 620) and 3 or 2
        local gap = 8
        local cardW = math.floor((viewW - gap * (cols - 1)) / cols)
        local cardH = 134

        for i = 1, #items do
            local d = items[i]
            local entry = d.entry
            local sum = d.sum
            local st = d.style
            local card = GetOrCreateCard(i)

            local r = math.floor((i - 1) / cols)
            local c = (i - 1) % cols
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", child, "TOPLEFT", c * (cardW + gap), -(r * (cardH + gap)))
            card:SetSize(cardW, cardH)

            -- Whole-card traffic-light tint & border!
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

            if sum.investQty and sum.investQty > 0 then
                card.qtyTxt:SetText(string.format("|cFFFFD100Inv:%d|r  AH:%d", sum.investQty, sum.latestQty or 0))
            else
                card.qtyTxt:SetText(string.format("AH Qty: %d", sum.latestQty or 0))
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

            -- Bottom target legend
            local tParts = {}
            if entry.buyTarget and entry.buyTarget > 0 then
                table.insert(tParts, "|cFF22EB70B:|r" .. NS.FormatMoney(entry.buyTarget, true))
            end
            if entry.sellTarget and entry.sellTarget > 0 then
                table.insert(tParts, "|cFFFF4D4DS:|r" .. NS.FormatMoney(entry.sellTarget, true))
            end
            card.targetsTxt:SetText(table.concat(tParts, " "))

            card.buyBtn:SetEnabledState(ahOpen and not isDemo)
            card.buyBtn:SetActiveState(d.zone == "BUY")
            card.buyBtn:SetScript("OnClick", function()
                if NS.Scanner and NS.Scanner.JumpToItemInAH then
                    NS.Scanner:JumpToItemInAH(d.itemID)
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
