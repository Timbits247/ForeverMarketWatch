-- AuctionHouseTab.lua
-- Taint-free Classic WoW Auction House tab integration for WoW: Forever 1.60.1.
-- Automatically uses LibAHTab-1-0 when present (e.g., alongside Auctionator/TSM),
-- or attaches a non-mutating Classic-styled docked tab button that never alters
-- Blizzard's protected AuctionHouseFrame.Tabs or DisplayMode tables.

local _, NS = ...

local AHTab = {}
NS.AHTab = AHTab

local TAB_ID = "ForeverMarketWatchAHTab"
local initialized = false
local usingLibAHTab = false
local tabPanel = nil
local tabButton = nil
local displayModeHooked = false

local function FindRightmostVisibleAHTab()
    if not AuctionHouseFrame then return nil end
    local bestTab = nil
    local bestRight = -1

    if type(AuctionHouseFrame.Tabs) == "table" then
        for i = 1, #AuctionHouseFrame.Tabs do
            local t = AuctionHouseFrame.Tabs[i]
            if t and t:IsShown() and t.GetRight then
                local r = t:GetRight() or 0
                if r > bestRight then
                    bestRight = r
                    bestTab = t
                end
            end
        end
    end

    local children = { AuctionHouseFrame:GetChildren() }
    for i = 1, #children do
        local child = children[i]
        if child and child ~= tabButton and child:IsShown() and child:IsObjectType("Button") then
            local name = child:GetName() or ""
            if name:find("Tab") and child.GetRight and child.GetBottom and AuctionHouseFrame.GetBottom then
                local ahBottom = AuctionHouseFrame:GetBottom() or 0
                local cBottom = child:GetBottom() or 99999
                if math.abs(cBottom - ahBottom) < 40 then
                    local r = child:GetRight() or 0
                    if r > bestRight then
                        bestRight = r
                        bestTab = child
                    end
                end
            end
        end
    end

    return bestTab
end

local function PositionFallbackTab()
    if not tabButton or not AuctionHouseFrame then return end
    tabButton:ClearAllPoints()
    local anchor = FindRightmostVisibleAHTab()
    if anchor then
        tabButton:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
    else
        tabButton:SetPoint("TOPLEFT", AuctionHouseFrame, "BOTTOMLEFT", 260, 2)
    end
end

local function SetOverlayVisible(show)
    if not tabPanel then return end
    if show then
        NS.Standalone:Hide()
        tabPanel:Show()
        tabPanel:Raise()
        NS.UI.MountInto(tabPanel, 8, 8, 8, 8)
        if tabButton then
            tabButton:SetActiveState(true)
        end
    else
        tabPanel:Hide()
        if tabButton then
            tabButton:SetActiveState(false)
        end
    end
end

local function InitAHTab()
    if initialized or not AuctionHouseFrame then return end
    initialized = true

    tabPanel = NS.CreatePanel(AuctionHouseFrame, "ForeverMarketWatchAHPanel", NS.COLORS.BG_DARK, NS.COLORS.BORDER, false)
    tabPanel:SetFrameLevel((AuctionHouseFrame:GetFrameLevel() or 10) + 25)
    tabPanel:EnableMouse(true)
    tabPanel:Hide()

    local LibAHTab = LibStub and LibStub("LibAHTab-1-0", true) or nil
    if LibAHTab and LibAHTab.CreateTab then
        usingLibAHTab = true
        tabPanel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 6, -56)
        tabPanel:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -6, 8)

        tabPanel:SetScript("OnShow", function(self)
            NS.Standalone:Hide()
            NS.UI.MountInto(self, 6, 6, 6, 6)
        end)
        tabPanel:SetScript("OnHide", function()
            NS.CloseAllDropdowns()
        end)

        local ok = pcall(function()
            LibAHTab:CreateTab(TAB_ID, tabPanel, "Market Watch", "ForeverMarketWatch")
        end)
        if ok then
            return
        end
        usingLibAHTab = false
    end

    -- Zero-taint Classic WoW red-gold docked tab button
    tabPanel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 6, -56)
    tabPanel:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -6, 8)

    tabButton = NS.CreateButton(AuctionHouseFrame, "Market Watch", 108, 26, true)
    tabButton:SetFrameLevel((AuctionHouseFrame:GetFrameLevel() or 10) + 30)
    tabButton:SetScript("OnClick", function()
        if tabPanel:IsShown() then
            SetOverlayVisible(false)
        else
            SetOverlayVisible(true)
        end
    end)

    if not displayModeHooked and hooksecurefunc and AuctionHouseFrame.SetDisplayMode then
        displayModeHooked = true
        hooksecurefunc(AuctionHouseFrame, "SetDisplayMode", function()
            if tabPanel and tabPanel:IsShown() then
                SetOverlayVisible(false)
            end
        end)
    end

    PositionFallbackTab()
end

NS:RegisterCallback("HIDE_AH_OVERLAY", function()
    if usingLibAHTab then
        if tabPanel and tabPanel:IsShown() then
            tabPanel:Hide()
        end
    else
        SetOverlayVisible(false)
    end
end)

local ahHookFrame = CreateFrame("Frame")
ahHookFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
ahHookFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
if Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Auctioneer then
    ahHookFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
end

local function OnAHShow()
    InitAHTab()
    if not usingLibAHTab and tabButton then
        PositionFallbackTab()
        if C_Timer and C_Timer.After then
            C_Timer.After(0.15, PositionFallbackTab)
        end
    end
end

ahHookFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "AUCTION_HOUSE_SHOW" then
        OnAHShow()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if Enum and Enum.PlayerInteractionType and arg1 == Enum.PlayerInteractionType.Auctioneer then
            OnAHShow()
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        SetOverlayVisible(false)
    end
end)
