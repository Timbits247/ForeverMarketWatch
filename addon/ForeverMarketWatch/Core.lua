-- Core.lua
-- Shared namespace, WoW: Forever (1.60.1) API compatibility helpers,
-- full Gold/Silver/Copper formatting, Classic WoW Auction House UI primitives,
-- and internal callback bus.

local ADDON_NAME, NS = ...

NS.ADDON_NAME = ADDON_NAME
NS.VERSION = "2.6.1"
NS.SCHEMA_VERSION = 6
NS.MAX_COPPER = 99999999999 -- ~10M gold hard safety ceiling (prevents Inf/NaN corruption)
NS.MAX_QTY    = 1000000
NS.MAX_VALID_TS = 4102444800 -- 2100-01-01 UTC (guards C localtime() against overflow)

function NS.IsFiniteNumber(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

-- Neutralizes untrusted WoW UI escape codes (|T texture bombs, |H fake links, |c color spoofing,
-- |K protected strings, control chars) before storing or printing external strings.
function NS.SanitizeText(str, maxLen)
    if type(str) ~= "string" then return "" end
    local s = str
    s = s:gsub("|T.-|t", "")
    s = s:gsub("|A.-|a", "")
    s = s:gsub("|K.-|k", "")
    s = s:gsub("|H.-|h(.-)|h", "%1")
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|cn[^:]+:", "")
    s = s:gsub("|r", "")
    s = s:gsub("|n", " ")
    s = s:gsub("|", "")
    s = s:gsub("[%c]+", " ")
    s = s:match("^%s*(.-)%s*$") or ""
    local limit = maxLen or 120
    if #s > limit then
        s = s:sub(1, limit)
    end
    return s
end

-- Classic WoW Auction House visual palette (warm parchment/stone + gold/bronze)
NS.COLORS = {
    BG_DARK       = { 0.085, 0.075, 0.065, 0.96 },
    BG_PANEL      = { 0.125, 0.110, 0.095, 0.94 },
    BG_CARD       = { 0.160, 0.140, 0.115, 0.92 },
    BG_HEADER     = { 0.200, 0.160, 0.110, 0.95 },
    BG_ROW        = { 0.135, 0.118, 0.098, 0.78 },
    BG_ROW_ALT    = { 0.105, 0.092, 0.076, 0.78 },
    BG_ROW_HOVER  = { 0.260, 0.215, 0.145, 0.92 },
    BG_ROW_SEL    = { 0.340, 0.265, 0.125, 0.95 },
    BORDER        = { 0.480, 0.390, 0.250, 0.95 },
    BORDER_ACCENT = { 0.850, 0.680, 0.250, 1.00 },
    TEXT_GOLD     = { 1.000, 0.820, 0.000, 1.00 },
    TEXT_PRIMARY  = { 0.960, 0.940, 0.880, 1.00 },
    TEXT_MUTED    = { 0.720, 0.670, 0.580, 1.00 },
    GREEN         = { 0.220, 0.850, 0.450, 1.00 },
    RED           = { 0.960, 0.350, 0.330, 1.00 },
    AMBER         = { 1.000, 0.800, 0.200, 1.00 },
    BLUE          = { 0.420, 0.680, 0.980, 1.00 },
    VOL_UP        = { 0.220, 0.760, 0.420, 0.78 },
    VOL_DOWN      = { 0.860, 0.320, 0.300, 0.78 },
    VOL_BG        = { 0.055, 0.048, 0.042, 0.90 },
    RANGE_WICK    = { 0.850, 0.760, 0.520, 0.65 },
    GRID          = { 0.380, 0.320, 0.230, 0.38 },
    CROSSHAIR     = { 1.000, 0.880, 0.550, 0.65 },
}

NS.CHART_MODES = {
    { id = 1, label = "1. Price & Market Spread",      short = "Price & Spread" },
    { id = 2, label = "2. Price + Bottom Volume",      short = "Price + Volume" },
    { id = 3, label = "3. Price + Moving Average",     short = "Price + MA" },
    { id = 4, label = "4. Full Stock View (+Targets)", short = "Full Stock View" },
    { id = 5, label = "5. Day-of-Week Cycle (Mon-Sun)", short = "Weekday Cycle" },
}

NS.TIMEFRAMES = { "1D", "7D", "30D", "90D", "All" }

NS.SORT_MODES = {
    { id = "roi_desc",   label = "Hot Flips (Net ROI%)" },
    { id = "swing_desc", label = "7D Volatility (Swing%)" },
    { id = "name_asc",   label = "Name (A-Z)" },
    { id = "name_desc",  label = "Name (Z-A)" },
    { id = "price_desc", label = "Buyout (High-Low)" },
    { id = "price_asc",  label = "Buyout (Low-High)" },
    { id = "alerts",     label = "Alerts First" },
    { id = "delta",      label = "% vs 7D Avg" },
}

-- Neutral Goblin Auction House zones/subzones in Classic / Forever
local NEUTRAL_AH_ZONES = {
    ["Booty Bay"]  = true,
    ["Gadgetzan"]  = true,
    ["Everlook"]   = true,
}

local GOLD_ICON   = "|TInterface\\MoneyFrame\\UI-GoldIcon:11:11:1:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:11:11:1:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:11:11:1:0|t"

--------------------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------------------

function NS.Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD100[ForeverMarketWatch]|r " .. tostring(msg))
    end
end

function NS.PrintError(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5555[ForeverMarketWatch]|r " .. tostring(msg))
    end
end

--------------------------------------------------------------------------------
-- Internal Callback Bus
--------------------------------------------------------------------------------

local callbacks = {}

function NS:RegisterCallback(eventName, fn)
    if not callbacks[eventName] then
        callbacks[eventName] = {}
    end
    table.insert(callbacks[eventName], fn)
end

function NS:FireCallback(eventName, ...)
    local list = callbacks[eventName]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then
            NS.PrintError("Callback error (" .. tostring(eventName) .. "): " .. tostring(err))
        end
    end
end

--------------------------------------------------------------------------------
-- WoW: Forever 1.60.1 Compatibility Wrappers
--------------------------------------------------------------------------------

NS.Compat = {}

function NS.Compat.GetItemInfo(itemIdentifier)
    if C_Item and C_Item.GetItemInfo then
        return C_Item.GetItemInfo(itemIdentifier)
    elseif GetItemInfo then
        return GetItemInfo(itemIdentifier)
    end
    return nil
end

function NS.Compat.GetItemInfoInstant(itemIdentifier)
    if C_Item and C_Item.GetItemInfoInstant then
        return C_Item.GetItemInfoInstant(itemIdentifier)
    elseif GetItemInfoInstant then
        return GetItemInfoInstant(itemIdentifier)
    end
    return nil
end

function NS.Compat.GetItemIconByID(itemID)
    if C_Item and C_Item.GetItemIconByID then
        return C_Item.GetItemIconByID(itemID)
    elseif GetItemIcon then
        return GetItemIcon(itemID)
    end
    local _, _, _, _, icon = NS.Compat.GetItemInfoInstant(itemID)
    return icon
end

function NS.Compat.RequestLoadItemDataByID(itemID)
    if C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(itemID)
    end
end

function NS.Compat.GetQualityColor(quality)
    if C_Item and C_Item.GetItemQualityColor and quality ~= nil then
        local r, g, b, hex = C_Item.GetItemQualityColor(quality)
        if r and g and b then
            local prefixHex = (type(hex) == "string" and (hex:sub(1, 2) == "|c" and hex or ("|c" .. hex))) or "|cFFFFFFFF"
            return r, g, b, prefixHex
        end
    end
    if ITEM_QUALITY_COLORS and quality ~= nil and ITEM_QUALITY_COLORS[quality] then
        local c = ITEM_QUALITY_COLORS[quality]
        return c.r or 1, c.g or 1, c.b or 1, c.hex or "|cFFFFFFFF"
    end
    return 1, 1, 1, "|cFFFFFFFF"
end

function NS.Compat.ParseItemID(input)
    if type(input) == "number" then
        local n = math.floor(input)
        return n > 0 and n or nil
    end
    if type(input) ~= "string" then return nil end

    local trimmed = input:match("^%s*(.-)%s*$")
    if trimmed == "" then return nil end

    -- Plain numeric item ID
    local numeric = tonumber(trimmed)
    if numeric and numeric > 0 then
        return math.floor(numeric)
    end

    -- Standard WoW item link: |Hitem:13444:...|h[Major Mana Potion]|h
    local fromLink = trimmed:match("item:(%d+)")
    if fromLink then
        return tonumber(fromLink)
    end

    -- Try resolving item name via client cache
    local itemID = NS.Compat.GetItemInfoInstant(trimmed)
    if itemID and itemID > 0 then
        return itemID
    end

    return nil
end

function NS.GetCurrentMarketKey()
    local realm = (GetRealmName and GetRealmName()) or ""
    if realm == "" and GetNormalizedRealmName then
        realm = GetNormalizedRealmName() or ""
    end
    if realm == "" then
        realm = "Forever"
    end

    local faction = UnitFactionGroup and UnitFactionGroup("player") or nil
    if faction and faction ~= "" and faction ~= "Neutral" then
        if ForeverMarketWatchDB and ForeverMarketWatchDB.settings then
            ForeverMarketWatchDB.settings.lastFaction = faction
        end
    else
        -- Fallback to last known faction if queried before PLAYER_LOGIN finishes
        if ForeverMarketWatchDB and ForeverMarketWatchDB.settings and ForeverMarketWatchDB.settings.lastFaction then
            faction = ForeverMarketWatchDB.settings.lastFaction
        else
            faction = "Horde"
        end
    end

    return realm .. "-" .. faction
end

--------------------------------------------------------------------------------
-- Money Formatting & Parsing (Always Shows Gold, Silver, AND Copper)
--------------------------------------------------------------------------------

function NS.FormatMoney(copper, compact)
    if not copper or type(copper) ~= "number" then
        return "--"
    end
    local negative = copper < 0
    local value = math.floor(math.abs(copper) + 0.5)
    local gold = math.floor(value / 10000)
    local silver = math.floor((value % 10000) / 100)
    local cop = value % 100
    local prefix = negative and "-" or ""

    if compact then
        -- Compact text form for chart axes & tags: ALWAYS includes gold, silver, and copper
        if gold > 0 then
            return string.format("%s%dg %02ds %02dc", prefix, gold, silver, cop)
        elseif silver > 0 then
            return string.format("%s%ds %02dc", prefix, silver, cop)
        else
            return string.format("%s%dc", prefix, cop)
        end
    end

    -- Classic WoW AH coin-icon display: ALWAYS displays copper alongside gold & silver
    local parts = {}
    if gold > 0 then
        table.insert(parts, string.format("|cFFFFFFFF%d|r%s", gold, GOLD_ICON))
    end
    if silver > 0 or gold > 0 then
        table.insert(parts, string.format("|cFFFFFFFF%02d|r%s", silver, SILVER_ICON))
    end
    table.insert(parts, string.format("|cFFFFFFFF%02d|r%s", cop, COPPER_ICON))
    return prefix .. table.concat(parts, " ")
end

-- Signed colored money string (never produces "++" or "+-").
function NS.FormatSignedMoney(copper, compact)
    if not copper or type(copper) ~= "number" then
        return "|cFF998C78--|r"
    end
    local val = math.floor(copper + (copper >= 0 and 0.5 or -0.5))
    if val > 0 then
        return "|cFF38D972+" .. NS.FormatMoney(val, compact ~= false) .. "|r"
    elseif val < 0 then
        return "|cFFF55954" .. NS.FormatMoney(val, compact ~= false) .. "|r"
    end
    return "|cFFC4B79E" .. NS.FormatMoney(0, compact ~= false) .. "|r"
end

-- Signed colored percentage string (never produces "++").
function NS.FormatSignedPct(pct, decimals)
    if not pct or type(pct) ~= "number" then
        return ""
    end
    local fmt = (decimals == 0) and "%+.0f%%" or "%+.1f%%"
    if pct > 0.04 then
        return "|cFF38D972" .. string.format(fmt, pct) .. "|r"
    elseif pct < -0.04 then
        return "|cFFF55954" .. string.format(fmt, pct) .. "|r"
    end
    return "|cFFC4B79E0.0%|r"
end

function NS.FormatMoneyPlain(copper)
    if not copper or type(copper) ~= "number" or copper <= 0 then
        return ""
    end
    local value = math.floor(copper + 0.5)
    local gold = math.floor(value / 10000)
    local silver = math.floor((value % 10000) / 100)
    local cop = value % 100
    local parts = {}
    if gold > 0 then table.insert(parts, gold .. "g") end
    if silver > 0 or (gold > 0 and cop > 0) then table.insert(parts, silver .. "s") end
    if cop > 0 or #parts == 0 then table.insert(parts, cop .. "c") end
    return table.concat(parts, " ")
end

-- Parses strings like "12g 50s 25c", "12.5g", "45s 10c", "2.5", "150c" into integer copper.
-- Plain numbers without units are treated as gold (e.g., "4.5" -> 45000 copper).
function NS.ParseMoney(text)
    if type(text) == "number" then
        if not NS.IsFiniteNumber(text) or text <= 0 or text > NS.MAX_COPPER then return nil end
        return math.floor(text + 0.5)
    end
    if type(text) ~= "string" then return nil end
    if #text > 64 then return nil end
    local s = text:lower():match("^%s*(.-)%s*$")
    if s == "" then return nil end

    local plain = tonumber(s)
    if plain then
        if not NS.IsFiniteNumber(plain) or plain <= 0 then return nil end
        local cop = plain * 10000
        if not NS.IsFiniteNumber(cop) or cop > NS.MAX_COPPER then return nil end
        return math.floor(cop + 0.5)
    end

    local total = 0
    local matched = false

    local g = s:match("(%d+%.?%d*)%s*g")
    if g then
        local gv = tonumber(g)
        if not NS.IsFiniteNumber(gv) then return nil end
        total = total + gv * 10000
        matched = true
    end
    local sv = s:match("(%d+%.?%d*)%s*s")
    if sv then
        local svv = tonumber(sv)
        if not NS.IsFiniteNumber(svv) then return nil end
        total = total + svv * 100
        matched = true
    end
    local cp = s:match("(%d+%.?%d*)%s*c")
    if cp then
        local cpv = tonumber(cp)
        if not NS.IsFiniteNumber(cpv) then return nil end
        total = total + cpv
        matched = true
    end

    if not matched or not NS.IsFiniteNumber(total) or total <= 0 or total > NS.MAX_COPPER then
        return nil
    end
    return math.floor(total + 0.5)
end

function NS.FormatRelativeTime(timestamp, now)
    if not timestamp or timestamp <= 0 then
        return "Never"
    end
    local current = now or (time and time()) or 0
    local diff = math.max(0, current - timestamp)
    if diff < 60 then
        return "Just now"
    elseif diff < 3600 then
        return string.format("%dm ago", math.floor(diff / 60))
    elseif diff < 86400 then
        return string.format("%dh ago", math.floor(diff / 3600))
    else
        return string.format("%dd ago", math.floor(diff / 86400))
    end
end

local dayKeyCache = {}
local dayKeyCacheCount = 0
local dayTsCache = {}
local dayTsCacheCount = 0

function NS.DayKeyFromTimestamp(ts)
    if not NS.IsFiniteNumber(ts) or ts < 0 or ts > NS.MAX_VALID_TS then return 0 end
    ts = math.floor(ts)
    local cached = dayKeyCache[ts]
    if cached then return cached end
    local ok, d = pcall(date, "*t", ts)
    if not ok or type(d) ~= "table" or not d.year or not d.month or not d.day then
        return 0
    end
    local key = (d.year * 10000) + (d.month * 100) + d.day
    if dayKeyCacheCount >= 8192 then
        dayKeyCache = {}
        dayKeyCacheCount = 0
    end
    dayKeyCache[ts] = key
    dayKeyCacheCount = dayKeyCacheCount + 1
    return key
end

function NS.TimestampFromDayKey(dayKey)
    dayKey = tonumber(dayKey)
    if not NS.IsFiniteNumber(dayKey) or dayKey < 19700101 or dayKey > 21000101 then return 0 end
    dayKey = math.floor(dayKey)
    local cached = dayTsCache[dayKey]
    if cached then return cached end
    local year = math.floor(dayKey / 10000)
    local month = math.floor((dayKey % 10000) / 100)
    local day = dayKey % 100
    if month < 1 or month > 12 or day < 1 or day > 31 then return 0 end
    local ok, ts = pcall(time, { year = year, month = month, day = day, hour = 12, min = 0, sec = 0 })
    if not ok or not NS.IsFiniteNumber(ts) then return 0 end
    if dayTsCacheCount >= 2048 then
        dayTsCache = {}
        dayTsCacheCount = 0
    end
    dayTsCache[dayKey] = ts
    dayTsCacheCount = dayTsCacheCount + 1
    return ts
end

--------------------------------------------------------------------------------
-- Classic WoW Auction House UI Primitives
--------------------------------------------------------------------------------

local BACKDROP_INSET = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true,
    tileSize = 16,
    edgeSize = 12,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
}

local BACKDROP_CLASSIC_DIALOG = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile     = true,
    tileSize = 32,
    edgeSize = 24,
    insets   = { left = 6, right = 6, top = 6, bottom = 6 },
}

local BACKDROP_SOLID = {
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    tile     = false,
    edgeSize = 1,
    insets   = { left = 1, right = 1, top = 1, bottom = 1 },
}

function NS.CreateDialogFrame(parent, name)
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    local f = CreateFrame("Frame", name, parent, template)
    if f.SetBackdrop then
        f:SetBackdrop(BACKDROP_CLASSIC_DIALOG)
        f:SetBackdropColor(0.09, 0.08, 0.07, 0.96)
        f:SetBackdropBorderColor(0.85, 0.72, 0.45, 1)
    end
    return f
end

function NS.CreatePanel(parent, name, bgColor, borderColor, flat)
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    local f = CreateFrame("Frame", name, parent, template)
    if f.SetBackdrop then
        f:SetBackdrop(flat and BACKDROP_SOLID or BACKDROP_INSET)
        local bg = bgColor or NS.COLORS.BG_PANEL
        local bd = borderColor or NS.COLORS.BORDER
        f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 0.94)
        f:SetBackdropBorderColor(bd[1], bd[2], bd[3], bd[4] or 0.95)
    end
    return f
end

-- Classic WoW red-and-gold UIPanelButtonTemplate button with active/enabled helpers
function NS.CreateButton(parent, label, width, height, accent)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(width or 96, height or 22)
    btn:SetText(label or "")

    local fs = btn:GetFontString()
    if fs then
        fs:SetFontObject("GameFontNormalSmall")
    end

    -- Subtle gold glow overlay when marked active (e.g., selected timeframe pill)
    local activeGlow = btn:CreateTexture(nil, "OVERLAY")
    activeGlow:SetPoint("TOPLEFT", 2, -2)
    activeGlow:SetPoint("BOTTOMRIGHT", -2, 2)
    activeGlow:SetTexture("Interface\\Buttons\\UI-Panel-Button-Highlight")
    activeGlow:SetBlendMode("ADD")
    activeGlow:SetVertexColor(1.0, 0.85, 0.25, 0.45)
    activeGlow:Hide()
    btn._activeGlow = activeGlow

    if accent then
        if fs then fs:SetTextColor(1.0, 0.92, 0.45, 1) end
    end

    function btn:SetTextLabel(str)
        self:SetText(str or "")
    end

    function btn:SetActiveState(isActive)
        self._activeGlow:SetShown(isActive and true or false)
        local t = self:GetFontString()
        if t then
            if isActive then
                t:SetTextColor(1, 1, 1, 1)
            else
                t:SetTextColor(1, 0.82, 0, 1)
            end
        end
    end

    function btn:SetEnabledState(enabled)
        if enabled then
            self:Enable()
            self:SetAlpha(1.0)
        else
            self:Disable()
            self:SetAlpha(0.60)
        end
    end

    return btn
end

-- Shared floating popup menu container (one open at a time, Classic AH bronze border)
local activeDropdownMenu = nil

function NS.CloseAllDropdowns()
    if activeDropdownMenu and activeDropdownMenu:IsShown() then
        activeDropdownMenu:Hide()
    end
    activeDropdownMenu = nil
end

function NS.CreateDropdown(parent, width, height, onSelect)
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    local btn = CreateFrame("Button", nil, parent, template)
    btn:SetSize(width or 150, height or 22)
    if btn.SetBackdrop then
        btn:SetBackdrop(BACKDROP_INSET)
        btn:SetBackdropColor(0.11, 0.095, 0.08, 0.96)
        btn:SetBackdropBorderColor(0.65, 0.53, 0.32, 1)
    end

    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", btn, "LEFT", 8, 0)
    text:SetPoint("RIGHT", btn, "RIGHT", -20, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    btn.label = text

    local arrow = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrow:SetPoint("RIGHT", btn, "RIGHT", -7, 0)
    arrow:SetText("v")

    btn:SetScript("OnEnter", function(self)
        if self:IsEnabled() and self.SetBackdropBorderColor then
            self:SetBackdropBorderColor(1.0, 0.82, 0.25, 1)
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if self.SetBackdropBorderColor then
            self:SetBackdropBorderColor(0.65, 0.53, 0.32, 1)
        end
    end)

    local menu = NS.CreatePanel(UIParent, nil, NS.COLORS.BG_DARK, NS.COLORS.BORDER_ACCENT, false)
    menu:SetFrameStrata("TOOLTIP")
    menu:SetClampedToScreen(true)
    menu:Hide()
    menu.buttons = {}

    btn._options = {}
    btn._selectedValue = nil
    btn._onSelect = onSelect
    btn._menu = menu

    local function RebuildMenu()
        local opts = btn._options or {}
        local rowH = 21
        local pad = 6
        local menuW = math.max(btn:GetWidth(), 158)

        for i = 1, #opts do
            local opt = opts[i]
            local row = menu.buttons[i]
            if not row then
                row = CreateFrame("Button", nil, menu)
                row:SetHeight(rowH)
                local bg = row:CreateTexture(nil, "BACKGROUND")
                bg:SetAllPoints()
                bg:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
                bg:SetBlendMode("ADD")
                bg:SetAlpha(0)
                row.bg = bg

                local txt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                txt:SetPoint("LEFT", 8, 0)
                txt:SetPoint("RIGHT", -8, 0)
                txt:SetJustifyH("LEFT")
                row.txt = txt

                row:SetScript("OnEnter", function(self)
                    self.bg:SetAlpha(0.75)
                end)
                row:SetScript("OnLeave", function(self)
                    self.bg:SetAlpha(self._isSelected and 0.40 or 0)
                end)
                menu.buttons[i] = row
            end

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", menu, "TOPLEFT", 5, -(pad + (i - 1) * rowH))
            row:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -5, -(pad + (i - 1) * rowH))
            row.txt:SetText(opt.label)
            row._isSelected = (opt.value == btn._selectedValue)
            if row._isSelected then
                row.bg:SetAlpha(0.40)
                row.txt:SetTextColor(1.0, 0.82, 0.0, 1)
            else
                row.bg:SetAlpha(0)
                row.txt:SetTextColor(0.95, 0.93, 0.88, 1)
            end

            row:SetScript("OnClick", function()
                btn:SetSelected(opt.value, true)
                menu:Hide()
                activeDropdownMenu = nil
            end)
            row:Show()
        end

        for i = #opts + 1, #menu.buttons do
            menu.buttons[i]:Hide()
        end

        menu:SetSize(menuW, math.max(28, #opts * rowH + pad * 2))
    end

    function btn:SetOptions(options)
        self._options = options or {}
        if self._selectedValue ~= nil then
            self:SetSelected(self._selectedValue, false)
        elseif #self._options > 0 then
            self:SetSelected(self._options[1].value, false)
        end
    end

    function btn:SetSelected(value, fireCallback)
        self._selectedValue = value
        local display = tostring(value or "")
        for i = 1, #self._options do
            if self._options[i].value == value then
                display = self._options[i].shortLabel or self._options[i].label
                break
            end
        end
        self.label:SetText(display)
        if fireCallback and self._onSelect then
            self._onSelect(value)
        end
    end

    function btn:GetSelected()
        return self._selectedValue
    end

    function btn:SetEnabledState(enabled)
        if enabled then
            self:Enable()
            self:SetAlpha(1.0)
        else
            self:Disable()
            self:SetAlpha(0.55)
        end
    end

    btn:SetScript("OnClick", function(self)
        if menu:IsShown() then
            menu:Hide()
            activeDropdownMenu = nil
            return
        end
        NS.CloseAllDropdowns()
        RebuildMenu()
        menu:ClearAllPoints()
        menu:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
        menu:Show()
        activeDropdownMenu = menu
    end)

    return btn
end

-- Classic WoW AH InputBoxTemplate edit box
function NS.CreateEditBox(parent, width, height, placeholder)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(width or 160, height or 22)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetTextInsets(4, 4, 0, 0)

    local ph = eb:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ph:SetPoint("LEFT", eb, "LEFT", 6, 0)
    ph:SetPoint("RIGHT", eb, "RIGHT", -6, 0)
    ph:SetJustifyH("LEFT")
    ph:SetText(placeholder or "")
    eb._placeholder = ph

    local function UpdatePlaceholder()
        local txt = eb:GetText() or ""
        ph:SetShown(txt == "" and not eb:HasFocus())
    end

    eb:SetScript("OnTextChanged", UpdatePlaceholder)
    eb:HookScript("OnEditFocusGained", UpdatePlaceholder)
    eb:HookScript("OnEditFocusLost", UpdatePlaceholder)
    if hooksecurefunc then
        hooksecurefunc(eb, "SetText", UpdatePlaceholder)
    end
    eb:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    return eb, eb
end
