-- UI: the Fellowship window (Chat, Activity, Achievements, Members) and the invite popup.
local _, ns = ...
local UI = {}
ns.UI = UI

local frame
local panels, tabButtons = {}, {}
local activeTab = "chat"
local refreshQueued = false
local MAX_LINES = 600

-- Members roster columns (widths add up to the panel width)
local ROSTER_COLUMNS = {
    { key = "name", title = "Name", width = 200 },
    { key = "level", title = "Level", width = 50, align = "CENTER" },
    { key = "zone", title = "Zone", width = 170 },
    { key = "rank", title = "Rank", width = 90 },
    { key = "seen", title = "Last Online", width = 110 },
}
local ROSTER_ROWS, ROW_HEIGHT = 15, 18

-- Achievements tab columns
local FEAT_COLUMNS = {
    { key = "title", title = "Achievement", width = 230 },
    { key = "type", title = "Type", width = 70 },
    { key = "date", title = "Completed", width = 100 },
    { key = "with", title = "Completed With", width = 220 },
}
local FEAT_ROWS = 16
local rosterSort = { key = "default", reverse = false }
local RANK_ORDER = { admin = 1, inviter = 2, member = 3 }
local GREY = "|cff808080"

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
    frame:SetSize(660, 440)
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
    local tabs = { { "chat", "Chat" }, { "achievements", "Activity" }, { "feats", "Achievements" },
        { "members", "Members" } }
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
    local SIDEBAR = 150
    chat.log:SetPoint("TOPLEFT", 4, -4)
    chat.log:SetPoint("BOTTOMRIGHT", -(SIDEBAR + 10), 34)
    chat.input = makeInput(chat, 255, function(text) ns.Sync:PostChat(text) end)
    chat.input:SetPoint("BOTTOMLEFT", 8, 4)
    chat.input:SetPoint("BOTTOMRIGHT", -(SIDEBAR + 10), 4)

    -- Member list on the right, like the guild window: class color when online, grey when offline.
    chat.divider = chat:CreateTexture(nil, "ARTWORK")
    chat.divider:SetColorTexture(1, 1, 1, 0.12)
    chat.divider:SetWidth(1)
    chat.divider:SetPoint("TOPRIGHT", -(SIDEBAR + 2), -2)
    chat.divider:SetPoint("BOTTOMRIGHT", -(SIDEBAR + 2), 2)
    chat.membersHeader = chat:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    chat.membersHeader:SetPoint("TOPRIGHT", -6, -6)
    chat.membersHeader:SetWidth(SIDEBAR - 8)
    chat.membersHeader:SetJustifyH("LEFT")
    chat.members = chat:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    chat.members:SetPoint("TOPRIGHT", -6, -26)
    chat.members:SetPoint("BOTTOMRIGHT", -6, 4)
    chat.members:SetWidth(SIDEBAR - 8)
    chat.members:SetJustifyH("LEFT")
    chat.members:SetJustifyV("TOP")
    chat.members:SetSpacing(4)
    panels.chat = chat

    local settingsButton = makeButton(frame, "Settings", 90, function() UI:ToggleSettings() end)
    settingsButton:SetPoint("TOPRIGHT", -12, -28)

    -- Activity: achievements, level-ups, collections, loot, dungeons, deaths
    local ach = panel()
    ach.log = makeLog(ach)
    ach.log:SetPoint("TOPLEFT", 4, -4)
    ach.log:SetPoint("BOTTOMRIGHT", -4, 4)
    panels.achievements = ach

    -- Achievements: Fellowship Achievements (dungeons and raids completed together)
    local feats = panel()
    local fx = 4
    for _, c in ipairs(FEAT_COLUMNS) do
        local h = CreateFrame("Frame", nil, feats)
        h:SetPoint("TOPLEFT", fx, -2)
        h:SetSize(c.width, 20)
        local bg = h:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.08)
        local label = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", 6, 0)
        label:SetText(c.title)
        c.x = fx
        fx = fx + c.width + 2
    end
    feats.rows = {}
    for i = 1, FEAT_ROWS do
        local row = CreateFrame("Button", nil, feats)
        row:SetPoint("TOPLEFT", 4, -24 - (i - 1) * ROW_HEIGHT)
        row:SetSize(fx - 6, ROW_HEIGHT)
        if i % 2 == 0 then
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(1, 1, 1, 0.03)
        end
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.cells = {}
        for _, c in ipairs(FEAT_COLUMNS) do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", c.x - 4 + 6, 0)
            fs:SetWidth(c.width - 8)
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            row.cells[c.key] = fs
        end
        row:SetScript("OnEnter", function(self) if self.feat then UI:ShowFeatTooltip(self, self.feat) end end)
        row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        row:Hide()
        feats.rows[i] = row
    end
    feats.offset = 0
    feats:EnableMouseWheel(true)
    feats:SetScript("OnMouseWheel", function(_, delta)
        feats.offset = math.max(0, feats.offset - delta * 3)
        UI:Refresh()
    end)
    feats.count = feats:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feats.count:SetPoint("BOTTOMLEFT", 8, 8)
    feats.hint = feats:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    feats.hint:SetPoint("BOTTOMRIGHT", -8, 8)
    feats.hint:SetText("Complete a dungeon or raid where everyone in the group is in the fellowship.")
    panels.feats = feats

    -- Members: a roster laid out like the guild window
    local mem = panel()
    mem.cols = {}
    local x = 4
    for _, c in ipairs(ROSTER_COLUMNS) do
        local h = CreateFrame("Button", nil, mem)
        h:SetPoint("TOPLEFT", x, -2)
        h:SetSize(c.width, 20)
        local bg = h:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.08)
        h.label = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h.label:SetPoint("LEFT", 6, 0)
        h.label:SetText(c.title)
        h:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        h:SetScript("OnClick", function()
            if rosterSort.key == c.key then rosterSort.reverse = not rosterSort.reverse
            else rosterSort.key, rosterSort.reverse = c.key, false end
            UI:Refresh()
        end)
        c.x = x
        mem.cols[#mem.cols + 1] = h
        x = x + c.width + 2
    end
    mem.rows = {}
    for i = 1, ROSTER_ROWS do
        local row = CreateFrame("Button", nil, mem)
        row:SetPoint("TOPLEFT", 4, -24 - (i - 1) * ROW_HEIGHT)
        row:SetSize(x - 6, ROW_HEIGHT)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        if i % 2 == 0 then
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(1, 1, 1, 0.03)
        end
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.cells = {}
        for _, c in ipairs(ROSTER_COLUMNS) do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", c.x - 4 + 6, 0)
            fs:SetWidth(c.width - 8)
            fs:SetJustifyH(c.align or "LEFT")
            fs:SetWordWrap(false)
            row.cells[c.key] = fs
        end
        row:SetScript("OnEnter", function(self) if self.member then UI:ShowMemberTooltip(self, self.member) end end)
        row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        row:SetScript("OnClick", function(self, button)
            if self.member and button == "RightButton" then UI:OpenMemberMenu(self, self.member) end
        end)
        row:Hide()
        mem.rows[i] = row
    end
    mem.offset = 0
    mem:EnableMouseWheel(true)
    mem:SetScript("OnMouseWheel", function(_, delta)
        mem.offset = math.max(0, mem.offset - delta * 3)
        UI:Refresh()
    end)

    mem.count = mem:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mem.count:SetPoint("BOTTOMLEFT", 8, 36)
    mem.showOffline = CreateFrame("CheckButton", nil, mem, "UICheckButtonTemplate")
    mem.showOffline:SetSize(22, 22)
    mem.showOffline:SetPoint("BOTTOMRIGHT", -120, 30)
    mem.showOffline:SetScript("OnClick", function(self)
        ns.settings.showOffline = self:GetChecked() and true or false
        mem.offset = 0
        UI:Refresh()
    end)
    mem.showOfflineLabel = mem:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mem.showOfflineLabel:SetPoint("LEFT", mem.showOffline, "RIGHT", 2, 0)
    mem.showOfflineLabel:SetText("Show offline members")

    mem.input = makeInput(mem, 64, function(text) ns.Sync:Invite(text) end)
    mem.input:SetPoint("BOTTOMLEFT", 10, 4)
    mem.input:SetWidth(220)
    mem.invite = makeButton(mem, "Invite", 80, function()
        ns.Sync:Invite(mem.input:GetText())
        mem.input:SetText("")
    end)
    mem.invite:SetPoint("LEFT", mem.input, "RIGHT", 6, 0)
    mem.leave = makeButton(mem, "Leave", 80, function() StaticPopup_Show("FELLOWSHIP_LEAVE") end)
    mem.leave:SetPoint("BOTTOMRIGHT", -4, 4)
    panels.members = mem

    -- No fellowship yet: a "Create Fellowship" screen
    local none = panel()
    none.heading = none:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    none.heading:SetPoint("TOP", 0, -30)
    none.heading:SetText("Create Fellowship")
    none.text = none:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    none.text:SetPoint("TOP", none.heading, "BOTTOM", 0, -14)
    none.text:SetWidth(460)
    none.text:SetText("You're not in a fellowship yet. Name your fellowship and click Create, "
        .. "then invite friends by right-clicking them or with /fship invite <first> <last>.")
    none.label = none:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    none.label:SetText("Fellowship name")
    local function create()
        local name = ns.Trim(none.input:GetText())
        if name == "" then return end
        ns.Sync:Create(name)
        if ns.Store:ActiveId() then
            none.input:SetText("")
            none.input:ClearFocus()
        end
    end
    none.input = makeInput(none, 48, create)
    none.input:SetScript("OnEnterPressed", create) -- keep the text if creating fails
    none.input:SetWidth(260)
    none.input:SetPoint("TOP", none.text, "BOTTOM", -49, -50) -- centers the input + button pair
    none.label:SetPoint("BOTTOMLEFT", none.input, "TOPLEFT", -4, 6)
    none.create = makeButton(none, "Create", 90, create)
    none.create:SetPoint("LEFT", none.input, "RIGHT", 8, 0)
    none.input:SetScript("OnTextChanged", function(self)
        if ns.Trim(self:GetText()) == "" then none.create:Disable() else none.create:Enable() end
    end)
    none.create:Disable()
    none.footer = none:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    none.footer:SetPoint("BOTTOM", 0, 30)
    none.footer:SetWidth(460)
    none.footer:SetText("Got an invitation instead? Accept it and you'll join your friend's fellowship. Everyone keeps a copy "
        .. "of the chat and activity history, so you can catch up on anything you missed while offline.")
    panels.none = none
end

function UI:Init()
    StaticPopupDialogs["FELLOWSHIP_INVITE"] = {
        text = "%s has invited you to the Fellowship [%s]",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function(_, data) ns.Sync:AcceptInvite(data) end,
        OnCancel = function(_, data, reason)
            if reason ~= "override" then ns.Sync:DeclineInvite(data, reason) end
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
    StaticPopupDialogs["FELLOWSHIP_REMOVE"] = {
        text = "Remove %s from the fellowship? This includes all of their characters.",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function(_, data) ns.Sync:Remove(data) end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
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
    -- Shift-clicking an item, spell or achievement while typing in the Fellowship window links it there.
    local function insertLink(link)
        local eb = panels.chat and panels.chat.input
        if type(link) == "string" and eb and eb.HasFocus and eb:HasFocus() then eb:Insert(link) end
    end
    if hooksecurefunc then
        if ChatFrameUtil and ChatFrameUtil.InsertLink then
            hooksecurefunc(ChatFrameUtil, "InsertLink", insertLink)
        elseif ChatEdit_InsertLink then
            hooksecurefunc("ChatEdit_InsertLink", insertLink)
        end
    end
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
    { "Rare mobs spotted", "shareRares", "showRares" },
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
    f:SetSize(470, 506)
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

local function renderSidebar(p, fid)
    local list, onlineCount = ns.Sync:MemberList(fid)
    p.membersHeader:SetText(string.format("Members  |cff808080%d/%d|r", onlineCount, #list))
    local lines = {}
    for _, m in ipairs(list) do
        local name
        if m.online then
            name = ns.ColorName(m.name)
            if ns.Key(m.name) ~= ns.Key(m.main) then name = name .. " |cff808080(" .. ns.Short(m.main) .. ")|r" end
        else
            name = "|cff6e6e6e" .. ns.Short(m.main) .. "|r"
        end
        if m.role == "admin" then
            name = name .. " |cffffd100*|r"
        end
        lines[#lines + 1] = name
    end
    p.members:SetText(table.concat(lines, "\n"))
end

local function sortRoster(list)
    local key, rev = rosterSort.key, rosterSort.reverse
    local function value(m)
        if key == "name" then return ns.Short(m.name):lower()
        elseif key == "level" then return m.level or -1
        elseif key == "zone" then return (m.online and m.zone or "~"):lower()
        elseif key == "rank" then return RANK_ORDER[m.role] or 9
        elseif key == "seen" then return m.online and math.huge or (m.seen or 0) end
    end
    if key == "default" then return list end -- MemberList order: online first, then by name
    table.sort(list, function(a, b)
        local va, vb = value(a), value(b)
        if va == vb then return ns.Short(a.name):lower() < ns.Short(b.name):lower() end
        if key == "level" or key == "seen" then va, vb = -va, -vb end -- highest / most recent first
        if rev then return va > vb end
        return va < vb
    end)
    return list
end

local function renderMembers(p, fid)
    local all, onlineCount = ns.Sync:MemberList(fid)
    local showOffline = ns.settings.showOffline ~= false
    p.showOffline:SetChecked(showOffline)
    p.count:SetText(string.format("%d of %d members online", onlineCount, #all))
    local list = {}
    for _, m in ipairs(all) do
        if showOffline or m.online then list[#list + 1] = m end
    end
    sortRoster(list)
    p.offset = math.max(0, math.min(p.offset or 0, #list - ROSTER_ROWS))
    for i, row in ipairs(p.rows) do
        local m = list[i + p.offset]
        row.member = m
        if m then
            local c = row.cells
            if m.online then
                local name = ns.ColorName(m.name)
                if ns.Key(m.name) ~= ns.Key(m.main) then name = name .. GREY .. " (" .. ns.Short(m.main) .. ")|r" end
                if m.isMe then name = name .. GREY .. " (you)|r" end
                c.name:SetText(name)
                c.level:SetText(m.level and tostring(m.level) or "")
                c.zone:SetText(m.zone and ns.Escape(m.zone) or "")
                c.seen:SetText("|cff33ff99Online|r")
            else
                c.name:SetText("|cff6e6e6e" .. ns.Short(m.main) .. "|r")
                c.level:SetText("")
                c.zone:SetText(GREY .. "Offline|r")
                c.seen:SetText(GREY .. (m.seen and ns.Ago(m.seen) or "unknown") .. "|r")
            end
            local rank = m.roleLabel
            if m.role == "admin" then rank = "|cffffd100" .. rank .. "|r"
            elseif not m.online then rank = GREY .. rank .. "|r" end
            c.rank:SetText(rank)
            row:Show()
        else
            row:Hide()
        end
    end
end

local function renderFeats(p, fid)
    local rows, earned, todo = ns.Feats:Rows(fid)
    if todo > 0 then
        p.count:SetText(string.format("%d of %d earned", earned, earned + todo))
    else
        p.count:SetText(string.format("%d earned", earned))
    end
    p.offset = math.max(0, math.min(p.offset or 0, #rows - FEAT_ROWS))
    for i, row in ipairs(p.rows) do
        local a = rows[i + p.offset]
        row.feat = a
        if a then
            local c = row.cells
            local kind = a.category == "raid" and "Raid" or "Dungeon"
            if a.t then
                c.title:SetText("|cffffd100" .. ns.Escape(a.title) .. "|r")
                c.type:SetText(kind)
                c.date:SetText(date("%b %d, %Y", a.t))
                c.with:SetText(ns.Feats.JoinNames(a.members, true))
            else
                c.title:SetText(GREY .. ns.Escape(a.title) .. "|r")
                c.type:SetText(GREY .. kind .. "|r")
                c.date:SetText(GREY .. "Not yet|r")
                c.with:SetText("")
            end
            row:Show()
        else
            row:Hide()
        end
    end
    if #rows == 0 then
        p.rows[1].cells.title:SetText(GREY .. "No Fellowship Achievements yet.|r")
        for _, k in ipairs({ "type", "date", "with" }) do p.rows[1].cells[k]:SetText("") end
        p.rows[1]:Show()
    end
end

function UI:ShowFeatTooltip(owner, a)
    if not GameTooltip then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ns.Escape(a.title), 1, 0.82, 0)
    if a.t then
        GameTooltip:AddLine((a.category == "raid" and "Cleared " or "Completed ") .. date("%b %d, %Y at %H:%M", a.t), 1, 1, 1)
        if #a.members > 0 then
            GameTooltip:AddLine("With " .. ns.Feats.JoinNames(a.members, false), 0.8, 0.8, 0.8, true)
        end
    else
        GameTooltip:AddLine((a.category == "raid" and "Clear" or "Complete")
            .. " it with a group made up only of fellowship members.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

function UI:ShowMemberTooltip(owner, m)
    if not GameTooltip then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(m.online and ns.ColorName(m.name) or ns.Short(m.main))
    GameTooltip:AddLine(m.roleLabel, 1, 0.82, 0)
    if m.online and (m.level or m.zone) then
        GameTooltip:AddLine((m.level and ("Level " .. m.level .. "  ") or "") .. (m.zone or ""), 1, 1, 1)
    elseif not m.online then
        GameTooltip:AddLine("Last online " .. (m.seen and ns.Ago(m.seen) or "unknown"), 0.6, 0.6, 0.6)
    end
    if #m.chars > 1 then
        local names = {}
        for _, n in ipairs(m.chars) do names[#names + 1] = ns.Short(n) end
        table.sort(names)
        GameTooltip:AddLine("Characters: " .. table.concat(names, ", "), 0.8, 0.8, 0.8, true)
    end
    GameTooltip:AddLine("Member since " .. date("%b %d, %Y", m.since), 0.8, 0.8, 0.8)
    GameTooltip:AddLine(m.achievements .. " achievement" .. (m.achievements == 1 and "" or "s") .. " shared", 0.8, 0.8, 0.8)
    if not m.isMe then GameTooltip:AddLine("Right-click for options", 0.5, 0.5, 0.5) end
    GameTooltip:Show()
end

-- Right-click a member: whisper/invite to group, plus role and removal options for the Admin.
function UI:MemberMenuItems(m)
    local items = {}
    if m.isMe then return items end
    local target = ns.Short(m.online and m.name or m.main)
    if m.online then
        items[#items + 1] = { "Whisper", function()
            local tell = (ChatFrameUtil and ChatFrameUtil.SendTell) or ChatFrame_SendTell
            if tell then tell(target) end
        end }
        items[#items + 1] = { "Invite to Group", function()
            local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
            if invite then invite(target) end
        end }
    end
    local fid = ns.Store:ActiveId()
    if fid and ns.Store:IsAdmin(fid, ns.me) then
        if m.role == "member" then
            items[#items + 1] = { "Make Inviter", function() ns.Sync:SetRole(m.main, "inviter") end }
        elseif m.role == "inviter" then
            items[#items + 1] = { "Make Member", function() ns.Sync:SetRole(m.main, "member") end }
        end
        items[#items + 1] = { "Pass Admin", function() ns.Sync:OfferAdmin(m.main) end }
        items[#items + 1] = { "Remove from Fellowship", function()
            StaticPopup_Show("FELLOWSHIP_REMOVE", ns.Short(m.main), nil, m.main)
        end }
    end
    return items
end

function UI:OpenMemberMenu(owner, m)
    local items = self:MemberMenuItems(m)
    if #items == 0 or not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(ns.Short(m.online and m.name or m.main))
        for _, item in ipairs(items) do root:CreateButton(item[1], item[2]) end
    end)
end

function UI:Refresh()
    if not frame or not frame:IsShown() then return end
    for _, p in pairs(panels) do p:Hide() end
    local f, fid = ns.Store:Active()
    if not f then
        frame.title:SetText("Fellowship")
        for _, b in pairs(tabButtons) do b:Hide() end
        panels.none:Show()
        return
    end
    for name, b in pairs(tabButtons) do
        b:Show()
        if name == activeTab then b:Disable() else b:Enable() end
    end
    local members, onlineCount = ns.Sync:MemberList(fid) -- same count as the Members tab (includes you)
    frame.title:SetText(ns.Escape(f.name) .. (f.pendingFrom and "  (joining...)" or
        string.format("  |cff808080(%d of %d online)|r", onlineCount, #members)))

    local p = panels[activeTab]
    p:Show()
    if activeTab == "chat" then
        renderFeed(p.log, fid, function(e) return ns.Announce.ShouldShow(e) end)
        renderSidebar(p, fid)
    elseif activeTab == "achievements" then
        renderFeed(p.log, fid, function(e) return (e.k == "A" or e.k == "M") and ns.Announce.ShouldShow(e) end)
    elseif activeTab == "feats" then
        renderFeats(p, fid)
    else
        renderMembers(p, fid)
    end
end
