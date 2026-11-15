-- CalendarUI: the Calendar tab (month view, day/upcoming list, event details with sign-up
-- buttons) and the New/Edit Event window.
local _, ns = ...
local UI = ns.UI
local C = ns.Calendar

local GREY = "|cff808080"
local CELL_W, CELL_H, CELL_GAP = 40, 38, 2
local LIST_ROWS, ROW_H = 8, 20
local LIST_X = 304
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function today()
    local t = date("*t", ns.Now())
    return t.year, t.month, t.day
end

local function daysIn(y, m)
    local t = date("*t", time({ year = y, month = m + 1, day = 0, hour = 12 }))
    return t.day
end

local function weekdayOf(y, m, d) -- 1 = Sunday
    return date("*t", time({ year = y, month = m, day = d, hour = 12 })).wday
end

local function text(parent, font, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

local function menu(owner, title, items)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        if root.SetScrollMode then root:SetScrollMode(360) end
        if title then root:CreateTitle(title) end
        for _, item in ipairs(items) do root:CreateButton(item[1], item[2]) end
    end)
end

---------------------------------------------------------------------------
-- Calendar tab
---------------------------------------------------------------------------
function UI:BuildCalendar(p, makeButton, makeInput)
    local y, m = today()
    p.year, p.month = y, m
    -- view state lives in its own table (fields on a frame could clash with frame methods)
    p.st = { selected = nil, eventKey = nil } -- selected: { y, m, d }, or nil for "Upcoming"

    p.prev = makeButton(p, "<", 28, function()
        p.month = p.month - 1
        if p.month < 1 then p.month, p.year = 12, p.year - 1 end
        UI:Refresh()
    end)
    p.prev:SetPoint("TOPLEFT", 4, -2)
    p.next = makeButton(p, ">", 28, function()
        p.month = p.month + 1
        if p.month > 12 then p.month, p.year = 1, p.year + 1 end
        UI:Refresh()
    end)
    p.next:SetPoint("TOPLEFT", 7 * (CELL_W + CELL_GAP) - 28, -2)
    p.monthLabel = text(p, "GameFontNormalLarge", "CENTER")
    p.monthLabel:SetPoint("TOP", p, "TOPLEFT", 7 * (CELL_W + CELL_GAP) / 2, -6)
    for i, wd in ipairs(WEEKDAYS) do
        local fs = text(p, "GameFontNormalSmall", "CENTER")
        fs:SetPoint("TOPLEFT", 4 + (i - 1) * (CELL_W + CELL_GAP), -30)
        fs:SetWidth(CELL_W)
        fs:SetText(wd)
    end
    p.cells = {}
    for i = 1, 42 do
        local col, row = (i - 1) % 7, math.floor((i - 1) / 7)
        local cell = CreateFrame("Button", nil, p)
        cell:SetSize(CELL_W, CELL_H)
        cell:SetPoint("TOPLEFT", 4 + col * (CELL_W + CELL_GAP), -46 - row * (CELL_H + CELL_GAP))
        cell.bg = cell:CreateTexture(nil, "BACKGROUND")
        cell.bg:SetAllPoints()
        cell:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        cell.day = text(cell, "GameFontHighlightSmall", "LEFT")
        cell.day:SetPoint("TOPLEFT", 3, -3)
        cell.count = text(cell, "GameFontNormalSmall", "RIGHT")
        cell.count:SetPoint("BOTTOMRIGHT", -3, 3)
        cell:SetScript("OnClick", function(self)
            if not self.date then return end
            local s = p.st.selected
            if s and s[1] == self.date[1] and s[2] == self.date[2] and s[3] == self.date[3] then
                p.st.selected = nil -- click again: back to Upcoming
            else
                p.st.selected = self.date
            end
            p.st.eventKey, p.offset = nil, 0
            UI:Refresh()
        end)
        cell:SetScript("OnEnter", function(self)
            if not self.events or #self.events == 0 or not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            for _, ev in ipairs(self.events) do
                GameTooltip:AddLine(date("%I:%M %p", ev.time):gsub("^0", "") .. "  " .. C.Title(ev)
                    .. (ev.cancelled and " (cancelled)" or ""), 1, 1, 1)
            end
            GameTooltip:Show()
        end)
        cell:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        p.cells[i] = cell
    end

    p.new = makeButton(p, "New Event", 110, function()
        UI:OpenEventEditor(nil, p.st.selected)
    end)
    p.new:SetPoint("BOTTOMLEFT", 4, 4)
    p.upcomingButton = makeButton(p, "Upcoming", 90, function()
        p.st.selected, p.st.eventKey, p.offset = nil, nil, 0
        local ty, tm = today()
        p.year, p.month = ty, tm
        UI:Refresh()
    end)
    p.upcomingButton:SetPoint("LEFT", p.new, "RIGHT", 6, 0)

    -- right side: list of events
    p.listTitle = text(p, "GameFontNormal", "LEFT")
    p.listTitle:SetPoint("TOPLEFT", LIST_X, -6)
    p.rows = {}
    for i = 1, LIST_ROWS do
        local row = CreateFrame("Button", nil, p)
        row:SetPoint("TOPLEFT", LIST_X, -24 - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", p, "RIGHT", -4, 0)
        row:SetHeight(ROW_H)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(1, 0.82, 0, 0.12)
        row.when = text(row)
        row.when:SetPoint("LEFT", 4, 0)
        row.when:SetWidth(120)
        row.when:SetWordWrap(false)
        row.title = text(row)
        row.title:SetPoint("LEFT", 128, 0)
        row.title:SetPoint("RIGHT", -70, 0)
        row.title:SetWordWrap(false)
        row.going = text(row, "GameFontHighlightSmall", "RIGHT")
        row.going:SetPoint("RIGHT", -4, 0)
        row:SetScript("OnClick", function(self)
            if self.ev then p.st.eventKey = self.ev.key; UI:Refresh() end
        end)
        row:Hide()
        p.rows[i] = row
    end
    p.empty = text(p, "GameFontDisable", "LEFT")
    p.empty:SetPoint("TOPLEFT", LIST_X + 4, -30)
    p.empty:SetWidth(330)
    p.offset = 0
    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", function(_, delta)
        p.offset = math.max(0, (p.offset or 0) - delta * 2)
        UI:Refresh()
    end)

    -- event details
    local d = CreateFrame("Frame", nil, p)
    d:SetPoint("TOPLEFT", LIST_X, -30 - LIST_ROWS * ROW_H)
    d:SetPoint("BOTTOMRIGHT", -4, 4)
    local dbg = d:CreateTexture(nil, "BACKGROUND")
    dbg:SetAllPoints()
    dbg:SetColorTexture(1, 1, 1, 0.04)
    d.title = text(d, "GameFontNormalLarge")
    d.title:SetPoint("TOPLEFT", 8, -6)
    d.title:SetPoint("RIGHT", -8, 0)
    d.title:SetWordWrap(false)
    d.info = text(d, "GameFontHighlightSmall")
    d.info:SetPoint("TOPLEFT", d.title, "BOTTOMLEFT", 0, -4)
    d.info:SetPoint("RIGHT", -8, 0)
    d.info:SetJustifyV("TOP")
    d.going = text(d, "GameFontHighlightSmall")
    d.going:SetPoint("TOPLEFT", d.info, "BOTTOMLEFT", 0, -6)
    d.going:SetPoint("RIGHT", -8, 0)
    d.going:SetJustifyV("TOP")
    d.buttons = {}
    local x = 8
    for _, s in ipairs({ { "y", "Going" }, { "m", "Maybe" }, { "n", "Can't" } }) do
        local b = makeButton(d, s[2], 64, function()
            if p.st.eventKey then C:Respond(p.st.eventKey, s[1]) end
        end)
        b:SetPoint("BOTTOMLEFT", x, 6)
        b.status = s[1]
        d.buttons[#d.buttons + 1] = b
        x = x + 68
    end
    d.edit = makeButton(d, "Edit", 50, function()
        if p.st.eventKey then UI:OpenEventEditor(p.st.eventKey) end
    end)
    d.edit:SetPoint("BOTTOMRIGHT", -64, 6)
    d.cancel = makeButton(d, "Cancel", 56, function()
        if p.st.eventKey then StaticPopup_Show("FELLOWSHIP_CANCEL_EVENT", nil, nil, p.st.eventKey) end
    end)
    d.cancel:SetPoint("BOTTOMRIGHT", -6, 6)
    d:Hide()
    p.details = d

    StaticPopupDialogs["FELLOWSHIP_CANCEL_EVENT"] = {
        text = "Cancel this event? Everyone will see that it was cancelled.",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function(_, key) C:Cancel(key) end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    return p
end

function UI:RenderCalendar(p, fid)
    -- month grid
    local y, m = p.year, p.month
    p.monthLabel:SetText(date("%B %Y", time({ year = y, month = m, day = 1, hour = 12 })))
    local first = weekdayOf(y, m, 1)
    local n = daysIn(y, m)
    local ty, tm, td = today()
    local counts = {}
    for _, ev in ipairs(C:Events(fid)) do
        local t = date("*t", ev.time)
        if t.year == y and t.month == m then
            counts[t.day] = counts[t.day] or {}
            table.insert(counts[t.day], ev)
        end
    end
    for i, cell in ipairs(p.cells) do
        local day = i - first + 1
        if day >= 1 and day <= n then
            cell.date = { y, m, day }
            cell.events = counts[day]
            cell.day:SetText(tostring(day))
            local live = 0
            for _, ev in ipairs(counts[day] or {}) do if not ev.cancelled then live = live + 1 end end
            cell.count:SetText(live > 0 and ("|cffffd100" .. live .. (live == 1 and " event" or " events") .. "|r") or "")
            local s = p.st.selected
            if s and s[1] == y and s[2] == m and s[3] == day then
                cell.bg:SetColorTexture(1, 0.82, 0, 0.25)
            elseif y == ty and m == tm and day == td then
                cell.bg:SetColorTexture(0.3, 0.8, 1, 0.18)
            elseif live > 0 then
                cell.bg:SetColorTexture(1, 1, 1, 0.10)
            else
                cell.bg:SetColorTexture(1, 1, 1, 0.04)
            end
            cell:Show()
        else
            cell.date, cell.events = nil, nil
            cell:Hide()
        end
    end

    -- list
    local list
    if p.st.selected then
        local s = p.st.selected
        list = C:OnDay(s[1], s[2], s[3], fid)
        p.listTitle:SetText(date("%A, %B ", time({ year = s[1], month = s[2], day = s[3], hour = 12 })) .. s[3])
        p.empty:SetText("Nothing planned this day.\n\nClick New Event to plan something.")
    else
        list = C:Upcoming(fid)
        p.listTitle:SetText("Upcoming events")
        p.empty:SetText("Nothing planned yet.\n\nClick New Event (or a day, then New Event) to plan a dungeon run, a raid or anything else.")
    end
    if #list == 0 then p.empty:Show() else p.empty:Hide() end
    p.offset = math.max(0, math.min(p.offset or 0, #list - LIST_ROWS))
    if p.st.eventKey and not C:Get(p.st.eventKey, fid) then p.st.eventKey = nil end
    if not p.st.eventKey and list[1] then
        -- show the next event that isn't over, else the first
        p.st.eventKey = list[1].key
    end
    for i, row in ipairs(p.rows) do
        local ev = list[i + p.offset]
        row.ev = ev
        if ev then
            local my = C:MyStatus(ev)
            local mark = my == "y" and "|cff33ff99+|r " or my == "m" and "|cffffd100?|r " or my == "n" and "|cffff4040x|r " or "|cffff8040!|r "
            row.when:SetText(mark .. C.When(ev.time))
            row.title:SetText(C.Title(ev) .. (ev.cancelled and (GREY .. " (cancelled)|r") or ""))
            row.going:SetText(GREY .. #C:Answers(ev).y .. " going|r")
            if ev.key == p.st.eventKey then row.sel:Show() else row.sel:Hide() end
            row:Show()
        else
            row:Hide()
        end
    end

    -- details
    local d = p.details
    local ev = p.st.eventKey and C:Get(p.st.eventKey, fid)
    if not ev then d:Hide(); return end
    d:Show()
    d.title:SetText(C.Title(ev) .. (ev.cancelled and " |cffff4040(cancelled)|r" or ""))
    local info = date("%A, %B ", ev.time) .. date("*t", ev.time).day .. " at " .. date("%I:%M %p", ev.time):gsub("^0", "")
        .. "\n" .. C.TYPES[ev.type] .. ", planned by " .. ns.ColorName(ev.author)
    if ev.note then info = info .. "\n|cffffd100" .. ns.Escape(ev.note) .. "|r" end
    d.info:SetText(info)
    local a = C:Answers(ev)
    local function names(list)
        if #list == 0 then return GREY .. "nobody|r" end
        local out = {}
        for _, nm in ipairs(list) do out[#out + 1] = ns.ColorName(nm) end
        return table.concat(out, ", ")
    end
    local waiting = {}
    local answered = {}
    for _, key in ipairs({ "y", "m", "n" }) do
        for _, nm in ipairs(a[key]) do
            local mem = ns.Store:Roster(fid)[ns.Key(nm)]
            answered[mem and mem.account or ns.Key(nm)] = true
        end
    end
    local seenAcct = {}
    for _, mem in pairs(ns.Store:Roster(fid)) do
        if not answered[mem.account] and not seenAcct[mem.account] then
            seenAcct[mem.account] = true
            waiting[#waiting + 1] = mem.main
        end
    end
    table.sort(waiting)
    d.going:SetText("|cff33ff99Going (" .. #a.y .. "):|r " .. names(a.y)
        .. "\n|cffffd100Maybe (" .. #a.m .. "):|r " .. names(a.m)
        .. "\n|cffff4040Can't (" .. #a.n .. "):|r " .. names(a.n)
        .. (#waiting > 0 and ("\n" .. GREY .. "No answer yet: " .. table.concat((function()
            local t = {}
            for _, nm in ipairs(waiting) do t[#t + 1] = ns.Short(nm) end
            return t
        end)(), ", ") .. "|r") or ""))
    local my = C:MyStatus(ev)
    for _, b in ipairs(d.buttons) do
        if ev.cancelled or b.status == my then b:Disable() else b:Enable() end
    end
    if C:CanEdit(ev.key) and not ev.cancelled then d.edit:Show(); d.cancel:Show() else d.edit:Hide(); d.cancel:Hide() end
end

---------------------------------------------------------------------------
-- New / Edit Event window
---------------------------------------------------------------------------
local editor

local function instances(category)
    local out = {}
    for _, inst in ipairs(ns.Feats:Catalog() or {}) do
        if inst.category == category then out[#out + 1] = inst end
    end
    table.sort(out, function(a, b)
        if (a.minLevel or 99) ~= (b.minLevel or 99) then return (a.minLevel or 99) < (b.minLevel or 99) end
        return a.name < b.name
    end)
    return out
end
UI.CalendarInstances = instances

function UI:BuildEventEditor(makeButton, makeInput)
    if editor then return editor end
    local f = CreateFrame("Frame", "FellowshipEventFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(380, 330)
    f:SetPoint("CENTER", 0, 40)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    table.insert(UISpecialFrames, "FellowshipEventFrame")
    local close = f.CloseButton or _G["FellowshipEventFrameCloseButton"]
    if type(close) == "table" and close.SetScript then close:SetScript("OnClick", function() f:Hide() end) end
    f.heading = text(f, "GameFontHighlight", "CENTER")
    f.heading:SetPoint("TOP", 0, -6)

    local function label(s, yy)
        local fs = text(f, "GameFontNormal")
        fs:SetPoint("TOPLEFT", 16, yy)
        fs:SetText(s)
        return fs
    end

    label("Type", -38)
    f.typeButtons = {}
    local x = 90
    for _, t in ipairs({ { "dungeon", "Dungeon" }, { "raid", "Raid" }, { "other", "Other" } }) do
        local b = makeButton(f, t[2], 84, function()
            f.state.type = t[1]
            if t[1] ~= "other" then f.state.title = "" end
            UI:RefreshEventEditor()
        end)
        b:SetPoint("TOPLEFT", x, -34)
        b.kind = t[1]
        f.typeButtons[#f.typeButtons + 1] = b
        x = x + 88
    end

    f.whatLabel = label("Where", -70)
    f.instance = makeButton(f, "Pick a dungeon...", 260, function(self)
        local items = {}
        for _, inst in ipairs(instances(f.state.type)) do
            local lv = inst.minLevel and (" |cff808080(" .. inst.minLevel .. (inst.maxLevel and inst.maxLevel ~= inst.minLevel
                and ("-" .. inst.maxLevel) or "") .. ")|r") or ""
            items[#items + 1] = { inst.name .. lv, function()
                f.state.title = inst.name
                UI:RefreshEventEditor()
            end }
        end
        menu(self, f.state.type == "raid" and "Raids" or "Dungeons", items)
    end)
    f.instance:SetPoint("TOPLEFT", 90, -66)
    f.titleInput = makeInput(f, C.MAX_TITLE, function() end)
    f.titleInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.titleInput:SetScript("OnTextChanged", function(self) f.state.title = self:GetText() end)
    f.titleInput:SetPoint("TOPLEFT", 96, -66)
    f.titleInput:SetWidth(254)

    label("Date", -106)
    f.dayPrev = makeButton(f, "<", 28, function() f.state.day = f.state.day - 1; UI:RefreshEventEditor() end)
    f.dayPrev:SetPoint("TOPLEFT", 90, -102)
    f.dateText = text(f, "GameFontHighlight", "CENTER")
    f.dateText:SetPoint("LEFT", f.dayPrev, "RIGHT", 4, 0)
    f.dateText:SetWidth(196)
    f.dayNext = makeButton(f, ">", 28, function() f.state.day = f.state.day + 1; UI:RefreshEventEditor() end)
    f.dayNext:SetPoint("LEFT", f.dateText, "RIGHT", 4, 0)

    label("Time", -140)
    f.hour = makeButton(f, "8", 50, function(self)
        local items = {}
        for h = 1, 12 do items[#items + 1] = { tostring(h), function() f.state.hour = h; UI:RefreshEventEditor() end } end
        menu(self, "Hour", items)
    end)
    f.hour:SetPoint("TOPLEFT", 90, -136)
    f.minute = makeButton(f, ":00", 56, function(self)
        local items = {}
        for _, mi in ipairs({ 0, 15, 30, 45 }) do
            items[#items + 1] = { string.format(":%02d", mi), function() f.state.minute = mi; UI:RefreshEventEditor() end }
        end
        menu(self, "Minutes", items)
    end)
    f.minute:SetPoint("LEFT", f.hour, "RIGHT", 4, 0)
    f.ampm = makeButton(f, "PM", 50, function()
        f.state.pm = not f.state.pm
        UI:RefreshEventEditor()
    end)
    f.ampm:SetPoint("LEFT", f.minute, "RIGHT", 4, 0)
    f.tz = text(f, "GameFontDisableSmall")
    f.tz:SetPoint("LEFT", f.ampm, "RIGHT", 8, 0)
    f.tz:SetText("your local time")

    label("Note", -176)
    f.note = makeInput(f, C.MAX_NOTE, function() end)
    f.note:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.note:SetPoint("TOPLEFT", 96, -172)
    f.note:SetWidth(254)
    f.noteHint = text(f, "GameFontDisableSmall")
    f.noteHint:SetPoint("TOPLEFT", 96, -196)
    f.noteHint:SetText("e.g. \"Meet at the summoning stone\" or \"Heroic, bring flasks\"")

    f.error = text(f, "GameFontRedSmall", "CENTER")
    f.error:SetPoint("BOTTOM", 0, 44)
    f.error:SetWidth(340)

    f.save = makeButton(f, "Save", 100, function() UI:SaveEventEditor() end)
    f.save:SetPoint("BOTTOMRIGHT", -112, 14)
    f.close = makeButton(f, "Cancel", 90, function() f:Hide() end)
    f.close:SetPoint("BOTTOMRIGHT", -16, 14)
    f:Hide()
    editor = f
    return f
end

function UI:EventEditorTime()
    local s = editor.state
    local hour = s.hour % 12 + (s.pm and 12 or 0)
    return time({ year = s.year, month = s.month, day = s.day, hour = hour, min = s.minute, sec = 0 })
end

function UI:RefreshEventEditor()
    local f, s = editor, editor.state
    -- normalise the date after < > (time() rolls days over months and years)
    local t = date("*t", time({ year = s.year, month = s.month, day = s.day, hour = 12 }))
    s.year, s.month, s.day = t.year, t.month, t.day
    f.heading:SetText(s.key and "Edit Event" or "New Event")
    for _, b in ipairs(f.typeButtons) do
        if b.kind == s.type then b:Disable() else b:Enable() end
    end
    if s.type == "other" then
        f.whatLabel:SetText("Name")
        f.instance:Hide()
        f.titleInput:Show()
        if f.titleInput:GetText() ~= (s.title or "") then f.titleInput:SetText(s.title or "") end
    else
        f.whatLabel:SetText(s.type == "raid" and "Raid" or "Dungeon")
        f.titleInput:Hide()
        f.instance:Show()
        f.instance:SetText((s.title and s.title ~= "") and s.title or (s.type == "raid" and "Pick a raid..." or "Pick a dungeon..."))
    end
    f.dateText:SetText(date("%A, %B ", time({ year = s.year, month = s.month, day = s.day, hour = 12 })) .. s.day)
    f.hour:SetText(tostring(s.hour))
    f.minute:SetText(string.format(":%02d", s.minute))
    f.ampm:SetText(s.pm and "PM" or "AM")
    f.error:SetText("")
end

-- key: edit that event; day: { y, m, d } to start on (default today)
function UI:OpenEventEditor(key, day)
    local f = self:BuildEventEditor(self.MakeButton, self.MakeInput)
    local ev = key and C:Get(key)
    local base = ev and ev.time
    local t
    if base then
        t = date("*t", base)
    else
        local y, m, d = today()
        if day then y, m, d = day[1], day[2], day[3] end
        t = { year = y, month = m, day = d, hour = 20, min = 0 }
    end
    f.state = { key = ev and key or nil, type = ev and ev.type or "dungeon", title = ev and ev.title or "",
        year = t.year, month = t.month, day = t.day, hour = (t.hour % 12 == 0) and 12 or t.hour % 12,
        minute = math.floor((t.min or 0) / 15) * 15, pm = t.hour >= 12 }
    f.titleInput:SetText(f.state.type == "other" and f.state.title or "")
    f.note:SetText(ev and ev.note or "")
    self:RefreshEventEditor()
    f:Show()
end

function UI:SaveEventEditor()
    local f, s = editor, editor.state
    local fields = { type = s.type, title = s.type == "other" and f.titleInput:GetText() or s.title,
        time = self:EventEditorTime(), note = f.note:GetText() }
    local key, err
    if s.key then key, err = C:Edit(s.key, fields) else key, err = C:Create(fields) end
    if not key then
        f.error:SetText(err or "Couldn't save the event.")
        return
    end
    f:Hide()
    ns.Print((s.key and "Updated " or "Planned ") .. C.Title(C:Get(key)) .. " for " .. C.When(fields.time) .. ".")
    local p = self.CalendarPanel and self.CalendarPanel()
    if p then
        p.st.eventKey = key
        local d = date("*t", fields.time)
        p.year, p.month = d.year, d.month
    end
    self:Show("calendar")
end
