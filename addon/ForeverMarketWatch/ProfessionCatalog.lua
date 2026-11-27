-- ProfessionCatalog.lua
-- Pre-populated catalog of verified Classic / WoW: Forever crafting materials
-- across all professions, plus offline + bag search helpers.

local _, NS = ...

local Catalog = {}
NS.Catalog = Catalog

Catalog.PROFESSION_GROUPS = {
    "Herbalism",
    "Mining",
    "Skinning",
    "Tailoring",
    "Enchanting",
    "Alchemy",
    "Blacksmithing & Eng",
    "Cooking & Fishing",
    "Flipping",
}

-- Verified Classic / WoW: Forever item IDs grouped by profession.
-- Format: { itemID, fallbackName, group, defaultQuality }
Catalog.ITEMS = {
    -- Herbalism
    { 2447,  "Peacebloom",          "Herbalism", 1 },
    { 765,   "Silverleaf",          "Herbalism", 1 },
    { 2449,  "Earthroot",           "Herbalism", 1 },
    { 785,   "Mageroyal",           "Herbalism", 1 },
    { 2450,  "Briarthorn",          "Herbalism", 1 },
    { 2452,  "Swiftthistle",        "Herbalism", 1 },
    { 3820,  "Stranglekelp",        "Herbalism", 1 },
    { 2453,  "Bruiseweed",          "Herbalism", 1 },
    { 3355,  "Wild Steelbloom",     "Herbalism", 1 },
    { 3369,  "Grave Moss",          "Herbalism", 1 },
    { 3356,  "Kingsblood",          "Herbalism", 1 },
    { 3357,  "Liferoot",            "Herbalism", 1 },
    { 3818,  "Fadeleaf",            "Herbalism", 1 },
    { 3821,  "Goldthorn",           "Herbalism", 1 },
    { 3358,  "Khadgar's Whisker",   "Herbalism", 1 },
    { 3819,  "Wintersbite",         "Herbalism", 1 },
    { 4625,  "Firebloom",           "Herbalism", 1 },
    { 8831,  "Purple Lotus",        "Herbalism", 1 },
    { 8836,  "Arthas' Tears",       "Herbalism", 1 },
    { 8838,  "Sungrass",            "Herbalism", 1 },
    { 8839,  "Blindweed",           "Herbalism", 1 },
    { 8845,  "Ghost Mushroom",      "Herbalism", 1 },
    { 8846,  "Gromsblood",          "Herbalism", 1 },
    { 13464, "Golden Sansam",       "Herbalism", 1 },
    { 13463, "Dreamfoil",           "Herbalism", 1 },
    { 13465, "Mountain Silversage", "Herbalism", 1 },
    { 13466, "Plaguebloom",         "Herbalism", 1 },
    { 13467, "Icecap",              "Herbalism", 1 },
    { 13468, "Black Lotus",         "Herbalism", 2 },

    -- Mining (Ores, Bars, Stones, Gems)
    { 2770,  "Copper Ore",          "Mining", 1 },
    { 2840,  "Copper Bar",          "Mining", 1 },
    { 2771,  "Tin Ore",             "Mining", 1 },
    { 3576,  "Tin Bar",             "Mining", 1 },
    { 2841,  "Bronze Bar",          "Mining", 1 },
    { 2775,  "Silver Ore",          "Mining", 2 },
    { 2842,  "Silver Bar",          "Mining", 2 },
    { 2772,  "Iron Ore",            "Mining", 1 },
    { 3575,  "Iron Bar",            "Mining", 1 },
    { 3859,  "Steel Bar",           "Mining", 1 },
    { 2776,  "Gold Ore",            "Mining", 2 },
    { 3577,  "Gold Bar",            "Mining", 2 },
    { 3858,  "Mithril Ore",         "Mining", 1 },
    { 3860,  "Mithril Bar",         "Mining", 1 },
    { 7911,  "Truesilver Ore",      "Mining", 2 },
    { 6037,  "Truesilver Bar",      "Mining", 2 },
    { 10620, "Thorium Ore",         "Mining", 1 },
    { 12359, "Thorium Bar",         "Mining", 1 },
    { 11370, "Dark Iron Ore",       "Mining", 1 },
    { 11371, "Dark Iron Bar",       "Mining", 1 },
    { 2835,  "Rough Stone",         "Mining", 1 },
    { 2836,  "Coarse Stone",        "Mining", 1 },
    { 2838,  "Heavy Stone",         "Mining", 1 },
    { 7912,  "Solid Stone",         "Mining", 1 },
    { 12365, "Dense Stone",         "Mining", 1 },
    { 12363, "Arcane Crystal",      "Mining", 2 },
    { 12361, "Blue Sapphire",       "Mining", 2 },
    { 12800, "Azerothian Diamond",  "Mining", 2 },
    { 12364, "Huge Emerald",        "Mining", 2 },
    { 12799, "Large Opal",          "Mining", 2 },
    { 7910,  "Star Ruby",           "Mining", 2 },

    -- Skinning & Leatherworking
    { 2934,  "Ruined Leather Scraps", "Skinning", 1 },
    { 2318,  "Light Leather",       "Skinning", 1 },
    { 783,   "Light Hide",          "Skinning", 1 },
    { 2319,  "Medium Leather",      "Skinning", 1 },
    { 4232,  "Medium Hide",         "Skinning", 1 },
    { 4234,  "Heavy Leather",       "Skinning", 1 },
    { 4235,  "Heavy Hide",          "Skinning", 1 },
    { 4304,  "Thick Leather",       "Skinning", 1 },
    { 8169,  "Thick Hide",          "Skinning", 1 },
    { 8170,  "Rugged Leather",      "Skinning", 1 },
    { 8171,  "Rugged Hide",         "Skinning", 1 },
    { 15409, "Refined Deeprock Salt","Skinning", 1 },
    { 15407, "Cured Rugged Hide",   "Skinning", 1 },
    { 15417, "Devilsaur Leather",   "Skinning", 2 },
    { 15416, "Black Dragonscale",   "Skinning", 2 },
    { 15415, "Blue Dragonscale",    "Skinning", 2 },
    { 17012, "Core Leather",        "Skinning", 3 },

    -- Tailoring & Cloth
    { 2589,  "Linen Cloth",         "Tailoring", 1 },
    { 2996,  "Bolt of Linen Cloth", "Tailoring", 1 },
    { 2592,  "Wool Cloth",          "Tailoring", 1 },
    { 2997,  "Bolt of Woolen Cloth","Tailoring", 1 },
    { 4306,  "Silk Cloth",          "Tailoring", 1 },
    { 4305,  "Bolt of Silk Cloth",  "Tailoring", 1 },
    { 4338,  "Mageweave Cloth",     "Tailoring", 1 },
    { 4339,  "Bolt of Mageweave",   "Tailoring", 1 },
    { 14047, "Runecloth",           "Tailoring", 1 },
    { 14048, "Bolt of Runecloth",   "Tailoring", 1 },
    { 14256, "Felcloth",            "Tailoring", 1 },
    { 14342, "Mooncloth",           "Tailoring", 1 },
    { 3182,  "Spider's Silk",       "Tailoring", 1 },
    { 4337,  "Thick Spider's Silk", "Tailoring", 1 },
    { 10285, "Shadow Silk",         "Tailoring", 1 },
    { 14227, "Ironweb Spider Silk", "Tailoring", 1 },

    -- Enchanting
    { 10940, "Strange Dust",           "Enchanting", 1 },
    { 11083, "Soul Dust",              "Enchanting", 1 },
    { 11137, "Vision Dust",            "Enchanting", 1 },
    { 11176, "Dream Dust",             "Enchanting", 1 },
    { 16204, "Illusion Dust",          "Enchanting", 1 },
    { 10938, "Lesser Magic Essence",   "Enchanting", 2 },
    { 10939, "Greater Magic Essence",  "Enchanting", 2 },
    { 10998, "Lesser Astral Essence",  "Enchanting", 2 },
    { 11038, "Greater Astral Essence", "Enchanting", 2 },
    { 11082, "Lesser Mystic Essence",  "Enchanting", 2 },
    { 11136, "Greater Mystic Essence", "Enchanting", 2 },
    { 11174, "Lesser Nether Essence",  "Enchanting", 2 },
    { 11175, "Greater Nether Essence", "Enchanting", 2 },
    { 16202, "Lesser Eternal Essence", "Enchanting", 2 },
    { 16203, "Greater Eternal Essence","Enchanting", 2 },
    { 10978, "Small Glimmering Shard", "Enchanting", 3 },
    { 11084, "Large Glimmering Shard", "Enchanting", 3 },
    { 11138, "Small Glowing Shard",    "Enchanting", 3 },
    { 11139, "Large Glowing Shard",    "Enchanting", 3 },
    { 11177, "Small Radiant Shard",    "Enchanting", 3 },
    { 11178, "Large Radiant Shard",    "Enchanting", 3 },
    { 14343, "Small Brilliant Shard",  "Enchanting", 3 },
    { 14344, "Large Brilliant Shard",  "Enchanting", 3 },
    { 20725, "Nexus Crystal",          "Enchanting", 4 },
    { 12655, "Enchanted Thorium Bar",  "Enchanting", 2 },
    { 12810, "Enchanted Leather",      "Enchanting", 1 },
    { 12811, "Righteous Orb",          "Enchanting", 2 },
    { 5498,  "Small Lustrous Pearl",   "Enchanting", 2 },
    { 5500,  "Iridescent Pearl",       "Enchanting", 2 },
    { 7971,  "Black Pearl",            "Enchanting", 2 },
    { 13926, "Golden Pearl",           "Enchanting", 2 },

    -- Alchemy & Consumables
    { 12360, "Arcanite Bar",                    "Alchemy", 2 },
    { 6370,  "Blackmouth Oil",                  "Alchemy", 1 },
    { 6371,  "Fire Oil",                        "Alchemy", 1 },
    { 13423, "Stonescale Oil",                  "Alchemy", 1 },
    { 3824,  "Shadow Oil",                      "Alchemy", 1 },
    { 2459,  "Swiftness Potion",                "Alchemy", 1 },
    { 5634,  "Free Action Potion",              "Alchemy", 1 },
    { 3387,  "Limited Invulnerability Potion",  "Alchemy", 1 },
    { 13446, "Major Healing Potion",            "Alchemy", 1 },
    { 13444, "Major Mana Potion",               "Alchemy", 1 },
    { 13452, "Elixir of the Mongoose",          "Alchemy", 1 },
    { 13454, "Greater Arcane Elixir",           "Alchemy", 1 },
    { 9206,  "Elixir of Giants",                "Alchemy", 1 },
    { 13457, "Greater Fire Protection Potion",  "Alchemy", 1 },
    { 13458, "Greater Nature Protection Potion","Alchemy", 1 },
    { 13459, "Greater Shadow Protection Potion","Alchemy", 1 },
    { 13460, "Greater Frost Protection Potion", "Alchemy", 1 },
    { 13510, "Flask of the Titans",             "Alchemy", 1 },
    { 13512, "Flask of Supreme Power",          "Alchemy", 1 },
    { 13511, "Flask of Distilled Wisdom",       "Alchemy", 1 },

    -- Blacksmithing, Engineering & Elementals
    { 7067,  "Elemental Earth",       "Blacksmithing & Eng", 1 },
    { 7068,  "Elemental Fire",        "Blacksmithing & Eng", 1 },
    { 7069,  "Elemental Air",         "Blacksmithing & Eng", 1 },
    { 7070,  "Elemental Water",       "Blacksmithing & Eng", 1 },
    { 7076,  "Essence of Earth",      "Blacksmithing & Eng", 2 },
    { 7078,  "Essence of Fire",       "Blacksmithing & Eng", 2 },
    { 7080,  "Essence of Water",      "Blacksmithing & Eng", 2 },
    { 7082,  "Essence of Air",        "Blacksmithing & Eng", 2 },
    { 12808, "Essence of Undeath",    "Blacksmithing & Eng", 2 },
    { 17010, "Fiery Core",            "Blacksmithing & Eng", 3 },
    { 17011, "Lava Core",             "Blacksmithing & Eng", 3 },
    { 2871,  "Heavy Sharpening Stone","Blacksmithing & Eng", 1 },
    { 7964,  "Solid Sharpening Stone","Blacksmithing & Eng", 1 },
    { 12404, "Dense Sharpening Stone","Blacksmithing & Eng", 1 },
    { 3241,  "Heavy Weightstone",     "Blacksmithing & Eng", 1 },
    { 7965,  "Solid Weightstone",     "Blacksmithing & Eng", 1 },
    { 12643, "Dense Weightstone",     "Blacksmithing & Eng", 1 },
    { 4377,  "Heavy Blasting Powder", "Blacksmithing & Eng", 1 },
    { 10505, "Solid Blasting Powder", "Blacksmithing & Eng", 1 },
    { 15992, "Dense Blasting Powder", "Blacksmithing & Eng", 1 },
    { 4394,  "Big Iron Bomb",         "Blacksmithing & Eng", 1 },
    { 10507, "Solid Dynamite",        "Blacksmithing & Eng", 1 },
    { 18641, "Dense Dynamite",        "Blacksmithing & Eng", 1 },
    { 7191,  "Fused Wiring",          "Blacksmithing & Eng", 1 },
    { 15994, "Thorium Widget",        "Blacksmithing & Eng", 1 },
    { 16000, "Thorium Tube",          "Blacksmithing & Eng", 1 },
    { 15993, "Thorium Grenade",       "Blacksmithing & Eng", 1 },

    -- Cooking & Fishing
    { 6358,  "Oily Blackmouth",       "Cooking & Fishing", 1 },
    { 6359,  "Firefin Snapper",       "Cooking & Fishing", 1 },
    { 13422, "Stonescale Eel",        "Cooking & Fishing", 1 },
    { 13759, "Raw Nightfin Snapper",  "Cooking & Fishing", 1 },
    { 13755, "Winter Squid",          "Cooking & Fishing", 1 },
    { 13754, "Raw Glossy Mightfish",  "Cooking & Fishing", 1 },
    { 6522,  "Deviate Fish",          "Cooking & Fishing", 1 },
    { 12208, "Tender Wolf Meat",      "Cooking & Fishing", 1 },
    { 20424, "Sandworm Meat",         "Cooking & Fishing", 1 },
    { 6657,  "Savory Deviate Delight","Cooking & Fishing", 1 },
    { 13931, "Nightfin Soup",         "Cooking & Fishing", 1 },
    { 20452, "Smoked Desert Dumplings","Cooking & Fishing", 1 },
}

-- Fast lookup by itemID
Catalog.BY_ID = {}
for i = 1, #Catalog.ITEMS do
    local entry = Catalog.ITEMS[i]
    Catalog.BY_ID[entry[1]] = entry
end

-- Smart profession auto-classification for ANY item (including WoW: Forever custom items & gear).
-- Prevents custom additions while on "All" from falling into "Herbalism".
function Catalog.GuessGroupForItem(itemID, itemName)
    itemID = tonumber(itemID)
    if itemID and Catalog.BY_ID[itemID] then
        return Catalog.BY_ID[itemID][3]
    end

    local resolvedName = itemName
    local classID, subClassID = nil, nil
    if itemID and NS.Compat and NS.Compat.GetItemInfoInstant then
        local _, _, _, _, _, cID, scID = NS.Compat.GetItemInfoInstant(itemID)
        classID, subClassID = cID, scID
    end
    if (not resolvedName or resolvedName == "") and itemID and NS.Compat and NS.Compat.GetItemInfo then
        resolvedName = NS.Compat.GetItemInfo(itemID)
    end

    -- 1. Name-based precision checks (handles cross-profession crafts & WoW: Forever custom mats)
    local n = (type(resolvedName) == "string") and resolvedName:lower() or ""
    if n ~= "" then
        if n:find("enchanted ", 1, true) or n:find(" dust", 1, true) or n:find(" shard", 1, true)
            or n:find(" pearl", 1, true) or n:find("righteous orb", 1, true)
            or n:find("wizard oil", 1, true) or n:find("mana oil", 1, true)
            or (n:find("essence", 1, true) and (n:find("magic", 1, true) or n:find("astral", 1, true) or n:find("mystic", 1, true) or n:find("nether", 1, true) or n:find("eternal", 1, true)))
        then
            return "Enchanting"
        end
        if n:find("sharpening stone", 1, true) or n:find("weightstone", 1, true)
            or n:find("blasting powder", 1, true) or n:find("dynamite", 1, true)
            or n:find("bomb", 1, true) or n:find("grenade", 1, true)
            or n:find("widget", 1, true) or n:find("thorium tube", 1, true)
            or n:find("wiring", 1, true) or n:find("elemental ", 1, true)
            or n:find("essence of ", 1, true)
        then
            return "Blacksmithing & Eng"
        end
        if n:find("bolt of ", 1, true) or n:find("cloth", 1, true) or n:find("spider's silk", 1, true)
            or n:find("shadow silk", 1, true) or n:find("spider silk", 1, true)
        then
            return "Tailoring"
        end
        if n:find("potion", 1, true) or n:find("elixir", 1, true) or n:find("flask", 1, true)
            or n:find("arcanite bar", 1, true) or n:find(" oil", 1, true)
        then
            return "Alchemy"
        end
        if n:find("leather", 1, true) or n:find("hide", 1, true) or n:find("dragonscale", 1, true)
            or n:find("deeprock salt", 1, true)
        then
            return "Skinning"
        end
        if n:find(" ore", 1, true) or n:find(" bar", 1, true) or n:find(" stone", 1, true)
            or n:find("pyrite", 1, true) or n:find("crystal", 1, true)
            or n:find("sapphire", 1, true) or n:find("emerald", 1, true)
            or n:find("ruby", 1, true) or n:find("opal", 1, true) or n:find("diamond", 1, true)
        then
            return "Mining"
        end
        if n:find("lichen", 1, true) or n:find("lotus", 1, true) or n:find("bloom", 1, true)
            or n:find("leaf", 1, true) or n:find("moss", 1, true) or n:find("weed", 1, true)
            or n:find("grass", 1, true) or n:find("kelp", 1, true) or n:find("root", 1, true)
            or n:find("thorn", 1, true) or n:find("thistle", 1, true) or n:find("silversage", 1, true)
            or n:find("dreamfoil", 1, true) or n:find("icecap", 1, true) or n:find("sansam", 1, true)
            or n:find("gromsblood", 1, true) or n:find("mushroom", 1, true)
        then
            return "Herbalism"
        end
        if n:find("snapper", 1, true) or n:find("fish", 1, true) or n:find("squid", 1, true)
            or n:find("eel", 1, true) or n:find("salmon", 1, true) or n:find("meat", 1, true)
            or n:find("soup", 1, true) or n:find("dumpling", 1, true) or n:find("delight", 1, true)
            or n:find("steak", 1, true) or n:find("stew", 1, true)
        then
            return "Cooking & Fishing"
        end
    end

    -- 2. WoW item classID / subClassID classification (Enum.ItemClass.Tradegoods = 7, Consumable = 0)
    if classID == 7 then
        if subClassID == 9 then return "Herbalism"
        elseif subClassID == 7 then return "Mining"
        elseif subClassID == 6 then return "Skinning"
        elseif subClassID == 5 then return "Tailoring"
        elseif subClassID == 12 then return "Enchanting"
        elseif subClassID == 8 then return "Cooking & Fishing"
        elseif subClassID == 1 or subClassID == 2 or subClassID == 3 or subClassID == 10 then
            return "Blacksmithing & Eng"
        end
    elseif classID == 0 then
        if subClassID == 1 or subClassID == 2 or subClassID == 3 then
            return "Alchemy"
        elseif subClassID == 5 then
            return "Cooking & Fishing"
        end
    end

    return "Flipping"
end

-- Ordered Dashboard sub-tab & grouped section definitions
Catalog.DASHBOARD_CATEGORIES = {
    { id = "Herbalism",           pill = "Herbs",     title = "Herbalism" },
    { id = "Mining",              pill = "Mining",    title = "Mining — Ores, Bars & Stone" },
    { id = "Fishing",             pill = "Fishing",   title = "Fishing" },
    { id = "Skinning",            pill = "Skinning",  title = "Skinning & Leather" },
    { id = "Tailoring",           pill = "Tailoring", title = "Tailoring & Cloth" },
    { id = "Enchanting",          pill = "Enchant",   title = "Enchanting" },
    { id = "Alchemy",             pill = "Alchemy",   title = "Alchemy & Consumables" },
    { id = "Blacksmithing & Eng", pill = "BS & Eng",  title = "Blacksmithing, Eng & Elementals" },
    { id = "Cooking",             pill = "Cooking",   title = "Cooking & Meat" },
}

local KNOWN_FISHING_IDS = {
    [6358]  = true, -- Oily Blackmouth
    [6359]  = true, -- Firefin Snapper
    [13422] = true, -- Stonescale Eel
    [13759] = true, -- Raw Nightfin Snapper
    [13755] = true, -- Winter Squid / Raw Winter Squid
    [13754] = true, -- Raw Glossy Mightfish
    [6522]  = true, -- Deviate Fish
    [6657]  = true, -- Savory Deviate Delight
    [13931] = true, -- Nightfin Soup
    [13756] = true, -- Raw Summer Bass
    [13758] = true, -- Raw Redgill
    [13760] = true, -- Raw Sunscale Salmon
    [13889] = true, -- Cooked Glossy Mightfish
    [13893] = true, -- Large Raw Mightfish
    [13928] = true, -- Grilled Squid
    [21153] = true, -- Raw Greater Sagefish
    [21071] = true, -- Raw Sagefish
    [21072] = true, -- Smoked Sagefish
    [21217] = true, -- Sagefish Delight
}

local SPECIFIC_PROFESSION_GROUPS = {
    ["Herbalism"]           = true,
    ["Mining"]              = true,
    ["Skinning"]            = true,
    ["Tailoring"]           = true,
    ["Enchanting"]          = true,
    ["Alchemy"]             = true,
    ["Blacksmithing & Eng"] = true,
}

local GENERIC_WATCH_GROUPS = {
    ["Watch list"] = true,
    ["Watchlist"]  = true,
    ["Flipping"]   = true,
    ["AH Market"]  = true,
    ["All"]        = true,
}

function Catalog.IsFishingItem(itemID, itemName)
    itemID = tonumber(itemID)
    if itemID and KNOWN_FISHING_IDS[itemID] then
        return true
    end
    local n = (type(itemName) == "string") and itemName:lower() or ""
    if n == "" then return false end
    if n:find(" oil", 1, true) then
        return false -- Keep Blackmouth/Fire/Stonescale Oil in Alchemy
    end
    if n:find("snapper", 1, true) or n:find("fish", 1, true) or n:find("squid", 1, true)
        or n:find("eel", 1, true) or n:find("salmon", 1, true) or n:find("blackmouth", 1, true)
        or n:find("deviate", 1, true) or n:find("trout", 1, true) or n:find("catfish", 1, true)
        or n:find("lobster", 1, true) or n:find("clam", 1, true) or n:find("bass", 1, true)
        or n:find("redgill", 1, true) or n:find("halibut", 1, true)
    then
        return true
    end
    return false
end

-- Resolves the clean Dashboard sub-tab category for any pinned or held item.
-- Splits "Cooking & Fishing" into "Fishing" vs "Cooking", and auto-classifies items
-- that were placed in generic groups like "Watch list" or "Flipping" (e.g. Frilled Lichen -> Herbalism, Pyrite -> Mining).
function Catalog.GetDashboardCategory(itemID, watchEntry, fallbackName)
    itemID = tonumber(itemID)
    local name = (watchEntry and watchEntry.name) or fallbackName
    if (not name or name == "") and itemID and NS.Compat and NS.Compat.GetItemInfo then
        name = NS.Compat.GetItemInfo(itemID)
    end

    local grp = watchEntry and watchEntry.group or nil
    if grp == "Herbs" then
        return "Herbalism"
    elseif grp == "Fishing" then
        return "Fishing"
    elseif grp == "Cooking" then
        return "Cooking"
    elseif grp == "Cooking & Fishing" then
        return Catalog.IsFishingItem(itemID, name) and "Fishing" or "Cooking"
    elseif grp and SPECIFIC_PROFESSION_GROUPS[grp] then
        return grp
    end

    -- Auto-classify from catalog / item name / WoW subclass (handles custom WoW: Forever mats & generic groups)
    local guessed = Catalog.GuessGroupForItem(itemID, name)
    if guessed == "Cooking & Fishing" then
        return Catalog.IsFishingItem(itemID, name) and "Fishing" or "Cooking"
    elseif guessed and SPECIFIC_PROFESSION_GROUPS[guessed] then
        return guessed
    elseif Catalog.IsFishingItem(itemID, name) then
        return "Fishing"
    end

    -- Preserve meaningful custom user-created groups (e.g. "Raid Mats", "Consumables")
    if grp and grp ~= "" and not GENERIC_WATCH_GROUPS[grp] then
        return grp
    end
    return "Other"
end

-- Searches the built-in profession catalog by partial name or Item ID
function Catalog.Search(query, limit)
    if type(query) ~= "string" then return {} end
    local q = query:lower():match("^%s*(.-)%s*$")
    if q == "" then return {} end

    local maxResults = limit or 12
    local out = {}
    local numQuery = tonumber(q)

    for i = 1, #Catalog.ITEMS do
        local row = Catalog.ITEMS[i]
        local itemID, name, group, quality = row[1], row[2], row[3], row[4]
        local matched = false
        if numQuery and itemID == numQuery then
            matched = true
        elseif name:lower():find(q, 1, true) or group:lower():find(q, 1, true) then
            matched = true
        end
        if matched then
            local liveName, _, liveQuality, _, _, _, _, _, _, liveIcon = NS.Compat.GetItemInfo(itemID)
            table.insert(out, {
                itemID  = itemID,
                name    = liveName or name,
                group   = group,
                quality = liveQuality ~= nil and liveQuality or quality,
                icon    = liveIcon or NS.Compat.GetItemIconByID(itemID) or 134400,
                source  = group,
            })
            if #out >= maxResults then break end
        end
    end
    return out
end

-- Scans player bags for items matching query (works offline anywhere)
function Catalog.SearchPlayerBags(query, limit)
    if type(query) ~= "string" then return {} end
    local q = query:lower():match("^%s*(.-)%s*$")
    if q == "" then return {} end

    local maxResults = limit or 8
    local results = {}
    local seen = {}

    local getNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    local getItemID = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
    if not getNumSlots or not getItemID then
        return results
    end

    local maxBag = NUM_BAG_SLOTS or 4
    for bag = 0, maxBag do
        local slots = getNumSlots(bag) or 0
        for slot = 1, slots do
            local itemID = getItemID(bag, slot)
            if itemID and not seen[itemID] then
                local name, _, quality, _, _, _, _, _, _, icon = NS.Compat.GetItemInfo(itemID)
                if name and name:lower():find(q, 1, true) then
                    seen[itemID] = true
                    table.insert(results, {
                        itemID  = itemID,
                        name    = name,
                        quality = quality or 1,
                        icon    = icon or NS.Compat.GetItemIconByID(itemID) or 134400,
                        source  = "In Bags",
                    })
                    if #results >= maxResults then return results end
                end
            end
        end
    end

    return results
end
