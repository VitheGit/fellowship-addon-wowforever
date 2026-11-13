-- Calendar: fellowship events (dungeon runs, raids, anything else) with sign-ups.
--
-- Anyone can create an event; only its creator can edit or cancel it. Every member answers
-- Going / Maybe / Can't. Like wishlists, each character's calendar data is one replicated
-- record (newest version wins), kept outside the event log so older versions ignore it:
--   CL fid proto | author version | E id time type title note cancelled | R author id status | ...
--   CV fid proto wantReply | author version | ...   "these are the calendars I have"
-- Any member passes on anyone's record, so an event made while you were offline reaches you.
-- Times are server time (seconds since 1970), shown in each player's own local time.
local _, ns = ...
local C = {}
ns.Calendar = C

C.MAX_EVENTS = 30         -- per creator
C.MAX_RSVPS = 80          -- per character
C.MAX_TITLE = 50
C.MAX_NOTE = 120
C.KEEP_PAST = 2 * 86400   -- events stay visible this long after they start
C.REMIND_BEFORE = 15 * 60 -- "starting in 15 minutes"
C.STATUS = { y = "Going", m = "Maybe", n = "Can't" }
C.TYPES = { dungeon = "Dungeon", raid = "Raid", other = "Other" }

---------------------------------------------------------------------------
-- Storage: f.calendar[charKey] = { name, v, events = { [id] = event }, rsvps = { ["author:id"] = status } }
---------------------------------------------------------------------------
local function records(fid)
    local f = ns.Store:Get(fid)
    if not f then return nil end
    f.calendar = f.calendar or {}
    return f.calendar
end

local function mine(fid)
    local all = records(fid)
    if not all then return nil end
    local r = all[ns.meKey]
    if not r then
        r = { name = ns.me, v = 0, events = {}, rsvps = {} }
        all[ns.meKey] = r
    end
    r.name = ns.me
    return r
end

function C.EventKey(author, id)
    return ns.Key(author) .. ":" .. tostring(id)
end

local function clean(s, max)
    return ns.Truncate(ns.Trim(tostring(s or "")):gsub("%c", ""), max)
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------
-- Every event (cancelled ones included) from current members:
-- { key, author, id, time, type, title, note, cancelled, rsvps = { [charName] = status } }
function C:Events(fid)
    fid = fid or ns.Store:ActiveId()
    local out = {}
    local all = fid and records(fid)
    if not all then return out end
    local roster = ns.Store:Roster(fid)
    local byKey = {}
    for key, r in pairs(all) do
        if roster[key] then
            for id, e in pairs(r.events or {}) do
                local ev = { key = C.EventKey(r.name, id), author = r.name, id = id, time = e.time, type = e.type,
                    title = e.title, note = e.note, cancelled = e.cancelled, rsvps = {} }
                byKey[ev.key] = ev
                out[#out + 1] = ev
            end
        end
    end
    -- one answer per account: an alt's answer counts for the account, newest record wins
    for key, r in pairs(all) do
        if roster[key] then
            for ek, status in pairs(r.rsvps or {}) do
                local ev = byKey[ek]
                if ev then ev.rsvps[r.name] = status end
            end
        end
    end
    for _, ev in ipairs(out) do
        -- the creator is going unless they said otherwise
        if not ev.rsvps[ev.author] then ev.rsvps[ev.author] = "y" end
    end
    table.sort(out, function(a, b)
        if a.time ~= b.time then return a.time < b.time end
        return a.key < b.key
    end)
    return out
end

function C:Get(key, fid)
    for _, ev in ipairs(self:Events(fid)) do
        if ev.key == key then return ev end
    end
end

-- Events that haven't ended yet (started less than 3 hours ago), not cancelled.
function C:Upcoming(fid)
    local now, out = ns.Now(), {}
    for _, ev in ipairs(self:Events(fid)) do
        if not ev.cancelled and ev.time > now - 3 * 3600 then out[#out + 1] = ev end
    end
    return out
end

-- Events on a local calendar day (year, month, day).
function C:OnDay(y, m, d, fid)
    local out = {}
    for _, ev in ipairs(self:Events(fid)) do
        local t = date("*t", ev.time)
        if t.year == y and t.month == m and t.day == d then out[#out + 1] = ev end
    end
    return out
end

function C:MyStatus(ev)
    local fid = ns.Store:ActiveId()
    if ev.rsvps[ns.me] then return ev.rsvps[ns.me] end
    for name, status in pairs(ev.rsvps) do
        if ns.Key(name) == ns.meKey or (fid and ns.Store:SameAccount(fid, name, ns.me)) then return status end
    end
end

-- { y = {names}, m = {names}, n = {names} }, one entry per account (its newest answer)
function C:Answers(ev)
    local fid = ns.Store:ActiveId()
    local byAccount, out = {}, { y = {}, m = {}, n = {} }
    local all = records(fid) or {}
    for name, status in pairs(ev.rsvps) do
        local m = ns.Store:Roster(fid)[ns.Key(name)]
        local acct = m and m.account or ns.Key(name)
        local r = all[ns.Key(name)]
        local v = r and r.v or 0
        if not byAccount[acct] or v > byAccount[acct].v then byAccount[acct] = { name = name, status = status, v = v } end
    end
    for _, a in pairs(byAccount) do
        if out[a.status] then table.insert(out[a.status], a.name) end
    end
    for _, list in pairs(out) do table.sort(list) end
    return out
end

---------------------------------------------------------------------------
-- Wire format
---------------------------------------------------------------------------
local function header(typ, fid, extra)
    return { typ, fid, ns.PROTOCOL, extra or "", ns.VERSION }
end

function C:Records(fid, key)
    local r = (records(fid) or {})[key]
    if not r then return nil end
    local rec = { header("CL", fid), { r.name, r.v } }
    for id, e in pairs(r.events or {}) do
        rec[#rec + 1] = { "E", id, e.time, e.type, e.title or "", e.note or "", e.cancelled and "1" or "" }
    end
    for ek, status in pairs(r.rsvps or {}) do
        local a, id = ek:match("^(.*):(%d+)$")
        if a then rec[#rec + 1] = { "R", a, id, status } end
    end
    return rec
end

function C:SendSummary(fid, target, wantReply)
    local rec = { header("CV", fid, wantReply and "1" or "0") }
    local roster = ns.Store:Roster(fid)
    for key, r in pairs(records(fid) or {}) do
        if roster[key] then rec[#rec + 1] = { r.name, r.v } end
    end
    ns.Sync:SendRaw(target, rec, true)
end

function C:OnSummary(sender, fid, recs, wantReply)
    local theirs = {}
    for i = 2, #recs do
        local name, v = recs[i][1], tonumber(recs[i][2])
        if name and v then theirs[ns.Key(name)] = v end
    end
    local roster = ns.Store:Roster(fid)
    local all = records(fid) or {}
    for key, r in pairs(all) do
        if roster[key] and (theirs[key] or -1) < (r.v or 0) then
            ns.Sync:SendRaw(sender, self:Records(fid, key), true)
        end
    end
    if wantReply then
        for key, v in pairs(theirs) do
            if roster[key] and v > ((all[key] and all[key].v) or -1) then
                self:SendSummary(fid, sender, false)
                break
            end
        end
    end
end

function C:OnList(sender, fid, recs)
    local h = recs[2]
    local name, v = h and ns.NormalizeName(h[1]), h and tonumber(h[2])
    if not name or not v then return end
    local key = ns.Key(name)
    if not ns.Store:Roster(fid)[key] then return end
    local all = records(fid)
    local cur = all[key]
    if cur and (cur.v or 0) >= v then return end
    local events, rsvps, nE, nR = {}, {}, 0, 0
    for i = 3, #recs do
        local r = recs[i]
        if r[1] == "E" and nE < C.MAX_EVENTS then
            local id, t = tonumber(r[2]), tonumber(r[3])
            if id and t and id >= 1 and id == math.floor(id) then
                local typ = C.TYPES[r[4]] and r[4] or "other"
                local note = clean(r[6], C.MAX_NOTE)
                events[id] = { time = t, type = typ, title = clean(r[5], C.MAX_TITLE), note = note ~= "" and note or nil,
                    cancelled = r[7] == "1" or nil }
                nE = nE + 1
            end
        elseif r[1] == "R" and nR < C.MAX_RSVPS then
            local a, id, status = ns.NormalizeName(r[2]), tonumber(r[3]), r[4]
            if a and id and C.STATUS[status] then
                rsvps[C.EventKey(a, id)] = status
                nR = nR + 1
            end
        end
    end
    -- what's new, for notices: events we hadn't seen, and answers to my events
    local old = cur or { events = {}, rsvps = {} }
    all[key] = { name = name, v = v, events = events, rsvps = rsvps }
    if key ~= ns.meKey then
        for id, e in pairs(events) do
            if not old.events[id] and not e.cancelled and e.time > ns.Now() then
                ns.Fire("CALENDAR_NEW_EVENT", fid, C.EventKey(name, id))
            elseif old.events[id] and e.cancelled and not old.events[id].cancelled and e.time > ns.Now() then
                ns.Fire("CALENDAR_CANCELLED", fid, C.EventKey(name, id))
            end
        end
        for ek, status in pairs(rsvps) do
            if old.rsvps[ek] ~= status and ek:sub(1, #ns.meKey + 1) == ns.meKey .. ":" then
                ns.Fire("CALENDAR_ANSWER", fid, ek, name, status)
            end
        end
    end
    ns.Fire("CALENDAR_CHANGED", fid)
end

---------------------------------------------------------------------------
-- Changing my record
---------------------------------------------------------------------------
function C:Publish()
    local fid = ns.Store:ActiveId()
    local r = fid and mine(fid)
    if not r then return end
    -- drop my old events, and answers to events that are gone
    local now = ns.Now()
    for id, e in pairs(r.events) do
        if e.time < now - C.KEEP_PAST then r.events[id] = nil end
    end
    local alive = {}
    for _, ev in ipairs(self:Events(fid)) do alive[ev.key] = true end
    for ek in pairs(r.rsvps) do
        if not alive[ek] then r.rsvps[ek] = nil end
    end
    r.v = math.max((r.v or 0) + 1, now)
    local f = ns.Store:Get(fid)
    if not f.pendingFrom then ns.Sync:Broadcast(fid, self:Records(fid, ns.meKey)) end
    ns.Fire("CALENDAR_CHANGED", fid)
end

-- fields: time, type, title, note. Returns the event key, or nil and a reason.
function C:Create(fields)
    local fid = ns.Store:ActiveId()
    if not fid then return nil, "You're not in a fellowship yet." end
    local ok, err = self:Check(fields)
    if not ok then return nil, err end
    local r = mine(fid)
    local count, nextId = 0, 1
    for id in pairs(r.events) do
        count = count + 1
        if id >= nextId then nextId = id + 1 end
    end
    r.nextId = math.max(r.nextId or 1, nextId)
    if count >= C.MAX_EVENTS then return nil, "You have too many events planned (" .. C.MAX_EVENTS .. ")." end
    local id = r.nextId
    r.nextId = id + 1
    r.events[id] = { time = math.floor(fields.time), type = fields.type, title = clean(fields.title, C.MAX_TITLE),
        note = (ns.Trim(fields.note or "") ~= "") and clean(fields.note, C.MAX_NOTE) or nil }
    r.rsvps[C.EventKey(ns.me, id)] = "y"
    self:Publish()
    return C.EventKey(ns.me, id)
end

function C:Check(fields)
    if not C.TYPES[fields.type or ""] then return false, "Pick Dungeon, Raid or Other." end
    if ns.Trim(fields.title or "") == "" then
        return false, fields.type == "other" and "Give the event a name." or "Pick a dungeon or raid."
    end
    if not tonumber(fields.time) then return false, "Pick a date and time." end
    if fields.time < ns.Now() - 300 then return false, "That time has already passed." end
    return true
end

local function ownEvent(key)
    local fid = ns.Store:ActiveId()
    local a, id = tostring(key):match("^(.*):(%d+)$")
    if not fid or a ~= ns.meKey then return nil end
    local r = mine(fid)
    return r.events[tonumber(id)], r
end

function C:CanEdit(key)
    return ownEvent(key) ~= nil
end

function C:Edit(key, fields)
    local e = ownEvent(key)
    if not e then return nil, "Only the person who made an event can change it." end
    local ok, err = self:Check(fields)
    if not ok then return nil, err end
    e.time, e.type, e.title = math.floor(fields.time), fields.type, clean(fields.title, C.MAX_TITLE)
    e.note = (ns.Trim(fields.note or "") ~= "") and clean(fields.note, C.MAX_NOTE) or nil
    e.cancelled = nil
    self:Publish()
    return key
end

function C:Cancel(key)
    local e = ownEvent(key)
    if not e then return false end
    e.cancelled = true
    self:Publish()
    return true
end

function C:Respond(key, status)
    local fid = ns.Store:ActiveId()
    if not fid or not C.STATUS[status] or not self:Get(key, fid) then return false end
    local r = mine(fid)
    if r.rsvps[key] == status then return true end
    r.rsvps[key] = status
    self:Publish()
    return true
end

---------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------
function C.When(t)
    local d, now = date("*t", t), date("*t", ns.Now())
    local clock = date("%I:%M %p", t):gsub("^0", "")
    local day
    local today = time({ year = now.year, month = now.month, day = now.day, hour = 0 })
    local that = time({ year = d.year, month = d.month, day = d.day, hour = 0 })
    local diff = math.floor((that - today) / 86400 + 0.5)
    if diff == 0 then day = "Today"
    elseif diff == 1 then day = "Tomorrow"
    elseif diff == -1 then day = "Yesterday"
    elseif diff > 1 and diff < 7 then day = date("%A", t)
    else day = date("%a %b ", t) .. d.day end
    return day .. " " .. clock
end

function C.Title(ev)
    local t = ns.Escape(ev.title ~= "" and ev.title or "Event")
    if ev.type == "raid" then return "|cffff8000" .. t .. "|r" end
    if ev.type == "dungeon" then return "|cff0070dd" .. t .. "|r" end
    return "|cffffd100" .. t .. "|r"
end

function C:Line(ev)
    local a = self:Answers(ev)
    local my = self:MyStatus(ev)
    return C.When(ev.time) .. "  " .. C.Title(ev) .. "  |cff808080by " .. ns.Short(ev.author) .. ", "
        .. #a.y .. " going" .. (#a.m > 0 and (", " .. #a.m .. " maybe") or "") .. "|r"
        .. (my and ("  (you: " .. C.STATUS[my] .. ")") or "  |cffff8040(not answered)|r")
end

function C:PrintUpcoming()
    local list = self:Upcoming()
    if #list == 0 then
        ns.Print("Nothing planned. Open the Calendar tab (/fship calendar) to plan something.")
        return
    end
    ns.Print("Upcoming events:")
    for i = 1, math.min(#list, 8) do ns.Output("  " .. self:Line(list[i])) end
end

---------------------------------------------------------------------------
-- Notices and reminders
---------------------------------------------------------------------------
local function remembered()
    local c = ns.Store.char
    if not c then return {} end
    c.reminded = c.reminded or {}
    return c.reminded
end

function C:CheckReminders()
    local now = ns.Now()
    local done = remembered()
    for k, t in pairs(done) do
        if t < now - 7 * 86400 then done[k] = nil end
    end
    for _, ev in ipairs(self:Upcoming()) do
        local my = self:MyStatus(ev)
        local left = ev.time - now
        if my ~= "n" and left > -60 and left <= C.REMIND_BEFORE and not done[ev.key] then
            done[ev.key] = now
            local mins = math.max(0, math.floor((left + 30) / 60))
            ns.Print("|cffffd100Reminder:|r " .. C.Title(ev) .. (mins > 0 and (" starts in " .. mins .. " minutes") or " is starting now")
                .. ". " .. #self:Answers(ev).y .. " going.")
            if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.READY_CHECK or SOUNDKIT.RAID_WARNING or 8960) end
            if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo.RAID_WARNING then
                RaidNotice_AddMessage(RaidWarningFrame, "Fellowship: " .. (ev.title or "Event")
                    .. (mins > 0 and (" in " .. mins .. " minutes") or " starting now"), ChatTypeInfo.RAID_WARNING)
            end
        end
    end
end

-- At login: what's coming up in the next 24 hours, and events still waiting for an answer.
function C:LoginSummary()
    local now, soon, unanswered = ns.Now(), {}, 0
    for _, ev in ipairs(self:Upcoming()) do
        local my = self:MyStatus(ev)
        if ev.time > now and ev.time <= now + 86400 and my ~= "n" then soon[#soon + 1] = ev end
        if ev.time > now and not my then unanswered = unanswered + 1 end
    end
    for i = 1, math.min(#soon, 3) do
        ns.Print("|cffffd100Coming up:|r " .. C.Title(soon[i]) .. " " .. C.When(soon[i].time)
            .. (self:MyStatus(soon[i]) and "" or " |cffff8040(you haven't answered)|r"))
    end
    if unanswered > 0 then
        ns.Print(unanswered .. " fellowship event" .. (unanswered == 1 and " is" or "s are")
            .. " waiting for your answer. Type /fship calendar.")
    end
end

function C:Init()
    ns.Listen("CALENDAR_NEW_EVENT", function(fid, key)
        local ev = C:Get(key, fid)
        if not ev then return end
        ns.Echo(ns.ColorName(ev.author) .. " planned " .. C.Title(ev) .. " for " .. C.When(ev.time)
            .. ". |cff808080Type /fship calendar to sign up.|r")
    end)
    ns.Listen("CALENDAR_CANCELLED", function(fid, key)
        local ev = C:Get(key, fid)
        if not ev then return end
        ns.Echo(ns.ColorName(ev.author) .. " cancelled " .. C.Title(ev) .. " (" .. C.When(ev.time) .. ").")
    end)
    ns.Listen("CALENDAR_ANSWER", function(fid, key, name, status)
        local ev = C:Get(key, fid)
        if not ev or ev.cancelled then return end
        local word = status == "y" and "|cff33ff99is going|r" or status == "m" and "|cffffd100might come|r"
            or "|cffff4040can't make it|r"
        ns.Echo(ns.ColorName(name) .. " " .. word .. " to " .. C.Title(ev) .. " (" .. C.When(ev.time) .. ").")
    end)
    C_Timer.NewTicker(30, function() C:CheckReminders() end)
    C_Timer.After(25, function()
        C:LoginSummary()
        C:CheckReminders()
    end)
end
