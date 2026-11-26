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

function InventoryUI.Create(parent, onOpenItem, onEditItem, onOpenCharGroups)
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
    kpiBar:SetHeight(50)

    local kpis = {
        { id = "cost",     title = "Cost Basis" },
        { id = "value",    title = "Est. Net Value" },
        { id = "unreal",   title = "Unrealized P&L" },
        { id = "realized", title = "Booked Profit" },
        { id = "counts",   title = "Positions" },
    }
    local kpiCols = {}
    frame._kpiValues = {}

    for i = 1, #kpis do
        local col = CreateFrame("Frame", nil, kpiBar)
        local tLbl = col:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tLbl:SetPoint("TOP", col, "TOP", 0, -7)
        tLbl:SetText(kpis[i].title)

        local vLbl = col:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        vLbl:SetPoint("BOTTOMLEFT", col, "BOTTOMLEFT", 4, 8)
        vLbl:SetPoint("BOTTOMRIGHT", col, "BOTTOMRIGHT", -4, 8)
        vLbl:SetJustifyH("CENTER")
        vLbl:SetWordWrap(false)
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
            kpiCols[i]:SetSize(cw, 50)
        end
    end
    kpiBar:SetScript("OnSizeChanged", LayoutKpis)
    LayoutKpis()

    ----------------------------------------------------------------------------
    -- 2. CONTROLS & FILTER BAR
    ----------------------------------------------------------------------------
    local ctrlBar = NS.CreatePanel(frame, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, false)
    ctrlBar:SetPoint("TOPLEFT", kpiBar, "BOTTOMLEFT", 0, -5)
    ctrlBar:SetPoint("TOPRIGHT", kpiBar, "BOTTOMRIGHT", 0, -5)
    ctrlBar:SetHeight(32)

    local filterBtns = {}
    local filterDefs = {
        { id = "IN_STOCK", label = "In Stock", w = 64 },
        { id = "SOLD_OUT", label = "Sold Out", w = 64 },
        { id = "ALL",      label = "All",      w = 36 },
        { id = "AUCTIONS", label = "Auctions", w = 82 },
    }
    local prevBtn = nil
    for i = 1, #filterDefs do
        local def = filterDefs[i]
        local b = NS.CreateButton(ctrlBar, def.label, def.w, 22, false)
        if not prevBtn then
            b:SetPoint("LEFT", ctrlBar, "LEFT", 6, 0)
        else
            b:SetPoint("LEFT", prevBtn, "RIGHT", 3, 0)
        end
        b:SetScript("OnClick", function()
            stockFilter = def.id
            frame:Refresh()
        end)
        filterBtns[def.id] = b
        prevBtn = b
    end

    local searchBox, searchEB = NS.CreateEditBox(ctrlBar, 108, 22, "Filter item...")
    searchBox:SetPoint("LEFT", prevBtn, "RIGHT", 6, 0)
    searchEB:HookScript("OnTextChanged", function(self)
        searchText = (self:GetText() or ""):lower():match("^%s*(.-)%s*$")
        frame:Refresh()
    end)
    searchEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local altsBtn = NS.CreateButton(ctrlBar, "Alts", 34, 22, false)
    altsBtn:SetPoint("RIGHT", ctrlBar, "RIGHT", -6, 0)
    altsBtn:SetScript("OnClick", function(self)
        if onOpenCharGroups then onOpenCharGroups(self) end
    end)

    local charDrop = NS.CreateDropdown(ctrlBar, 114, 22, function(val)
        if NS.UI and NS.UI.SetCharFilter then
            NS.UI.SetCharFilter(val)
        end
    end)
    charDrop:SetPoint("RIGHT", altsBtn, "LEFT", -3, 0)

    local checkUndercutBtn = NS.CreateButton(ctrlBar, "Undercuts", 76, 22, true)
    checkUndercutBtn:SetPoint("RIGHT", charDrop, "LEFT", -4, 0)
    checkUndercutBtn:SetScript("OnClick", function()
        stockFilter = "AUCTIONS"
        if NS.Scanner and NS.Scanner.ScanMyAuctions then
            NS.Scanner:ScanMyAuctions(true)
        end
        frame:Refresh()
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
        MakeSortHeader("Item / Alt",     "name",  "LEFT",  "LEFT",  "LEFT",   8,    160),
        MakeSortHeader("Qty",            "qty",   "RIGHT", "RIGHT", "RIGHT", -468,   46),
        MakeSortHeader("Avg Buy",        "cost",  "RIGHT", "RIGHT", "RIGHT", -374,   88),
        MakeSortHeader("Break-Even",     "be",    "RIGHT", "RIGHT", "RIGHT", -280,   88),
        MakeSortHeader("AH Price",       "mkt",   "RIGHT", "RIGHT", "RIGHT", -186,   88),
        MakeSortHeader("Unrealized P&L", "pnl",   "RIGHT", "RIGHT", "RIGHT", -82,    98),
    }

    local scroll = CreateFrame("ScrollFrame", "ForeverMarketWatchInvScroll", tablePanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", tablePanel, "BOTTOMRIGHT", -26, 6)

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

    local rows = {}

    local function GetOrCreateRow(idx)
        if rows[idx] then return rows[idx] end
        local r = CreateFrame("Button", nil, child)
        r:SetHeight(34)
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
        nameTxt:SetPoint("RIGHT", r, "RIGHT", -520, 0)
        nameTxt:SetJustifyH("LEFT")
        nameTxt:SetWordWrap(false)
        r.nameTxt = nameTxt

        local subTxt = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        subTxt:SetPoint("BOTTOMLEFT", iconBg, "BOTTOMRIGHT", 6, 1)
        subTxt:SetPoint("RIGHT", r, "RIGHT", -520, 0)
        subTxt:SetJustifyH("LEFT")
        subTxt:SetWordWrap(false)
        r.subTxt = subTxt

        local qtyTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        qtyTxt:SetPoint("TOPRIGHT", r, "TOPRIGHT", -468, -5)
        qtyTxt:SetWidth(48)
        qtyTxt:SetJustifyH("RIGHT")
        r.qtyTxt = qtyTxt

        local bagTxt = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        bagTxt:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -468, 5)
        bagTxt:SetWidth(58)
        bagTxt:SetJustifyH("RIGHT")
        r.bagTxt = bagTxt

        local costTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        costTxt:SetPoint("RIGHT", r, "RIGHT", -374, 0)
        costTxt:SetWidth(90)
        costTxt:SetJustifyH("RIGHT")
        r.costTxt = costTxt

        local beTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        beTxt:SetPoint("RIGHT", r, "RIGHT", -280, 0)
        beTxt:SetWidth(90)
        beTxt:SetJustifyH("RIGHT")
        r.beTxt = beTxt

        local mktTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        mktTxt:SetPoint("RIGHT", r, "RIGHT", -186, 0)
        mktTxt:SetWidth(90)
        mktTxt:SetJustifyH("RIGHT")
        r.mktTxt = mktTxt

        local pnlTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pnlTxt:SetPoint("TOPRIGHT", r, "TOPRIGHT", -82, -5)
        pnlTxt:SetWidth(98)
        pnlTxt:SetJustifyH("RIGHT")
        r.pnlTxt = pnlTxt

        local pnlPctTxt = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        pnlPctTxt:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -82, 5)
        pnlPctTxt:SetWidth(98)
        pnlPctTxt:SetJustifyH("RIGHT")
        r.pnlPctTxt = pnlPctTxt

        local actBtn = NS.CreateButton(r, "Post", 54, 22, false)
        actBtn:SetPoint("RIGHT", r, "RIGHT", -22, 0)
        r.actBtn = actBtn

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

        local charFilter = (NS.UI and NS.UI.GetCharFilter and NS.UI.GetCharFilter()) or "ALL"
        charDrop:SetOptions(NS.DB:GetCharacterFilterOptions())
        charDrop:SetSelected(charFilter, false)

        local ownedList, ownedMeta = NS.DB:GetOwnedAuctionsView(charFilter)
        if ownedMeta and ownedMeta.undercutCount > 0 then
            filterBtns.AUCTIONS:SetTextLabel(string.format("Auctions |cFFF55954(%d!)|r", ownedMeta.undercutCount))
        elseif ownedMeta and ownedMeta.totalAuctions > 0 then
            filterBtns.AUCTIONS:SetTextLabel(string.format("Auctions (%d)", ownedMeta.totalAuctions))
        else
            filterBtns.AUCTIONS:SetTextLabel("Auctions")
        end

        -- 2. Update Top KPI Banner
        local port = NS.DB:GetPortfolioSummary(charFilter)
        self._kpiValues.cost:SetText(NS.FormatMoney(port.totalInvested, true))
        self._kpiValues.value:SetText(NS.FormatMoney(port.estNetValue, true))

        local uPctStr = (port.totalInvested > 0) and (" (" .. NS.FormatSignedPct((port.unrealizedPnL / port.totalInvested) * 100, 1) .. ")") or ""
        self._kpiValues.unreal:SetText(NS.FormatSignedMoney(port.unrealizedPnL, true) .. uPctStr)
        self._kpiValues.realized:SetText(NS.FormatSignedMoney(port.realizedProfit, true))
        self._kpiValues.counts:SetText(string.format("|cFFFFD100%d|r items · |cFFFFD100%d|r units", port.activePositions or 0, port.totalUnits or 0))

        local ahOpen = NS.Scanner and NS.Scanner:IsAuctionHouseOpen()

        -- 3. Active Auctions & Undercut Check View
        if stockFilter == "AUCTIONS" then
            hdrBtns[3].txt:SetText("Your Price")
            hdrBtns[4].txt:SetText("Break-Even")
            hdrBtns[5].txt:SetText("AH Min")
            hdrBtns[6].txt:SetText("Status")

            local filtered = {}
            for i = 1, #ownedList do
                local a = ownedList[i]
                local ok = true
                if searchText ~= "" then
                    local nm = a.name and a.name:lower():find(searchText, 1, true)
                    local ch = a.character and a.character:lower():find(searchText, 1, true)
                    if not nm and not ch then ok = false end
                end
                if ok then table.insert(filtered, a) end
            end

            emptyTxt:SetShown(#filtered == 0)
            if #filtered == 0 then
                emptyTxt:SetText("No active auctions cached yet.\n\nClick 'Undercuts' at the Auction House to scan your listings.")
            end

            local rowH = 35
            local w = scroll:GetWidth()
            if w and w > 100 then child:SetWidth(w) end

            for i = 1, #filtered do
                local a = filtered[i]
                local row = GetOrCreateRow(i)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -((i - 1) * rowH))
                row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -((i - 1) * rowH))

                local bgC = ((i % 2) == 0) and NS.COLORS.BG_ROW_ALT or NS.COLORS.BG_ROW
                row.bg:SetColorTexture(bgC[1], bgC[2], bgC[3], bgC[4])

                row.icon:SetTexture(a.icon or 134400)
                local qr, qg, qb = NS.Compat.GetQualityColor(a.quality)
                row.nameTxt:SetTextColor(qr, qg, qb, 1)
                row.nameTxt:SetText(a.name)

                local subParts = { a.character or "Alt" }
                if a.belowBreakEven then
                    table.insert(subParts, "|cFFF55954BELOW BREAK-EVEN!|r")
                elseif a.avgCost and a.avgCost > 0 then
                    table.insert(subParts, "Cost: " .. NS.FormatMoney(a.avgCost, true))
                end
                row.subTxt:SetText(table.concat(subParts, "  |  "))

                row.qtyTxt:SetText("|cFFFFD100x" .. tostring(a.qty) .. "|r")
                row.bagTxt:SetText("")

                row.costTxt:SetText(NS.FormatMoney(a.unitPrice, true))
                row.beTxt:SetText(a.breakEven > 0 and ("|cFFFFCC33" .. NS.FormatMoney(a.breakEven, true) .. "|r") or "|cFF8A7E6B--|r")
                row.mktTxt:SetText(a.mktMin and NS.FormatMoney(a.mktMin, true) or "|cFF8A7E6B--|r")

                if a.status == "UNDERCUT" then
                    row.pnlTxt:SetText("|cFFF55954UNDERCUT|r")
                    row.pnlPctTxt:SetText("|cFFF55954-" .. NS.FormatMoney(a.undercutBy, true) .. "|r")
                elseif a.status == "LOWEST" then
                    row.pnlTxt:SetText("|cFF38D972LOWEST|r")
                    row.pnlPctTxt:SetText(a.belowBreakEven and "|cFFFFA030Hold|r" or "|cFF38D972Safe|r")
                else
                    row.pnlTxt:SetText("|cFF998C78No Scan|r")
                    row.pnlPctTxt:SetText("")
                end

                row.delBtn:Hide()
                if a.isCurrentChar and ahOpen and a.auctionID then
                    row.actBtn:SetTextLabel(a.status == "UNDERCUT" and "|cFFF55954Cancel|r" or "Cancel")
                    row.actBtn:SetScript("OnClick", function()
                        if NS.Scanner and NS.Scanner.CancelOwnedAuction then
                            NS.Scanner:CancelOwnedAuction(a.auctionID)
                        end
                    end)
                    row.actBtn:Show()
                else
                    row.actBtn:Hide()
                end

                row:SetScript("OnClick", function()
                    if a.itemID and a.itemID > 0 and onOpenItem then
                        onOpenItem(a.itemID)
                    end
                end)

                row:Show()
            end

            for i = #filtered + 1, #rows do
                rows[i]:Hide()
            end
            child:SetHeight(math.max(1, #filtered * rowH))
            return
        end

        -- 4. Update sort header indicators (Stock view)
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

        for itemID in pairs(investments) do
            local inv = NS.DB:GetInvestmentView(itemID, charFilter)
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

        local rowH = 35
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
                table.insert(subParts, "Booked " .. NS.FormatSignedMoney(d.realizedProfit, true))
            end
            row.subTxt:SetText(table.concat(subParts, "  ·  "))

            row.qtyTxt:SetText(d.qty > 0 and ("|cFFFFD100" .. tostring(d.qty) .. "|r") or "|cFF8A7E6B0|r")
            row.bagTxt:SetText(d.bagCount > 0 and ("Bags " .. tostring(d.bagCount)) or "")

            row.costTxt:SetText(d.avgCost > 0 and NS.FormatMoney(d.avgCost, true) or "--")
            row.beTxt:SetText(d.breakEven > 0 and ("|cFFFFCC33" .. NS.FormatMoney(d.breakEven, true) .. "|r") or "--")
            row.mktTxt:SetText(d.mktPrice and NS.FormatMoney(d.mktPrice, true) or "|cFF8A7E6B--|r")

            if d.qty > 0 and d.unrealPnL ~= nil then
                row.pnlTxt:SetText(NS.FormatSignedMoney(d.unrealPnL, true))
                row.pnlPctTxt:SetText(d.unrealPct and NS.FormatSignedPct(d.unrealPct, 1) or "")
            elseif d.qty <= 0 then
                row.pnlTxt:SetText(NS.FormatSignedMoney(d.realizedProfit, true))
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

            row.delBtn:Show()
            row.delBtn:SetScript("OnClick", function()
                NS.DB:ClearInvestment(d.itemID)
            end)

            if d.qty > 0 then
                row.actBtn:SetTextLabel("|cFF38D972Post|r")
                row.actBtn:SetScript("OnClick", function()
                    if NS.Scanner and NS.Scanner.JumpToSellItemInAH then
                        NS.Scanner:JumpToSellItemInAH(d.itemID, {
                            qty       = d.qty,
                            avgCost   = d.avgCost,
                            breakEven = d.breakEven,
                            mktPrice  = d.mktPrice,
                        })
                    end
                end)
                row.actBtn:Show()
            else
                row.actBtn:Hide()
            end

            row:Show()
        end

        for i = #list + 1, #rows do
            rows[i]:Hide()
        end
        child:SetHeight(math.max(1, #list * rowH))
    end

    return frame
end
