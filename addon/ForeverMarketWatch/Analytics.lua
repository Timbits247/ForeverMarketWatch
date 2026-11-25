-- Analytics.lua
-- Pure math & time-series engine: timeframe extraction, SMA moving averages,
-- 7-day baseline delta %, period stats, and Buy/Sell target signal evaluation.

local _, NS = ...

local Analytics = {}
NS.Analytics = Analytics

local TIMEFRAME_DAYS = {
    ["1D"]  = 1,
    ["7D"]  = 7,
    ["30D"] = 30,
    ["90D"] = 90,
    ["All"] = nil,
}

-- Lua date("*t").wday: 1=Sun, 2=Mon, 3=Tue, 4=Wed, 5=Thu, 6=Fri, 7=Sat
-- Reorder to Mon..Sun (1..7) for cleaner weekly trading seasonality charts
local WDAY_TO_MON_INDEX = {
    [2] = 1, -- Mon
    [3] = 2, -- Tue
    [4] = 3, -- Wed
    [5] = 4, -- Thu
    [6] = 5, -- Fri
    [7] = 6, -- Sat
    [1] = 7, -- Sun
}

Analytics.WEEKDAY_NAMES = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

function Analytics.GetAHCutRate()
    local marketKey = (NS.DB and NS.DB:GetActiveMarketKey()) or ""
    if marketKey:find("%-Neutral$") then
        return 0.15
    end
    return 0.05
end

function Analytics.ComputeDayOfWeekCycle(itemHist, timeframe, nowTs)
    local buckets = {}
    for i = 1, 7 do
        buckets[i] = { dayIndex = i, label = Analytics.WEEKDAY_NAMES[i], sum = 0, count = 0, avg = nil }
    end
    if type(itemHist) ~= "table" then
        return { days = buckets, validDays = 0 }
    end

    local now = nowTs or (time and time()) or 0
    local daysWindow = TIMEFRAME_DAYS[timeframe or "All"]
    local cutoff = daysWindow and (now - daysWindow * 86400) or 0

    local function AddSample(ts, price)
        if not ts or not price or price <= 0 or ts < cutoff then return end
        local d = date("*t", ts)
        if not d or not d.wday then return end
        local idx = WDAY_TO_MON_INDEX[d.wday]
        if idx then
            buckets[idx].sum = buckets[idx].sum + price
            buckets[idx].count = buckets[idx].count + 1
        end
    end

    local daily = itemHist.daily or {}
    for dayKey, d in pairs(daily) do
        AddSample(NS.TimestampFromDayKey(dayKey), d[1])
    end

    local intraday = itemHist.intraday or {}
    for i = 1, #intraday do
        AddSample(intraday[i][1], intraday[i][2])
    end

    local validDays = 0
    local bestBuyIdx, bestSellIdx = nil, nil
    local overallSum, overallCnt = 0, 0

    for i = 1, 7 do
        local b = buckets[i]
        if b.count > 0 then
            b.avg = math.floor((b.sum / b.count) + 0.5)
            validDays = validDays + 1
            overallSum = overallSum + b.avg
            overallCnt = overallCnt + 1
            if not bestBuyIdx or b.avg < buckets[bestBuyIdx].avg then
                bestBuyIdx = i
            end
            if not bestSellIdx or b.avg > buckets[bestSellIdx].avg then
                bestSellIdx = i
            end
        end
    end

    local overallAvg = (overallCnt > 0) and math.floor((overallSum / overallCnt) + 0.5) or nil
    local spreadPct = nil
    if bestBuyIdx and bestSellIdx and buckets[bestBuyIdx].avg and buckets[bestBuyIdx].avg > 0 then
        spreadPct = ((buckets[bestSellIdx].avg - buckets[bestBuyIdx].avg) / buckets[bestBuyIdx].avg) * 100
    end

    return {
        days        = buckets,
        validDays   = validDays,
        overallAvg  = overallAvg,
        bestBuyIdx  = bestBuyIdx,
        bestSellIdx = bestSellIdx,
        bestBuyDay  = bestBuyIdx and Analytics.WEEKDAY_NAMES[bestBuyIdx] or nil,
        bestSellDay = bestSellIdx and Analytics.WEEKDAY_NAMES[bestSellIdx] or nil,
        spreadPct   = spreadPct,
    }
end

function Analytics.GetTodayBounds(nowTs)
    local now = nowTs or (time and time()) or 0
    local d = date("*t", now)
    local dayStart = time({ year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0 })
    return dayStart, dayStart + 86400
end

-- Returns Google-Finance-style day progression context for 1D charts:
-- { dayStart = midnight, dayEnd = midnight+24h, prevClose = copper, dayDelta = copper, dayDeltaPct = pct }
function Analytics.GetDayContext(itemHist, nowTs)
    local now = nowTs or (time and time()) or 0
    local dayStart, dayEnd = Analytics.GetTodayBounds(now)
    local prevClose = nil
    local firstToday = nil
    local latestToday = nil

    if type(itemHist) == "table" then
        local intraday = itemHist.intraday or {}
        for i = 1, #intraday do
            local pt = intraday[i]
            if pt[1] < dayStart then
                prevClose = pt[2] -- latest intraday point from before midnight
            elseif pt[1] <= dayEnd then
                if not firstToday then firstToday = pt[2] end
                latestToday = pt[2]
            end
        end

        -- Fall back to most recent daily close before today if no pre-midnight intraday exists
        if not prevClose and type(itemHist.daily) == "table" then
            local todayKey = NS.DayKeyFromTimestamp(now)
            local bestKey = nil
            for dk in pairs(itemHist.daily) do
                if dk < todayKey and (not bestKey or dk > bestKey) then
                    bestKey = dk
                end
            end
            if bestKey then
                local d = itemHist.daily[bestKey]
                prevClose = d[4] or d[1]
            end
        end
    end

    local baseline = prevClose or firstToday
    local dayDelta, dayDeltaPct = nil, nil
    if baseline and baseline > 0 and latestToday and latestToday > 0 then
        dayDelta = latestToday - baseline
        dayDeltaPct = (dayDelta / baseline) * 100
    end

    return {
        dayStart    = dayStart,
        dayEnd      = dayEnd,
        prevClose   = baseline,
        latestToday = latestToday,
        dayDelta    = dayDelta,
        dayDeltaPct = dayDeltaPct,
    }
end

--------------------------------------------------------------------------------
-- Build Unified Chronological Series for Charting
--------------------------------------------------------------------------------

-- Returns array of points:
-- { ts = number, min = copper, avg = copper, max = copper, qty = count, ma = copper, isDaily = bool }
function Analytics.BuildSeries(itemHist, timeframe, nowTs)
    if type(itemHist) ~= "table" then
        return {}
    end

    local now = nowTs or (time and time()) or 0
    local days = TIMEFRAME_DAYS[timeframe or "30D"]
    local cutoff = days and (now - days * 86400) or 0
    local points = {}

    local intraday = itemHist.intraday or {}
    local daily = itemHist.daily or {}

    if timeframe == "1D" then
        -- Google Finance 1D view: all data from today (00:00 -> 24:00) filling in as the day progresses
        local dayStart, dayEnd = Analytics.GetTodayBounds(now)
        for i = 1, #intraday do
            local pt = intraday[i]
            if pt[1] >= dayStart and pt[1] <= dayEnd then
                table.insert(points, {
                    ts      = pt[1],
                    min     = pt[2],
                    avg     = pt[3] or pt[2],
                    max     = pt[4] or pt[2],
                    qty     = pt[5] or 0,
                    isDaily = false,
                })
            end
        end

        -- If it's right after midnight and no point has landed today yet, fall back to rolling 24h
        if #points == 0 then
            for i = 1, #intraday do
                local pt = intraday[i]
                if pt[1] >= cutoff then
                    table.insert(points, {
                        ts      = pt[1],
                        min     = pt[2],
                        avg     = pt[3] or pt[2],
                        max     = pt[4] or pt[2],
                        qty     = pt[5] or 0,
                        isDaily = false,
                    })
                end
            end
        end
    elseif timeframe == "7D" then
        -- Intraday granularity for 7D
        for i = 1, #intraday do
            local pt = intraday[i]
            if pt[1] >= cutoff then
                table.insert(points, {
                    ts      = pt[1],
                    min     = pt[2],
                    avg     = pt[3] or pt[2],
                    max     = pt[4] or pt[2],
                    qty     = pt[5] or 0,
                    isDaily = false,
                })
            end
        end

        if #points == 0 then
            for dayKey, d in pairs(daily) do
                local ts = NS.TimestampFromDayKey(dayKey)
                if ts >= cutoff then
                    table.insert(points, {
                        ts      = ts,
                        min     = d[1],
                        avg     = d[2] or d[1],
                        max     = d[3] or d[1],
                        qty     = d[5] or 0,
                        isDaily = true,
                    })
                end
            end
        end
    else
        -- 30D / 90D / All: combine daily buckets + daily-aggregated recent intraday
        local byDay = {}

        for dayKey, d in pairs(daily) do
            local ts = NS.TimestampFromDayKey(dayKey)
            if ts >= cutoff then
                byDay[dayKey] = {
                    ts      = ts,
                    min     = d[1],
                    avg     = d[2] or d[1],
                    max     = d[3] or d[1],
                    qty     = d[5] or 0,
                    samples = d[6] or 1,
                    isDaily = true,
                }
            end
        end

        -- Aggregate intraday points into day buckets so 30D/90D/All have clean daily cadence
        for i = 1, #intraday do
            local pt = intraday[i]
            if pt[1] >= cutoff then
                local dayKey = NS.DayKeyFromTimestamp(pt[1])
                local b = byDay[dayKey]
                if not b then
                    byDay[dayKey] = {
                        ts      = pt[1],
                        min     = pt[2],
                        avg     = pt[3] or pt[2],
                        max     = pt[4] or pt[2],
                        qty     = pt[5] or 0,
                        samples = 1,
                        isDaily = true,
                    }
                else
                    local c = b.samples
                    local nc = c + 1
                    b.ts      = math.max(b.ts, pt[1])
                    b.min     = math.min(b.min, pt[2])
                    b.avg     = math.floor(((b.avg * c) + (pt[3] or pt[2])) / nc + 0.5)
                    b.max     = math.max(b.max, pt[4] or pt[2])
                    b.qty     = math.floor(((b.qty * c) + (pt[5] or 0)) / nc + 0.5)
                    b.samples = nc
                end
            end
        end

        for _, b in pairs(byDay) do
            table.insert(points, b)
        end
    end

    table.sort(points, function(a, b) return a.ts < b.ts end)

    -- Compute rolling Simple Moving Average (SMA)
    local window = (timeframe == "1D") and 4 or 7
    Analytics.ApplyMovingAverage(points, window)

    return points
end

function Analytics.ApplyMovingAverage(points, windowSize)
    local w = math.max(2, windowSize or 7)
    local runningSum = 0
    for i = 1, #points do
        runningSum = runningSum + points[i].min
        if i > w then
            runningSum = runningSum - points[i - w].min
        end
        local denom = math.min(i, w)
        points[i].ma = math.floor((runningSum / denom) + 0.5)
    end
    return points
end

--------------------------------------------------------------------------------
-- Item Summary Metrics & Buy/Sell Alerts
--------------------------------------------------------------------------------

function Analytics.Compute7DayAverage(itemHist, nowTs)
    if type(itemHist) ~= "table" then return nil end
    local now = nowTs or (time and time()) or 0
    local cutoff = now - (7 * 86400)
    local sum, count = 0, 0

    local intraday = itemHist.intraday or {}
    for i = 1, #intraday do
        local pt = intraday[i]
        if pt[1] >= cutoff and pt[2] and pt[2] > 0 then
            sum = sum + pt[2]
            count = count + 1
        end
    end

    if count == 0 then
        local daily = itemHist.daily or {}
        for dayKey, d in pairs(daily) do
            local ts = NS.TimestampFromDayKey(dayKey)
            if ts >= cutoff and d[1] and d[1] > 0 then
                sum = sum + d[1]
                count = count + 1
            end
        end
    end

    if count == 0 then return nil end
    return math.floor((sum / count) + 0.5)
end

function Analytics.GetLatestPoint(itemHist)
    if type(itemHist) ~= "table" then return nil end
    local intraday = itemHist.intraday
    if type(intraday) == "table" and #intraday > 0 then
        local last = intraday[#intraday]
        return {
            ts  = last[1],
            min = last[2],
            avg = last[3] or last[2],
            max = last[4] or last[2],
            qty = last[5] or 0,
        }
    end
    local daily = itemHist.daily
    if type(daily) == "table" then
        local bestKey = nil
        for k in pairs(daily) do
            if not bestKey or k > bestKey then
                bestKey = k
            end
        end
        if bestKey then
            local d = daily[bestKey]
            return {
                ts  = NS.TimestampFromDayKey(bestKey),
                min = d[4] or d[1],
                avg = d[2] or d[1],
                max = d[3] or d[1],
                qty = d[5] or 0,
            }
        end
    end
    return nil
end

function Analytics.EvaluateAlert(latestMin, buyTarget, sellTarget)
    if not latestMin or latestMin <= 0 then
        return "NONE"
    end
    if buyTarget and buyTarget > 0 and latestMin <= buyTarget then
        return "BUY"
    end
    if sellTarget and sellTarget > 0 and latestMin >= sellTarget then
        return "SELL"
    end
    return "NONE"
end

-- Checks whether an item's latest price is at its lowest point over the given timeframe
-- ("1D" = 24h, "7D" = 7 days, "30D" = 30 days).
-- Requires at least 2 samples in the window and actual price movement (periodHigh > periodLow)
-- so single-scan or flat items don't produce false "buy the dip" alerts.
function Analytics.IsAtPeriodLow(itemHist, timeframe, nowTs)
    if type(itemHist) ~= "table" then return false end
    local latest = Analytics.GetLatestPoint(itemHist)
    if not latest or not latest.min or latest.min <= 0 then
        return false
    end

    local now = nowTs or (time and time()) or 0
    local days = TIMEFRAME_DAYS[timeframe]
    if days and latest.ts and (now - latest.ts) > (days * 86400) then
        return false -- Latest scan is stale outside the window
    end

    local series
    if timeframe == "1D" then
        -- 24h Low always checks the true rolling 24-hour window (not just since 00:00 midnight)
        series = {}
        local cutoff24 = now - 86400
        local intraday = itemHist.intraday or {}
        for i = 1, #intraday do
            local pt = intraday[i]
            if pt[1] >= cutoff24 and pt[2] and pt[2] > 0 then
                table.insert(series, { ts = pt[1], min = pt[2] })
            end
        end
    else
        series = Analytics.BuildSeries(itemHist, timeframe, now)
    end
    if #series < 2 then
        return false
    end

    local minVal = series[1].min
    local maxVal = series[1].min
    for i = 2, #series do
        local v = series[i].min
        if v < minVal then minVal = v end
        if v > maxVal then maxVal = v end
    end

    return (maxVal > minVal) and (latest.min <= minVal)
end

function Analytics.CheckPeriodLows(itemHist, nowTs)
    return {
        low24h = Analytics.IsAtPeriodLow(itemHist, "1D", nowTs),
        low7d  = Analytics.IsAtPeriodLow(itemHist, "7D", nowTs),
        low30d = Analytics.IsAtPeriodLow(itemHist, "30D", nowTs),
    }
end

-- Computes how many units (and total copper) are listed at or below buyTarget.
-- Uses exact live order-book tiers from AH scans when available; falls back to Dip Wall estimate.
function Analytics.ComputeUnderTargetDepth(itemHist, buyTarget)
    if type(itemHist) ~= "table" or not buyTarget or buyTarget <= 0 then
        return nil
    end
    local ob = itemHist.orderBook
    if type(ob) ~= "table" then
        return nil
    end

    if type(ob.tiers) == "table" and #ob.tiers > 0 then
        local qty, cost = 0, 0
        for i = 1, #ob.tiers do
            local t = ob.tiers[i]
            if t[1] and t[1] <= buyTarget then
                qty = qty + (t[2] or 0)
                cost = cost + (t[1] * (t[2] or 0))
            else
                break
            end
        end
        return { qty = qty, cost = cost, exact = true }
    end

    local latest = Analytics.GetLatestPoint(itemHist)
    if latest and latest.min and latest.min > 0 and latest.min <= buyTarget and ob.wallQty and ob.wallQty > 0 then
        local wallCeil = math.ceil(latest.min * 1.10)
        if buyTarget >= wallCeil then
            return { qty = ob.wallQty, cost = ob.wallCost or (ob.wallQty * latest.min), exact = false, atLeast = true }
        end
        return { qty = nil, wallQty = ob.wallQty, wallCost = ob.wallCost, exact = false }
    end
    return nil
end

function Analytics.GetItemSummary(watchEntry, itemHist, timeframe, nowTs)
    local now = nowTs or (time and time()) or 0
    local latest = Analytics.GetLatestPoint(itemHist)
    local avg7d = Analytics.Compute7DayAverage(itemHist, now)
    local series = Analytics.BuildSeries(itemHist, timeframe or "30D", now)
    local series7d = (timeframe == "7D") and series or Analytics.BuildSeries(itemHist, "7D", now)
    local lows = Analytics.CheckPeriodLows(itemHist, now)
    local cutRate = Analytics.GetAHCutRate()

    local periodLow, periodHigh, periodSum = nil, nil, 0
    for i = 1, #series do
        local p = series[i]
        if not periodLow or p.min < periodLow then periodLow = p.min end
        if not periodHigh or p.max > periodHigh then periodHigh = p.max end
        periodSum = periodSum + p.min
    end
    local periodAvg = (#series > 0) and math.floor((periodSum / #series) + 0.5) or nil

    -- 7-day volatility (price swing %) & liquidity rating
    local low7d, high7d = nil, nil
    for i = 1, #series7d do
        local p = series7d[i]
        if not low7d or p.min < low7d then low7d = p.min end
        if not high7d or p.min > high7d then high7d = p.min end
    end
    local swing7dPct = nil
    if low7d and high7d and low7d > 0 and #series7d >= 2 then
        swing7dPct = ((high7d - low7d) / low7d) * 100
    end

    local latestMin = latest and latest.min or nil
    local latestQty = latest and latest.qty or 0
    local liquidityTier = "Low"
    if latestQty >= 150 then
        liquidityTier = "High"
    elseif latestQty >= 30 then
        liquidityTier = "Med"
    end

    local delta7dPct = nil
    if latestMin and avg7d and avg7d > 0 then
        delta7dPct = ((latestMin - avg7d) / avg7d) * 100
    end

    -- 5% (or 15% Neutral) AH-cut Break-Even, Historical Dip ROI, and Live Order-Book Snipe Detection
    local ob = (itemHist and type(itemHist.orderBook) == "table") and itemHist.orderBook or nil
    local wallQty = ob and ob.wallQty or nil
    local wallCost = ob and ob.wallCost or nil
    local wallNextPrice = ob and ob.nextPrice or nil

    local breakEven = nil
    local estNetProfit = nil
    local estRoiPct = nil
    local isDipFlip = false

    local snipeNetProfit = nil
    local snipeRoiPct = nil
    local isSnipeFlip = false

    if latestMin and latestMin > 0 then
        breakEven = math.ceil(latestMin / (1 - cutRate))

        -- A. Historical 7D Dip Flip (current price well below 7-day average)
        if avg7d and avg7d > 0 then
            estNetProfit = math.floor((avg7d * (1 - cutRate)) - latestMin + 0.5)
            estRoiPct = (estNetProfit / latestMin) * 100
            if #series7d >= 2 and estRoiPct >= 15 and estNetProfit >= 200 then
                isDipFlip = true
            end
        end

        -- B. Live Order-Book Undercut Snipe (works on Day 1! Detects mispriced undercuts below core market)
        local latestAvg = latest and latest.avg or nil
        if latestAvg and latestAvg > latestMin and latestQty >= 5 then
            local conservativeTarget = latestAvg
            if wallNextPrice and wallNextPrice > latestMin and wallNextPrice < conservativeTarget then
                conservativeTarget = wallNextPrice
            end
            snipeNetProfit = math.floor((conservativeTarget * (1 - cutRate)) - latestMin + 0.5)
            snipeRoiPct = (snipeNetProfit / latestMin) * 100
            local thinWall = (not wallQty) or (wallQty < latestQty and wallQty <= math.max(30, math.floor(latestQty * 0.45)))
            if thinWall and snipeRoiPct >= 20 and snipeNetProfit >= 200 then
                isSnipeFlip = true
            end
        end
    end

    local isHotFlip = isSnipeFlip or isDipFlip
    local flipType = isSnipeFlip and "SNIPE" or (isDipFlip and "DIP" or nil)
    local bestFlipRoiPct = estRoiPct
    if isSnipeFlip and (not bestFlipRoiPct or (snipeRoiPct and snipeRoiPct > bestFlipRoiPct)) then
        bestFlipRoiPct = snipeRoiPct
    end
    local bestFlipProfit = estNetProfit
    if isSnipeFlip and (not bestFlipProfit or (snipeNetProfit and snipeNetProfit > bestFlipProfit)) then
        bestFlipProfit = snipeNetProfit
    end

    local periodDeltaPct = nil
    if #series >= 2 and series[1].min > 0 then
        periodDeltaPct = ((series[#series].min - series[1].min) / series[1].min) * 100
    end

    -- Account-wide explicit investment position evaluation (never auto-includes junk)
    local itemID = watchEntry and watchEntry.itemID or nil
    local inv = (itemID and NS.DB and NS.DB:GetInvestment(itemID)) or nil
    local investQty = (inv and inv.qty and inv.qty > 0) and inv.qty or 0
    local investAvgCost = (investQty > 0) and inv.avgCost or nil
    local investBreakEven = (investAvgCost and investAvgCost > 0) and math.ceil(investAvgCost / (1 - cutRate)) or nil
    local investUnrealizedPnL = nil
    local investUnrealizedPct = nil
    if investQty > 0 and investAvgCost and investAvgCost > 0 and latestMin and latestMin > 0 then
        local netVal = math.floor((investQty * latestMin) * (1 - cutRate) + 0.5)
        local cost = inv.totalCost or (investQty * investAvgCost)
        investUnrealizedPnL = netVal - cost
        if cost > 0 then
            investUnrealizedPct = (investUnrealizedPnL / cost) * 100
        end
    end

    local buyTarget = watchEntry and watchEntry.buyTarget or nil
    local sellTarget = watchEntry and watchEntry.sellTarget or nil
    local alert = Analytics.EvaluateAlert(latestMin, buyTarget, sellTarget)

    return {
        latestMin           = latestMin,
        latestAvg           = latest and latest.avg or nil,
        latestMax           = latest and latest.max or nil,
        latestQty           = latestQty,
        lastScan            = (itemHist and itemHist.lastScan) or (latest and latest.ts) or 0,
        avg7d               = avg7d,
        delta7dPct          = delta7dPct,
        periodLow           = periodLow,
        periodHigh          = periodHigh,
        periodAvg           = periodAvg,
        periodDeltaPct      = periodDeltaPct,
        swing7dPct          = swing7dPct,
        liquidityTier       = liquidityTier,
        ahCutRate           = cutRate,
        breakEven           = breakEven,
        estNetProfit        = estNetProfit,
        estRoiPct           = estRoiPct,
        snipeNetProfit      = snipeNetProfit,
        snipeRoiPct         = snipeRoiPct,
        bestFlipRoiPct      = bestFlipRoiPct,
        bestFlipProfit      = bestFlipProfit,
        flipType            = flipType,
        isDipFlip           = isDipFlip,
        isSnipeFlip         = isSnipeFlip,
        isHotFlip           = isHotFlip,
        wallQty             = wallQty,
        wallCost            = wallCost,
        wallNextPrice       = wallNextPrice,
        investment          = inv,
        investQty           = investQty,
        investAvgCost       = investAvgCost,
        investBreakEven     = investBreakEven,
        investUnrealizedPnL = investUnrealizedPnL,
        investUnrealizedPct = investUnrealizedPct,
        sampleCount         = #series,
        alert               = alert,
        low24h              = lows.low24h,
        low7d               = lows.low7d,
        low30d              = lows.low30d,
        series              = series,
    }
end

--------------------------------------------------------------------------------
-- Data-Driven Buy/Sell Target Analytics (Percentiles, Hit Rates & Presets)
--------------------------------------------------------------------------------

local function CollectTargetSamples(itemHist, daysWindow, nowTs)
    if type(itemHist) ~= "table" then return {}, "7D" end
    local now = nowTs or (time and time()) or 0
    local days = daysWindow or 7
    local cutoff = now - (days * 86400)

    local function Gather(minTs)
        local vals = {}
        local intraday = itemHist.intraday or {}
        for i = 1, #intraday do
            local pt = intraday[i]
            if pt[1] and pt[1] >= minTs and pt[2] and pt[2] > 0 then
                table.insert(vals, pt[2])
            end
        end
        local daily = itemHist.daily or {}
        for dayKey, d in pairs(daily) do
            local ts = NS.TimestampFromDayKey(dayKey)
            if ts >= minTs and d[1] and d[1] > 0 then
                -- Only include daily buckets older than intraday retention to avoid double-weighting
                if ts < (now - (7 * 86400)) or #vals < 6 then
                    table.insert(vals, d[1])
                end
            end
        end
        return vals
    end

    local vals = Gather(cutoff)
    local label = tostring(days) .. "D"
    if #vals < 6 then
        local vals30 = Gather(now - (30 * 86400))
        if #vals30 > #vals then
            vals = vals30
            label = "30D"
        end
    end
    if #vals < 6 then
        local valsAll = Gather(0)
        if #valsAll > #vals then
            vals = valsAll
            label = "All"
        end
    end

    table.sort(vals)
    return vals, label
end

local function Percentile(sorted, p)
    local n = #sorted
    if n == 0 then return nil end
    if n == 1 then return sorted[1] end
    local pos = 1 + (n - 1) * p
    local lo = math.floor(pos)
    local hi = math.ceil(pos)
    if lo == hi then
        return sorted[lo]
    end
    local frac = pos - lo
    return math.floor(sorted[lo] + (sorted[hi] - sorted[lo]) * frac + 0.5)
end

-- Evaluates any custom (or preset) Buy & Sell target pair against historical scans:
-- returns netProfit, netRoiPct, breakEven, buyHitPct, sellHitPct, verdict, verdictColor.
function Analytics.EvaluateTargetPlan(itemHist, buyTarget, sellTarget, daysWindow, nowTs)
    local cutRate = Analytics.GetAHCutRate()
    local samples, windowLabel = CollectTargetSamples(itemHist, daysWindow or 7, nowTs)
    local n = #samples

    local buy = (buyTarget and buyTarget > 0) and math.floor(buyTarget + 0.5) or nil
    local sell = (sellTarget and sellTarget > 0) and math.floor(sellTarget + 0.5) or nil

    local buyHits, sellHits = 0, 0
    for i = 1, n do
        local v = samples[i]
        if buy and v <= buy then buyHits = buyHits + 1 end
        if sell and v >= sell then sellHits = sellHits + 1 end
    end

    local buyHitPct = (n > 0 and buy) and ((buyHits / n) * 100) or nil
    local sellHitPct = (n > 0 and sell) and ((sellHits / n) * 100) or nil

    local breakEven = buy and math.ceil(buy / (1 - cutRate)) or nil
    local netProfit, netRoiPct = nil, nil
    if buy and sell then
        netProfit = math.floor((sell * (1 - cutRate)) - buy + 0.5)
        netRoiPct = (buy > 0) and ((netProfit / buy) * 100) or nil
    end

    local verdict = "Set Buy & Sell"
    local verdictHex = "|cFF998C78"
    if buy and sell then
        if netProfit <= 0 then
            verdict = "Loss after 5% cut!"
            verdictHex = "|cFFF55954"
        elseif n >= 4 and ((buyHitPct and buyHitPct < 3) or (sellHitPct and sellHitPct < 3)) then
            verdict = "Rarely fills"
            verdictHex = "|cFFFFA030"
        elseif netRoiPct and netRoiPct >= 12 and (not buyHitPct or buyHitPct >= 8) and (not sellHitPct or sellHitPct >= 8) then
            verdict = "Strong flip"
            verdictHex = "|cFF38D972"
        elseif netRoiPct and netRoiPct >= 5 then
            verdict = "Tight margin"
            verdictHex = "|cFFFFD100"
        else
            verdict = "Very thin margin"
            verdictHex = "|cFFFFA030"
        end
    elseif buy then
        verdict = (buyHitPct and buyHitPct >= 5) and "Buy alert active" or "Deep buy alert"
        verdictHex = "|cFF38D972"
    elseif sell then
        verdict = (sellHitPct and sellHitPct >= 5) and "Sell alert active" or "High sell alert"
        verdictHex = "|cFFFFD100"
    end

    return {
        sampleCount = n,
        windowLabel = windowLabel,
        buyTarget   = buy,
        sellTarget  = sell,
        breakEven   = breakEven,
        netProfit   = netProfit,
        netRoiPct   = netRoiPct,
        buyHits     = buyHits,
        sellHits    = sellHits,
        buyHitPct   = buyHitPct,
        sellHitPct  = sellHitPct,
        verdict     = verdict,
        verdictHex  = verdictHex,
    }
end

-- Computes outlier-resistant percentile target recommendations (Quick / Balanced / Sniper)
-- using live 24/7 hourly price history + 5% AH cut enforcement + weekday seasonality.
function Analytics.RecommendTargets(itemHist, daysWindow, nowTs)
    local cutRate = Analytics.GetAHCutRate()
    local samples, windowLabel = CollectTargetSamples(itemHist, daysWindow or 7, nowTs)
    local n = #samples
    if n < 3 then
        return {
            ready       = false,
            sampleCount = n,
            windowLabel = windowLabel,
            reason      = "Need at least 3 price scans for statistical targets.",
        }
    end

    local p10 = Percentile(samples, 0.10)
    local p20 = Percentile(samples, 0.20)
    local p30 = Percentile(samples, 0.30)
    local p50 = Percentile(samples, 0.50)
    local p70 = Percentile(samples, 0.70)
    local p80 = Percentile(samples, 0.80)
    local p90 = Percentile(samples, 0.90)

    local function BuildPreset(id, label, desc, rawBuy, rawSell, minNetMargin)
        local buy = math.max(1, rawBuy)
        local sell = math.max(buy + 1, rawSell)
        local minProfitableSell = math.ceil((buy * (1 + minNetMargin)) / (1 - cutRate))
        local adjusted = false
        if sell < minProfitableSell then
            -- Try nudging sell up to P90 first, or buy down to P10 if flat
            if p90 >= minProfitableSell then
                sell = minProfitableSell
                adjusted = true
            else
                sell = math.max(sell, math.ceil((buy * 1.03) / (1 - cutRate)))
                adjusted = true
            end
        end
        local eval = Analytics.EvaluateTargetPlan(itemHist, buy, sell, daysWindow or 7, nowTs)
        return {
            id          = id,
            label       = label,
            desc        = desc,
            buy         = buy,
            sell        = sell,
            netProfit   = eval.netProfit,
            netRoiPct   = eval.netRoiPct,
            buyHitPct   = eval.buyHitPct,
            sellHitPct  = eval.sellHitPct,
            viable      = (eval.netProfit or 0) > 0,
            adjusted    = adjusted,
        }
    end

    local presets = {
        BuildPreset("quick",    "Quick",    "Fast fills (P30 -> P70)",  p30, p70, 0.06),
        BuildPreset("balanced", "Balanced", "Sweet spot (P20 -> P80)",  p20, p80, 0.10),
        BuildPreset("sniper",   "Sniper",   "Max margin (P10 -> P90)",  p10, p90, 0.15),
    }

    -- Weekday seasonality insight (when >= 3 distinct days exist)
    local cyc = Analytics.ComputeDayOfWeekCycle(itemHist, "30D", nowTs)
    local bestBuyDay  = (cyc and cyc.validDays >= 3) and cyc.bestBuyDay or nil
    local bestSellDay = (cyc and cyc.validDays >= 3) and cyc.bestSellDay or nil

    -- Check if item actually swings enough to be worth flipping after 5% AH cut
    local trimSwingPct = (p10 and p10 > 0) and (((p90 - p10) / p10) * 100) or 0
    local flippable = (presets[2].netRoiPct and presets[2].netRoiPct >= 8) or (presets[3].netRoiPct and presets[3].netRoiPct >= 12)

    return {
        ready        = true,
        sampleCount  = n,
        windowLabel  = windowLabel,
        p10          = p10,
        p20          = p20,
        p30          = p30,
        median       = p50,
        p70          = p70,
        p80          = p80,
        p90          = p90,
        trimSwingPct = trimSwingPct,
        flippable    = flippable,
        bestBuyDay   = bestBuyDay,
        bestSellDay  = bestSellDay,
        presets      = presets,
    }
end
