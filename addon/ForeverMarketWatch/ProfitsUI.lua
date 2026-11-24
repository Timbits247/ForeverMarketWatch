-- ProfitsUI.lua
-- Per-Item Profit & Loss Summary Tab (Classic WoW AH themed):
--   * Rolls up dozens of individual Ledger BUY/SELL rows into ONE clean row per item
--     so you can immediately tell which items are making or losing you gold overall.
--   * Shows Total Bought (qty + avg), Total Net Sold (qty + avg), Remaining On Hand
--     (qty + live est. net value), Realized P&L, and Total P&L (Incl. Open Stock).

local _, NS = ...

local ProfitsUI = {}
NS.ProfitsUI = ProfitsUI

function ProfitsUI.Create(parent, onOpenItem, onOpenCharGroups)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    frame:Hide()

    local selectedDays = nil        -- 1 (Today), 7, 30, nil (All Time)
    local outcomeFilter = "ALL"     -- "ALL", "WINNERS", "LOSERS"
    local sortCol = "totalPnL"      -- "name", "bought", "sold", "onHand", "realized", "totalPnL"
    local sortAsc = false
    local searchText = ""

    ----------------------------------------------------------------------------
    -- 1. TOP PER-ITEM PERFORMANCE KPI BANNER
    ----------------------------------------------------------------------------
    local kpiBar = NS.CreatePanel(frame, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER_ACCENT, false)
    kpiBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    kpiBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    kpiBar:SetHeight(56)

    local kpis = {
        { id = "winloss",  title = "Winners / Losers" },
        { id = "best",     title = "Top Money-Maker" },
        { id = "worst",    title = "Biggest Loser" },
        { id = "realized", title = "Realized P&L" },
        { id = "total",    title = "Total P&L (Incl. Stock)" },
    }
    local kpiCols = {}
    frame._kpiValues = {}

    for i = 1, #kpis do
        local col = CreateFrame("Frame", nil, kpiBar)
        local tLbl = col:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tLbl:SetPoint("TOP", col, "TOP", 0, -8)
        tLbl:SetText(kpis[i].title)

        local vLbl = col:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        vLbl:SetPoint("BOTTOMLEFT", col, "BOTTOMLEFT", 4, 10)
        vLbl:SetPoint("BOTTOMRIGHT", col, "BOTTOMRIGHT", -4, 10)
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
            kpiCols[i]:SetSize(cw, 56)
        end
    end
    kpiBar:SetScript("OnSizeChanged", LayoutKpis)
    LayoutKpis()

    ----------------------------------------------------------------------------
    -- 2. TIMEFRAME, OUTCOME FILTER & SEARCH BAR
    ----------------------------------------------------------------------------
    local ctrlBar = NS.CreatePanel(frame, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, false)
    ctrlBar:SetPoint("TOPLEFT", kpiBar, "BOTTOMLEFT", 0, -6)
    ctrlBar:SetPoint("TOPRIGHT", kpiBar, "BOTTOMRIGHT", 0, -6)
    ctrlBar:SetHeight(34)

    local tfBtns = {}
    local tfDefs = {
        { key = "TODAY", days = 1,   label = "Today", w = 52 },
        { key = "7D",    days = 7,   label = "7D",    w = 34 },
        { key = "30D",   days = 30,  label = "30D",   w = 38 },
        { key = "ALL",   days = nil, label = "All",   w = 36 },
    }
    local prev = nil
    for i = 1, #tfDefs do
        local def = tfDefs[i]
        local b = NS.CreateButton(ctrlBar, def.label, def.w, 22, false)
        if not prev then
            b:SetPoint("LEFT", ctrlBar, "LEFT", 8, 0)
        else
            b:SetPoint("LEFT", prev, "RIGHT", 3, 0)
        end
        b:SetScript("OnClick", function()
            selectedDays = def.days
            frame:Refresh()
        end)
        tfBtns[def.key] = { btn = b, days = def.days }
        prev = b
    end

    local outBtns = {}
    local outDefs = {
        { id = "ALL",     label = "All Items", w = 68 },
        { id = "WINNERS", label = "Winners",   w = 62 },
        { id = "LOSERS",  label = "Losers",    w = 56 },
    }
    for i = 1, #outDefs do
        local def = outDefs[i]
        local b = NS.CreateButton(ctrlBar, def.label, def.w, 22, false)
        b:SetPoint("LEFT", prev, "RIGHT", (i == 1) and 12 or 3, 0)
        b:SetScript("OnClick", function()
            outcomeFilter = def.id
            frame:Refresh()
        end)
        outBtns[def.id] = b
        prev = b
    end

    local searchBox, searchEB = NS.CreateEditBox(ctrlBar, 128, 22, "Filter item...")
    searchBox:SetPoint("LEFT", prev, "RIGHT", 10, 0)
    searchEB:SetScript("OnTextChanged", function(self)
        searchText = (self:GetText() or ""):lower():match("^%s*(.-)%s*$")
        frame:Refresh()
    end)
    searchEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local altsBtn = NS.CreateButton(ctrlBar, "Alts", 40, 22, false)
    altsBtn:SetPoint("RIGHT", ctrlBar, "RIGHT", -8, 0)
    altsBtn:SetScript("OnClick", function(self)
        if onOpenCharGroups then onOpenCharGroups(self) end
    end)

    local charDrop = NS.CreateDropdown(ctrlBar, 128, 22, function(val)
        if NS.UI and NS.UI.SetCharFilter then
            NS.UI.SetCharFilter(val)
        end
    end)
    charDrop:SetPoint("RIGHT", altsBtn, "LEFT", -4, 0)

    ----------------------------------------------------------------------------
    -- 3. PER-ITEM PROFIT ROLLUP TABLE
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
        MakeSortHeader("Item / Trades", "name",     "LEFT",  "LEFT",  "LEFT",    8, 170),
        MakeSortHeader("Bought",        "bought",   "RIGHT", "RIGHT", "RIGHT", -392, 92),
        MakeSortHeader("Sold (Net)",    "sold",     "RIGHT", "RIGHT", "RIGHT", -294, 92),
        MakeSortHeader("On Hand",       "onHand",   "RIGHT", "RIGHT", "RIGHT", -204, 84),
        MakeSortHeader("Realized P&L",  "realized", "RIGHT", "RIGHT", "RIGHT", -106, 94),
        MakeSortHeader("Total P&L",     "totalPnL", "RIGHT", "RIGHT", "RIGHT",   -8, 94),
    }

    local scroll = CreateFrame("ScrollFrame", "ForeverMarketWatchProfitsScroll", tablePanel, "UIPanelScrollFrameTemplate")
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
    footer:SetText("Total P&L = Locked-in Realized P&L + Unrealized P&L on remaining stock (after 5% AH cut)  |  Click any item to open its chart")

    local rows = {}

    local function GetOrCreateRow(idx)
        if rows[idx] then return rows[idx] end
        local r = CreateFrame("Button", nil, child)
        r:SetHeight(37)

        local bg = r:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        r.bg = bg

        local hl = r:CreateTexture(nil, "ARTWORK")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0)
        r.hl = hl

        local bar = r:CreateTexture(nil, "OVERLAY")
        bar:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
        bar:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
        bar:SetWidth(3)
        r.bar = bar

        local iconBg = r:CreateTexture(nil, "BORDER")
        iconBg:SetSize(28, 28)
        iconBg:SetPoint("LEFT", r, "LEFT", 7, 0)
        iconBg:SetColorTexture(0.45, 0.36, 0.22, 0.9)

        local ic = r:CreateTexture(nil, "ARTWORK")
        ic:SetSize(26, 26)
        ic:SetPoint("CENTER", iconBg, "CENTER", 0, 0)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.icon = ic

        local nameTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameTxt:SetPoint("TOPLEFT", iconBg, "TOPRIGHT", 6, -1)
        nameTxt:SetPoint("RIGHT", r, "RIGHT", -488, 0)
        nameTxt:SetJustifyH("LEFT")
        nameTxt:SetWordWrap(false)
        r.nameTxt = nameTxt

        local subTxt = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        subTxt:SetPoint("BOTTOMLEFT", iconBg, "BOTTOMRIGHT", 6, 1)
        subTxt:SetPoint("RIGHT", r, "RIGHT", -488, 0)
        subTxt:SetJustifyH("LEFT")
        subTxt:SetWordWrap(false)
        r.subTxt = subTxt

        local buyTop = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        buyTop:SetPoint("TOPRIGHT", r, "TOPRIGHT", -392, -5)
        buyTop:SetWidth(94)
        buyTop:SetJustifyH("RIGHT")
        r.buyTop = buyTop

        local buyBot = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        buyBot:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -392, 5)
        buyBot:SetWidth(94)
        buyBot:SetJustifyH("RIGHT")
        r.buyBot = buyBot

        local sellTop = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        sellTop:SetPoint("TOPRIGHT", r, "TOPRIGHT", -294, -5)
        sellTop:SetWidth(94)
        sellTop:SetJustifyH("RIGHT")
        r.sellTop = sellTop

        local sellBot = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        sellBot:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -294, 5)
        sellBot:SetWidth(94)
        sellBot:SetJustifyH("RIGHT")
        r.sellBot = sellBot

        local holdTop = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        holdTop:SetPoint("TOPRIGHT", r, "TOPRIGHT", -204, -5)
        holdTop:SetWidth(84)
        holdTop:SetJustifyH("RIGHT")
        r.holdTop = holdTop

        local holdBot = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        holdBot:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -204, 5)
        holdBot:SetWidth(84)
        holdBot:SetJustifyH("RIGHT")
        r.holdBot = holdBot

        local realTop = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        realTop:SetPoint("TOPRIGHT", r, "TOPRIGHT", -106, -5)
        realTop:SetWidth(94)
        realTop:SetJustifyH("RIGHT")
        r.realTop = realTop

        local realBot = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        realBot:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -106, 5)
        realBot:SetWidth(94)
        realBot:SetJustifyH("RIGHT")
        r.realBot = realBot

        local totTop = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        totTop:SetPoint("TOPRIGHT", r, "TOPRIGHT", -8, -5)
        totTop:SetWidth(94)
        totTop:SetJustifyH("RIGHT")
        r.totTop = totTop

        local totBot = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        totBot:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -8, 5)
        totBot:SetWidth(94)
        totBot:SetJustifyH("RIGHT")
        r.totBot = totBot

        r:SetScript("OnEnter", function(s) s.hl:SetAlpha(0.50) end)
        r:SetScript("OnLeave", function(s) s.hl:SetAlpha(0) end)

        rows[idx] = r
        return r
    end

    function frame:Refresh()
        -- 1. Update filter & timeframe controls
        for _, info in pairs(tfBtns) do
            info.btn:SetActiveState(info.days == selectedDays)
        end
        for id, btn in pairs(outBtns) do
            btn:SetActiveState(id == outcomeFilter)
        end
        for i = 1, #hdrBtns do
            local hb = hdrBtns[i]
            if hb._colId == sortCol then
                hb.txt:SetText(hb._baseLabel .. (sortAsc and " ^" or " v"))
            else
                hb.txt:SetText(hb._baseLabel)
            end
        end

        -- 2. Compute per-item rollups (filtered by active character or character group)
        local charFilter = (NS.UI and NS.UI.GetCharFilter and NS.UI.GetCharFilter()) or "ALL"
        charDrop:SetOptions(NS.DB:GetCharacterFilterOptions())
        charDrop:SetSelected(charFilter, false)

        local allItems, totals = NS.DB:GetItemProfitSummaries({
            days       = selectedDays,
            charFilter = charFilter,
            search     = searchText,
        })

        -- Update Top KPI Banner
        self._kpiValues.winloss:SetText(string.format("|cFF38D972%d Win|r  /  |cFFF55954%d Loss|r", totals.winners, totals.losers))

        if totals.bestItem and totals.bestItem.totalPnL > 0 then
            self._kpiValues.best:SetText(string.format("%s (|cFF38D972+%s|r)", totals.bestItem.name, NS.FormatMoney(totals.bestItem.totalPnL, true)))
        else
            self._kpiValues.best:SetText("|cFF998C78--|r")
        end

        if totals.worstItem and totals.worstItem.totalPnL < 0 then
            self._kpiValues.worst:SetText(string.format("%s (|cFFF55954%s|r)", totals.worstItem.name, NS.FormatMoney(totals.worstItem.totalPnL, true)))
        else
            self._kpiValues.worst:SetText("|cFF38D972None|r")
        end

        local rClr = (totals.realizedPnL >= 0) and "|cFF38D972+" or "|cFFF55954"
        self._kpiValues.realized:SetText(rClr .. NS.FormatMoney(totals.realizedPnL, true) .. "|r")

        local tClr = (totals.totalPnL >= 0) and "|cFF38D972+" or "|cFFF55954"
        self._kpiValues.total:SetText(tClr .. NS.FormatMoney(totals.totalPnL, true) .. "|r")

        -- 3. Filter Winners / Losers and sort
        local list = {}
        for i = 1, #allItems do
            local item = allItems[i]
            local include = true
            if outcomeFilter == "WINNERS" then
                include = (item.totalPnL > 0)
            elseif outcomeFilter == "LOSERS" then
                include = (item.totalPnL < 0)
            end
            if include then
                table.insert(list, item)
            end
        end

        table.sort(list, function(a, b)
            local av, bv
            if sortCol == "name" then
                av, bv = (a.name or ""):lower(), (b.name or ""):lower()
            elseif sortCol == "bought" then
                av, bv = a.buyTotal, b.buyTotal
            elseif sortCol == "sold" then
                av, bv = a.sellNet, b.sellNet
            elseif sortCol == "onHand" then
                av, bv = a.onHandNetVal, b.onHandNetVal
            elseif sortCol == "realized" then
                av, bv = a.realizedPnL, b.realizedPnL
            else
                av, bv = a.totalPnL, b.totalPnL
            end
            if av ~= bv then
                if sortAsc then return av < bv else return av > bv end
            end
            return (a.name or ""):lower() < (b.name or ""):lower()
        end)

        emptyTxt:SetShown(#list == 0)
        if #list == 0 then
            if outcomeFilter == "LOSERS" then
                emptyTxt:SetText("No losing items in this period — nice flipping!")
            elseif outcomeFilter == "WINNERS" then
                emptyTxt:SetText("No profitable items recorded in this period yet.")
            else
                emptyTxt:SetText("No item profit/loss data in this period yet.\n\nBuy and sell items on the AH — every item's trades will automatically\nroll up here into one clean profit/loss summary row!")
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

            if d.totalPnL > 0 then
                row.bar:SetColorTexture(NS.COLORS.GREEN[1], NS.COLORS.GREEN[2], NS.COLORS.GREEN[3], 1)
            elseif d.totalPnL < 0 then
                row.bar:SetColorTexture(NS.COLORS.RED[1], NS.COLORS.RED[2], NS.COLORS.RED[3], 1)
            else
                row.bar:SetColorTexture(0.55, 0.50, 0.42, 0.5)
            end

            row.icon:SetTexture(d.icon or 134400)
            local qr, qg, qb = NS.Compat.GetQualityColor(d.quality)
            row.nameTxt:SetTextColor(qr, qg, qb, 1)
            row.nameTxt:SetText(d.name or "Unknown Item")

            if d.buyCount > 0 or d.sellCount > 0 then
                row.subTxt:SetText(string.format("%dB / %dS", d.buyCount, d.sellCount))
            else
                row.subTxt:SetText("Open Inventory")
            end

            if d.buyQty > 0 then
                row.buyTop:SetText("|cFF42A8FA" .. NS.FormatMoney(d.buyTotal, true) .. "|r")
                row.buyBot:SetText(string.format("x%d @ %s", d.buyQty, NS.FormatMoney(d.avgBuy, true)))
            else
                row.buyTop:SetText("|cFF8A7E6B--|r")
                row.buyBot:SetText("")
            end

            if d.sellQty > 0 then
                row.sellTop:SetText("|cFF38D972" .. NS.FormatMoney(d.sellNet, true) .. "|r")
                row.sellBot:SetText(string.format("x%d @ %s", d.sellQty, NS.FormatMoney(d.avgSell, true)))
            else
                row.sellTop:SetText("|cFF8A7E6B--|r")
                row.sellBot:SetText("")
            end

            if d.onHandQty > 0 then
                row.holdTop:SetText("|cFFFFD100x" .. tostring(d.onHandQty) .. "|r")
                row.holdBot:SetText(NS.FormatMoney(d.onHandNetVal, true))
            else
                row.holdTop:SetText("|cFF8A7E6B0|r")
                row.holdBot:SetText("")
            end

            if d.sellCount > 0 or d.matchedSellCount > 0 then
                local rc = (d.realizedPnL >= 0) and "|cFF38D972+" or "|cFFF55954"
                row.realTop:SetText(rc .. NS.FormatMoney(d.realizedPnL, true) .. "|r")
                if d.isFarmedOnly then
                    row.realBot:SetText("Farmed/Craft")
                elseif d.realizedRoiPct then
                    row.realBot:SetText(string.format("%s%+.1f%%|r", rc, d.realizedRoiPct))
                else
                    row.realBot:SetText("")
                end
            else
                row.realTop:SetText("|cFF8A7E6B--|r")
                row.realBot:SetText("")
            end

            local tc = (d.totalPnL >= 0) and "|cFF38D972+" or "|cFFF55954"
            row.totTop:SetText(tc .. NS.FormatMoney(d.totalPnL, true) .. "|r")
            if d.isFarmedOnly then
                row.totBot:SetText("Net Sale")
            elseif d.totalRoiPct then
                row.totBot:SetText(string.format("%s%+.1f%%|r", tc, d.totalRoiPct))
            else
                row.totBot:SetText("")
            end

            row:SetScript("OnClick", function()
                if d.itemID and d.itemID > 0 and onOpenItem then
                    onOpenItem(d.itemID)
                end
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
