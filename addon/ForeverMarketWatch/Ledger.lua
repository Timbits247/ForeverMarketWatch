-- Ledger.lua
-- Automatic Auction House Purchase & Mailbox Sale Accounting Engine.
-- Zero manual entry required:
--   * Hooks C_AuctionHouse commodity purchases & item buyouts (works with Blizzard AH,
--     Auctionator, and ForeverMarketWatch Quick Buy — 100% taint-safe via hooksecurefunc).
--   * Hooks Mailbox collection (TakeInboxMoney / TakeInboxItem / AutoLootMailItem) to
--     capture exact Blizzard-verified AH sales (gross, 5%/15% AH cut, net proceeds, realized
--     profit vs Inventory avg cost basis) plus offline bid wins with exact deduplication.

local _, NS = ...

local Ledger = {}
NS.Ledger = Ledger

local initialized = false
local eventFrame = nil

-- Active purchase tracking state
local pendingCommodity = nil
local pendingBid = nil
local auctionCache = {}
local auctionCacheCount = 0

-- Mailbox invoice snapshot (rebuilt cleanly on MAIL_SHOW / MAIL_INBOX_UPDATE)
local inboxSnapshot = {}
-- Pending mailbox sale payouts awaiting actual PLAYER_MONEY gold-receipt confirmation.
-- Prevents duplicate SELL logging when Blizzard "Open All" or rapid clicks retry a mail
-- before MAIL_INBOX_UPDATE removes it from the client inbox.
local pendingMailSales = {}
local lastKnownMoney = 0

local function IsTrackingEnabled()
    if NS.DB:IsDemoMode() then return false end
    local s = NS.DB:GetSettings()
    return s and s.autoTrackLedger ~= false
end

local function ShouldAnnounce()
    local s = NS.DB:GetSettings()
    return s and s.announceAutoLedger ~= false
end

local function SafeGetMoney()
    return (GetMoney and GetMoney()) or 0
end

local function AnnounceBuy(rec)
    if not ShouldAnnounce() or not rec then return end
    NS.Print(string.format(
        "|cFF42A8FA[BUY]|r %dx %s @ %s (%s total)",
        rec.qty or 1,
        rec.name or "Item",
        NS.FormatMoney(rec.unitPrice or 0, true),
        NS.FormatMoney(rec.netTotal or rec.gross or 0, true)
    ))
end

local function AnnounceSale(rec)
    if not ShouldAnnounce() or not rec then return end
    if rec.profit ~= nil then
        local clr = (rec.profit >= 0) and "|cFF38D972+" or "|cFFF55954"
        NS.Print(string.format(
            "|cFF38D972[SELL]|r %dx %s for %s net (%s%s|r profit)",
            rec.qty or 1,
            rec.name or "Item",
            NS.FormatMoney(rec.netTotal or 0, true),
            clr,
            NS.FormatMoney(rec.profit, true)
        ))
    else
        NS.Print(string.format(
            "|cFF38D972[SELL]|r %dx %s for %s net (no tracked cost basis)",
            rec.qty or 1,
            rec.name or "Item",
            NS.FormatMoney(rec.netTotal or 0, true)
        ))
    end
end

--------------------------------------------------------------------------------
-- Commodity Purchase Finalization
--------------------------------------------------------------------------------

local function CommitCommodityPurchase(p, totalCopper)
    if not p or not p.itemID or not p.qty or p.qty <= 0 then return end
    if not totalCopper or totalCopper <= 0 then return end
    if not IsTrackingEnabled() then return end

    local ok, rec = NS.DB:RecordLedgerBuy(p.itemID, p.qty, totalCopper, {
        source = "AH",
    })
    if ok and rec then
        NS.DB:AddPendingMailMatch(p.itemID, p.qty, totalCopper, rec.ts)
        AnnounceBuy(rec)
    end
end

local function OnCommodityPurchaseSucceeded()
    local p = pendingCommodity
    pendingCommodity = nil
    if not p or not IsTrackingEnabled() then return end

    local now = (time and time()) or 0
    if p.ts and (now - p.ts) > 30 then
        return -- Stale pending quote
    end

    local total = p.totalPrice
    if (not total or total <= 0) and p.unitPrice and p.unitPrice > 0 and p.qty and p.qty > 0 then
        total = p.unitPrice * p.qty
    end
    if (not total or total <= 0) and p.moneyBefore then
        local spent = p.moneyBefore - SafeGetMoney()
        if spent > 0 then
            total = spent
        end
    end

    if total and total > 0 then
        CommitCommodityPurchase(p, total)
    elseif p.moneyBefore and C_Timer and C_Timer.After then
        -- Wait one tick for PLAYER_MONEY to reflect exact gold deducted
        local saved = p
        C_Timer.After(0.2, function()
            local spent = saved.moneyBefore - SafeGetMoney()
            if spent > 0 then
                CommitCommodityPurchase(saved, spent)
            end
        end)
    end
end

--------------------------------------------------------------------------------
-- Non-Commodity Auction Cache & Instant Buyout Confirmation
--------------------------------------------------------------------------------

local function CacheItemSearchResults(itemKey)
    if not C_AuctionHouse or not C_AuctionHouse.GetNumItemSearchResults or not C_AuctionHouse.GetItemSearchResultInfo then
        return
    end
    if type(itemKey) ~= "table" or not itemKey.itemID then return end

    local num = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
    if num <= 0 or num > 150 then return end

    if auctionCacheCount > 600 then
        auctionCache = {}
        auctionCacheCount = 0
    end

    for i = 1, num do
        local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if info and info.auctionID then
            local id = (info.itemKey and info.itemKey.itemID) or itemKey.itemID
            if id and id > 0 then
                if not auctionCache[info.auctionID] then
                    auctionCacheCount = auctionCacheCount + 1
                end
                auctionCache[info.auctionID] = {
                    itemID = id,
                    qty    = math.max(1, info.quantity or 1),
                    buyout = info.buyoutAmount or 0,
                    bid    = info.bidAmount or info.minBid or 0,
                }
            end
        end
    end
end

local function CheckPendingBidMoney()
    local b = pendingBid
    if not b then return end

    local now = (time and time()) or 0
    if (now - (b.ts or 0)) > 6 then
        pendingBid = nil
        return
    end

    local spent = (b.moneyBefore or 0) - SafeGetMoney()
    if spent >= b.totalPrice and b.totalPrice > 0 then
        pendingBid = nil
        if not IsTrackingEnabled() then return end
        local ok, rec = NS.DB:RecordLedgerBuy(b.itemID, b.qty, b.totalPrice, {
            source = "AH",
        })
        if ok and rec then
            NS.DB:AddPendingMailMatch(b.itemID, b.qty, b.totalPrice, rec.ts)
            AnnounceBuy(rec)
        end
    end
end

--------------------------------------------------------------------------------
-- Mailbox Snapshot & Exact Blizzard Invoice Capture (Sales + Offline Wins)
--------------------------------------------------------------------------------

local function ParseQuantityFromSubject(subject)
    if type(subject) ~= "string" then return 1 end
    local q = subject:match("%(x?(%d+)%)")
    local n = tonumber(q)
    if n and n > 0 then
        return n
    end
    return 1
end

local function RefreshInboxSnapshot()
    inboxSnapshot = {}
    if not GetInboxNumItems or not GetInboxHeaderInfo or not GetInboxInvoiceInfo then
        return
    end

    local maxSlots = ATTACHMENTS_MAX_RECEIVE or 12
    local numItems = GetInboxNumItems() or 0
    for i = 1, numItems do
        local invoiceType, itemName, playerName, bid, buyout, deposit, consignment, _, _, _, invCount, commerceAuction = GetInboxInvoiceInfo(i)
        if invoiceType == "seller" or invoiceType == "buyer" then
            local _, _, sender, subject, money, _, _, hasItem = GetInboxHeaderInfo(i)
            local firstLink = nil
            local attachName, attachItemID, attachIcon = nil, nil, nil
            local totalAttachCount = 0
            local attachSlots = 0

            for slot = 1, maxSlots do
                local sLink = (GetInboxItemLink and GetInboxItemLink(i, slot)) or nil
                if sLink and not firstLink then
                    firstLink = sLink
                end
                if GetInboxItem then
                    local a1, a2, a3, a4 = GetInboxItem(i, slot)
                    if a1 then
                        attachSlots = attachSlots + 1
                        if not attachName then attachName = a1 end
                        local slotCount = 1
                        -- WoW Modern/Forever returns (name, itemID, texture, count, ...); legacy returns (name, texture, count, ...)
                        if type(a2) == "number" and type(a4) == "number" then
                            if not attachItemID then attachItemID = a2 end
                            if not attachIcon then attachIcon = a3 end
                            slotCount = a4
                        else
                            if not attachIcon then attachIcon = a2 end
                            slotCount = tonumber(a3) or 1
                        end
                        totalAttachCount = totalAttachCount + math.max(1, slotCount)
                    end
                end
            end

            local itemID = (firstLink and NS.Compat.ParseItemID(firstLink)) or attachItemID or nil
            local resolvedName = (itemName and itemName ~= "" and itemName) or attachName or ""
            local qty = (totalAttachCount > 0 and totalAttachCount)
                or (tonumber(invCount) and tonumber(invCount) > 0 and tonumber(invCount))
                or ParseQuantityFromSubject(subject)

            local maxStack = (itemID and C_Item and C_Item.GetItemMaxStackSizeByID and C_Item.GetItemMaxStackSizeByID(itemID)) or 1
            local isCommodityMail = (commerceAuction == true) or (attachSlots > 1) or (maxStack > 1)

            inboxSnapshot[i] = {
                invoiceType = invoiceType,
                isCommodity = isCommodityMail,
                attachSlots = attachSlots,
                itemID      = itemID,
                itemName    = resolvedName,
                icon        = attachIcon,
                playerName  = playerName or "",
                sender      = sender or "",
                subject     = subject or "",
                bid         = tonumber(bid) or 0,
                buyout      = tonumber(buyout) or 0,
                deposit     = tonumber(deposit) or 0,
                consignment = tonumber(consignment) or 0,
                money       = tonumber(money) or 0,
                hasItem     = (hasItem and hasItem > 0) or (firstLink ~= nil) or (attachSlots > 0),
                count       = math.max(1, math.floor((qty or 1) + 0.5)),
                collected   = false,
            }
        end
    end
end

local function PruneStalePendingSales(now)
    for i = #pendingMailSales, 1, -1 do
        local p = pendingMailSales[i]
        if not p or (now - (p.ts or 0)) > 8 then
            table.remove(pendingMailSales, i)
        end
    end
end

local function FindExactSubsetIndices(list, target)
    local n = math.min(#list, 10)
    if n < 2 or target <= 0 then return nil end

    local found = nil
    local function Search(idx, rem, chosen)
        if rem == 0 then
            found = {}
            for i = 1, #chosen do found[i] = chosen[i] end
            return true
        end
        if idx > n or rem < 0 then return false end
        local val = list[idx].money or 0
        if val > 0 and val <= rem then
            chosen[#chosen + 1] = idx
            if Search(idx + 1, rem - val, chosen) then return true end
            chosen[#chosen] = nil
        end
        return Search(idx + 1, rem, chosen)
    end

    Search(1, target, {})
    return found
end

local function CommitPendingMailSale(sale)
    if not sale or not IsTrackingEnabled() then return end
    local itemID = sale.itemID or NS.DB:ResolveItemIDByName(sale.itemName)
    local ok, rec = NS.DB:RecordLedgerSale(itemID, sale.count, sale.gross, sale.ahCut, {
        name         = sale.itemName,
        counterparty = sale.playerName,
        source       = "MAIL",
    })
    if ok and rec then
        AnnounceSale(rec)
    end
end

local function CaptureCurrentGold(silent)
    if NS.DB and NS.DB.RecordCharacterGold and not NS.DB:IsDemoMode() then
        local cur = SafeGetMoney()
        NS.DB:RecordCharacterGold(cur, nil, nil, silent)
    end
end

local function OnPlayerMoneyChanged()
    local current = SafeGetMoney()
    local delta = current - (lastKnownMoney or current)
    lastKnownMoney = current
    CaptureCurrentGold(false)

    if pendingBid then
        CheckPendingBidMoney()
    end

    if delta > 0 and #pendingMailSales > 0 then
        local now = (time and time()) or 0
        PruneStalePendingSales(now)
        if #pendingMailSales == 0 then return end

        -- 1. Exact single-mail match (handles normal & Open-All sequential pickups)
        for i = 1, #pendingMailSales do
            if pendingMailSales[i].money == delta then
                local sale = table.remove(pendingMailSales, i)
                CommitPendingMailSale(sale)
                return
            end
        end

        -- 2. Batched server tick: multiple sales credited in one PLAYER_MONEY event
        local subset = FindExactSubsetIndices(pendingMailSales, delta)
        if subset and #subset > 0 then
            local toCommit = {}
            for i = #subset, 1, -1 do
                local sale = table.remove(pendingMailSales, subset[i])
                table.insert(toCommit, 1, sale)
            end
            for i = 1, #toCommit do
                CommitPendingMailSale(toCommit[i])
            end
        end
    end
end

local function ProcessCollectedMail(mailIndex, mode)
    if not IsTrackingEnabled() then return end
    local snap = inboxSnapshot[mailIndex]
    if not snap or snap.collected then return end

    if snap.invoiceType == "seller" and (mode == "MONEY" or mode == "AUTO") then
        if not snap.money or snap.money <= 0 then return end
        snap.collected = true

        -- In WoW: Forever (modern C_AuctionHouse), GetInboxInvoiceInfo can set `buyout = 1` as a flag
        -- while `money` (from GetInboxHeaderInfo) ALWAYS equals: grossSale - consignment + deposit.
        local ahCut = snap.consignment or 0
        local deposit = snap.deposit or 0
        local netFromMail = math.max(0, snap.money - deposit)
        local grossFromMail = netFromMail + ahCut

        local gross = grossFromMail
        if gross <= 0 then
            gross = math.max(snap.bid or 0, snap.buyout or 0)
        elseif snap.bid and snap.bid > ahCut and math.abs(snap.bid - grossFromMail) <= math.max(5, snap.count) then
            gross = snap.bid
        end
        if gross <= 0 then return end

        -- Queue for PLAYER_MONEY confirmation instead of committing immediately.
        -- If Blizzard "Open All" retries this exact mail index before the server deletes it,
        -- the duplicate signature is coalesced AND no second PLAYER_MONEY gain ever arrives.
        local now = (time and time()) or 0
        PruneStalePendingSales(now)
        local sig = string.format("%d|%d|%s|%d|%s", mailIndex, snap.money, snap.itemName or "", snap.count or 1, snap.playerName or "")
        for i = 1, #pendingMailSales do
            if pendingMailSales[i].sig == sig then
                pendingMailSales[i].ts = now
                return
            end
        end

        table.insert(pendingMailSales, {
            mailIndex  = mailIndex,
            sig        = sig,
            money      = snap.money,
            gross      = gross,
            ahCut      = ahCut,
            itemID     = snap.itemID,
            itemName   = snap.itemName,
            count      = snap.count,
            playerName = snap.playerName,
            ts         = now,
        })

    elseif snap.invoiceType == "buyer" and (mode == "ITEM" or mode == "AUTO") then
        if not snap.hasItem then return end
        snap.collected = true

        local itemID = snap.itemID or NS.DB:ResolveItemIDByName(snap.itemName)
        -- Prefer `bid` / max(bid, buyout) so a `buyout = 1` flag never overrides the real purchase price
        local paid = math.max(snap.bid or 0, snap.buyout or 0)

        -- Commodities on WoW: Forever are 100% instant-purchase (no bidding) and are ALWAYS
        -- captured live at the AH via COMMODITY_PURCHASE_SUCCEEDED with exact qty & copper.
        -- Never re-log commodity buyer mails from the mailbox (avoids multi-stack split inflation!).
        if snap.isCommodity then
            if itemID then
                NS.DB:ConsumePendingMailMatch(itemID, snap.count, paid)
            end
            return
        end

        if paid <= 0 then return end

        if itemID then
            local fullyMatched = NS.DB:ConsumePendingMailMatch(itemID, snap.count, paid)
            if fullyMatched then
                -- Non-commodity buyout already auto-logged live at the AH; skip duplicate
                return
            end
        end

        -- Non-commodity offline bid win (e.g. BoE gear/weapon/recipe won while offline)
        local ok, rec = NS.DB:RecordLedgerBuy(itemID, snap.count, paid, {
            name         = snap.itemName,
            icon         = snap.icon,
            counterparty = snap.playerName,
            source       = "MAIL",
        })
        if ok and rec then
            AnnounceBuy(rec)
        end
    end
end

--------------------------------------------------------------------------------
-- Initialization (100% Taint-Safe Hooks & Events)
--------------------------------------------------------------------------------

function Ledger:Init()
    if initialized then return end
    initialized = true

    -- 1. Hook C_AuctionHouse purchase functions (works for Blizzard AH, Auctionator, Quick Buy)
    if C_AuctionHouse and hooksecurefunc then
        if C_AuctionHouse.StartCommoditiesPurchase then
            hooksecurefunc(C_AuctionHouse, "StartCommoditiesPurchase", function(itemID, quantity, maybeUnitPrice)
                if not IsTrackingEnabled() then return end
                pendingCommodity = {
                    itemID      = tonumber(itemID),
                    qty         = tonumber(quantity) or 0,
                    unitPrice   = tonumber(maybeUnitPrice),
                    totalPrice  = nil,
                    confirmed   = false,
                    moneyBefore = nil,
                    ts          = (time and time()) or 0,
                }
            end)
        end

        if C_AuctionHouse.ConfirmCommoditiesPurchase then
            hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(itemID, quantity, maybeTotalPrice)
                if not IsTrackingEnabled() then return end
                local idNum = tonumber(itemID)
                local qNum = tonumber(quantity) or 0
                if not pendingCommodity or pendingCommodity.itemID ~= idNum then
                    pendingCommodity = {
                        itemID     = idNum,
                        qty        = qNum,
                        unitPrice  = nil,
                        totalPrice = nil,
                    }
                end
                pendingCommodity.qty = (qNum > 0) and qNum or pendingCommodity.qty
                pendingCommodity.confirmed = true
                pendingCommodity.moneyBefore = SafeGetMoney()
                pendingCommodity.ts = (time and time()) or 0
                if tonumber(maybeTotalPrice) and tonumber(maybeTotalPrice) > 0 and not pendingCommodity.totalPrice then
                    pendingCommodity.totalPrice = tonumber(maybeTotalPrice)
                end
            end)
        end

        if C_AuctionHouse.PlaceBid then
            hooksecurefunc(C_AuctionHouse, "PlaceBid", function(auctionID, bidAmount)
                if not IsTrackingEnabled() then return end
                local info = auctionCache[auctionID]
                local amt = tonumber(bidAmount) or 0
                if info and info.buyout and info.buyout > 0 and amt >= info.buyout then
                    pendingBid = {
                        auctionID   = auctionID,
                        itemID      = info.itemID,
                        qty         = info.qty or 1,
                        totalPrice  = amt,
                        moneyBefore = SafeGetMoney(),
                        ts          = (time and time()) or 0,
                    }
                end
            end)
        end
    end

    -- 2. Hook Mailbox collection functions (works with Blizzard Open All, Shift-click, and mail addons)
    if hooksecurefunc then
        if TakeInboxMoney then
            hooksecurefunc("TakeInboxMoney", function(mailIndex)
                ProcessCollectedMail(mailIndex, "MONEY")
            end)
        end
        if TakeInboxItem then
            hooksecurefunc("TakeInboxItem", function(mailIndex)
                ProcessCollectedMail(mailIndex, "ITEM")
            end)
        end
        if AutoLootMailItem then
            hooksecurefunc("AutoLootMailItem", function(mailIndex)
                ProcessCollectedMail(mailIndex, "AUTO")
            end)
        end
    end

    -- 3. Event listener
    lastKnownMoney = SafeGetMoney()
    CaptureCurrentGold(true)
    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_LOGOUT")
    eventFrame:RegisterEvent("COMMODITY_PRICE_UPDATED")
    eventFrame:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
    eventFrame:RegisterEvent("COMMODITY_PURCHASE_FAILED")
    eventFrame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
    eventFrame:RegisterEvent("PLAYER_MONEY")
    eventFrame:RegisterEvent("MAIL_SHOW")
    eventFrame:RegisterEvent("MAIL_INBOX_UPDATE")
    eventFrame:RegisterEvent("MAIL_CLOSED")
    eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")

    eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
        if event == "PLAYER_ENTERING_WORLD" then
            lastKnownMoney = SafeGetMoney()
            CaptureCurrentGold(false)
        elseif event == "PLAYER_LOGOUT" then
            CaptureCurrentGold(true)
        elseif event == "COMMODITY_PRICE_UPDATED" then
            if pendingCommodity then
                local up = tonumber(arg1)
                local tp = tonumber(arg2)
                if up and up > 0 then pendingCommodity.unitPrice = up end
                if tp and tp > 0 then pendingCommodity.totalPrice = tp end
            end
        elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
            OnCommodityPurchaseSucceeded()
        elseif event == "COMMODITY_PURCHASE_FAILED" then
            pendingCommodity = nil
        elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
            if IsTrackingEnabled() then
                CacheItemSearchResults(arg1)
            end
        elseif event == "PLAYER_MONEY" then
            OnPlayerMoneyChanged()
        elseif event == "MAIL_SHOW" then
            lastKnownMoney = SafeGetMoney()
            CaptureCurrentGold(true)
            pendingMailSales = {}
            RefreshInboxSnapshot()
        elseif event == "MAIL_INBOX_UPDATE" then
            RefreshInboxSnapshot()
        elseif event == "MAIL_CLOSED" then
            inboxSnapshot = {}
            CaptureCurrentGold(false)
        elseif event == "AUCTION_HOUSE_CLOSED" then
            pendingCommodity = nil
            pendingBid = nil
            auctionCache = {}
            auctionCacheCount = 0
            CaptureCurrentGold(false)
        end
    end)
end
