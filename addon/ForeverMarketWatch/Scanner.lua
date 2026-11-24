-- Scanner.lua
-- C_AuctionHouse throttled watchlist/group scanner, passive browsing capture,
-- live AH name search (SendBrowseQuery), configurable auto-scan on AH open,
-- and Quick-Buy jump integration.

local _, NS = ...

local Scanner = {}
NS.Scanner = Scanner

local ahOpen = false
local isScanning = false
local isAutoScan = false
local scanQueue = {}
local scanIndex = 0
local scanTotal = 0
local currentItemID = nil
local waitingForResult = false
local retryCount = 0
local itemTimeoutTimer = nil
local autoScanDelayTimer = nil
local periodicScanTimer = nil
local nextAutoScanAt = 0
local lastViewedItemID = nil
local pendingBrowseSearchQuery = nil
local queuedBrowseQueryToSend = nil
local browseSearchTimeoutTimer = nil
local lastSearchResultRows = nil
local pendingOwnedPriceScan = false

local ITEM_TIMEOUT_SECONDS = 4.0
local MAX_RETRIES_PER_ITEM = 1
local AUTO_SCAN_DELAY_SECONDS = 1.5

local function GetPriceSort()
    if Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price then
        return { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    end
    return {}
end

local function CancelTimer(timerObj)
    if timerObj and timerObj.Cancel then
        timerObj:Cancel()
    end
    return nil
end

local function IsThrottleReady()
    if C_AuctionHouse and C_AuctionHouse.IsThrottledMessageSystemReady then
        return C_AuctionHouse.IsThrottledMessageSystemReady()
    end
    return true
end

--------------------------------------------------------------------------------
-- Public State Queries
--------------------------------------------------------------------------------

function Scanner:IsAuctionHouseOpen()
    return ahOpen
end

function Scanner:IsScanning()
    return isScanning
end

function Scanner:GetLastViewedItemID()
    return lastViewedItemID
end

function Scanner:GetProgress()
    return scanIndex, scanTotal, currentItemID
end

function Scanner:GetNextAutoScanSeconds()
    if not ahOpen or nextAutoScanAt <= 0 then return nil end
    local rem = nextAutoScanAt - time()
    return rem > 0 and rem or 0
end

function Scanner:ReschedulePeriodicScan()
    periodicScanTimer = CancelTimer(periodicScanTimer)
    nextAutoScanAt = 0
    if not ahOpen or NS.DB:IsDemoMode() then return end

    local settings = NS.DB:GetSettings()
    local intervalMin = tonumber(settings.autoScanIntervalMinutes) or 0
    if intervalMin <= 0 then return end

    local intervalSec = intervalMin * 60
    nextAutoScanAt = time() + intervalSec
    if C_Timer and C_Timer.NewTimer then
        periodicScanTimer = C_Timer.NewTimer(intervalSec, function()
            nextAutoScanAt = 0
            if ahOpen and not isScanning and not NS.DB:IsDemoMode() then
                Scanner:StartWatchlistScan(true)
            else
                Scanner:ReschedulePeriodicScan()
            end
        end)
    end
end

--------------------------------------------------------------------------------
-- Listing Price Aggregation (Outlier-Resistant)
--------------------------------------------------------------------------------

local function AggregateEntries(entries)
    if not entries or #entries == 0 then
        return nil
    end

    table.sort(entries, function(a, b) return a.price < b.price end)

    local totalQty = 0
    for i = 1, #entries do
        totalQty = totalQty + entries[i].qty
    end
    if totalQty <= 0 then
        return nil
    end

    local minPrice = entries[1].price

    local coreTarget = math.max(1, math.ceil(totalQty * 0.50))
    local coreQty = 0
    local coreSum = 0

    local p90Target = math.max(1, math.ceil(totalQty * 0.90))
    local p90Price = minPrice

    local cumQty = 0
    for i = 1, #entries do
        local e = entries[i]
        if coreQty < coreTarget then
            local take = math.min(e.qty, coreTarget - coreQty)
            coreSum = coreSum + (e.price * take)
            coreQty = coreQty + take
        end
        cumQty = cumQty + e.qty
        if cumQty >= p90Target and p90Price == minPrice and i > 1 then
            p90Price = e.price
        end
    end

    local avgPrice = (coreQty > 0) and math.floor((coreSum / coreQty) + 0.5) or minPrice
    local maxCap = minPrice * 5
    local maxPrice = math.min(p90Price, maxCap)
    if maxPrice < minPrice then maxPrice = minPrice end

    -- Dip Wall (+10% reset cost): total units & gold within 10% above lowest buyout
    local wallCeiling = math.ceil(minPrice * 1.10)
    local wallQty, wallCost, nextPrice = 0, 0, minPrice
    for i = 1, #entries do
        local e = entries[i]
        if e.price <= wallCeiling then
            wallQty = wallQty + e.qty
            wallCost = wallCost + (e.price * e.qty)
        else
            nextPrice = e.price
            break
        end
    end

    -- Capture top 20 cheapest price tiers so the Flipping tab can calculate exact
    -- quantity & total gold needed to buy out everything <= your Buy Target!
    local tiers = {}
    for i = 1, #entries do
        local e = entries[i]
        local lastTier = tiers[#tiers]
        if lastTier and lastTier[1] == e.price then
            lastTier[2] = lastTier[2] + e.qty
        elseif #tiers < 20 then
            table.insert(tiers, { e.price, e.qty })
        else
            break
        end
    end

    local orderBook = {
        wallQty   = wallQty,
        wallCost  = wallCost,
        nextPrice = nextPrice,
        tiers     = tiers,
    }

    return minPrice, avgPrice, maxPrice, totalQty, orderBook
end

local function ProcessCommodityResults(itemID, isPassive)
    if not C_AuctionHouse or not C_AuctionHouse.GetNumCommoditySearchResults then
        return false
    end
    local count = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
    if count <= 0 then
        return false
    end

    local entries = {}
    for i = 1, count do
        local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if info and info.unitPrice and info.unitPrice > 0 and info.quantity and info.quantity > 0 then
            table.insert(entries, { price = info.unitPrice, qty = info.quantity })
        end
    end

    local minP, avgP, maxP, totalQty, orderBook = AggregateEntries(entries)
    if minP then
        NS.DB:RecordSnapshot(itemID, minP, avgP, maxP, totalQty, time(), isPassive, nil, orderBook)
        return true
    end
    return false
end

local function ProcessItemResults(itemKey, isPassive)
    if not itemKey or not itemKey.itemID then return false end
    if not C_AuctionHouse or not C_AuctionHouse.GetNumItemSearchResults then
        return false
    end
    local count = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
    if count <= 0 then
        return false
    end

    local entries = {}
    for i = 1, count do
        local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if info then
            local buyout = info.buyoutAmount or 0
            local qty = info.quantity or 1
            if buyout > 0 and qty > 0 then
                local unitPrice = math.floor((buyout / qty) + 0.5)
                table.insert(entries, { price = unitPrice, qty = qty })
            end
        end
    end

    local minP, avgP, maxP, totalQty, orderBook = AggregateEntries(entries)
    if minP then
        NS.DB:RecordSnapshot(itemKey.itemID, minP, avgP, maxP, totalQty, time(), isPassive, nil, orderBook)
        return true
    end
    return false
end

local function ProcessBrowseResults()
    if not C_AuctionHouse or not C_AuctionHouse.GetBrowseResults then return end

    local results = C_AuctionHouse.GetBrowseResults()
    if type(results) ~= "table" then results = {} end

    -- Skip massive full-AH browse dumps (e.g. Auctionator Full Scan) so we NEVER lag other AH addons.
    if not pendingBrowseSearchQuery and (#results == 0 or #results > 100) then
        return
    end

    local settings = NS.DB:GetSettings()
    local now = time()
    local searchRows = {}
    local seen = {}
    local recordedAny = false

    local maxToScan = pendingBrowseSearchQuery and math.min(#results, 50) or math.min(#results, 100)
    for i = 1, maxToScan do
        local r = results[i]
        if r and r.itemKey and r.itemKey.itemID then
            local itemID = r.itemKey.itemID
            local minPrice = r.minPrice or 0
            local qty = r.totalQuantity or 0

            if settings.passiveCapture and minPrice > 0 then
                if NS.DB:RecordSnapshot(itemID, minPrice, minPrice, minPrice, math.max(1, qty), now, true, nil, nil, true) then
                    recordedAny = true
                end
            end

            if pendingBrowseSearchQuery and not seen[itemID] and #searchRows < 14 then
                seen[itemID] = true
                local name, _, quality, _, _, _, _, _, _, icon = NS.Compat.GetItemInfo(itemID)
                local keyInfo = C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(r.itemKey) or nil
                if not name then
                    NS.Compat.RequestLoadItemDataByID(itemID)
                end
                local displayName = name or (keyInfo and keyInfo.itemName) or ("Item #" .. tostring(itemID))
                local displayIcon = icon or (keyInfo and keyInfo.iconFileID) or NS.Compat.GetItemIconByID(itemID) or 134400
                local displayQual = quality ~= nil and quality or (keyInfo and keyInfo.quality) or 1

                table.insert(searchRows, {
                    itemID  = itemID,
                    itemKey = r.itemKey,
                    name    = displayName,
                    icon    = displayIcon,
                    quality = displayQual,
                    price   = minPrice > 0 and minPrice or nil,
                    qty     = qty,
                    source  = "Live AH",
                    watched = NS.DB:GetWatchItem(itemID) ~= nil,
                })
            end
        end
    end

    if recordedAny then
        NS:FireCallback("HISTORY_UPDATED", nil, true)
    end

    if pendingBrowseSearchQuery then
        browseSearchTimeoutTimer = CancelTimer(browseSearchTimeoutTimer)
        local q = pendingBrowseSearchQuery
        pendingBrowseSearchQuery = nil
        lastSearchResultRows = { query = q, rows = searchRows }
        NS:FireCallback("AH_SEARCH_RESULTS", q, searchRows)
    end
end

--------------------------------------------------------------------------------
-- Live AH Name Search (SendBrowseQuery — Throttle-Safe!)
--------------------------------------------------------------------------------

local function DispatchQueuedBrowseSearch()
    if not queuedBrowseQueryToSend or not ahOpen then return end
    if not IsThrottleReady() then return end

    local clean = queuedBrowseQueryToSend
    queuedBrowseQueryToSend = nil
    pendingBrowseSearchQuery = clean

    local browseQuery = {
        searchString = clean,
        sorts        = GetPriceSort(),
        filters      = {},
    }

    local ok = pcall(function()
        C_AuctionHouse.SendBrowseQuery(browseQuery)
    end)
    if not ok then
        pendingBrowseSearchQuery = nil
        NS:FireCallback("AH_SEARCH_RESULTS", clean, {})
        return
    end

    browseSearchTimeoutTimer = CancelTimer(browseSearchTimeoutTimer)
    if C_Timer and C_Timer.NewTimer then
        browseSearchTimeoutTimer = C_Timer.NewTimer(3.5, function()
            if pendingBrowseSearchQuery == clean then
                pendingBrowseSearchQuery = nil
                NS:FireCallback("AH_SEARCH_RESULTS", clean, {})
            end
        end)
    end
end

function Scanner:SearchAHByName(query)
    if not ahOpen then
        NS.Print("Open the Auction House to run a live AH search. Offline catalog & bag matches still appear as you type!")
        return false
    end
    if type(query) ~= "string" then return false end
    local clean = query:match("^%s*(.-)%s*$")
    if clean == "" then return false end

    if not C_AuctionHouse or not C_AuctionHouse.SendBrowseQuery then
        NS.PrintError("Live AH Browse API is unavailable.")
        return false
    end

    if isScanning then
        self:StopScan("USER_SEARCH")
    end

    queuedBrowseQueryToSend = clean
    DispatchQueuedBrowseSearch()
    return true
end

--------------------------------------------------------------------------------
-- Throttled Scan Queue Execution
--------------------------------------------------------------------------------

local function FinishScan(reason)
    itemTimeoutTimer = CancelTimer(itemTimeoutTimer)
    local completed = scanIndex
    local total = scanTotal
    local wasAuto = isAutoScan

    isScanning = false
    isAutoScan = false
    waitingForResult = false
    currentItemID = nil
    scanQueue = {}
    scanIndex = 0
    scanTotal = 0
    retryCount = 0

    if not wasAuto and reason == "DONE" and total > 0 then
        NS.Print(string.format("Scan complete (%d/%d items checked).", completed, total))
    elseif wasAuto and reason == "DONE" and total > 0 then
        NS.Print(string.format("Auto-scan updated %d items.", completed))
    end
    NS:FireCallback("SCAN_STATE_CHANGED", false, completed, total, reason)

    -- Schedule next periodic auto-scan while standing at the AH
    if ahOpen and reason ~= "AH_CLOSED" then
        Scanner:ReschedulePeriodicScan()
    end
end

local function AdvanceQueue()
    itemTimeoutTimer = CancelTimer(itemTimeoutTimer)
    waitingForResult = false
    currentItemID = nil
    retryCount = 0

    if not isScanning or not ahOpen then
        FinishScan("STOPPED")
        return
    end

    if scanIndex >= scanTotal then
        FinishScan("DONE")
        return
    end

    Scanner:TrySendNext()
end

function Scanner:TrySendNext()
    if not isScanning or not ahOpen then return end
    if waitingForResult then return end
    if scanIndex >= scanTotal then
        FinishScan("DONE")
        return
    end

    if not IsThrottleReady() then
        return
    end

    if not C_AuctionHouse or not C_AuctionHouse.MakeItemKey or not C_AuctionHouse.SendSearchQuery then
        NS.PrintError("C_AuctionHouse API unavailable on this client.")
        FinishScan("UNAVAILABLE")
        return
    end

    scanIndex = scanIndex + 1
    currentItemID = scanQueue[scanIndex]
    waitingForResult = true
    retryCount = 0

    NS:FireCallback("SCAN_PROGRESS", scanIndex, scanTotal, currentItemID)

    local itemKey = C_AuctionHouse.MakeItemKey(currentItemID)
    C_AuctionHouse.SendSearchQuery(itemKey, GetPriceSort(), false)

    itemTimeoutTimer = CancelTimer(itemTimeoutTimer)
    if C_Timer and C_Timer.NewTimer then
        local expectedID = currentItemID
        itemTimeoutTimer = C_Timer.NewTimer(ITEM_TIMEOUT_SECONDS, function()
            if isScanning and waitingForResult and currentItemID == expectedID then
                AdvanceQueue()
            end
        end)
    end
end

function Scanner:StartWatchlistScan(autoTriggered, groupFilter)
    if NS.DB:IsDemoMode() then
        if not autoTriggered then
            NS.Print("Demo Mode is active. Run /fmw demo to exit Demo Mode before scanning live AH.")
        end
        return false
    end
    if not ahOpen then
        if not autoTriggered then
            NS.Print("Open the Auction House to scan prices.")
        end
        return false
    end
    if isScanning then
        return false
    end

    local ids = NS.DB:GetWatchedItemIDs(groupFilter)
    if #ids == 0 then
        if not autoTriggered then
            NS.Print("No items in this group to scan.")
        end
        return false
    end

    scanQueue = ids
    scanTotal = #ids
    scanIndex = 0
    isScanning = true
    isAutoScan = autoTriggered and true or false
    waitingForResult = false
    currentItemID = nil

    if autoTriggered then
        local market = NS.DB:GetActiveMarket()
        market.lastAutoScan = time()
    end

    NS:FireCallback("SCAN_STATE_CHANGED", true, 0, scanTotal, "STARTED")
    self:TrySendNext()
    return true
end

function Scanner:StartDashboardScan()
    if NS.DB:IsDemoMode() then
        NS.Print("Demo Mode is active. Run /fmw demo to exit Demo Mode before scanning live AH.")
        return false
    end
    if not ahOpen then
        NS.Print("Open the Auction House to scan your Dashboard items.")
        return false
    end
    if isScanning then
        self:StopScan("REPLACED")
    end

    local ids = NS.DB:GetDashboardPinnedIDs()
    if #ids == 0 then
        NS.Print("No pinned items or investments on your Dashboard to scan yet.")
        return false
    end

    scanQueue = ids
    scanTotal = #ids
    scanIndex = 0
    isScanning = true
    isAutoScan = false
    waitingForResult = false
    currentItemID = nil

    NS:FireCallback("SCAN_STATE_CHANGED", true, 0, scanTotal, "STARTED")
    self:TrySendNext()
    return true
end

function Scanner:StartTargetScan()
    if NS.DB:IsDemoMode() then
        NS.Print("Demo Mode is active. Run /fmw demo to exit Demo Mode before scanning live AH.")
        return false
    end
    if not ahOpen then
        NS.Print("Open the Auction House to scan your Flipping targets.")
        return false
    end
    if isScanning then
        self:StopScan("REPLACED")
    end

    local ids = NS.DB:GetTargetedItemIDs()
    if #ids == 0 then
        NS.Print("No items have Buy/Sell targets set yet.")
        return false
    end

    scanQueue = ids
    scanTotal = #ids
    scanIndex = 0
    isScanning = true
    isAutoScan = false
    waitingForResult = false
    currentItemID = nil

    NS:FireCallback("SCAN_STATE_CHANGED", true, 0, scanTotal, "STARTED")
    self:TrySendNext()
    return true
end

function Scanner:ScanSingleItem(itemID)
    if NS.DB:IsDemoMode() then
        NS.Print("Demo Mode is active. Exit Demo Mode (/fmw demo) to scan live AH.")
        return false
    end
    if not ahOpen then
        NS.Print("Open the Auction House to scan this item.")
        return false
    end
    if not itemID then return false end

    if isScanning then
        self:StopScan("REPLACED")
    end

    scanQueue = { itemID }
    scanTotal = 1
    scanIndex = 0
    isScanning = true
    isAutoScan = false
    waitingForResult = false
    currentItemID = nil

    NS:FireCallback("SCAN_STATE_CHANGED", true, 0, 1, "STARTED")
    self:TrySendNext()
    return true
end

function Scanner:StopScan(reason)
    if not isScanning then return end
    FinishScan(reason or "CANCELLED")
end

--------------------------------------------------------------------------------
-- Quick "Buy" / Jump Directly to AH Listing
--------------------------------------------------------------------------------

local function ResolveItemNameForBuy(itemID)
    local liveName = NS.Compat.GetItemInfo(itemID)
    if liveName and liveName ~= "" then return liveName end

    local watch = NS.DB and NS.DB:GetWatchItem(itemID)
    if watch and watch.name and watch.name ~= "" and not watch.name:match("^Item #%d+$") then
        return watch.name
    end

    local hist = NS.DB and NS.DB:GetItemHistory(itemID)
    if hist and hist.name and hist.name ~= "" and not hist.name:match("^Item #%d+$") then
        return hist.name
    end

    local cat = NS.Catalog and NS.Catalog.BY_ID and NS.Catalog.BY_ID[itemID]
    if cat and cat[2] and cat[2] ~= "" then
        return cat[2]
    end

    return nil
end

function Scanner:JumpToItemInAH(itemID, snipeInfo)
    if not ahOpen or not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
        NS.Print("Open the Auction House to jump to live listings.")
        return false
    end
    if not itemID then return false end

    if isScanning then
        self:StopScan("QUICK_BUY")
    end

    NS:FireCallback("HIDE_AH_OVERLAY")

    local itemName = ResolveItemNameForBuy(itemID)

    -- Print a quick 1-line snipe cheat sheet so exact qty & max price stay visible in chat
    if type(snipeInfo) == "table" and snipeInfo.buyTarget and snipeInfo.buyTarget > 0 then
        local label = itemName or ("Item #" .. tostring(itemID))
        if snipeInfo.underQty and snipeInfo.underQty > 0 and snipeInfo.underCost then
            NS.Print(string.format(
                "|cFF22EB70[SNIPE]|r %s: |cFFFFD100%d|r unit(s) <= %s (%s total) — type |cFFFFD100%d|r to buy all under target.",
                label, snipeInfo.underQty, NS.FormatMoney(snipeInfo.buyTarget, true), NS.FormatMoney(snipeInfo.underCost, true), snipeInfo.underQty
            ))
        else
            NS.Print(string.format(
                "|cFF22EB70[SNIPE]|r %s: buy all listings <= %s (run Scan Targets for exact unit count).",
                label, NS.FormatMoney(snipeInfo.buyTarget, true)
            ))
        end
    end

    -- 1. Preferred: Jump straight to Auctionator's Shopping tab and run an exact search for this item
    if itemName and AuctionatorTabs_Shopping then
        local cleanName = itemName:gsub('["%^;]', "")
        local exactTerm = '"' .. cleanName .. '"'

        local okDirect = pcall(function()
            AuctionatorTabs_Shopping:Click()
            if AuctionatorShoppingFrame and AuctionatorShoppingFrame.DoSearch then
                if AuctionatorShoppingFrame.SearchOptions and AuctionatorShoppingFrame.SearchOptions.SetSearchTerm then
                    AuctionatorShoppingFrame.SearchOptions:SetSearchTerm(exactTerm)
                end
                AuctionatorShoppingFrame.singleSearch = true
                AuctionatorShoppingFrame:DoSearch({ exactTerm })
                if Auctionator and Auctionator.Shopping and Auctionator.Shopping.Recents and Auctionator.Shopping.Recents.Save then
                    Auctionator.Shopping.Recents.Save(exactTerm)
                end
            elseif Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.MultiSearchExact then
                Auctionator.API.v1.MultiSearchExact("ForeverMarketWatch", { cleanName })
            end
        end)
        if okDirect then
            lastViewedItemID = itemID
            return true
        end
    elseif itemName and Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.MultiSearchExact then
        local cleanName = itemName:gsub('["%^;]', "")
        local okApi = pcall(function()
            Auctionator.API.v1.MultiSearchExact("ForeverMarketWatch", { cleanName })
        end)
        if okApi then
            lastViewedItemID = itemID
            return true
        end
    end

    -- 2. Fallback (if Auctionator is not installed): Blizzard default Buy tab + exact search
    if AuctionHouseFrame.SetDisplayMode and AuctionHouseFrameDisplayMode and AuctionHouseFrameDisplayMode.Buy then
        pcall(function()
            AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
        end)
    end
    if itemName and AuctionHouseFrame.SearchBar and AuctionHouseFrame.SearchBar.SearchBox and AuctionHouseFrame.SearchBar.StartSearch then
        local okSearch = pcall(function()
            AuctionHouseFrame.SearchBar.SearchBox:SetText(itemName)
            AuctionHouseFrame.SearchBar:StartSearch()
        end)
        if okSearch then
            lastViewedItemID = itemID
            return true
        end
    end

    if C_AuctionHouse and C_AuctionHouse.MakeItemKey and C_AuctionHouse.SendSearchQuery then
        local itemKey = C_AuctionHouse.MakeItemKey(itemID)
        C_AuctionHouse.SendSearchQuery(itemKey, GetPriceSort(), false)
        lastViewedItemID = itemID
        return true
    end
    return false
end

--------------------------------------------------------------------------------
-- Quick "Post" / Sell My Inventory Helper + Owned Auction Undercut Scanner
--------------------------------------------------------------------------------

local function FindItemInPlayerBags(targetItemID)
    if not targetItemID then return nil, nil end
    local numSlotsFn = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    local getIDFn = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
    if not numSlotsFn or not getIDFn then return nil, nil end

    for bag = 0, 4 do
        local slots = numSlotsFn(bag) or 0
        for slot = 1, slots do
            if getIDFn(bag, slot) == targetItemID then
                return bag, slot
            end
        end
    end
    return nil, nil
end

function Scanner:JumpToSellItemInAH(itemID, sellInfo)
    if not ahOpen or not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
        NS.Print("Open the Auction House to post items for sale.")
        return false
    end
    if not itemID then return false end

    if isScanning then
        self:StopScan("QUICK_POST")
    end

    NS:FireCallback("HIDE_AH_OVERLAY")

    local itemName = ResolveItemNameForBuy(itemID) or ("Item #" .. tostring(itemID))
    sellInfo = sellInfo or {}
    local avgCost = tonumber(sellInfo.avgCost) or 0
    local breakEven = tonumber(sellInfo.breakEven) or 0
    local mktPrice = tonumber(sellInfo.mktPrice)
    local watch = NS.DB and NS.DB:GetWatchItem(itemID) or nil
    local sellTarget = watch and watch.sellTarget or nil

    -- Suggest a safe listing price that respects your Break-Even floor
    local suggested = nil
    if sellTarget and sellTarget > 0 then
        suggested = math.max(sellTarget, breakEven)
    elseif mktPrice and mktPrice > 0 then
        suggested = math.max(mktPrice, breakEven)
    elseif breakEven > 0 then
        suggested = math.ceil(breakEven * 1.15)
    end

    local warnStr = ""
    if breakEven > 0 and mktPrice and mktPrice < breakEven then
        warnStr = "  |cFFF55954(WAIT: AH min is BELOW break-even!)|r"
    end

    NS.Print(string.format(
        "|cFF38D972[POST]|r %s (x%d) — Avg: %s | Break-Even: |cFFFFCC33%s|r | AH Min: %s | Suggest: |cFF38D972%s|r%s",
        itemName,
        sellInfo.qty or 1,
        avgCost > 0 and NS.FormatMoney(avgCost, true) or "--",
        breakEven > 0 and NS.FormatMoney(breakEven, true) or "--",
        mktPrice and NS.FormatMoney(mktPrice, true) or "--",
        suggested and NS.FormatMoney(suggested, true) or "--",
        warnStr
    ))

    local bag, slot = FindItemInPlayerBags(itemID)

    -- 1. Preferred: Jump straight to Auctionator's Selling tab
    if AuctionatorTabs_Selling then
        local ok = pcall(function()
            AuctionatorTabs_Selling:Click()
            if bag ~= nil and slot ~= nil and ItemLocation and ItemLocation.CreateFromBagAndSlot then
                local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
                if Auctionator and Auctionator.EventBus and Auctionator.Selling and Auctionator.Selling.Events and Auctionator.Selling.Events.BagItemClicked then
                    local link = (C_Container and C_Container.GetContainerItemLink and C_Container.GetContainerItemLink(bag, slot)) or nil
                    local info = (C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)) or nil
                    Auctionator.EventBus:Fire({ name = "ForeverMarketWatch" }, Auctionator.Selling.Events.BagItemClicked, {
                        itemLink   = link,
                        itemID     = itemID,
                        location   = loc,
                        count      = (info and info.stackCount) or 1,
                        iconTexture = (info and info.iconFileID) or NS.Compat.GetItemIconByID(itemID),
                        itemName   = itemName,
                        quality    = (info and info.quality) or 1,
                        classId    = 0,
                        auctionable = true,
                    })
                end
            end
        end)
        if ok then
            lastViewedItemID = itemID
            return true
        end
    end

    -- 2. Fallback (Blizzard native Sell tab)
    if AuctionHouseFrame.SetDisplayMode and AuctionHouseFrameDisplayMode then
        local maxStack = (C_Item and C_Item.GetItemMaxStackSizeByID and C_Item.GetItemMaxStackSizeByID(itemID)) or 1
        local mode = (maxStack > 1 and AuctionHouseFrameDisplayMode.CommoditiesSell) or AuctionHouseFrameDisplayMode.ItemSell
        if mode then
            pcall(function()
                AuctionHouseFrame:SetDisplayMode(mode)
            end)
        end
    end
    lastViewedItemID = itemID
    return true
end

local function ProcessOwnedAuctionsUpdate()
    if not C_AuctionHouse or not C_AuctionHouse.GetNumOwnedAuctions or not C_AuctionHouse.GetOwnedAuctionInfo then
        return
    end
    local count = C_AuctionHouse.GetNumOwnedAuctions() or 0
    local list = {}
    local uniqueItemIDs = {}
    local seenIDs = {}
    local soldEnum = (Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold) or 1

    for i = 1, count do
        local info = C_AuctionHouse.GetOwnedAuctionInfo(i)
        if info and info.status ~= soldEnum then
            local itemID = info.itemKey and info.itemKey.itemID or nil
            local qty = math.max(1, tonumber(info.quantity) or 1)
            local rawBuyout = tonumber(info.buyoutAmount) or 0
            local maxStack = (itemID and C_Item and C_Item.GetItemMaxStackSizeByID and C_Item.GetItemMaxStackSizeByID(itemID)) or 1

            -- Modern C_AuctionHouse reports unit price in buyoutAmount for commodities, total buyout for gear/items
            local unitPrice, totalBuyout
            if maxStack > 1 then
                unitPrice = rawBuyout
                totalBuyout = rawBuyout * qty
            else
                totalBuyout = rawBuyout
                unitPrice = (qty > 0) and math.floor((rawBuyout / qty) + 0.5) or rawBuyout
            end

            local liveName, _, liveQual, _, _, _, _, _, _, liveIcon = itemID and NS.Compat.GetItemInfo(itemID) or nil
            local keyInfo = (info.itemKey and C_AuctionHouse.GetItemKeyInfo) and C_AuctionHouse.GetItemKeyInfo(info.itemKey) or nil
            if itemID and not liveName then
                NS.Compat.RequestLoadItemDataByID(itemID)
            end

            table.insert(list, {
                auctionID       = info.auctionID,
                itemID          = itemID,
                name            = liveName or (keyInfo and keyInfo.itemName) or (itemID and ("Item #" .. tostring(itemID)) or "Auction"),
                icon            = liveIcon or (keyInfo and keyInfo.iconFileID) or (itemID and NS.Compat.GetItemIconByID(itemID)) or 134400,
                quality         = (liveQual ~= nil) and liveQual or (keyInfo and keyInfo.quality) or 1,
                qty             = qty,
                unitPrice       = unitPrice,
                totalBuyout     = totalBuyout,
                timeLeftSeconds = info.timeLeftSeconds,
            })

            if itemID and itemID > 0 and not seenIDs[itemID] then
                seenIDs[itemID] = true
                table.insert(uniqueItemIDs, itemID)
            end
        end
    end

    local playerName = (UnitName and UnitName("player")) or "Alt"
    NS.DB:SetOwnedAuctions(playerName, list, time())

    if pendingOwnedPriceScan then
        pendingOwnedPriceScan = false
        if #uniqueItemIDs > 0 and ahOpen and not NS.DB:IsDemoMode() then
            if isScanning then
                Scanner:StopScan("UNDERCUT_SCAN")
            end
            scanQueue = uniqueItemIDs
            scanTotal = #uniqueItemIDs
            scanIndex = 0
            isScanning = true
            isAutoScan = false
            waitingForResult = false
            currentItemID = nil
            NS.Print(string.format("Checking live prices on %d listed item(s) for undercuts...", #uniqueItemIDs))
            NS:FireCallback("SCAN_STATE_CHANGED", true, 0, scanTotal, "STARTED")
            Scanner:TrySendNext()
        else
            NS.Print(string.format("Owned auctions updated (%d active listing%s).", #list, #list == 1 and "" or "s"))
        end
    end
end

function Scanner:ScanMyAuctions(andCheckPrices)
    if NS.DB:IsDemoMode() then
        NS.Print("Exit Demo Mode (/fmw demo) to scan your live posted auctions.")
        return false
    end
    if not ahOpen then
        NS.Print("Open the Auction House to check your active auctions for undercuts.")
        return false
    end
    if not C_AuctionHouse or not C_AuctionHouse.QueryOwnedAuctions then
        NS.PrintError("Owned Auctions API is unavailable on this client.")
        return false
    end

    pendingOwnedPriceScan = andCheckPrices and true or false
    local ok = pcall(function()
        C_AuctionHouse.QueryOwnedAuctions({})
    end)
    if not ok then
        pendingOwnedPriceScan = false
        return false
    end
    return true
end

function Scanner:CancelOwnedAuction(auctionID)
    if not ahOpen or not auctionID then
        NS.Print("Open the Auction House to cancel an auction.")
        return false
    end
    if not C_AuctionHouse or not C_AuctionHouse.CancelAuction then
        return false
    end
    local ok = pcall(C_AuctionHouse.CancelAuction, auctionID)
    if ok then
        if C_Timer and C_Timer.After then
            C_Timer.After(0.6, function()
                if ahOpen and C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions then
                    pcall(C_AuctionHouse.QueryOwnedAuctions, {})
                end
            end)
        end
    end
    return ok
end

--------------------------------------------------------------------------------
-- Event Listener
--------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
eventFrame:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
eventFrame:RegisterEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
eventFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
eventFrame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
eventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
eventFrame:RegisterEvent("OWNED_AUCTIONS_UPDATED")
eventFrame:RegisterEvent("ITEM_KEY_ITEM_INFO_RECEIVED")

if Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Auctioneer then
    eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
    eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
end

local function OnAuctionHouseOpened()
    if ahOpen then return end
    ahOpen = true
    NS:FireCallback("AH_STATE_CHANGED", true)

    autoScanDelayTimer = CancelTimer(autoScanDelayTimer)
    local settings = NS.DB:GetSettings()
    local startedAuto = false
    -- Skip in-game auto-scan if external Blizzard API already synced recently (<65 min)
    local apiFresh = (time() - (NS.DB:GetExternalSyncTimestamp() or 0)) < 3900
    if settings.autoScanOnOpen and not apiFresh and not NS.DB:IsDemoMode() then
        local market = NS.DB:GetActiveMarket()
        local cooldownSec = math.max(1, settings.autoScanCooldownMinutes or 15) * 60
        local lastAuto = market.lastAutoScan or 0
        if (time() - lastAuto) >= cooldownSec and #NS.DB:GetWatchedItemIDs() > 0 then
            startedAuto = true
            if C_Timer and C_Timer.NewTimer then
                autoScanDelayTimer = C_Timer.NewTimer(AUTO_SCAN_DELAY_SECONDS, function()
                    if ahOpen and not isScanning then
                        Scanner:StartWatchlistScan(true)
                    end
                end)
            end
        end
    end

    if not startedAuto then
        Scanner:ReschedulePeriodicScan()
    end
end

local function OnAuctionHouseClosed()
    if not ahOpen then return end
    ahOpen = false
    pendingBrowseSearchQuery = nil
    queuedBrowseQueryToSend = nil
    lastSearchResultRows = nil
    browseSearchTimeoutTimer = CancelTimer(browseSearchTimeoutTimer)
    autoScanDelayTimer = CancelTimer(autoScanDelayTimer)
    periodicScanTimer = CancelTimer(periodicScanTimer)
    nextAutoScanAt = 0
    if isScanning then
        FinishScan("AH_CLOSED")
    end
    NS:FireCallback("AH_STATE_CHANGED", false)
end

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "AUCTION_HOUSE_SHOW" then
        OnAuctionHouseOpened()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if Enum and Enum.PlayerInteractionType and arg1 == Enum.PlayerInteractionType.Auctioneer then
            OnAuctionHouseOpened()
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        OnAuctionHouseClosed()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if Enum and Enum.PlayerInteractionType and arg1 == Enum.PlayerInteractionType.Auctioneer then
            OnAuctionHouseClosed()
        end
    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        if queuedBrowseQueryToSend then
            DispatchQueuedBrowseSearch()
        elseif isScanning and not waitingForResult then
            Scanner:TrySendNext()
        end
    elseif event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
        -- Refresh names/icons on any live search results whose item metadata just arrived
        if lastSearchResultRows and lastSearchResultRows.rows then
            local changed = false
            for i = 1, #lastSearchResultRows.rows do
                local row = lastSearchResultRows.rows[i]
                if row.itemID == arg1 then
                    local keyInfo = row.itemKey and C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(row.itemKey) or nil
                    local name, _, qual, _, _, _, _, _, _, icon = NS.Compat.GetItemInfo(row.itemID)
                    if name or (keyInfo and keyInfo.itemName) then
                        row.name = name or keyInfo.itemName
                        row.icon = icon or (keyInfo and keyInfo.iconFileID) or row.icon
                        row.quality = (qual ~= nil) and qual or ((keyInfo and keyInfo.quality) or row.quality)
                        changed = true
                    end
                end
            end
            if changed then
                NS:FireCallback("AH_SEARCH_RESULTS", lastSearchResultRows.query, lastSearchResultRows.rows)
            end
        end
    elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
        if isScanning and waitingForResult and currentItemID then
            if retryCount < MAX_RETRIES_PER_ITEM then
                retryCount = retryCount + 1
                waitingForResult = false
                scanIndex = math.max(0, scanIndex - 1)
                if C_Timer and C_Timer.After then
                    C_Timer.After(0.5, function()
                        if isScanning then
                            Scanner:TrySendNext()
                        end
                    end)
                end
            else
                AdvanceQueue()
            end
        end
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        local itemID = arg1
        if not itemID then return end
        lastViewedItemID = itemID

        if isScanning and waitingForResult and itemID == currentItemID then
            ProcessCommodityResults(itemID, false)
            AdvanceQueue()
        else
            if isScanning and isAutoScan then
                FinishScan("YIELDED_TO_USER")
            end
            if NS.DB:GetSettings().passiveCapture then
                ProcessCommodityResults(itemID, true)
            end
        end
        NS:FireCallback("LAST_VIEWED_ITEM_CHANGED", lastViewedItemID)
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        local itemKey = arg1
        local itemID = itemKey and itemKey.itemID or nil
        if not itemID then return end
        lastViewedItemID = itemID

        if isScanning and waitingForResult and itemID == currentItemID then
            ProcessItemResults(itemKey, false)
            AdvanceQueue()
        else
            if isScanning and isAutoScan then
                FinishScan("YIELDED_TO_USER")
            end
            if NS.DB:GetSettings().passiveCapture then
                ProcessItemResults(itemKey, true)
            end
        end
        NS:FireCallback("LAST_VIEWED_ITEM_CHANGED", lastViewedItemID)
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        if not isScanning then
            ProcessBrowseResults()
        end
    elseif event == "OWNED_AUCTIONS_UPDATED" then
        ProcessOwnedAuctionsUpdate()
    end
end)
