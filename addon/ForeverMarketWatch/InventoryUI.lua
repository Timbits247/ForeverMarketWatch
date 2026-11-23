-- InventoryUI.lua
-- Auto-Populated AH Inventory & Positions Tab (Classic WoW AH themed):
--   * Automatically populated from Auction House purchases & decremented on Mailbox sales.
--   * Preserves existing manual positions and supports right-click adjustment or removal.
--   * Full Gold/Silver/Copper Cost Basis, 5% AH Break-Even, Live AH Price, and Unrealized P&L.

local _, NS = ...

local InventoryUI = {}
NS.InventoryUI = InventoryUI

local function ResolveInventoryDisplay(itemID, inv)
    local watch = NS.DB:GetWatchItem(itemID)
    local hist  = NS.DB:GetItemHistory(itemID)
    local cat   = NS.Catalog and NS.Catalog.BY_ID and NS.Catalog.BY_ID[itemID] or nil
    local liveName, _, liveQual, _, _, _, _, _, _, liveIcon = NS.Compat.GetItemInfo(itemID)
    if not liveName then
        NS.Compat.RequestLoadItemDataByID(itemID)
    end

    local name = liveName or (watch and watch.name) or (inv and inv.name) or (hist and hist.name) or (cat and cat[2]) or ("Item #" .. tostring(itemID))
    local icon = liveIcon or (watch and watch.icon) or (inv and inv.icon) or (hist and hist.icon) or NS.Compat.GetItemIconByID(itemID) or 134400
    local quality = (liveQual ~= nil) and liveQual
        or (watch and watch.quality)
        or (inv and inv.quality)
        or (hist and hist.quality)
        or (cat and cat[4])
        or 1

    return name, icon, quality, hist
end

function InventoryUI.Create(parent, onOpenItem, onEditItem)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    frame:Hide()

    local stockFilter = "IN_STOCK" -- "IN_STOCK", "SOLD_OUT", "ALL"
    local sortCol = "value"        -- "name", "qty", "cost", "mkt", "pnl", "value"
    local sortAsc = false
    local searchText = ""

    ----------------------------------------------------------------------------
    -- 1. TOP KPI SUMMARY BANNER
    ----------------------------------------------------------------------------
    local kpiBar = NS.CreatePanel(frame, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER_ACCENT, false)
    kpiBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    kpiBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    kpiBar:SetHeight(56)

    local kpis = {
        { id = "cost",     title = "Inventory Cost Basis" },
        { id = "value",    title = "Est. Net Value (5% Cut)" },
        { id = "unreal",   title = "Unrealized P&L" },
        { id = "realized", title = "Booked Profit (All Time)" },
        { id = "counts",   title = "Open Positions / Units" },
    }
    local kpiCols = {}
    frame._kpiValues = {}

    for i = 1, #kpis do
        local col = CreateFrame("Frame", nil, kpiBar)
        local tLbl = col:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tLbl:SetPoint("TOP", col, "TOP", 0, -8)
        tLbl:SetText(kpis[i].title)

        local vLbl = col:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        vLbl:SetPoint("BOTTOM", col, "BOTTOM", 0, 10)
        vLbl:SetText("--")

        frame._kpiValues[kpis[i].id] = vLbl
        kpiCols[i] = col
    end

    local function LayoutKpis()
        local w = kpiBar:GetWidth() or 760
        local cw = math.max(90, (w - 12) / #kpiCols)
        for i = 1, #kpiCols do
            kpiCols[i]:ClearAllPoints()
            kpiCols[i]:SetPoint("TOPLEFT", kpiBar, "TOPLEFT", 6 + (i - 1) * cw, 0)
            kpiCols[i]:SetSize(cw, 56)
        end
    end
    kpiBar:SetScript("OnSizeChanged", LayoutKpis)
    LayoutKpis()

    ----------------------------------------------------------------------------
    -- 2. CONTROLS & FILTER BAR
    ----------------------------------------------------------------------------
    local ctrlBar = NS.CreatePanel(frame, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, false)
    ctrlBar:SetPoint("TOPLEFT", kpiBar, "BOTTOMLEFT", 0, -6)
    ctrlBar:SetPoint("TOPRIGHT", kpiBar, "BOTTOMRIGHT", 0, -6)
    ctrlBar:SetHeight(34)

    local filterBtns = {}
    local filterDefs = {
        { id = "IN_STOCK", label = "In Stock", w = 72 },
        { id = "SOLD_OUT", label = "Sold Out", w = 72 },
        { id = "ALL",      label = "All",      w = 46 },
    }
    local prevBtn = nil
    for i = 1, #filterDefs do
        local def = filterDefs[i]
        local b = NS.CreateButton(ctrlBar, def.label, def.w, 22, false)
        if not prevBtn then
            b:SetPoint("LEFT", ctrlBar, "LEFT", 8, 0)
        else
            b:SetPoint("LEFT", prevBtn, "RIGHT", 4, 0)
        end
        b:SetScript("OnClick", function()
            stockFilter = def.id
            frame:Refresh()
        end)
        filterBtns[def.id] = b
        prevBtn = b
    end

    local searchBox, searchEB = NS.CreateEditBox(ctrlBar, 178, 22, "Filter item or alt...")
    searchBox:SetPoint("LEFT", prevBtn, "RIGHT", 14, 0)
    searchEB:SetScript("OnTextChanged", function(self)
        searchText = (self:GetText() or ""):lower():match("^%s*(.-)%s*$")
        frame:Refresh()
    end)
    searchEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local autoTrackBtn = NS.CreateButton(ctrlBar, "Auto-Track: ON", 122, 22, false)
    autoTrackBtn:SetPoint("RIGHT", ctrlBar, "RIGHT", -8, 0)
    autoTrackBtn:SetScript("OnClick", function()
        local s = NS.DB:GetSettings()
        s.autoTrackLedger = not (s.autoTrackLedger ~= false)
        NS:FireCallback("DATA_UPDATED", nil, "SETTINGS_CHANGED")
    end)

    ----------------------------------------------------------------------------
    -- 3. INVENTORY TABLE PANEL
    ----------------------------------------------------------------------------
    local tablePanel = NS.CreatePanel(frame, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, false)
    tablePanel:SetPoint("TOPLEFT", ctrlBar, "BOTTOMLEFT", 0, -6)
    tablePanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

    local hdr = NS.CreatePanel(tablePanel, nil, NS.COLORS.BG_HEADER, NS.COLORS.BORDER, true)
    hdr:SetPoint("TOPLEFT", tablePanel, "TOPLEFT", 6, -6)
    hdr:SetPoint("TOPRIGHT", tablePanel, "TOPRIGHT", -26, -6)
    hdr:SetHeight(22)

    local function MakeSortHeader(label, colId, align, anchorPoint, relPoint, xOff, width)
        local b = CreateFrame("Button", nil, hdr)
        b:SetSize(width, 20)
        b:SetPoint(anchorPoint, hdr, relPoint, xOff, 0)
        local txt = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        txt:SetAllPoints()
        txt:SetJustifyH(align)
        txt:SetText(label)
        b.txt = txt
        b._baseLabel = label
        b._colId = colId
        b:SetScript("OnEnter", function(s) s.txt:SetTextColor(1, 0.92, 0.55, 1) end)
        b:SetScript("OnLeave", function(s) s.txt:SetTextColor(1, 0.82, 0, 1) end)
        b:SetScript("OnClick", function()
            if sortCol == colId then
                sortAsc = not sortAsc
            else
                sortCol = colId
                sortAsc = (colId == "name")
            end
            frame:Refresh()
        end)
        return b
    end

    local hdrBtns = {
        MakeSortHeader("Item / Alt",     "name",  "LEFT",  "LEFT",  "LEFT",   8,    180),
        MakeSortHeader("Qty",            "qty",   "RIGHT", "RIGHT", "RIGHT", -436,   52),
        MakeSortHeader("Avg Buy",        "cost",  "RIGHT", "RIGHT", "RIGHT", -334,   96),
        MakeSortHeader("Break-Even",     "be",    "RIGHT", "RIGHT", "RIGHT", -232,   96),
        MakeSortHeader("AH Price",       "mkt",   "RIGHT", "RIGHT", "RIGHT", -130,   96),
        MakeSortHeader("Unrealized P&L", "pnl",   "RIGHT", "RIGHT", "RIGHT", -24,   104),
    }

    local scroll = CreateFrame("ScrollFrame", "ForeverMarketWatchInvScroll", tablePanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", tablePanel, "BOTTOMRIGHT", -26, 24)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(720)
    child:SetHeight(1)
    scroll:SetScrollChild(child)

    scroll:SetScript("OnSizeChanged", function(self, w)
        if w and w > 100 then
            child:SetWidth(w)
        end
    end)

    local emptyTxt = tablePanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyTxt:SetPoint("CENTER", tablePanel, "CENTER", 0, 0)
    emptyTxt:SetJustifyH("CENTER")
    emptyTxt:SetTextColor(0.75, 0.68, 0.56, 1)
    emptyTxt:Hide()

    local footer = tablePanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", tablePanel, "BOTTOMLEFT", 10, 6)
    footer:SetPoint("BOTTOMRIGHT", tablePanel, "BOTTOMRIGHT", -10, 6)
    footer:SetJustifyH("LEFT")
    footer:SetText("Auto-populated from AH purchases & decremented on Mailbox sales  |  Left-click: Chart  |  Right-click: Edit  |  x: Remove")

    local rows = {}

    local function GetOrCreateRow(idx)
        if rows[idx] then return rows[idx] end
        local r = CreateFrame("Button", nil, child)
        r:SetHeight(37)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        local bg = r:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        r.bg = bg

        local hl = r:CreateTexture(nil, "ARTWORK")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0)
        r.hl = hl

        local iconBg = r:CreateTexture(nil, "BORDER")
        iconBg:SetSize(28, 28)
        iconBg:SetPoint("LEFT", r, "LEFT", 6, 0)
        iconBg:SetColorTexture(0.45, 0.36, 0.22, 0.9)

        local ic = r:CreateTexture(nil, "ARTWORK")
        ic:SetSize(26, 26)
        ic:SetPoint("CENTER", iconBg, "CENTER", 0, 0)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.icon = ic

        local nameTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameTxt:SetPoint("TOPLEFT", iconBg, "TOPRIGHT", 6, -1)
        nameTxt:SetPoint("RIGHT", r, "RIGHT", -494, 0)
        nameTxt:SetJustifyH("LEFT")
        nameTxt:SetWordWrap(false)
        r.nameTxt = nameTxt

        local subTxt = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        subTxt:SetPoint("BOTTOMLEFT", iconBg, "BOTTOMRIGHT", 6, 1)
        subTxt:SetPoint("RIGHT", r, "RIGHT", -494, 0)
        subTxt:SetJustifyH("LEFT")
        subTxt:SetWordWrap(false)
        r.subTxt = subTxt

        local qtyTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        qtyTxt:SetPoint("TOPRIGHT", r, "TOPRIGHT", -436, -5)
        qtyTxt:SetWidth(54)
        qtyTxt:SetJustifyH("RIGHT")
        r.qtyTxt = qtyTxt

        local bagTxt = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        bagTxt:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -436, 5)
        bagTxt:SetWidth(64)
        bagTxt:SetJustifyH("RIGHT")
        r.bagTxt = bagTxt

        local costTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        costTxt:SetPoint("RIGHT", r, "RIGHT", -334, 0)
        costTxt:SetWidth(98)
        costTxt:SetJustifyH("RIGHT")
        r.costTxt = costTxt

        local beTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        beTxt:SetPoint("RIGHT", r, "RIGHT", -232, 0)
        beTxt:SetWidth(98)
        beTxt:SetJustifyH("RIGHT")
        r.beTxt = beTxt

        local mktTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        mktTxt:SetPoint("RIGHT", r, "RIGHT", -130, 0)
        mktTxt:SetWidth(98)
        mktTxt:SetJustifyH("RIGHT")
        r.mktTxt = mktTxt

        local pnlTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pnlTxt:SetPoint("TOPRIGHT", r, "TOPRIGHT", -24, -5)
        pnlTxt:SetWidth(104)
        pnlTxt:SetJustifyH("RIGHT")
        r.pnlTxt = pnlTxt

        local pnlPctTxt = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        pnlPctTxt:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -24, 5)
        pnlPctTxt:SetWidth(104)
        pnlPctTxt:SetJustifyH("RIGHT")
        r.pnlPctTxt = pnlPctTxt

        local delBtn = CreateFrame("Button", nil, r)
        delBtn:SetSize(18, 18)
        delBtn:SetPoint("RIGHT", r, "RIGHT", -2, 0)
        local delTxt = delBtn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        delTxt:SetPoint("CENTER")
        delTxt:SetText("x")
        delBtn.txt = delTxt
        delBtn:SetScript("OnEnter", function(s) s.txt:SetTextColor(0.96, 0.35, 0.33, 1) end)
        delBtn:SetScript("OnLeave", function(s) s.txt:SetTextColor(0.65, 0.58, 0.48, 1) end)
        r.delBtn = delBtn

        r:SetScript("OnEnter", function(s) s.hl:SetAlpha(0.50) end)
        r:SetScript("OnLeave", function(s) s.hl:SetAlpha(0) end)

        rows[idx] = r
        return r
    end

    function frame:Refresh()
        -- 1. Update filter & toggle buttons
        for id, btn in pairs(filterBtns) do
            btn:SetActiveState(id == stockFilter)
        end
        local s = NS.DB:GetSettings()
        local trackingOn = (s.autoTrackLedger ~= false)
        autoTrackBtn:SetTextLabel("Auto-Track: " .. (trackingOn and "|cFF38D972ON|r" or "|cFFF55954OFF|r"))
        autoTrackBtn:SetActiveState(trackingOn)

        -- 2. Update Top KPI Banner
        local port = NS.DB:GetPortfolioSummary()
        self._kpiValues.cost:SetText(NS.FormatMoney(port.totalInvested, true))
        self._kpiValues.value:SetText(NS.FormatMoney(port.estNetValue, true))

        local uClr = (port.unrealizedPnL >= 0) and "|cFF38D972+" or "|cFFF55954"
        local uPct = (port.totalInvested > 0) and string.format(" (%.1f%%)", (port.unrealizedPnL / port.totalInvested) * 100) or ""
        self._kpiValues.unreal:SetText(uClr .. NS.FormatMoney(port.unrealizedPnL, true) .. uPct .. "|r")

        local rClr = (port.realizedProfit >= 0) and "|cFF38D972+" or "|cFFF55954"
        self._kpiValues.realized:SetText(rClr .. NS.FormatMoney(port.realizedProfit, true) .. "|r")
        self._kpiValues.counts:SetText(string.format("|cFFFFD100%d|r items  (|cFFFFD100%d|r units)", port.activePositions or 0, port.totalUnits or 0))

        -- 3. Update sort header indicators
        for i = 1, #hdrBtns do
            local hb = hdrBtns[i]
            if hb._colId == sortCol then
                hb.txt:SetText(hb._baseLabel .. (sortAsc and " ^" or " v"))
            else
                hb.txt:SetText(hb._baseLabel)
            end
        end

        -- 4. Build item rows
        local investments = NS.DB:GetAllInvestments()
        local cutRate = (NS.Analytics and NS.Analytics.GetAHCutRate()) or 0.05
        local list = {}

        for itemID, inv in pairs(investments) do
            if type(inv) == "table" then
                local qty = inv.qty or 0
                local include = true
                if stockFilter == "IN_STOCK" then
                    include = (qty > 0)
                elseif stockFilter == "SOLD_OUT" then
                    include = (qty <= 0)
                end

                local name, icon, quality, hist = ResolveInventoryDisplay(itemID, inv)
                if include and searchText ~= "" then
                    local nMatch = name and name:lower():find(searchText, 1, true)
                    local hMatch = inv.holder and inv.holder:lower():find(searchText, 1, true)
                    if not nMatch and not hMatch then
                        include = false
                    end
                end

                if include then
                    local latest = hist and NS.Analytics and NS.Analytics.GetLatestPoint(hist) or nil
                    local mktPrice = (latest and latest.min and latest.min > 0) and latest.min or nil
                    local avgCost = inv.avgCost or 0
                    local breakEven = (avgCost > 0) and math.ceil(avgCost / (1 - cutRate)) or 0
                    local totalCost = inv.totalCost or (qty * avgCost)
                    local netValue = (qty > 0 and mktPrice) and math.floor((qty * mktPrice) * (1 - cutRate) + 0.5) or totalCost
                    local unrealPnL = (qty > 0 and mktPrice) and (netValue - totalCost) or nil
                    local unrealPct = (unrealPnL and totalCost > 0) and ((unrealPnL / totalCost) * 100) or nil
                    local bagCount = NS.DB:CountItemOnCurrentCharacter(itemID)

                    table.insert(list, {
                        itemID         = itemID,
                        inv            = inv,
                        name           = name,
                        icon           = icon,
                        quality        = quality,
                        qty            = qty,
                        bagCount       = bagCount,
                        avgCost        = avgCost,
                        breakEven      = breakEven,
                        totalCost      = totalCost,
                        mktPrice       = mktPrice,
                        netValue       = netValue,
                        unrealPnL      = unrealPnL,
                        unrealPct      = unrealPct,
                        realizedProfit = inv.realizedProfit or 0,
                    })
                end
            end
        end

        table.sort(list, function(a, b)
            local av, bv
            if sortCol == "name" then
                av, bv = (a.name or ""):lower(), (b.name or ""):lower()
            elseif sortCol == "qty" then
                av, bv = a.qty, b.qty
            elseif sortCol == "cost" then
                av, bv = a.avgCost, b.avgCost
            elseif sortCol == "be" then
                av, bv = a.breakEven, b.breakEven
            elseif sortCol == "mkt" then
                av, bv = a.mktPrice or -1, b.mktPrice or -1
            elseif sortCol == "pnl" then
                av, bv = a.unrealPnL or a.realizedProfit or -999999999, b.unrealPnL or b.realizedProfit or -999999999
            else
                av, bv = a.totalCost, b.totalCost
            end
            if av ~= bv then
                if sortAsc then return av < bv else return av > bv end
            end
            return (a.name or ""):lower() < (b.name or ""):lower()
        end)

        emptyTxt:SetShown(#list == 0)
        if #list == 0 then
            if stockFilter == "SOLD_OUT" then
                emptyTxt:SetText("No sold-out positions yet.\n\nWhen your AH sales arrive in the mailbox and you collect them,\ncompleted flips will appear here with total booked profit.")
            else
                emptyTxt:SetText("Your AH Inventory is currently empty.\n\nBuy any item on the Auction House (Blizzard UI or Auctionator)\nand it will auto-populate here with exact cost basis & live P&L!")
            end
        end

        local rowH = 38
        local w = scroll:GetWidth()
        if w and w > 100 then child:SetWidth(w) end

        for i = 1, #list do
            local d = list[i]
            local row = GetOrCreateRow(i)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -((i - 1) * rowH))
            row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -((i - 1) * rowH))

            local bgC = ((i % 2) == 0) and NS.COLORS.BG_ROW_ALT or NS.COLORS.BG_ROW
            row.bg:SetColorTexture(bgC[1], bgC[2], bgC[3], bgC[4])

            row.icon:SetTexture(d.icon or 134400)
            local qr, qg, qb = NS.Compat.GetQualityColor(d.quality)
            row.nameTxt:SetTextColor(qr, qg, qb, 1)
            row.nameTxt:SetText(d.name)

            local holder = (d.inv and d.inv.holder and d.inv.holder ~= "") and d.inv.holder or "Alt"
            local subParts = { holder }
            if d.realizedProfit ~= 0 then
                local rpClr = (d.realizedProfit >= 0) and "|cFF38D972+" or "|cFFF55954"
                table.insert(subParts, "Booked: " .. rpClr .. NS.FormatMoney(d.realizedProfit, true) .. "|r")
            end
            row.subTxt:SetText(table.concat(subParts, "  |  "))

            row.qtyTxt:SetText(d.qty > 0 and ("|cFFFFD100" .. tostring(d.qty) .. "|r") or "|cFF8A7E6B0|r")
            row.bagTxt:SetText(d.bagCount > 0 and ("Bags: " .. tostring(d.bagCount)) or "")

            row.costTxt:SetText(d.avgCost > 0 and NS.FormatMoney(d.avgCost, true) or "--")
            row.beTxt:SetText(d.breakEven > 0 and ("|cFFFFCC33" .. NS.FormatMoney(d.breakEven, true) .. "|r") or "--")
            row.mktTxt:SetText(d.mktPrice and NS.FormatMoney(d.mktPrice, true) or "|cFF8A7E6B--|r")

            if d.qty > 0 and d.unrealPnL ~= nil then
                local clr = (d.unrealPnL >= 0) and "|cFF38D972+" or "|cFFF55954"
                row.pnlTxt:SetText(clr .. NS.FormatMoney(d.unrealPnL, true) .. "|r")
                row.pnlPctTxt:SetText(d.unrealPct and string.format("%s%+.1f%%|r", clr, d.unrealPct) or "")
            elseif d.qty <= 0 then
                local clr = (d.realizedProfit >= 0) and "|cFF38D972+" or "|cFFF55954"
                row.pnlTxt:SetText(clr .. NS.FormatMoney(d.realizedProfit, true) .. "|r")
                row.pnlPctTxt:SetText("|cFF998C78Booked|r")
            else
                row.pnlTxt:SetText("|cFF8A7E6B--|r")
                row.pnlPctTxt:SetText("")
            end

            row:SetScript("OnClick", function(selfRow, button)
                if button == "RightButton" then
                    if onEditItem then onEditItem(selfRow, d.itemID) end
                else
                    if onOpenItem then onOpenItem(d.itemID) end
                end
            end)

            row.delBtn:SetScript("OnClick", function()
                NS.DB:ClearInvestment(d.itemID)
            end)

            row:Show()
        end

        for i = #list + 1, #rows do
            rows[i]:Hide()
        end
        child:SetHeight(math.max(1, #list * rowH))
    end

    return frame
end
