-- DashboardUI.lua
-- Clean Google Finance–inspired Overview Dashboard (Classic WoW AH themed):
--  * Top Account-Wide Portfolio Banner (All Alts: Invested, Est. Net Value, Unrealized P&L, Booked Profit)
--  * Full-height Pinned Investments & Watch Cards Grid with live 1D Google Finance sparklines
--  * Drag-and-drop card reordering (persisted across all alts!)

local _, NS = ...

local Dashboard = {}
NS.Dashboard = Dashboard

local function BuildItemDisplay(itemID)
    local entry = NS.DB:GetWatchItem(itemID)
    if entry then
        return entry, true
    end
    local hist = NS.DB:GetItemHistory(itemID)
    local liveName, _, liveQual, _, _, _, _, _, _, liveIcon = NS.Compat.GetItemInfo(itemID)
    if not liveName then
        NS.Compat.RequestLoadItemDataByID(itemID)
    end
    return {
        itemID  = itemID,
        name    = liveName or (hist and hist.name) or ("Item #" .. tostring(itemID)),
        icon    = liveIcon or (hist and hist.icon) or NS.Compat.GetItemIconByID(itemID) or 134400,
        quality = (liveQual ~= nil) and liveQual or ((hist and hist.quality) or 1),
        group   = "AH Market",
    }, false
end

function Dashboard.Create(parent, onOpenItem)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    frame:Hide()

    ----------------------------------------------------------------------------
    -- 1. TOP PORTFOLIO BANNER (Account-Wide Across All Alts)
    ----------------------------------------------------------------------------
    local portBar = NS.CreatePanel(frame, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER_ACCENT, false)
    portBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    portBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    portBar:SetHeight(56)

    local portKpis = {
        { id = "invested", title = "All-Alts Invested" },
        { id = "netVal",   title = "Est. Net Value (5% Cut)" },
        { id = "unreal",   title = "Unrealized P&L" },
        { id = "realized", title = "Booked Profit" },
        { id = "status",   title = "Positions / API" },
    }
    local portCols = {}
    frame._portValues = {}

    for i = 1, #portKpis do
        local col = CreateFrame("Frame", nil, portBar)
        local tLbl = col:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tLbl:SetPoint("TOP", col, "TOP", 0, -8)
        tLbl:SetText(portKpis[i].title)

        local vLbl = col:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        vLbl:SetPoint("BOTTOM", col, "BOTTOM", 0, 10)
        vLbl:SetText("--")

        frame._portValues[portKpis[i].id] = vLbl
        portCols[i] = col
    end

    local function LayoutPortCols()
        local w = portBar:GetWidth() or 760
        local cw = math.max(90, (w - 12) / #portCols)
        for i = 1, #portCols do
            portCols[i]:ClearAllPoints()
            portCols[i]:SetPoint("TOPLEFT", portBar, "TOPLEFT", 6 + (i - 1) * cw, 0)
            portCols[i]:SetSize(cw, 56)
        end
    end
    portBar:SetScript("OnSizeChanged", LayoutPortCols)
    LayoutPortCols()

    ----------------------------------------------------------------------------
    -- 2. FULL-HEIGHT PINNED INVESTMENTS & WATCH CARDS GRID (DRAG-AND-DROP)
    ----------------------------------------------------------------------------
    local pinnedPanel = NS.CreatePanel(frame, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, false)
    pinnedPanel:SetPoint("TOPLEFT", portBar, "BOTTOMLEFT", 0, -6)
    pinnedPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

    local pinTitle = pinnedPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pinTitle:SetPoint("TOPLEFT", 12, -10)
    pinTitle:SetText("Pinned Investments & Market Watch (Today 00:00 -> 24:00)")

    local scanBtn = NS.CreateButton(pinnedPanel, "Scan Pinned", 96, 21, true)
    scanBtn:SetPoint("TOPRIGHT", pinnedPanel, "TOPRIGHT", -10, -6)
    scanBtn:SetScript("OnClick", function()
        if NS.Scanner:IsScanning() then
            NS.Scanner:StopScan("USER_STOP")
        else
            NS.Scanner:StartDashboardScan()
        end
    end)
    frame._scanBtn = scanBtn

    local pinHint = pinnedPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    pinHint:SetPoint("RIGHT", scanBtn, "LEFT", -10, 0)
    pinHint:SetText("Drag to reorder  |  Click for chart")

    local pinScroll = CreateFrame("ScrollFrame", "ForeverMarketWatchDashScroll", pinnedPanel, "UIPanelScrollFrameTemplate")
    pinScroll:SetPoint("TOPLEFT", pinnedPanel, "TOPLEFT", 10, -32)
    pinScroll:SetPoint("BOTTOMRIGHT", pinnedPanel, "BOTTOMRIGHT", -28, 10)

    local pinChild = CreateFrame("Frame", nil, pinScroll)
    pinChild:SetWidth(720)
    pinChild:SetHeight(1)
    pinScroll:SetScrollChild(pinChild)

    local pinEmpty = pinnedPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pinEmpty:SetPoint("CENTER", pinnedPanel, "CENTER", 0, -6)
    pinEmpty:SetJustifyH("CENTER")
    pinEmpty:SetTextColor(0.75, 0.68, 0.56, 1)
    pinEmpty:SetText("No pinned investments yet.\n\nGo to 'Market & Charts', pick any item, and click 'Pin' or 'Invest'\nto track it here with live Google Finance sparklines!")
    pinEmpty:Hide()

    -- Floating Drag Ghost Card (follows cursor smoothly while dragging)
    local dragGhost = NS.CreatePanel(UIParent, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER_ACCENT, false)
    dragGhost:SetSize(210, 44)
    dragGhost:SetFrameStrata("TOOLTIP")
    dragGhost:SetAlpha(0.92)
    dragGhost:Hide()

    local ghostIcon = dragGhost:CreateTexture(nil, "ARTWORK")
    ghostIcon:SetSize(26, 26)
    ghostIcon:SetPoint("LEFT", 10, 0)
    ghostIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local ghostName = dragGhost:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ghostName:SetPoint("LEFT", ghostIcon, "RIGHT", 8, 5)
    ghostName:SetPoint("RIGHT", dragGhost, "RIGHT", -8, 5)
    ghostName:SetJustifyH("LEFT")
    ghostName:SetWordWrap(false)

    local ghostSub = dragGhost:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ghostSub:SetPoint("LEFT", ghostIcon, "RIGHT", 8, -8)
    ghostSub:SetText("Drop on another card to reorder")

    frame._cards = {}
    local draggingItemID = nil
    local draggingSourceCard = nil
    local hoveredTargetCard = nil

    local function FindHoveredCard()
        local scale = UIParent:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        cx, cy = cx / scale, cy / scale

        for i = 1, #frame._cards do
            local c = frame._cards[i]
            if c and c:IsShown() and c._itemID then
                local l, r, b, t = c:GetLeft(), c:GetRight(), c:GetBottom(), c:GetTop()
                if l and r and b and t and cx >= l and cx <= r and cy >= b and cy <= t then
                    return c
                end
            end
        end
        return nil
    end

    local function ClearDropHighlights()
        for i = 1, #frame._cards do
            local c = frame._cards[i]
            if c and c.SetBackdropBorderColor then
                c:SetBackdropBorderColor(NS.COLORS.BORDER[1], NS.COLORS.BORDER[2], NS.COLORS.BORDER[3], NS.COLORS.BORDER[4])
                c:SetAlpha(1.0)
            end
        end
        hoveredTargetCard = nil
    end

    local function StopDragging()
        dragGhost:SetScript("OnUpdate", nil)
        dragGhost:Hide()

        local target = FindHoveredCard()
        local fromID = draggingItemID
        draggingItemID = nil
        draggingSourceCard = nil
        ClearDropHighlights()

        if fromID and target and target._itemID and target._itemID ~= fromID then
            NS.DB:MovePinnedItem(fromID, target._itemID)
        end
    end

    local function StartDragging(card, entry)
        if not card or not card._itemID then return end
        draggingItemID = card._itemID
        draggingSourceCard = card
        card:SetAlpha(0.45)

        ghostIcon:SetTexture(entry.icon or 134400)
        local qr, qg, qb = NS.Compat.GetQualityColor(entry.quality)
        ghostName:SetTextColor(qr, qg, qb, 1)
        ghostName:SetText(entry.name or ("Item #" .. tostring(card._itemID)))

        dragGhost:Show()
        dragGhost:SetScript("OnUpdate", function(self)
            if not IsMouseButtonDown("LeftButton") then
                StopDragging()
                return
            end
            local scale = UIParent:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            self:ClearAllPoints()
            self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", (cx / scale) + 12, (cy / scale) - 8)

            local over = FindHoveredCard()
            if over ~= hoveredTargetCard then
                if hoveredTargetCard and hoveredTargetCard.SetBackdropBorderColor then
                    hoveredTargetCard:SetBackdropBorderColor(NS.COLORS.BORDER[1], NS.COLORS.BORDER[2], NS.COLORS.BORDER[3], NS.COLORS.BORDER[4])
                end
                hoveredTargetCard = over
                if hoveredTargetCard and hoveredTargetCard ~= draggingSourceCard and hoveredTargetCard.SetBackdropBorderColor then
                    hoveredTargetCard:SetBackdropBorderColor(NS.COLORS.BORDER_ACCENT[1], NS.COLORS.BORDER_ACCENT[2], NS.COLORS.BORDER_ACCENT[3], 1)
                end
            end
        end)
    end

    frame:SetScript("OnHide", function()
        if draggingItemID then
            draggingItemID = nil
            draggingSourceCard = nil
            dragGhost:SetScript("OnUpdate", nil)
            dragGhost:Hide()
            ClearDropHighlights()
        end
    end)

    local function GetOrCreateCard(idx)
        if frame._cards[idx] then
            return frame._cards[idx]
        end

        local card = NS.CreatePanel(pinChild, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER, false)
        card:SetHeight(116)
        card:EnableMouse(true)

        local clicker = CreateFrame("Button", nil, card)
        clicker:SetAllPoints()
        clicker:RegisterForClicks("LeftButtonUp")
        clicker:RegisterForDrag("LeftButton")

        local hl = clicker:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.28)
        card.clicker = clicker

        local icon = card:CreateTexture(nil, "ARTWORK")
        icon:SetSize(26, 26)
        icon:SetPoint("TOPLEFT", 10, -9)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        card.icon = icon

        local nameTxt = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        nameTxt:SetPoint("TOPLEFT", icon, "TOPRIGHT", 7, 0)
        nameTxt:SetPoint("RIGHT", card, "RIGHT", -24, 0)
        nameTxt:SetJustifyH("LEFT")
        nameTxt:SetWordWrap(false)
        card.nameTxt = nameTxt

        local priceTxt = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        priceTxt:SetPoint("TOPLEFT", icon, "TOPRIGHT", 7, -15)
        priceTxt:SetJustifyH("LEFT")
        card.priceTxt = priceTxt

        local deltaTxt = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        deltaTxt:SetPoint("TOPRIGHT", card, "TOPRIGHT", -22, -24)
        deltaTxt:SetJustifyH("RIGHT")
        card.deltaTxt = deltaTxt

        local unpinBtn = CreateFrame("Button", nil, card)
        unpinBtn:SetSize(16, 16)
        unpinBtn:SetPoint("TOPRIGHT", -5, -6)
        unpinBtn:SetFrameLevel(clicker:GetFrameLevel() + 2)
        local ut = unpinBtn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        ut:SetPoint("CENTER")
        ut:SetText("x")
        unpinBtn.txt = ut
        unpinBtn:SetScript("OnEnter", function(s) s.txt:SetTextColor(0.96, 0.35, 0.33, 1) end)
        unpinBtn:SetScript("OnLeave", function(s) s.txt:SetTextColor(0.65, 0.58, 0.48, 1) end)
        card.unpinBtn = unpinBtn

        local spark = NS.Chart.CreateSparkline(card)
        spark:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -42)
        spark:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -42)
        spark:SetHeight(50)
        card.spark = spark

        local footTxt = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        footTxt:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 10, 7)
        footTxt:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -10, 7)
        footTxt:SetJustifyH("LEFT")
        footTxt:SetWordWrap(false)
        card.footTxt = footTxt

        frame._cards[idx] = card
        return card
    end

    ----------------------------------------------------------------------------
    -- Full Refresh
    ----------------------------------------------------------------------------

    function frame:Refresh()
        -- 1. Account-Wide Portfolio Summary
        local port = NS.DB:GetPortfolioSummary()
        self._portValues.invested:SetText(NS.FormatMoney(port.totalInvested, false))
        self._portValues.netVal:SetText(NS.FormatMoney(port.estNetValue, false))

        local uClr = (port.unrealizedPnL >= 0) and "|cFF38D972+" or "|cFFF55954"
        local uPct = (port.totalInvested > 0) and ((port.unrealizedPnL / port.totalInvested) * 100) or 0
        self._portValues.unreal:SetText(string.format("%s%s (%+.1f%%)|r", uClr, NS.FormatMoney(port.unrealizedPnL, true), uPct))

        local rClr = (port.realizedProfit >= 0) and "|cFF38D972+" or "|cFFF55954"
        self._portValues.realized:SetText(rClr .. NS.FormatMoney(port.realizedProfit, true) .. "|r")

        local apiTs = NS.DB:GetExternalSyncTimestamp()
        local apiTxt = (apiTs > 0) and ("|cFF38D972API " .. NS.FormatRelativeTime(apiTs) .. "|r") or "Local"
        self._portValues.status:SetText(string.format("%d Active  |  %s", port.activePositions, apiTxt))

        -- 2. Full-Height Pinned Cards Grid (3 columns, larger 50px sparklines, drag-and-drop reorderable)
        local pinnedIDs = NS.DB:GetDashboardPinnedIDs()
        pinEmpty:SetShown(#pinnedIDs == 0)

        local ahOpen = NS.Scanner and NS.Scanner:IsAuctionHouseOpen()
        local scanning = NS.Scanner and NS.Scanner:IsScanning()
        local isDemo = NS.DB:IsDemoMode()
        if scanning then
            scanBtn:SetTextLabel("Stop")
            scanBtn:SetEnabledState(true)
        else
            scanBtn:SetTextLabel("Scan Pinned")
            scanBtn:SetEnabledState(ahOpen and not isDemo and #pinnedIDs > 0)
        end

        local viewW = math.max(360, pinScroll:GetWidth() or 720)
        pinChild:SetWidth(viewW)
        local cols = (viewW >= 620) and 3 or 2
        local gap = 8
        local cardW = math.floor((viewW - gap * (cols - 1)) / cols)
        local cardH = 116

        for i = 1, #pinnedIDs do
            local itemID = pinnedIDs[i]
            local entry = BuildItemDisplay(itemID)
            local hist = NS.DB:GetItemHistory(itemID)
            local sum = NS.Analytics.GetItemSummary(entry, hist, "1D")
            local dayCtx = NS.Analytics.GetDayContext(hist)
            local card = GetOrCreateCard(i)

            card._itemID = itemID
            local r = math.floor((i - 1) / cols)
            local c = (i - 1) % cols
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", pinChild, "TOPLEFT", c * (cardW + gap), -(r * (cardH + gap)))
            card:SetSize(cardW, cardH)

            card.icon:SetTexture(entry.icon or 134400)
            local qr, qg, qb = NS.Compat.GetQualityColor(entry.quality)
            card.nameTxt:SetTextColor(qr, qg, qb, 1)
            card.nameTxt:SetText(entry.name)
            card.priceTxt:SetText(sum.latestMin and NS.FormatMoney(sum.latestMin, true) or "--")

            if dayCtx and dayCtx.dayDeltaPct ~= nil then
                local dClr = (dayCtx.dayDeltaPct >= 0) and "|cFF38D972+" or "|cFFF55954"
                card.deltaTxt:SetText(string.format("%s%.1f%%|r", dClr, dayCtx.dayDeltaPct))
            else
                card.deltaTxt:SetText("|cFF998C780.0%|r")
            end

            if sum.investQty and sum.investQty > 0 then
                local pClr = (sum.investUnrealizedPnL and sum.investUnrealizedPnL >= 0) and "|cFF38D972+" or "|cFFF55954"
                card.footTxt:SetText(string.format("Inv: %d (%s)  %s%s|r",
                    sum.investQty,
                    (sum.investment and sum.investment.holder) or "Alt",
                    pClr,
                    sum.investUnrealizedPnL and NS.FormatMoney(sum.investUnrealizedPnL, true) or "--"
                ))
            else
                local swStr = "--"
                if sum.swing7dPct ~= nil then
                    local swClr = (sum.swing7dPct >= 20) and "|cFF38D972" or ((sum.swing7dPct >= 10) and "|cFFFFD100" or "|cFFB0A48E")
                    swStr = string.format("%s%.0f%%|r", swClr, sum.swing7dPct)
                end
                local liqClr = (sum.liquidityTier == "High") and "|cFF38D972" or ((sum.liquidityTier == "Med") and "|cFFFFD100" or "|cFFF55954")
                local wallPart = (sum.wallQty and sum.wallQty > 0) and ("  |  Wall: " .. tostring(sum.wallQty)) or ""
                card.footTxt:SetText(string.format("Swing: %s  |  Vol: %d (%s%s|r)%s",
                    swStr, sum.latestQty or 0, liqClr, sum.liquidityTier or "Low", wallPart
                ))
            end

            card.spark:Render(sum.series, dayCtx)

            card.clicker:SetScript("OnClick", function()
                if not draggingItemID and onOpenItem then
                    onOpenItem(itemID)
                end
            end)
            card.clicker:SetScript("OnDragStart", function()
                StartDragging(card, entry)
            end)
            card.clicker:SetScript("OnDragStop", function()
                StopDragging()
            end)

            local isInvOnly = (sum.investQty and sum.investQty > 0) and (not NS.DB:IsPinned(itemID))
            card.unpinBtn:SetShown(not isInvOnly)
            card.unpinBtn:SetScript("OnClick", function()
                NS.DB:SetPinned(itemID, false)
            end)

            card:Show()
        end

        for i = #pinnedIDs + 1, #self._cards do
            self._cards[i]._itemID = nil
            self._cards[i]:Hide()
        end

        local totalRows = math.ceil(#pinnedIDs / cols)
        pinChild:SetHeight(math.max(1, totalRows * (cardH + gap)))
    end

    pinScroll:SetScript("OnSizeChanged", function()
        if frame:IsShown() then
            frame:Refresh()
        end
    end)

    return frame
end
