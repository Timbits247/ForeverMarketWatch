-- Arbitrage.lua
-- Built-in Classic / WoW: Forever crafting recipes (Alchemy, Smelting, Enchanting,
-- Tailoring, Leatherworking, Cooking), live post-5%-AH-cut arbitrage calculation,
-- per-reagent mini-chart data, and historical Craft Cost series builder for main chart overlays.

local _, NS = ...

local Arbitrage = {}
NS.Arbitrage = Arbitrage

-- Curated Classic / WoW: Forever recipes backed by live Blizzard API commodity data
Arbitrage.RECIPES = {
    -- Smelting (Mining)
    {
        name = "Copper Bar",
        profession = "Mining",
        productID = 2840, productQty = 1,
        reagents = { { 2770, 1 } }, -- 1x Copper Ore
    },
    {
        name = "Tin Bar",
        profession = "Mining",
        productID = 3576, productQty = 1,
        reagents = { { 2771, 1 } }, -- 1x Tin Ore
    },
    {
        name = "Bronze Bar (x2)",
        profession = "Mining",
        productID = 2841, productQty = 2,
        reagents = { { 2840, 1 }, { 3576, 1 } }, -- 1x Copper Bar + 1x Tin Bar
    },
    {
        name = "Silver Bar",
        profession = "Mining",
        productID = 2842, productQty = 1,
        reagents = { { 2775, 1 } }, -- 1x Silver Ore
    },
    {
        name = "Iron Bar",
        profession = "Mining",
        productID = 3575, productQty = 1,
        reagents = { { 2772, 1 } }, -- 1x Iron Ore
    },
    {
        name = "Gold Bar",
        profession = "Mining",
        productID = 3577, productQty = 1,
        reagents = { { 2776, 1 } }, -- 1x Gold Ore
    },
    {
        name = "Mithril Bar",
        profession = "Mining",
        productID = 3860, productQty = 1,
        reagents = { { 3858, 1 } }, -- 1x Mithril Ore
    },
    {
        name = "Truesilver Bar",
        profession = "Mining",
        productID = 6037, productQty = 1,
        reagents = { { 7911, 1 } }, -- 1x Truesilver Ore
    },
    {
        name = "Thorium Bar",
        profession = "Mining",
        productID = 12359, productQty = 1,
        reagents = { { 10620, 1 } }, -- 1x Thorium Ore
    },
    {
        name = "Dark Iron Bar",
        profession = "Mining",
        productID = 11371, productQty = 1,
        reagents = { { 11370, 8 } }, -- 8x Dark Iron Ore
    },

    -- Enchanting / Tailoring / Leatherworking
    {
        name = "Enchanted Thorium Bar",
        profession = "Enchanting",
        productID = 12655, productQty = 1,
        reagents = { { 12359, 1 }, { 11176, 3 } }, -- 1x Thorium Bar + 3x Dream Dust
    },
    {
        name = "Enchanted Leather",
        profession = "Enchanting",
        productID = 12810, productQty = 1,
        reagents = { { 8170, 1 }, { 16202, 1 } }, -- 1x Rugged Leather + 1x Lesser Eternal Essence
    },
    {
        name = "Cured Rugged Hide",
        profession = "Skinning",
        productID = 15407, productQty = 1,
        reagents = { { 8171, 1 }, { 15409, 1 } }, -- 1x Rugged Hide + 1x Refined Deeprock Salt
    },
    {
        name = "Mooncloth (CD)",
        profession = "Tailoring",
        productID = 14342, productQty = 1,
        reagents = { { 14256, 2 } }, -- 2x Felcloth
    },

    -- Alchemy Transmutes, Oils, Potions, Elixirs & Flasks
    {
        name = "Arcanite Bar (CD)",
        profession = "Alchemy",
        productID = 12360, productQty = 1,
        reagents = { { 12359, 1 }, { 12363, 1 } }, -- 1x Thorium Bar + 1x Arcane Crystal
    },
    {
        name = "Blackmouth Oil",
        profession = "Alchemy",
        productID = 6370, productQty = 1,
        reagents = { { 6358, 2 } }, -- 2x Oily Blackmouth
    },
    {
        name = "Fire Oil",
        profession = "Alchemy",
        productID = 6371, productQty = 1,
        reagents = { { 6359, 2 } }, -- 2x Firefin Snapper
    },
    {
        name = "Stonescale Oil",
        profession = "Alchemy",
        productID = 13423, productQty = 1,
        reagents = { { 13422, 1 } }, -- 1x Stonescale Eel
    },
    {
        name = "Shadow Oil",
        profession = "Alchemy",
        productID = 3824, productQty = 1,
        reagents = { { 3818, 4 }, { 3369, 4 } }, -- 4x Fadeleaf + 4x Grave Moss
    },
    {
        name = "Swiftness Potion",
        profession = "Alchemy",
        productID = 2459, productQty = 1,
        reagents = { { 2452, 1 }, { 2450, 1 } }, -- 1x Swiftthistle + 1x Briarthorn
    },
    {
        name = "Free Action Potion",
        profession = "Alchemy",
        productID = 5634, productQty = 1,
        reagents = { { 6370, 2 }, { 3820, 1 } }, -- 2x Blackmouth Oil + 1x Stranglekelp
    },
    {
        name = "Limited Invulnerability Potion",
        profession = "Alchemy",
        productID = 3387, productQty = 1,
        reagents = { { 8839, 2 }, { 8845, 1 } }, -- 2x Blindweed + 1x Ghost Mushroom
    },
    {
        name = "Major Healing Potion",
        profession = "Alchemy",
        productID = 13446, productQty = 1,
        reagents = { { 13464, 2 }, { 13465, 1 } }, -- 2x Golden Sansam + 1x Mountain Silversage
    },
    {
        name = "Major Mana Potion",
        profession = "Alchemy",
        productID = 13444, productQty = 1,
        reagents = { { 13463, 3 }, { 13467, 2 } }, -- 3x Dreamfoil + 2x Icecap
    },
    {
        name = "Elixir of the Mongoose",
        profession = "Alchemy",
        productID = 13452, productQty = 1,
        reagents = { { 13465, 2 }, { 13466, 2 } }, -- 2x Mountain Silversage + 2x Plaguebloom
    },
    {
        name = "Greater Arcane Elixir",
        profession = "Alchemy",
        productID = 13454, productQty = 1,
        reagents = { { 13463, 3 }, { 13465, 1 } }, -- 3x Dreamfoil + 1x Mountain Silversage
    },
    {
        name = "Elixir of Giants",
        profession = "Alchemy",
        productID = 9206, productQty = 1,
        reagents = { { 8838, 1 }, { 8846, 1 } }, -- 1x Sungrass + 1x Gromsblood
    },
    {
        name = "Greater Fire Protection Potion",
        profession = "Alchemy",
        productID = 13457, productQty = 1,
        reagents = { { 7068, 1 }, { 13463, 1 } }, -- 1x Elemental Fire + 1x Dreamfoil
    },
    {
        name = "Greater Nature Protection Potion",
        profession = "Alchemy",
        productID = 13458, productQty = 1,
        reagents = { { 7067, 1 }, { 13463, 1 } }, -- 1x Elemental Earth + 1x Dreamfoil
    },
    {
        name = "Greater Shadow Protection Potion",
        profession = "Alchemy",
        productID = 13459, productQty = 1,
        reagents = { { 3824, 1 }, { 13463, 1 } }, -- 1x Shadow Oil + 1x Dreamfoil
    },
    {
        name = "Greater Frost Protection Potion",
        profession = "Alchemy",
        productID = 13460, productQty = 1,
        reagents = { { 7070, 1 }, { 13463, 1 } }, -- 1x Elemental Water + 1x Dreamfoil
    },
    {
        name = "Flask of the Titans",
        profession = "Alchemy",
        productID = 13510, productQty = 1,
        reagents = { { 8846, 30 }, { 13423, 10 }, { 13468, 1 } }, -- 30x Gromsblood + 10x Stonescale Oil + 1x Black Lotus
    },
    {
        name = "Flask of Supreme Power",
        profession = "Alchemy",
        productID = 13512, productQty = 1,
        reagents = { { 13463, 30 }, { 13465, 10 }, { 13468, 1 } }, -- 30x Dreamfoil + 10x Mountain Silversage + 1x Black Lotus
    },
    {
        name = "Flask of Distilled Wisdom",
        profession = "Alchemy",
        productID = 13511, productQty = 1,
        reagents = { { 13463, 30 }, { 13467, 10 }, { 13468, 1 } }, -- 30x Dreamfoil + 10x Icecap + 1x Black Lotus
    },

    -- Cooking
    {
        name = "Savory Deviate Delight",
        profession = "Cooking",
        productID = 6657, productQty = 1,
        reagents = { { 6522, 1 } }, -- 1x Deviate Fish
    },
    {
        name = "Nightfin Soup",
        profession = "Cooking",
        productID = 13931, productQty = 1,
        reagents = { { 13759, 1 } }, -- 1x Raw Nightfin Snapper
    },
    {
        name = "Smoked Desert Dumplings",
        profession = "Cooking",
        productID = 20452, productQty = 1,
        reagents = { { 20424, 1 } }, -- 1x Sandworm Meat
    },
}

-- Fast lookup by product itemID
Arbitrage.BY_PRODUCT = {}
for i = 1, #Arbitrage.RECIPES do
    local rec = Arbitrage.RECIPES[i]
    Arbitrage.BY_PRODUCT[rec.productID] = rec
end

function Arbitrage.GetRecipeForProduct(productID)
    return productID and Arbitrage.BY_PRODUCT[productID] or nil
end

local function GetLatestMinPrice(itemID)
    local hist = NS.DB:GetItemHistory(itemID)
    local pt = NS.Analytics.GetLatestPoint(hist)
    return pt and pt.min or nil, hist
end

local function GetItemMeta(itemID)
    local watch = NS.DB:GetWatchItem(itemID)
    if watch then
        return watch.name, watch.icon or 134400, watch.quality or 1
    end
    local cat = NS.Catalog and NS.Catalog.BY_ID and NS.Catalog.BY_ID[itemID]
    local liveName, _, liveQual, _, _, _, _, _, _, liveIcon = NS.Compat.GetItemInfo(itemID)
    if not liveName then
        NS.Compat.RequestLoadItemDataByID(itemID)
    end
    return liveName or (cat and cat[2]) or ("Item #" .. tostring(itemID)),
        liveIcon or NS.Compat.GetItemIconByID(itemID) or 134400,
        (liveQual ~= nil) and liveQual or ((cat and cat[4]) or 1)
end

-- Detailed evaluation of a single crafted item including every reagent's live price & sparkline series
function Arbitrage.EvaluateProduct(productID, timeframe, nowTs)
    local rec = Arbitrage.GetRecipeForProduct(productID)
    if not rec then return nil end

    local tf = timeframe or "1D"
    local cutRate = NS.Analytics.GetAHCutRate()
    local prodUnit, prodHist = GetLatestMinPrice(rec.productID)
    local prodName, prodIcon, prodQual = GetItemMeta(rec.productID)

    local reagentsOut = {}
    local craftCost = 0
    local complete = true

    for i = 1, #rec.reagents do
        local rID, rQty = rec.reagents[i][1], rec.reagents[i][2]
        local rPrice, rHist = GetLatestMinPrice(rID)
        local rName, rIcon, rQual = GetItemMeta(rID)
        local lineCost = (rPrice and rPrice > 0) and (rPrice * rQty) or nil

        if lineCost then
            craftCost = craftCost + lineCost
        else
            complete = false
        end

        local rSeries = rHist and NS.Analytics.BuildSeries(rHist, tf, nowTs) or {}
        local rDayCtx = rHist and NS.Analytics.GetDayContext(rHist, nowTs) or nil

        table.insert(reagentsOut, {
            itemID    = rID,
            name      = rName,
            icon      = rIcon,
            quality   = rQual,
            qty       = rQty,
            unitPrice = rPrice,
            lineCost  = lineCost,
            hist      = rHist,
            series    = rSeries,
            dayCtx    = rDayCtx,
        })
    end

    local prodQty = rec.productQty or 1
    local unitCraftCost = (complete and craftCost > 0) and math.floor((craftCost / prodQty) + 0.5) or nil
    local grossSale = (prodUnit and prodUnit > 0) and (prodUnit * prodQty) or nil
    local netSale = grossSale and math.floor(grossSale * (1 - cutRate) + 0.5) or nil
    local netProfit = (complete and netSale and craftCost > 0) and (netSale - craftCost) or nil
    local marginPct = (netProfit and craftCost > 0) and ((netProfit / craftCost) * 100) or nil

    return {
        recipe        = rec,
        name          = prodName or rec.name,
        profession    = rec.profession,
        productID     = rec.productID,
        productQty    = prodQty,
        icon          = prodIcon,
        quality       = prodQual,
        productPrice  = prodUnit,
        productSeries = prodHist and NS.Analytics.BuildSeries(prodHist, tf, nowTs) or {},
        productDayCtx = prodHist and NS.Analytics.GetDayContext(prodHist, nowTs) or nil,
        complete      = complete,
        craftCost     = complete and craftCost or nil,
        unitCraftCost = unitCraftCost,
        grossSale     = grossSale,
        netSale       = netSale,
        netProfit     = netProfit,
        marginPct     = marginPct,
        reagents      = reagentsOut,
    }
end

-- Builds a historical per-unit Craft Cost series aligned 1-to-1 with productSeries timestamps
-- so Chart.lua can overlay the purple 'Mat Cost' line directly onto the product's price chart.
function Arbitrage.BuildCraftCostSeries(productID, productSeries, timeframe, nowTs)
    local rec = Arbitrage.GetRecipeForProduct(productID)
    if not rec or not productSeries or #productSeries == 0 then
        return nil
    end

    local reagentSeriesList = {}
    for r = 1, #rec.reagents do
        local rID, rQty = rec.reagents[r][1], rec.reagents[r][2]
        local rHist = NS.DB:GetItemHistory(rID)
        local rSeries = rHist and NS.Analytics.BuildSeries(rHist, timeframe or "1D", nowTs) or {}
        if #rSeries == 0 then
            -- Fall back to latest known point if reagent has no points inside the narrow window
            local latest = NS.Analytics.GetLatestPoint(rHist)
            if latest and latest.min and latest.min > 0 then
                rSeries = { { ts = latest.ts or 0, min = latest.min } }
            else
                return nil -- Missing price data for at least one reagent
            end
        end
        table.insert(reagentSeriesList, { qty = rQty, series = rSeries })
    end

    local function PriceAtTimestamp(rSeries, targetTs)
        local best = rSeries[1].min
        local bestDiff = math.abs(rSeries[1].ts - targetTs)
        for j = 2, #rSeries do
            local diff = math.abs(rSeries[j].ts - targetTs)
            if diff <= bestDiff then
                bestDiff = diff
                best = rSeries[j].min
            elseif rSeries[j].ts > targetTs then
                break
            end
        end
        return best
    end

    local prodQty = rec.productQty or 1
    local costSeries = {}
    for i = 1, #productSeries do
        local ts = productSeries[i].ts
        local totalCost = 0
        for r = 1, #reagentSeriesList do
            local item = reagentSeriesList[r]
            totalCost = totalCost + (PriceAtTimestamp(item.series, ts) * item.qty)
        end
        costSeries[i] = math.floor((totalCost / prodQty) + 0.5)
    end

    return costSeries
end

function Arbitrage.EvaluateAll()
    local cutRate = NS.Analytics.GetAHCutRate()
    local results = {}

    for i = 1, #Arbitrage.RECIPES do
        local rec = Arbitrage.RECIPES[i]
        local prodUnit = GetLatestMinPrice(rec.productID)
        if prodUnit and prodUnit > 0 then
            local craftCost = 0
            local complete = true
            for r = 1, #rec.reagents do
                local rID, rQty = rec.reagents[r][1], rec.reagents[r][2]
                local rPrice = GetLatestMinPrice(rID)
                if not rPrice or rPrice <= 0 then
                    complete = false
                    break
                end
                craftCost = craftCost + (rPrice * rQty)
            end

            if complete and craftCost > 0 then
                local grossSale = prodUnit * (rec.productQty or 1)
                local netSale = math.floor(grossSale * (1 - cutRate) + 0.5)
                local netProfit = netSale - craftCost
                local marginPct = (netProfit / craftCost) * 100
                local _, icon, quality = GetItemMeta(rec.productID)

                table.insert(results, {
                    name       = rec.name,
                    profession = rec.profession,
                    productID  = rec.productID,
                    productQty = rec.productQty or 1,
                    icon       = icon,
                    quality    = quality,
                    craftCost  = craftCost,
                    grossSale  = grossSale,
                    netSale    = netSale,
                    netProfit  = netProfit,
                    marginPct  = marginPct,
                })
            end
        end
    end

    table.sort(results, function(a, b)
        if a.netProfit ~= b.netProfit then
            return a.netProfit > b.netProfit
        end
        return a.name < b.name
    end)

    return results
end
