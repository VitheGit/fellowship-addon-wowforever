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

-- Achievements tab: dungeon/raid cards, two per row like the game's dungeon picker
local CARD_W, CARD_H, CARD_GAP, CARD_ROWS = 310, 100, 8, 3
local GREEN, RED = "|cff40ff40", "|cffff3333"
local rosterSort = { key = "default", reverse = false }
local RANK_ORDER = { admin = 1, inviter = 2, member = 3 }
local GREY = "|cff808080"
local WISH_ROWS, WISH_ROW_H = 14, 20
-- Wishlist columns: { x, width } for My Wishlist and Fellowship Wishes
local WISH_COLS = {
    mine = { { 24, 250, "Item" }, { 278, 100, "Kind" }, { 382, 70, "Have" }, { 456, 170, "Note" } },
    all = { { 24, 250, "Item" }, { 278, 350, "Wanted by" } },
}

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

-- The template's X button closes through the game's panel manager (HideUIPanel), which is
-- blocked for addons during combat. Hide the frame directly instead, so X works in combat.
local function fixCloseButton(f)
    local close = f.CloseButton or (f.GetName and f:GetName() and _G[f:GetName() .. "CloseButton"])
    if type(close) == "table" and close.SetScript then
        close:SetScript("OnClick", function() f:Hide() end)
    end
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
    fixCloseButton(frame)
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
        { "members", "Members" }, { "wishlist", "Wishlist" } }
    for i, t in ipairs(tabs) do
        local b = makeButton(frame, t[2], 98, function() UI:SelectTab(t[1]) end)
        b:SetPoint("TOPLEFT", 12 + (i - 1) * 101, -28)
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

    -- Achievements: Fellowship Achievements, with Dungeons and Raids sub-tabs
    local feats = panel()
    feats.category = "dungeon"
    feats.subTabs = {}
    for i, t in ipairs({ { "dungeon", "Dungeons" }, { "raid", "Raids" } }) do
        local b = makeButton(feats, t[2], 100, function()
            feats.category = t[1]
            feats.offset = 0
            UI:Refresh()
        end)
        b:SetPoint("TOPLEFT", 4 + (i - 1) * 104, -2)
        feats.subTabs[t[1]] = b
    end
    feats.count = feats:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    feats.count:SetPoint("TOPRIGHT", -8, -6)
    feats.cards = {}
    for i = 1, CARD_ROWS * 2 do
        local col, rowN = (i - 1) % 2, math.floor((i - 1) / 2)
        local card = CreateFrame("Button", nil, feats)
        card:SetSize(CARD_W, CARD_H)
        card:SetPoint("TOPLEFT", 4 + col * (CARD_W + CARD_GAP), -30 - rowN * (CARD_H + CARD_GAP))
        card.fill = card:CreateTexture(nil, "BACKGROUND")
        card.fill:SetAllPoints()
        card.fill:SetColorTexture(0.12, 0.09, 0.06, 1)
        card.art = card:CreateTexture(nil, "BORDER")
        card.art:SetPoint("TOPLEFT", 2, -2)
        card.art:SetPoint("BOTTOMRIGHT", -2, 2)
        -- darker band along the top so the name and status stay readable on any picture
        card.band = card:CreateTexture(nil, "ARTWORK")
        card.band:SetPoint("TOPLEFT", 2, -2)
        card.band:SetPoint("TOPRIGHT", -2, -2)
        card.band:SetHeight(32)
        card.band:SetColorTexture(0, 0, 0, 0.45)
        card.shade = card:CreateTexture(nil, "ARTWORK")
        card.shade:SetPoint("BOTTOMLEFT", 2, 2)
        card.shade:SetPoint("BOTTOMRIGHT", -2, 2)
        card.shade:SetHeight(22)
        card.shade:SetColorTexture(0, 0, 0, 0.4)
        -- thin gold-brown frame
        for _, edge in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, 2 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 2 },
                { "TOPLEFT", "BOTTOMLEFT", 2, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 2, nil } }) do
            local t = card:CreateTexture(nil, "OVERLAY")
            t:SetPoint(edge[1]); t:SetPoint(edge[2])
            if edge[3] then t:SetWidth(edge[3]) else t:SetHeight(edge[4]) end
            t:SetColorTexture(0.45, 0.33, 0.16, 1)
        end
        card.name = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        card.name:SetPoint("TOPLEFT", 12, -9)
        card.name:SetPoint("RIGHT", card, "RIGHT", -180, 0)
        card.name:SetJustifyH("LEFT")
        card.name:SetWordWrap(false)
        card.status = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        card.status:SetPoint("TOPRIGHT", -10, -11)
        card.status:SetJustifyH("RIGHT")
        card.check = card:CreateTexture(nil, "OVERLAY")
        card.check:SetSize(18, 18)
        card.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
        card.check:SetPoint("RIGHT", card.status, "LEFT", -4, 0)
        card.level = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.level:SetPoint("BOTTOMLEFT", 12, 7)
        card.with = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.with:SetPoint("BOTTOMRIGHT", -10, 7)
        card.with:SetPoint("LEFT", card, "LEFT", 90, 0)
        card.with:SetJustifyH("RIGHT")
        card.with:SetWordWrap(false)
        card.glow = card:CreateTexture(nil, "HIGHLIGHT")
        card.glow:SetPoint("TOPLEFT", 2, -2)
        card.glow:SetPoint("BOTTOMRIGHT", -2, 2)
        card.glow:SetColorTexture(1, 1, 1, 0.08)
        card:SetScript("OnEnter", function(self) if self.card then UI:ShowFeatTooltip(self, self.card) end end)
        card:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        card:Hide()
        feats.cards[i] = card
    end
    feats.empty = feats:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    feats.empty:SetPoint("CENTER", 0, -10)
    feats.empty:SetWidth(460)
    feats.offset = 0 -- in rows of two cards
    feats:EnableMouseWheel(true)
    feats:SetScript("OnMouseWheel", function(_, delta)
        feats.offset = math.max(0, feats.offset - delta)
        UI:Refresh()
    end)
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

    -- Wishlist: my list (editable) and everyone's, grouped by item
    local wl = panel()
    wl.view = "mine"
    wl.subTabs = {}
    for i, t in ipairs({ { "mine", "My Wishlist" }, { "all", "Fellowship Wishes" } }) do
        local b = makeButton(wl, t[2], 130, function()
            wl.view = t[1]
            wl.offset = 0
            UI:Refresh()
        end)
        b:SetPoint("TOPLEFT", 4 + (i - 1) * 134, -2)
        wl.subTabs[t[1]] = b
    end
    wl.count = wl:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    wl.count:SetPoint("TOPRIGHT", -8, -8)
    wl.cols = {}
    for i = 1, 4 do
        local fs = wl:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetJustifyH("LEFT")
        wl.cols[i] = fs
    end
    wl.rows = {}
    for i = 1, WISH_ROWS do
        local row = CreateFrame("Button", nil, wl)
        row:SetPoint("TOPLEFT", 4, -46 - (i - 1) * WISH_ROW_H)
        row:SetPoint("RIGHT", wl, "RIGHT", -4, 0)
        row:SetHeight(WISH_ROW_H)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        if i % 2 == 0 then
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(1, 1, 1, 0.03)
        end
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(WISH_ROW_H - 2, WISH_ROW_H - 2)
        row.icon:SetPoint("LEFT", 2, 0)
        row.cells = {}
        for c = 1, 4 do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            row.cells[c] = fs
        end
        row:SetScript("OnEnter", function(self)
            if not self.wish or not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. self.wish.id)
            if self.wish.note then GameTooltip:AddLine("Note: " .. ns.Escape(self.wish.note), 1, 0.82, 0, true) end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        row:SetScript("OnReceiveDrag", function() if wl.dropItem then wl.dropItem() end end)
        row:SetScript("OnClick", function(self, button)
            if wl.dropItem and wl.dropItem() then return end
            if not self.wish then return end
            if button == "RightButton" and self.mine then
                UI:OpenWishMenu(self, self.wish)
            elseif IsShiftKeyDown() then
                local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
                if insert then insert(ns.Wishlist.Link(self.wish)) end
            end
        end)
        row:Hide()
        wl.rows[i] = row
    end
    wl.offset = 0
    wl:EnableMouseWheel(true)
    wl:SetScript("OnMouseWheel", function(_, delta)
        wl.offset = math.max(0, wl.offset - delta * 3)
        UI:Refresh()
    end)
    wl.empty = wl:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    wl.empty:SetPoint("CENTER", 0, 0)
    wl.empty:SetWidth(520)
    local function addFromBox()
        local text = wl.input:GetText()
        -- typed a name: take the top suggestion
        local top = wl.suggest and wl.suggest:IsShown() and wl.suggest.results and wl.suggest.results[1]
        if top and not text:find("|H", 1, true) then
            wl.input:SetText("")
            wl.suggest:Hide()
            ns.Wishlist:AddAndSay(top.id)
            return
        end
        wl.input:SetText("")
        if ns.Trim(text) ~= "" then
            local item, want, note = ns.Wishlist.ParseCommand(text)
            ns.Wishlist:AddAndSay(item, want, note)
        end
    end
    wl.input = makeInput(wl, 255, function() end)
    wl.input:SetScript("OnEnterPressed", function(self) addFromBox(); self:ClearFocus() end)
    wl.input:SetPoint("BOTTOMLEFT", 40, 4)
    wl.input:SetWidth(250)
    -- drag an item from your bags onto the box (or the Add button)
    local function dropItem()
        if not GetCursorInfo then return end
        local kind, _, link = GetCursorInfo() -- (not "GetCursorInfo and GetCursorInfo()": that keeps one value)
        if kind == "item" and link then
            if ClearCursor then ClearCursor() end
            ns.Wishlist:AddAndSay(link)
            return true
        end
    end
    wl.dropItem = dropItem
    -- suggestions while typing: "ore" -> Copper Ore, Iron Ore...
    local SUGGEST_ROWS = 10
    local sug = CreateFrame("Frame", nil, wl, BackdropTemplateMixin and "BackdropTemplate" or nil)
    sug:SetPoint("BOTTOMLEFT", wl.input, "TOPLEFT", -6, 2)
    sug:SetSize(320, SUGGEST_ROWS * 18 + 28)
    sug:SetFrameStrata("DIALOG")
    local sbg = sug:CreateTexture(nil, "BACKGROUND")
    sbg:SetAllPoints()
    sbg:SetColorTexture(0.05, 0.05, 0.05, 0.95)
    sug.rows = {}
    for i = 1, SUGGEST_ROWS do
        local b = CreateFrame("Button", nil, sug)
        b:SetSize(310, 18)
        b:SetPoint("BOTTOMLEFT", 5, 22 + (i - 1) * 18) -- best match nearest the box
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(16, 16)
        b.icon:SetPoint("LEFT", 2, 0)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", 22, 0)
        b.text:SetPoint("RIGHT", -4, 0)
        b.text:SetJustifyH("LEFT")
        b.text:SetWordWrap(false)
        b:SetScript("OnClick", function(self)
            if not self.hit then return end
            wl.input:SetText("")
            sug:Hide()
            ns.Wishlist:AddAndSay(self.hit.id)
        end)
        b:SetScript("OnEnter", function(self)
            if not self.hit or not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. self.hit.id)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        sug.rows[i] = b
    end
    sug.footer = sug:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sug.footer:SetPoint("BOTTOMLEFT", 8, 5)
    sug.footer:SetPoint("BOTTOMRIGHT", -8, 5)
    sug.footer:SetJustifyH("LEFT")
    sug:Hide()
    wl.suggest = sug
    wl.input:SetScript("OnTextChanged", function(self, userInput)
        UI:UpdateSuggestions(self:GetText())
    end)
    wl.input:SetScript("OnEscapePressed", function(self) sug:Hide(); self:ClearFocus() end)
    wl.input:SetScript("OnReceiveDrag", dropItem)
    wl.input:SetScript("OnMouseDown", dropItem)
    -- an empty item slot to drop items on, and the whole tab accepts a dropped item too
    wl.slot = CreateFrame("Button", nil, wl)
    wl.slot:SetSize(26, 26)
    wl.slot:SetPoint("BOTTOMLEFT", 6, 2)
    wl.slot.tex = wl.slot:CreateTexture(nil, "ARTWORK")
    wl.slot.tex:SetAllPoints()
    wl.slot.tex:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
    wl.slot:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    wl.slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    wl.slot:SetScript("OnReceiveDrag", dropItem)
    wl.slot:SetScript("OnClick", dropItem)
    wl.slot:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Drop an item here to add it")
        GameTooltip:AddLine("Or shift-click any item while this tab is open.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    wl.slot:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    wl:EnableMouse(true)
    wl:SetScript("OnReceiveDrag", dropItem)
    wl:SetScript("OnMouseDown", dropItem)
    wl.add = makeButton(wl, "Add", 70, function() if not dropItem() then addFromBox() end end)
    wl.add:SetScript("OnReceiveDrag", dropItem)
    wl.add:SetPoint("LEFT", wl.input, "RIGHT", 6, 0)
    wl.hint = wl:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    wl.hint:SetPoint("LEFT", wl.add, "RIGHT", 10, 0)
    wl.hint:SetPoint("RIGHT", wl, "RIGHT", -6, 0)
    wl.hint:SetJustifyH("LEFT")
    wl.hint:SetText("Shift-click any item while this tab is open, or drop it on the slot. Right-click a row to change it.")
    panels.wishlist = wl

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
    -- Wishlist tab open: shift-clicking an item (bags, chat links, loot, vendors) adds it, instead of
    -- splitting the stack. Typing in a chat box still gets the link as usual.
    local suppressSplit = 0
    local function onModifiedItemClick(link)
        local wl = panels.wishlist
        if type(link) ~= "string" or not link:find("item:", 1, true) then return end
        if not (wl and wl:IsShown() and frame and frame:IsShown()) then return end
        if IsModifiedClick and not IsModifiedClick("CHATLINK") then return end
        local active = (ChatFrameUtil and ChatFrameUtil.GetActiveWindow and ChatFrameUtil.GetActiveWindow())
            or (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow())
        local focused = wl.input.HasFocus and wl.input:HasFocus()
        if active and not focused then return end
        suppressSplit = GetTime() + 0.5
        ns.Wishlist:AddAndSay(link)
        -- the bag opens the stack splitter after this; close it
        C_Timer.After(0, function()
            if StackSplitFrame and StackSplitFrame.IsShown and StackSplitFrame:IsShown() then StackSplitFrame:Hide() end
        end)
    end
    if hooksecurefunc then
        if ChatFrameUtil and ChatFrameUtil.InsertLink then
            hooksecurefunc(ChatFrameUtil, "InsertLink", insertLink)
        elseif ChatEdit_InsertLink then
            hooksecurefunc("ChatEdit_InsertLink", insertLink)
        end
        if HandleModifiedItemClick then hooksecurefunc("HandleModifiedItemClick", onModifiedItemClick) end
        if StackSplitFrame and StackSplitFrame.OpenStackSplitFrame then
            hooksecurefunc(StackSplitFrame, "OpenStackSplitFrame", function(self)
                if GetTime() < suppressSplit then self:Hide() end
            end)
        elseif OpenStackSplitFrame then
            hooksecurefunc("OpenStackSplitFrame", function()
                if GetTime() < suppressSplit and StackSplitFrame then StackSplitFrame:Hide() end
            end)
        end
    end
    StaticPopupDialogs["FELLOWSHIP_WISH_AMOUNT"] = {
        text = "How many %s do you want? Friends see your count and when you're stocked. (0 = no amount)",
        button1 = ACCEPT or "Accept",
        button2 = CANCEL or "Cancel",
        hasEditBox = true,
        OnShow = function(self, data)
            local eb = self.editBox or self.EditBox
            local e = ns.Wishlist:Find(data)
            if eb then eb:SetText(e and e.want and e.want > 0 and tostring(e.want) or "") end
        end,
        OnAccept = function(self, data)
            local eb = self.editBox or self.EditBox
            if eb then ns.Wishlist:SetWant(data, eb:GetText()) end
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            ns.Wishlist:SetWant(parent.data, self:GetText())
            parent:Hide()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    StaticPopupDialogs["FELLOWSHIP_WISH_NOTE"] = {
        text = "Note for %s (friends see it on your wishlist):",
        button1 = ACCEPT or "Accept",
        button2 = CANCEL or "Cancel",
        hasEditBox = true,
        maxLetters = ns.Wishlist.MAX_NOTE,
        OnShow = function(self, data)
            local eb = self.editBox or self.EditBox
            local e = ns.Wishlist:Find(data)
            if eb then eb:SetText(e and e.note or "") end
        end,
        OnAccept = function(self, data)
            local eb = self.editBox or self.EditBox
            if eb then ns.Wishlist:SetNote(data, eb:GetText()) end
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            ns.Wishlist:SetNote(parent.data, self:GetText())
            parent:Hide()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    local function queue() UI:QueueRefresh() end
    ns.Listen("WISHLIST_CHANGED", queue)
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
    fixCloseButton(f)
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

function UI.WishlistPanelForTest() return panels.wishlist end

function UI:UpdateSuggestions(text)
    local wl = panels.wishlist
    local sug = wl and wl.suggest
    if not sug then return end
    text = tostring(text or "")
    if text:find("|H", 1, true) or #ns.Trim(text) < 2 then sug:Hide(); return end
    local results, total = ns.ItemSearch:Search(text, #sug.rows)
    sug.results = results
    local progress = ns.ItemSearch:Progress()
    if #results == 0 then
        sug.footer:SetText(progress and ("No match yet. Still learning items (" .. progress .. "%).")
            or "No items match. Shift-click the item instead.")
    else
        local more = (total or 0) > #results and (#results .. " of " .. total .. " matches. ") or ""
        sug.footer:SetText(more .. "Click one to add it, or press Enter for the top one."
            .. (progress and (" Learning items " .. progress .. "%.") or ""))
    end
    local GetColor = function(q)
        local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
        return (c and c.hex) or "|cffffffff"
    end
    for i, b in ipairs(sug.rows) do
        local h = results[i]
        b.hit = h
        if h then
            local fn = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
            b.icon:SetTexture((fn and fn(h.id)) or "Interface\\Icons\\INV_Misc_QuestionMark")
            b.text:SetText(GetColor(h.quality) .. ns.Escape(h.name) .. "|r")
            b:Show()
        else
            b:Hide()
        end
    end
    sug:Show()
end

function UI:Show(tab)
    self:Build()
    if tab then activeTab = tab end
    if frame:IsShown() then self:Refresh() else frame:Show() end
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

-- Show a picture cropped (not stretched) to fill the card.
local function setArt(tex, card)
    -- Dungeon Finder picture first, then the Encounter Journal's; SetTexture returns false
    -- when the game has no such file, so a wrong guess just falls through to the next one
    local tries = {}
    if card.art then tries[#tries + 1] = { card.art, 1, 1, 2 } end
    if card.ejArt then tries[#tries + 1] = { card.ejArt, 0.68359375, 0.7421875, 174 / 95 } end
    for _, t in ipairs(tries) do
        if tex:SetTexture(t[1]) ~= false then
            local w, h = CARD_W - 4, CARD_H - 4
            -- both pictures are less wide than a card: trim top and bottom instead of stretching
            local keep = math.min(1, t[4] / (w / h))
            local top = (1 - keep) / 2
            tex:SetTexCoord(0, t[2], top * t[3], (top + keep) * t[3])
            tex:Show()
            return
        end
    end
    tex:Hide()
end

local function renderFeats(p, fid)
    for cat, b in pairs(p.subTabs) do
        if cat == p.category then b:Disable() else b:Enable() end
    end
    local cards, completed = ns.Feats:Cards(fid, p.category)
    p.count:SetText(string.format("%d / %d completed", completed, #cards))
    local rows = math.ceil(#cards / 2)
    p.offset = math.max(0, math.min(p.offset or 0, rows - CARD_ROWS))
    for i, f in ipairs(p.cards) do
        local c = cards[i + p.offset * 2]
        f.card = c
        if c then
            setArt(f.art, c)
            f.name:SetText(ns.Escape(c.name))
            if c.minLevel and c.maxLevel and c.maxLevel > 0 then
                f.level:SetText(c.minLevel == c.maxLevel and ("LV " .. c.minLevel)
                    or ("LV " .. c.minLevel .. "-" .. c.maxLevel))
            else
                f.level:SetText("")
            end
            if c.done then
                f.status:SetText(GREEN .. "Completed: " .. date("%b %d, %Y", c.done.t) .. "|r")
                f.check:Show()
                f.art:SetVertexColor(1, 1, 1)
                f.with:SetText(ns.Feats.JoinNames(c.done.members, true))
            else
                f.status:SetText(RED .. "Incomplete|r")
                f.check:Hide()
                f.art:SetVertexColor(0.7, 0.7, 0.7) -- not done yet: a little dimmer
                f.with:SetText("")
            end
            f:Show()
        else
            f:Hide()
        end
    end
    if #cards == 0 then
        p.empty:SetText(p.category == "raid" and "No raids to show yet." or "No dungeons to show yet.")
        p.empty:Show()
    else
        p.empty:Hide()
    end
end

function UI:ShowFeatTooltip(owner, c)
    if not GameTooltip then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ns.Escape(c.name), 1, 0.82, 0)
    if c.done then
        GameTooltip:AddLine((c.category == "raid" and "Cleared " or "Completed ")
            .. date("%b %d, %Y at %H:%M", c.done.t), 0.25, 1, 0.25)
        GameTooltip:AddLine("Difficulty: " .. table.concat(c.done.difficulties, ", "), 1, 1, 1)
        if #c.done.members > 0 then
            GameTooltip:AddLine("With " .. ns.Feats.JoinNames(c.done.members, false), 0.8, 0.8, 0.8, true)
        end
    else
        GameTooltip:AddLine("Incomplete", 1, 0.2, 0.2)
        GameTooltip:AddLine((c.category == "raid" and "Clear" or "Complete")
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

local function wishKind(e)
    if e.mode == "always" then return "|cff66ccffAlways wanted|r" end
    return "One-time"
end

local function placeColumns(p, cols)
    for i, fs in ipairs(p.cols) do
        local c = cols[i]
        if c then
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", c[1] + 4, -30)
            fs:SetText(c[3])
            fs:Show()
        else
            fs:Hide()
        end
    end
    for _, row in ipairs(p.rows) do
        for i, fs in ipairs(row.cells) do
            local c = cols[i]
            if c then
                fs:ClearAllPoints()
                fs:SetPoint("LEFT", c[1], 0)
                fs:SetWidth(c[2] - 6)
                fs:Show()
            else
                fs:Hide()
            end
        end
    end
end

local function itemIcon(id)
    local fn = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
    return (fn and fn(id)) or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function renderWishlist(p, fid)
    local W = ns.Wishlist
    for view, b in pairs(p.subTabs) do
        if view == p.view then b:Disable() else b:Enable() end
    end
    placeColumns(p, WISH_COLS[p.view])
    local rows = {}
    if p.view == "mine" then
        for _, e in ipairs(W:Mine()) do
            local have = ""
            if e.mode == "always" then
                if W.Stocked(e) then have = "|cff33ff99" .. e.have .. "/" .. e.want .. "|r"
                elseif (e.want or 0) > 0 then have = e.have .. "/" .. e.want
                else have = tostring(e.have or 0) end
            end
            rows[#rows + 1] = { wish = e, mine = true, cells = { W.Link(e), wishKind(e) .. (e.notify and " |cffffd100(ping)|r" or ""),
                have, e.note and (GREY .. ns.Escape(e.note) .. "|r") or "" } }
        end
        p.count:SetText(#rows .. " / " .. W.MAX_ITEMS .. " items")
        p.empty:SetText("Your wishlist is empty.\n\nShift-click an item into the box below, or drag one from your bags,\n"
            .. "and your fellowship will see it in the item's tooltip.")
    else
        local byItem, order = {}, {}
        for _, l in ipairs(W:AllLists(fid)) do
            for _, e in ipairs(l.items) do
                local g = byItem[e.id]
                if not g then g = { wish = e, names = {} }; byItem[e.id] = g; order[#order + 1] = g end
                local prog = W.Progress(e)
                g.names[#g.names + 1] = ns.ColorName(l.name) .. (prog ~= "" and (GREY .. " (" .. prog .. ")|r") or "")
            end
        end
        table.sort(order, function(a, b) return (a.wish.name or "") < (b.wish.name or "") end)
        for _, g in ipairs(order) do
            rows[#rows + 1] = { wish = g.wish, mine = false, cells = { W.Link(g.wish), table.concat(g.names, ", ") } }
        end
        p.count:SetText(#rows .. " items wanted")
        p.empty:SetText("Nobody in your fellowship has a wishlist yet.")
    end
    if #rows == 0 then p.empty:Show() else p.empty:Hide() end
    p.offset = math.max(0, math.min(p.offset or 0, #rows - WISH_ROWS))
    for i, row in ipairs(p.rows) do
        local r = rows[i + p.offset]
        row.wish, row.mine = r and r.wish, r and r.mine
        if r then
            row.icon:SetTexture(itemIcon(r.wish.id))
            for c, fs in ipairs(row.cells) do fs:SetText(r.cells[c] or "") end
            row:Show()
        else
            row:Hide()
        end
    end
end

function UI:WishMenuItems(e)
    local W, id = ns.Wishlist, e.id
    local items = {}
    if e.mode == "always" then
        items[#items + 1] = { "Make it a one-time wish", function() W:SetMode(id, "once") end }
        items[#items + 1] = { "Set amount wanted...", function()
            StaticPopup_Show("FELLOWSHIP_WISH_AMOUNT", e.name or "this item", nil, id)
        end }
        items[#items + 1] = { e.notify and "Stop pinging me when a member loots it" or "Ping me when a member loots it",
            function() W:SetNotify(id, not e.notify) end }
    else
        items[#items + 1] = { "Make it always wanted (materials)", function() W:SetMode(id, "always") end }
    end
    items[#items + 1] = { "Set note...", function() StaticPopup_Show("FELLOWSHIP_WISH_NOTE", e.name or "this item", nil, id) end }
    items[#items + 1] = { "Remove from Wishlist", function() W:Remove(id) end }
    return items
end

function UI:OpenWishMenu(owner, e)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    local items = self:WishMenuItems(e)
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(e.name or ("Item " .. e.id))
        for _, item in ipairs(items) do root:CreateButton(item[1], item[2]) end
    end)
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
    elseif activeTab == "wishlist" then
        renderWishlist(p, fid)
    else
        renderMembers(p, fid)
    end
end
