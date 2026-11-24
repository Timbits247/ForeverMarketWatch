-- Database.lua
-- SavedVariables persistence (ForeverMarketWatchDB), automatic pre-population
-- of all profession materials, watchlist & group CRUD, intraday snapshot storage,
-- >7-day daily rollup compaction, and isolated Demo Mode.

local _, NS = ...

local DB = {}
NS.DB = DB

local INTRADAY_RETENTION_SECONDS = 7 * 86400   -- Keep raw/intraday points for 7 days
local INTRADAY_MERGE_WINDOW      = 300         -- Merge points <5 minutes apart
local PASSIVE_PRUNE_DAYS         = 90          -- Prune unwatched passive history older than 90 days

local DEFAULT_SETTINGS = {
    autoScanOnOpen          = true,  -- Automatically scans AH when you open it (respects cooldown)
    autoScanCooldownMinutes = 15,
    autoScanIntervalMinutes = 30,    -- Periodic auto-rescan while parked at the AH (0 = Off, 15, 30, 60)
    passiveCapture          = true,
    autoTrackLedger         = true,  -- Auto-populate Inventory & Ledger from AH purchases & mailbox sales
    announceAutoLedger      = true,  -- Print subtle chat confirmation on auto-logged AH buys/sales
    defaultTimeframe        = "30D",
    defaultChartMode        = 2,     -- Start on Price + Bottom Volume so classic stock chart shines immediately
    defaultSort             = "name_asc",
    minimapAngle            = 225,
    window                  = { point = "CENTER", x = 0, y = 0, width = 920, height = 580 },
}

local demoModeActive = false
local demoMarket = nil
local activeMarketOverride = nil

local function DeepCopy(tbl)
    if type(tbl) ~= "table" then return tbl end
    local copy = {}
    for k, v in pairs(tbl) do
        copy[k] = DeepCopy(v)
    end
    return copy
end

local function GetDefaultGroups()
    if NS.Catalog and NS.Catalog.PROFESSION_GROUPS then
        return DeepCopy(NS.Catalog.PROFESSION_GROUPS)
    end
    return { "Herbalism", "Mining", "Skinning", "Tailoring", "Enchanting", "Alchemy", "Flipping" }
end

--------------------------------------------------------------------------------
-- Initialization & Market Access
--------------------------------------------------------------------------------

function DB:Init()
    if type(ForeverMarketWatchDB) ~= "table" then
        ForeverMarketWatchDB = {}
    end
    local prevSchema = tonumber(ForeverMarketWatchDB.schemaVersion) or 0
    ForeverMarketWatchDB.schemaVersion = NS.SCHEMA_VERSION

    if type(ForeverMarketWatchDB.settings) ~= "table" then
        ForeverMarketWatchDB.settings = DeepCopy(DEFAULT_SETTINGS)
    else
        for k, v in pairs(DEFAULT_SETTINGS) do
            if ForeverMarketWatchDB.settings[k] == nil then
                ForeverMarketWatchDB.settings[k] = DeepCopy(v)
            end
        end
        if type(ForeverMarketWatchDB.settings.window) ~= "table" then
            ForeverMarketWatchDB.settings.window = DeepCopy(DEFAULT_SETTINGS.window)
        end
    end

    if type(ForeverMarketWatchDB.markets) ~= "table" then
        ForeverMarketWatchDB.markets = {}
    end

    -- One-time v5 accounting repair: purges duplicate commodity MAIL BUY entries
    -- and duplicate Open-All MAIL SELL entries from earlier builds, then replays
    -- all real trades chronologically to rebuild exact cost bases, profits & per-char splits.
    if prevSchema > 0 and prevSchema < 5 then
        local totalPurged = 0
        for _, m in pairs(ForeverMarketWatchDB.markets) do
            if type(m) == "table" and type(m.ledger) == "table" and #m.ledger > 0 then
                local stats = self:RebuildAccountingFromLedger(true, m, true)
                totalPurged = totalPurged + (stats and stats.purged or 0)
            end
        end
        if totalPurged > 0 then
            NS.Print(string.format("Accounting auto-repair: removed %d duplicate mail rows & recalculated exact cost bases and profits.", totalPurged))
        end
    end

    -- Ensure current market exists, seed profession mats if not yet seeded,
    -- merge any synced Blizzard API feed data, and compact history.
    local market = self:GetActiveMarket()
    if not market.professionsSeeded then
        self:SeedProfessionMaterials(false)
    end
    self:MergeExternalFeed()
    self:CompactAll()
end

--------------------------------------------------------------------------------
-- External Blizzard API Feed Merge (MarketFeedData.lua)
--------------------------------------------------------------------------------

function DB:GetExternalSyncTimestamp()
    if NS.ExternalFeed and type(NS.ExternalFeed.syncedAt) == "number" and NS.ExternalFeed.syncedAt > 0 then
        return NS.ExternalFeed.syncedAt
    end
    return 0
end

function DB:MergeExternalFeed(feedOverride, marketOverride)
    if demoModeActive and not marketOverride then return 0 end
    local feed = feedOverride or NS.ExternalFeed
    if type(feed) ~= "table" or type(feed.houses) ~= "table" then
        return 0
    end

    local marketKey = self:GetActiveMarketKey()
    local market = marketOverride or self:GetActiveMarket()

    -- Match active market faction ("Horde", "Alliance", or "Neutral")
    local factionKey = marketKey:match("%-([^-]+)$") or "Neutral"
    local houseData = feed.houses[factionKey]
    if type(houseData) ~= "table" then
        return 0
    end

    local now = (feedOverride and feedOverride.syncedAt) or (time and time()) or feed.syncedAt or 0
    local mergedItems = 0

    for itemID, extHist in pairs(houseData) do
        local idNum = tonumber(itemID)
        if idNum and idNum > 0 and type(extHist) == "table" then
            local hist = market.history[idNum]
            if type(hist) ~= "table" then
                hist = { intraday = {}, daily = {}, lastScan = 0 }
                market.history[idNum] = hist
            end
            if type(hist.intraday) ~= "table" then hist.intraday = {} end
            if type(hist.daily) ~= "table" then hist.daily = {} end

            -- Merge intraday points (deduplicate points within INTRADAY_MERGE_WINDOW seconds)
            if type(extHist.intraday) == "table" then
                for i = 1, #extHist.intraday do
                    local ep = extHist.intraday[i]
                    if type(ep) == "table" and ep[1] and ep[2] and ep[2] > 0 then
                        local duplicate = false
                        for j = 1, #hist.intraday do
                            if math.abs(hist.intraday[j][1] - ep[1]) < INTRADAY_MERGE_WINDOW then
                                -- Refresh existing bucket with API point if timestamps match closely
                                if ep[1] >= hist.intraday[j][1] then
                                    hist.intraday[j][1] = ep[1]
                                    hist.intraday[j][2] = ep[2]
                                    hist.intraday[j][3] = ep[3] or ep[2]
                                    hist.intraday[j][4] = math.max(hist.intraday[j][4] or ep[2], ep[4] or ep[2])
                                    hist.intraday[j][5] = ep[5] or 0
                                end
                                duplicate = true
                                break
                            end
                        end
                        if not duplicate then
                            table.insert(hist.intraday, { ep[1], ep[2], ep[3] or ep[2], ep[4] or ep[2], ep[5] or 0 })
                        end
                    end
                end
                table.sort(hist.intraday, function(a, b) return a[1] < b[1] end)
            end

            -- Merge rolled-up daily summaries
            if type(extHist.daily) == "table" then
                for dayKey, ed in pairs(extHist.daily) do
                    if type(ed) == "table" and ed[1] and ed[1] > 0 then
                        local existing = hist.daily[dayKey]
                        if not existing then
                            hist.daily[dayKey] = { ed[1], ed[2] or ed[1], ed[3] or ed[1], ed[4] or ed[1], ed[5] or 0, ed[6] or 1 }
                        else
                            -- Prefer richer sample count for avg/close while preserving true min/max envelope
                            existing[1] = math.min(existing[1], ed[1])
                            existing[3] = math.max(existing[3], ed[3] or ed[1])
                            if (ed[6] or 1) >= (existing[6] or 1) then
                                existing[2] = ed[2] or existing[2]
                                existing[4] = ed[4] or existing[4]
                                existing[5] = ed[5] or existing[5]
                                existing[6] = ed[6] or existing[6]
                            end
                        end
                    end
                end
            end

            if extHist.lastScan and extHist.lastScan > (hist.lastScan or 0) then
                hist.lastScan = extHist.lastScan
            end

            -- Merge Order-Book Dip Wall (+10% reset wall) if newer
            if type(extHist.wall) == "table" and extHist.wall[1] then
                if not hist.orderBook or (extHist.lastScan or 0) >= (hist.orderBook.updatedAt or 0) then
                    hist.orderBook = {
                        wallQty   = extHist.wall[1] or 0,
                        wallCost  = extHist.wall[2] or 0,
                        nextPrice = extHist.wall[3] or 0,
                        updatedAt = extHist.lastScan or now,
                    }
                end
            end

            self:CompactItemHistory(hist, now)
            mergedItems = mergedItems + 1
        end
    end

    return mergedItems
end

function DB:GetSettings()
    if not ForeverMarketWatchDB or not ForeverMarketWatchDB.settings then
        self:Init()
    end
    return ForeverMarketWatchDB.settings
end

function DB:SetMarketOverride(marketKey)
    activeMarketOverride = marketKey
end

function DB:GetActiveMarketKey()
    if demoModeActive then
        return "DemoMarket-Preview"
    end
    if activeMarketOverride then
        return activeMarketOverride
    end
    return NS.GetCurrentMarketKey(false)
end

function DB:IsDemoMode()
    return demoModeActive
end

function DB:SetDemoMode(enabled, marketTable)
    demoModeActive = enabled and true or false
    if demoModeActive and marketTable then
        demoMarket = marketTable
    elseif not demoModeActive then
        demoMarket = nil
    end
    NS:FireCallback("DATA_UPDATED", nil, "DEMO_TOGGLE")
end

function DB:GetMarket(marketKey)
    if demoModeActive and demoMarket then
        return demoMarket
    end
    if not ForeverMarketWatchDB or not ForeverMarketWatchDB.markets then
        self:Init()
    end
    local key = marketKey or self:GetActiveMarketKey()
    local market = ForeverMarketWatchDB.markets[key]
    if type(market) ~= "table" then
        market = {
            groups             = GetDefaultGroups(),
            watchlist          = {},
            history            = {},
            investments        = {},
            ledger             = {},
            ledgerNextId       = 1,
            pendingMailMatches = {},
            charGroups         = {},
            charGold           = {},
            pinned             = {},
            pinnedOrder        = {},
            lastAutoScan       = 0,
            professionsSeeded  = false,
        }
        ForeverMarketWatchDB.markets[key] = market
    end
    if type(market.groups) ~= "table" or #market.groups == 0 then
        market.groups = GetDefaultGroups()
    end
    if type(market.watchlist) ~= "table" then
        market.watchlist = {}
    end
    if type(market.history) ~= "table" then
        market.history = {}
    end
    if type(market.investments) ~= "table" then
        market.investments = {}
    end
    if type(market.ledger) ~= "table" then
        market.ledger = {}
    end
    if type(market.ledgerNextId) ~= "number" or market.ledgerNextId < 1 then
        market.ledgerNextId = (#market.ledger) + 1
    end
    if type(market.pendingMailMatches) ~= "table" then
        market.pendingMailMatches = {}
    end
    if type(market.charGroups) ~= "table" then
        market.charGroups = {}
    end
    if type(market.charGold) ~= "table" then
        market.charGold = {}
    end
    if type(market.pinned) ~= "table" then
        market.pinned = {}
    end
    if type(market.pinnedOrder) ~= "table" then
        market.pinnedOrder = {}
    end
    return market
end

--------------------------------------------------------------------------------
-- Account-Wide Pinned Dashboard Items (Google Finance Style + Drag Order)
--------------------------------------------------------------------------------

function DB:IsPinned(itemID)
    local market = self:GetActiveMarket()
    return market.pinned and market.pinned[itemID] == true
end

function DB:SetPinned(itemID, isPinned)
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 then return false end
    local market = self:GetActiveMarket()
    if type(market.pinnedOrder) ~= "table" then market.pinnedOrder = {} end

    if isPinned then
        market.pinned[itemID] = true
        local found = false
        for i = 1, #market.pinnedOrder do
            if market.pinnedOrder[i] == itemID then
                found = true
                break
            end
        end
        if not found then
            table.insert(market.pinnedOrder, itemID)
        end
    else
        market.pinned[itemID] = nil
        for i = #market.pinnedOrder, 1, -1 do
            if market.pinnedOrder[i] == itemID then
                table.remove(market.pinnedOrder, i)
            end
        end
    end
    NS:FireCallback("DATA_UPDATED", itemID, "PIN_CHANGED")
    return true
end

function DB:TogglePin(itemID)
    local nowPinned = not self:IsPinned(itemID)
    self:SetPinned(itemID, nowPinned)
    return nowPinned
end

-- Returns pinned itemIDs & active investments in the user's persisted custom drag order.
function DB:GetDashboardPinnedIDs()
    local market = self:GetActiveMarket()
    local pinned = market.pinned or {}
    local investments = market.investments or {}
    if type(market.pinnedOrder) ~= "table" then
        market.pinnedOrder = {}
    end

    local eligible = {}
    for itemID, inv in pairs(investments) do
        if inv and inv.qty and inv.qty > 0 then
            eligible[itemID] = true
        end
    end
    for itemID, flag in pairs(pinned) do
        if flag then
            eligible[itemID] = true
        end
    end

    -- Keep existing custom order for still-eligible items
    local list = {}
    local seen = {}
    for i = 1, #market.pinnedOrder do
        local id = market.pinnedOrder[i]
        if eligible[id] and not seen[id] then
            seen[id] = true
            table.insert(list, id)
        end
    end

    -- Append any newly added investments/pins alphabetically
    local extras = {}
    for id in pairs(eligible) do
        if not seen[id] then
            table.insert(extras, id)
        end
    end
    table.sort(extras, function(a, b)
        local wa = market.watchlist and market.watchlist[a]
        local wb = market.watchlist and market.watchlist[b]
        local na = (wa and wa.name) or tostring(a)
        local nb = (wb and wb.name) or tostring(b)
        return na < nb
    end)
    for i = 1, #extras do
        table.insert(list, extras[i])
    end

    market.pinnedOrder = list
    return list
end

function DB:MovePinnedItem(fromItemID, toItemID)
    if not fromItemID or not toItemID or fromItemID == toItemID then
        return false
    end
    local order = self:GetDashboardPinnedIDs()
    local fromIdx, toIdx = nil, nil
    for i = 1, #order do
        if order[i] == fromItemID then fromIdx = i end
        if order[i] == toItemID then toIdx = i end
    end
    if not fromIdx or not toIdx then
        return false
    end

    table.remove(order, fromIdx)
    table.insert(order, toIdx, fromItemID)

    local market = self:GetActiveMarket()
    market.pinnedOrder = order
    NS:FireCallback("DATA_UPDATED", fromItemID, "PIN_REORDERED")
    return true
end

--------------------------------------------------------------------------------
-- Account-Wide Explicit Investment Portfolio (Shared Across All Alts)
--------------------------------------------------------------------------------

function DB:GetInvestment(itemID)
    local market = self:GetActiveMarket()
    return market.investments and market.investments[itemID] or nil
end

function DB:GetAllInvestments()
    local market = self:GetActiveMarket()
    return market.investments or {}
end

-- Read-only helper showing how many of an item the current character is carrying
-- (never auto-added to Investments — strictly informational).
function DB:CountItemOnCurrentCharacter(itemID)
    if not itemID then return 0 end
    if C_Item and C_Item.GetItemCount then
        return C_Item.GetItemCount(itemID, true) or 0
    elseif GetItemCount then
        return GetItemCount(itemID, true) or 0
    end
    return 0
end

function DB:LogInvestmentBuy(itemID, addQty, unitCostCopper, holderAlt, notes, skipLedger)
    itemID = tonumber(itemID)
    addQty = math.floor(tonumber(addQty) or 0)
    unitCostCopper = math.floor((tonumber(unitCostCopper) or 0) + 0.5)
    if not itemID or addQty <= 0 or unitCostCopper <= 0 then
        return false, "Enter a valid quantity and unit cost."
    end

    local market = self:GetActiveMarket()
    local existing = market.investments[itemID]
    local defaultHolder = (UnitName and UnitName("player")) or "Alt"
    local holder = (type(holderAlt) == "string" and holderAlt:match("^%s*(.-)%s*$") ~= "") and holderAlt:match("^%s*(.-)%s*$") or nil
    local liveName, _, liveQual, _, _, _, _, _, _, liveIcon = NS.Compat.GetItemInfo(itemID)
    local now = (time and time()) or 0

    if not existing then
        market.investments[itemID] = {
            qty            = addQty,
            avgCost        = unitCostCopper,
            totalCost      = addQty * unitCostCopper,
            realizedProfit = 0,
            holder         = holder or defaultHolder,
            notes          = (type(notes) == "string") and notes:match("^%s*(.-)%s*$") or "",
            name           = liveName,
            icon           = liveIcon,
            quality        = liveQual,
            lastBuyTs      = now,
            updatedAt      = now,
        }
    else
        local newQty = (existing.qty or 0) + addQty
        local newTotal = (existing.totalCost or ((existing.qty or 0) * (existing.avgCost or 0))) + (addQty * unitCostCopper)
        existing.qty       = newQty
        existing.totalCost = newTotal
        existing.avgCost   = (newQty > 0) and math.floor((newTotal / newQty) + 0.5) or unitCostCopper
        if liveName then
            existing.name    = liveName
            existing.icon    = liveIcon or existing.icon
            existing.quality = (liveQual ~= nil) and liveQual or existing.quality
        end
        if holder then
            if existing.holder and existing.holder ~= "" and not existing.holder:find(holder, 1, true) then
                existing.holder = existing.holder .. ", " .. holder
            else
                existing.holder = holder
            end
        end
        if type(notes) == "string" and notes:match("^%s*(.-)%s*$") ~= "" then
            existing.notes = notes:match("^%s*(.-)%s*$")
        end
        existing.lastBuyTs = now
        existing.updatedAt = now
    end

    if not skipLedger then
        self:RecordLedgerBuy(itemID, addQty, addQty * unitCostCopper, {
            character     = holder or defaultHolder,
            source        = "MANUAL",
            ts            = now,
            skipInventory = true,
        })
    else
        NS:FireCallback("DATA_UPDATED", itemID, "INVESTMENT_UPDATED")
    end
    return true, market.investments[itemID]
end

function DB:LogInvestmentSale(itemID, soldQty, unitSaleCopper, skipLedger)
    itemID = tonumber(itemID)
    soldQty = math.floor(tonumber(soldQty) or 0)
    unitSaleCopper = math.floor((tonumber(unitSaleCopper) or 0) + 0.5)
    if not itemID or soldQty <= 0 or unitSaleCopper <= 0 then
        return false, "Enter a valid quantity sold and sale price."
    end

    local market = self:GetActiveMarket()
    local inv = market.investments[itemID]
    if not inv or (inv.qty or 0) <= 0 then
        return false, "No active investment position for this item."
    end

    local actualSold = math.min(soldQty, inv.qty)
    local cutRate = (NS.Analytics and NS.Analytics.GetAHCutRate()) or 0.05
    local gross = actualSold * unitSaleCopper
    local ahCut = math.floor((gross * cutRate) + 0.5)
    local netProceeds = gross - ahCut
    local costBasis = actualSold * (inv.avgCost or 0)
    local netProfit = netProceeds - costBasis
    local now = (time and time()) or 0

    inv.qty = inv.qty - actualSold
    inv.totalCost = inv.qty * (inv.avgCost or 0)
    inv.realizedProfit = (inv.realizedProfit or 0) + netProfit
    inv.lastSellTs = now
    inv.updatedAt = now

    if not skipLedger then
        self:RecordLedgerSale(itemID, actualSold, gross, ahCut, {
            source             = "MANUAL",
            ts                 = now,
            skipInventory      = true,
            explicitCostBasis  = costBasis,
            explicitMatchedQty = actualSold,
        })
    else
        NS:FireCallback("DATA_UPDATED", itemID, "INVESTMENT_UPDATED")
    end
    return true, netProfit, inv
end

function DB:ClearInvestment(itemID)
    local market = self:GetActiveMarket()
    if market.investments and market.investments[itemID] then
        market.investments[itemID] = nil
        NS:FireCallback("DATA_UPDATED", itemID, "INVESTMENT_CLEARED")
        return true
    end
    return false
end

function DB:UpdateInvestmentPosition(itemID, newQty, newAvgCost)
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 then return false end
    local market = self:GetActiveMarket()
    local inv = market.investments and market.investments[itemID]
    if not inv then return false end

    local q = math.max(0, math.floor((tonumber(newQty) or 0) + 0.5))
    local avg = (newAvgCost and newAvgCost > 0) and math.floor(newAvgCost + 0.5) or (inv.avgCost or 0)
    inv.qty = q
    inv.avgCost = avg
    inv.totalCost = q * avg
    inv.updatedAt = (time and time()) or 0
    NS:FireCallback("DATA_UPDATED", itemID, "INVESTMENT_UPDATED")
    return true
end

--------------------------------------------------------------------------------
-- Character & Character-Group Filtering (Account-Wide / Per-Alt / Custom Groups)
--------------------------------------------------------------------------------

function DB:GetCharacterGroups()
    local market = self:GetActiveMarket()
    if type(market.charGroups) ~= "table" then
        market.charGroups = {}
    end
    return market.charGroups
end

function DB:SaveCharacterGroup(groupName, membersMap)
    if type(groupName) ~= "string" then return false, "Enter a group name." end
    local clean = groupName:match("^%s*(.-)%s*$")
    if clean == "" then return false, "Enter a group name." end

    local cleanMembers = {}
    local count = 0
    if type(membersMap) == "table" then
        for charName, flag in pairs(membersMap) do
            if flag and type(charName) == "string" and charName ~= "" then
                cleanMembers[charName] = true
                count = count + 1
            end
        end
    end
    if count == 0 then
        return false, "Select at least one character for this group."
    end

    local groups = self:GetCharacterGroups()
    groups[clean] = cleanMembers
    NS:FireCallback("DATA_UPDATED", nil, "CHAR_GROUPS_UPDATED")
    return true
end

function DB:DeleteCharacterGroup(groupName)
    local groups = self:GetCharacterGroups()
    if groups[groupName] then
        groups[groupName] = nil
        NS:FireCallback("DATA_UPDATED", nil, "CHAR_GROUPS_UPDATED")
        return true
    end
    return false
end

function DB:GetKnownCharacters()
    local market = self:GetActiveMarket()
    local seen = {}
    local list = {}

    local function AddChar(name)
        if type(name) ~= "string" then return end
        local c = name:match("^%s*(.-)%s*$")
        if c ~= "" and c ~= "Alt" and not seen[c] then
            seen[c] = true
            table.insert(list, c)
        end
    end

    if UnitName then
        AddChar(UnitName("player"))
    end

    if type(market.ledger) == "table" then
        for i = 1, #market.ledger do
            AddChar(market.ledger[i].character)
        end
    end

    if type(market.investments) == "table" then
        for _, inv in pairs(market.investments) do
            if type(inv) == "table" then
                if type(inv.byChar) == "table" then
                    for ch in pairs(inv.byChar) do AddChar(ch) end
                end
                if type(inv.holder) == "string" and inv.holder ~= "" then
                    for part in inv.holder:gmatch("[^,]+") do
                        AddChar(part)
                    end
                end
            end
        end
    end

    if type(market.charGroups) == "table" then
        for _, members in pairs(market.charGroups) do
            if type(members) == "table" then
                for ch, flag in pairs(members) do
                    if flag then AddChar(ch) end
                end
            end
        end
    end

    if type(market.charGold) == "table" then
        for ch in pairs(market.charGold) do
            AddChar(ch)
        end
    end

    table.sort(list, function(a, b) return a:lower() < b:lower() end)
    return list
end

function DB:BuildCharacterFilterSet(charFilter)
    if type(charFilter) ~= "string" or charFilter == "" or charFilter == "ALL" then
        return nil
    end

    if charFilter:sub(1, 5) == "CHAR:" then
        local ch = charFilter:sub(6)
        if ch ~= "" then
            return { [ch:lower()] = true }
        end
        return nil
    elseif charFilter:sub(1, 6) == "GROUP:" then
        local gName = charFilter:sub(7)
        local groups = self:GetCharacterGroups()
        local members = groups[gName]
        if type(members) == "table" then
            local set = {}
            local any = false
            for ch, flag in pairs(members) do
                if flag and type(ch) == "string" and ch ~= "" then
                    set[ch:lower()] = true
                    any = true
                end
            end
            if any then return set end
        end
        return {} -- Group exists/deleted with 0 members -> matches nothing
    end

    -- Allow passing raw character name directly
    return { [charFilter:lower()] = true }
end

function DB:MatchesCharacterFilter(charName, filterSet)
    if not filterSet then return true end
    if type(charName) ~= "string" or charName == "" then return false end
    return filterSet[charName:lower()] == true
end

function DB:GetCharacterFilterOptions()
    local opts = {
        { value = "ALL", label = "All Characters" },
    }
    local groups = self:GetCharacterGroups()
    local gNames = {}
    for gName in pairs(groups) do
        table.insert(gNames, gName)
    end
    table.sort(gNames, function(a, b) return a:lower() < b:lower() end)
    for i = 1, #gNames do
        table.insert(opts, { value = "GROUP:" .. gNames[i], label = "[Grp] " .. gNames[i] })
    end

    local chars = self:GetKnownCharacters()
    for i = 1, #chars do
        table.insert(opts, { value = "CHAR:" .. chars[i], label = chars[i] })
    end
    return opts
end

-- Returns an investment position filtered by character or character group (nil if no match)
function DB:GetInvestmentView(itemID, charFilter)
    local inv = self:GetInvestment(itemID)
    if type(inv) ~= "table" then return nil end

    local filterSet = self:BuildCharacterFilterSet(charFilter)
    if not filterSet then
        return inv
    end

    if type(inv.byChar) == "table" then
        local qty, totalCost, realized = 0, 0, 0
        local holders = {}
        local matchedAny = false
        for ch, cd in pairs(inv.byChar) do
            if filterSet[ch:lower()] then
                matchedAny = true
                qty = qty + (cd.qty or 0)
                totalCost = totalCost + (cd.totalCost or ((cd.qty or 0) * (cd.avgCost or 0)))
                realized = realized + (cd.realizedProfit or 0)
                if (cd.qty or 0) > 0 or (cd.realizedProfit or 0) ~= 0 then
                    table.insert(holders, ch)
                end
            end
        end
        if not matchedAny then return nil end
        table.sort(holders)
        local avgCost = (qty > 0) and math.floor((totalCost / qty) + 0.5) or (inv.avgCost or 0)
        return {
            qty            = qty,
            avgCost        = avgCost,
            totalCost      = totalCost,
            realizedProfit = realized,
            holder         = (#holders > 0) and table.concat(holders, ", ") or (inv.holder or "Alt"),
            name           = inv.name,
            icon           = inv.icon,
            quality        = inv.quality,
            updatedAt      = inv.updatedAt,
        }
    end

    -- Fallback for legacy pre-Ledger investments without byChar
    if type(inv.holder) == "string" and inv.holder ~= "" then
        for part in inv.holder:gmatch("[^,]+") do
            local clean = part:match("^%s*(.-)%s*$")
            if clean ~= "" and filterSet[clean:lower()] then
                return inv
            end
        end
    end
    return nil
end

function DB:GetPortfolioSummary(charFilter)
    local market = self:GetActiveMarket()
    local investments = market.investments or {}
    local cutRate = (NS.Analytics and NS.Analytics.GetAHCutRate()) or 0.05

    local activePositions = 0
    local totalUnits = 0
    local totalInvested = 0
    local estNetValue = 0
    local realizedProfit = 0

    for itemID in pairs(investments) do
        local inv = self:GetInvestmentView(itemID, charFilter)
        if inv then
            realizedProfit = realizedProfit + (inv.realizedProfit or 0)
            if inv.qty and inv.qty > 0 then
                activePositions = activePositions + 1
                totalUnits = totalUnits + inv.qty
                local cost = inv.totalCost or (inv.qty * (inv.avgCost or 0))
                totalInvested = totalInvested + cost

                local hist = market.history and market.history[itemID] or nil
                local latest = hist and NS.Analytics and NS.Analytics.GetLatestPoint(hist) or nil
                if latest and latest.min and latest.min > 0 then
                    estNetValue = estNetValue + math.floor((inv.qty * latest.min) * (1 - cutRate) + 0.5)
                else
                    estNetValue = estNetValue + cost
                end
            end
        end
    end

    return {
        activePositions = activePositions,
        totalUnits      = totalUnits,
        totalInvested   = totalInvested,
        estNetValue     = estNetValue,
        unrealizedPnL   = estNetValue - totalInvested,
        realizedProfit  = realizedProfit,
    }
end

--------------------------------------------------------------------------------
-- Per-Character Gold Balance & TSM-Style Gold History Tracking
--------------------------------------------------------------------------------

local GOLD_MERGE_WINDOW       = 300        -- Merge rapid balance changes within 5 minutes
local GOLD_INTRADAY_KEEP_SECS = 14 * 86400 -- Keep intraday points for 14 days, then 1 point/day
local GOLD_MAX_POINTS         = 1200

local function CompactGoldHistory(history, now)
    if type(history) ~= "table" or #history <= 2 then return end
    local intradayCutoff = (now or 0) - GOLD_INTRADAY_KEEP_SECS
    local dailyLast = {}
    local dailyOrder = {}
    local recent = {}

    for i = 1, #history do
        local pt = history[i]
        if type(pt) == "table" and pt[1] and pt[2] ~= nil then
            if pt[1] < intradayCutoff then
                local dk = NS.DayKeyFromTimestamp(pt[1])
                if not dailyLast[dk] then
                    table.insert(dailyOrder, dk)
                end
                dailyLast[dk] = pt
            else
                table.insert(recent, pt)
            end
        end
    end

    table.sort(dailyOrder)
    local out = {}
    for i = 1, #dailyOrder do
        table.insert(out, dailyLast[dailyOrder[i]])
    end
    for i = 1, #recent do
        table.insert(out, recent[i])
    end

    while #out > GOLD_MAX_POINTS do
        table.remove(out, 1)
    end

    for i = 1, #out do history[i] = out[i] end
    for i = #out + 1, #history do history[i] = nil end
end

function DB:RecordCharacterGold(copper, character, ts, silent, marketOverride)
    if demoModeActive and not marketOverride then return false end
    copper = math.max(0, math.floor((tonumber(copper) or 0) + 0.5))
    local ch = (type(character) == "string" and character:match("^%s*(.-)%s*$") ~= "")
        and character:match("^%s*(.-)%s*$")
        or (UnitName and UnitName("player"))
    if type(ch) ~= "string" or ch == "" then return false end

    local market = marketOverride or self:GetActiveMarket()
    if type(market.charGold) ~= "table" then market.charGold = {} end

    local now = ts or (time and time()) or 0
    local rec = market.charGold[ch]
    local changed = false

    if type(rec) ~= "table" then
        rec = {
            current   = copper,
            updatedAt = now,
            history   = { { now, copper } },
        }
        market.charGold[ch] = rec
        changed = true
    else
        if type(rec.history) ~= "table" then rec.history = {} end
        changed = (rec.current ~= copper)
        rec.current = copper
        rec.updatedAt = now

        local h = rec.history
        local n = #h
        if n == 0 then
            h[1] = { now, copper }
        else
            local last = h[n]
            if last and math.abs(now - (last[1] or 0)) < GOLD_MERGE_WINDOW then
                last[1] = math.max(last[1] or now, now)
                last[2] = copper
            elseif n >= 2 and h[n][2] == copper and h[n - 1][2] == copper then
                -- Collapse redundant flat points while preserving exact inflection corners
                last[1] = math.max(last[1] or now, now)
            else
                table.insert(h, { now, copper })
                if #h > 300 and (#h % 25 == 0) then
                    CompactGoldHistory(h, now)
                end
            end
        end
    end

    if changed and not silent then
        NS:FireCallback("DATA_UPDATED", nil, "GOLD_UPDATED")
    end
    return true
end

-- Aggregates per-character gold histories using exact Step-Carry-Forward (LOCF)
-- so multi-character or Character-Group totals stay smooth and accurate over time.
function DB:GetGoldHistorySummary(opts)
    opts = opts or {}
    local market = opts.marketOverride or self:GetActiveMarket()
    local charGold = (type(market.charGold) == "table") and market.charGold or {}
    local filterSet = self:BuildCharacterFilterSet(opts.charFilter)
    local now = opts.nowTs or (time and time()) or 0

    local cutoff = 0
    if opts.days == 1 then
        if date then
            local d = date("*t", now)
            cutoff = now - ((d.hour * 3600) + (d.min * 60) + d.sec)
        else
            cutoff = now - 86400
        end
    elseif opts.days and opts.days > 1 then
        cutoff = now - (opts.days * 86400)
    end

    local matched = {}
    local chars = {}
    local currentTotal = 0

    for ch, rec in pairs(charGold) do
        if type(rec) == "table" and self:MatchesCharacterFilter(ch, filterSet) then
            local cur = math.max(0, math.floor((tonumber(rec.current) or 0) + 0.5))
            currentTotal = currentTotal + cur
            table.insert(chars, {
                name      = ch,
                copper    = cur,
                updatedAt = rec.updatedAt or 0,
            })

            local hist = {}
            if type(rec.history) == "table" and #rec.history > 0 then
                for i = 1, #rec.history do
                    local pt = rec.history[i]
                    if type(pt) == "table" and pt[1] and pt[2] ~= nil then
                        table.insert(hist, { pt[1], math.max(0, math.floor((tonumber(pt[2]) or 0) + 0.5)) })
                    end
                end
                table.sort(hist, function(a, b) return a[1] < b[1] end)
            else
                hist[1] = { rec.updatedAt or now, cur }
            end
            table.insert(matched, { name = ch, current = cur, updatedAt = rec.updatedAt or now, history = hist })
        end
    end

    table.sort(chars, function(a, b)
        if a.copper ~= b.copper then return a.copper > b.copper end
        return a.name:lower() < b.name:lower()
    end)

    -- Collect union of timestamps inside [cutoff, now] plus carry-forward anchor at cutoff
    local tsSet = {}
    local tsList = {}
    local anyBeforeCutoff = false
    local maxRecordedTs = 0

    for i = 1, #matched do
        local h = matched[i].history
        for j = 1, #h do
            local t = h[j][1]
            if t > maxRecordedTs then maxRecordedTs = t end
            if cutoff > 0 and t <= cutoff then
                anyBeforeCutoff = true
            elseif t >= cutoff and not tsSet[t] then
                tsSet[t] = true
                table.insert(tsList, t)
            end
        end
    end

    if cutoff > 0 and anyBeforeCutoff and not tsSet[cutoff] then
        tsSet[cutoff] = true
        table.insert(tsList, cutoff)
    end

    -- Append live current balance at `now` if we have tracked characters and `now` is after last point
    if #matched > 0 and now > maxRecordedTs and not tsSet[now] then
        tsSet[now] = true
        table.insert(tsList, now)
    end

    table.sort(tsList)

    -- Step-carry-forward evaluation across all matching characters
    local pointers = {}
    for i = 1, #matched do pointers[i] = 0 end

    local points = {}
    local minCopper = nil
    local maxCopper = nil

    for ti = 1, #tsList do
        local t = tsList[ti]
        local sum = 0
        local contributing = 0
        for ci = 1, #matched do
            local h = matched[ci].history
            local p = pointers[ci]
            while p < #h and h[p + 1][1] <= t do
                p = p + 1
            end
            pointers[ci] = p
            if p > 0 then
                sum = sum + h[p][2]
                contributing = contributing + 1
            end
        end

        -- At the final live `now` point, guarantee exact match with live `currentTotal`
        if t == now and #matched > 0 then
            sum = currentTotal
            contributing = #matched
        end

        if contributing > 0 then
            table.insert(points, { ts = t, copper = sum })
            if not minCopper or sum < minCopper then minCopper = sum end
            if not maxCopper or sum > maxCopper then maxCopper = sum end
        end
    end

    -- Fallback single point if matched chars exist with empty timestamps
    if #points == 0 and #matched > 0 then
        points[1] = { ts = now, copper = currentTotal }
        minCopper = currentTotal
        maxCopper = currentTotal
    end

    local startTotal = (#points > 0) and points[1].copper or currentTotal
    local periodDelta = currentTotal - startTotal
    local periodPct = (startTotal > 0) and ((periodDelta / startTotal) * 100) or nil

    return {
        currentTotal = currentTotal,
        startTotal   = startTotal,
        periodDelta  = periodDelta,
        periodPct    = periodPct,
        minCopper    = minCopper or 0,
        maxCopper    = maxCopper or 0,
        charCount    = #chars,
        chars        = chars,
        points       = points,
    }
end

--------------------------------------------------------------------------------
-- Auto-Populated AH Ledger & Cost-Basis Accounting (Account-Wide)
--------------------------------------------------------------------------------

local MAX_LEDGER_ENTRIES = 2500

function DB:ResolveItemIDByName(itemName)
    if type(itemName) ~= "string" then return nil end
    local q = itemName:lower():match("^%s*(.-)%s*$")
    if q == "" then return nil end

    local market = self:GetActiveMarket()

    -- 1. Check active inventory/investments first (highest probability for sales)
    if market.investments then
        for itemID, inv in pairs(market.investments) do
            if inv and inv.name and inv.name:lower() == q then
                return itemID
            end
        end
    end

    -- 2. Check watchlist
    if market.watchlist then
        for itemID, entry in pairs(market.watchlist) do
            if entry and entry.name and entry.name:lower() == q then
                return itemID
            end
        end
    end

    -- 3. Check built-in profession catalog
    if NS.Catalog and NS.Catalog.ITEMS then
        for i = 1, #NS.Catalog.ITEMS do
            local spec = NS.Catalog.ITEMS[i]
            if spec[2] and spec[2]:lower() == q then
                return spec[1]
            end
        end
    end

    -- 4. Check AH price history cache
    if market.history then
        for itemID, hist in pairs(market.history) do
            if hist and hist.name and hist.name:lower() == q then
                return itemID
            end
        end
    end

    -- 5. Ask WoW item cache directly
    local _, link = NS.Compat.GetItemInfo(itemName)
    if link then
        local parsed = NS.Compat.ParseItemID(link)
        if parsed and parsed > 0 then
            return parsed
        end
    end
    local instantID = NS.Compat.GetItemInfoInstant(itemName)
    if instantID and instantID > 0 then
        return instantID
    end

    return nil
end

local function ResolveLedgerItemMeta(market, itemID, meta)
    meta = meta or {}
    local liveName, _, liveQual, _, _, _, _, _, _, liveIcon
    if itemID and itemID > 0 then
        liveName, _, liveQual, _, _, _, _, _, _, liveIcon = NS.Compat.GetItemInfo(itemID)
        if not liveName then
            NS.Compat.RequestLoadItemDataByID(itemID)
        end
    end

    local watch = (itemID and market.watchlist) and market.watchlist[itemID] or nil
    local hist  = (itemID and market.history) and market.history[itemID] or nil
    local cat   = (itemID and NS.Catalog and NS.Catalog.BY_ID) and NS.Catalog.BY_ID[itemID] or nil

    local name = liveName or meta.name or (watch and watch.name) or (hist and hist.name) or (cat and cat[2]) or (itemID and ("Item #" .. tostring(itemID)) or "Unknown Item")
    local icon = liveIcon or meta.icon or (watch and watch.icon) or (hist and hist.icon) or (itemID and NS.Compat.GetItemIconByID(itemID)) or 134400
    local quality = (liveQual ~= nil) and liveQual
        or (meta.quality ~= nil and meta.quality)
        or (watch and watch.quality)
        or (hist and hist.quality)
        or (cat and cat[4])
        or 1

    return name, icon, quality
end

function DB:RecordLedgerBuy(itemID, qty, totalCostCopper, meta)
    if demoModeActive then return false, "Demo mode active" end
    meta = meta or {}
    itemID = tonumber(itemID)
    qty = math.floor((tonumber(qty) or 0) + 0.5)
    totalCostCopper = math.floor((tonumber(totalCostCopper) or 0) + 0.5)
    if qty <= 0 or totalCostCopper <= 0 then
        return false, "Invalid quantity or purchase cost."
    end

    local market = self:GetActiveMarket()
    local now = meta.ts or (time and time()) or 0
    local character = meta.character or (UnitName and UnitName("player")) or "Alt"
    local unitPrice = math.max(1, math.floor((totalCostCopper / qty) + 0.5))
    local name, icon, quality = ResolveLedgerItemMeta(market, itemID, meta)

    -- Auto-update Inventory (weighted average cost basis + per-character breakdown)
    if itemID and itemID > 0 and not meta.skipInventory then
        local existing = market.investments[itemID]
        if not existing then
            market.investments[itemID] = {
                qty            = qty,
                avgCost        = unitPrice,
                totalCost      = totalCostCopper,
                realizedProfit = 0,
                holder         = character,
                byChar         = {
                    [character] = {
                        qty            = qty,
                        avgCost        = unitPrice,
                        totalCost      = totalCostCopper,
                        realizedProfit = 0,
                    },
                },
                name           = name,
                icon           = icon,
                quality        = quality,
                notes          = "",
                source         = meta.source or "AH",
                lastBuyTs      = now,
                updatedAt      = now,
            }
        else
            local prevQty = existing.qty or 0
            local prevTotal = existing.totalCost or (prevQty * (existing.avgCost or 0))
            local newQty = prevQty + qty
            local newTotal = prevTotal + totalCostCopper
            existing.qty       = newQty
            existing.totalCost = newTotal
            existing.avgCost   = (newQty > 0) and math.floor((newTotal / newQty) + 0.5) or unitPrice
            existing.name      = name
            existing.icon      = icon
            existing.quality   = quality
            if type(existing.byChar) ~= "table" then existing.byChar = {} end
            local cb = existing.byChar[character]
            if not cb then
                existing.byChar[character] = {
                    qty            = qty,
                    avgCost        = unitPrice,
                    totalCost      = totalCostCopper,
                    realizedProfit = 0,
                }
            else
                local cq = (cb.qty or 0) + qty
                local ct = (cb.totalCost or ((cb.qty or 0) * (cb.avgCost or 0))) + totalCostCopper
                cb.qty       = cq
                cb.totalCost = ct
                cb.avgCost   = (cq > 0) and math.floor((ct / cq) + 0.5) or unitPrice
            end
            if character and character ~= "" then
                if existing.holder and existing.holder ~= "" and not existing.holder:find(character, 1, true) then
                    existing.holder = existing.holder .. ", " .. character
                else
                    existing.holder = character
                end
            end
            existing.lastBuyTs = now
            existing.updatedAt = now
        end
    end

    local entryId = market.ledgerNextId or ((#market.ledger) + 1)
    market.ledgerNextId = entryId + 1

    local rec = {
        id           = entryId,
        ts           = now,
        type         = "BUY",
        itemID       = itemID,
        name         = name,
        icon         = icon,
        quality      = quality,
        qty          = qty,
        unitPrice    = unitPrice,
        gross        = totalCostCopper,
        ahCut        = 0,
        netTotal     = totalCostCopper,
        costBasis    = totalCostCopper,
        profit       = nil,
        roiPct       = nil,
        matched      = "BUY",
        character    = character,
        counterparty = meta.counterparty or "",
        source       = meta.source or "AH",
    }

    table.insert(market.ledger, rec)
    if #market.ledger > MAX_LEDGER_ENTRIES then
        table.remove(market.ledger, 1)
    end

    NS:FireCallback("DATA_UPDATED", itemID, "LEDGER_BUY")
    return true, rec
end

function DB:RecordLedgerSale(itemID, qty, grossCopper, ahCutCopper, meta)
    if demoModeActive then return false, "Demo mode active" end
    meta = meta or {}
    itemID = tonumber(itemID)
    qty = math.floor((tonumber(qty) or 0) + 0.5)
    grossCopper = math.floor((tonumber(grossCopper) or 0) + 0.5)
    ahCutCopper = math.max(0, math.floor((tonumber(ahCutCopper) or 0) + 0.5))
    if qty <= 0 or grossCopper <= 0 then
        return false, "Invalid quantity or sale price."
    end

    local market = self:GetActiveMarket()
    local now = meta.ts or (time and time()) or 0
    local character = meta.character or (UnitName and UnitName("player")) or "Alt"
    local netProceeds = math.max(0, grossCopper - ahCutCopper)
    local unitPrice = math.max(1, math.floor((grossCopper / qty) + 0.5))
    local name, icon, quality = ResolveLedgerItemMeta(market, itemID, meta)

    local costBasis = meta.explicitCostBasis
    local matchedQty = meta.explicitMatchedQty or 0
    local profit = nil
    local roiPct = nil
    local matchedState = "UNTRACKED"

    if meta.skipInventory and costBasis ~= nil then
        profit = netProceeds - costBasis
        roiPct = (costBasis > 0) and ((profit / costBasis) * 100) or nil
        matchedState = "FULL"
    elseif itemID and itemID > 0 and not meta.skipInventory then
        local inv = market.investments[itemID]
        if inv and (inv.qty or 0) > 0 then
            matchedQty = math.min(qty, inv.qty)
            costBasis = matchedQty * (inv.avgCost or 0)
            local matchedNet = (matchedQty == qty) and netProceeds or math.floor((netProceeds * (matchedQty / qty)) + 0.5)
            local matchedProfit = matchedNet - costBasis

            inv.qty = inv.qty - matchedQty
            inv.totalCost = inv.qty * (inv.avgCost or 0)
            inv.realizedProfit = (inv.realizedProfit or 0) + matchedProfit
            inv.name = name
            inv.icon = icon
            inv.quality = quality
            inv.lastSellTs = now
            inv.updatedAt = now

            -- Update per-character breakdown (prefer selling char's stock first, then fallback to remaining pool)
            if type(inv.byChar) == "table" then
                local cb = inv.byChar[character]
                if cb and (cb.qty or 0) > 0 then
                    local cTake = math.min(matchedQty, cb.qty)
                    cb.qty = cb.qty - cTake
                    cb.totalCost = cb.qty * (cb.avgCost or inv.avgCost or 0)
                    cb.realizedProfit = (cb.realizedProfit or 0) + matchedProfit
                else
                    if not cb then
                        cb = { qty = 0, avgCost = inv.avgCost or 0, totalCost = 0, realizedProfit = 0 }
                        inv.byChar[character] = cb
                    end
                    cb.realizedProfit = (cb.realizedProfit or 0) + matchedProfit
                    local rem = matchedQty
                    for ch, other in pairs(inv.byChar) do
                        if ch ~= character and rem > 0 and (other.qty or 0) > 0 then
                            local take = math.min(rem, other.qty)
                            other.qty = other.qty - take
                            other.totalCost = other.qty * (other.avgCost or inv.avgCost or 0)
                            rem = rem - take
                        end
                    end
                end
            end

            profit = matchedProfit
            roiPct = (costBasis > 0) and ((profit / costBasis) * 100) or nil
            matchedState = (matchedQty == qty) and "FULL" or "PARTIAL"
        end
    end

    local entryId = market.ledgerNextId or ((#market.ledger) + 1)
    market.ledgerNextId = entryId + 1

    local rec = {
        id           = entryId,
        ts           = now,
        type         = "SELL",
        itemID       = itemID,
        name         = name,
        icon         = icon,
        quality      = quality,
        qty          = qty,
        matchedQty   = matchedQty,
        unitPrice    = unitPrice,
        gross        = grossCopper,
        ahCut        = ahCutCopper,
        netTotal     = netProceeds,
        costBasis    = costBasis,
        profit       = profit,
        roiPct       = roiPct,
        matched      = matchedState,
        character    = character,
        counterparty = meta.counterparty or "",
        source       = meta.source or "MAIL",
    }

    table.insert(market.ledger, rec)
    if #market.ledger > MAX_LEDGER_ENTRIES then
        table.remove(market.ledger, 1)
    end

    NS:FireCallback("DATA_UPDATED", itemID, "LEDGER_SELL")
    return true, rec
end

function DB:GetLedgerEntries(opts)
    opts = opts or {}
    local market = self:GetActiveMarket()
    local ledger = market.ledger or {}
    local out = {}

    local now = opts.nowTs or (time and time()) or 0
    local cutoff = 0
    if opts.days == 1 then
        if date then
            local d = date("*t", now)
            cutoff = now - ((d.hour * 3600) + (d.min * 60) + d.sec)
        else
            cutoff = now - 86400
        end
    elseif opts.days and opts.days > 1 then
        cutoff = now - (opts.days * 86400)
    end

    local typeFilter = opts.typeFilter or "ALL"
    local charFilterSet = self:BuildCharacterFilterSet(opts.charFilter)
    local searchQ = (type(opts.search) == "string") and opts.search:lower():match("^%s*(.-)%s*$") or ""

    for i = #ledger, 1, -1 do
        local e = ledger[i]
        local ok = true
        if cutoff > 0 and (e.ts or 0) < cutoff then
            ok = false
        end
        if ok and typeFilter ~= "ALL" and e.type ~= typeFilter then
            ok = false
        end
        if ok and charFilterSet and not self:MatchesCharacterFilter(e.character, charFilterSet) then
            ok = false
        end
        if ok and searchQ ~= "" then
            local nMatch = e.name and e.name:lower():find(searchQ, 1, true)
            local cMatch = e.character and e.character:lower():find(searchQ, 1, true)
            local pMatch = e.counterparty and e.counterparty:lower():find(searchQ, 1, true)
            if not nMatch and not cMatch and not pMatch then
                ok = false
            end
        end
        if ok then
            table.insert(out, e)
        end
    end

    return out
end

function DB:GetLedgerSummary(days, nowTs, charFilter)
    local entries = self:GetLedgerEntries({ days = days, nowTs = nowTs, charFilter = charFilter })
    local totalBought = 0
    local totalSoldGross = 0
    local totalSoldNet = 0
    local totalFees = 0
    local realizedProfit = 0
    local matchedCostBasis = 0
    local buyCount = 0
    local sellCount = 0
    local matchedSellCount = 0

    for i = 1, #entries do
        local e = entries[i]
        if e.type == "BUY" then
            buyCount = buyCount + 1
            totalBought = totalBought + (e.netTotal or e.gross or 0)
        elseif e.type == "SELL" then
            sellCount = sellCount + 1
            totalSoldGross = totalSoldGross + (e.gross or 0)
            totalSoldNet = totalSoldNet + (e.netTotal or 0)
            totalFees = totalFees + (e.ahCut or 0)
            if e.profit ~= nil then
                realizedProfit = realizedProfit + e.profit
                matchedCostBasis = matchedCostBasis + (e.costBasis or 0)
                matchedSellCount = matchedSellCount + 1
            end
        end
    end

    return {
        totalBought      = totalBought,
        totalSoldGross   = totalSoldGross,
        totalSoldNet     = totalSoldNet,
        totalFees        = totalFees,
        netCashflow      = totalSoldNet - totalBought,
        realizedProfit   = realizedProfit,
        matchedCostBasis = matchedCostBasis,
        realizedRoiPct   = (matchedCostBasis > 0) and ((realizedProfit / matchedCostBasis) * 100) or nil,
        buyCount         = buyCount,
        sellCount        = sellCount,
        matchedSellCount = matchedSellCount,
        totalCount       = #entries,
    }
end

-- Rolls up all Ledger transactions (and open Inventory positions) into ONE summary row per item
-- so you can immediately see whether you are making or losing gold on each item overall.
function DB:GetItemProfitSummaries(opts)
    opts = opts or {}
    local market = self:GetActiveMarket()
    local entries = self:GetLedgerEntries({ days = opts.days, nowTs = opts.nowTs, charFilter = opts.charFilter })
    local investments = market.investments or {}
    local cutRate = (NS.Analytics and NS.Analytics.GetAHCutRate()) or 0.05
    local searchQ = (type(opts.search) == "string") and opts.search:lower():match("^%s*(.-)%s*$") or ""

    local byKey = {}

    local function GetOrCreateBucket(itemID, name, icon, quality)
        local key = (itemID and itemID > 0) and itemID or ("NAME:" .. tostring(name or "Unknown"):lower())
        local b = byKey[key]
        if not b then
            local resolvedName, resolvedIcon, resolvedQual = ResolveLedgerItemMeta(market, itemID, {
                name    = name,
                icon    = icon,
                quality = quality,
            })
            b = {
                key              = key,
                itemID           = (itemID and itemID > 0) and itemID or nil,
                name             = resolvedName,
                icon             = resolvedIcon,
                quality          = resolvedQual,
                buyCount         = 0,
                buyQty           = 0,
                buyTotal         = 0,
                sellCount        = 0,
                sellQty          = 0,
                sellGross        = 0,
                sellNet          = 0,
                sellFees         = 0,
                matchedProfit    = 0,
                matchedCost      = 0,
                matchedSellCount = 0,
                untrackedSellNet = 0,
                onHandQty        = 0,
                onHandCost       = 0,
                onHandNetVal     = 0,
                unrealizedPnL    = 0,
                lastTs           = 0,
            }
            byKey[key] = b
        end
        return b
    end

    -- 1. Aggregate every Ledger transaction in the selected timeframe
    for i = 1, #entries do
        local e = entries[i]
        local b = GetOrCreateBucket(e.itemID, e.name, e.icon, e.quality)
        if (e.ts or 0) > b.lastTs then
            b.lastTs = e.ts or 0
        end
        if e.type == "BUY" then
            b.buyCount = b.buyCount + 1
            b.buyQty   = b.buyQty + (e.qty or 0)
            b.buyTotal = b.buyTotal + (e.netTotal or e.gross or 0)
        elseif e.type == "SELL" then
            b.sellCount = b.sellCount + 1
            b.sellQty   = b.sellQty + (e.qty or 0)
            b.sellGross = b.sellGross + (e.gross or 0)
            b.sellNet   = b.sellNet + (e.netTotal or 0)
            b.sellFees  = b.sellFees + (e.ahCut or 0)
            if e.profit ~= nil then
                b.matchedProfit    = b.matchedProfit + e.profit
                b.matchedCost      = b.matchedCost + (e.costBasis or 0)
                b.matchedSellCount = b.matchedSellCount + 1
            else
                b.untrackedSellNet = b.untrackedSellNet + (e.netTotal or 0)
            end
        end
    end

    -- 2. Attach open Inventory positions (filtered by charFilter when selected)
    for itemID in pairs(investments) do
        local inv = self:GetInvestmentView(itemID, opts.charFilter)
        if type(inv) == "table" and ((inv.qty or 0) > 0 or (inv.realizedProfit or 0) ~= 0) then
            local alreadyPresent = (byKey[itemID] ~= nil)
            if alreadyPresent or (opts.days == nil) then
                local b = GetOrCreateBucket(itemID, inv.name, inv.icon, inv.quality)
                local qty = inv.qty or 0
                local cost = inv.totalCost or (qty * (inv.avgCost or 0))
                local hist = market.history and market.history[itemID] or nil
                local latest = hist and NS.Analytics and NS.Analytics.GetLatestPoint(hist) or nil
                local mktPrice = (latest and latest.min and latest.min > 0) and latest.min or nil
                local netVal = (qty > 0 and mktPrice) and math.floor((qty * mktPrice) * (1 - cutRate) + 0.5) or cost

                b.onHandQty     = qty
                b.onHandCost    = cost
                b.onHandNetVal  = netVal
                b.unrealizedPnL = (qty > 0) and (netVal - cost) or 0
                if (inv.updatedAt or 0) > b.lastTs then
                    b.lastTs = inv.updatedAt or 0
                end
                -- If item had pre-Ledger manual realizedProfit/cost with no ledger rows, reflect it cleanly in All Time
                if opts.days == nil and b.buyCount == 0 and b.sellCount == 0 then
                    b.buyQty = qty
                    b.buyTotal = cost
                    if (inv.realizedProfit or 0) ~= 0 then
                        b.matchedProfit = inv.realizedProfit
                        b.matchedSellCount = 1
                    end
                end
            end
        end
    end

    -- 3. Finalize per-item P&L metrics & filter by search
    local list = {}
    local totals = {
        itemCount     = 0,
        winners       = 0,
        losers        = 0,
        realizedPnL   = 0,
        unrealizedPnL = 0,
        totalPnL      = 0,
        totalBought   = 0,
        totalSoldNet  = 0,
        bestItem      = nil,
        worstItem     = nil,
    }

    for _, b in pairs(byKey) do
        local keep = true
        if searchQ ~= "" then
            if not (b.name and b.name:lower():find(searchQ, 1, true)) then
                keep = false
            end
        end
        if keep then
            b.avgBuy  = (b.buyQty > 0) and math.floor((b.buyTotal / b.buyQty) + 0.5) or 0
            b.avgSell = (b.sellQty > 0) and math.floor((b.sellNet / b.sellQty) + 0.5) or 0

            -- Realized P&L: matched flips profit + net revenue from farmed/crafted sales with no tracked buy cost
            b.realizedPnL = b.matchedProfit + b.untrackedSellNet
            b.isFarmedOnly = (b.buyQty == 0 and b.onHandQty == 0 and b.untrackedSellNet > 0)
            b.realizedRoiPct = (b.matchedCost > 0) and ((b.matchedProfit / b.matchedCost) * 100) or nil

            -- Total P&L (Incl. remaining open stock): Realized P&L + Unrealized P&L on stock currently held
            b.totalPnL = b.realizedPnL + b.unrealizedPnL
            local capitalBasis = math.max(b.buyTotal, b.matchedCost + b.onHandCost)
            b.totalRoiPct = (capitalBasis > 0) and ((b.totalPnL / capitalBasis) * 100) or nil

            totals.itemCount     = totals.itemCount + 1
            totals.realizedPnL   = totals.realizedPnL + b.realizedPnL
            totals.unrealizedPnL = totals.unrealizedPnL + b.unrealizedPnL
            totals.totalPnL      = totals.totalPnL + b.totalPnL
            totals.totalBought   = totals.totalBought + b.buyTotal
            totals.totalSoldNet  = totals.totalSoldNet + b.sellNet

            if b.totalPnL > 0 then
                totals.winners = totals.winners + 1
            elseif b.totalPnL < 0 then
                totals.losers = totals.losers + 1
            end

            if not totals.bestItem or b.totalPnL > totals.bestItem.totalPnL then
                totals.bestItem = b
            end
            if b.totalPnL < 0 and (not totals.worstItem or b.totalPnL < totals.worstItem.totalPnL) then
                totals.worstItem = b
            end

            table.insert(list, b)
        end
    end

    return list, totals
end

-- Replays Ledger transactions chronologically to rebuild exact Inventory qty,
-- weighted average cost basis, per-character byChar splits, and SELL row P&L.
-- When purgeDuplicates is true, removes:
--   1. Corrupted commodity BUY entries with source == "MAIL" (multi-stack mail splitting)
--   2. Corrupted legacy 0c SELL entries (buyout=1 flag bug from early builds)
--   3. Duplicate rapid-fire MAIL SELL entries logged within 3s by Blizzard "Open All" retries
function DB:RebuildAccountingFromLedger(purgeDuplicates, marketOverride, silent)
    if demoModeActive and not marketOverride then
        return { purged = 0, purgedBuys = 0, purgedSells = 0, replayed = 0 }
    end
    local market = marketOverride or self:GetActiveMarket()
    if type(market.ledger) ~= "table" then market.ledger = {} end
    if type(market.investments) ~= "table" then market.investments = {} end

    -- 1. Sort ledger chronologically (ts asc, id asc) before deduplication & replay
    table.sort(market.ledger, function(a, b)
        local at, bt = a.ts or 0, b.ts or 0
        if at ~= bt then return at < bt end
        return (a.id or 0) < (b.id or 0)
    end)

    -- 2. Identify which itemIDs have live AH buys or are stackable commodities
    local hasAHBuy = {}
    for i = 1, #market.ledger do
        local e = market.ledger[i]
        if e.type == "BUY" and e.source == "AH" and e.itemID then
            hasAHBuy[e.itemID] = true
        end
    end

    local purged = 0
    local purgedBuys = 0
    local purgedSells = 0
    if purgeDuplicates then
        local cleaned = {}
        local lastKeptSellByKey = {}
        for i = 1, #market.ledger do
            local e = market.ledger[i]
            local dropReason = nil

            if e.type == "BUY" and e.source == "MAIL" and e.itemID then
                local maxStack = (C_Item and C_Item.GetItemMaxStackSizeByID and C_Item.GetItemMaxStackSizeByID(e.itemID)) or 1
                if hasAHBuy[e.itemID] or maxStack > 1 then
                    dropReason = "BUY"
                end
            elseif e.type == "SELL" and e.source == "MAIL" then
                local netAmt = tonumber(e.netTotal) or 0
                local grossAmt = tonumber(e.gross) or 0
                if netAmt <= 0 and grossAmt <= 25 then
                    -- Legacy corrupted 0c sale from buyout=1 flag bug
                    dropReason = "SELL"
                else
                    local chKey = tostring(e.character or ""):lower()
                    local itemKey = (e.itemID and tostring(e.itemID)) or ("NAME:" .. tostring(e.name or ""):lower())
                    local sellKey = chKey .. "|" .. itemKey
                    local prev = lastKeptSellByKey[sellKey]
                    if prev
                        and math.abs((e.ts or 0) - (prev.ts or 0)) <= 3
                        and (tonumber(e.qty) or 0) == (tonumber(prev.qty) or 0)
                        and netAmt == (tonumber(prev.netTotal) or 0)
                        and tostring(e.counterparty or "") == tostring(prev.counterparty or "")
                    then
                        dropReason = "SELL"
                    else
                        lastKeptSellByKey[sellKey] = e
                    end
                end
            end

            if dropReason == "BUY" then
                purged = purged + 1
                purgedBuys = purgedBuys + 1
            elseif dropReason == "SELL" then
                purged = purged + 1
                purgedSells = purgedSells + 1
            else
                table.insert(cleaned, e)
            end
        end
        market.ledger = cleaned
        market.pendingMailMatches = {}
    end

    -- 3. Preserve any pre-Ledger manual investments (items with NO AH/MAIL buys in ledger)
    local hasAutoActivity = {}
    for i = 1, #market.ledger do
        local e = market.ledger[i]
        if e.itemID and (e.source == "AH" or e.source == "MAIL") then
            hasAutoActivity[e.itemID] = true
        end
    end

    local oldInvestments = market.investments
    local rebuiltInv = {}
    for itemID, oldInv in pairs(oldInvestments) do
        if type(oldInv) == "table" and not hasAutoActivity[itemID] then
            -- Keep pre-Ledger manual investment intact and ensure byChar exists for char filtering
            if type(oldInv.byChar) ~= "table" then
                local ch = (type(oldInv.holder) == "string" and oldInv.holder ~= "") and oldInv.holder:match("^%s*([^,]+)") or "Alt"
                ch = ch:match("^%s*(.-)%s*$")
                oldInv.byChar = {
                    [ch] = {
                        qty            = oldInv.qty or 0,
                        avgCost        = oldInv.avgCost or 0,
                        totalCost      = oldInv.totalCost or ((oldInv.qty or 0) * (oldInv.avgCost or 0)),
                        realizedProfit = oldInv.realizedProfit or 0,
                    },
                }
            end
            rebuiltInv[itemID] = oldInv
        end
    end

    -- 4. Replay every auto-tracked BUY and SELL chronologically
    local replayed = 0
    for i = 1, #market.ledger do
        local e = market.ledger[i]
        local itemID = tonumber(e.itemID)
        if itemID and itemID > 0 and hasAutoActivity[itemID] then
            local ch = (type(e.character) == "string" and e.character ~= "") and e.character or "Alt"
            local qty = math.max(0, math.floor((tonumber(e.qty) or 0) + 0.5))

            if e.type == "BUY" and qty > 0 then
                local totalCost = math.floor((tonumber(e.netTotal or e.gross) or 0) + 0.5)
                local unitPrice = (qty > 0) and math.max(1, math.floor((totalCost / qty) + 0.5)) or 0
                local inv = rebuiltInv[itemID]
                if not inv then
                    inv = {
                        qty            = qty,
                        avgCost        = unitPrice,
                        totalCost      = totalCost,
                        realizedProfit = 0,
                        holder         = ch,
                        byChar         = {
                            [ch] = {
                                qty            = qty,
                                avgCost        = unitPrice,
                                totalCost      = totalCost,
                                realizedProfit = 0,
                            },
                        },
                        name           = e.name,
                        icon           = e.icon,
                        quality        = e.quality,
                        notes          = (oldInvestments[itemID] and oldInvestments[itemID].notes) or "",
                        source         = e.source or "AH",
                        lastBuyTs      = e.ts or 0,
                        updatedAt      = e.ts or 0,
                    }
                    rebuiltInv[itemID] = inv
                else
                    local newQty = (inv.qty or 0) + qty
                    local newTotal = (inv.totalCost or 0) + totalCost
                    inv.qty = newQty
                    inv.totalCost = newTotal
                    inv.avgCost = (newQty > 0) and math.floor((newTotal / newQty) + 0.5) or unitPrice
                    if not inv.holder or inv.holder == "" then
                        inv.holder = ch
                    elseif not inv.holder:find(ch, 1, true) then
                        inv.holder = inv.holder .. ", " .. ch
                    end
                    local cb = inv.byChar[ch]
                    if not cb then
                        inv.byChar[ch] = {
                            qty            = qty,
                            avgCost        = unitPrice,
                            totalCost      = totalCost,
                            realizedProfit = 0,
                        }
                    else
                        local cq = (cb.qty or 0) + qty
                        local ct = (cb.totalCost or 0) + totalCost
                        cb.qty = cq
                        cb.totalCost = ct
                        cb.avgCost = (cq > 0) and math.floor((ct / cq) + 0.5) or unitPrice
                    end
                    inv.lastBuyTs = math.max(inv.lastBuyTs or 0, e.ts or 0)
                    inv.updatedAt = math.max(inv.updatedAt or 0, e.ts or 0)
                end
                replayed = replayed + 1

            elseif e.type == "SELL" and qty > 0 then
                local netProceeds = math.floor((tonumber(e.netTotal) or 0) + 0.5)
                local inv = rebuiltInv[itemID]
                if inv and (inv.qty or 0) > 0 then
                    local matchedQty = math.min(qty, inv.qty)
                    local costBasis = matchedQty * (inv.avgCost or 0)
                    local matchedNet = (matchedQty == qty) and netProceeds or math.floor((netProceeds * (matchedQty / qty)) + 0.5)
                    local profit = matchedNet - costBasis

                    inv.qty = inv.qty - matchedQty
                    inv.totalCost = inv.qty * (inv.avgCost or 0)
                    inv.realizedProfit = (inv.realizedProfit or 0) + profit
                    inv.lastSellTs = math.max(inv.lastSellTs or 0, e.ts or 0)
                    inv.updatedAt = math.max(inv.updatedAt or 0, e.ts or 0)

                    local cb = inv.byChar[ch]
                    if cb and (cb.qty or 0) > 0 then
                        local cTake = math.min(matchedQty, cb.qty)
                        cb.qty = cb.qty - cTake
                        cb.totalCost = cb.qty * (cb.avgCost or inv.avgCost or 0)
                        cb.realizedProfit = (cb.realizedProfit or 0) + profit
                    else
                        if not cb then
                            cb = { qty = 0, avgCost = inv.avgCost or 0, totalCost = 0, realizedProfit = 0 }
                            inv.byChar[ch] = cb
                        end
                        cb.realizedProfit = (cb.realizedProfit or 0) + profit
                        local rem = matchedQty
                        for otherCh, other in pairs(inv.byChar) do
                            if otherCh ~= ch and rem > 0 and (other.qty or 0) > 0 then
                                local take = math.min(rem, other.qty)
                                other.qty = other.qty - take
                                other.totalCost = other.qty * (other.avgCost or inv.avgCost or 0)
                                rem = rem - take
                            end
                        end
                    end

                    e.matchedQty = matchedQty
                    e.costBasis  = costBasis
                    e.profit     = profit
                    e.roiPct     = (costBasis > 0) and ((profit / costBasis) * 100) or nil
                    e.matched    = (matchedQty == qty) and "FULL" or "PARTIAL"
                else
                    e.matchedQty = 0
                    e.costBasis  = nil
                    e.profit     = nil
                    e.roiPct     = nil
                    e.matched    = "UNTRACKED"
                end
                replayed = replayed + 1
            end
        end
    end

    -- Preserve manually cleared items that had 0 qty and no remaining ledger entries? No, only active rebuilt ones.
    market.investments = rebuiltInv

    if not silent then
        NS:FireCallback("DATA_UPDATED", nil, "LEDGER_REBUILT")
    end
    return { purged = purged, purgedBuys = purgedBuys, purgedSells = purgedSells, replayed = replayed }
end

function DB:DeleteLedgerEntry(entryId, skipInventorySync)
    local market = self:GetActiveMarket()
    local ledger = market.ledger or {}
    for i = #ledger, 1, -1 do
        local e = ledger[i]
        if e.id == entryId then
            table.remove(ledger, i)

            -- Keep Inventory in sync when deleting an erroneous BUY/SELL ledger entry
            if not skipInventorySync and e.itemID and market.investments and market.investments[e.itemID] then
                local inv = market.investments[e.itemID]
                if e.type == "BUY" and (e.qty or 0) > 0 then
                    local newQty = math.max(0, (inv.qty or 0) - e.qty)
                    local removedCost = e.costBasis or e.netTotal or e.gross or 0
                    local prevTotal = inv.totalCost or ((inv.qty or 0) * (inv.avgCost or 0))
                    local newTotal = math.max(0, prevTotal - removedCost)
                    inv.qty = newQty
                    if newQty > 0 then
                        inv.totalCost = (newTotal > 0) and newTotal or (newQty * (inv.avgCost or 0))
                        inv.avgCost = math.floor((inv.totalCost / newQty) + 0.5)
                    else
                        inv.totalCost = 0
                    end
                    inv.updatedAt = (time and time()) or 0
                elseif e.type == "SELL" and (e.matchedQty or 0) > 0 then
                    local restoredQty = e.matchedQty
                    inv.qty = (inv.qty or 0) + restoredQty
                    inv.totalCost = inv.qty * (inv.avgCost or 0)
                    if e.profit ~= nil then
                        inv.realizedProfit = (inv.realizedProfit or 0) - e.profit
                    end
                    inv.updatedAt = (time and time()) or 0
                end
            end

            NS:FireCallback("DATA_UPDATED", e.itemID, "LEDGER_DELETED")
            return true
        end
    end
    return false
end

function DB:AddPendingMailMatch(itemID, qty, totalPrice, ts)
    if demoModeActive or not itemID or not qty or qty <= 0 then return end
    local market = self:GetActiveMarket()
    local list = market.pendingMailMatches
    local now = ts or (time and time()) or 0

    -- Prune stale pending matches (> 72h old)
    for i = #list, 1, -1 do
        if (now - (list[i].ts or 0)) > (72 * 3600) or (list[i].qty or 0) <= 0 then
            table.remove(list, i)
        end
    end

    table.insert(list, {
        itemID = tonumber(itemID),
        qty    = math.floor(qty + 0.5),
        total  = math.floor((totalPrice or 0) + 0.5),
        ts     = now,
    })
end

-- Matches and consumes pending live-AH purchases when items are collected from Mailbox.
-- Handles BOTH single-mail deliveries (even when Blizzard's commodity invoice reports
-- unit price vs total price) AND split multi-seller commodity mails (e.g. 8 bought -> 5 + 3 mailed).
-- Returns: fullyMatched (boolean), remainingUnmatchedQty (number)
function DB:ConsumePendingMailMatch(itemID, qty, totalPrice, nowTs)
    if demoModeActive or not itemID or not qty or qty <= 0 then return false, qty or 0 end
    local market = self:GetActiveMarket()
    local list = market.pendingMailMatches
    local now = nowTs or (time and time()) or 0
    local idNum = tonumber(itemID)
    local qNum = math.floor(qty + 0.5)
    local tNum = math.floor((totalPrice or 0) + 0.5)

    -- Prune expired/empty entries first
    for i = #list, 1, -1 do
        if (now - (list[i].ts or 0)) > (72 * 3600) or (list[i].qty or 0) <= 0 then
            table.remove(list, i)
        end
    end

    -- Pass 1: Exact itemID + qty + close totalPrice match
    for i = 1, #list do
        local m = list[i]
        if m.itemID == idNum and m.qty == qNum and tNum > 0 and math.abs((m.total or 0) - tNum) <= math.max(5, qNum) then
            table.remove(list, i)
            return true, 0
        end
    end

    -- Pass 2: Exact itemID + qty match (covers commodity invoices where bid/buyout is unit price)
    for i = 1, #list do
        local m = list[i]
        if m.itemID == idNum and m.qty == qNum then
            table.remove(list, i)
            return true, 0
        end
    end

    -- Pass 3: Partial / split-mail consumption across pending live-AH buys for the same itemID
    local remaining = qNum
    for i = 1, #list do
        local m = list[i]
        if m.itemID == idNum and (m.qty or 0) > 0 and remaining > 0 then
            local take = math.min(m.qty, remaining)
            m.qty = m.qty - take
            remaining = remaining - take
        end
    end

    -- Clean up depleted entries
    for i = #list, 1, -1 do
        if (list[i].qty or 0) <= 0 then
            table.remove(list, i)
        end
    end

    return (remaining == 0), remaining
end

function DB:GetActiveMarket()
    return self:GetMarket(self:GetActiveMarketKey())
end

--------------------------------------------------------------------------------
-- Pre-Populate All Profession Materials
--------------------------------------------------------------------------------

function DB:SeedProfessionMaterials(silent)
    if demoModeActive then return 0 end
    if not NS.Catalog or not NS.Catalog.ITEMS then return 0 end

    local market = self:GetActiveMarket()

    -- Ensure all profession groups exist
    local groupSet = {}
    for i = 1, #market.groups do
        groupSet[market.groups[i]] = true
    end
    for i = 1, #NS.Catalog.PROFESSION_GROUPS do
        local g = NS.Catalog.PROFESSION_GROUPS[i]
        if not groupSet[g] then
            table.insert(market.groups, g)
            groupSet[g] = true
        end
    end

    local now = (time and time()) or 0
    local added = 0
    for i = 1, #NS.Catalog.ITEMS do
        local spec = NS.Catalog.ITEMS[i]
        local itemID, fallbackName, groupName, quality = spec[1], spec[2], spec[3], spec[4]
        if not market.watchlist[itemID] then
            local liveName, _, liveQuality, _, _, _, _, _, _, liveIcon = NS.Compat.GetItemInfo(itemID)
            if not liveName then
                NS.Compat.RequestLoadItemDataByID(itemID)
            end
            market.watchlist[itemID] = {
                itemID     = itemID,
                name       = liveName or fallbackName,
                icon       = liveIcon or NS.Compat.GetItemIconByID(itemID) or 134400,
                quality    = liveQuality ~= nil and liveQuality or quality,
                group      = groupName,
                buyTarget  = nil,
                sellTarget = nil,
                addedAt    = now,
            }
            added = added + 1
        end
    end

    market.professionsSeeded = true
    if not silent and added > 0 then
        NS.Print(string.format("Pre-populated %d crafting materials across all professions.", added))
    end
    NS:FireCallback("GROUPS_UPDATED")
    NS:FireCallback("DATA_UPDATED", nil, "PROFESSIONS_SEEDED")
    return added
end

--------------------------------------------------------------------------------
-- Groups CRUD
--------------------------------------------------------------------------------

function DB:GetGroups()
    local market = self:GetActiveMarket()
    return market.groups
end

function DB:HasGroup(groupName)
    local groups = self:GetGroups()
    for i = 1, #groups do
        if groups[i] == groupName then
            return true, i
        end
    end
    return false, nil
end

function DB:AddGroup(groupName)
    if type(groupName) ~= "string" then return false, "Invalid group name." end
    local clean = groupName:match("^%s*(.-)%s*$")
    if clean == "" or clean == "All" or clean == "Alerts Only" then
        return false, "Reserved or empty group name."
    end
    if self:HasGroup(clean) then
        return false, "Group already exists."
    end
    local market = self:GetActiveMarket()
    table.insert(market.groups, clean)
    NS:FireCallback("GROUPS_UPDATED")
    return true
end

function DB:RenameGroup(oldName, newName)
    if type(newName) ~= "string" then return false, "Invalid group name." end
    local clean = newName:match("^%s*(.-)%s*$")
    if clean == "" or clean == "All" or clean == "Alerts Only" then
        return false, "Reserved or empty group name."
    end
    local exists, idx = self:HasGroup(oldName)
    if not exists then return false, "Group not found." end
    if self:HasGroup(clean) then return false, "Target group name already exists." end

    local market = self:GetActiveMarket()
    market.groups[idx] = clean
    for _, item in pairs(market.watchlist) do
        if item.group == oldName then
            item.group = clean
        end
    end
    NS:FireCallback("GROUPS_UPDATED")
    NS:FireCallback("DATA_UPDATED")
    return true
end

function DB:DeleteGroup(groupName)
    local market = self:GetActiveMarket()
    if #market.groups <= 1 then
        return false, "At least one group must remain."
    end
    local exists, idx = self:HasGroup(groupName)
    if not exists then return false, "Group not found." end

    table.remove(market.groups, idx)
    local fallback = market.groups[1]
    for _, item in pairs(market.watchlist) do
        if item.group == groupName then
            item.group = fallback
        end
    end
    NS:FireCallback("GROUPS_UPDATED")
    NS:FireCallback("DATA_UPDATED")
    return true
end

--------------------------------------------------------------------------------
-- Watchlist CRUD
--------------------------------------------------------------------------------

function DB:RefreshItemMetadata(itemID, entry)
    if not itemID or not entry then return end
    local name, _, quality, _, _, _, _, _, _, icon = NS.Compat.GetItemInfo(itemID)
    if name and name ~= "" then
        entry.name = name
    end
    if quality ~= nil then
        entry.quality = quality
    end
    if icon then
        entry.icon = icon
    elseif not entry.icon then
        entry.icon = NS.Compat.GetItemIconByID(itemID)
    end
end

function DB:AddWatchItem(itemID, groupName, explicitName, explicitIcon, explicitQuality)
    itemID = NS.Compat.ParseItemID(itemID)
    if not itemID then
        return false, "Could not resolve an Item ID."
    end

    local market = self:GetActiveMarket()
    local groups = market.groups
    local targetGroup = groupName
    if not targetGroup or targetGroup == "All" or targetGroup == "Alerts Only" or not self:HasGroup(targetGroup) then
        -- Use catalog profession group if known, otherwise first group
        local catSpec = NS.Catalog and NS.Catalog.BY_ID and NS.Catalog.BY_ID[itemID]
        if catSpec and self:HasGroup(catSpec[3]) then
            targetGroup = catSpec[3]
        else
            targetGroup = groups[1] or "Herbalism"
        end
    end

    local existing = market.watchlist[itemID]
    if existing then
        if groupName and self:HasGroup(groupName) then
            existing.group = groupName
        end
        self:RefreshItemMetadata(itemID, existing)
        NS:FireCallback("DATA_UPDATED", itemID, "WATCH_UPDATED")
        return true, existing, false
    end

    local name, _, quality, _, _, _, _, _, _, icon = NS.Compat.GetItemInfo(itemID)
    if not name then
        NS.Compat.RequestLoadItemDataByID(itemID)
    end

    local catSpec = NS.Catalog and NS.Catalog.BY_ID and NS.Catalog.BY_ID[itemID]
    local entry = {
        itemID     = itemID,
        name       = name or explicitName or (catSpec and catSpec[2]) or ("Item #" .. tostring(itemID)),
        icon       = icon or explicitIcon or NS.Compat.GetItemIconByID(itemID) or 134400,
        quality    = quality ~= nil and quality or (explicitQuality ~= nil and explicitQuality or (catSpec and catSpec[4]) or 1),
        group      = targetGroup,
        buyTarget  = nil,
        sellTarget = nil,
        addedAt    = (time and time()) or 0,
    }
    market.watchlist[itemID] = entry
    NS:FireCallback("DATA_UPDATED", itemID, "WATCH_ADDED")
    return true, entry, true
end

function DB:RemoveWatchItem(itemID)
    local market = self:GetActiveMarket()
    if market.watchlist[itemID] then
        market.watchlist[itemID] = nil
        NS:FireCallback("DATA_UPDATED", itemID, "WATCH_REMOVED")
        return true
    end
    return false
end

function DB:GetWatchItem(itemID)
    local market = self:GetActiveMarket()
    return market.watchlist[itemID]
end

function DB:GetWatchlist()
    local market = self:GetActiveMarket()
    return market.watchlist
end

function DB:GetWatchedItemIDs(groupFilter)
    local market = self:GetActiveMarket()
    local list = {}
    for itemID, entry in pairs(market.watchlist) do
        if not groupFilter or groupFilter == "All" or groupFilter == "Alerts Only" or entry.group == groupFilter then
            table.insert(list, itemID)
        end
    end
    table.sort(list)
    return list
end

function DB:GetTargetedItemIDs()
    local market = self:GetActiveMarket()
    local list = {}
    for itemID, entry in pairs(market.watchlist) do
        if entry and ((entry.buyTarget and entry.buyTarget > 0) or (entry.sellTarget and entry.sellTarget > 0)) then
            table.insert(list, itemID)
        end
    end
    table.sort(list)
    return list
end

function DB:SetItemGroup(itemID, groupName)
    local entry = self:GetWatchItem(itemID)
    if not entry or not self:HasGroup(groupName) then
        return false
    end
    entry.group = groupName
    NS:FireCallback("DATA_UPDATED", itemID, "GROUP_CHANGED")
    return true
end

function DB:SetItemTargets(itemID, buyTarget, sellTarget)
    local entry = self:GetWatchItem(itemID)
    if not entry then return false end
    entry.buyTarget = (buyTarget and buyTarget > 0) and math.floor(buyTarget + 0.5) or nil
    entry.sellTarget = (sellTarget and sellTarget > 0) and math.floor(sellTarget + 0.5) or nil
    NS:FireCallback("DATA_UPDATED", itemID, "TARGETS_CHANGED")
    return true
end

-- Unified offline item search: merges Catalog + Player Bags + Watchlist + Passive AH History
function DB:SearchOfflineItems(query, limit)
    if type(query) ~= "string" then return {} end
    local q = query:lower():match("^%s*(.-)%s*$")
    if q == "" then return {} end

    local maxResults = limit or 12
    local market = self:GetActiveMarket()
    local results = {}
    local seen = {}

    local function PushResult(itemID, name, icon, quality, source)
        if not itemID or seen[itemID] then return end
        seen[itemID] = true
        local hist = market.history[itemID]
        local latest = hist and NS.Analytics and NS.Analytics.GetLatestPoint(hist) or nil
        table.insert(results, {
            itemID  = itemID,
            name    = name or ("Item #" .. tostring(itemID)),
            icon    = icon or NS.Compat.GetItemIconByID(itemID) or 134400,
            quality = quality or 1,
            source  = source or "Catalog",
            price   = latest and latest.min or nil,
            watched = market.watchlist[itemID] ~= nil,
        })
    end

    -- 1. Direct numeric itemID lookup OR exact cached WoW item name (works for ANY gear/item WoW knows!)
    local numeric = tonumber(q)
    if numeric and numeric > 0 then
        local liveName, _, liveQual, _, _, _, _, _, _, liveIcon = NS.Compat.GetItemInfo(numeric)
        local catSpec = NS.Catalog and NS.Catalog.BY_ID and NS.Catalog.BY_ID[numeric]
        PushResult(numeric, liveName or (catSpec and catSpec[2]) or ("Item #" .. numeric), liveIcon, liveQual or (catSpec and catSpec[4]) or 1, "Item ID")
    else
        local trimmedOrig = query:match("^%s*(.-)%s*$")
        local directName, directLink, directQual, _, _, _, _, _, _, directIcon = NS.Compat.GetItemInfo(trimmedOrig)
        local directID = (directLink and NS.Compat.ParseItemID(directLink)) or NS.Compat.GetItemInfoInstant(trimmedOrig)
        if directID and directID > 0 then
            PushResult(directID, directName or trimmedOrig, directIcon, directQual or 1, "Game Cache")
        end
    end

    -- 2. Built-in Profession Catalog
    if NS.Catalog and NS.Catalog.Search then
        local catMatches = NS.Catalog.Search(q, maxResults)
        for i = 1, #catMatches do
            local m = catMatches[i]
            PushResult(m.itemID, m.name, m.icon, m.quality, m.source)
            if #results >= maxResults then return results end
        end
    end

    -- 3. Player Bags
    if NS.Catalog and NS.Catalog.SearchPlayerBags then
        local bagMatches = NS.Catalog.SearchPlayerBags(q, maxResults)
        for i = 1, #bagMatches do
            local m = bagMatches[i]
            PushResult(m.itemID, m.name, m.icon, m.quality, m.source)
            if #results >= maxResults then return results end
        end
    end

    -- 4. Passive & Watched AH History
    for itemID, entry in pairs(market.watchlist) do
        if not seen[itemID] and entry.name and entry.name:lower():find(q, 1, true) then
            PushResult(itemID, entry.name, entry.icon, entry.quality, entry.group or "Watched")
            if #results >= maxResults then return results end
        end
    end
    for itemID, hist in pairs(market.history) do
        if not seen[itemID] then
            local name = hist.name
            if not name then
                name = NS.Compat.GetItemInfo(itemID)
            end
            if name and name:lower():find(q, 1, true) then
                PushResult(itemID, name, hist.icon, hist.quality, "AH History")
                if #results >= maxResults then return results end
            end
        end
    end

    return results
end

--------------------------------------------------------------------------------
-- Price History Recording & Intraday -> Daily Compaction
--------------------------------------------------------------------------------

local function FoldPointIntoDaily(dailyTable, dayKey, minP, avgP, maxP, qty)
    local d = dailyTable[dayKey]
    if not d then
        dailyTable[dayKey] = { minP, avgP, maxP, minP, qty, 1 }
    else
        local count = d[6] or 1
        local newCount = count + 1
        d[1] = math.min(d[1], minP)
        d[2] = math.floor(((d[2] * count) + avgP) / newCount + 0.5)
        d[3] = math.max(d[3], maxP)
        d[4] = minP
        d[5] = math.floor(((d[5] * count) + qty) / newCount + 0.5)
        d[6] = newCount
    end
end

function DB:CompactItemHistory(itemHist, nowTs)
    if type(itemHist) ~= "table" then return end
    local now = nowTs or (time and time()) or 0
    local cutoff = now - INTRADAY_RETENTION_SECONDS
    local intraday = itemHist.intraday
    if type(intraday) ~= "table" or #intraday == 0 then return end
    if type(itemHist.daily) ~= "table" then
        itemHist.daily = {}
    end

    table.sort(intraday, function(a, b) return a[1] < b[1] end)

    local kept = {}
    for i = 1, #intraday do
        local pt = intraday[i]
        local ts = pt[1]
        if ts < cutoff then
            local dayKey = NS.DayKeyFromTimestamp(ts)
            FoldPointIntoDaily(itemHist.daily, dayKey, pt[2], pt[3], pt[4], pt[5])
        else
            table.insert(kept, pt)
        end
    end
    itemHist.intraday = kept
end

function DB:CompactAll(nowTs)
    if demoModeActive then return end
    if not ForeverMarketWatchDB or not ForeverMarketWatchDB.markets then return end
    local now = nowTs or (time and time()) or 0
    local passiveCutoff = now - (PASSIVE_PRUNE_DAYS * 86400)

    for _, market in pairs(ForeverMarketWatchDB.markets) do
        if type(market.history) == "table" then
            local toRemove = {}
            for itemID, itemHist in pairs(market.history) do
                self:CompactItemHistory(itemHist, now)
                local isWatched = market.watchlist and market.watchlist[itemID] ~= nil
                if not isWatched and (itemHist.lastScan or 0) < passiveCutoff then
                    table.insert(toRemove, itemID)
                end
            end
            for i = 1, #toRemove do
                market.history[toRemove[i]] = nil
            end
        end
    end
end

function DB:GetItemHistory(itemID)
    local market = self:GetActiveMarket()
    return market.history[itemID]
end

function DB:RecordSnapshot(itemID, minPrice, avgPrice, maxPrice, totalQty, timestamp, isPassive, marketKeyOverride, orderBook, silent)
    if demoModeActive then return false end
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 then return false end
    if not minPrice or minPrice <= 0 then return false end

    local now = timestamp or (time and time()) or 0
    local minP = math.floor(minPrice + 0.5)
    local avgP = math.floor((avgPrice and avgPrice > 0 and avgPrice or minP) + 0.5)
    local maxP = math.floor((maxPrice and maxPrice > 0 and maxPrice or minP) + 0.5)
    if maxP < minP then maxP = minP end
    local qty = math.max(0, math.floor((totalQty or 0) + 0.5))

    local market = self:GetMarket(marketKeyOverride)
    local hist = market.history[itemID]
    if type(hist) ~= "table" then
        hist = { intraday = {}, daily = {}, lastScan = 0 }
        market.history[itemID] = hist
    end
    if type(hist.intraday) ~= "table" then hist.intraday = {} end
    if type(hist.daily) ~= "table" then hist.daily = {} end

    if not hist.name then
        local name, _, quality, _, _, _, _, _, _, icon = NS.Compat.GetItemInfo(itemID)
        if name then
            hist.name = name
            hist.quality = quality
            hist.icon = icon
        end
    end
    if market.watchlist[itemID] then
        self:RefreshItemMetadata(itemID, market.watchlist[itemID])
    end

    local intraday = hist.intraday
    local last = intraday[#intraday]

    if last and math.abs(now - last[1]) < INTRADAY_MERGE_WINDOW then
        last[1] = now
        last[2] = minP
        last[3] = avgP
        last[4] = math.max(last[4], maxP)
        last[5] = qty
    else
        table.insert(intraday, { now, minP, avgP, maxP, qty })
    end

    hist.lastScan = now

    if type(orderBook) == "table" and orderBook.wallQty then
        hist.orderBook = {
            wallQty   = orderBook.wallQty or 0,
            wallCost  = orderBook.wallCost or 0,
            nextPrice = orderBook.nextPrice or 0,
            tiers     = orderBook.tiers,
            updatedAt = now,
        }
    end

    if #intraday > 0 and intraday[1][1] < (now - INTRADAY_RETENTION_SECONDS) then
        self:CompactItemHistory(hist, now)
    end

    if not silent then
        NS:FireCallback("HISTORY_UPDATED", itemID, isPassive)
    end
    return true
end
