-- UI: the Fellowship window (Chat feed, Achievements, Members) and the invite popup.
local _, ns = ...
local UI = {}
ns.UI = UI

local frame
local panels, tabButtons = {}, {}
local activeTab = "chat"
local refreshQueued = false
local MAX_LINES = 600

local NEW_DIVIDER = "|cff33ff99----------  new since you were last here  ----------|r"
local TIME_COLOR = "|cff808080"

local function makeLog(parent)
    local smf = CreateFrame("ScrollingMessageFrame", nil, parent)
    smf:SetFontObject(ChatFontNormal)
    smf:SetJustifyH("LEFT")
    smf:SetFading(false)
    smf:SetMaxLines(MAX_LINES + 10)
    smf:SetHyperlinksEnabled(true)
    smf:SetScript("OnHyperlinkClick", function(self, link, text, button)
        SetItemRef(link, text, button, self)
    end)
    smf:EnableMouseWheel(true)
    smf:SetScript("OnMouseWheel", function(self, delta)
        if IsShiftKeyDown() then
            if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
        elseif delta > 0 then
            self:ScrollUp()
        else
            self:ScrollDown()
        end
    end)
    return smf
end

local function makeButton(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function makeInput(parent, maxLetters, onEnter)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(maxLetters)
    eb:SetHeight(22)
    eb:SetScript("OnEnterPressed", function(self)
        local text = self:GetText()
        self:SetText("")
        onEnter(text)
    end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return eb
end

function UI:Build()
    if frame then return end
    frame = CreateFrame("Frame", "FellowshipFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(560, 440)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:Hide()
    table.insert(UISpecialFrames, "FellowshipFrame") -- close on Escape

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -6)

    frame:SetScript("OnShow", function() UI:Refresh() end)
    frame:SetScript("OnHide", function()
        local fid = ns.Store:ActiveId()
        if fid then ns.Store:MarkRead(fid) end
    end)

    -- Tabs
    local tabs = { { "chat", "Chat" }, { "achievements", "Activity" }, { "members", "Members" } }
    for i, t in ipairs(tabs) do
        local b = makeButton(frame, t[2], 110, function() UI:SelectTab(t[1]) end)
        b:SetPoint("TOPLEFT", 12 + (i - 1) * 114, -28)
        tabButtons[t[1]] = b
    end

    local function panel()
        local p = CreateFrame("Frame", nil, frame)
        p:SetPoint("TOPLEFT", 12, -56)
        p:SetPoint("BOTTOMRIGHT", -12, 10)
        p:Hide()
        return p
    end

    -- Chat
    local chat = panel()
    chat.log = makeLog(chat)
    chat.log:SetPoint("TOPLEFT", 4, -4)
    chat.log:SetPoint("BOTTOMRIGHT", -4, 34)
    chat.input = makeInput(chat, 255, function(text) ns.Sync:PostChat(text) end)
    chat.input:SetPoint("BOTTOMLEFT", 8, 4)
    chat.input:SetPoint("BOTTOMRIGHT", -4, 4)
    panels.chat = chat

    local settingsButton = makeButton(frame, "Settings", 90, function() UI:ToggleSettings() end)
    settingsButton:SetPoint("TOPRIGHT", -12, -28)

    -- Activity: achievements, level-ups, collections, loot, dungeons, deaths
    local ach = panel()
    ach.log = makeLog(ach)
    ach.log:SetPoint("TOPLEFT", 4, -4)
    ach.log:SetPoint("BOTTOMRIGHT", -4, 4)
    panels.achievements = ach

    -- Members
    local mem = panel()
    -- A plain top-anchored text block: a ScrollingMessageFrame is bottom-anchored and
    -- "scroll to top" on a short list hides everything but the first line.
    mem.list = mem:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    mem.list:SetPoint("TOPLEFT", 8, -8)
    mem.list:SetPoint("BOTTOMRIGHT", -8, 38)
    mem.list:SetJustifyH("LEFT")
    mem.list:SetJustifyV("TOP")
    mem.list:SetSpacing(3)
    mem.input = makeInput(mem, 64, function(text) ns.Sync:Invite(text) end)
    mem.input:SetPoint("BOTTOMLEFT", 8, 4)
    mem.input:SetWidth(220)
    mem.invite = makeButton(mem, "Invite", 80, function()
        ns.Sync:Invite(mem.input:GetText())
        mem.input:SetText("")
    end)
    mem.invite:SetPoint("LEFT", mem.input, "RIGHT", 6, 0)
    mem.leave = makeButton(mem, "Leave", 80, function() StaticPopup_Show("FELLOWSHIP_LEAVE") end)
    mem.leave:SetPoint("BOTTOMRIGHT", -4, 4)
    panels.members = mem

    -- No fellowship yet
    local none = panel()
    none.text = none:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    none.text:SetPoint("TOP", 0, -40)
    none.text:SetWidth(460)
    none.text:SetText("You're not in a fellowship yet.\n\nCreate one below and invite your friends with /fship invite <player>, "
        .. "or ask a friend to invite you.\n\nEveryone in the fellowship keeps a copy of the chat and achievement history, "
        .. "so you can catch up on anything you missed while offline.")
    none.input = makeInput(none, 48, function(text) ns.Sync:Create(text) end)
    none.input:SetPoint("TOP", -45, -170)
    none.input:SetWidth(220)
    none.create = makeButton(none, "Create", 80, function()
        ns.Sync:Create(none.input:GetText())
        none.input:SetText("")
    end)
    none.create:SetPoint("LEFT", none.input, "RIGHT", 6, 0)
    panels.none = none
end

function UI:Init()
    StaticPopupDialogs["FELLOWSHIP_INVITE"] = {
        text = "%s has invited you to the Fellowship [%s]",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function(_, data) ns.Sync:AcceptInvite(data) end,
        OnCancel = function(_, data, reason)
            if reason ~= "override" then ns.Sync:DeclineInvite(data) end
        end,
        timeout = 120,
        whileDead = true,
        hideOnEscape = true,
    }
    StaticPopupDialogs["FELLOWSHIP_ADMIN_OFFER"] = {
        text = "%s wants to make you the Admin of the Fellowship [%s]. Do you accept?",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function(_, data) ns.Sync:AnswerAdminOffer(data, true) end,
        OnCancel = function(_, data, reason)
            if reason == "clicked" then ns.Sync:AnswerAdminOffer(data, false) end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = false,
    }
    StaticPopupDialogs["FELLOWSHIP_LEAVE"] = {
        text = "Leave your fellowship? Your copy of its history will be deleted.",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function() ns.Sync:Leave() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    local function queue() UI:QueueRefresh() end
    ns.Listen("EVENTS_ADDED", queue)
    ns.Listen("PRESENCE", queue)
    ns.Listen("FELLOWSHIP_CHANGED", queue)
end

function UI:ShowInvite(data)
    StaticPopup_Show("FELLOWSHIP_INVITE", ns.ColorName(data.from), ns.Escape(data.name), data)
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_PLAYER_INVITE then PlaySound(SOUNDKIT.IG_PLAYER_INVITE) end
    ns.Print(ns.ColorName(data.from) .. " has invited you to the Fellowship [" .. ns.Escape(data.name) .. "].")
end

function UI:ShowAdminOffer(data)
    StaticPopup_Show("FELLOWSHIP_ADMIN_OFFER", ns.ColorName(data.from), ns.Escape(data.name), data)
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_PLAYER_INVITE then PlaySound(SOUNDKIT.IG_PLAYER_INVITE) end
    ns.Print(ns.ColorName(data.from) .. " wants to make you the Admin of [" .. ns.Escape(data.name) .. "].")
end

function UI:IsShown()
    return frame ~= nil and frame:IsShown()
end

---------------------------------------------------------------------------
-- Settings window
---------------------------------------------------------------------------
local settingsFrame
UI.settingsChecks = {}

UI.SETTINGS_ROWS = {
    { "Chat messages (in your chat tabs)", nil, "echoChat" },
    { "Achievements", "shareAchievements", "showAchievements" },
    { "Level ups", "shareLevels", "showLevels" },
    { "New mounts, pets and toys", "shareCollections", "showCollections" },
    { "Loot (Rare or better)", "shareLoot", "showLoot" },
    { "Dungeon and raid completions", "shareInstances", "showInstances" },
    { "Deaths", "shareDeaths", "showDeaths" },
    { "Online / offline notices", nil, "showPresence" },
    { "Zone and level (Members tab)", "shareLocation", nil },
}

local QUALITY = {
    { 3, "Rare", "ff0070dd" },
    { 4, "Epic", "ffa335ee" },
    { 5, "Legendary", "ffff8000" },
}

local function qualityLabel()
    local q = ns.settings.lootMinQuality or 4
    for _, entry in ipairs(QUALITY) do
        if entry[1] == q then return "|c" .. entry[3] .. entry[2] .. "|r and better" end
    end
    return "Epic and better"
end

function UI:BuildSettings()
    if settingsFrame then return end
    local f = CreateFrame("Frame", "FellowshipSettingsFrame", UIParent, "BasicFrameTemplateWithInset")
    settingsFrame = f
    f:SetSize(470, 480)
    f:SetPoint("CENTER", 40, -20)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")
    f:Hide()
    table.insert(UISpecialFrames, "FellowshipSettingsFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -6)
    title:SetText("Fellowship Settings")

    local function label(text, x, y, font)
        local fs = f:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", x, y)
        fs:SetText(text)
        return fs
    end

    local SHARE_X, SHOW_X = 300, 380
    label("|cffffd100Announcements|r", 20, -36, "GameFontNormal")
    label("Share mine", SHARE_X - 8, -38)
    label("Show others'", SHOW_X - 12, -38)

    local function check(key, x, y)
        local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        cb:SetSize(24, 24)
        cb:SetPoint("TOPLEFT", x, y + 5)
        cb:SetScript("OnClick", function(self)
            ns.settings[key] = self:GetChecked() and true or false
            UI:QueueRefresh()
        end)
        UI.settingsChecks[key] = cb
        return cb
    end

    local y = -60
    for _, row in ipairs(UI.SETTINGS_ROWS) do
        label(row[1], 24, y)
        if row[2] then check(row[2], SHARE_X + 14, y) end
        if row[3] then check(row[3], SHOW_X + 14, y) end
        y = y - 26
    end

    y = y - 8
    label("Loot to show:", 24, y - 4)
    f.quality = makeButton(f, qualityLabel(), 170, function(self)
        local q = ns.settings.lootMinQuality or 4
        q = q + 1
        if q > 5 then q = 3 end
        ns.settings.lootMinQuality = q
        self:SetText(qualityLabel())
        UI:QueueRefresh()
    end)
    f.quality:SetPoint("TOPLEFT", 150, y)

    y = y - 32
    label("Chat text color:", 24, y - 4)
    f.color = makeInput(f, 7, function(text) ns.HandleSlash("color " .. text); UI:RefreshSettings() end)
    f.color:SetPoint("TOPLEFT", 156, y)
    f.color:SetWidth(80)
    f.colorPreview = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.colorPreview:SetPoint("LEFT", f.color, "RIGHT", 10, 0)
    f.colorReset = makeButton(f, "Reset", 60, function() ns.HandleSlash("color reset"); UI:RefreshSettings() end)
    f.colorReset:SetPoint("TOPRIGHT", -20, y)

    y = y - 32
    f.minimap = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.minimap:SetSize(24, 24)
    f.minimap:SetPoint("TOPLEFT", 20, y + 5)
    f.minimap:SetScript("OnClick", function(self) ns.MinimapButton:SetShown(self:GetChecked() and true or false) end)
    label("Show minimap button", 48, y)

    y = y - 30
    local tip = label("|cff808080To pick which chat tabs show Fellowship, right-click a chat tab and tick\n"
        .. "\"Show Fellowship\" (or type /fship tab in that tab). \"Share mine\" controls what your\n"
        .. "friends see from you; \"Show others'\" controls what you see.|r", 20, y)
    tip:SetJustifyH("LEFT")

    f:SetScript("OnShow", function() UI:RefreshSettings() end)
end

function UI:RefreshSettings()
    if not settingsFrame then return end
    for key, cb in pairs(self.settingsChecks) do cb:SetChecked(ns.settings[key] and true or false) end
    settingsFrame.quality:SetText(qualityLabel())
    settingsFrame.minimap:SetChecked(ns.settings.minimapShow ~= false)
    settingsFrame.color:SetText(ns.TextColor())
    settingsFrame.colorPreview:SetText("|cff" .. ns.TextColor() .. "Hello, fellowship!|r")
end

function UI:ToggleSettings()
    self:BuildSettings()
    if settingsFrame:IsShown() then settingsFrame:Hide() else settingsFrame:Show() end
end

function UI:Toggle()
    self:Build()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

function UI:SelectTab(tab)
    activeTab = tab
    self:Refresh()
end

function UI:QueueRefresh()
    if refreshQueued or not self:IsShown() then return end
    refreshQueued = true
    C_Timer.After(0.2, function()
        refreshQueued = false
        UI:Refresh()
    end)
end

local function renderFeed(log, fid, filter)
    log:Clear()
    local events = ns.Store:Sorted(fid)
    local shown = {}
    for _, e in ipairs(events) do
        if filter(e) then shown[#shown + 1] = e end
    end
    local first = math.max(1, #shown - MAX_LINES + 1)
    local divided = false
    for i = first, #shown do
        local e = shown[i]
        if not divided and ns.Store:IsUnread(fid, e) then
            log:AddMessage(NEW_DIVIDER)
            divided = true
        end
        local text = ns.FormatEvent(e)
        if text then log:AddMessage(TIME_COLOR .. ns.TimeStamp(e.t) .. "|r  " .. text) end
    end
    if #shown == 0 then
        log:AddMessage(TIME_COLOR .. "Nothing here yet.|r")
    end
    log:ScrollToBottom()
end

local function renderMembers(fs, fid)
    local list, onlineCount = ns.Sync:MemberList(fid)
    local achievementCounts = {}
    for _, e in ipairs(ns.Store:Sorted(fid)) do
        if e.k == "A" then achievementCounts[e.a] = (achievementCounts[e.a] or 0) + 1 end
    end
    local lines = { string.format("|cffffd100%d of %d online|r", onlineCount, #list), " " }
    for _, m in ipairs(list) do
        lines[#lines + 1] = string.format("%s  %s  |cffffd100%s|r", m.status, ns.ColorName(m.name), m.roleLabel)
        local achievements = achievementCounts[m.name] or 0
        lines[#lines + 1] = string.format("      |cffaaaaaa%smember since %s, %d achievement%s shared|r",
            m.where and (m.where .. "  -  ") or "", date("%b %d %Y", m.since), achievements, achievements == 1 and "" or "s")
    end
    fs:SetText(table.concat(lines, "\n"))
end

function UI:Refresh()
    if not frame or not frame:IsShown() then return end
    for _, p in pairs(panels) do p:Hide() end
    local f, fid = ns.Store:Active()
    if not f then
        frame.title:SetText("Fellowship")
        for _, b in pairs(tabButtons) do b:Disable() end
        panels.none:Show()
        return
    end
    for name, b in pairs(tabButtons) do
        if name == activeTab then b:Disable() else b:Enable() end
    end
    local members, onlineCount = ns.Sync:MemberList(fid) -- same count as the Members tab (includes you)
    frame.title:SetText(ns.Escape(f.name) .. (f.pendingFrom and "  (joining...)" or
        string.format("  |cff808080(%d of %d online)|r", onlineCount, #members)))

    local p = panels[activeTab]
    p:Show()
    if activeTab == "chat" then
        renderFeed(p.log, fid, function(e) return ns.Announce.ShouldShow(e) end)
    elseif activeTab == "achievements" then
        renderFeed(p.log, fid, function(e) return (e.k == "A" or e.k == "M") and ns.Announce.ShouldShow(e) end)
    else
        renderMembers(p.list, fid)
    end
end
