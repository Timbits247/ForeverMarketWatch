-- Chart.lua
-- Pure-Lua interactive Google Finance–inspired stock chart (Classic WoW AH themed)
-- rendered with Frame:CreateLine() and pooled textures/fontstrings.
-- Features:
--  * True full-day 1D timeline (00:00 -> 24:00) filling in progressively as the day advances
--  * Google Finance green/red directional line + translucent area fill + dotted prev-close baseline + live endpoint dot
--  * Dedicated bottom-anchored Volume sub-chart (green/red stock histogram)
--  * 5 dropdown-selectable Chart Modes (including Mon-Sun Day-of-Week Seasonality)
--  * Lightweight Chart.CreateSparkline() for Google Finance–style Dashboard cards
--  * Zero WoW GameTooltip hooks

local _, NS = ...

local Chart = {}
NS.Chart = Chart

local PAD_LEFT   = 88
local PAD_RIGHT  = 68
local PAD_TOP    = 28
local PAD_BOTTOM = 24
local VOL_GAP    = 10

local function FormatAxisDate(ts, timeframe)
    if not ts then return "" end
    if timeframe == "1D" then
        return date("%H:%M", ts)
    elseif timeframe == "7D" then
        return date("%b %d %H:%M", ts)
    end
    return date("%b %d", ts)
end

local function FormatHudTimestamp(ts, isDaily)
    if not ts then return "" end
    if isDaily then
        return date("%b %d, %Y", ts)
    end
    return date("%b %d %H:%M", ts)
end

--------------------------------------------------------------------------------
-- Object Pool Helpers (Zero Frame Leaks on Redraw)
--------------------------------------------------------------------------------

local function AcquireLine(pool, parent, layer, subLevel)
    pool.used = pool.used + 1
    local obj = pool.items[pool.used]
    if not obj then
        if parent.CreateLine then
            obj = parent:CreateLine(nil, layer or "ARTWORK", nil, subLevel or 0)
        else
            obj = parent:CreateTexture(nil, layer or "ARTWORK")
        end
        pool.items[pool.used] = obj
    end
    obj:Show()
    return obj
end

local function AcquireTexture(pool, parent, layer, subLevel)
    pool.used = pool.used + 1
    local obj = pool.items[pool.used]
    if not obj then
        obj = parent:CreateTexture(nil, layer or "ARTWORK", nil, subLevel or 0)
        pool.items[pool.used] = obj
    end
    obj:Show()
    return obj
end

local function AcquireFontString(pool, parent, fontObj)
    pool.used = pool.used + 1
    local obj = pool.items[pool.used]
    if not obj then
        obj = parent:CreateFontString(nil, "OVERLAY", fontObj or "GameFontHighlightSmall")
        pool.items[pool.used] = obj
    end
    obj:Show()
    return obj
end

local function ResetPool(pool)
    for i = 1, #pool.items do
        pool.items[i]:Hide()
    end
    pool.used = 0
end

local function DrawSegment(line, parent, x1, y1, x2, y2, thickness, color)
    if line.SetStartPoint then
        line:SetThickness(thickness or 2)
        line:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
        -- WoW Line API takes 4 args: (relativePoint, relativeTo, offsetX, offsetY)
        line:SetStartPoint("BOTTOMLEFT", parent, x1, y1)
        line:SetEndPoint("BOTTOMLEFT", parent, x2, y2)
    else
        line:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
        line:ClearAllPoints()
        line:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", math.min(x1, x2), math.min(y1, y2))
        line:SetSize(math.max(thickness or 2, math.abs(x2 - x1)), math.max(thickness or 2, math.abs(y2 - y1)))
    end
end

--------------------------------------------------------------------------------
-- Main Interactive Chart Widget
--------------------------------------------------------------------------------

function Chart.Create(parent)
    local frame = NS.CreatePanel(parent, nil, NS.COLORS.BG_DARK, NS.COLORS.BORDER, false)
    frame:EnableMouse(true)
    frame:SetClipsChildren(true)

    local hudText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hudText:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -9)
    hudText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -9)
    hudText:SetJustifyH("LEFT")
    hudText:SetTextColor(0.95, 0.92, 0.84, 1)
    frame._hudText = hudText

    local emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyText:SetPoint("CENTER", frame, "CENTER", 0, 0)
    emptyText:SetJustifyH("CENTER")
    emptyText:SetTextColor(0.75, 0.68, 0.56, 1)
    emptyText:Hide()
    frame._emptyText = emptyText

    -- Interactive crosshair primitives
    local crossV = frame:CreateTexture(nil, "OVERLAY", nil, 5)
    crossV:SetColorTexture(NS.COLORS.CROSSHAIR[1], NS.COLORS.CROSSHAIR[2], NS.COLORS.CROSSHAIR[3], NS.COLORS.CROSSHAIR[4])
    crossV:Hide()

    local crossH = frame:CreateTexture(nil, "OVERLAY", nil, 5)
    crossH:SetColorTexture(NS.COLORS.CROSSHAIR[1], NS.COLORS.CROSSHAIR[2], NS.COLORS.CROSSHAIR[3], NS.COLORS.CROSSHAIR[4])
    crossH:Hide()

    local hoverDot = frame:CreateTexture(nil, "OVERLAY", nil, 6)
    hoverDot:SetSize(8, 8)
    hoverDot:SetColorTexture(1, 0.92, 0.55, 1)
    hoverDot:Hide()

    frame._pools = {
        bgRects  = { items = {}, used = 0 },
        areaFill = { items = {}, used = 0 },
        lines    = { items = {}, used = 0 },
        wicks    = { items = {}, used = 0 },
        volBars  = { items = {}, used = 0 },
        dots     = { items = {}, used = 0 },
        grid     = { items = {}, used = 0 },
        labels   = { items = {}, used = 0 },
    }

    frame._series = {}
    frame._plotted = {}
    frame._weekdayBars = {}
    frame._weekdayCycle = nil
    frame._chartMode = 2
    frame._timeframe = "1D"
    frame._dayContext = nil
    frame._buyTarget = nil
    frame._sellTarget = nil
    frame._investAvgCost = nil
    frame._investBreakEven = nil
    frame._craftCostSeries = nil
    frame._showCraftCost = true
    frame._defaultLegend = ""
    frame._plotBounds = nil

    function frame:SetData(series, opts)
        self._series = series or {}
        opts = opts or {}
        self._chartMode = opts.chartMode or self._chartMode or 2
        self._timeframe = opts.timeframe or self._timeframe or "1D"
        self._dayContext = opts.dayContext
        self._buyTarget = opts.buyTarget
        self._sellTarget = opts.sellTarget
        self._investAvgCost = opts.investAvgCost
        self._investBreakEven = opts.investBreakEven
        self._craftCostSeries = opts.craftCostSeries
        self._showCraftCost = (opts.showCraftCost ~= false)
        self._weekdayCycle = opts.weekdayCycle
        self._emptyReason = opts.emptyReason
        self:Redraw()
    end

    function frame:ClearPools()
        for _, p in pairs(self._pools) do
            ResetPool(p)
        end
        crossV:Hide()
        crossH:Hide()
        hoverDot:Hide()
    end

    function frame:GetBaselineAndDirection()
        local series = self._series
        if not series or #series == 0 then
            return nil, true, 0, 0
        end
        local latest = series[#series].min
        local baseline = series[1].min
        if self._timeframe == "1D" and self._dayContext and self._dayContext.prevClose and self._dayContext.prevClose > 0 then
            baseline = self._dayContext.prevClose
        end
        local diff = latest - baseline
        local pct = (baseline and baseline > 0) and ((diff / baseline) * 100) or 0
        return baseline, (diff >= 0), diff, pct
    end

    function frame:BuildLegend()
        local m = self._chartMode
        local tf = self._timeframe or "1D"
        local count = self._series and #self._series or 0
        local gran = (tf == "1D") and "Today" or ((tf == "7D") and "7D" or (tf .. " Daily"))

        if m == 5 then
            local cyc = self._weekdayCycle
            if cyc and cyc.validDays and cyc.validDays >= 2 and cyc.bestBuyDay and cyc.bestSellDay then
                return string.format(
                    "|cFFFFD100[%s]|r |cFF38D972Best Buy: %s|r | |cFFFFCC33Best Sell: %s|r | Spread: |cFF38D972+%.1f%%|r",
                    tf, cyc.bestBuyDay, cyc.bestSellDay, cyc.spreadPct or 0
                )
            end
            return string.format("|cFFFFD100[%s Weekday Cycle]|r — Needs 2+ days of history", tf)
        end

        local _, isUp, diff, pct = self:GetBaselineAndDirection()
        local dirColor = isUp and "|cFF38D972" or "|cFFF55954"
        local sign = (diff > 0) and "+" or ""
        local deltaStr = (count >= 1)
            and string.format("%s%s%s (%s%.1f%%)|r", dirColor, sign, NS.FormatMoney(diff, true), sign, pct)
            or ""

        local parts = {
            string.format("|cFFFFD100[%s • %d pts]|r", gran, count),
            deltaStr,
        }
        if m == 1 or m == 4 then
            table.insert(parts, "|cFF60A5FA— Mkt Avg|r")
        end
        if self._showCraftCost and self._craftCostSeries and #self._craftCostSeries > 0 then
            table.insert(parts, "|cFFD078FF— Mat Cost|r")
        end
        if m == 3 or m == 4 then
            table.insert(parts, "|cFFFFCC33— MA|r")
        end
        if m == 2 or m == 4 then
            table.insert(parts, "|cFF38D972||r|cFFF55954| Vol|r")
        end
        if self._investBreakEven and self._investBreakEven > 0 then
            table.insert(parts, "|cFF60A5FA-- Cost|r |cFFFFD100-- BE|r")
        end
        if count == 1 and (tf == "30D" or tf == "90D" or tf == "All") then
            table.insert(parts, "|cFF998C78(1 day so far)|r")
        end
        return table.concat(parts, "  ")
    end

    function frame:DrawWeekdayChart(w, h)
        local cyc = self._weekdayCycle
        if not cyc or not cyc.validDays or cyc.validDays == 0 then
            emptyText:SetText("No weekday history yet.\nCollect 2+ days of scans (or run /fmw demo) to see Mon-Sun seasonality.")
            emptyText:Show()
            return
        end
        emptyText:Hide()

        local plotX = PAD_LEFT
        local plotW = math.max(30, w - PAD_LEFT - PAD_RIGHT)
        local plotBottom = PAD_BOTTOM
        local plotH = math.max(50, h - PAD_TOP - PAD_BOTTOM)

        self._plotBounds = {
            x = plotX, w = plotW,
            priceBottom = plotBottom, priceH = plotH,
            fullBottom = plotBottom, fullH = plotH,
            isWeekday = true,
        }

        local minY, maxY = nil, nil
        for i = 1, 7 do
            local d = cyc.days[i]
            if d and d.avg then
                if not minY or d.avg < minY then minY = d.avg end
                if not maxY or d.avg > maxY then maxY = d.avg end
            end
        end
        if not minY then return end

        local floorY = math.max(0, math.floor(minY * 0.85))
        local ceilY  = math.max(floorY + 100, math.ceil(maxY * 1.08))
        local ySpan  = math.max(1, ceilY - floorY)

        local leftAxis = AcquireTexture(self._pools.grid, self, "BACKGROUND", 2)
        leftAxis:SetColorTexture(NS.COLORS.BORDER[1], NS.COLORS.BORDER[2], NS.COLORS.BORDER[3], 0.70)
        leftAxis:ClearAllPoints()
        leftAxis:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", plotX, plotBottom)
        leftAxis:SetSize(1, plotH)

        local bottomAxis = AcquireTexture(self._pools.grid, self, "BACKGROUND", 2)
        bottomAxis:SetColorTexture(NS.COLORS.BORDER[1], NS.COLORS.BORDER[2], NS.COLORS.BORDER[3], 0.85)
        bottomAxis:ClearAllPoints()
        bottomAxis:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", plotX, plotBottom)
        bottomAxis:SetSize(plotW, 1)

        local ticks = 4
        for t = 0, ticks do
            local frac = t / ticks
            local yVal = floorY + frac * ySpan
            local yPos = plotBottom + frac * plotH

            local gLine = AcquireTexture(self._pools.grid, self, "BACKGROUND", 1)
            gLine:SetColorTexture(NS.COLORS.GRID[1], NS.COLORS.GRID[2], NS.COLORS.GRID[3], NS.COLORS.GRID[4])
            gLine:ClearAllPoints()
            gLine:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", plotX, yPos)
            gLine:SetSize(plotW, 1)

            local lbl = AcquireFontString(self._pools.labels, self, "GameFontHighlightSmall")
            lbl:ClearAllPoints()
            lbl:SetPoint("RIGHT", self, "BOTTOMLEFT", plotX - 6, yPos)
            lbl:SetJustifyH("RIGHT")
            lbl:SetTextColor(0.86, 0.80, 0.66, 1)
            lbl:SetText(NS.FormatMoney(yVal, true))
        end

        local colW = plotW / 7
        local barW = math.max(14, math.floor(colW * 0.56))

        for i = 1, 7 do
            local d = cyc.days[i]
            local centerX = plotX + (i - 0.5) * colW

            local xLbl = AcquireFontString(self._pools.labels, self, "GameFontHighlightSmall")
            xLbl:ClearAllPoints()
            xLbl:SetPoint("TOP", self, "BOTTOMLEFT", centerX, plotBottom - 4)
            xLbl:SetText(d.label)

            if d.avg then
                local norm = math.max(0.04, math.min(1, (d.avg - floorY) / ySpan))
                local barH = math.max(6, math.floor(norm * (plotH - 4)))
                local color = { 0.52, 0.64, 0.78, 0.82 }
                if i == cyc.bestBuyIdx and cyc.validDays >= 2 then
                    color = NS.COLORS.GREEN
                    xLbl:SetTextColor(0.22, 0.85, 0.45, 1)
                elseif i == cyc.bestSellIdx and cyc.validDays >= 2 then
                    color = NS.COLORS.AMBER
                    xLbl:SetTextColor(1.0, 0.82, 0.20, 1)
                else
                    xLbl:SetTextColor(0.80, 0.75, 0.65, 1)
                end

                local bar = AcquireTexture(self._pools.volBars, self, "ARTWORK", 2)
                bar:SetColorTexture(color[1], color[2], color[3], color[4] or 0.9)
                bar:ClearAllPoints()
                bar:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", math.floor(centerX - barW / 2), plotBottom + 1)
                bar:SetSize(barW, barH)

                table.insert(self._weekdayBars, {
                    x1 = centerX - (colW * 0.45),
                    x2 = centerX + (colW * 0.45),
                    centerX = centerX,
                    topY = plotBottom + barH,
                    day = d,
                    overallAvg = cyc.overallAvg,
                })
            else
                xLbl:SetTextColor(0.45, 0.42, 0.38, 0.8)
            end
        end
    end

    function frame:Redraw()
        self:ClearPools()
        self._plotted = {}
        self._weekdayBars = {}
        self._plotBounds = nil

        local w = self:GetWidth() or 0
        local h = self:GetHeight() or 0
        if w < 180 or h < 110 then return end

        self._defaultLegend = self:BuildLegend()
        hudText:SetText(self._defaultLegend)

        if self._chartMode == 5 then
            self:DrawWeekdayChart(w, h)
            return
        end

        local series = self._series
        if not series or #series == 0 then
            emptyText:SetText(self._emptyReason or "No price history yet.\nSync Blizzard API or visit the Auction House.")
            emptyText:Show()
            return
        end
        emptyText:Hide()

        local mode = self._chartMode or 2
        local showRange  = (mode == 1 or mode == 4)
        local showVolume = (mode == 2 or mode == 4)
        local showMA     = (mode == 3 or mode == 4)

        local plotX = PAD_LEFT
        local plotW = math.max(30, w - PAD_LEFT - PAD_RIGHT)
        local fullPlotBottom = PAD_BOTTOM
        local fullPlotH = math.max(50, h - PAD_TOP - PAD_BOTTOM)

        local priceBottom, priceH, volBottom, volH
        if showVolume then
            volBottom = fullPlotBottom
            volH = math.max(32, math.floor(fullPlotH * 0.24))
            priceBottom = volBottom + volH + VOL_GAP
            priceH = math.max(40, fullPlotH - volH - VOL_GAP)
        else
            priceBottom = fullPlotBottom
            priceH = fullPlotH
            volBottom = fullPlotBottom
            volH = 0
        end

        self._plotBounds = {
            x = plotX,
            w = plotW,
            priceBottom = priceBottom,
            priceH = priceH,
            volBottom = volBottom,
            volH = volH,
            fullBottom = fullPlotBottom,
            fullH = fullPlotH,
        }

        local baselinePrice, isUp = self:GetBaselineAndDirection()
        local mainLineColor = isUp and NS.COLORS.GREEN or NS.COLORS.RED

        -- Determine Y-axis bounds (price) & max volume
        -- Scale to Min Buyout & Market Avg (not overpriced 90th-pct High) so curves stay crisp & readable
        local minY, maxY = nil, nil
        local maxVol = 1
        local hasCraftCost = self._showCraftCost and self._craftCostSeries and (#self._craftCostSeries == #series)
        for i = 1, #series do
            local p = series[i]
            local lo = p.min
            local hi = showRange and (p.avg or p.min) or p.min
            if showMA and p.ma then
                lo = math.min(lo, p.ma)
                hi = math.max(hi, p.ma)
            end
            if hasCraftCost and self._craftCostSeries[i] and self._craftCostSeries[i] > 0 then
                lo = math.min(lo, self._craftCostSeries[i])
                hi = math.max(hi, self._craftCostSeries[i])
            end
            if not minY or lo < minY then minY = lo end
            if not maxY or hi > maxY then maxY = hi end
            if p.qty and p.qty > maxVol then maxVol = p.qty end
        end

        if baselinePrice and baselinePrice > 0 then
            minY = math.min(minY, baselinePrice)
            maxY = math.max(maxY, baselinePrice)
        end

        if self._buyTarget and self._buyTarget > 0 then
            if mode == 4 or (self._buyTarget >= minY * 0.4 and self._buyTarget <= maxY * 2.2) then
                minY = math.min(minY, self._buyTarget)
                maxY = math.max(maxY, self._buyTarget)
            end
        end
        if self._sellTarget and self._sellTarget > 0 then
            if mode == 4 or (self._sellTarget >= minY * 0.4 and self._sellTarget <= maxY * 2.2) then
                minY = math.min(minY, self._sellTarget)
                maxY = math.max(maxY, self._sellTarget)
            end
        end
        if self._investAvgCost and self._investAvgCost > 0 then
            if self._investAvgCost >= minY * 0.4 and self._investAvgCost <= maxY * 2.2 then
                minY = math.min(minY, self._investAvgCost)
                maxY = math.max(maxY, self._investAvgCost)
            end
        end
        if self._investBreakEven and self._investBreakEven > 0 then
            if self._investBreakEven >= minY * 0.4 and self._investBreakEven <= maxY * 2.2 then
                minY = math.min(minY, self._investBreakEven)
                maxY = math.max(maxY, self._investBreakEven)
            end
        end

        if maxY == minY then
            local pad = math.max(50, math.floor(minY * 0.12))
            minY = math.max(0, minY - pad)
            maxY = maxY + pad
        else
            local span = maxY - minY
            minY = math.max(0, minY - span * 0.10)
            maxY = maxY + span * 0.10
        end
        local ySpan = math.max(1, maxY - minY)

        local function MapY(val)
            local norm = (val - minY) / ySpan
            norm = math.max(0, math.min(1, norm))
            return priceBottom + norm * priceH
        end

        -- Axes
        local leftAxis = AcquireTexture(self._pools.grid, self, "BACKGROUND", 2)
        leftAxis:SetColorTexture(NS.COLORS.BORDER[1], NS.COLORS.BORDER[2], NS.COLORS.BORDER[3], 0.70)
        leftAxis:ClearAllPoints()
        leftAxis:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", plotX, fullPlotBottom)
        leftAxis:SetSize(1, fullPlotH)

        local bottomAxis = AcquireTexture(self._pools.grid, self, "BACKGROUND", 2)
        bottomAxis:SetColorTexture(NS.COLORS.BORDER[1], NS.COLORS.BORDER[2], NS.COLORS.BORDER[3], 0.85)
        bottomAxis:ClearAllPoints()
        bottomAxis:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", plotX, fullPlotBottom)
        bottomAxis:SetSize(plotW, 1)

        -- Horizontal grid lines + full Gold/Silver/Copper Y-axis labels
        local ticks = 4
        for t = 0, ticks do
            local frac = t / ticks
            local yVal = minY + frac * ySpan
            local yPos = priceBottom + frac * priceH

            local gLine = AcquireTexture(self._pools.grid, self, "BACKGROUND", 1)
            gLine:SetColorTexture(NS.COLORS.GRID[1], NS.COLORS.GRID[2], NS.COLORS.GRID[3], NS.COLORS.GRID[4])
            gLine:ClearAllPoints()
            gLine:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", plotX, yPos)
            gLine:SetSize(plotW, 1)

            local lbl = AcquireFontString(self._pools.labels, self, "GameFontHighlightSmall")
            lbl:ClearAllPoints()
            lbl:SetPoint("RIGHT", self, "BOTTOMLEFT", plotX - 6, yPos)
            lbl:SetJustifyH("RIGHT")
            lbl:SetTextColor(0.86, 0.80, 0.66, 1)
            lbl:SetText(NS.FormatMoney(yVal, true))
        end

        -- Dedicated Bottom Volume Sub-Pane
        if showVolume then
            local volPanelBg = AcquireTexture(self._pools.bgRects, self, "BACKGROUND", 0)
            volPanelBg:SetColorTexture(NS.COLORS.VOL_BG[1], NS.COLORS.VOL_BG[2], NS.COLORS.VOL_BG[3], NS.COLORS.VOL_BG[4])
            volPanelBg:ClearAllPoints()
            volPanelBg:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", plotX + 1, volBottom + 1)
            volPanelBg:SetSize(math.max(1, plotW - 1), math.max(1, volH - 1))

            local volTopBorder = AcquireTexture(self._pools.grid, self, "BACKGROUND", 3)
            volTopBorder:SetColorTexture(NS.COLORS.BORDER[1], NS.COLORS.BORDER[2], NS.COLORS.BORDER[3], 0.85)
            volTopBorder:ClearAllPoints()
            volTopBorder:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", plotX, volBottom + volH)
            volTopBorder:SetSize(plotW, 1)

            local volMaxLbl = AcquireFontString(self._pools.labels, self, "GameFontDisableSmall")
            volMaxLbl:ClearAllPoints()
            volMaxLbl:SetPoint("RIGHT", self, "BOTTOMLEFT", plotX - 6, volBottom + volH - 4)
            volMaxLbl:SetJustifyH("RIGHT")
            volMaxLbl:SetTextColor(0.62, 0.78, 0.96, 0.95)
            volMaxLbl:SetText("Vol " .. tostring(maxVol))

            local volZeroLbl = AcquireFontString(self._pools.labels, self, "GameFontDisableSmall")
            volZeroLbl:ClearAllPoints()
            volZeroLbl:SetPoint("RIGHT", self, "BOTTOMLEFT", plotX - 6, volBottom + 4)
            volZeroLbl:SetJustifyH("RIGHT")
            volZeroLbl:SetTextColor(0.55, 0.60, 0.68, 0.85)
            volZeroLbl:SetText("0")
        end

        -- Google Finance X-Axis Time Mapping!
        -- On 1D: fixed 00:00 -> 24:00 day axis so the chart fills in progressively from left to right!
        -- On 7D/30D/90D/All: true timestamp-proportional X spacing across collected span.
        local count = #series
        local useFixedDayAxis = false
        local axisStartTs, axisEndTs = nil, nil

        if self._timeframe == "1D" and self._dayContext and self._dayContext.dayStart and self._dayContext.dayEnd then
            -- Verify points fall inside today's 00:00 -> 24:00 window
            if series[#series].ts >= self._dayContext.dayStart then
                useFixedDayAxis = true
                axisStartTs = self._dayContext.dayStart
                axisEndTs   = self._dayContext.dayEnd
            end
        end

        if not useFixedDayAxis and count >= 2 then
            axisStartTs = series[1].ts
            axisEndTs   = series[count].ts
        end

        local timeSpan = (axisStartTs and axisEndTs and axisEndTs > axisStartTs) and (axisEndTs - axisStartTs) or nil
        local function MapX(ts, idx)
            if timeSpan then
                local norm = (ts - axisStartTs) / timeSpan
                norm = math.max(0, math.min(1, norm))
                return plotX + norm * plotW
            elseif count == 1 then
                return plotX + plotW * 0.5
            else
                return plotX + ((idx - 1) / (count - 1)) * plotW
            end
        end

        -- Subtle vertical day progress guides on 1D (06:00, 12:00, 18:00)
        if useFixedDayAxis then
            for q = 1, 3 do
                local gx = plotX + (plotW * (q / 4))
                local vGrid = AcquireTexture(self._pools.grid, self, "BACKGROUND", 1)
                vGrid:SetColorTexture(NS.COLORS.GRID[1], NS.COLORS.GRID[2], NS.COLORS.GRID[3], 0.22)
                vGrid:ClearAllPoints()
                vGrid:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", gx, fullPlotBottom)
                vGrid:SetSize(1, fullPlotH)
            end
        end

        -- Compute plotted coordinates
        local barWidth = useFixedDayAxis and 6 or ((count > 1) and math.max(3, math.min(12, math.floor((plotW / count) * 0.55))) or 12)

        for i = 1, count do
            local p = series[i]
            local xPos = MapX(p.ts, i)
            local yMin = MapY(p.min)
            local yAvg = MapY(p.avg or p.min)
            local yMA  = p.ma and MapY(p.ma) or yMin

            local cCost = hasCraftCost and self._craftCostSeries[i] or nil
            local yCraft = cCost and MapY(cCost) or nil

            self._plotted[i] = {
                x = xPos,
                y = yMin,
                yAvg = yAvg,
                yMA = yMA,
                yCraft = yCraft,
                craftCost = cCost,
                point = p,
            }

            -- Bottom Volume Histogram Bars (Modes 2 & 4)
            if showVolume and p.qty and p.qty > 0 then
                local usableVolH = math.max(4, volH - 4)
                local barH = math.max(2, math.floor((p.qty / maxVol) * usableVolH))
                local barUp = (i == 1) or (p.min >= series[i - 1].min)
                local vColor = barUp and NS.COLORS.VOL_UP or NS.COLORS.VOL_DOWN

                local barLeft = math.floor(xPos - (barWidth / 2))
                barLeft = math.max(plotX + 1, math.min(plotX + plotW - barWidth, barLeft))

                local vBar = AcquireTexture(self._pools.volBars, self, "ARTWORK", 2)
                vBar:SetColorTexture(vColor[1], vColor[2], vColor[3], vColor[4])
                vBar:ClearAllPoints()
                vBar:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", barLeft, volBottom + 1)
                vBar:SetSize(barWidth, barH)
            end
        end

        -- Google Finance Soft Translucent Area Fill underneath the price line
        if count >= 2 then
            local fillAlpha = 0.13
            for i = 1, count - 1 do
                local a = self._plotted[i]
                local b = self._plotted[i + 1]
                local segW = b.x - a.x
                if segW >= 1 then
                    local slices = math.max(1, math.min(28, math.floor(segW / 6)))
                    local sliceW = (segW / slices) + 0.6
                    for s = 0, slices - 1 do
                        local tFrac = (s + 0.5) / slices
                        local sx = a.x + (s / slices) * segW
                        local sy = a.y + (b.y - a.y) * tFrac
                        local fh = math.max(1, sy - priceBottom)
                        local fill = AcquireTexture(self._pools.areaFill, self, "ARTWORK", 0)
                        fill:SetColorTexture(mainLineColor[1], mainLineColor[2], mainLineColor[3], fillAlpha)
                        fill:ClearAllPoints()
                        fill:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", sx, priceBottom + 1)
                        fill:SetSize(sliceW, fh)

                        -- Clean Market Spread Ribbon (Modes 1 & 4): shaded band between Lowest Buyout & Market Avg
                        if showRange then
                            local syAvg = a.yAvg + (b.yAvg - a.yAvg) * tFrac
                            if syAvg > sy + 1 then
                                local band = AcquireTexture(self._pools.wicks, self, "ARTWORK", 1)
                                band:SetColorTexture(NS.COLORS.BLUE[1], NS.COLORS.BLUE[2], NS.COLORS.BLUE[3], 0.16)
                                band:ClearAllPoints()
                                band:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", sx, sy)
                                band:SetSize(sliceW, syAvg - sy)
                            end
                        end
                    end
                end
            end
        end

        -- Dotted Prev-Close / Open Baseline across full chart (classic Google Finance touch!)
        if baselinePrice and baselinePrice >= minY and baselinePrice <= maxY then
            local baseY = MapY(baselinePrice)
            local dotW, gapW = 3, 4
            local cx = plotX
            while cx < (plotX + plotW) do
                local segW = math.min(dotW, (plotX + plotW) - cx)
                local dTex = AcquireTexture(self._pools.grid, self, "ARTWORK", 2)
                dTex:SetColorTexture(0.76, 0.72, 0.62, 0.55)
                dTex:ClearAllPoints()
                dTex:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", cx, baseY)
                dTex:SetSize(segW, 1)
                cx = cx + dotW + gapW
            end
        end

        -- Target & Investment Reference Lines
        local function DrawTargetLine(targetVal, color, tagPrefix)
            if not targetVal or targetVal <= 0 then return end
            if targetVal < minY or targetVal > maxY then return end
            local yPos = MapY(targetVal)

            local dashW, gapW = 8, 5
            local cx = plotX
            while cx < (plotX + plotW) do
                local segW = math.min(dashW, (plotX + plotW) - cx)
                local dash = AcquireTexture(self._pools.grid, self, "ARTWORK", 3)
                dash:SetColorTexture(color[1], color[2], color[3], 0.90)
                dash:ClearAllPoints()
                dash:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", cx, yPos)
                dash:SetSize(segW, 1.5)
                cx = cx + dashW + gapW
            end

            local tag = AcquireFontString(self._pools.labels, self, "GameFontHighlightSmall")
            tag:ClearAllPoints()
            tag:SetPoint("LEFT", self, "BOTTOMLEFT", plotX + plotW + 4, yPos)
            tag:SetJustifyH("LEFT")
            tag:SetTextColor(color[1], color[2], color[3], 1)
            tag:SetText(tagPrefix .. NS.FormatMoney(targetVal, true))
        end

        DrawTargetLine(self._buyTarget,       NS.COLORS.GREEN, "B:")
        DrawTargetLine(self._sellTarget,      NS.COLORS.RED,   "S:")
        DrawTargetLine(self._investAvgCost,   NS.COLORS.BLUE,  "C:")
        DrawTargetLine(self._investBreakEven, NS.COLORS.AMBER, "BE:")

        -- Sleek Market Average Upper Line (Modes 1 & 4 — shows real clearing price vs lowest undercut)
        if showRange and count >= 2 then
            local avgCol = { NS.COLORS.BLUE[1], NS.COLORS.BLUE[2], NS.COLORS.BLUE[3], 0.78 }
            for i = 1, count - 1 do
                local a = self._plotted[i]
                local b = self._plotted[i + 1]
                local line = AcquireLine(self._pools.lines, self, "ARTWORK", 3)
                DrawSegment(line, self, a.x, a.yAvg, b.x, b.yAvg, 1.4, avgCol)
            end
        end

        -- Historical Underlying Material Craft Cost Line (violet overlay when viewing crafted items!)
        if hasCraftCost then
            local craftCol = { 0.82, 0.47, 1.00, 0.92 }
            if count >= 2 then
                for i = 1, count - 1 do
                    local a = self._plotted[i]
                    local b = self._plotted[i + 1]
                    if a.yCraft and b.yCraft then
                        local line = AcquireLine(self._pools.lines, self, "ARTWORK", 4)
                        DrawSegment(line, self, a.x, a.yCraft, b.x, b.yCraft, 1.8, craftCol)
                    end
                end
            elseif count == 1 and self._plotted[1].yCraft then
                local cDot = AcquireTexture(self._pools.dots, self, "ARTWORK", 6)
                cDot:SetSize(6, 6)
                cDot:SetColorTexture(craftCol[1], craftCol[2], craftCol[3], 1)
                cDot:ClearAllPoints()
                cDot:SetPoint("CENTER", self, "BOTTOMLEFT", self._plotted[1].x, self._plotted[1].yCraft)
            end
        end

        -- Moving Average line (Modes 3 & 4)
        if showMA and count >= 2 then
            for i = 1, count - 1 do
                local a = self._plotted[i]
                local b = self._plotted[i + 1]
                local line = AcquireLine(self._pools.lines, self, "ARTWORK", 4)
                DrawSegment(line, self, a.x, a.yMA, b.x, b.yMA, 1.8, NS.COLORS.AMBER)
            end
        end

        -- Main Google Finance Directional Price Line (Green Up / Red Down)
        if count >= 2 then
            for i = 1, count - 1 do
                local a = self._plotted[i]
                local b = self._plotted[i + 1]
                local line = AcquireLine(self._pools.lines, self, "ARTWORK", 5)
                DrawSegment(line, self, a.x, a.y, b.x, b.y, 2.3, mainLineColor)
            end
        end

        -- Live Glowing Endpoint Marker at the most recent point (leading edge of today's curve!)
        local lastPlot = self._plotted[count]
        if lastPlot then
            local halo = AcquireTexture(self._pools.dots, self, "ARTWORK", 5)
            halo:SetSize(12, 12)
            halo:SetColorTexture(mainLineColor[1], mainLineColor[2], mainLineColor[3], 0.30)
            halo:ClearAllPoints()
            halo:SetPoint("CENTER", self, "BOTTOMLEFT", lastPlot.x, lastPlot.y)

            local tip = AcquireTexture(self._pools.dots, self, "ARTWORK", 7)
            tip:SetSize(6, 6)
            tip:SetColorTexture(mainLineColor[1], mainLineColor[2], mainLineColor[3], 1.0)
            tip:ClearAllPoints()
            tip:SetPoint("CENTER", self, "BOTTOMLEFT", lastPlot.x, lastPlot.y)
        end

        -- X-axis labels
        if useFixedDayAxis then
            local dayTicks = {
                { frac = 0.00, label = "00:00" },
                { frac = 0.25, label = "06:00" },
                { frac = 0.50, label = "12:00" },
                { frac = 0.75, label = "18:00" },
                { frac = 1.00, label = "24:00" },
            }
            for k = 1, #dayTicks do
                local dt = dayTicks[k]
                local xl = AcquireFontString(self._pools.labels, self, "GameFontHighlightSmall")
                xl:ClearAllPoints()
                xl:SetPoint("TOP", self, "BOTTOMLEFT", plotX + plotW * dt.frac, fullPlotBottom - 4)
                xl:SetTextColor(0.75, 0.70, 0.60, 1)
                xl:SetText(dt.label)
            end
        else
            local xLabelCount = math.min(count, 5)
            if xLabelCount == 1 then
                local p = self._plotted[1]
                local xl = AcquireFontString(self._pools.labels, self, "GameFontHighlightSmall")
                xl:ClearAllPoints()
                xl:SetPoint("TOP", self, "BOTTOMLEFT", p.x, fullPlotBottom - 4)
                xl:SetTextColor(0.75, 0.70, 0.60, 1)
                xl:SetText(FormatAxisDate(p.point.ts, self._timeframe))
            else
                for k = 0, xLabelCount - 1 do
                    local idx = math.floor(1 + (k * (count - 1) / (xLabelCount - 1)) + 0.5)
                    local p = self._plotted[idx]
                    if p then
                        local xl = AcquireFontString(self._pools.labels, self, "GameFontHighlightSmall")
                        xl:ClearAllPoints()
                        xl:SetPoint("TOP", self, "BOTTOMLEFT", p.x, fullPlotBottom - 4)
                        xl:SetTextColor(0.75, 0.70, 0.60, 1)
                        xl:SetText(FormatAxisDate(p.point.ts, self._timeframe))
                    end
                end
            end
        end
    end

    ----------------------------------------------------------------------------
    -- Interactive Hover Crosshair (In-Chart Readout Only — Zero GameTooltip)
    ----------------------------------------------------------------------------

    local function UpdateHover(self)
        local bounds = self._plotBounds
        if not bounds then
            crossV:Hide(); crossH:Hide(); hoverDot:Hide()
            return
        end

        local scale = self:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        cx, cy = cx / scale, cy / scale

        local left = self:GetLeft()
        local bottom = self:GetBottom()
        if not left or not bottom then return end

        local relX = cx - left
        local relY = cy - bottom

        if bounds.isWeekday then
            local bars = self._weekdayBars or {}
            local hit = nil
            for i = 1, #bars do
                if relX >= bars[i].x1 and relX <= bars[i].x2 and relY >= bounds.fullBottom and relY <= (bounds.fullBottom + bounds.fullH) then
                    hit = bars[i]
                    break
                end
            end
            crossV:Hide(); crossH:Hide(); hoverDot:Hide()
            if hit then
                local d = hit.day
                local vsPct = (hit.overallAvg and hit.overallAvg > 0) and (((d.avg - hit.overallAvg) / hit.overallAvg) * 100) or 0
                local colorTag = (vsPct <= -0.5) and "|cFF38D972" or ((vsPct >= 0.5) and "|cFFF55954" or "|cFFE2E8F0")
                hudText:SetText(string.format(
                    "|cFFFFD100%s|r  Avg: %s  (%s%+.1f%% vs avg|r)  Samples: %d",
                    d.label, NS.FormatMoney(d.avg, false), colorTag, vsPct, d.count
                ))
            else
                hudText:SetText(self._defaultLegend)
            end
            return
        end

        local plotted = self._plotted
        if not plotted or #plotted == 0 then
            crossV:Hide(); crossH:Hide(); hoverDot:Hide()
            return
        end

        if relX < bounds.x - 10 or relX > (bounds.x + bounds.w + 10)
            or relY < bounds.fullBottom - 6 or relY > (bounds.fullBottom + bounds.fullH + 6) then
            crossV:Hide(); crossH:Hide(); hoverDot:Hide()
            hudText:SetText(self._defaultLegend)
            return
        end

        local best = plotted[1]
        local bestDist = math.abs(relX - best.x)
        for i = 2, #plotted do
            local d = math.abs(relX - plotted[i].x)
            if d < bestDist then
                bestDist = d
                best = plotted[i]
            end
        end

        crossV:ClearAllPoints()
        crossV:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", best.x, bounds.fullBottom)
        crossV:SetSize(1, bounds.fullH)
        crossV:Show()

        crossH:ClearAllPoints()
        crossH:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", bounds.x, best.y)
        crossH:SetSize(bounds.w, 1)
        crossH:Show()

        hoverDot:ClearAllPoints()
        hoverDot:SetPoint("CENTER", self, "BOTTOMLEFT", best.x, best.y)
        hoverDot:Show()

        local pt = best.point
        local craftPart = best.craftCost and ("  |cFFD078FFMats:|r " .. NS.FormatMoney(best.craftCost, true)) or ""
        local hud = string.format(
            "|cFFFFD100%s|r  Min: %s  Avg: %s%s  Vol: |cFF60A5FA%d|r",
            FormatHudTimestamp(pt.ts, pt.isDaily),
            NS.FormatMoney(pt.min, false),
            NS.FormatMoney(pt.avg or pt.min, true),
            craftPart,
            pt.qty or 0
        )
        hudText:SetText(hud)
    end

    frame:SetScript("OnEnter", function(self)
        self:SetScript("OnUpdate", UpdateHover)
    end)
    frame:SetScript("OnLeave", function(self)
        self:SetScript("OnUpdate", nil)
        crossV:Hide(); crossH:Hide(); hoverDot:Hide()
        hudText:SetText(self._defaultLegend)
    end)
    frame:SetScript("OnSizeChanged", function(self)
        self:Redraw()
    end)

    return frame
end

--------------------------------------------------------------------------------
-- Lightweight Google Finance Mini Sparkline Widget (For Dashboard Cards)
--------------------------------------------------------------------------------

function Chart.CreateSparkline(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetClipsChildren(true)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.055, 0.048, 0.042, 0.78)
    f._bg = bg

    f._lines = { items = {}, used = 0 }
    f._dots  = { items = {}, used = 0 }

    function f:Render(series, dayContext, opts)
        ResetPool(self._lines)
        ResetPool(self._dots)
        opts = opts or {}

        if opts.bgColor then
            self._bg:SetColorTexture(opts.bgColor[1], opts.bgColor[2], opts.bgColor[3], opts.bgColor[4] or 0.85)
        else
            self._bg:SetColorTexture(0.055, 0.048, 0.042, 0.78)
        end

        local w = self:GetWidth() or 0
        local h = self:GetHeight() or 0
        if w < 24 or h < 14 or not series or #series == 0 then
            return
        end

        local padX, padY = 4, 4
        local pw = math.max(8, w - padX * 2)
        local ph = math.max(6, h - padY * 2)
        local count = #series

        local baseline = (dayContext and dayContext.prevClose) or series[1].min
        local latest = series[count].min
        local isUp = (latest >= baseline)
        local col = opts.lineColor or (isUp and NS.COLORS.GREEN or NS.COLORS.RED)

        local minY, maxY = series[1].min, series[1].min
        if not opts.hideBaseline then
            if baseline < minY then minY = baseline end
            if baseline > maxY then maxY = baseline end
        end
        for i = 1, count do
            local v = series[i].min
            if v < minY then minY = v end
            if v > maxY then maxY = v end
        end
        if opts.buyTarget and opts.buyTarget > 0 then
            if opts.buyTarget < minY then minY = opts.buyTarget end
            if opts.buyTarget > maxY then maxY = opts.buyTarget end
        end
        if opts.sellTarget and opts.sellTarget > 0 then
            if opts.sellTarget < minY then minY = opts.sellTarget end
            if opts.sellTarget > maxY then maxY = opts.sellTarget end
        end
        if maxY == minY then
            minY = math.max(0, minY - 50)
            maxY = maxY + 50
        end
        local ySpan = math.max(1, maxY - minY)

        local useDayAxis = dayContext and dayContext.dayStart and dayContext.dayEnd and (series[count].ts >= dayContext.dayStart)
        local startTs = useDayAxis and dayContext.dayStart or series[1].ts
        local endTs   = useDayAxis and dayContext.dayEnd   or series[count].ts
        local tSpan   = (endTs > startTs) and (endTs - startTs) or nil

        local function DrawDashedHLine(val, r, g, b, a)
            local ly = padY + ((val - minY) / ySpan) * ph
            local cx = padX
            while cx < (padX + pw) do
                local d = AcquireTexture(self._dots, self, "ARTWORK", 1)
                d:SetColorTexture(r, g, b, a)
                d:ClearAllPoints()
                d:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", cx, ly)
                d:SetSize(3, 1)
                cx = cx + 6
            end
        end

        -- Reference lines: either Buy/Sell target lines or prevClose baseline
        if opts.buyTarget and opts.buyTarget > 0 then
            DrawDashedHLine(opts.buyTarget, 0.22, 0.90, 0.45, 0.70)
        end
        if opts.sellTarget and opts.sellTarget > 0 then
            DrawDashedHLine(opts.sellTarget, 0.96, 0.35, 0.33, 0.70)
        end
        if not opts.hideBaseline then
            DrawDashedHLine(baseline, 0.75, 0.70, 0.58, 0.35)
        end

        local pts = {}
        for i = 1, count do
            local x
            if tSpan then
                x = padX + math.max(0, math.min(1, (series[i].ts - startTs) / tSpan)) * pw
            elseif count == 1 then
                x = padX + pw * 0.5
            else
                x = padX + ((i - 1) / (count - 1)) * pw
            end
            local y = padY + ((series[i].min - minY) / ySpan) * ph
            pts[i] = { x = x, y = y }
        end

        -- Soft translucent area fill under the line when zone tint is requested
        if opts.areaFill and count >= 2 then
            local fillA = opts.areaAlpha or 0.16
            for i = 1, count - 1 do
                local a = pts[i]
                local b = pts[i + 1]
                local segW = math.max(1, b.x - a.x)
                local avgY = (a.y + b.y) * 0.5
                local barH = math.max(1, avgY - padY)
                local fill = AcquireTexture(self._dots, self, "ARTWORK", 0)
                fill:SetColorTexture(col[1], col[2], col[3], fillA)
                fill:ClearAllPoints()
                fill:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", a.x, padY)
                fill:SetSize(segW + 0.5, barH)
            end
        end

        for i = 1, count - 1 do
            local line = AcquireLine(self._lines, self, "ARTWORK", 3)
            DrawSegment(line, self, pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y, opts.lineWidth or 1.8, col)
        end

        local tip = AcquireTexture(self._dots, self, "ARTWORK", 5)
        tip:SetSize(6, 6)
        tip:SetColorTexture(col[1], col[2], col[3], 1)
        tip:ClearAllPoints()
        tip:SetPoint("CENTER", self, "BOTTOMLEFT", pts[count].x, pts[count].y)
    end

    return f
end
