-- Menu: adds "Invite to Fellowship" to player right-click menus
-- (target/focus portraits, party and raid frames, player names in chat, guild and community rosters).
-- Uses the Mainline Menu API (Menu.ModifyMenu), which works without tainting Blizzard's menus.
local _, ns = ...
local M = {}
ns.Menu = M

M.TAGS = {
    "MENU_UNIT_PLAYER",       -- your own portrait / generic player units
    "MENU_UNIT_TARGET",       -- target portrait
    "MENU_UNIT_FOCUS",        -- focus portrait
    "MENU_UNIT_PARTY",        -- party frames
    "MENU_UNIT_RAID_PLAYER",  -- raid frames
    "MENU_UNIT_FRIEND",       -- player names in chat, friends list
    "MENU_UNIT_GUILD",        -- guild roster
    "MENU_UNIT_COMMUNITIES_GUILD_MEMBER",
    "MENU_UNIT_COMMUNITIES_MEMBER",
}

-- Full "Name-Realm" for the player a menu was opened on, or nil if it isn't someone we can invite.
function M:Resolve(contextData)
    if type(contextData) ~= "table" then return nil end
    local unit = contextData.unit
    if unit and UnitExists and UnitExists(unit) then
        if not UnitIsPlayer(unit) then return nil end
        if UnitFactionGroup and UnitFactionGroup(unit) ~= UnitFactionGroup("player") then return nil end
        local name, realm = UnitFullName(unit)
        if not name then return nil end
        return ns.NormalizeName(realm and realm ~= "" and (name .. "-" .. realm) or name)
    end
    local name = contextData.name
    if type(name) ~= "string" or name == "" then return nil end
    if not name:find("-", 1, true) and contextData.server and contextData.server ~= "" then
        name = name .. "-" .. contextData.server
    end
    return ns.NormalizeName(name)
end

function M:ShouldShow(target)
    local f, fid = ns.Store:Active()
    if not target or not f or f.pendingFrom then return false end
    if ns.Key(target) == ns.meKey or not ns.Store:CanInvite(fid, ns.me) then return false end
    return not ns.Store:IsMember(fid, target)
end

function M:Modify(owner, rootDescription, contextData)
    local target = self:Resolve(contextData)
    if not self:ShouldShow(target) then return end
    rootDescription:CreateDivider()
    rootDescription:CreateTitle("Fellowship")
    rootDescription:CreateButton("Invite to Fellowship", function() ns.Sync:Invite(target) end)
end

-- Chat tab right-click menu: a "Show Fellowship" checkbox, like the Guild/Party options.
M.CHAT_TAB_TAGS = { "MENU_FCF_TAB" }

function M:InitChatTab()
    if not (Menu and Menu.ModifyMenu) then return end
    for _, tag in ipairs(self.CHAT_TAB_TAGS) do
        Menu.ModifyMenu(tag, function(owner, rootDescription)
            local id = owner and owner.GetID and owner:GetID()
            if not id or not rootDescription.CreateCheckbox then return end
            rootDescription:CreateDivider()
            rootDescription:CreateCheckbox("Show Fellowship",
                function() return ns.ChatFrameSet()[id] == true end,
                function() ns.ToggleChatFrame(id) end)
        end)
    end
end

function M:Init()
    if not (Menu and Menu.ModifyMenu) then return end -- older menu system: use /fship invite instead
    for _, tag in ipairs(self.TAGS) do
        Menu.ModifyMenu(tag, function(owner, rootDescription, contextData)
            M:Modify(owner, rootDescription, contextData)
        end)
    end
end
