-- WatchlistUI.lua
-- Classic WoW Auction House styled two-pane Watchlist & Stock Chart workspace.
-- Includes live + offline Item Search-to-Add popup, Profession Groups,
-- full Gold/Silver/Copper coin-icon prices, and zero WoW GameTooltip hooks.

local _, NS = ...

local UI = {}
NS.UI = UI

local mainView = nil
local selectedItemID = nil
local selectedPage = "MARKET" -- "DASHBOARD" or "MARKET"
local selectedGroupFilter = "All"
local selectedLowFilter = "NONE" -- "NONE", "FLIPS", "24H", "7D", "30D", "INVEST"
local selectedSort = "name_asc"
local selectedTimeframe = nil
local selectedChartMode = nil
local showCraftCostOverlay = true
local activeMountHost = nil

--------------------------------------------------------------------------------
-- Shift-Click Item Link Capture (Only When Search/Add Input Has Focus)
--------------------------------------------------------------------------------

local shiftClickHooked = false

local function EnsureShiftClickHook()
    if shiftClickHooked then return end
    shiftClickHooked = true

    local function TryInsertIntoAddBox(text)
        if not mainView or not mainView:IsShown() then return false end
        local eb = mainView._addEditBox
        if eb and eb:HasFocus() and type(text) == "string" and text:find("item:%d+") then
            eb:SetText(text)
            eb:SetCursorPosition(#text)
            return true
        end
        return false
    end

    if hooksecurefunc and ChatEdit_InsertLink then
        hooksecurefunc("ChatEdit_InsertLink", function(text)
            TryInsertIntoAddBox(text)
        end)
    end
end

--------------------------------------------------------------------------------
-- Helper: Format Delta Percentage Badge
--------------------------------------------------------------------------------

local function FormatDeltaBadge(pct)
    if pct == nil then
        return "|cFF998C78--|r"
    end
    if pct <= -0.5 then
        return string.format("|cFF38D972v %.1f%%|r", pct)
    elseif pct >= 0.5 then
        return string.format("|cFFF55954^ +%.1f%%|r", pct)
    else
        return "|cFFC4B79E0.0%|r"
    end
end

--------------------------------------------------------------------------------
-- Popover Builders (Targets, Group Manager, Settings)
--------------------------------------------------------------------------------

local function CloseAllPopovers()
    NS.CloseAllDropdowns()
    if not mainView then return end
    if mainView._targetsPopover then mainView._targetsPopover:Hide() end
    if mainView._groupsPopover then mainView._groupsPopover:Hide() end
    if mainView._settingsPopover then mainView._settingsPopover:Hide() end
    if mainView._investPopover then mainView._investPopover:Hide() end
    if mainView._craftsPopover then mainView._craftsPopover:Hide() end
    if mainView._searchPopup then mainView._searchPopup:Hide() end
    if mainView._matsHoverCard then mainView._matsHoverCard:Hide() end
end

local function CreateTargetsPopover()
    local pop = NS.CreatePanel(UIParent, nil, NS.COLORS.BG_DARK, NS.COLORS.BORDER_ACCENT, false)
    pop:SetSize(272, 162)
    pop:SetFrameStrata("FULLSCREEN_DIALOG")
    pop:SetFrameLevel(200)
    pop:EnableMouse(true)
    pop:SetClampedToScreen(true)
    pop:Hide()

    local title = pop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Price Alert Targets")

    local hint = pop:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 14, -29)
    hint:SetText("Format: 2g 50s 10c, 12.5g, 45s (blank=clear)")

    local buyLbl = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    buyLbl:SetPoint("TOPLEFT", 14, -52)
    buyLbl:SetText("Buy Below:")
    buyLbl:SetTextColor(0.22, 0.85, 0.45, 1)

    local buyBox, buyEB = NS.CreateEditBox(pop, 126, 22, "e.g. 2g 50s 00c")
    buyBox:SetPoint("TOPRIGHT", -14, -48)

    local sellLbl = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sellLbl:SetPoint("TOPLEFT", 14, -84)
    sellLbl:SetText("Sell Above:")
    sellLbl:SetTextColor(0.96, 0.35, 0.33, 1)

    local sellBox, sellEB = NS.CreateEditBox(pop, 126, 22, "e.g. 4g 20s 00c")
    sellBox:SetPoint("TOPRIGHT", -14, -80)

    local saveBtn = NS.CreateButton(pop, "Save Targets", 104, 22, true)
    saveBtn:SetPoint("BOTTOMLEFT", 14, 14)

    local clearBtn = NS.CreateButton(pop, "Clear", 58, 22, false)
    clearBtn:SetPoint("LEFT", saveBtn, "RIGHT", 6, 0)

    local closeBtn = NS.CreateButton(pop, "Close", 58, 22, false)
    closeBtn:SetPoint("BOTTOMRIGHT", -14, 14)

    local function CommitTargets()
        if not selectedItemID then return end
        local buyVal = NS.ParseMoney(buyEB:GetText())
        local sellVal = NS.ParseMoney(sellEB:GetText())
        NS.DB:SetItemTargets(selectedItemID, buyVal, sellVal)
        pop:Hide()
    end

    saveBtn:SetScript("OnClick", CommitTargets)
    buyEB:SetScript("OnEnterPressed", CommitTargets)
    sellEB:SetScript("OnEnterPressed", CommitTargets)
    clearBtn:SetScript("OnClick", function()
        buyEB:SetText("")
        sellEB:SetText("")
        if selectedItemID then
            NS.DB:SetItemTargets(selectedItemID, nil, nil)
        end
        pop:Hide()
    end)
    closeBtn:SetScript("OnClick", function() pop:Hide() end)

    function pop:OpenForItem(anchor, itemID)
        local entry = NS.DB:GetWatchItem(itemID)
        if not entry then return end
        CloseAllPopovers()
        buyEB:SetText(NS.FormatMoneyPlain(entry.buyTarget))
        sellEB:SetText(NS.FormatMoneyPlain(entry.sellTarget))
        self:ClearAllPoints()
        self:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4)
        self:SetFrameStrata("FULLSCREEN_DIALOG")
        self:SetFrameLevel(200)
        self:Show()
        self:Raise()
    end

    return pop
end

local function CreateGroupsPopover()
    local pop = NS.CreatePanel(UIParent, nil, NS.COLORS.BG_DARK, NS.COLORS.BORDER_ACCENT, false)
    pop:SetSize(268, 280)
    pop:SetFrameStrata("FULLSCREEN_DIALOG")
    pop:SetFrameLevel(200)
    pop:EnableMouse(true)
    pop:SetClampedToScreen(true)
    pop:Hide()

    local title = pop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Profession & Watchlist Groups")

    local addBox, addEB = NS.CreateEditBox(pop, 168, 22, "New group name...")
    addBox:SetPoint("TOPLEFT", 18, -34)

    local addBtn = NS.CreateButton(pop, "Add", 56, 22, true)
    addBtn:SetPoint("LEFT", addBox, "RIGHT", 6, 0)

    local statusTxt = pop:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    statusTxt:SetPoint("TOPLEFT", 14, -60)
    statusTxt:SetPoint("TOPRIGHT", -14, -60)
    statusTxt:SetJustifyH("LEFT")

    local rows = {}

    local function RefreshGroupList()
        local groups = NS.DB:GetGroups()
        for i = 1, #groups do
            local gName = groups[i]
            local row = rows[i]
            if not row then
                row = CreateFrame("Frame", nil, pop)
                row:SetHeight(20)
                local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                lbl:SetPoint("LEFT", 4, 0)
                lbl:SetPoint("RIGHT", -52, 0)
                lbl:SetJustifyH("LEFT")
                row.lbl = lbl

                local del = NS.CreateButton(row, "Del", 42, 18, false)
                del:SetPoint("RIGHT", -2, 0)
                row.del = del
                rows[i] = row
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", pop, "TOPLEFT", 12, -(76 + (i - 1) * 22))
            row:SetPoint("TOPRIGHT", pop, "TOPRIGHT", -12, -(76 + (i - 1) * 22))
            row.lbl:SetText(gName)
            row.del:SetEnabledState(#groups > 1)
            row.del:SetScript("OnClick", function()
                local ok, err = NS.DB:DeleteGroup(gName)
                if not ok then
                    statusTxt:SetText("|cFFF55954" .. tostring(err) .. "|r")
                else
                    statusTxt:SetText("Deleted '" .. gName .. "'.")
                    if selectedGroupFilter == gName then
                        selectedGroupFilter = "All"
                    end
                    RefreshGroupList()
                end
            end)
            row:Show()
        end
        for i = #groups + 1, #rows do
            rows[i]:Hide()
        end
        local neededH = math.max(170, 118 + #groups * 22)
        pop:SetHeight(math.min(380, neededH))
    end

    local function DoAddGroup()
        local ok, err = NS.DB:AddGroup(addEB:GetText())
        if ok then
            addEB:SetText("")
            statusTxt:SetText("|cFF38D972Group added.|r")
            RefreshGroupList()
        else
            statusTxt:SetText("|cFFF55954" .. tostring(err) .. "|r")
        end
    end

    addBtn:SetScript("OnClick", DoAddGroup)
    addEB:SetScript("OnEnterPressed", DoAddGroup)

    local closeBtn = NS.CreateButton(pop, "Close", 62, 22, false)
    closeBtn:SetPoint("BOTTOMRIGHT", -12, 12)
    closeBtn:SetScript("OnClick", function() pop:Hide() end)

    function pop:OpenAt(anchor)
        CloseAllPopovers()
        statusTxt:SetText("")
        RefreshGroupList()
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
        self:SetFrameStrata("FULLSCREEN_DIALOG")
        self:SetFrameLevel(200)
        self:Show()
        self:Raise()
    end

    return pop
end

local function CreateSettingsPopover()
    local pop = NS.CreatePanel(UIParent, nil, NS.COLORS.BG_DARK, NS.COLORS.BORDER_ACCENT, false)
    pop:SetSize(288, 272)
    pop:SetFrameStrata("FULLSCREEN_DIALOG")
    pop:SetFrameLevel(200)
    pop:EnableMouse(true)
    pop:SetClampedToScreen(true)
    pop:Hide()

    local title = pop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("ForeverMarketWatch Settings")

    local autoBtn = NS.CreateButton(pop, "", 260, 22, false)
    autoBtn:SetPoint("TOPLEFT", 14, -36)

    local intervalBtn = NS.CreateButton(pop, "", 260, 22, false)
    intervalBtn:SetPoint("TOPLEFT", 14, -64)

    local cdLbl = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cdLbl:SetPoint("TOPLEFT", 16, -96)
    cdLbl:SetText("Open Cooldown (minutes):")

    local cdBox, cdEB = NS.CreateEditBox(pop, 54, 22, "15")
    cdBox:SetPoint("TOPRIGHT", -14, -92)

    local passiveBtn = NS.CreateButton(pop, "", 260, 22, false)
    passiveBtn:SetPoint("TOPLEFT", 14, -124)

    local seedBtn = NS.CreateButton(pop, "Restore All Profession Materials", 260, 22, false)
    seedBtn:SetPoint("TOPLEFT", 14, -152)

    local demoBtn = NS.CreateButton(pop, "", 260, 22, false)
    demoBtn:SetPoint("TOPLEFT", 14, -180)

    local tipTxt = pop:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    tipTxt:SetPoint("TOPLEFT", 14, -208)
    tipTxt:SetPoint("TOPRIGHT", -14, -208)
    tipTxt:SetJustifyH("LEFT")
    tipTxt:SetText("Tip: Run api-sync\\Setup Blizzard API.bat for live hourly prices even while offline.")

    local closeBtn = NS.CreateButton(pop, "Done", 74, 22, true)
    closeBtn:SetPoint("BOTTOMRIGHT", -14, 12)

    local INTERVAL_CYCLE = { 0, 15, 30, 60 }

    local function RefreshControls()
        local s = NS.DB:GetSettings()
        autoBtn:SetTextLabel("Auto-Scan on AH Open: " .. (s.autoScanOnOpen and "|cFF38D972ON|r" or "|cFFF55954OFF|r"))
        autoBtn:SetActiveState(s.autoScanOnOpen)

        local iv = tonumber(s.autoScanIntervalMinutes) or 0
        local ivLabel = (iv > 0) and ("|cFF38D972Every " .. iv .. " min|r") or "|cFFF55954OFF|r"
        intervalBtn:SetTextLabel("Park-at-AH Auto-Scan: " .. ivLabel)
        intervalBtn:SetActiveState(iv > 0)

        cdEB:SetText(tostring(s.autoScanCooldownMinutes or 15))

        passiveBtn:SetTextLabel("Passive Capture: " .. (s.passiveCapture and "|cFF38D972ON|r" or "|cFFF55954OFF|r"))
        passiveBtn:SetActiveState(s.passiveCapture)

        local isDemo = NS.DB:IsDemoMode()
        demoBtn:SetTextLabel("90-Day Demo Preview: " .. (isDemo and "|cFFFFD100ACTIVE|r" or "OFF"))
        demoBtn:SetActiveState(isDemo)
        seedBtn:SetEnabledState(not isDemo)
    end

    autoBtn:SetScript("OnClick", function()
        local s = NS.DB:GetSettings()
        s.autoScanOnOpen = not s.autoScanOnOpen
        RefreshControls()
    end)

    intervalBtn:SetScript("OnClick", function()
        local s = NS.DB:GetSettings()
        local cur = tonumber(s.autoScanIntervalMinutes) or 0
        local nextVal = INTERVAL_CYCLE[1]
        for i = 1, #INTERVAL_CYCLE do
            if INTERVAL_CYCLE[i] == cur then
                nextVal = INTERVAL_CYCLE[(i % #INTERVAL_CYCLE) + 1]
                break
            end
        end
        s.autoScanIntervalMinutes = nextVal
        NS.Scanner:ReschedulePeriodicScan()
        RefreshControls()
        UI.RefreshWatchlist()
    end)

    passiveBtn:SetScript("OnClick", function()
        local s = NS.DB:GetSettings()
        s.passiveCapture = not s.passiveCapture
        RefreshControls()
    end)

    seedBtn:SetScript("OnClick", function()
        local added = NS.DB:SeedProfessionMaterials(false)
        if added == 0 then
            NS.Print("All profession materials are already in your watchlist.")
        end
        pop:Hide()
    end)

    demoBtn:SetScript("OnClick", function()
        if NS.ToggleDemoMode then
            NS.ToggleDemoMode()
        end
        RefreshControls()
    end)

    local function SaveCooldown()
        local n = tonumber(cdEB:GetText())
        if n and n >= 1 and n <= 1440 then
            NS.DB:GetSettings().autoScanCooldownMinutes = math.floor(n)
        end
    end

    cdEB:SetScript("OnEnterPressed", function(self) SaveCooldown(); self:ClearFocus() end)
    cdEB:SetScript("OnEditFocusLost", SaveCooldown)

    closeBtn:SetScript("OnClick", function()
        SaveCooldown()
        pop:Hide()
    end)

    function pop:OpenAt(anchor)
        CloseAllPopovers()
        RefreshControls()
        self:ClearAllPoints()
        self:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4)
        self:SetFrameStrata("FULLSCREEN_DIALOG")
        self:SetFrameLevel(200)
        self:Show()
        self:Raise()
    end

    return pop
end

--------------------------------------------------------------------------------
-- Account-Wide Explicit Investment Ledger Popover (Shared Across All Alts)
--------------------------------------------------------------------------------

local function CreateInvestPopover()
    local pop = NS.CreatePanel(UIParent, nil, NS.COLORS.BG_DARK, NS.COLORS.BORDER_ACCENT, false)
    pop:SetSize(336, 286)
    pop:SetFrameStrata("FULLSCREEN_DIALOG")
    pop:SetFrameLevel(200)
    pop:EnableMouse(true)
    pop:SetClampedToScreen(true)
    pop:Hide()

    local title = pop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Investment Position (Account-Wide)")

    local itemTitle = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    itemTitle:SetPoint("TOPLEFT", 14, -29)
    itemTitle:SetPoint("TOPRIGHT", -14, -29)
    itemTitle:SetJustifyH("LEFT")

    local statusBox = NS.CreatePanel(pop, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER, true)
    statusBox:SetPoint("TOPLEFT", 12, -48)
    statusBox:SetPoint("TOPRIGHT", -12, -48)
    statusBox:SetHeight(66)

    local posLine1 = statusBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    posLine1:SetPoint("TOPLEFT", 8, -7)
    posLine1:SetPoint("TOPRIGHT", -8, -7)
    posLine1:SetJustifyH("LEFT")

    local posLine2 = statusBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    posLine2:SetPoint("TOPLEFT", 8, -26)
    posLine2:SetPoint("TOPRIGHT", -8, -26)
    posLine2:SetJustifyH("LEFT")

    local posLine3 = statusBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    posLine3:SetPoint("TOPLEFT", 8, -46)
    posLine3:SetPoint("TOPRIGHT", -8, -46)
    posLine3:SetJustifyH("LEFT")

    -- Explicit Buy/Sell Lot Entry (never auto-counts personal/junk items)
    local qtyLbl = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    qtyLbl:SetPoint("TOPLEFT", 14, -126)
    qtyLbl:SetText("Qty:")

    local qtyBox, qtyEB = NS.CreateEditBox(pop, 54, 22, "20")
    qtyBox:SetPoint("TOPLEFT", 48, -122)

    local priceLbl = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    priceLbl:SetPoint("LEFT", qtyBox, "RIGHT", 10, 0)
    priceLbl:SetText("Each:")

    local priceBox, priceEB = NS.CreateEditBox(pop, 128, 22, "e.g. 10g 50s")
    priceBox:SetPoint("LEFT", priceLbl, "RIGHT", 8, 0)

    local altLbl = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    altLbl:SetPoint("TOPLEFT", 14, -156)
    altLbl:SetText("Alt / Bank:")

    local altBox, altEB = NS.CreateEditBox(pop, 124, 22, "Bankalt")
    altBox:SetPoint("TOPLEFT", 84, -152)

    local bagHint = pop:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    bagHint:SetPoint("LEFT", altBox, "RIGHT", 8, 0)
    bagHint:SetPoint("RIGHT", pop, "RIGHT", -12, 0)
    bagHint:SetJustifyH("LEFT")

    local buyBtn = NS.CreateButton(pop, "+ Log Buy", 86, 22, true)
    buyBtn:SetPoint("TOPLEFT", 14, -184)

    local sellBtn = NS.CreateButton(pop, "- Log Sale", 86, 22, false)
    sellBtn:SetPoint("LEFT", buyBtn, "RIGHT", 6, 0)

    local clearBtn = NS.CreateButton(pop, "Clear", 54, 22, false)
    clearBtn:SetPoint("LEFT", sellBtn, "RIGHT", 6, 0)

    local closeBtn = NS.CreateButton(pop, "Close", 58, 22, false)
    closeBtn:SetPoint("TOPRIGHT", -14, -184)

    local msgTxt = pop:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    msgTxt:SetPoint("TOPLEFT", 14, -212)
    msgTxt:SetPoint("TOPRIGHT", -14, -212)
    msgTxt:SetJustifyH("LEFT")

    -- Account-wide portfolio summary footer
    local portBox = NS.CreatePanel(pop, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, true)
    portBox:SetPoint("BOTTOMLEFT", 12, 12)
    portBox:SetPoint("BOTTOMRIGHT", -12, 12)
    portBox:SetHeight(42)

    local portLine1 = portBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    portLine1:SetPoint("TOPLEFT", 8, -6)
    portLine1:SetPoint("TOPRIGHT", -8, -6)
    portLine1:SetJustifyH("LEFT")

    local portLine2 = portBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    portLine2:SetPoint("BOTTOMLEFT", 8, 6)
    portLine2:SetPoint("BOTTOMRIGHT", -8, 6)
    portLine2:SetJustifyH("LEFT")

    local activeID = nil

    local function RefreshInvestView()
        if not activeID then return end
        local entry = NS.DB:GetWatchItem(activeID)
        local hist = NS.DB:GetItemHistory(activeID)
        local sum = NS.Analytics.GetItemSummary(entry, hist, selectedTimeframe)
        local inv = sum.investment

        itemTitle:SetText((entry and entry.name or ("Item #" .. activeID)) .. "  |cFF998C78(Only logged lots are tracked)|r")
        local carrying = NS.DB:CountItemOnCurrentCharacter(activeID)
        bagHint:SetText("In bags: " .. tostring(carrying))

        if inv and inv.qty and inv.qty > 0 then
            posLine1:SetText(string.format(
                "Held: |cFFFFD100%d|r  Avg Cost: %s  BE(5%%): %s",
                inv.qty, NS.FormatMoney(inv.avgCost, true), NS.FormatMoney(sum.investBreakEven, true)
            ))
            local pnlStr = "--"
            if sum.investUnrealizedPnL then
                local clr = (sum.investUnrealizedPnL >= 0) and "|cFF38D972+" or "|cFFF55954"
                pnlStr = string.format("%s%s (%.1f%%)|r", clr, NS.FormatMoney(sum.investUnrealizedPnL, true), sum.investUnrealizedPct or 0)
            end
            posLine2:SetText("Unrealized P&L (net): " .. pnlStr)
            posLine3:SetText(string.format(
                "Alts: %s  |  Booked Realized: %s",
                inv.holder or "Any",
                NS.FormatMoney(inv.realizedProfit or 0, true)
            ))
        else
            posLine1:SetText("|cFF998C78No active investment logged for this item.|r")
            posLine2:SetText("Personal/raid items in bags are ignored until you click '+ Log Buy'.")
            local realized = (inv and inv.realizedProfit) or 0
            posLine3:SetText("Prior Realized Profit: " .. NS.FormatMoney(realized, true))
        end

        local port = NS.DB:GetPortfolioSummary()
        portLine1:SetText(string.format("All-Alts Portfolio (%d active)  |  Invested: %s", port.activePositions, NS.FormatMoney(port.totalInvested, true)))
        local uClr = (port.unrealizedPnL >= 0) and "|cFF38D972+" or "|cFFF55954"
        local rClr = (port.realizedProfit >= 0) and "|cFF38D972+" or "|cFFF55954"
        portLine2:SetText(string.format("Unrealized: %s%s|r   |   Realized: %s%s|r",
            uClr, NS.FormatMoney(port.unrealizedPnL, true),
            rClr, NS.FormatMoney(port.realizedProfit, true)
        ))
    end

    buyBtn:SetScript("OnClick", function()
        if not activeID then return end
        local q = tonumber(qtyEB:GetText())
        local p = NS.ParseMoney(priceEB:GetText())
        local ok, res = NS.DB:LogInvestmentBuy(activeID, q, p, altEB:GetText())
        if ok then
            msgTxt:SetText("|cFF38D972Logged investment purchase!|r")
            qtyEB:SetText("")
            RefreshInvestView()
        else
            msgTxt:SetText("|cFFF55954" .. tostring(res) .. "|r")
        end
    end)

    sellBtn:SetScript("OnClick", function()
        if not activeID then return end
        local q = tonumber(qtyEB:GetText())
        local p = NS.ParseMoney(priceEB:GetText())
        local ok, profitOrErr = NS.DB:LogInvestmentSale(activeID, q, p)
        if ok then
            local clr = (profitOrErr >= 0) and "|cFF38D972+" or "|cFFF55954"
            msgTxt:SetText("Sale booked! Net profit (after AH cut): " .. clr .. NS.FormatMoney(profitOrErr, true) .. "|r")
            qtyEB:SetText("")
            RefreshInvestView()
        else
            msgTxt:SetText("|cFFF55954" .. tostring(profitOrErr) .. "|r")
        end
    end)

    clearBtn:SetScript("OnClick", function()
        if not activeID then return end
        NS.DB:ClearInvestment(activeID)
        msgTxt:SetText("Investment cleared.")
        RefreshInvestView()
    end)

    closeBtn:SetScript("OnClick", function() pop:Hide() end)

    function pop:OpenForItem(anchor, itemID)
        if not itemID then return end
        CloseAllPopovers()
        activeID = itemID
        msgTxt:SetText("")
        local hist = NS.DB:GetItemHistory(itemID)
        local latest = NS.Analytics.GetLatestPoint(hist)
        priceEB:SetText(latest and NS.FormatMoneyPlain(latest.min) or "")
        altEB:SetText((UnitName and UnitName("player")) or "")
        qtyEB:SetText("")
        RefreshInvestView()
        self:ClearAllPoints()
        self:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4)
        self:SetFrameStrata("FULLSCREEN_DIALOG")
        self:SetFrameLevel(200)
        self:Show()
        self:Raise()
    end

    return pop
end

--------------------------------------------------------------------------------
-- Raw-to-Crafted Arbitrage Scanner Popover (Smelting / Transmutes / Alchemy)
--------------------------------------------------------------------------------

local function CreateCraftsPopover()
    local pop = NS.CreatePanel(UIParent, nil, NS.COLORS.BG_DARK, NS.COLORS.BORDER_ACCENT, false)
    pop:SetSize(456, 340)
    pop:SetFrameStrata("FULLSCREEN_DIALOG")
    pop:SetFrameLevel(200)
    pop:EnableMouse(true)
    pop:SetClampedToScreen(true)
    pop:Hide()

    local title = pop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Crafting & Smelting Arbitrage (After 5% AH Cut)")

    local closeBtn = NS.CreateButton(pop, "Close", 58, 20, false)
    closeBtn:SetPoint("TOPRIGHT", -10, -8)
    closeBtn:SetScript("OnClick", function() pop:Hide() end)

    local hdr = NS.CreatePanel(pop, nil, NS.COLORS.BG_HEADER, NS.COLORS.BORDER, true)
    hdr:SetPoint("TOPLEFT", 10, -34)
    hdr:SetPoint("TOPRIGHT", -10, -34)
    hdr:SetHeight(18)

    local h1 = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h1:SetPoint("LEFT", 8, 0); h1:SetText("Recipe")
    local h2 = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h2:SetPoint("RIGHT", -190, 0); h2:SetText("Mat Cost")
    local h3 = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h3:SetPoint("RIGHT", -96, 0); h3:SetText("Net Sale")
    local h4 = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h4:SetPoint("RIGHT", -10, 0); h4:SetText("Net Profit")

    local sf = CreateFrame("ScrollFrame", "ForeverMarketWatchCraftsScroll", pop, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 10, -56)
    sf:SetPoint("BOTTOMRIGHT", -30, 12)

    local child = CreateFrame("Frame", nil, sf)
    child:SetWidth(410)
    child:SetHeight(1)
    sf:SetScrollChild(child)

    local emptyLbl = pop:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyLbl:SetPoint("CENTER", pop, "CENTER", 0, -10)
    emptyLbl:SetText("No craft spreads calculated yet â€” sync Blizzard API or scan mats first.")
    emptyLbl:Hide()

    local rows = {}

    local function RefreshCrafts()
        local list = NS.Arbitrage and NS.Arbitrage.EvaluateAll() or {}
        emptyLbl:SetShown(#list == 0)
        local rowH = 26

        for i = 1, #list do
            local r = list[i]
            local row = rows[i]
            if not row then
                row = CreateFrame("Button", nil, child)
                row:SetHeight(rowH - 1)
                local bg = row:CreateTexture(nil, "BACKGROUND")
                bg:SetAllPoints()
                row.bg = bg
                local hl = row:CreateTexture(nil, "ARTWORK")
                hl:SetAllPoints()
                hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
                hl:SetBlendMode("ADD")
                hl:SetAlpha(0)
                row.hl = hl

                local ic = row:CreateTexture(nil, "ARTWORK")
                ic:SetSize(20, 20)
                ic:SetPoint("LEFT", 4, 0)
                ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                row.icon = ic

                local nTxt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                nTxt:SetPoint("LEFT", ic, "RIGHT", 6, 0)
                nTxt:SetWidth(156)
                nTxt:SetJustifyH("LEFT")
                nTxt:SetWordWrap(false)
                row.nameTxt = nTxt

                local cTxt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                cTxt:SetPoint("RIGHT", row, "RIGHT", -168, 0)
                cTxt:SetJustifyH("RIGHT")
                row.costTxt = cTxt

                local sTxt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                sTxt:SetPoint("RIGHT", row, "RIGHT", -84, 0)
                sTxt:SetJustifyH("RIGHT")
                row.saleTxt = sTxt

                local pTxt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                pTxt:SetPoint("RIGHT", row, "RIGHT", -4, 0)
                pTxt:SetJustifyH("RIGHT")
                row.profTxt = pTxt

                row:SetScript("OnEnter", function(s) s.hl:SetAlpha(0.55) end)
                row:SetScript("OnLeave", function(s) s.hl:SetAlpha(0) end)
                rows[i] = row
            end

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -((i - 1) * rowH))
            row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -((i - 1) * rowH))
            local bgC = ((i % 2) == 0) and NS.COLORS.BG_ROW_ALT or NS.COLORS.BG_ROW
            row.bg:SetColorTexture(bgC[1], bgC[2], bgC[3], bgC[4])

            row.icon:SetTexture(r.icon or 134400)
            row.nameTxt:SetText(r.name)
            row.costTxt:SetText(NS.FormatMoney(r.craftCost, true))
            row.saleTxt:SetText(NS.FormatMoney(r.netSale, true))

            local pClr = (r.netProfit > 0) and "|cFF38D972+" or "|cFFF55954"
            row.profTxt:SetText(string.format("%s%s|r", pClr, NS.FormatMoney(r.netProfit, true)))

            row:SetScript("OnClick", function()
                pop:Hide()
                selectedLowFilter = "NONE"
                selectedGroupFilter = "All"
                UI.SelectItem(r.productID)
            end)
            row:Show()
        end

        for i = #list + 1, #rows do
            rows[i]:Hide()
        end
        child:SetHeight(math.max(1, #list * rowH))
    end

    function pop:OpenAt(anchor)
        CloseAllPopovers()
        RefreshCrafts()
        self:ClearAllPoints()
        self:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4)
        self:SetFrameStrata("FULLSCREEN_DIALOG")
        self:SetFrameLevel(200)
        self:Show()
        self:Raise()
    end

    return pop
end

--------------------------------------------------------------------------------
-- Crafted Item Underlying Materials Hover Preview Card (Multi-Sparkline)
--------------------------------------------------------------------------------

local function CreateMatsHoverCard()
    local card = NS.CreatePanel(UIParent, nil, NS.COLORS.BG_DARK, NS.COLORS.BORDER_ACCENT, false)
    card:SetSize(318, 120)
    card:SetFrameStrata("TOOLTIP")
    card:SetClampedToScreen(true)
    card:EnableMouse(false) -- Strictly visual hover preview; never blocks row clicks
    card:Hide()

    local title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetPoint("TOPRIGHT", -10, -8)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)

    local arbSummary = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    arbSummary:SetPoint("TOPLEFT", 10, -24)
    arbSummary:SetPoint("TOPRIGHT", -10, -24)
    arbSummary:SetJustifyH("LEFT")

    local rows = {}

    local function GetOrCreateRow(idx)
        if rows[idx] then return rows[idx] end
        local r = CreateFrame("Frame", nil, card)
        r:SetHeight(34)

        local bg = r:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        r.bg = bg

        local ic = r:CreateTexture(nil, "ARTWORK")
        ic:SetSize(22, 22)
        ic:SetPoint("LEFT", 5, 0)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.icon = ic

        local nTxt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nTxt:SetPoint("TOPLEFT", ic, "TOPRIGHT", 6, -1)
        nTxt:SetWidth(158)
        nTxt:SetJustifyH("LEFT")
        nTxt:SetWordWrap(false)
        r.nameTxt = nTxt

        local pTxt = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        pTxt:SetPoint("BOTTOMLEFT", ic, "BOTTOMRIGHT", 6, 1)
        pTxt:SetWidth(158)
        pTxt:SetJustifyH("LEFT")
        pTxt:SetWordWrap(false)
        r.priceTxt = pTxt

        local spark = NS.Chart.CreateSparkline(r)
        spark:SetPoint("RIGHT", r, "RIGHT", -5, 0)
        spark:SetSize(102, 26)
        r.spark = spark

        rows[idx] = r
        return r
    end

    function card:ShowForCraftedItem(anchorRow, itemID, timeframe)
        if not NS.Arbitrage or not NS.Arbitrage.EvaluateProduct then
            self:Hide()
            return
        end
        local info = NS.Arbitrage.EvaluateProduct(itemID, timeframe or "1D")
        if not info then
            self:Hide()
            return
        end

        title:SetText(info.name .. "  |cFF998C78(" .. info.profession .. " â€” Mats & Arbitrage)|r")

        if info.netProfit ~= nil then
            local clr = (info.netProfit > 0) and "|cFF38D972+" or "|cFFF55954"
            arbSummary:SetText(string.format(
                "Mats: %s  |  Net(5%%): %s  |  Arb: %s%s (%.0f%%)|r",
                NS.FormatMoney(info.craftCost, true),
                NS.FormatMoney(info.netSale, true),
                clr, NS.FormatMoney(info.netProfit, true), info.marginPct or 0
            ))
        else
            arbSummary:SetText("|cFF998C78Waiting for price data on all ingredients...|r")
        end

        -- Row 1: The crafted product itself
        local yOff = 44
        local prodRow = GetOrCreateRow(1)
        prodRow:ClearAllPoints()
        prodRow:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -yOff)
        prodRow:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -yOff)
        prodRow.bg:SetColorTexture(NS.COLORS.BG_ROW_SEL[1], NS.COLORS.BG_ROW_SEL[2], NS.COLORS.BG_ROW_SEL[3], 0.55)
        prodRow.icon:SetTexture(info.icon or 134400)
        prodRow.nameTxt:SetTextColor(1, 0.85, 0.25, 1)
        prodRow.nameTxt:SetText("Product: " .. info.name)
        prodRow.priceTxt:SetText(info.productPrice and ("Buyout: " .. NS.FormatMoney(info.productPrice, true)) or "No price")
        prodRow.spark:Render(info.productSeries, info.productDayCtx)
        prodRow:Show()
        yOff = yOff + 36

        -- Rows 2..N: Each underlying material with its own mini sparkline
        for i = 1, #info.reagents do
            local rg = info.reagents[i]
            local rr = GetOrCreateRow(i + 1)
            rr:ClearAllPoints()
            rr:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -yOff)
            rr:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -yOff)
            local bgC = ((i % 2) == 0) and NS.COLORS.BG_ROW_ALT or NS.COLORS.BG_ROW
            rr.bg:SetColorTexture(bgC[1], bgC[2], bgC[3], bgC[4])
            rr.icon:SetTexture(rg.icon or 134400)
            local qr, qg, qb = NS.Compat.GetQualityColor(rg.quality)
            rr.nameTxt:SetTextColor(qr, qg, qb, 1)
            rr.nameTxt:SetText(string.format("%dx %s", rg.qty, rg.name))
            if rg.unitPrice then
                rr.priceTxt:SetText(string.format("%s ea  (= %s)", NS.FormatMoney(rg.unitPrice, true), NS.FormatMoney(rg.lineCost, true)))
            else
                rr.priceTxt:SetText("No price data")
            end
            rr.spark:Render(rg.series, rg.dayCtx)
            rr:Show()
            yOff = yOff + 36
        end

        for i = (#info.reagents + 2), #rows do
            rows[i]:Hide()
        end

        self:SetHeight(yOff + 8)
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", anchorRow, "TOPRIGHT", 10, 12)
        self:Show()
        self:Raise()
    end

    return card
end

--------------------------------------------------------------------------------
-- Main Shared Workspace Construction (Classic WoW AH Style)
--------------------------------------------------------------------------------

function UI.GetOrCreateMainView()
    if mainView then
        return mainView
    end

    EnsureShiftClickHook()

    local settings = NS.DB:GetSettings()
    selectedTimeframe = settings.defaultTimeframe or "30D"
    selectedChartMode = settings.defaultChartMode or 2
    selectedSort = settings.defaultSort or "name_asc"
    if selectedSort == "signal_desc" then
        selectedSort = "name_asc"
        settings.defaultSort = "name_asc"
    end

    local root = CreateFrame("Frame", "ForeverMarketWatchMainView", UIParent)
    root:Hide()
    mainView = root

    ----------------------------------------------------------------------------
    -- TOP PAGE SWITCHER BAR (Dashboard | Market & Charts | Flipping | Inventory | Ledger)
    ----------------------------------------------------------------------------
    local topNav = CreateFrame("Frame", nil, root)
    topNav:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
    topNav:SetPoint("TOPRIGHT", root, "TOPRIGHT", 0, 0)
    topNav:SetHeight(24)

    local dashTabBtn = NS.CreateButton(topNav, "Dashboard", 82, 22, false)
    dashTabBtn:SetPoint("LEFT", topNav, "LEFT", 0, 0)
    root._dashTabBtn = dashTabBtn

    local marketTabBtn = NS.CreateButton(topNav, "Market & Charts", 108, 22, false)
    marketTabBtn:SetPoint("LEFT", dashTabBtn, "RIGHT", 4, 0)
    root._marketTabBtn = marketTabBtn

    local flipTabBtn = NS.CreateButton(topNav, "Flipping", 68, 22, false)
    flipTabBtn:SetPoint("LEFT", marketTabBtn, "RIGHT", 4, 0)
    root._flipTabBtn = flipTabBtn

    local invTabBtn = NS.CreateButton(topNav, "Inventory", 76, 22, false)
    invTabBtn:SetPoint("LEFT", flipTabBtn, "RIGHT", 4, 0)
    root._invTabBtn = invTabBtn

    local ledgerTabBtn = NS.CreateButton(topNav, "Ledger", 64, 22, false)
    ledgerTabBtn:SetPoint("LEFT", invTabBtn, "RIGHT", 4, 0)
    root._ledgerTabBtn = ledgerTabBtn

    local navStatusTxt = topNav:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    navStatusTxt:SetPoint("RIGHT", topNav, "RIGHT", -4, 0)
    navStatusTxt:SetJustifyH("RIGHT")
    root._navStatusTxt = navStatusTxt

    local contentHost = CreateFrame("Frame", nil, root)
    contentHost:SetPoint("TOPLEFT", topNav, "BOTTOMLEFT", 0, -4)
    contentHost:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", 0, 0)

    local marketPage = CreateFrame("Frame", nil, contentHost)
    marketPage:SetAllPoints(contentHost)
    root._marketPage = marketPage

    local function OpenItemFromSubTab(itemID)
        selectedPage = "MARKET"
        selectedLowFilter = "NONE"
        selectedItemID = itemID
        CloseAllPopovers()
        UI.ApplyPageVisibility()
        UI.RefreshAll()
    end

    local dashboardPage = NS.Dashboard.Create(contentHost, OpenItemFromSubTab)
    root._dashboardPage = dashboardPage

    local flippingPage = NS.FlippingUI.Create(contentHost, OpenItemFromSubTab, function(anchor, itemID)
        if root._targetsPopover and itemID then
            root._targetsPopover:OpenForItem(anchor, itemID)
        end
    end)
    root._flippingPage = flippingPage

    local inventoryPage = NS.InventoryUI.Create(contentHost, OpenItemFromSubTab, function(anchor, itemID)
        if root._investPopover and itemID then
            root._investPopover:OpenForItem(anchor, itemID)
        end
    end)
    root._inventoryPage = inventoryPage

    local ledgerPage = NS.LedgerUI.Create(contentHost, OpenItemFromSubTab)
    root._ledgerPage = ledgerPage

    local function SwitchToPage(pageName)
        selectedPage = pageName
        CloseAllPopovers()
        UI.ApplyPageVisibility()
        UI.RefreshAll()
    end

    dashTabBtn:SetScript("OnClick",   function() SwitchToPage("DASHBOARD") end)
    marketTabBtn:SetScript("OnClick", function() SwitchToPage("MARKET") end)
    flipTabBtn:SetScript("OnClick",   function() SwitchToPage("FLIPPING") end)
    invTabBtn:SetScript("OnClick",    function() SwitchToPage("INVENTORY") end)
    ledgerTabBtn:SetScript("OnClick", function() SwitchToPage("LEDGER") end)

    ----------------------------------------------------------------------------
    -- LEFT PANE: Classic AH Category Filters + Search-to-Add + Watchlist Table
    ----------------------------------------------------------------------------
    local leftPane = NS.CreatePanel(marketPage, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, false)
    leftPane:SetPoint("TOPLEFT", marketPage, "TOPLEFT", 0, 0)
    leftPane:SetPoint("BOTTOMLEFT", marketPage, "BOTTOMLEFT", 0, 0)
    leftPane:SetWidth(312)
    root._leftPane = leftPane

    -- Row 1: Profession Group Dropdown + Groups Button + Sort Dropdown
    local groupDropdown = NS.CreateDropdown(leftPane, 118, 22, function(val)
        selectedGroupFilter = val
        UI.RefreshWatchlist()
        UI.RefreshActionButtons()
    end)
    groupDropdown:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 8, -8)
    root._groupDropdown = groupDropdown

    local groupsBtn = NS.CreateButton(leftPane, "Groups", 54, 22, false)
    groupsBtn:SetPoint("LEFT", groupDropdown, "RIGHT", 4, 0)

    local sortDropdown = NS.CreateDropdown(leftPane, 116, 22, function(val)
        selectedSort = val
        NS.DB:GetSettings().defaultSort = val
        UI.RefreshWatchlist()
    end)
    sortDropdown:SetPoint("LEFT", groupsBtn, "RIGHT", 4, 0)
    root._sortDropdown = sortDropdown
    do
        local sOpts = {}
        for i = 1, #NS.SORT_MODES do
            table.insert(sOpts, { value = NS.SORT_MODES[i].id, label = NS.SORT_MODES[i].label })
        end
        sortDropdown:SetOptions(sOpts)
        sortDropdown:SetSelected(selectedSort, false)
    end

    -- Row 2: Search Items to Add Bar (Offline Catalog + Bags + Live AH Search)
    local addBox, addEB = NS.CreateEditBox(leftPane, 162, 22, "Search item name or ID...")
    addBox:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 14, -36)
    root._addEditBox = addEB

    local searchAHBtn = NS.CreateButton(leftPane, "Search AH", 74, 22, true)
    searchAHBtn:SetPoint("LEFT", addBox, "RIGHT", 6, 0)
    root._searchAHBtn = searchAHBtn

    local watchCurrentBtn = NS.CreateButton(leftPane, "+ AH", 44, 22, false)
    watchCurrentBtn:SetPoint("LEFT", searchAHBtn, "RIGHT", 4, 0)
    root._watchCurrentBtn = watchCurrentBtn

    -- Floating Search Results Popup (shows Catalog / Bags / History / Live AH matches with 1-click +Add)
    local searchPopup = NS.CreatePanel(UIParent, nil, NS.COLORS.BG_DARK, NS.COLORS.BORDER_ACCENT, false)
    searchPopup:SetFrameStrata("FULLSCREEN_DIALOG")
    searchPopup:SetFrameLevel(210)
    searchPopup:EnableMouse(true)
    searchPopup:SetClampedToScreen(true)
    searchPopup:SetWidth(346)
    searchPopup:Hide()
    searchPopup.rows = {}
    root._searchPopup = searchPopup

    local searchHeader = searchPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchHeader:SetPoint("TOPLEFT", 10, -8)
    searchHeader:SetPoint("TOPRIGHT", -54, -8)
    searchHeader:SetJustifyH("LEFT")
    searchPopup._header = searchHeader

    local closeSearchBtn = NS.CreateButton(searchPopup, "Close", 44, 18, false)
    closeSearchBtn:SetPoint("TOPRIGHT", -6, -5)
    closeSearchBtn:SetScript("OnClick", function() searchPopup:Hide() end)

    local function AddItemAndSelect(itemIdentifier, explicitName, explicitIcon, explicitQuality)
        local ok, result = NS.DB:AddWatchItem(itemIdentifier, selectedGroupFilter, explicitName, explicitIcon, explicitQuality)
        if ok and result then
            selectedItemID = result.itemID
            addEB:SetText("")
            addEB:ClearFocus()
            searchPopup:Hide()
            UI.RefreshAll()
            if NS.Scanner:IsAuctionHouseOpen() and not NS.Scanner:IsScanning() and not NS.DB:IsDemoMode() then
                NS.Scanner:ScanSingleItem(result.itemID)
            end
        else
            NS.PrintError(result or "Could not add item. Search by name, Shift-click, drag from bags, or enter an Item ID.")
        end
    end

    local function RenderSearchPopup(headerLabel, matches)
        if not matches or #matches == 0 then
            searchHeader:SetText(headerLabel or "No matching items found.")
            for i = 1, #searchPopup.rows do
                searchPopup.rows[i]:Hide()
            end
            searchPopup:SetHeight(44)
            searchPopup:ClearAllPoints()
            searchPopup:SetPoint("TOPLEFT", addBox, "BOTTOMLEFT", -6, -4)
            searchPopup:Show()
            return
        end

        searchHeader:SetText(headerLabel or string.format("Search Results (%d)", #matches))
        local rowH = 26
        local shown = math.min(#matches, 12)

        for i = 1, shown do
            local m = matches[i]
            local r = searchPopup.rows[i]
            if not r then
                r = CreateFrame("Button", nil, searchPopup)
                r:SetHeight(rowH - 1)

                local hl = r:CreateTexture(nil, "BACKGROUND")
                hl:SetAllPoints()
                hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
                hl:SetBlendMode("ADD")
                hl:SetAlpha(0)
                r.hl = hl

                local ic = r:CreateTexture(nil, "ARTWORK")
                ic:SetSize(20, 20)
                ic:SetPoint("LEFT", 4, 0)
                ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                r.icon = ic

                local nameLbl = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                nameLbl:SetPoint("LEFT", ic, "RIGHT", 6, 0)
                nameLbl:SetPoint("RIGHT", r, "RIGHT", -132, 0)
                nameLbl:SetJustifyH("LEFT")
                nameLbl:SetWordWrap(false)
                r.nameLbl = nameLbl

                local infoLbl = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                infoLbl:SetPoint("RIGHT", r, "RIGHT", -60, 0)
                infoLbl:SetJustifyH("RIGHT")
                r.infoLbl = infoLbl

                local actBtn = NS.CreateButton(r, "+ Add", 50, 19, true)
                actBtn:SetPoint("RIGHT", r, "RIGHT", -4, 0)
                r.actBtn = actBtn

                r:SetScript("OnEnter", function(s) s.hl:SetAlpha(0.65) end)
                r:SetScript("OnLeave", function(s) s.hl:SetAlpha(0) end)
                searchPopup.rows[i] = r
            end

            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", searchPopup, "TOPLEFT", 6, -(28 + (i - 1) * rowH))
            r:SetPoint("TOPRIGHT", searchPopup, "TOPRIGHT", -6, -(28 + (i - 1) * rowH))
            r.icon:SetTexture(m.icon or 134400)

            local qr, qg, qb = NS.Compat.GetQualityColor(m.quality)
            r.nameLbl:SetTextColor(qr, qg, qb, 1)
            r.nameLbl:SetText(m.name or ("Item #" .. tostring(m.itemID)))

            if m.price and m.price > 0 then
                r.infoLbl:SetText(NS.FormatMoney(m.price, true))
            else
                r.infoLbl:SetText(m.source or "")
            end

            local isWatched = NS.DB:GetWatchItem(m.itemID) ~= nil
            if isWatched then
                r.actBtn:SetTextLabel("View")
                r.actBtn:SetActiveState(false)
            else
                r.actBtn:SetTextLabel("+ Add")
                r.actBtn:SetActiveState(true)
            end

            local function OnPick()
                if NS.DB:GetWatchItem(m.itemID) then
                    selectedItemID = m.itemID
                    selectedGroupFilter = "All"
                    addEB:SetText("")
                    addEB:ClearFocus()
                    searchPopup:Hide()
                    UI.RefreshAll()
                else
                    AddItemAndSelect(m.itemID, m.name, m.icon, m.quality)
                end
            end

            r:SetScript("OnClick", OnPick)
            r.actBtn:SetScript("OnClick", OnPick)
            r:Show()
        end

        for i = shown + 1, #searchPopup.rows do
            searchPopup.rows[i]:Hide()
        end

        searchPopup:SetHeight(36 + shown * rowH)
        searchPopup:ClearAllPoints()
        searchPopup:SetPoint("TOPLEFT", addBox, "BOTTOMLEFT", -6, -4)
        searchPopup:SetFrameStrata("FULLSCREEN_DIALOG")
        searchPopup:SetFrameLevel(210)
        searchPopup:Show()
        searchPopup:Raise()
    end

    local function TriggerSearchOrAdd()
        local text = (addEB:GetText() or ""):match("^%s*(.-)%s*$")
        if text == "" then return end

        -- Direct item link or numeric ID adds immediately
        if text:find("item:%d+") or tonumber(text) then
            local parsedID = NS.Compat.ParseItemID(text)
            if parsedID then
                AddItemAndSelect(parsedID)
                return
            end
        end

        -- At Auction House -> run live AH Browse search too!
        if NS.Scanner:IsAuctionHouseOpen() and not NS.DB:IsDemoMode() then
            RenderSearchPopup("Searching live Auction House for '" .. text .. "'...", NS.DB:SearchOfflineItems(text, 8))
            NS.Scanner:SearchAHByName(text)
            return
        end

        -- Offline -> show matches from Profession Catalog + Bags + History
        local matches = NS.DB:SearchOfflineItems(text, 12)
        if #matches > 0 then
            RenderSearchPopup("Matches (Catalog / Bags / History):", matches)
        else
            RenderSearchPopup("No offline matches. Open AH and click 'Search AH'!", {})
        end
    end

    searchAHBtn:SetScript("OnClick", TriggerSearchOrAdd)
    addEB:SetScript("OnEnterPressed", TriggerSearchOrAdd)
    addEB:HookScript("OnEscapePressed", function() searchPopup:Hide() end)

    addEB:HookScript("OnTextChanged", function(self)
        local txt = (self:GetText() or ""):match("^%s*(.-)%s*$")
        if txt == "" or #txt < 2 or txt:find("item:%d+") then
            searchPopup:Hide()
            return
        end
        local matches = NS.DB:SearchOfflineItems(txt, 10)
        if #matches > 0 then
            local hintSuffix = NS.Scanner:IsAuctionHouseOpen() and "  (Enter = Live AH)" or ""
            RenderSearchPopup("Quick Matches" .. hintSuffix, matches)
        elseif NS.Scanner:IsAuctionHouseOpen() then
            RenderSearchPopup("Press Enter or click 'Search AH' for live AH results", {})
        else
            RenderSearchPopup("Not in local cache - open AH & click 'Search AH', or Shift-click item", {})
        end
    end)

    watchCurrentBtn:SetScript("OnClick", function()
        local lastID = NS.Scanner:GetLastViewedItemID()
        if lastID then
            AddItemAndSelect(lastID)
        else
            NS.Print("View an item in the Auction House first, then click '+ AH' to watch it.")
        end
    end)

    -- Drag-and-drop receiver
    local function TryReceiveDraggedItem()
        if not GetCursorInfo then return false end
        local infoType, itemID = GetCursorInfo()
        if infoType == "item" and itemID then
            ClearCursor()
            AddItemAndSelect(itemID)
            return true
        end
        return false
    end

    addEB:SetScript("OnReceiveDrag", TryReceiveDraggedItem)
    addEB:SetScript("OnMouseUp", TryReceiveDraggedItem)

    -- Row 3: Goblin & Dip-Finder Filter Strip (All | Flips | 24h | 7d | 30d | Invest)
    local lowFilterBar = CreateFrame("Frame", nil, leftPane)
    lowFilterBar:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 8, -62)
    lowFilterBar:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -8, -62)
    lowFilterBar:SetHeight(20)

    local lowSpecs = {
        { id = "NONE",   label = "All",    width = 34 },
        { id = "FLIPS",  label = "Flips",  width = 46 },
        { id = "24H",    label = "24hL",   width = 44, syncTf = "1D" },
        { id = "7D",     label = "7dL",    width = 40, syncTf = "7D" },
        { id = "30D",    label = "30dL",   width = 44, syncTf = "30D" },
        { id = "INVEST", label = "Invest", width = 64 },
    }
    local lowButtons = {}
    local prevLowBtn = nil
    for i = 1, #lowSpecs do
        local spec = lowSpecs[i]
        local b = NS.CreateButton(lowFilterBar, spec.label, spec.width, 20, false)
        if not prevLowBtn then
            b:SetPoint("LEFT", lowFilterBar, "LEFT", 0, 0)
        else
            b:SetPoint("LEFT", prevLowBtn, "RIGHT", 4, 0)
        end
        b:SetScript("OnClick", function()
            if selectedLowFilter == spec.id and spec.id ~= "NONE" then
                selectedLowFilter = "NONE"
            else
                selectedLowFilter = spec.id
                if spec.syncTf then
                    selectedTimeframe = spec.syncTf
                    NS.DB:GetSettings().defaultTimeframe = spec.syncTf
                end
            end
            UI.RefreshWatchlist()
            UI.RefreshDetail()
        end)
        lowButtons[spec.id] = b
        prevLowBtn = b
    end
    root._lowButtons = lowButtons

    -- Clickable Classic WoW AH Column Header Bar above Watchlist (Sort A-Z/Z-A, Buyout, 7D)
    local colHeader = NS.CreatePanel(leftPane, nil, NS.COLORS.BG_HEADER, NS.COLORS.BORDER, true)
    colHeader:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 8, -86)
    colHeader:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -8, -86)
    colHeader:SetHeight(20)

    local function MakeSortHeader(parentBar, align, width, label, onClick)
        local b = CreateFrame("Button", nil, parentBar)
        b:SetSize(width, 18)
        local t = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t:SetAllPoints()
        t:SetJustifyH(align)
        t:SetText(label)
        b.txt = t
        b:SetScript("OnEnter", function(s) s.txt:SetTextColor(1, 1, 1, 1) end)
        b:SetScript("OnLeave", function(s) s.txt:SetTextColor(1, 0.82, 0, 1) end)
        b:SetScript("OnClick", onClick)
        return b
    end

    local hdrNameBtn = MakeSortHeader(colHeader, "LEFT", 136, "Item", function()
        if selectedSort == "name_asc" then
            selectedSort = "name_desc"
        else
            selectedSort = "name_asc"
        end
        NS.DB:GetSettings().defaultSort = selectedSort
        root._sortDropdown:SetSelected(selectedSort, false)
        UI.RefreshWatchlist()
    end)
    hdrNameBtn:SetPoint("LEFT", colHeader, "LEFT", 8, 0)
    root._hdrNameBtn = hdrNameBtn

    local hdrPriceBtn = MakeSortHeader(colHeader, "RIGHT", 94, "Min Buyout", function()
        if selectedSort == "price_desc" then
            selectedSort = "price_asc"
        else
            selectedSort = "price_desc"
        end
        NS.DB:GetSettings().defaultSort = selectedSort
        root._sortDropdown:SetSelected(selectedSort, false)
        UI.RefreshWatchlist()
    end)
    hdrPriceBtn:SetPoint("RIGHT", colHeader, "RIGHT", -44, 0)
    root._hdrPriceBtn = hdrPriceBtn

    local hdrTrendBtn = MakeSortHeader(colHeader, "RIGHT", 36, "7D", function()
        selectedSort = "delta"
        NS.DB:GetSettings().defaultSort = selectedSort
        root._sortDropdown:SetSelected(selectedSort, false)
        UI.RefreshWatchlist()
    end)
    hdrTrendBtn:SetPoint("RIGHT", colHeader, "RIGHT", -6, 0)
    root._hdrTrendBtn = hdrTrendBtn

    -- Classic WoW AH Scrollable List Container with Native Bronze Scrollbar
    local listContainer = NS.CreatePanel(leftPane, nil, NS.COLORS.BG_DARK, NS.COLORS.BORDER, false)
    listContainer:SetPoint("TOPLEFT", colHeader, "BOTTOMLEFT", 0, -2)
    listContainer:SetPoint("BOTTOMRIGHT", leftPane, "BOTTOMRIGHT", -8, 28)
    listContainer:EnableMouse(true)
    listContainer:SetScript("OnReceiveDrag", TryReceiveDraggedItem)
    listContainer:SetScript("OnMouseUp", TryReceiveDraggedItem)

    local scrollFrame = CreateFrame("ScrollFrame", "ForeverMarketWatchListScroll", listContainer, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 5, -5)
    scrollFrame:SetPoint("BOTTOMRIGHT", listContainer, "BOTTOMRIGHT", -25, 5)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(282)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)

    scrollFrame:SetScript("OnSizeChanged", function(_, w)
        if w and w > 40 then
            scrollChild:SetWidth(w)
        end
    end)

    local emptyListText = listContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyListText:SetPoint("CENTER", listContainer, "CENTER", -8, 0)
    emptyListText:SetWidth(240)
    emptyListText:SetJustifyH("CENTER")
    emptyListText:SetText("No items in this view.\n\nUse the Search box above, drag from bags,\nor click Settings -> Restore Profession Mats.")
    root._emptyListText = emptyListText

    -- Left Pane Footer (Market Scope Badge)
    local marketFooter = leftPane:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    marketFooter:SetPoint("BOTTOMLEFT", leftPane, "BOTTOMLEFT", 10, 9)
    marketFooter:SetPoint("BOTTOMRIGHT", leftPane, "BOTTOMRIGHT", -10, 9)
    marketFooter:SetJustifyH("LEFT")
    root._marketFooter = marketFooter

    root._scrollFrame = scrollFrame
    root._scrollChild = scrollChild
    root._tickerRows = {}

    ----------------------------------------------------------------------------
    -- RIGHT PANE: Classic AH Detail Header + Action Bar + Chart + KPI Footer
    ----------------------------------------------------------------------------
    local rightPane = NS.CreatePanel(marketPage, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, false)
    rightPane:SetPoint("TOPLEFT", leftPane, "TOPRIGHT", 6, 0)
    rightPane:SetPoint("BOTTOMRIGHT", marketPage, "BOTTOMRIGHT", 0, 0)
    root._rightPane = rightPane

    -- 1. Selected Item Header Card (includes Item Group Dropdown so Action Bar never clips!)
    local headerCard = NS.CreatePanel(rightPane, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER, false)
    headerCard:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 8, -8)
    headerCard:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -8, -8)
    headerCard:SetHeight(68)

    local iconBorder = NS.CreatePanel(headerCard, nil, NS.COLORS.BG_DARK, NS.COLORS.BORDER_ACCENT, true)
    iconBorder:SetSize(44, 44)
    iconBorder:SetPoint("LEFT", headerCard, "LEFT", 10, 0)

    local itemIcon = iconBorder:CreateTexture(nil, "ARTWORK")
    itemIcon:SetPoint("TOPLEFT", 2, -2)
    itemIcon:SetPoint("BOTTOMRIGHT", -2, 2)
    itemIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    root._detailIcon = itemIcon

    local itemNameTxt = headerCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    itemNameTxt:SetPoint("TOPLEFT", iconBorder, "TOPRIGHT", 10, -1)
    itemNameTxt:SetPoint("RIGHT", headerCard, "RIGHT", -185, 0)
    itemNameTxt:SetJustifyH("LEFT")
    itemNameTxt:SetWordWrap(false)
    root._detailName = itemNameTxt

    local itemGroupDrop = NS.CreateDropdown(headerCard, 102, 19, function(groupVal)
        if selectedItemID then
            NS.DB:SetItemGroup(selectedItemID, groupVal)
        end
    end)
    itemGroupDrop:SetPoint("BOTTOMLEFT", iconBorder, "BOTTOMRIGHT", 10, -2)
    root._itemGroupDrop = itemGroupDrop

    local pinBtn = NS.CreateButton(headerCard, "Pin", 48, 19, false)
    pinBtn:SetPoint("LEFT", itemGroupDrop, "RIGHT", 4, 0)
    pinBtn:SetScript("OnClick", function()
        if selectedItemID then
            NS.DB:TogglePin(selectedItemID)
        end
    end)
    root._pinBtn = pinBtn

    local itemSubTxt = headerCard:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    itemSubTxt:SetPoint("LEFT", pinBtn, "RIGHT", 6, 0)
    itemSubTxt:SetPoint("RIGHT", headerCard, "RIGHT", -155, 0)
    itemSubTxt:SetJustifyH("LEFT")
    itemSubTxt:SetWordWrap(false)
    root._detailSub = itemSubTxt

    local itemPriceTxt = headerCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    itemPriceTxt:SetPoint("TOPRIGHT", headerCard, "TOPRIGHT", -10, -10)
    itemPriceTxt:SetJustifyH("RIGHT")
    root._detailPrice = itemPriceTxt

    local itemDeltaTxt = headerCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    itemDeltaTxt:SetPoint("BOTTOMRIGHT", headerCard, "BOTTOMRIGHT", -10, 10)
    itemDeltaTxt:SetJustifyH("RIGHT")
    root._detailDelta = itemDeltaTxt

    -- 2. Action Toolbar (7 cleanly spaced Classic buttons â€” zero clipping inside AH frame!)
    local actionBar = CreateFrame("Frame", nil, rightPane)
    actionBar:SetPoint("TOPLEFT", headerCard, "BOTTOMLEFT", 0, -6)
    actionBar:SetPoint("TOPRIGHT", headerCard, "BOTTOMRIGHT", 0, -6)
    actionBar:SetHeight(24)
    root._actionBar = actionBar

    local scanAllBtn = NS.CreateButton(actionBar, "Scan", 68, 22, true)
    scanAllBtn:SetPoint("LEFT", actionBar, "LEFT", 0, 0)
    root._scanAllBtn = scanAllBtn

    local scanItemBtn = NS.CreateButton(actionBar, "Item", 52, 22, false)
    scanItemBtn:SetPoint("LEFT", scanAllBtn, "RIGHT", 4, 0)
    root._scanItemBtn = scanItemBtn

    local quickBuyBtn = NS.CreateButton(actionBar, "Buy", 48, 22, false)
    quickBuyBtn:SetPoint("LEFT", scanItemBtn, "RIGHT", 4, 0)
    root._quickBuyBtn = quickBuyBtn

    local settingsBtn = NS.CreateButton(actionBar, "Settings", 62, 22, false)
    settingsBtn:SetPoint("RIGHT", actionBar, "RIGHT", 0, 0)

    local targetsBtn = NS.CreateButton(actionBar, "Targets", 58, 22, false)
    targetsBtn:SetPoint("RIGHT", settingsBtn, "LEFT", -4, 0)
    root._targetsBtn = targetsBtn

    local craftsBtn = NS.CreateButton(actionBar, "Crafts", 54, 22, false)
    craftsBtn:SetPoint("RIGHT", targetsBtn, "LEFT", -4, 0)
    root._craftsBtn = craftsBtn

    local investBtn = NS.CreateButton(actionBar, "Invest", 56, 22, true)
    investBtn:SetPoint("RIGHT", craftsBtn, "LEFT", -4, 0)
    root._investBtn = investBtn

    -- Slim scan progress bar
    local progressBg = NS.CreatePanel(rightPane, nil, NS.COLORS.BG_DARK, NS.COLORS.BORDER, true)
    progressBg:SetPoint("TOPLEFT", actionBar, "BOTTOMLEFT", 0, -4)
    progressBg:SetPoint("TOPRIGHT", actionBar, "BOTTOMRIGHT", 0, -4)
    progressBg:SetHeight(16)
    progressBg:Hide()

    local progressFill = progressBg:CreateTexture(nil, "ARTWORK")
    progressFill:SetPoint("TOPLEFT", progressBg, "TOPLEFT", 1, -1)
    progressFill:SetPoint("BOTTOMLEFT", progressBg, "BOTTOMLEFT", 1, 1)
    progressFill:SetWidth(1)
    progressFill:SetColorTexture(0.85, 0.65, 0.18, 0.60)

    local progressLbl = progressBg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    progressLbl:SetPoint("CENTER", progressBg, "CENTER", 0, 0)
    root._progressBg = progressBg
    root._progressFill = progressFill
    root._progressLbl = progressLbl

    -- 3. Chart Controls Row (Timeframe Pills + Chart Mode Dropdown 1-4, zero clipping)
    local chartCtrlBar = CreateFrame("Frame", nil, rightPane)
    chartCtrlBar:SetPoint("TOPLEFT", actionBar, "BOTTOMLEFT", 0, -8)
    chartCtrlBar:SetPoint("TOPRIGHT", actionBar, "BOTTOMRIGHT", 0, -8)
    chartCtrlBar:SetHeight(24)
    root._chartCtrlBar = chartCtrlBar

    local tfWidths = { ["1D"] = 34, ["7D"] = 34, ["30D"] = 38, ["90D"] = 38, ["All"] = 34 }
    local tfButtons = {}
    local prevTf = nil
    for i = 1, #NS.TIMEFRAMES do
        local tf = NS.TIMEFRAMES[i]
        local b = NS.CreateButton(chartCtrlBar, tf, tfWidths[tf] or 36, 22, false)
        if not prevTf then
            b:SetPoint("LEFT", chartCtrlBar, "LEFT", 0, 0)
        else
            b:SetPoint("LEFT", prevTf, "RIGHT", 3, 0)
        end
        b:SetScript("OnClick", function()
            selectedTimeframe = tf
            NS.DB:GetSettings().defaultTimeframe = tf
            UI.RefreshDetail()
        end)
        tfButtons[tf] = b
        prevTf = b
    end
    root._tfButtons = tfButtons

    local chartModeDropdown = NS.CreateDropdown(chartCtrlBar, 202, 22, function(modeId)
        selectedChartMode = modeId
        NS.DB:GetSettings().defaultChartMode = modeId
        UI.RefreshDetail()
    end)
    chartModeDropdown:SetPoint("RIGHT", chartCtrlBar, "RIGHT", 0, 0)

    do
        local mOpts = {}
        for i = 1, #NS.CHART_MODES do
            table.insert(mOpts, {
                value = NS.CHART_MODES[i].id,
                label = NS.CHART_MODES[i].label,
                shortLabel = NS.CHART_MODES[i].label,
            })
        end
        chartModeDropdown:SetOptions(mOpts)
        chartModeDropdown:SetSelected(selectedChartMode, false)
    end
    root._chartModeDropdown = chartModeDropdown

    -- 4. Bottom 2-Row Goblin KPI Summary Dashboard (10 metrics: Market + Flipping + Investment)
    local statsStrip = NS.CreatePanel(rightPane, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER, false)
    statsStrip:SetPoint("BOTTOMLEFT", rightPane, "BOTTOMLEFT", 8, 8)
    statsStrip:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", -8, 8)
    statsStrip:SetHeight(72)

    local statRow1Keys = {
        { id = "low",   title = "Period Low" },
        { id = "high",  title = "Period High" },
        { id = "avg7",  title = "7D Avg" },
        { id = "roi",   title = "Net Flip (5%)" },
        { id = "swing", title = "7D Swing / Liq" },
    }
    local statRow2Keys = {
        { id = "be",      title = "Break-Even" },
        { id = "wall",    title = "Dip Wall (+10%)" },
        { id = "supply",  title = "Total Supply" },
        { id = "invQty",  title = "My Invest" },
        { id = "invPnl",  title = "Unrealized P&L" },
    }
    root._statValues = {}
    local row1Cols, row2Cols = {}, {}

    local function BuildStatRow(keys, outCols)
        for i = 1, #keys do
            local col = CreateFrame("Frame", nil, statsStrip)
            local tLbl = col:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            tLbl:SetPoint("TOP", col, "TOP", 0, -2)
            tLbl:SetText(keys[i].title)

            local vLbl = col:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            vLbl:SetPoint("BOTTOM", col, "BOTTOM", 0, 2)
            vLbl:SetText("--")

            root._statValues[keys[i].id] = vLbl
            outCols[i] = col
        end
    end

    BuildStatRow(statRow1Keys, row1Cols)
    BuildStatRow(statRow2Keys, row2Cols)

    local rowDivider = statsStrip:CreateTexture(nil, "ARTWORK")
    rowDivider:SetPoint("LEFT", statsStrip, "LEFT", 8, 0)
    rowDivider:SetPoint("RIGHT", statsStrip, "RIGHT", -8, 0)
    rowDivider:SetHeight(1)
    rowDivider:SetColorTexture(NS.COLORS.BORDER[1], NS.COLORS.BORDER[2], NS.COLORS.BORDER[3], 0.45)

    local function LayoutStatCols()
        local totalW = statsStrip:GetWidth() or 520
        local colW = math.max(50, (totalW - 8) / #row1Cols)
        for i = 1, #row1Cols do
            row1Cols[i]:ClearAllPoints()
            row1Cols[i]:SetPoint("TOPLEFT", statsStrip, "TOPLEFT", 4 + (i - 1) * colW, -4)
            row1Cols[i]:SetSize(colW, 30)

            row2Cols[i]:ClearAllPoints()
            row2Cols[i]:SetPoint("BOTTOMLEFT", statsStrip, "BOTTOMLEFT", 4 + (i - 1) * colW, 4)
            row2Cols[i]:SetSize(colW, 30)
        end
    end
    statsStrip:SetScript("OnSizeChanged", LayoutStatCols)
    LayoutStatCols()

    -- 5. Inline Underlying Mats Sparkline Strip (auto-shown whenever a crafted item is selected!)
    local matsStrip = NS.CreatePanel(rightPane, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, false)
    matsStrip:SetPoint("BOTTOMLEFT", statsStrip, "TOPLEFT", 0, 6)
    matsStrip:SetPoint("BOTTOMRIGHT", statsStrip, "TOPRIGHT", 0, 6)
    matsStrip:SetHeight(74)
    matsStrip:Hide()
    root._matsStrip = matsStrip

    local matsHdrTxt = matsStrip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    matsHdrTxt:SetPoint("TOPLEFT", 8, -5)
    matsHdrTxt:SetPoint("TOPRIGHT", -94, -5)
    matsHdrTxt:SetJustifyH("LEFT")
    matsHdrTxt:SetWordWrap(false)
    root._matsHdrTxt = matsHdrTxt

    local matLineBtn = NS.CreateButton(matsStrip, "Mat Line: ON", 84, 17, false)
    matLineBtn:SetPoint("TOPRIGHT", -6, -3)
    matLineBtn:SetScript("OnClick", function()
        showCraftCostOverlay = not showCraftCostOverlay
        UI.RefreshDetail()
    end)
    root._matLineBtn = matLineBtn

    local matsCardsHost = CreateFrame("Frame", nil, matsStrip)
    matsCardsHost:SetPoint("TOPLEFT", 6, -22)
    matsCardsHost:SetPoint("BOTTOMRIGHT", -6, 5)
    root._matsCardsHost = matsCardsHost
    root._inlineMatCards = {}

    -- 6. Interactive Chart Canvas
    local chartWidget = NS.Chart.Create(rightPane)
    chartWidget:SetPoint("TOPLEFT", chartCtrlBar, "BOTTOMLEFT", 0, -8)
    chartWidget:SetPoint("BOTTOMRIGHT", statsStrip, "TOPRIGHT", 0, 8)
    root._chart = chartWidget

    -- Popovers (parented to UIParent at FULLSCREEN_DIALOG strata so reparenting never blocks clicks)
    root._targetsPopover  = CreateTargetsPopover()
    root._groupsPopover   = CreateGroupsPopover()
    root._settingsPopover = CreateSettingsPopover()
    root._investPopover   = CreateInvestPopover()
    root._craftsPopover   = CreateCraftsPopover()
    root._matsHoverCard   = CreateMatsHoverCard()

    ----------------------------------------------------------------------------
    -- Wire Up Toolbar Actions & Callbacks
    ----------------------------------------------------------------------------

    groupsBtn:SetScript("OnClick", function(self)
        root._groupsPopover:OpenAt(self)
    end)

    targetsBtn:SetScript("OnClick", function(self)
        if selectedItemID then
            root._targetsPopover:OpenForItem(self, selectedItemID)
        end
    end)

    investBtn:SetScript("OnClick", function(self)
        if selectedItemID then
            root._investPopover:OpenForItem(self, selectedItemID)
        end
    end)

    craftsBtn:SetScript("OnClick", function(self)
        root._craftsPopover:OpenAt(self)
    end)

    settingsBtn:SetScript("OnClick", function(self)
        root._settingsPopover:OpenAt(self)
    end)

    scanAllBtn:SetScript("OnClick", function()
        if NS.Scanner:IsScanning() then
            NS.Scanner:StopScan("USER_STOP")
        else
            local groupFilter = (selectedGroupFilter ~= "All" and selectedGroupFilter ~= "Alerts Only") and selectedGroupFilter or nil
            NS.Scanner:StartWatchlistScan(false, groupFilter)
        end
    end)

    scanItemBtn:SetScript("OnClick", function()
        if selectedItemID then
            NS.Scanner:ScanSingleItem(selectedItemID)
        end
    end)

    quickBuyBtn:SetScript("OnClick", function()
        if selectedItemID then
            NS.Scanner:JumpToItemInAH(selectedItemID)
        end
    end)

    root:SetScript("OnHide", CloseAllPopovers)

    -- Subscribe to addon events (debounced HISTORY_UPDATED so rapid batch scans never freeze FPS)
    NS:RegisterCallback("DATA_UPDATED", function() UI.RefreshAll() end)
    NS:RegisterCallback("GROUPS_UPDATED", function() UI.RefreshGroups() end)

    local pendingHistoryRefresh = false
    local pendingHistoryItemID = nil
    NS:RegisterCallback("HISTORY_UPDATED", function(itemID)
        if not mainView or not mainView:IsShown() then return end
        if itemID == selectedItemID then
            pendingHistoryItemID = itemID
        end
        if pendingHistoryRefresh then return end
        pendingHistoryRefresh = true
        if C_Timer and C_Timer.After then
            C_Timer.After(0.30, function()
                pendingHistoryRefresh = false
                local needDetail = (pendingHistoryItemID == selectedItemID)
                pendingHistoryItemID = nil
                if mainView and mainView:IsShown() then
                    if selectedPage == "DASHBOARD" then
                        mainView._dashboardPage:Refresh()
                    elseif selectedPage == "FLIPPING" then
                        if mainView._flippingPage then mainView._flippingPage:Refresh() end
                    elseif selectedPage == "INVENTORY" then
                        if mainView._inventoryPage then mainView._inventoryPage:Refresh() end
                    elseif selectedPage == "LEDGER" then
                        -- Ledger history does not change on price snapshots
                    else
                        UI.RefreshWatchlist()
                        if needDetail then
                            UI.RefreshDetail()
                        end
                    end
                end
            end)
        else
            pendingHistoryRefresh = false
            UI.RefreshWatchlist()
            if itemID == selectedItemID then
                UI.RefreshDetail()
            end
        end
    end)
    NS:RegisterCallback("AH_STATE_CHANGED", function()
        UI.RefreshActionButtons()
        if mainView and mainView:IsShown() and selectedPage == "FLIPPING" and mainView._flippingPage then
            mainView._flippingPage:Refresh()
        end
    end)
    NS:RegisterCallback("LAST_VIEWED_ITEM_CHANGED", function() UI.RefreshActionButtons() end)
    NS:RegisterCallback("SCAN_STATE_CHANGED", function(scanning, idx, total)
        UI.RefreshScanProgress(scanning, idx, total)
        UI.RefreshActionButtons()
        if mainView and mainView:IsShown() and selectedPage == "FLIPPING" and mainView._flippingPage then
            mainView._flippingPage:Refresh()
        end
    end)
    NS:RegisterCallback("SCAN_PROGRESS", function(idx, total, itemID)
        UI.RefreshScanProgress(true, idx, total, itemID)
    end)
    NS:RegisterCallback("AH_SEARCH_RESULTS", function(query, results)
        if mainView and mainView:IsShown() then
            if #results > 0 then
                RenderSearchPopup(string.format("Live AH Results for '%s' (%d)", query, #results), results)
            else
                local fallback = NS.DB:SearchOfflineItems(query, 8)
                RenderSearchPopup("No live AH listings for '" .. query .. "' (showing catalog):", fallback)
            end
        end
    end)

    -- Refresh metadata (debounced) as WoW finishes loading item icons/names for watched & whole-AH items
    local pendingMetaRefresh = false
    local itemInfoFrame = CreateFrame("Frame")
    itemInfoFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    itemInfoFrame:SetScript("OnEvent", function(_, _, itemID, success)
        if not success or not itemID then return end
        local entry = NS.DB:GetWatchItem(itemID)
        local hist = NS.DB:GetItemHistory(itemID)
        if not entry and not hist then return end

        if entry then
            NS.DB:RefreshItemMetadata(itemID, entry)
        end
        if hist then
            local liveName, _, liveQual, _, _, _, _, _, _, liveIcon = NS.Compat.GetItemInfo(itemID)
            if liveName then
                hist.name = liveName
                hist.quality = liveQual
                hist.icon = liveIcon
            end
        end

        if mainView and mainView:IsShown() and not pendingMetaRefresh then
            pendingMetaRefresh = true
            if C_Timer and C_Timer.After then
                C_Timer.After(0.25, function()
                    pendingMetaRefresh = false
                    if mainView and mainView:IsShown() then
                        UI.RefreshAll()
                    end
                end)
            else
                pendingMetaRefresh = false
                UI.RefreshAll()
            end
        end
    end)

    return root
end

--------------------------------------------------------------------------------
-- Mounting Helper (Shares One Single Workspace Across Standalone & AH Tab)
--------------------------------------------------------------------------------

function UI.ApplyPageVisibility()
    if not mainView then return end
    local isDash   = (selectedPage == "DASHBOARD")
    local isMarket = (selectedPage == "MARKET")
    local isFlip   = (selectedPage == "FLIPPING")
    local isInv    = (selectedPage == "INVENTORY")
    local isLedger = (selectedPage == "LEDGER")

    mainView._dashboardPage:SetShown(isDash)
    mainView._marketPage:SetShown(isMarket)
    if mainView._flippingPage then mainView._flippingPage:SetShown(isFlip) end
    if mainView._inventoryPage then mainView._inventoryPage:SetShown(isInv) end
    if mainView._ledgerPage then mainView._ledgerPage:SetShown(isLedger) end

    mainView._dashTabBtn:SetActiveState(isDash)
    mainView._marketTabBtn:SetActiveState(isMarket)
    if mainView._flipTabBtn then mainView._flipTabBtn:SetActiveState(isFlip) end
    if mainView._invTabBtn then mainView._invTabBtn:SetActiveState(isInv) end
    if mainView._ledgerTabBtn then mainView._ledgerTabBtn:SetActiveState(isLedger) end
end

function UI.MountInto(hostFrame, padLeft, padRight, padTop, padBottom)
    local view = UI.GetOrCreateMainView()
    if activeMountHost == hostFrame and view:GetParent() == hostFrame and view:IsShown() then
        UI.ApplyPageVisibility()
        UI.RefreshAll()
        return view
    end

    CloseAllPopovers()
    activeMountHost = hostFrame
    view:SetParent(hostFrame)
    view:ClearAllPoints()
    view:SetPoint("TOPLEFT", hostFrame, "TOPLEFT", padLeft or 12, -(padTop or 40))
    view:SetPoint("BOTTOMRIGHT", hostFrame, "BOTTOMRIGHT", -(padRight or 12), padBottom or 12)
    view:Show()

    UI.ApplyPageVisibility()
    UI.RefreshAll()
    return view
end

function UI.GetActiveMountHost()
    return activeMountHost
end

--------------------------------------------------------------------------------
-- Refresh Routines
--------------------------------------------------------------------------------

function UI.RefreshGroups()
    if not mainView then return end
    local groups = NS.DB:GetGroups()

    local filterOpts = {
        { value = "All",        label = "All Watchlist" },
        { value = "ENTIRE_AH",  label = "Entire AH (All Scanned)" },
        { value = "Alerts Only", label = "Alerts Only" },
    }
    local itemOpts = {}
    for i = 1, #groups do
        table.insert(filterOpts, { value = groups[i], label = groups[i] })
        table.insert(itemOpts, { value = groups[i], label = groups[i] })
    end

    mainView._groupDropdown:SetOptions(filterOpts)
    mainView._groupDropdown:SetSelected(selectedGroupFilter, false)
    mainView._itemGroupDrop:SetOptions(itemOpts)
end

function UI.RefreshScanProgress(scanning, idx, total, itemID)
    if not mainView then return end
    if scanning then
        mainView._progressBg:Show()
        mainView._chartCtrlBar:ClearAllPoints()
        mainView._chartCtrlBar:SetPoint("TOPLEFT", mainView._progressBg, "BOTTOMLEFT", 0, -6)
        mainView._chartCtrlBar:SetPoint("TOPRIGHT", mainView._progressBg, "BOTTOMRIGHT", 0, -6)

        local frac = (total and total > 0) and math.min(1, (idx or 0) / total) or 0
        local maxW = math.max(1, (mainView._progressBg:GetWidth() or 200) - 2)
        mainView._progressFill:SetWidth(math.max(1, math.floor(maxW * frac)))

        local entry = itemID and NS.DB:GetWatchItem(itemID)
        local itemLabel = entry and entry.name or (itemID and ("Item #" .. itemID) or "Starting...")
        mainView._progressLbl:SetText(string.format("Scanning %d / %d â€” %s", idx or 0, total or 0, itemLabel))
    else
        mainView._progressBg:Hide()
        mainView._chartCtrlBar:ClearAllPoints()
        mainView._chartCtrlBar:SetPoint("TOPLEFT", mainView._actionBar, "BOTTOMLEFT", 0, -8)
        mainView._chartCtrlBar:SetPoint("TOPRIGHT", mainView._actionBar, "BOTTOMRIGHT", 0, -8)
    end
end

function UI.RefreshActionButtons()
    if not mainView then return end
    local ahOpen = NS.Scanner:IsAuctionHouseOpen()
    local scanning = NS.Scanner:IsScanning()
    local isDemo = NS.DB:IsDemoMode()
    local isWatched = selectedItemID ~= nil and NS.DB:GetWatchItem(selectedItemID) ~= nil
    local hasSelection = selectedItemID ~= nil and (isWatched or NS.DB:GetItemHistory(selectedItemID) ~= nil)

    if scanning then
        mainView._scanAllBtn:SetTextLabel("Stop")
        mainView._scanAllBtn:SetEnabledState(true)
    else
        local isGroupScoped = (selectedGroupFilter ~= "All" and selectedGroupFilter ~= "ENTIRE_AH" and selectedGroupFilter ~= "Alerts Only")
        mainView._scanAllBtn:SetTextLabel(isGroupScoped and "Scan Grp" or "Scan All")
        mainView._scanAllBtn:SetEnabledState(ahOpen and not isDemo)
    end

    mainView._scanItemBtn:SetEnabledState(ahOpen and not isDemo and hasSelection)
    mainView._quickBuyBtn:SetEnabledState(ahOpen and not isDemo and hasSelection)
    mainView._targetsBtn:SetEnabledState(isWatched)
    mainView._investBtn:SetEnabledState(hasSelection)
    mainView._itemGroupDrop:SetEnabledState(isWatched)
    if mainView._pinBtn then
        mainView._pinBtn:SetEnabledState(hasSelection)
        local pinned = selectedItemID and NS.DB:IsPinned(selectedItemID)
        mainView._pinBtn:SetTextLabel(pinned and "Pinned" or "Pin")
        mainView._pinBtn:SetActiveState(pinned)
    end
    mainView._watchCurrentBtn:SetEnabledState(NS.Scanner:GetLastViewedItemID() ~= nil)
    mainView._searchAHBtn:SetTextLabel(ahOpen and "Search AH" or "Search")
end

function UI.RefreshWatchlist()
    if not mainView then return end

    -- Highlight active Low-filter button
    if mainView._lowButtons then
        for id, btn in pairs(mainView._lowButtons) do
            btn:SetActiveState(id == selectedLowFilter)
        end
    end

    local market = NS.DB:GetActiveMarket()
    local watchlist = market.watchlist or {}
    local allHistory = market.history or {}
    local items = {}

    -- Whole-AH mode: when viewing 'Flips' (with All/Entire AH) or 'Entire AH' group,
    -- scan EVERY item synced from Blizzard's API across the entire Auction House!
    local scanWholeAH = (selectedGroupFilter == "ENTIRE_AH")
        or (selectedLowFilter == "FLIPS" and selectedGroupFilter == "All")
        or (selectedLowFilter == "INVEST")

    local function BuildEntryForItem(itemID)
        local w = watchlist[itemID]
        if w then return w, true end
        local h = allHistory[itemID]
        local liveName, _, liveQual, _, _, _, _, _, _, liveIcon = NS.Compat.GetItemInfo(itemID)
        if not liveName then
            NS.Compat.RequestLoadItemDataByID(itemID)
        end
        local name = liveName or (h and h.name) or ("Item #" .. tostring(itemID))
        local icon = liveIcon or (h and h.icon) or NS.Compat.GetItemIconByID(itemID) or 134400
        local quality = (liveQual ~= nil) and liveQual or ((h and h.quality) or 1)
        if h and liveName then
            h.name = liveName
            h.icon = icon
            h.quality = quality
        end
        return {
            itemID  = itemID,
            name    = name,
            icon    = icon,
            quality = quality,
            group   = "AH Market",
        }, false
    end

    local sourceIDs = {}
    local seenID = {}
    if scanWholeAH then
        for itemID in pairs(allHistory) do
            seenID[itemID] = true
            table.insert(sourceIDs, itemID)
        end
        for itemID in pairs(watchlist) do
            if not seenID[itemID] then
                seenID[itemID] = true
                table.insert(sourceIDs, itemID)
            end
        end
        if selectedLowFilter == "INVEST" and market.investments then
            for itemID in pairs(market.investments) do
                if not seenID[itemID] then
                    seenID[itemID] = true
                    table.insert(sourceIDs, itemID)
                end
            end
        end
    else
        for itemID in pairs(watchlist) do
            table.insert(sourceIDs, itemID)
        end
    end

    for idx = 1, #sourceIDs do
        local itemID = sourceIDs[idx]
        local entry, isWatched = BuildEntryForItem(itemID)
        local hist = allHistory[itemID]
        local summary = NS.Analytics.GetItemSummary(entry, hist, selectedTimeframe)

        local include = true
        if selectedGroupFilter == "Alerts Only" then
            include = isWatched and (summary.alert == "BUY" or summary.alert == "SELL")
        elseif selectedGroupFilter ~= "All" and selectedGroupFilter ~= "ENTIRE_AH" then
            include = isWatched and (entry.group == selectedGroupFilter)
        end

        if include and selectedLowFilter ~= "NONE" then
            if selectedLowFilter == "FLIPS" then
                include = summary.isHotFlip
            elseif selectedLowFilter == "24H" then
                include = summary.low24h
            elseif selectedLowFilter == "7D" then
                include = summary.low7d
            elseif selectedLowFilter == "30D" then
                include = summary.low30d
            elseif selectedLowFilter == "INVEST" then
                include = (summary.investQty and summary.investQty > 0)
            end
        end

        if include then
            table.insert(items, {
                itemID    = itemID,
                entry     = entry,
                isWatched = isWatched,
                summary   = summary,
            })
        end
    end

    -- Update clickable column header sort indicators
    if mainView._hdrNameBtn then
        if selectedSort == "name_asc" then
            mainView._hdrNameBtn.txt:SetText("Item ^")
        elseif selectedSort == "name_desc" then
            mainView._hdrNameBtn.txt:SetText("Item v")
        else
            mainView._hdrNameBtn.txt:SetText("Item")
        end
    end
    if mainView._hdrPriceBtn then
        if selectedSort == "price_desc" then
            mainView._hdrPriceBtn.txt:SetText("Min Buyout v")
        elseif selectedSort == "price_asc" then
            mainView._hdrPriceBtn.txt:SetText("Min Buyout ^")
        else
            mainView._hdrPriceBtn.txt:SetText("Min Buyout")
        end
    end
    if mainView._hdrTrendBtn then
        mainView._hdrTrendBtn.txt:SetText(selectedSort == "delta" and "7D ^" or "7D")
    end

    table.sort(items, function(a, b)
        local aName = (a.entry.name or ""):lower()
        local bName = (b.entry.name or ""):lower()

        local effectiveSort = (selectedLowFilter == "FLIPS" and selectedSort == "name_asc") and "roi_desc" or selectedSort

        if effectiveSort == "roi_desc" then
            local ar = a.summary.bestFlipRoiPct or -999999
            local br = b.summary.bestFlipRoiPct or -999999
            if ar ~= br then return ar > br end
            return aName < bName
        elseif effectiveSort == "swing_desc" then
            local as = a.summary.swing7dPct or -1
            local bs = b.summary.swing7dPct or -1
            if as ~= bs then return as > bs end
            return aName < bName
        elseif effectiveSort == "name_asc" or effectiveSort == "name" then
            if aName ~= bName then return aName < bName end
            return a.itemID < b.itemID
        elseif selectedSort == "name_desc" then
            if aName ~= bName then return aName > bName end
            return a.itemID > b.itemID
        elseif selectedSort == "price_desc" or selectedSort == "price" then
            local ap = a.summary.latestMin or -1
            local bp = b.summary.latestMin or -1
            if ap ~= bp then return ap > bp end
            return aName < bName
        elseif selectedSort == "price_asc" then
            local aHas = a.summary.latestMin ~= nil
            local bHas = b.summary.latestMin ~= nil
            if aHas ~= bHas then return aHas end -- Priced items always sort before unscanned '--' items
            if aHas and a.summary.latestMin ~= b.summary.latestMin then
                return a.summary.latestMin < b.summary.latestMin
            end
            return aName < bName
        elseif selectedSort == "alerts" then
            local aRank = (a.summary.alert ~= "NONE") and 0 or 1
            local bRank = (b.summary.alert ~= "NONE") and 0 or 1
            if aRank ~= bRank then return aRank < bRank end
            local aHas = a.summary.latestMin and 0 or 1
            local bHas = b.summary.latestMin and 0 or 1
            if aHas ~= bHas then return aHas < bHas end
            return aName < bName
        elseif selectedSort == "delta" then
            local ad = a.summary.delta7dPct or 999999
            local bd = b.summary.delta7dPct or 999999
            if ad ~= bd then return ad < bd end
            return aName < bName
        else
            return aName < bName
        end
    end)

    local selectedInFiltered = false
    for i = 1, #items do
        if items[i].itemID == selectedItemID then
            selectedInFiltered = true
            break
        end
    end
    local selectedValid = selectedItemID and (watchlist[selectedItemID] ~= nil or allHistory[selectedItemID] ~= nil)
    if not selectedValid or (selectedLowFilter ~= "NONE" and not selectedInFiltered) then
        selectedItemID = (#items > 0) and items[1].itemID or nil
    end

    -- Cap visible rows at 250 when browsing the Entire AH so UI stays silky smooth at 60 FPS
    local visibleCount = math.min(#items, 250)
    local rowH = 42
    local child = mainView._scrollChild
    local rows = mainView._tickerRows

    mainView._emptyListText:SetShown(#items == 0)
    if #items == 0 then
        if selectedLowFilter == "INVEST" then
            mainView._emptyListText:SetText("No explicit investments logged yet.\n\nSelect any item and click 'Invest' to log lots across all your alts (personal gear/bags are never mixed in).")
        elseif selectedLowFilter == "FLIPS" then
            mainView._emptyListText:SetText("No mispriced flips (+20% live undercut or +15% 7D dip after 5% AH cut) right now.\n\nTry /fmw demo or wait for next 5-min API sync.")
        elseif selectedLowFilter ~= "NONE" then
            mainView._emptyListText:SetText("No items currently at a " .. selectedLowFilter .. " low.\n\nRequires at least 2 scans with price movement.\nClick 'All' or run /fmw demo to preview.")
        else
            mainView._emptyListText:SetText("No items in this view.\n\nUse the Search box above, drag from bags,\nor click Settings -> Restore Profession Mats.")
        end
    end

    for i = 1, visibleCount do
        local data = items[i]
        local entry = data.entry
        local sum = data.summary
        local row = rows[i]

        if not row then
            row = CreateFrame("Button", nil, child)
            row:SetHeight(rowH - 1)

            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            row.bg = bg

            -- Classic WoW AH golden highlight bar
            local hl = row:CreateTexture(nil, "ARTWORK")
            hl:SetAllPoints()
            hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            hl:SetBlendMode("ADD")
            hl:SetAlpha(0)
            row.hl = hl

            local accentBar = row:CreateTexture(nil, "OVERLAY")
            accentBar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
            accentBar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
            accentBar:SetWidth(3)
            row.accentBar = accentBar

            -- Classic slot border around item icon
            local iconBg = row:CreateTexture(nil, "BORDER")
            iconBg:SetSize(30, 30)
            iconBg:SetPoint("LEFT", row, "LEFT", 6, 0)
            iconBg:SetColorTexture(0.45, 0.36, 0.22, 0.9)

            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(28, 28)
            icon:SetPoint("CENTER", iconBg, "CENTER", 0, 0)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.icon = icon

            local nameTxt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            nameTxt:SetPoint("TOPLEFT", iconBg, "TOPRIGHT", 6, -1)
            nameTxt:SetPoint("RIGHT", row, "RIGHT", -104, 0)
            nameTxt:SetJustifyH("LEFT")
            nameTxt:SetWordWrap(false)
            row.nameTxt = nameTxt

            local subTxt = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            subTxt:SetPoint("BOTTOMLEFT", iconBg, "BOTTOMRIGHT", 6, 1)
            subTxt:SetPoint("RIGHT", row, "RIGHT", -104, 0)
            subTxt:SetJustifyH("LEFT")
            subTxt:SetWordWrap(false)
            row.subTxt = subTxt

            local priceTxt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            priceTxt:SetPoint("TOPRIGHT", row, "TOPRIGHT", -20, -6)
            priceTxt:SetJustifyH("RIGHT")
            row.priceTxt = priceTxt

            local deltaTxt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            deltaTxt:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -20, 6)
            deltaTxt:SetJustifyH("RIGHT")
            row.deltaTxt = deltaTxt

            local delBtn = CreateFrame("Button", nil, row)
            delBtn:SetSize(16, 16)
            delBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
            local delTxt = delBtn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            delTxt:SetPoint("CENTER")
            delTxt:SetText("x")
            delBtn.txt = delTxt
            delBtn:SetScript("OnEnter", function(s) s.txt:SetTextColor(0.96, 0.35, 0.33, 1) end)
            delBtn:SetScript("OnLeave", function(s) s.txt:SetTextColor(0.65, 0.58, 0.48, 1) end)
            row.delBtn = delBtn

            row:SetScript("OnEnter", function(self)
                self.hl:SetAlpha(0.55)
                if self._itemID and mainView and mainView._matsHoverCard and NS.Arbitrage and NS.Arbitrage.GetRecipeForProduct(self._itemID) then
                    mainView._matsHoverCard:ShowForCraftedItem(self, self._itemID, selectedTimeframe)
                end
            end)
            row:SetScript("OnLeave", function(self)
                self:ApplyRowBg()
                if mainView and mainView._matsHoverCard then
                    mainView._matsHoverCard:Hide()
                end
            end)

            function row:ApplyRowBg()
                local isSel = (self._itemID == selectedItemID)
                local c = isSel and NS.COLORS.BG_ROW_SEL or (((self._index % 2) == 0) and NS.COLORS.BG_ROW_ALT or NS.COLORS.BG_ROW)
                self.bg:SetColorTexture(c[1], c[2], c[3], c[4])
                self.hl:SetAlpha(isSel and 0.35 or 0)
            end

            rows[i] = row
        end

        row._itemID = data.itemID
        row._index = i
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -((i - 1) * rowH))
        row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -((i - 1) * rowH))
        row:ApplyRowBg()

        if sum.alert == "BUY" then
            row.accentBar:SetColorTexture(NS.COLORS.GREEN[1], NS.COLORS.GREEN[2], NS.COLORS.GREEN[3], 1)
        elseif sum.alert == "SELL" then
            row.accentBar:SetColorTexture(NS.COLORS.RED[1], NS.COLORS.RED[2], NS.COLORS.RED[3], 1)
        elseif data.itemID == selectedItemID then
            row.accentBar:SetColorTexture(NS.COLORS.TEXT_GOLD[1], NS.COLORS.TEXT_GOLD[2], NS.COLORS.TEXT_GOLD[3], 1)
        else
            row.accentBar:SetColorTexture(0, 0, 0, 0)
        end

        row.icon:SetTexture(entry.icon or 134400)
        local r, g, b = NS.Compat.GetQualityColor(entry.quality)
        row.nameTxt:SetTextColor(r, g, b, 1)
        row.nameTxt:SetText(entry.name or ("Item #" .. tostring(data.itemID)))

        local alertTag = ""
        if selectedLowFilter == "INVEST" and sum.investQty and sum.investQty > 0 then
            local pClr = (sum.investUnrealizedPnL and sum.investUnrealizedPnL >= 0) and "|cFF38D972" or "|cFFF55954"
            local pPct = sum.investUnrealizedPct and string.format("%s%+.1f%%|r", pClr, sum.investUnrealizedPct) or ""
            row.subTxt:SetText(string.format("Inv:%d (%s)  %s", sum.investQty, (sum.investment and sum.investment.holder) or "Alt", pPct))
        else
            if sum.alert == "BUY" then
                alertTag = " |cFF38D972[BUY]|r"
            elseif sum.alert == "SELL" then
                alertTag = " |cFFF55954[SELL]|r"
            elseif sum.isSnipeFlip then
                alertTag = string.format(" |cFF38D972[SNIPE +%.0f%%]|r", sum.snipeRoiPct or 0)
            elseif sum.isDipFlip then
                alertTag = string.format(" |cFF38D972[DIP +%.0f%%]|r", sum.estRoiPct or 0)
            elseif sum.low30d then
                alertTag = " |cFF38D972[30D]|r"
            elseif sum.low7d then
                alertTag = " |cFF38D972[7D]|r"
            elseif sum.low24h then
                alertTag = " |cFF38D972[24H]|r"
            end
            row.subTxt:SetText(string.format("%s  Qty:%d%s", entry.group or "", sum.latestQty or 0, alertTag))
        end

        -- Full Gold/Silver/Copper price display
        row.priceTxt:SetText(sum.latestMin and NS.FormatMoney(sum.latestMin, false) or "|cFF8A7E6B--|r")
        row.deltaTxt:SetText(FormatDeltaBadge(sum.delta7dPct))

        row:SetScript("OnClick", function()
            selectedItemID = data.itemID
            UI.RefreshWatchlist()
            UI.RefreshDetail()
            UI.RefreshActionButtons()
        end)

        if data.isWatched then
            row.delBtn.txt:SetText("x")
            row.delBtn:SetScript("OnClick", function()
                NS.DB:RemoveWatchItem(data.itemID)
            end)
        else
            -- Unwatched AH market item: '+' pins it straight to your watchlist!
            row.delBtn.txt:SetText("+")
            row.delBtn:SetScript("OnClick", function()
                NS.DB:AddWatchItem(data.itemID, "Flipping", entry.name, entry.icon, entry.quality)
            end)
        end

        row:Show()
    end

    for i = visibleCount + 1, #rows do
        rows[i]:Hide()
    end

    child:SetHeight(math.max(1, visibleCount * rowH))

    local marketTag = NS.DB:GetActiveMarketKey()
    if NS.DB:IsDemoMode() then
        mainView._marketFooter:SetText("|cFFFFD100DEMO PREVIEW|r  (" .. #items .. " items)  |  /fmw demo to exit")
    elseif selectedLowFilter == "INVEST" then
        local port = NS.DB:GetPortfolioSummary()
        local clr = (port.unrealizedPnL >= 0) and "|cFF38D972+" or "|cFFF55954"
        mainView._marketFooter:SetText(string.format("Portfolio: %s  |  P&L: %s%s|r",
            NS.FormatMoney(port.totalInvested, true), clr, NS.FormatMoney(port.unrealizedPnL, true)
        ))
    else
        local apiTs = NS.DB:GetExternalSyncTimestamp()
        local apiTag = (apiTs > 0) and ("  |  |cFF38D972API: " .. NS.FormatRelativeTime(apiTs) .. "|r") or ""
        mainView._marketFooter:SetText(string.format("%s (%d)%s", marketTag, #items, apiTag))
    end
end

function UI.RefreshDetail()
    if not mainView then return end

    for tf, btn in pairs(mainView._tfButtons) do
        btn:SetActiveState(tf == selectedTimeframe)
    end
    mainView._chartModeDropdown:SetSelected(selectedChartMode, false)

    local entry = selectedItemID and NS.DB:GetWatchItem(selectedItemID) or nil
    local hist = selectedItemID and NS.DB:GetItemHistory(selectedItemID) or nil
    if not entry and selectedItemID and hist then
        local liveName, _, liveQual, _, _, _, _, _, _, liveIcon = NS.Compat.GetItemInfo(selectedItemID)
        entry = {
            itemID  = selectedItemID,
            name    = liveName or hist.name or ("Item #" .. tostring(selectedItemID)),
            icon    = liveIcon or hist.icon or NS.Compat.GetItemIconByID(selectedItemID) or 134400,
            quality = (liveQual ~= nil) and liveQual or (hist.quality or 1),
            group   = "AH Market",
        }
    end
    if not entry then
        mainView._detailIcon:SetTexture(134400)
        mainView._detailName:SetText("Select or Search an Item")
        mainView._detailName:SetTextColor(1, 0.82, 0, 1)
        mainView._detailSub:SetText("Search by name above, drag from bags, or run /fmw demo")
        mainView._detailPrice:SetText("--")
        mainView._detailDelta:SetText("")
        mainView._statValues.low:SetText("--")
        mainView._statValues.high:SetText("--")
        mainView._statValues.avg7:SetText("--")
        mainView._statValues.roi:SetText("--")
        mainView._statValues.swing:SetText("--")
        mainView._statValues.be:SetText("--")
        mainView._statValues.wall:SetText("--")
        mainView._statValues.supply:SetText("--")
        mainView._statValues.invQty:SetText("--")
        mainView._statValues.invPnl:SetText("--")
        mainView._matsStrip:Hide()
        mainView._chart:ClearAllPoints()
        mainView._chart:SetPoint("TOPLEFT", mainView._chartCtrlBar, "BOTTOMLEFT", 0, -8)
        mainView._chart:SetPoint("BOTTOMRIGHT", mainView._matsStrip, "BOTTOMRIGHT", 0, 0)
        mainView._chart:SetData({}, {
            chartMode = selectedChartMode,
            timeframe = selectedTimeframe,
            emptyReason = "Select an item on the left (or search above)\nto view its Auction House price history.",
        })
        return
    end

    local hist = NS.DB:GetItemHistory(selectedItemID)
    local sum = NS.Analytics.GetItemSummary(entry, hist, selectedTimeframe)

    mainView._detailIcon:SetTexture(entry.icon or 134400)
    local r, g, b = NS.Compat.GetQualityColor(entry.quality)
    mainView._detailName:SetTextColor(r, g, b, 1)
    mainView._detailName:SetText(entry.name or ("Item #" .. tostring(selectedItemID)))

    local targetNotes = {}
    if entry.buyTarget then
        table.insert(targetNotes, "|cFF38D972Buy <= " .. NS.FormatMoney(entry.buyTarget, true) .. "|r")
    end
    if entry.sellTarget then
        table.insert(targetNotes, "|cFFF55954Sell >= " .. NS.FormatMoney(entry.sellTarget, true) .. "|r")
    end
    local targetStr = (#targetNotes > 0) and ("  |  " .. table.concat(targetNotes, "  ")) or ""

    mainView._detailSub:SetText(string.format(
        "Scan: %s%s",
        NS.FormatRelativeTime(sum.lastScan),
        targetStr
    ))

    mainView._detailPrice:SetText(sum.latestMin and NS.FormatMoney(sum.latestMin, false) or "|cFF8A7E6BNo Data|r")

    local alertSuffix = ""
    if sum.alert == "BUY" then
        alertSuffix = "  |cFF38D972[BUY TARGET HIT]|r"
    elseif sum.alert == "SELL" then
        alertSuffix = "  |cFFF55954[SELL TARGET HIT]|r"
    end
    mainView._detailDelta:SetText("vs 7D Avg: " .. FormatDeltaBadge(sum.delta7dPct) .. alertSuffix)

    mainView._itemGroupDrop:SetSelected(entry.group, false)

    -- Update 2-row Goblin KPI Dashboard
    mainView._statValues.low:SetText(sum.periodLow and NS.FormatMoney(sum.periodLow, true) or "--")
    mainView._statValues.high:SetText(sum.periodHigh and NS.FormatMoney(sum.periodHigh, true) or "--")
    mainView._statValues.avg7:SetText(sum.avg7d and NS.FormatMoney(sum.avg7d, true) or "--")

    if sum.bestFlipRoiPct ~= nil then
        local rClr = (sum.isHotFlip) and "|cFF38D972" or ((sum.bestFlipRoiPct > 0) and "|cFFFFD100" or "|cFFF55954")
        local tag = sum.isSnipeFlip and "S " or ""
        mainView._statValues.roi:SetText(string.format("%s%s%+.1f%%|r", rClr, tag, sum.bestFlipRoiPct))
    else
        mainView._statValues.roi:SetText("--")
    end

    if sum.swing7dPct ~= nil then
        local lClr = (sum.liquidityTier == "High") and "|cFF38D972" or ((sum.liquidityTier == "Med") and "|cFFFFD100" or "|cFFF55954")
        mainView._statValues.swing:SetText(string.format("%.0f%% (%s%s|r)", sum.swing7dPct, lClr, sum.liquidityTier))
    else
        mainView._statValues.swing:SetText(sum.liquidityTier or "--")
    end

    mainView._statValues.be:SetText(sum.breakEven and NS.FormatMoney(sum.breakEven, true) or "--")

    if sum.wallQty and sum.wallQty > 0 and sum.wallCost then
        mainView._statValues.wall:SetText(string.format("%d (%s)", sum.wallQty, NS.FormatMoney(sum.wallCost, true)))
    else
        mainView._statValues.wall:SetText("--")
    end

    mainView._statValues.supply:SetText(tostring(sum.latestQty or 0))

    if sum.investQty and sum.investQty > 0 then
        mainView._statValues.invQty:SetText(string.format("|cFFFFD100%d|r @ %s", sum.investQty, NS.FormatMoney(sum.investAvgCost, true)))
        if sum.investUnrealizedPnL then
            local pClr = (sum.investUnrealizedPnL >= 0) and "|cFF38D972+" or "|cFFF55954"
            mainView._statValues.invPnl:SetText(string.format("%s%s|r", pClr, NS.FormatMoney(sum.investUnrealizedPnL, true)))
        else
            mainView._statValues.invPnl:SetText("--")
        end
    else
        mainView._statValues.invQty:SetText("--")
        mainView._statValues.invPnl:SetText("--")
    end

    -- Inline Underlying Mats Sparkline Strip + Historical Craft Cost Overlay (for crafted items!)
    local craftInfo = NS.Arbitrage and NS.Arbitrage.EvaluateProduct(selectedItemID, selectedTimeframe) or nil
    local craftCostSeries = nil

    if craftInfo and #craftInfo.reagents > 0 then
        mainView._matsStrip:Show()
        mainView._matLineBtn:SetTextLabel(showCraftCostOverlay and "Mat Line: ON" or "Mat Line: OFF")
        mainView._matLineBtn:SetActiveState(showCraftCostOverlay)

        if craftInfo.netProfit ~= nil then
            local aClr = (craftInfo.netProfit > 0) and "|cFF38D972+" or "|cFFF55954"
            mainView._matsHdrTxt:SetText(string.format(
                "|cFFD078FFMats:|r %s  |  Net(5%%): %s  |  Arb: %s%s (%.0f%%)|r",
                NS.FormatMoney(craftInfo.craftCost, true),
                NS.FormatMoney(craftInfo.netSale, true),
                aClr, NS.FormatMoney(craftInfo.netProfit, true), craftInfo.marginPct or 0
            ))
        else
            mainView._matsHdrTxt:SetText("|cFFD078FFUnderlying Mats|r  (Click any mat to open its chart)")
        end

        local host = mainView._matsCardsHost
        local hostW = math.max(240, host:GetWidth() or 450)
        local rCount = #craftInfo.reagents
        local gap = 5
        local cardW = math.floor((hostW - gap * (rCount - 1)) / rCount)

        for i = 1, rCount do
            local rg = craftInfo.reagents[i]
            local mc = mainView._inlineMatCards[i]
            if not mc then
                mc = NS.CreatePanel(host, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER, true)
                local btn = CreateFrame("Button", nil, mc)
                btn:SetAllPoints()
                local hl = btn:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
                hl:SetBlendMode("ADD")
                hl:SetAlpha(0.35)
                mc.btn = btn

                local ic = mc:CreateTexture(nil, "ARTWORK")
                ic:SetSize(16, 16)
                ic:SetPoint("TOPLEFT", 4, -4)
                ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                mc.icon = ic

                local lbl = mc:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                lbl:SetPoint("LEFT", ic, "RIGHT", 4, 0)
                lbl:SetPoint("RIGHT", mc, "RIGHT", -4, 0)
                lbl:SetJustifyH("LEFT")
                lbl:SetWordWrap(false)
                mc.lbl = lbl

                local costLbl = mc:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                costLbl:SetPoint("BOTTOMLEFT", mc, "BOTTOMLEFT", 4, 3)
                costLbl:SetJustifyH("LEFT")
                mc.costLbl = costLbl

                local sp = NS.Chart.CreateSparkline(mc)
                sp:SetPoint("BOTTOMRIGHT", mc, "BOTTOMRIGHT", -4, 3)
                sp:SetSize(64, 20)
                mc.spark = sp

                mainView._inlineMatCards[i] = mc
            end

            mc:ClearAllPoints()
            mc:SetPoint("TOPLEFT", host, "TOPLEFT", (i - 1) * (cardW + gap), 0)
            mc:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", (i - 1) * (cardW + gap), 0)
            mc:SetWidth(cardW)

            mc.icon:SetTexture(rg.icon or 134400)
            local qr, qg, qb = NS.Compat.GetQualityColor(rg.quality)
            mc.lbl:SetTextColor(qr, qg, qb, 1)
            mc.lbl:SetText(string.format("%dx %s", rg.qty, rg.name))
            mc.costLbl:SetText(rg.lineCost and NS.FormatMoney(rg.lineCost, true) or "--")
            mc.spark:Render(rg.series, rg.dayCtx)

            mc.btn:SetScript("OnClick", function()
                UI.SelectItem(rg.itemID)
            end)
            mc:Show()
        end

        for i = rCount + 1, #mainView._inlineMatCards do
            mainView._inlineMatCards[i]:Hide()
        end

        mainView._chart:ClearAllPoints()
        mainView._chart:SetPoint("TOPLEFT", mainView._chartCtrlBar, "BOTTOMLEFT", 0, -8)
        mainView._chart:SetPoint("BOTTOMRIGHT", mainView._matsStrip, "TOPRIGHT", 0, 6)

        if showCraftCostOverlay then
            craftCostSeries = NS.Arbitrage.BuildCraftCostSeries(selectedItemID, sum.series, selectedTimeframe)
        end
    else
        mainView._matsStrip:Hide()
        mainView._chart:ClearAllPoints()
        mainView._chart:SetPoint("TOPLEFT", mainView._chartCtrlBar, "BOTTOMLEFT", 0, -8)
        mainView._chart:SetPoint("BOTTOMRIGHT", mainView._matsStrip, "BOTTOMRIGHT", 0, 0)
    end

    local dayCtx = NS.Analytics.GetDayContext(hist)
    local weekdayCycle = (selectedChartMode == 5) and NS.Analytics.ComputeDayOfWeekCycle(hist, selectedTimeframe) or nil
    mainView._chart:SetData(sum.series, {
        chartMode       = selectedChartMode,
        timeframe       = selectedTimeframe,
        dayContext      = dayCtx,
        buyTarget       = entry.buyTarget,
        sellTarget      = entry.sellTarget,
        investAvgCost   = sum.investAvgCost,
        investBreakEven = sum.investBreakEven,
        craftCostSeries = craftCostSeries,
        showCraftCost   = showCraftCostOverlay,
        weekdayCycle    = weekdayCycle,
    })
end

function UI.RefreshAll()
    if not mainView then return end
    UI.ApplyPageVisibility()

    -- Update top status bar
    if mainView._navStatusTxt then
        local apiTs = NS.DB:GetExternalSyncTimestamp()
        local apiTag = (apiTs > 0) and ("|cFF38D972API Sync: " .. NS.FormatRelativeTime(apiTs) .. "|r") or "Local Scans"
        local modeTag = NS.DB:IsDemoMode() and "|cFFFFD100DEMO PREVIEW|r  |  " or ""
        mainView._navStatusTxt:SetText(modeTag .. NS.DB:GetActiveMarketKey() .. "  |  " .. apiTag)
    end

    if selectedPage == "DASHBOARD" then
        if mainView._dashboardPage then
            mainView._dashboardPage:Refresh()
        end
    elseif selectedPage == "FLIPPING" then
        if mainView._flippingPage then
            mainView._flippingPage:Refresh()
        end
    elseif selectedPage == "INVENTORY" then
        if mainView._inventoryPage then
            mainView._inventoryPage:Refresh()
        end
    elseif selectedPage == "LEDGER" then
        if mainView._ledgerPage then
            mainView._ledgerPage:Refresh()
        end
    else
        UI.RefreshGroups()
        UI.RefreshWatchlist()
        UI.RefreshDetail()
        UI.RefreshActionButtons()
    end
end

function UI.SelectItem(itemID)
    selectedPage = "MARKET"
    selectedItemID = itemID
    UI.ApplyPageVisibility()
    UI.RefreshAll()
end
