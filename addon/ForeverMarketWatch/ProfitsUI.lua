-- ProfitsUI.lua
-- Per-Item Profit & Loss Summary Tab + TSM-Style Gold Balance Chart (Classic WoW AH themed):
--   * Top KPI banner featuring filtered Total Gold, Realized P&L, Total P&L (Incl. Stock),
--     Winners / Losers, and Top Money-Maker.
--   * Interactive collapsible TSM-style Gold Balance line chart filtered by Character / Group
--     and timeframe (Today / 7D / 30D / All) with hover crosshair & multi-alt breakdown.
--   * Rolls up individual Ledger BUY/SELL rows into ONE clean row per item.

local _, NS = ...

local ProfitsUI = {}
NS.ProfitsUI = ProfitsUI

--------------------------------------------------------------------------------
-- Lightweight TSM-Style Gold Balance Chart Widget (Zero GameTooltip Hooks)
--------------------------------------------------------------------------------

local GOLD_PAD_LEFT   = 88
local GOLD_PAD_RIGHT  = 14
local GOLD_PAD_TOP    = 26
local GOLD_PAD_BOTTOM = 20

local function AcquireObj(pool, creator)
    pool.used = pool.used + 1
    local obj = pool.items[pool.used]
    if not obj then
        obj = creator()
        pool.items[pool.used] = obj
    end
    obj:Show()
    return obj
end

local function ResetObjPool(pool)
    for i = 1, #pool.items do
        pool.items[i]:Hide()
    end
    pool.used = 0
end

local function DrawGoldSegment(line, parent, x1, y1, x2, y2, thickness, r, g, b, a)
    if line.SetStartPoint then
        line:SetThickness(thickness or 2.2)
        line:SetColorTexture(r, g, b, a or 1)
        -- WoW Line API takes 4 args: (relativePoint, relativeTo, offsetX, offsetY)
        line:SetStartPoint("BOTTOMLEFT", parent, x1, y1)
        line:SetEndPoint("BOTTOMLEFT", parent, x2, y2)
    else
        line:SetColorTexture(r, g, b, a or 1)
        line:ClearAllPoints()
        line:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", math.min(x1, x2), math.min(y1, y2))
        line:SetSize(math.max(thickness or 2, math.abs(x2 - x1)), math.max(thickness or 2, math.abs(y2 - y1)))
    end
end

local function FormatGoldAxisDate(ts, days)
    if not ts then return "" end
    if days == 1 then
        return date("%H:%M", ts)
    elseif days == 7 then
        return date("%b %d %H:%M", ts)
    end
    return date("%b %d", ts)
end

local function CreateGoldChartWidget(parent)
    local panel = NS.CreatePanel(parent, nil, NS.COLORS.BG_DARK, NS.COLORS.BORDER_ACCENT, false)
    panel:EnableMouse(true)
    panel:SetClipsChildren(true)

    local coinIcon = panel:CreateTexture(nil, "ARTWORK")
    coinIcon:SetSize(14, 14)
    coinIcon:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -6)
    coinIcon:SetTexture(133784)
    coinIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local hudLeft = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hudLeft:SetPoint("LEFT", coinIcon, "RIGHT", 5, 0)
    hudLeft:SetJustifyH("LEFT")
    hudLeft:SetWordWrap(false)

    local hudRight = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hudRight:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -7)
    hudRight:SetJustifyH("RIGHT")
    hudRight:SetWordWrap(false)

    hudLeft:SetPoint("RIGHT", hudRight, "LEFT", -8, 0)

    local emptyTxt = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    emptyTxt:SetPoint("CENTER", panel, "CENTER", 0, -6)
    emptyTxt:SetJustifyH("CENTER")
    emptyTxt:SetTextColor(0.76, 0.70, 0.58, 1)
    emptyTxt:Hide()

    local hintTxt = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintTxt:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -12, 24)
    hintTxt:SetJustifyH("RIGHT")
    hintTxt:Hide()

    local crossV = panel:CreateTexture(nil, "OVERLAY", nil, 5)
    crossV:SetColorTexture(NS.COLORS.CROSSHAIR[1], NS.COLORS.CROSSHAIR[2], NS.COLORS.CROSSHAIR[3], 0.55)
    crossV:Hide()

    local hoverDot = panel:CreateTexture(nil, "OVERLAY", nil, 6)
    hoverDot:SetSize(8, 8)
    hoverDot:SetColorTexture(1.0, 0.92, 0.45, 1)
    hoverDot:Hide()

    local endDot = panel:CreateTexture(nil, "OVERLAY", nil, 4)
    endDot:SetSize(7, 7)
    endDot:SetColorTexture(1.0, 0.84, 0.08, 1)
    endDot:Hide()

    local endNetDot = panel:CreateTexture(nil, "OVERLAY", nil, 4)
    endNetDot:SetSize(7, 7)
    endNetDot:SetColorTexture(0.26, 0.78, 0.98, 1)
    endNetDot:Hide()

    local hoverNetDot = panel:CreateTexture(nil, "OVERLAY", nil, 6)
    hoverNetDot:SetSize(7, 7)
    hoverNetDot:SetColorTexture(0.38, 0.84, 1.0, 1)
    hoverNetDot:Hide()

    local pools = {
        grid   = { items = {}, used = 0 },
        fill   = { items = {}, used = 0 },
        lines  = { items = {}, used = 0 },
        labels = { items = {}, used = 0 },
    }

    local plotted = {}
    local lastData = nil
    local lastScopeLabel = "All Characters"
    local lastDays = nil
    local lastShowNetWorth = true
    local defaultRightText = ""

    local function UpdateHover(self)
        if not lastData or #plotted == 0 then
            crossV:Hide()
            hoverDot:Hide()
            return
        end
        local cx, cy = GetCursorPosition()
        local scale = self:GetEffectiveScale() or 1
        cx = cx / scale
        cy = cy / scale
        local left = self:GetLeft()
        local bottom = self:GetBottom()
        local w = self:GetWidth() or 0
        local h = self:GetHeight() or 0
        if not left or not bottom then return end

        local rx = cx - left
        local ry = cy - bottom
        if rx < GOLD_PAD_LEFT or rx > (w - GOLD_PAD_RIGHT) or ry < GOLD_PAD_BOTTOM or ry > (h - GOLD_PAD_TOP) then
            crossV:Hide()
            hoverDot:Hide()
            hoverNetDot:Hide()
            hudRight:SetText(defaultRightText)
            return
        end

        local best = nil
        local bestDist = math.huge
        for i = 1, #plotted do
            local d = math.abs(plotted[i].x - rx)
            if d < bestDist then
                bestDist = d
                best = plotted[i]
            end
        end

        if best then
            crossV:ClearAllPoints()
            crossV:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", best.x, GOLD_PAD_BOTTOM)
            crossV:SetSize(1, math.max(1, h - GOLD_PAD_TOP - GOLD_PAD_BOTTOM))
            crossV:Show()

            hoverDot:ClearAllPoints()
            hoverDot:SetPoint("CENTER", self, "BOTTOMLEFT", best.x, best.y)
            hoverDot:Show()

            local tStr = date and date("%b %d %H:%M", best.ts) or ""
            if lastShowNetWorth and best.yNet and (best.netWorth or 0) > (best.copper or 0) then
                hoverNetDot:ClearAllPoints()
                hoverNetDot:SetPoint("CENTER", self, "BOTTOMLEFT", best.x, best.yNet)
                hoverNetDot:Show()
                hudRight:SetText(string.format(
                    "|cFFC4B79E%s|r   |cFFFFD100%s|r  |  |cFF42C8FA%s|r",
                    tStr,
                    NS.FormatMoney(best.copper, true),
                    NS.FormatMoney(best.netWorth, true)
                ))
            else
                hoverNetDot:Hide()
                local diff = best.copper - (lastData.startTotal or best.copper)
                hudRight:SetText(string.format(
                    "|cFFC4B79E%s|r   |cFFFFD100%s|r  (%s)",
                    tStr,
                    NS.FormatMoney(best.copper, true),
                    NS.FormatSignedMoney(diff, true)
                ))
            end
        end
    end

    panel:SetScript("OnUpdate", function(self)
        if self:IsMouseOver() then
            UpdateHover(self)
        elseif crossV:IsShown() then
            crossV:Hide()
            hoverDot:Hide()
            hoverNetDot:Hide()
            hudRight:SetText(defaultRightText)
        end
    end)

    panel:SetScript("OnLeave", function()
        crossV:Hide()
        hoverDot:Hide()
        hoverNetDot:Hide()
        hudRight:SetText(defaultRightText)
    end)

    function panel:Render(goldData, scopeLabel, days, showNetWorth)
        lastData = goldData
        lastScopeLabel = scopeLabel or "All Characters"
        lastDays = days
        lastShowNetWorth = (showNetWorth ~= false)

        ResetObjPool(pools.grid)
        ResetObjPool(pools.fill)
        ResetObjPool(pools.lines)
        ResetObjPool(pools.labels)
        plotted = {}
        crossV:Hide()
        hoverDot:Hide()
        hoverNetDot:Hide()
        endDot:Hide()
        endNetDot:Hide()
        hintTxt:Hide()

        -- Build Clean Header HUD
        local cur = (goldData and goldData.currentTotal) or 0
        local curNW = (goldData and goldData.currentNetWorth) or cur
        local curInv = (goldData and goldData.currentInvValue) or 0
        local hasNW = lastShowNetWorth and curInv > 0
        local delta = hasNW and ((goldData and goldData.netWorthDelta) or 0) or ((goldData and goldData.periodDelta) or 0)
        local pctVal = hasNW and (goldData and goldData.netWorthPct) or (goldData and goldData.periodPct)
        local deltaChunk = ""
        if delta ~= 0 then
            local pStr = pctVal and (" " .. NS.FormatSignedPct(pctVal, 1)) or ""
            deltaChunk = "   " .. NS.FormatSignedMoney(delta, true) .. pStr
        end

        if hasNW then
            hudLeft:SetText(string.format(
                "|cFFFFD100Gold|r |cFFFFFFFF%s|r   |cFF42C8FANet Worth|r |cFFFFFFFF%s|r%s",
                NS.FormatMoney(cur, true),
                NS.FormatMoney(curNW, true),
                deltaChunk
            ))
        else
            hudLeft:SetText(string.format(
                "|cFFFFD100Gold|r |cFFFFFFFF%s|r%s",
                NS.FormatMoney(cur, true),
                deltaChunk
            ))
        end

        -- Right HUD defaults to compact top-2 alt split or minimal legend
        defaultRightText = ""
        if goldData and goldData.chars and #goldData.chars > 1 then
            local parts = {}
            local limit = math.min(#goldData.chars, 2)
            for i = 1, limit do
                local c = goldData.chars[i]
                table.insert(parts, string.format("%s |cFFFFD100%s|r", c.name, NS.FormatMoney(c.copper, true)))
            end
            if #goldData.chars > limit then
                table.insert(parts, string.format("+%d", #goldData.chars - limit))
            end
            defaultRightText = "|cFFA89C86" .. table.concat(parts, "  ·  ") .. "|r"
        elseif hasNW then
            defaultRightText = "|cFFFFD100— Gold|r   |cFF42C8FA— Net Worth|r"
        end
        hudRight:SetText(defaultRightText)

        local w = self:GetWidth() or 0
        local h = self:GetHeight() or 0
        local plotW = w - GOLD_PAD_LEFT - GOLD_PAD_RIGHT
        local plotH = h - GOLD_PAD_TOP - GOLD_PAD_BOTTOM
        if plotW < 60 or plotH < 30 then return end

        local pts = (goldData and goldData.points) or {}
        if #pts == 0 or (goldData and goldData.charCount == 0) then
            emptyTxt:SetText("No gold snapshot recorded for " .. lastScopeLabel .. " yet.\nLog onto this character to start tracking its gold curve automatically.")
            emptyTxt:Show()
            return
        end
        emptyTxt:Hide()

        -- Normalize plot series (if only 1 point, draw clean horizontal baseline across canvas)
        local drawPts = {}
        if #pts == 1 then
            drawPts[1] = { ts = pts[1].ts, copper = pts[1].copper, netWorth = pts[1].netWorth or pts[1].copper, frac = 0 }
            drawPts[2] = { ts = pts[1].ts, copper = pts[1].copper, netWorth = pts[1].netWorth or pts[1].copper, frac = 1 }
            hintTxt:SetText("Live tracking active")
            hintTxt:Show()
        else
            local minTs = pts[1].ts
            local maxTs = pts[#pts].ts
            local spanTs = math.max(1, maxTs - minTs)
            for i = 1, #pts do
                drawPts[i] = {
                    ts       = pts[i].ts,
                    copper   = pts[i].copper,
                    netWorth = pts[i].netWorth or pts[i].copper,
                    frac     = (pts[i].ts - minTs) / spanTs,
                }
            end
        end

        -- Compute Y-axis range covering both Liquid Gold and Net Worth (when shown)
        local minV = goldData.minCopper or 0
        local maxV = goldData.maxCopper or 0
        if hasNW then
            minV = math.min(minV, goldData.minNetWorth or minV)
            maxV = math.max(maxV, goldData.maxNetWorth or maxV)
        end
        if maxV == minV then
            local pad = math.max(1000, math.floor(maxV * 0.12))
            minV = math.max(0, minV - pad)
            maxV = maxV + pad
        else
            local pad = math.max(100, math.floor((maxV - minV) * 0.14))
            minV = math.max(0, minV - pad)
            maxV = maxV + pad
        end
        local spanV = math.max(1, maxV - minV)

        -- Horizontal grid lines + full Gold/Silver/Copper Y-axis labels (3 levels)
        local yTicks = 2
        for t = 0, yTicks do
            local frac = t / yTicks
            local y = GOLD_PAD_BOTTOM + (frac * plotH)
            local val = math.floor(minV + (frac * spanV) + 0.5)

            local gLine = AcquireObj(pools.grid, function()
                return self:CreateTexture(nil, "BACKGROUND", nil, 2)
            end)
            gLine:SetColorTexture(NS.COLORS.GRID[1], NS.COLORS.GRID[2], NS.COLORS.GRID[3], 0.42)
            gLine:ClearAllPoints()
            gLine:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", GOLD_PAD_LEFT, y)
            gLine:SetSize(plotW, 1)

            local yLbl = AcquireObj(pools.labels, function()
                return self:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            end)
            yLbl:ClearAllPoints()
            yLbl:SetPoint("RIGHT", self, "BOTTOMLEFT", GOLD_PAD_LEFT - 6, y)
            yLbl:SetWidth(GOLD_PAD_LEFT - 10)
            yLbl:SetJustifyH("RIGHT")
            yLbl:SetTextColor(0.84, 0.78, 0.66, 1)
            yLbl:SetText(NS.FormatMoney(val, true))
        end

        -- Subtle starting-balance reference line
        if #pts >= 2 and goldData.startTotal then
            local baseFrac = math.max(0, math.min(1, (goldData.startTotal - minV) / spanV))
            local baseY = GOLD_PAD_BOTTOM + (baseFrac * plotH)
            local bLine = AcquireObj(pools.grid, function()
                return self:CreateTexture(nil, "BACKGROUND", nil, 3)
            end)
            bLine:SetColorTexture(0.95, 0.80, 0.30, 0.25)
            bLine:ClearAllPoints()
            bLine:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", GOLD_PAD_LEFT, baseY)
            bLine:SetSize(plotW, 1)
        end

        -- Map points to screen coordinates
        for i = 1, #drawPts do
            local dp = drawPts[i]
            local x = GOLD_PAD_LEFT + (dp.frac * plotW)
            local y = GOLD_PAD_BOTTOM + (((dp.copper - minV) / spanV) * plotH)
            local yNet = GOLD_PAD_BOTTOM + (((dp.netWorth - minV) / spanV) * plotH)
            plotted[i] = { x = x, y = y, yNet = yNet, ts = dp.ts, copper = dp.copper, netWorth = dp.netWorth }
        end

        -- Downsample translucent area-fill strips beneath Liquid Gold
        local maxStrips = 80
        local step = math.max(1, math.floor((#plotted - 1) / maxStrips))
        local idx = 1
        while idx < #plotted do
            local nextIdx = math.min(#plotted, idx + step)
            local p1 = plotted[idx]
            local p2 = plotted[nextIdx]
            local stripW = math.max(1, p2.x - p1.x)
            local midY = (p1.y + p2.y) * 0.5
            local stripH = math.max(1, midY - GOLD_PAD_BOTTOM)

            local fill = AcquireObj(pools.fill, function()
                return self:CreateTexture(nil, "BACKGROUND", nil, 4)
            end)
            fill:SetColorTexture(1.0, 0.82, 0.14, 0.13)
            fill:ClearAllPoints()
            fill:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", p1.x, GOLD_PAD_BOTTOM)
            fill:SetSize(stripW + 0.5, stripH)

            idx = nextIdx
        end

        -- Sky-Blue Net Worth line (Liquid + Inventory Est. Value) when enabled
        if hasNW then
            for i = 1, #plotted - 1 do
                local p1 = plotted[i]
                local p2 = plotted[i + 1]
                local seg = AcquireObj(pools.lines, function()
                    if self.CreateLine then
                        return self:CreateLine(nil, "ARTWORK", nil, 2)
                    end
                    return self:CreateTexture(nil, "ARTWORK")
                end)
                DrawGoldSegment(seg, self, p1.x, p1.yNet, p2.x, p2.yNet, 2.0, 0.26, 0.78, 0.98, 0.95)
            end
        end

        -- Crisp Classic WoW Gold line segments (Liquid Gold)
        for i = 1, #plotted - 1 do
            local p1 = plotted[i]
            local p2 = plotted[i + 1]
            local seg = AcquireObj(pools.lines, function()
                if self.CreateLine then
                    return self:CreateLine(nil, "ARTWORK", nil, 3)
                end
                return self:CreateTexture(nil, "ARTWORK")
            end)
            DrawGoldSegment(seg, self, p1.x, p1.y, p2.x, p2.y, 2.2, 1.0, 0.83, 0.12, 1.0)
        end

        -- Glowing live endpoint dot(s)
        local lastPt = plotted[#plotted]
        if lastPt then
            endDot:ClearAllPoints()
            endDot:SetPoint("CENTER", self, "BOTTOMLEFT", lastPt.x, lastPt.y)
            endDot:Show()
            if hasNW and lastPt.yNet then
                endNetDot:ClearAllPoints()
                endNetDot:SetPoint("CENTER", self, "BOTTOMLEFT", lastPt.x, lastPt.yNet)
                endNetDot:Show()
            end
        end

        -- Bottom X-axis date ticks (Start, Mid, Now)
        local xTickCount = (#pts >= 2) and 3 or 1
        for i = 1, xTickCount do
            local frac = (xTickCount == 1) and 1 or ((i - 1) / (xTickCount - 1))
            local pIdx = math.max(1, math.min(#plotted, math.floor(1 + frac * (#plotted - 1) + 0.5)))
            local pt = plotted[pIdx]
            local xLbl = AcquireObj(pools.labels, function()
                return self:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            end)
            xLbl:ClearAllPoints()
            xLbl:SetTextColor(0.70, 0.65, 0.55, 1)
            if i == 1 and xTickCount > 1 then
                xLbl:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", GOLD_PAD_LEFT, 4)
                xLbl:SetJustifyH("LEFT")
                xLbl:SetText(FormatGoldAxisDate(pt.ts, days))
            elseif i == xTickCount then
                xLbl:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -GOLD_PAD_RIGHT, 4)
                xLbl:SetJustifyH("RIGHT")
                xLbl:SetText((#pts >= 2) and "Now" or FormatGoldAxisDate(pt.ts, days))
            else
                xLbl:SetPoint("BOTTOM", self, "BOTTOMLEFT", GOLD_PAD_LEFT + (plotW * frac), 4)
                xLbl:SetJustifyH("CENTER")
                xLbl:SetText(FormatGoldAxisDate(pt.ts, days))
            end
        end
    end

    panel:SetScript("OnSizeChanged", function(self)
        if lastData and self:IsShown() then
            self:Render(lastData, lastScopeLabel, lastDays, lastShowNetWorth)
        end
    end)

    return panel
end

--------------------------------------------------------------------------------
-- Seed Capital & Alt Transfers Popover
--------------------------------------------------------------------------------

local function CreateSeedCapitalPopover(parent, onSaved)
    local pop = NS.CreatePanel(parent, nil, NS.COLORS.BG_DARK, NS.COLORS.BORDER_ACCENT, false)
    pop:SetSize(356, 308)
    pop:SetFrameStrata("DIALOG")
    pop:SetFrameLevel(90)
    pop:EnableMouse(true)
    pop:Hide()

    local title = pop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", pop, "TOPLEFT", 12, -10)
    title:SetText("Seed Capital & Alt Gold Transfers")

    local closeBtn = CreateFrame("Button", nil, pop, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", pop, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() pop:Hide() end)

    local sub = pop:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sub:SetPoint("TOPLEFT", pop, "TOPLEFT", 12, -28)
    sub:SetPoint("TOPRIGHT", pop, "TOPRIGHT", -12, -28)
    sub:SetJustifyH("LEFT")
    sub:SetText("Set starting seed gold per alt (e.g. '5g') to track Seed ROI%. Alt mail transfers log automatically.")

    local charScroll = CreateFrame("ScrollFrame", "ForeverMarketWatchSeedScroll", pop, "UIPanelScrollFrameTemplate")
    charScroll:SetPoint("TOPLEFT", pop, "TOPLEFT", 10, -56)
    charScroll:SetPoint("TOPRIGHT", pop, "TOPRIGHT", -28, -56)
    charScroll:SetHeight(124)

    local charChild = CreateFrame("Frame", nil, charScroll)
    charChild:SetSize(308, 1)
    charScroll:SetScrollChild(charChild)

    local xferHdr = pop:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    xferHdr:SetPoint("TOPLEFT", charScroll, "BOTTOMLEFT", 2, -10)
    xferHdr:SetText("Recent Alt-to-Alt Transfers:")

    local xferBox = NS.CreatePanel(pop, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, false)
    xferBox:SetPoint("TOPLEFT", xferHdr, "BOTTOMLEFT", -2, -4)
    xferBox:SetPoint("BOTTOMRIGHT", pop, "BOTTOMRIGHT", -10, 10)

    local xferText = xferBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    xferText:SetPoint("TOPLEFT", xferBox, "TOPLEFT", 8, -6)
    xferText:SetPoint("BOTTOMRIGHT", xferBox, "BOTTOMRIGHT", -8, 6)
    xferText:SetJustifyH("LEFT")
    xferText:SetJustifyV("TOP")

    local charRows = {}

    function pop:RefreshAndShow(anchorBtn)
        local chars = NS.DB:GetKnownCharacters()
        local rowH = 28

        for i = 1, #chars do
            local ch = chars[i]
            local row = charRows[i]
            if not row then
                row = CreateFrame("Frame", nil, charChild)
                row:SetHeight(rowH)

                local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                lbl:SetPoint("LEFT", row, "LEFT", 4, 0)
                lbl:SetWidth(110)
                lbl:SetJustifyH("LEFT")
                lbl:SetWordWrap(false)
                row.lbl = lbl

                local box, eb = NS.CreateEditBox(row, 118, 22, "e.g. 5g")
                box:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
                row.box = box
                row.eb = eb

                local saveBtn = NS.CreateButton(row, "Save", 54, 22, false)
                saveBtn:SetPoint("LEFT", box, "RIGHT", 6, 0)
                row.saveBtn = saveBtn

                charRows[i] = row
            end

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", charChild, "TOPLEFT", 0, -((i - 1) * rowH))
            row:SetPoint("TOPRIGHT", charChild, "TOPRIGHT", 0, -((i - 1) * rowH))
            row.lbl:SetText(ch)

            local seedVal = NS.DB:GetCharacterSeedCapital(ch)
            row.eb:SetText(seedVal > 0 and NS.FormatMoneyPlain(seedVal) or "")

            local function SaveSeed()
                local raw = row.eb:GetText() or ""
                if raw:match("^%s*$") then
                    NS.DB:SetCharacterSeedCapital(ch, 0)
                else
                    local parsed = NS.ParseMoney(raw)
                    if parsed and parsed >= 0 then
                        NS.DB:SetCharacterSeedCapital(ch, parsed)
                    else
                        NS.PrintError("Enter a valid amount like '5g' or '5g 50s'.")
                        return
                    end
                end
                row.eb:ClearFocus()
                if onSaved then onSaved() end
            end

            row.saveBtn:SetScript("OnClick", SaveSeed)
            row.eb:SetScript("OnEnterPressed", SaveSeed)
            row:Show()
        end

        for i = #chars + 1, #charRows do
            charRows[i]:Hide()
        end
        charChild:SetHeight(math.max(1, #chars * rowH))

        local transfers = NS.DB:GetTransfers(5)
        if #transfers == 0 then
            xferText:SetText("No alt-to-alt mail transfers captured yet.\nSend gold between your alts and it will log here automatically.")
        else
            local lines = {}
            for i = 1, #transfers do
                local tr = transfers[i]
                local dt = (date and tr.ts) and date("%b %d %H:%M", tr.ts) or ""
                table.insert(lines, string.format(
                    "|cFF998C78%s|r  %s -> %s:  |cFFFFD100%s|r",
                    dt, tr.fromChar or "Alt", tr.toChar or "Alt", NS.FormatMoney(tr.amount or 0, true)
                ))
            end
            xferText:SetText(table.concat(lines, "\n"))
        end

        pop:ClearAllPoints()
        if anchorBtn then
            pop:SetPoint("TOPRIGHT", anchorBtn, "BOTTOMRIGHT", 0, -4)
        else
            pop:SetPoint("CENTER", parent, "CENTER", 0, 0)
        end
        pop:Show()
        pop:Raise()
    end

    return pop
end

function ProfitsUI.Create(parent, onOpenItem, onOpenCharGroups)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    frame:Hide()

    local selectedDays = nil        -- 1 (Today), 7, 30, nil (All Time)
    local outcomeFilter = "ALL"     -- "ALL", "WINNERS", "LOSERS"
    local sortCol = "totalPnL"      -- "name", "bought", "sold", "onHand", "realized", "totalPnL"
    local sortAsc = false
    local searchText = ""
    local showGoldChart = true
    local showNetWorthLine = true
    local seedPopover = nil

    ----------------------------------------------------------------------------
    -- 1. TOP PER-ITEM PERFORMANCE + TOTAL GOLD KPI BANNER
    ----------------------------------------------------------------------------
    local kpiBar = NS.CreatePanel(frame, nil, NS.COLORS.BG_CARD, NS.COLORS.BORDER_ACCENT, false)
    kpiBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    kpiBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    kpiBar:SetHeight(50)

    local kpis = {
        { id = "gold",     title = "Total Gold" },
        { id = "realized", title = "Realized P&L" },
        { id = "total",    title = "Total P&L" },
        { id = "winloss",  title = "Win / Loss" },
        { id = "best",     title = "Top Item" },
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
    -- 2. TIMEFRAME, OUTCOME FILTER & SEARCH BAR
    ----------------------------------------------------------------------------
    local ctrlBar = NS.CreatePanel(frame, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, false)
    ctrlBar:SetPoint("TOPLEFT", kpiBar, "BOTTOMLEFT", 0, -5)
    ctrlBar:SetPoint("TOPRIGHT", kpiBar, "BOTTOMRIGHT", 0, -5)
    ctrlBar:SetHeight(32)

    local tfBtns = {}
    local tfDefs = {
        { key = "TODAY", days = 1,   label = "Today", w = 46 },
        { key = "7D",    days = 7,   label = "7D",    w = 30 },
        { key = "30D",   days = 30,  label = "30D",   w = 34 },
        { key = "ALL",   days = nil, label = "All",   w = 30 },
    }
    local prev = nil
    for i = 1, #tfDefs do
        local def = tfDefs[i]
        local b = NS.CreateButton(ctrlBar, def.label, def.w, 22, false)
        if not prev then
            b:SetPoint("LEFT", ctrlBar, "LEFT", 6, 0)
        else
            b:SetPoint("LEFT", prev, "RIGHT", 2, 0)
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
        { id = "ALL",     label = "All",  w = 32 },
        { id = "WINNERS", label = "Win",  w = 38 },
        { id = "LOSERS",  label = "Loss", w = 40 },
    }
    for i = 1, #outDefs do
        local def = outDefs[i]
        local b = NS.CreateButton(ctrlBar, def.label, def.w, 22, false)
        b:SetPoint("LEFT", prev, "RIGHT", (i == 1) and 8 or 2, 0)
        b:SetScript("OnClick", function()
            outcomeFilter = def.id
            frame:Refresh()
        end)
        outBtns[def.id] = b
        prev = b
    end

    local searchBox, searchEB = NS.CreateEditBox(ctrlBar, 114, 22, "Search...")
    searchBox:SetPoint("LEFT", prev, "RIGHT", 8, 0)
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

    local seedBtn = NS.CreateButton(ctrlBar, "Seed", 40, 22, false)
    seedBtn:SetPoint("RIGHT", altsBtn, "LEFT", -3, 0)
    seedBtn:SetScript("OnClick", function(self)
        if not seedPopover then
            seedPopover = CreateSeedCapitalPopover(frame, function()
                frame:Refresh()
            end)
        end
        if seedPopover:IsShown() then
            seedPopover:Hide()
        else
            seedPopover:RefreshAndShow(self)
        end
    end)

    local charDrop = NS.CreateDropdown(ctrlBar, 108, 22, function(val)
        if NS.UI and NS.UI.SetCharFilter then
            NS.UI.SetCharFilter(val)
        end
    end)
    charDrop:SetPoint("RIGHT", seedBtn, "LEFT", -3, 0)

    local netWorthBtn = NS.CreateButton(ctrlBar, "+Net", 42, 22, false)
    netWorthBtn:SetPoint("RIGHT", charDrop, "LEFT", -3, 0)
    netWorthBtn:SetScript("OnClick", function()
        showNetWorthLine = not showNetWorthLine
        frame:Refresh()
    end)

    local chartToggleBtn = NS.CreateButton(ctrlBar, "Chart", 44, 22, false)
    chartToggleBtn:SetPoint("RIGHT", netWorthBtn, "LEFT", -3, 0)

    ----------------------------------------------------------------------------
    -- 3. TSM-STYLE GOLD BALANCE CHART PANEL (COLLAPSIBLE)
    ----------------------------------------------------------------------------
    local goldChart = CreateGoldChartWidget(frame)
    goldChart:SetPoint("TOPLEFT", ctrlBar, "BOTTOMLEFT", 0, -5)
    goldChart:SetPoint("TOPRIGHT", ctrlBar, "BOTTOMRIGHT", 0, -5)
    goldChart:SetHeight(128)

    ----------------------------------------------------------------------------
    -- 4. PER-ITEM PROFIT ROLLUP TABLE
    ----------------------------------------------------------------------------
    local tablePanel = NS.CreatePanel(frame, nil, NS.COLORS.BG_PANEL, NS.COLORS.BORDER, false)
    tablePanel:SetPoint("TOPLEFT", goldChart, "BOTTOMLEFT", 0, -6)
    tablePanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

    local function UpdateChartLayout()
        chartToggleBtn:SetActiveState(showGoldChart)
        tablePanel:ClearAllPoints()
        if showGoldChart then
            goldChart:Show()
            tablePanel:SetPoint("TOPLEFT", goldChart, "BOTTOMLEFT", 0, -6)
        else
            goldChart:Hide()
            tablePanel:SetPoint("TOPLEFT", ctrlBar, "BOTTOMLEFT", 0, -6)
        end
        tablePanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    end

    chartToggleBtn:SetScript("OnClick", function()
        showGoldChart = not showGoldChart
        UpdateChartLayout()
        frame:Refresh()
    end)
    UpdateChartLayout()

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

        -- 2. Sync live player gold snapshot & compute filtered gold + per-item rollups
        if GetMoney and not NS.DB:IsDemoMode() and not (NS.Ledger and NS.Ledger.IsLoggingOut and NS.Ledger:IsLoggingOut()) then
            local liveCopper = GetMoney()
            if liveCopper and liveCopper > 0 then
                NS.DB:RecordCharacterGold(liveCopper, nil, nil, true)
            end
        end

        local charFilter = (NS.UI and NS.UI.GetCharFilter and NS.UI.GetCharFilter()) or "ALL"
        local filterOpts = NS.DB:GetCharacterFilterOptions()
        charDrop:SetOptions(filterOpts)
        charDrop:SetSelected(charFilter, false)

        local scopeLabel = "All Characters"
        for i = 1, #filterOpts do
            if filterOpts[i].value == charFilter then
                scopeLabel = filterOpts[i].label
                break
            end
        end

        local goldData = NS.DB:GetGoldHistorySummary({
            days       = selectedDays,
            charFilter = charFilter,
        })

        local allItems, totals = NS.DB:GetItemProfitSummaries({
            days       = selectedDays,
            charFilter = charFilter,
            search     = searchText,
        })

        -- Update Top KPI Banner
        netWorthBtn:SetActiveState(showNetWorthLine)
        local seedInfo = NS.DB:GetFilteredSeedSummary(charFilter)
        local seedCap = (seedInfo and seedInfo.effectiveSeed) or 0

        if goldData and goldData.charCount > 0 then
            if seedCap > 0 then
                local baseVal = (goldData.currentNetWorth and goldData.currentNetWorth > 0) and goldData.currentNetWorth or goldData.currentTotal
                local roi = ((baseVal - seedCap) / seedCap) * 100
                self._kpiValues.gold:SetText(string.format(
                    "|cFFFFD100%s|r (%s)",
                    NS.FormatMoney(goldData.currentTotal, true),
                    NS.FormatSignedPct(roi, 0)
                ))
            else
                self._kpiValues.gold:SetText("|cFFFFD100" .. NS.FormatMoney(goldData.currentTotal, true) .. "|r")
            end
        else
            self._kpiValues.gold:SetText("|cFF998C78--|r")
        end

        self._kpiValues.realized:SetText(NS.FormatSignedMoney(totals.realizedPnL, true))
        self._kpiValues.total:SetText(NS.FormatSignedMoney(totals.totalPnL, true))
        self._kpiValues.winloss:SetText(string.format("|cFF38D972%d|r / |cFFF55954%d|r", totals.winners, totals.losers))

        if totals.bestItem and totals.bestItem.totalPnL > 0 then
            self._kpiValues.best:SetText(string.format("%s (%s)", totals.bestItem.name, NS.FormatSignedMoney(totals.bestItem.totalPnL, true)))
        else
            self._kpiValues.best:SetText("|cFF998C78--|r")
        end

        -- Render TSM-Style Gold Balance + Net Worth Chart
        if showGoldChart then
            goldChart:Render(goldData, scopeLabel, selectedDays, showNetWorthLine)
        end

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

            local subParts = {}
            if d.buyCount > 0 or d.sellCount > 0 then
                table.insert(subParts, string.format("%dB / %dS", d.buyCount, d.sellCount))
            else
                table.insert(subParts, "Held")
            end
            if d.depositLoss and d.depositLoss > 0 then
                table.insert(subParts, "|cFFFFA030Dep: -" .. NS.FormatMoney(d.depositLoss, true) .. "|r")
            end
            row.subTxt:SetText(table.concat(subParts, "  ·  "))

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
                row.realTop:SetText(NS.FormatSignedMoney(d.realizedPnL, true))
                if d.isFarmedOnly then
                    row.realBot:SetText("Farmed")
                elseif d.realizedRoiPct then
                    row.realBot:SetText(NS.FormatSignedPct(d.realizedRoiPct, 1))
                else
                    row.realBot:SetText("")
                end
            else
                row.realTop:SetText("|cFF8A7E6B--|r")
                row.realBot:SetText("")
            end

            row.totTop:SetText(NS.FormatSignedMoney(d.totalPnL, true))
            if d.isFarmedOnly then
                row.totBot:SetText("")
            elseif d.totalRoiPct then
                row.totBot:SetText(NS.FormatSignedPct(d.totalRoiPct, 1))
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
