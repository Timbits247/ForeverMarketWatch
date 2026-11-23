-- LedgerUI.lua
-- Auto-Populated Auction House Accounting Ledger Tab (Classic WoW AH themed):
--   * Logs every AH Buy (Blizzard AH, Auctionator, Quick Buy, Mailbox wins) and
--     every AH Sale collected from the Mailbox with exact AH fees and realized P&L.
--   * Filterable by Timeframe (Today / 7D / 30D / All), Type (All / Buys / Sales),
--     and Item / Alt search.

local _, NS = ...

local LedgerUI = {}
NS.LedgerUI = LedgerUI

local function FormatLedgerTimestamp(ts)
    if not ts or ts <= 0 then return "--" end
    if date then
        return date("%b %d %H:%M", ts)
    end
    return tostring(ts)
end

function LedgerUI.Create(parent, onOpenItem)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    frame:Hide()

    local selectedDays = nil     -- 1 (Today), 7, 30, nil (All Time)
    local selectedType = "ALL"   -- "ALL", "BUY", "SELL"
    local searchText = ""

    ----------------------------------------------------------------------------
    -- 1. TOP ACCOUNTING KPI SUMMARY BANNER
    ----------------------------------------------------------------------------
    local kpiBar = NS.CreatePanel(frame, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER_ACCENT, false)
    kpiBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    kpiBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    kpiBar:SetHeight(56)

    local kpis = {
        { id = "bought",   title = "Total Bought" },
        { id = "sold",     title = "Net Sales (After Cut)" },
        { id = "cashflow", title = "Net Cashflow" },
        { id = "profit",   title = "Realized Gain / Loss" },
        { id = "meta",     title = "Trades / AH Fees" },
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
    -- 2. TIMEFRAME, TYPE FILTER & SEARCH BAR
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

    local typeBtns = {}
    local typeDefs = {
        { id = "ALL",  label = "All",   w = 36 },
        { id = "BUY",  label = "Buys",  w = 46 },
        { id = "SELL", label = "Sales", w = 48 },
    }
    for i = 1, #typeDefs do
        local def = typeDefs[i]
        local b = NS.CreateButton(ctrlBar, def.label, def.w, 22, false)
        b:SetPoint("LEFT", prev, "RIGHT", (i == 1) and 12 or 3, 0)
        b:SetScript("OnClick", function()
            selectedType = def.id
            frame:Refresh()
        end)
        typeBtns[def.id] = b
        prev = b
    end

    local searchBox, searchEB = NS.CreateEditBox(ctrlBar, 148, 22, "Filter item / alt...")
    searchBox:SetPoint("LEFT", prev, "RIGHT", 12, 0)
    searchEB:SetScript("OnTextChanged", function(self)
        searchText = (self:GetText() or ""):lower():match("^%s*(.-)%s*$")
        frame:Refresh()
    end)
    searchEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local autoTrackBtn = NS.CreateButton(ctrlBar, "Auto-Track: ON", 116, 22, false)
    autoTrackBtn:SetPoint("RIGHT", ctrlBar, "RIGHT", -8, 0)
    autoTrackBtn:SetScript("OnClick", function()
        local s = NS.DB:GetSettings()
        s.autoTrackLedger = not (s.autoTrackLedger ~= false)
        NS:FireCallback("DATA_UPDATED", nil, "SETTINGS_CHANGED")
    end)

    local chatBtn = NS.CreateButton(ctrlBar, "Chat Log: ON", 96, 22, false)
    chatBtn:SetPoint("RIGHT", autoTrackBtn, "LEFT", -4, 0)
    chatBtn:SetScript("OnClick", function()
        local s = NS.DB:GetSettings()
        s.announceAutoLedger = not (s.announceAutoLedger ~= false)
        frame:Refresh()
    end)

    ----------------------------------------------------------------------------
    -- 3. LEDGER TRANSACTION TABLE
    ----------------------------------------------------------------------------
    local tablePanel = NS.CreatePanel(frame, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, false)
    tablePanel:SetPoint("TOPLEFT", ctrlBar, "BOTTOMLEFT", 0, -6)
    tablePanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

    local hdr = NS.CreatePanel(tablePanel, nil, NS.COLORS.BG_HEADER, NS.COLORS.BORDER, true)
    hdr:SetPoint("TOPLEFT", tablePanel, "TOPLEFT", 6, -6)
    hdr:SetPoint("TOPRIGHT", tablePanel, "TOPRIGHT", -26, -6)
    hdr:SetHeight(22)

    local function AddHdr(text, align, anchor, rel, xOff, w)
        local fs = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint(anchor, hdr, rel, xOff, 0)
        fs:SetWidth(w)
        fs:SetJustifyH(align)
        fs:SetText(text)
    end

    AddHdr("Time / Type",  "LEFT",  "LEFT",  "LEFT",   8,    82)
    AddHdr("Item",         "LEFT",  "LEFT",  "LEFT",   94,  160)
    AddHdr("Qty",          "RIGHT", "RIGHT", "RIGHT", -412,  42)
    AddHdr("Unit Price",   "RIGHT", "RIGHT", "RIGHT", -314,  92)
    AddHdr("Total / Net",  "RIGHT", "RIGHT", "RIGHT", -208, 100)
    AddHdr("Gain / Loss",  "RIGHT", "RIGHT", "RIGHT", -100, 104)
    AddHdr("Alt",          "RIGHT", "RIGHT", "RIGHT", -22,   74)

    local scroll = CreateFrame("ScrollFrame", "ForeverMarketWatchLedgerScroll", tablePanel, "UIPanelScrollFrameTemplate")
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
    footer:SetText("AH Buys log instantly on purchase; AH Sales & exact 5% fees log automatically when collected from your Mailbox.")

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

        local timeTxt = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        timeTxt:SetPoint("TOPLEFT", r, "TOPLEFT", 8, -5)
        timeTxt:SetWidth(82)
        timeTxt:SetJustifyH("LEFT")
        r.timeTxt = timeTxt

        local typeTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        typeTxt:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 8, 5)
        typeTxt:SetWidth(82)
        typeTxt:SetJustifyH("LEFT")
        r.typeTxt = typeTxt

        local ic = r:CreateTexture(nil, "ARTWORK")
        ic:SetSize(24, 24)
        ic:SetPoint("LEFT", r, "LEFT", 94, 0)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.icon = ic

        local nameTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameTxt:SetPoint("TOPLEFT", ic, "TOPRIGHT", 6, -1)
        nameTxt:SetPoint("RIGHT", r, "RIGHT", -460, 0)
        nameTxt:SetJustifyH("LEFT")
        nameTxt:SetWordWrap(false)
        r.nameTxt = nameTxt

        local partyTxt = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        partyTxt:SetPoint("BOTTOMLEFT", ic, "BOTTOMRIGHT", 6, 1)
        partyTxt:SetPoint("RIGHT", r, "RIGHT", -460, 0)
        partyTxt:SetJustifyH("LEFT")
        partyTxt:SetWordWrap(false)
        r.partyTxt = partyTxt

        local qtyTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        qtyTxt:SetPoint("RIGHT", r, "RIGHT", -412, 0)
        qtyTxt:SetWidth(44)
        qtyTxt:SetJustifyH("RIGHT")
        r.qtyTxt = qtyTxt

        local unitTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        unitTxt:SetPoint("RIGHT", r, "RIGHT", -314, 0)
        unitTxt:SetWidth(94)
        unitTxt:SetJustifyH("RIGHT")
        r.unitTxt = unitTxt

        local totalTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        totalTxt:SetPoint("TOPRIGHT", r, "TOPRIGHT", -208, -5)
        totalTxt:SetWidth(102)
        totalTxt:SetJustifyH("RIGHT")
        r.totalTxt = totalTxt

        local feeTxt = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        feeTxt:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -208, 5)
        feeTxt:SetWidth(102)
        feeTxt:SetJustifyH("RIGHT")
        r.feeTxt = feeTxt

        local gainTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        gainTxt:SetPoint("TOPRIGHT", r, "TOPRIGHT", -100, -5)
        gainTxt:SetWidth(104)
        gainTxt:SetJustifyH("RIGHT")
        r.gainTxt = gainTxt

        local roiTxt = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        roiTxt:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -100, 5)
        roiTxt:SetWidth(104)
        roiTxt:SetJustifyH("RIGHT")
        r.roiTxt = roiTxt

        local altTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        altTxt:SetPoint("TOPRIGHT", r, "TOPRIGHT", -22, -5)
        altTxt:SetWidth(74)
        altTxt:SetJustifyH("RIGHT")
        altTxt:SetWordWrap(false)
        r.altTxt = altTxt

        local srcTxt = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        srcTxt:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -22, 5)
        srcTxt:SetWidth(74)
        srcTxt:SetJustifyH("RIGHT")
        r.srcTxt = srcTxt

        local delBtn = CreateFrame("Button", nil, r)
        delBtn:SetSize(16, 16)
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
        -- 1. Highlight controls
        for _, info in pairs(tfBtns) do
            info.btn:SetActiveState(info.days == selectedDays)
        end
        for id, btn in pairs(typeBtns) do
            btn:SetActiveState(id == selectedType)
        end
        local s = NS.DB:GetSettings()
        local trackingOn = (s.autoTrackLedger ~= false)
        autoTrackBtn:SetTextLabel("Auto-Track: " .. (trackingOn and "|cFF38D972ON|r" or "|cFFF55954OFF|r"))
        autoTrackBtn:SetActiveState(trackingOn)

        local chatOn = (s.announceAutoLedger ~= false)
        chatBtn:SetTextLabel("Chat Log: " .. (chatOn and "|cFF38D972ON|r" or "|cFFF55954OFF|r"))
        chatBtn:SetActiveState(chatOn)

        -- 2. Update Top Accounting KPI Banner for selected timeframe
        local sum = NS.DB:GetLedgerSummary(selectedDays)
        self._kpiValues.bought:SetText("|cFF42A8FA" .. NS.FormatMoney(sum.totalBought, true) .. "|r")
        self._kpiValues.sold:SetText("|cFF38D972" .. NS.FormatMoney(sum.totalSoldNet, true) .. "|r")

        local cfClr = (sum.netCashflow >= 0) and "|cFF38D972+" or "|cFFF55954"
        self._kpiValues.cashflow:SetText(cfClr .. NS.FormatMoney(sum.netCashflow, true) .. "|r")

        local pClr = (sum.realizedProfit >= 0) and "|cFF38D972+" or "|cFFF55954"
        local pRoi = sum.realizedRoiPct and string.format(" (%.1f%%)", sum.realizedRoiPct) or ""
        self._kpiValues.profit:SetText(pClr .. NS.FormatMoney(sum.realizedProfit, true) .. pRoi .. "|r")

        self._kpiValues.meta:SetText(string.format("%dB / %dS  |  Cut: %s", sum.buyCount, sum.sellCount, NS.FormatMoney(sum.totalFees, true)))

        -- 3. Fetch & render filtered transactions
        local entries = NS.DB:GetLedgerEntries({
            days       = selectedDays,
            typeFilter = selectedType,
            search     = searchText,
        })

        emptyTxt:SetShown(#entries == 0)
        if #entries == 0 then
            emptyTxt:SetText("No Auction House transactions recorded in this period yet.\n\nBuy items on the AH or collect AH sale gold from your Mailbox\nand every trade, fee, and profit/loss will appear here automatically!")
        end

        local visible = math.min(#entries, 300)
        local rowH = 38
        local w = scroll:GetWidth()
        if w and w > 100 then child:SetWidth(w) end

        for i = 1, visible do
            local e = entries[i]
            local row = GetOrCreateRow(i)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -((i - 1) * rowH))
            row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -((i - 1) * rowH))

            local bgC = ((i % 2) == 0) and NS.COLORS.BG_ROW_ALT or NS.COLORS.BG_ROW
            row.bg:SetColorTexture(bgC[1], bgC[2], bgC[3], bgC[4])

            local isBuy = (e.type == "BUY")
            if isBuy then
                row.bar:SetColorTexture(NS.COLORS.BLUE[1], NS.COLORS.BLUE[2], NS.COLORS.BLUE[3], 1)
                row.typeTxt:SetText("|cFF42A8FABUY|r")
            else
                row.bar:SetColorTexture(NS.COLORS.GREEN[1], NS.COLORS.GREEN[2], NS.COLORS.GREEN[3], 1)
                row.typeTxt:SetText("|cFF38D972SELL|r")
            end

            row.timeTxt:SetText(FormatLedgerTimestamp(e.ts))
            row.icon:SetTexture(e.icon or (e.itemID and NS.Compat.GetItemIconByID(e.itemID)) or 134400)
            local qr, qg, qb = NS.Compat.GetQualityColor(e.quality)
            row.nameTxt:SetTextColor(qr, qg, qb, 1)
            row.nameTxt:SetText(e.name or (e.itemID and ("Item #" .. tostring(e.itemID)) or "Unknown Item"))

            if e.counterparty and e.counterparty ~= "" then
                row.partyTxt:SetText((isBuy and "From: " or "Buyer: ") .. e.counterparty)
            else
                row.partyTxt:SetText(isBuy and "Auction House Purchase" or "Auction House Sale")
            end

            row.qtyTxt:SetText("x" .. tostring(e.qty or 1))
            row.unitTxt:SetText(NS.FormatMoney(e.unitPrice or 0, true))

            if isBuy then
                row.totalTxt:SetText("|cFF42A8FA-" .. NS.FormatMoney(e.netTotal or e.gross or 0, true) .. "|r")
                row.feeTxt:SetText("Spent")
                row.gainTxt:SetText("|cFF8A7E6B--|r")
                row.roiTxt:SetText("")
            else
                row.totalTxt:SetText("|cFF38D972+" .. NS.FormatMoney(e.netTotal or 0, true) .. "|r")
                row.feeTxt:SetText((e.ahCut and e.ahCut > 0) and ("Cut: " .. NS.FormatMoney(e.ahCut, true)) or "Net")
                if e.profit ~= nil then
                    local gClr = (e.profit >= 0) and "|cFF38D972+" or "|cFFF55954"
                    row.gainTxt:SetText(gClr .. NS.FormatMoney(e.profit, true) .. "|r")
                    local roiStr = e.roiPct and string.format("%s%+.1f%%|r", gClr, e.roiPct) or ""
                    if e.matched == "PARTIAL" then
                        roiStr = roiStr .. " |cFFFFCC33(part)|r"
                    end
                    row.roiTxt:SetText(roiStr)
                else
                    row.gainTxt:SetText("|cFF998C78No Cost|r")
                    row.roiTxt:SetText("Untracked")
                end
            end

            row.altTxt:SetText(e.character or "Alt")
            row.srcTxt:SetText(e.source or "AH")

            row:SetScript("OnClick", function()
                if e.itemID and e.itemID > 0 and onOpenItem then
                    onOpenItem(e.itemID)
                end
            end)

            row.delBtn:SetScript("OnClick", function()
                NS.DB:DeleteLedgerEntry(e.id)
            end)

            row:Show()
        end

        for i = visible + 1, #rows do
            rows[i]:Hide()
        end
        child:SetHeight(math.max(1, visible * rowH))
    end

    return frame
end
