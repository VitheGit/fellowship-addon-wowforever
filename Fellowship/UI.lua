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
    local tabs = { { "chat", "Chat" }, { "achievements", "Achievements" }, { "members", "Members" } }
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

    -- Achievements
    local ach = panel()
    ach.log = makeLog(ach)
    ach.log:SetPoint("TOPLEFT", 4, -4)
    ach.log:SetPoint("BOTTOMRIGHT", -4, 4)
    panels.achievements = ach

    -- Members
    local mem = panel()
    mem.log = makeLog(mem)
    mem.log:SetPoint("TOPLEFT", 4, -4)
    mem.log:SetPoint("BOTTOMRIGHT", -4, 34)
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
    none.text:SetText("You're not in a fellowship yet.\n\nCreate one below and invite your friends with /fs invite <player>, "
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
        text = "%s invites you to join the fellowship \"%s\".",
        button1 = ACCEPT or "Accept",
        button2 = DECLINE or "Decline",
        OnAccept = function(_, data) ns.Sync:AcceptInvite(data) end,
        OnCancel = function(_, data, reason)
            if reason ~= "override" then ns.Sync:DeclineInvite(data) end
        end,
        timeout = 120,
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
    local function queue() UI:QueueRefresh() end
    ns.Listen("EVENTS_ADDED", queue)
    ns.Listen("PRESENCE", queue)
    ns.Listen("FELLOWSHIP_CHANGED", queue)
end

function UI:ShowInvite(data)
    StaticPopup_Show("FELLOWSHIP_INVITE", ns.Short(data.from), ns.Escape(data.name), data)
end

function UI:IsShown()
    return frame ~= nil and frame:IsShown()
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

local function line(e)
    return TIME_COLOR .. ns.TimeStamp(e.t) .. "|r  " .. ns.FormatEvent(e)
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
        log:AddMessage(line(e))
    end
    if #shown == 0 then
        log:AddMessage(TIME_COLOR .. "Nothing here yet.|r")
    end
    log:ScrollToBottom()
end

local function renderMembers(log, fid)
    log:Clear()
    local roster, founder = ns.Store:Roster(fid)
    local list = {}
    for key, m in pairs(roster) do list[#list + 1] = { key = key, name = m.name, since = m.since } end
    table.sort(list, function(a, b) return a.name < b.name end)
    local achievementCounts = {}
    for _, e in ipairs(ns.Store:Sorted(fid)) do
        if e.k == "A" then achievementCounts[e.a] = (achievementCounts[e.a] or 0) + 1 end
    end
    for _, m in ipairs(list) do
        local status
        if m.key == ns.meKey then status = "|cff33ff99you|r"
        elseif ns.online[m.key] then status = "|cff33ff99online|r"
        else status = "|cff9d9d9doffline|r" end
        local last = ns.Store:LastActive(fid, m.name)
        log:AddMessage(string.format("%s%s  %s   |cff808080member since %s, %d achievements shared%s|r",
            ns.ColorName(m.name), m.name == founder and " (founder)" or "", status,
            date("%b %d %Y", m.since), achievementCounts[m.name] or 0,
            last and (", last active " .. ns.TimeStamp(last)) or ""))
    end
    log:ScrollToTop()
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
    local onlineCount = 0
    for key in pairs(ns.Store:Roster(fid)) do
        if key ~= ns.meKey and ns.online[key] then onlineCount = onlineCount + 1 end
    end
    frame.title:SetText(ns.Escape(f.name) .. (f.pendingFrom and "  (joining...)" or
        string.format("  |cff808080(%d online)|r", onlineCount)))

    local p = panels[activeTab]
    p:Show()
    if activeTab == "chat" then
        renderFeed(p.log, fid, function() return true end)
    elseif activeTab == "achievements" then
        renderFeed(p.log, fid, function(e) return e.k == "A" or e.k == "M" end)
    else
        renderMembers(p.log, fid)
    end
end
