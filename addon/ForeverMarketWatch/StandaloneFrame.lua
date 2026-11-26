-- StandaloneFrame.lua
-- Classic WoW Auction House styled movable/resizable standalone window,
-- draggable minimap button, SavedVariables init, and slash commands (/fmw, /market).

local ADDON_NAME, NS = ...

local Standalone = {}
NS.Standalone = Standalone

local windowFrame = nil
local minimapButton = nil

--------------------------------------------------------------------------------
-- Standalone Window (Classic WoW AH Dialog Frame)
--------------------------------------------------------------------------------

local function SaveWindowGeometry()
    if not windowFrame then return end
    local s = NS.DB:GetSettings()
    local point, _, _, x, y = windowFrame:GetPoint(1)
    s.window = {
        point  = point or "CENTER",
        x      = math.floor((x or 0) + 0.5),
        y      = math.floor((y or 0) + 0.5),
        width  = math.floor((windowFrame:GetWidth() or 920) + 0.5),
        height = math.floor((windowFrame:GetHeight() or 580) + 0.5),
    }
end

function Standalone:GetOrCreateWindow()
    if windowFrame then
        return windowFrame
    end

    local f = NS.CreateDialogFrame(UIParent, "ForeverMarketWatchFrame")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetResizable(true)
    f:EnableMouse(true)

    if f.SetResizeBounds then
        f:SetResizeBounds(820, 480, 1320, 840)
    elseif f.SetMinResize then
        f:SetMinResize(820, 480)
        f:SetMaxResize(1320, 840)
    end

    local cfg = NS.DB:GetSettings().window or {}
    f:SetSize(math.max(820, cfg.width or 920), math.max(480, cfg.height or 580))
    f:ClearAllPoints()
    f:SetPoint(cfg.point or "CENTER", UIParent, cfg.point or "CENTER", cfg.x or 0, cfg.y or 0)

    if UISpecialFrames then
        local already = false
        for i = 1, #UISpecialFrames do
            if UISpecialFrames[i] == "ForeverMarketWatchFrame" then
                already = true
                break
            end
        end
        if not already then
            table.insert(UISpecialFrames, "ForeverMarketWatchFrame")
        end
    end

    -- Classic WoW AH Header Bar (drag handle)
    local titleBar = NS.CreatePanel(f, nil, NS.COLORS.BG_HEADER, NS.COLORS.BORDER, true)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -10)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)
    titleBar:SetHeight(28)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        SaveWindowGeometry()
    end)

    local titleIcon = titleBar:CreateTexture(nil, "ARTWORK")
    titleIcon:SetSize(20, 20)
    titleIcon:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    titleIcon:SetTexture(133784) -- Classic gold coin icon
    titleIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("LEFT", titleIcon, "RIGHT", 7, 0)
    titleText:SetText("ForeverMarketWatch  |cFFA89C86v" .. NS.VERSION .. "|r")

    -- Native Classic WoW red close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Resize Grip (bottom-right)
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 6)
    grip:EnableMouse(true)
    local gripTxt = grip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gripTxt:SetPoint("CENTER", 1, -1)
    gripTxt:SetText("//")
    grip:SetScript("OnMouseDown", function()
        f:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        SaveWindowGeometry()
    end)

    f:SetScript("OnShow", function(self)
        NS:FireCallback("HIDE_AH_OVERLAY")
        NS.UI.MountInto(self, 12, 12, 44, 14)
    end)
    f:SetScript("OnHide", function()
        NS.CloseAllDropdowns()
    end)

    f:Hide()
    windowFrame = f
    return f
end

function Standalone:Show()
    local f = self:GetOrCreateWindow()
    f:Show()
    f:Raise()
end

function Standalone:Hide()
    if windowFrame and windowFrame:IsShown() then
        windowFrame:Hide()
    end
end

function Standalone:Toggle()
    local f = self:GetOrCreateWindow()
    if f:IsShown() then
        f:Hide()
    else
        self:Show()
    end
end

function Standalone:IsShown()
    return windowFrame ~= nil and windowFrame:IsShown()
end

--------------------------------------------------------------------------------
-- Draggable Minimap Button (Zero External Libs)
--------------------------------------------------------------------------------

local function UpdateMinimapButtonPosition(btn, angleDeg)
    local rad = math.rad(angleDeg or 225)
    local radius = 80
    local x = math.cos(rad) * radius
    local y = math.sin(rad) * radius
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMinimapButton()
    if minimapButton or not Minimap then return end

    local btn = CreateFrame("Button", "ForeverMarketWatchMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetPoint("CENTER", 0, 0)
    bg:SetColorTexture(0.10, 0.08, 0.06, 0.95)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(133784)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    local angle = NS.DB:GetSettings().minimapAngle or 225
    UpdateMinimapButtonPosition(btn, angle)

    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            local deg = math.deg(math.atan2(cy - my, cx - mx))
            NS.DB:GetSettings().minimapAngle = deg
            UpdateMinimapButtonPosition(self, deg)
        end)
    end)

    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    btn:SetScript("OnClick", function(_, mouseBtn)
        if mouseBtn == "RightButton" then
            if NS.Scanner:IsAuctionHouseOpen() then
                NS.Scanner:StartWatchlistScan(false)
            else
                local count = #NS.DB:GetWatchedItemIDs()
                NS.Print(string.format("Tracking %d items on %s. Left-click minimap icon or type /fmw to open.", count, NS.DB:GetActiveMarketKey()))
            end
        else
            Standalone:Toggle()
        end
    end)

    minimapButton = btn
end

--------------------------------------------------------------------------------
-- Slash Commands (/fmw and /market)
--------------------------------------------------------------------------------

local function HandleSlashCommand(msg)
    local input = (msg or ""):match("^%s*(.-)%s*$")
    local cmd, rest = input:match("^(%S+)%s*(.-)$")
    cmd = cmd and cmd:lower() or ""

    if cmd == "" or cmd == "open" or cmd == "show" then
        Standalone:Toggle()
    elseif cmd == "scan" then
        NS.Scanner:StartWatchlistScan(false)
    elseif cmd == "stop" then
        NS.Scanner:StopScan("USER_STOP")
    elseif cmd == "seed" then
        local added = NS.DB:SeedProfessionMaterials(false)
        if added == 0 then
            NS.Print("All profession materials are already in your watchlist.")
        end
    elseif cmd == "add" then
        if not rest or rest == "" then
            NS.Print("Usage: /fmw add <ItemLink, ItemID, or Name>")
            return
        end
        local ok, result = NS.DB:AddWatchItem(rest)
        if ok and result then
            NS.Print("Added to watchlist: " .. tostring(result.name))
            Standalone:Show()
            NS.UI.SelectItem(result.itemID)
        else
            local matches = NS.DB:SearchOfflineItems(rest, 1)
            if #matches > 0 then
                local m = matches[1]
                local ok2, res2 = NS.DB:AddWatchItem(m.itemID, nil, m.name, m.icon, m.quality)
                if ok2 and res2 then
                    NS.Print("Added to watchlist: " .. tostring(res2.name))
                    Standalone:Show()
                    NS.UI.SelectItem(res2.itemID)
                    return
                end
            end
            NS.PrintError(result or "Could not find item.")
        end
    elseif cmd == "demo" then
        if NS.ToggleDemoMode then
            NS.ToggleDemoMode()
            Standalone:Show()
        end
    elseif cmd == "repair" then
        local stats = NS.DB:RebuildAccountingFromLedger(true)
        NS.Print(string.format("Accounting rebuilt: purged %d duplicate mail rows, replayed %d trades cleanly.", stats.purged or 0, stats.replayed or 0))
    elseif cmd == "test" then
        if NS.RunSelfTests then
            NS.RunSelfTests()
        end
    else
        NS.Print("Commands: /fmw (toggle), /fmw scan, /fmw add <name|link|id>, /fmw seed, /fmw repair (recalc ledger), /fmw demo, /fmw test")
    end
end

SLASH_FOREVERMARKETWATCH1 = "/fmw"
SLASH_FOREVERMARKETWATCH2 = "/market"
SlashCmdList["FOREVERMARKETWATCH"] = HandleSlashCommand

--------------------------------------------------------------------------------
-- Addon Bootstrap
--------------------------------------------------------------------------------

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        -- Wait until PLAYER_LOGIN to initialize market/faction data so UnitFactionGroup("player") is always valid
        if type(ForeverMarketWatchDB) ~= "table" then
            ForeverMarketWatchDB = {}
        end
    elseif event == "PLAYER_LOGIN" then
        NS.DB:Init()
        if NS.Ledger and NS.Ledger.Init then
            NS.Ledger:Init()
        end
        CreateMinimapButton()
    end
end)
