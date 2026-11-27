-- DashboardUI.lua
-- Clean Google Finance–inspired Overview Dashboard (Classic WoW AH themed):
--  * Top Account-Wide Portfolio Banner (All Alts: Invested, Est. Net Value, Unrealized P&L, Booked Profit)
--  * Dynamic Profession Sub-Tabs (All, Herbs, Mining, Fishing, Enchant, Alchemy, Tailoring, ..., + Holdings)
--  * Grouped Category Sections when viewing 'All' so Herbs, Fishing, and Mining Ores/Bars stay grouped together
--  * Drag-and-drop card reordering (persisted across all alts!)

local _, NS = ...

local Dashboard = {}
NS.Dashboard = Dashboard

local requestedItemInfo = {}

local function BuildItemDisplay(itemID)
    local entry = NS.DB:GetWatchItem(itemID)
    if entry then
        return entry, true
    end
    local hist = NS.DB:GetItemHistory(itemID)
    local catSpec = NS.Catalog and NS.Catalog.BY_ID and NS.Catalog.BY_ID[itemID]
    local liveName, _, liveQual, _, _, _, _, _, _, liveIcon = NS.Compat.GetItemInfo(itemID)
    if not liveName and not (hist and hist.name) and not catSpec and not requestedItemInfo[itemID] then
        requestedItemInfo[itemID] = true
        NS.Compat.RequestLoadItemDataByID(itemID)
    end
    return {
        itemID  = itemID,
        name    = liveName or (hist and hist.name) or (catSpec and catSpec[2]) or ("Item #" .. tostring(itemID)),
        icon    = liveIcon or (hist and hist.icon) or NS.Compat.GetItemIconByID(itemID) or 134400,
        quality = (liveQual ~= nil) and liveQual or ((hist and hist.quality) or (catSpec and catSpec[4]) or 1),
        group   = "AH Market",
    }, false
end

local function ResolveCategoryMeta(catID)
    if NS.Catalog and NS.Catalog.DASHBOARD_CATEGORIES then
        for i = 1, #NS.Catalog.DASHBOARD_CATEGORIES do
            local def = NS.Catalog.DASHBOARD_CATEGORIES[i]
            if def.id == catID then
                return def.pill, def.title, i
            end
        end
    end
    if catID == "Other" then
        return "Other", "Other Pinned Items", 999
    end
    return catID, catID, 500
end

function Dashboard.Create(parent, onOpenItem)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    frame:Hide()

    local activeSubTab = (NS.DB and NS.DB:GetSettings().dashboardSubTab) or "ALL"
    local activeScanIDs = {}

    ----------------------------------------------------------------------------
    -- 1. TOP PORTFOLIO BANNER (Account-Wide Across All Alts)
    ----------------------------------------------------------------------------
    local portBar = NS.CreatePanel(frame, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER_ACCENT, false)
    portBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    portBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    portBar:SetHeight(50)

    local portKpis = {
        { id = "invested", title = "Invested" },
        { id = "netVal",   title = "Est. Net Value" },
        { id = "unreal",   title = "Unrealized P&L" },
        { id = "realized", title = "Booked Profit" },
        { id = "status",   title = "Active / Sync" },
    }
    local portCols = {}
    frame._portValues = {}

    for i = 1, #portKpis do
        local col = CreateFrame("Frame", nil, portBar)
        local tLbl = col:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tLbl:SetPoint("TOP", col, "TOP", 0, -7)
        tLbl:SetText(portKpis[i].title)

        local vLbl = col:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        vLbl:SetPoint("BOTTOMLEFT", col, "BOTTOMLEFT", 4, 8)
        vLbl:SetPoint("BOTTOMRIGHT", col, "BOTTOMRIGHT", -4, 8)
        vLbl:SetJustifyH("CENTER")
        vLbl:SetWordWrap(false)
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
            portCols[i]:SetSize(cw, 50)
        end
    end
    portBar:SetScript("OnSizeChanged", LayoutPortCols)
    LayoutPortCols()

    ----------------------------------------------------------------------------
    -- 2. PINNED & GROUPED SUB-TAB WORKSPACE (DRAG-AND-DROP)
    ----------------------------------------------------------------------------
    local pinnedPanel = NS.CreatePanel(frame, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, false)
    pinnedPanel:SetPoint("TOPLEFT", portBar, "BOTTOMLEFT", 0, -5)
    pinnedPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

    local scanBtn = NS.CreateButton(pinnedPanel, "Scan Pinned", 96, 21, true)
    scanBtn:SetPoint("TOPRIGHT", pinnedPanel, "TOPRIGHT", -10, -6)
    scanBtn:SetScript("OnClick", function()
        if NS.Scanner:IsScanning() then
            NS.Scanner:StopScan("USER_STOP")
        else
            NS.Scanner:StartDashboardScan(activeScanIDs)
        end
    end)
    frame._scanBtn = scanBtn

    local pinScroll = CreateFrame("ScrollFrame", "ForeverMarketWatchDashScroll", pinnedPanel, "UIPanelScrollFrameTemplate")
    pinScroll:SetPoint("TOPLEFT", pinnedPanel, "TOPLEFT", 10, -32)
    pinScroll:SetPoint("BOTTOMRIGHT", pinnedPanel, "BOTTOMRIGHT", -28, 8)

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
    ghostName:SetPoint("TOPLEFT", ghostIcon, "TOPRIGHT", 8, 0)
    ghostName:SetPoint("TOPRIGHT", dragGhost, "TOPRIGHT", -8, -8)
    ghostName:SetHeight(15)
    ghostName:SetJustifyH("LEFT")
    ghostName:SetWordWrap(false)

    local ghostSub = dragGhost:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ghostSub:SetPoint("BOTTOMLEFT", ghostIcon, "BOTTOMRIGHT", 8, 0)
    ghostSub:SetText("Drop on another card to reorder")

    frame._cards = {}
    frame._subTabBtns = {}
    frame._sectionHeaders = {}
    local draggingItemID = nil
    local draggingSourceCard = nil
    local hoveredTargetCard = nil

    local function SelectSubTab(tabID)
        activeSubTab = tabID or "ALL"
        if NS.DB and NS.DB.GetSettings then
            NS.DB:GetSettings().dashboardSubTab = activeSubTab
        end
        if pinScroll then
            pinScroll:SetVerticalScroll(0)
        end
        frame:Refresh()
    end

    local function GetOrCreateSubTabBtn(idx)
        if frame._subTabBtns[idx] then
            return frame._subTabBtns[idx]
        end
        local b = NS.CreateButton(pinnedPanel, "", 64, 21, false)
        frame._subTabBtns[idx] = b
        return b
    end

    local function GetOrCreateSectionHeader(idx)
        if frame._sectionHeaders[idx] then
            return frame._sectionHeaders[idx]
        end
        local hdr = CreateFrame("Button", nil, pinChild)
        hdr:SetHeight(22)

        local accent = hdr:CreateTexture(nil, "ARTWORK")
        accent:SetSize(3, 14)
        accent:SetPoint("LEFT", hdr, "LEFT", 2, 0)
        accent:SetColorTexture(NS.COLORS.BORDER_ACCENT[1], NS.COLORS.BORDER_ACCENT[2], NS.COLORS.BORDER_ACCENT[3], 0.95)

        local titleTxt = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        titleTxt:SetPoint("LEFT", accent, "RIGHT", 7, 0)
        titleTxt:SetJustifyH("LEFT")
        hdr.titleTxt = titleTxt

        local hintTxt = hdr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hintTxt:SetPoint("RIGHT", hdr, "RIGHT", -4, 0)
        hintTxt:SetJustifyH("RIGHT")
        hintTxt:SetText("Filter >")
        hdr.hintTxt = hintTxt

        local line = hdr:CreateTexture(nil, "BORDER")
        line:SetPoint("LEFT", titleTxt, "RIGHT", 10, 0)
        line:SetPoint("RIGHT", hintTxt, "LEFT", -10, 0)
        line:SetHeight(1)
        line:SetColorTexture(NS.COLORS.BORDER[1], NS.COLORS.BORDER[2], NS.COLORS.BORDER[3], 0.45)

        hdr:SetScript("OnEnter", function(s)
            s.titleTxt:SetTextColor(1, 1, 1, 1)
            s.hintTxt:SetTextColor(1, 0.82, 0, 1)
        end)
        hdr:SetScript("OnLeave", function(s)
            s.titleTxt:SetTextColor(1, 0.82, 0, 1)
            s.hintTxt:SetTextColor(0.65, 0.58, 0.48, 1)
        end)

        frame._sectionHeaders[idx] = hdr
        return hdr
    end

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
        nameTxt:SetPoint("TOPRIGHT", card, "TOPRIGHT", -24, -9)
        nameTxt:SetHeight(15)
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

    local function PopulateCard(card, itemID, entry, xOff, yOff, cardW, cardH)
        local hist = NS.DB:GetItemHistory(itemID)
        local sum = NS.Analytics.GetItemSummary(entry, hist, "1D")
        local dayCtx = NS.Analytics.GetDayContext(hist)

        card._itemID = itemID
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", pinChild, "TOPLEFT", xOff, -yOff)
        card:SetSize(cardW, cardH)

        card.icon:SetTexture(entry.icon or 134400)
        local qr, qg, qb = NS.Compat.GetQualityColor(entry.quality)
        card.nameTxt:SetTextColor(qr, qg, qb, 1)
        card.nameTxt:SetText(entry.name)
        card.priceTxt:SetText(sum.latestMin and NS.FormatMoney(sum.latestMin, true) or "--")

        if dayCtx and dayCtx.dayDeltaPct ~= nil then
            card.deltaTxt:SetText(NS.FormatSignedPct(dayCtx.dayDeltaPct, 1))
        else
            card.deltaTxt:SetText("|cFF998C780.0%|r")
        end

        if sum.investQty and sum.investQty > 0 then
            card.footTxt:SetText(string.format("Inv %d (%s)  %s",
                sum.investQty,
                (sum.investment and sum.investment.holder) or "Alt",
                sum.investUnrealizedPnL and NS.FormatSignedMoney(sum.investUnrealizedPnL, true) or "--"
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

    ----------------------------------------------------------------------------
    -- Full Refresh
    ----------------------------------------------------------------------------

    function frame:Refresh()
        -- 1. Account-Wide Portfolio Summary
        local port = NS.DB:GetPortfolioSummary()
        self._portValues.invested:SetText(NS.FormatMoney(port.totalInvested, true))
        self._portValues.netVal:SetText(NS.FormatMoney(port.estNetValue, true))

        local uPctStr = (port.totalInvested > 0) and (" (" .. NS.FormatSignedPct((port.unrealizedPnL / port.totalInvested) * 100, 1) .. ")") or ""
        self._portValues.unreal:SetText(NS.FormatSignedMoney(port.unrealizedPnL, true) .. uPctStr)
        self._portValues.realized:SetText(NS.FormatSignedMoney(port.realizedProfit, true))

        local apiTs = NS.DB:GetExternalSyncTimestamp()
        local apiTxt = (apiTs > 0) and ("|cFF38D972" .. NS.FormatRelativeTime(apiTs) .. "|r") or "Local"
        self._portValues.status:SetText(string.format("%d Active · %s", port.activePositions, apiTxt))

        -- 2. Partition Pinned Items by Profession Category + Unpinned Holdings
        local pinnedOnlyIDs = NS.DB:GetDashboardPinnedIDs(true)
        local unpinnedHoldings = NS.DB:GetUnpinnedHoldingIDs()

        -- If the player has 0 explicitly pinned items yet, group their active holdings into the main sub-tabs
        local primaryIDs = (#pinnedOnlyIDs > 0) and pinnedOnlyIDs or unpinnedHoldings
        local separateHoldings = (#pinnedOnlyIDs > 0) and unpinnedHoldings or {}

        local bucketsByCat = {}
        local catOrder = {}
        local displayMap = {}

        for i = 1, #primaryIDs do
            local itemID = primaryIDs[i]
            local entry = BuildItemDisplay(itemID)
            displayMap[itemID] = entry
            local watchEntry = NS.DB:GetWatchItem(itemID)
            local catID = (NS.Catalog and NS.Catalog.GetDashboardCategory)
                and NS.Catalog.GetDashboardCategory(itemID, watchEntry, entry.name)
                or (entry.group or "Other")

            if not bucketsByCat[catID] then
                local pill, title, rank = ResolveCategoryMeta(catID)
                bucketsByCat[catID] = {
                    id    = catID,
                    pill  = pill,
                    title = title,
                    rank  = rank,
                    items = {},
                }
                table.insert(catOrder, bucketsByCat[catID])
            end
            table.insert(bucketsByCat[catID].items, itemID)
        end

        table.sort(catOrder, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            return a.title:lower() < b.title:lower()
        end)

        -- Build dynamic sub-tab specs (only non-empty tabs so bar stays sleek & focused)
        local tabSpecs = {
            { id = "ALL", label = string.format("All (%d)", #primaryIDs) },
        }
        local validTabSet = { ["ALL"] = true }
        for i = 1, #catOrder do
            local b = catOrder[i]
            validTabSet[b.id] = true
            table.insert(tabSpecs, {
                id    = b.id,
                label = string.format("%s (%d)", b.pill, #b.items),
            })
        end
        if #separateHoldings > 0 then
            validTabSet["HOLDINGS"] = true
            table.insert(tabSpecs, {
                id    = "HOLDINGS",
                label = string.format("Holdings (%d)", #separateHoldings),
            })
        end

        local effectiveTab = validTabSet[activeSubTab] and activeSubTab or "ALL"

        -- 3. Layout Auto-Wrapping Sub-Tab Pill Bar (never clips Scan button!)
        local panelW = math.max(480, pinnedPanel:GetWidth() or 760)
        local row1MaxX = panelW - 114 -- Leave clean space on Row 1 for 'Scan' button on the right
        local fullRowMaxX = panelW - 12
        local curX = 10
        local curRow = 0
        local pillH = 21
        local pillGapX = 4
        local pillGapY = 3

        for i = 1, #tabSpecs do
            local spec = tabSpecs[i]
            local btn = GetOrCreateSubTabBtn(i)
            btn:SetTextLabel(spec.label)
            local fs = btn:GetFontString()
            local textW = (fs and fs.GetStringWidth and fs:GetStringWidth()) or (#spec.label * 6.5)
            local btnW = math.max(52, math.ceil(textW + 18))
            btn:SetSize(btnW, pillH)

            local limitX = (curRow == 0) and row1MaxX or fullRowMaxX
            if curX > 10 and (curX + btnW) > limitX then
                curRow = curRow + 1
                curX = 10
            end

            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", pinnedPanel, "TOPLEFT", curX, -(6 + curRow * (pillH + pillGapY)))
            btn:SetActiveState(spec.id == effectiveTab)
            btn:SetScript("OnClick", function()
                SelectSubTab(spec.id)
            end)
            btn:Show()

            curX = curX + btnW + pillGapX
        end

        for i = #tabSpecs + 1, #self._subTabBtns do
            self._subTabBtns[i]:Hide()
        end

        local scrollTopOffset = 6 + (curRow + 1) * pillH + curRow * pillGapY + 6
        pinScroll:ClearAllPoints()
        pinScroll:SetPoint("TOPLEFT", pinnedPanel, "TOPLEFT", 10, -scrollTopOffset)
        pinScroll:SetPoint("BOTTOMRIGHT", pinnedPanel, "BOTTOMRIGHT", -28, 8)

        -- 4. Determine Active Cards & Update Scan Button
        activeScanIDs = {}
        if effectiveTab == "ALL" then
            for i = 1, #catOrder do
                local items = catOrder[i].items
                for j = 1, #items do
                    table.insert(activeScanIDs, items[j])
                end
            end
        elseif effectiveTab == "HOLDINGS" then
            for i = 1, #separateHoldings do
                table.insert(activeScanIDs, separateHoldings[i])
            end
        elseif bucketsByCat[effectiveTab] then
            local items = bucketsByCat[effectiveTab].items
            for i = 1, #items do
                table.insert(activeScanIDs, items[i])
            end
        end

        local totalAnything = #primaryIDs + #separateHoldings
        pinEmpty:SetShown(totalAnything == 0)

        local ahOpen = NS.Scanner and NS.Scanner:IsAuctionHouseOpen()
        local scanning = NS.Scanner and NS.Scanner:IsScanning()
        local isDemo = NS.DB:IsDemoMode()
        if scanning then
            scanBtn:SetTextLabel("Stop")
            scanBtn:SetEnabledState(true)
        else
            local scanLbl = (effectiveTab == "ALL") and "Scan Pinned" or string.format("Scan (%d)", #activeScanIDs)
            scanBtn:SetTextLabel(scanLbl)
            scanBtn:SetEnabledState(ahOpen and not isDemo and #activeScanIDs > 0)
        end

        -- 5. Render Grouped Sections (on 'All') or Focused Category Grid (on Sub-Tabs)
        local viewW = math.max(360, pinScroll:GetWidth() or 720)
        pinChild:SetWidth(viewW)
        local cols = (viewW >= 620) and 3 or 2
        local gap = 8
        local cardW = math.floor((viewW - gap * (cols - 1)) / cols)
        local cardH = 116

        local cardPoolIdx = 0
        local hdrPoolIdx = 0
        local yCursor = 0

        if effectiveTab == "ALL" and #catOrder > 0 then
            local showSectionHeaders = (#catOrder > 1)
            for s = 1, #catOrder do
                local bucket = catOrder[s]
                if showSectionHeaders then
                    hdrPoolIdx = hdrPoolIdx + 1
                    local hdr = GetOrCreateSectionHeader(hdrPoolIdx)
                    hdr:ClearAllPoints()
                    hdr:SetPoint("TOPLEFT", pinChild, "TOPLEFT", 0, -yCursor)
                    hdr:SetPoint("TOPRIGHT", pinChild, "TOPRIGHT", 0, -yCursor)
                    hdr.titleTxt:SetText(string.format("%s |cFF998C78(%d)|r", bucket.title, #bucket.items))
                    hdr:SetScript("OnClick", function()
                        SelectSubTab(bucket.id)
                    end)
                    hdr:Show()
                    yCursor = yCursor + 24
                end

                local bItems = bucket.items
                for j = 1, #bItems do
                    local itemID = bItems[j]
                    local entry = displayMap[itemID] or BuildItemDisplay(itemID)
                    cardPoolIdx = cardPoolIdx + 1
                    local card = GetOrCreateCard(cardPoolIdx)
                    local r = math.floor((j - 1) / cols)
                    local c = (j - 1) % cols
                    PopulateCard(card, itemID, entry, c * (cardW + gap), yCursor + r * (cardH + gap), cardW, cardH)
                end

                local sectionRows = math.ceil(#bItems / cols)
                yCursor = yCursor + sectionRows * (cardH + gap) + 6
            end
        else
            for i = 1, #activeScanIDs do
                local itemID = activeScanIDs[i]
                local entry = displayMap[itemID] or BuildItemDisplay(itemID)
                cardPoolIdx = cardPoolIdx + 1
                local card = GetOrCreateCard(cardPoolIdx)
                local r = math.floor((i - 1) / cols)
                local c = (i - 1) % cols
                PopulateCard(card, itemID, entry, c * (cardW + gap), r * (cardH + gap), cardW, cardH)
            end
            local totalRows = math.ceil(#activeScanIDs / cols)
            yCursor = totalRows * (cardH + gap)
        end

        for i = hdrPoolIdx + 1, #self._sectionHeaders do
            self._sectionHeaders[i]:Hide()
        end
        for i = cardPoolIdx + 1, #self._cards do
            self._cards[i]._itemID = nil
            self._cards[i]:Hide()
        end

        pinChild:SetHeight(math.max(1, yCursor))
    end

    pinScroll:HookScript("OnSizeChanged", function()
        if frame:IsShown() then
            frame:Refresh()
        end
    end)

    return frame
end
