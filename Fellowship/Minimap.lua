-- Minimap button: left-click opens the Fellowship window, right-click opens a small menu.
-- Drag it around the edge of the minimap; its position is saved.
local _, ns = ...
local MB = {}
ns.MinimapButton = MB

MB.ICON = "Interface\\Icons\\Ability_Warrior_SwordandBoard" -- a shield with a sword across it

local button

local function radius()
    local w = (Minimap and Minimap.GetWidth and Minimap:GetWidth()) or 140
    return w / 2 + 5
end

function MB:UpdatePosition()
    if not button then return end
    local angle = math.rad(ns.settings.minimapAngle or 210)
    local r = radius()
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function dragUpdate()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    if not mx or not px or not scale then return end
    px, py = px / scale, py / scale
    ns.settings.minimapAngle = math.deg(math.atan2(py - my, px - mx)) % 360
    MB:UpdatePosition()
end

-- Entries for the right-click menu. Add new items here.
function MB:MenuItems()
    return {
        { "Settings", function() ns.UI:ToggleSettings() end },
        { "Hide minimap button", function()
            MB:SetShown(false)
            ns.Print("Minimap button hidden. Bring it back with /fship minimap or in Settings.")
        end },
    }
end

function MB:OpenMenu(owner)
    local items = self:MenuItems()
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(owner, function(_, root)
            root:CreateTitle("Fellowship")
            for _, item in ipairs(items) do root:CreateButton(item[1], item[2]) end
        end)
    else
        ns.UI:ToggleSettings() -- no menu system available: go straight to settings
    end
end

local function showTooltip(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Fellowship")
    local f, fid = ns.Store:Active()
    if f then
        local list, onlineCount = ns.Sync:MemberList(fid)
        GameTooltip:AddLine(string.format("%s: %d of %d online", f.name, onlineCount, #list), 1, 1, 1)
        local chats, achievements = ns.Store:UnreadCounts(fid)
        if chats + achievements > 0 then
            GameTooltip:AddLine(string.format("%d new message%s, %d new announcement%s", chats, chats == 1 and "" or "s",
                achievements, achievements == 1 and "" or "s"), 0.31, 0.82, 0.71)
        end
    else
        GameTooltip:AddLine("Not in a fellowship yet", 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffffd100Left-click|r to open Fellowship", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffd100Right-click|r for the menu", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffd100Drag|r to move", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

function MB:Build()
    if button or not Minimap then return end
    button = CreateFrame("Button", "FellowshipMinimapButton", Minimap)
    self.button = button
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(MB.ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetPoint("TOPLEFT", 7, -6)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    button:SetScript("OnClick", function(self, mouseButton)
        if GameTooltip then GameTooltip:Hide() end
        if mouseButton == "RightButton" then
            MB:OpenMenu(self)
        else
            ns.UI:Toggle()
        end
    end)
    button:SetScript("OnDragStart", function(self)
        if GameTooltip then GameTooltip:Hide() end
        self:SetScript("OnUpdate", dragUpdate)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", showTooltip)
    button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    self:UpdatePosition()
end

function MB:SetShown(shown)
    ns.settings.minimapShow = shown and true or false
    self:Build()
    if not button then return end
    if shown then button:Show() else button:Hide() end
    if ns.UI.RefreshSettings then ns.UI:RefreshSettings() end
end

function MB:Init()
    self:Build()
    self:SetShown(ns.settings.minimapShow ~= false)
end
