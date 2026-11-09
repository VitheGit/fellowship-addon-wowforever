-- Sync: the fellowship protocol (all messages are whispers between members).
--
--   HI  fid proto wantReply | author hwm | ...   presence + "here is what I have"
--   REQ fid proto           | author fromSeq | ... "send me author's events after fromSeq"
--   EV  fid proto live      | event | event ...   events (live = just happened)
--   FL  fid proto           | author floor | ...  "I pruned everything <= floor, stop asking"
--   INV fid proto name                           invitation
--   ACC fid proto                                invitation accepted
--   DEC fid proto reason                         invitation declined
--
-- Catch-up: whenever two members meet (login, periodic ping, new member) they swap HI
-- vectors; each side REQuests only the ranges it is missing. Because every member keeps
-- the full log, anyone online can fill you in, not just the original author.
local _, ns = ...
local Sync = {}
ns.Sync = Sync

local S
local online = {}        -- key -> true (seen) / false (whisper bounced)
local pendingReq = {}    -- fid -> author -> GetTime() expiry
local pendingInvites = {} -- invitee key -> { fid, expires }
ns.online = online

local HELLO_INTERVAL = 300
local REQ_TIMEOUT = 60

---------------------------------------------------------------------------
-- Encoding helpers
---------------------------------------------------------------------------
local function header(typ, fid, extra)
    return { typ, fid or "", ns.PROTOCOL, extra }
end

local function encodeEvent(e)
    local r = { e.a, e.s, e.t, e.k }
    local d = e.d or {}
    for i = 1, #d do r[4 + i] = d[i] end
    return r
end

local function decodeEvent(r)
    local e = { a = r[1], s = tonumber(r[2]), t = tonumber(r[3]), k = r[4], d = {} }
    for i = 5, #r do e.d[#e.d + 1] = r[i] end
    return e
end

local function send(target, records, bulk)
    ns.Comm:Send(target, S.Encode(records), bulk)
end

-- Events are sent in ~1KB messages so a long catch-up makes steady progress.
local function sendEvents(target, fid, events, live, bulk)
    local head = S.EncodeRecord(header("EV", fid, live and "1" or "0"))
    local batch, size = { head }, 0
    for _, e in ipairs(events) do
        local rec = S.EncodeRecord(encodeEvent(e))
        batch[#batch + 1] = rec
        size = size + #rec + 1
        if size > 900 then
            send(target, batch, bulk)
            batch, size = { head }, 0
        end
    end
    if #batch > 1 then send(target, batch, bulk) end
end

local function otherMembers(fid)
    local out = {}
    for key, m in pairs(ns.Store:Roster(fid)) do
        if key ~= ns.meKey then out[#out + 1] = m.name end
    end
    table.sort(out)
    return out
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function Sync:Init()
    S = ns.Serializer
    C_Timer.After(4, function() Sync:HelloAll() end)
    C_Timer.NewTicker(HELLO_INTERVAL, function() Sync:HelloAll() end)
end

function Sync:IsOnline(name)
    return online[ns.Key(name)]
end

function Sync:MarkOnline(key)
    if online[key] ~= true then
        online[key] = true
        ns.Fire("PRESENCE", key, true)
    end
end

function Sync:MarkOffline(key)
    if online[key] ~= false then
        online[key] = false
        ns.Fire("PRESENCE", key, false)
    end
end

---------------------------------------------------------------------------
-- Presence and catch-up
---------------------------------------------------------------------------
function Sync:Hello(fid, target, wantReply)
    local f = ns.Store:Get(fid)
    if not f then return end
    local rec = { header("HI", fid, wantReply and "1" or "0") }
    for author, h in pairs(f.hwm) do
        if h > 0 then rec[#rec + 1] = { author, h } end
    end
    send(target, rec)
end

function Sync:HelloAll()
    local f, fid = ns.Store:Active()
    if not f then return end
    local targets = otherMembers(fid)
    if f.pendingFrom and not ns.Store:IsMember(fid, f.pendingFrom) then
        targets[#targets + 1] = f.pendingFrom
    end
    for _, name in ipairs(targets) do self:Hello(fid, name, true) end
end

function Sync:OnHello(sender, fid, f, wantReply, records)
    local now = GetTime()
    pendingReq[fid] = pendingReq[fid] or {}
    local pend = pendingReq[fid]
    local wants = { header("REQ", fid) }
    for i = 2, #records do
        local author, theirs = records[i][1], tonumber(records[i][2])
        if author and author ~= "" and theirs then
            local mine = f.hwm[author] or 0
            if theirs > mine and not (pend[author] and pend[author] > now) then
                wants[#wants + 1] = { author, mine }
                pend[author] = now + REQ_TIMEOUT
            end
        end
    end
    if #wants > 1 then send(sender, wants) end
    if wantReply then self:Hello(fid, sender, false) end
end

function Sync:OnRequest(sender, fid, records)
    local limit = ns.settings.backfillLimit
    local floors = { header("FL", fid) }
    local events = {}
    for i = 2, #records do
        local author, from = records[i][1], tonumber(records[i][2])
        if author and author ~= "" and from then
            local evs, floor = ns.Store:EventsAfter(fid, author, from, limit)
            for _, e in ipairs(evs) do events[#events + 1] = e end
            if floor then floors[#floors + 1] = { author, floor } end
        end
    end
    if #floors > 1 then send(sender, floors, true) end
    if #events > 0 then sendEvents(sender, fid, events, false, true) end
end

function Sync:OnFloor(fid, records)
    for i = 2, #records do
        local author, n = records[i][1], tonumber(records[i][2])
        if author and author ~= "" and n then ns.Store:SetFloor(fid, author, n) end
    end
end

function Sync:OnEvents(fid, live, records)
    local added = {}
    for i = 2, #records do
        local e = decodeEvent(records[i])
        if ns.Store:AddEvent(fid, e) then
            e.d = ns.Store:Get(fid).events[e.a][e.s].d
            added[#added + 1] = e
        end
    end
    if #added > 0 then self:AfterAdded(fid, added, live) end
end

function Sync:AfterAdded(fid, added, live)
    for _, e in ipairs(added) do
        if ns.MEMBERSHIP_KINDS[e.k] then
            self:OnRosterChanged(fid, added)
            break
        end
    end
    -- the fellowship may have been forgotten (we were removed)
    if ns.Store:Get(fid) then ns.Fire("EVENTS_ADDED", fid, added, live) end
end

function Sync:OnRosterChanged(fid, added)
    local f = ns.Store:Get(fid)
    local roster = ns.Store:Roster(fid)
    if f.pendingFrom then
        if roster[ns.meKey] then
            f.pendingFrom = nil
            ns.Print("Welcome to " .. ns.Escape(f.name) .. "! Catching up on history...")
            ns.Fire("FELLOWSHIP_CHANGED")
            self:HelloAll()
        end
        return
    end
    if not roster[ns.meKey] then
        local left = false
        for _, e in ipairs(added) do
            if e.k == "L" and e.a == ns.me then left = true end
        end
        ns.Print((left and "You left " or "You are no longer a member of ") .. ns.Escape(f.name) .. ".")
        ns.Store:Forget(fid)
        ns.Fire("FELLOWSHIP_CHANGED")
        return
    end
    for _, e in ipairs(added) do
        -- say hi to brand-new members so they can sync with us too
        if e.k == "J" and e.a ~= ns.me and e.d[1] and ns.Key(e.d[1]) ~= ns.meKey then
            self:Hello(fid, e.d[1], true)
        end
    end
end

---------------------------------------------------------------------------
-- Dispatch
---------------------------------------------------------------------------
function Sync:Trusted(fid, f, key)
    if ns.Store:Roster(fid)[key] then return true end
    return f.pendingFrom ~= nil and ns.Key(f.pendingFrom) == key
end

function Sync:OnMessage(sender, records)
    local h = records[1]
    if not h then return end
    local typ, fid, proto = h[1], h[2], h[3]
    if proto ~= ns.PROTOCOL or not fid or fid == "" then return end
    local key = ns.Key(sender)
    if key == ns.meKey then return end

    if typ == "INV" then return self:OnInvite(sender, fid, h[4]) end
    if typ == "ACC" then return self:OnAccept(sender, fid) end
    if typ == "DEC" then return self:OnDecline(sender, fid, h[4]) end

    local f = ns.Store:Get(fid)
    if not f or ns.Store:ActiveId() ~= fid then return end
    if not self:Trusted(fid, f, key) then return end
    self:MarkOnline(key)

    if typ == "HI" then
        self:OnHello(sender, fid, f, h[4] == "1", records)
    elseif typ == "REQ" then
        self:OnRequest(sender, fid, records)
    elseif typ == "EV" then
        self:OnEvents(fid, h[4] == "1", records)
    elseif typ == "FL" then
        self:OnFloor(fid, records)
    end
end

---------------------------------------------------------------------------
-- Publishing
---------------------------------------------------------------------------
function Sync:Publish(kind, data)
    local f, fid = ns.Store:Active()
    if not f or f.pendingFrom then return nil end
    local e = ns.Store:NewLocalEvent(fid, kind, data)
    if not e then return nil end
    for _, name in ipairs(otherMembers(fid)) do
        if online[ns.Key(name)] then sendEvents(name, fid, { e }, true, false) end
    end
    self:AfterAdded(fid, { e }, true)
    return e
end

function Sync:PostChat(text)
    text = ns.Trim(text):gsub("%c", "")
    if text == "" then return end
    local f = ns.Store:Active()
    if not f then
        ns.Print("You're not in a fellowship yet. Use /fs create <name> or ask a friend to invite you.")
        return
    end
    if f.pendingFrom then
        ns.Print("Still joining " .. ns.Escape(f.name) .. "; try again in a moment.")
        return
    end
    text = ns.Truncate(text, 255)
    if not self:Publish("C", { text }) then return end
    if not self.hintShown then
        local others, onlineCount = otherMembers(ns.Store:ActiveId()), 0
        for _, name in ipairs(others) do
            if online[ns.Key(name)] then onlineCount = onlineCount + 1 end
        end
        if #others == 0 then
            self.hintShown = true
            ns.Print("You're the only member so far. Invite friends with /fs invite <player>; they'll see this history when they join.")
        elseif onlineCount == 0 then
            self.hintShown = true
            ns.Print("Nobody else is online right now. Your message is saved and members will get it when they log in.")
        end
    end
end

---------------------------------------------------------------------------
-- Membership
---------------------------------------------------------------------------
function Sync:Create(name)
    name = ns.Trim(name):gsub("%c", "")
    if name == "" or #name > 48 then
        ns.Print("Usage: /fs create <name> (up to 48 bytes)")
        return
    end
    if ns.Store:ActiveId() then
        ns.Print("You're already in a fellowship. /fs leave first.")
        return
    end
    local fid = ns.me .. ":" .. ns.Now()
    ns.Store:Create(fid, name)
    self:Publish("N", { name })
    ns.Print("Created " .. ns.Escape(name) .. ". Invite friends with /fs invite <player>.")
    ns.Fire("FELLOWSHIP_CHANGED")
end

function Sync:Invite(target)
    local f, fid = ns.Store:Active()
    if not f or f.pendingFrom then
        ns.Print("You need to be in a fellowship to invite people.")
        return
    end
    local name = ns.NormalizeName(ns.Trim(target))
    if not name then
        ns.Print("Usage: /fs invite <player> or <player-realm>")
        return
    end
    local key = ns.Key(name)
    if key == ns.meKey or ns.Store:IsMember(fid, name) then
        ns.Print(ns.Short(name) .. " is already in the fellowship.")
        return
    end
    pendingInvites[key] = { fid = fid, expires = GetTime() + 300 }
    send(name, { header("INV", fid, f.name) })
    ns.Print("Invitation sent to " .. ns.Short(name) .. ". They need Fellowship installed to see it.")
end

function Sync:OnInvite(sender, fid, name)
    if ns.Store:ActiveId() then
        send(sender, { header("DEC", fid, "busy") })
        return
    end
    name = ns.Truncate(tostring(name or "?"), 48)
    ns.UI:ShowInvite({ fid = fid, name = name, from = sender })
end

function Sync:AcceptInvite(data)
    if ns.Store:ActiveId() then return end
    ns.Store:Create(data.fid, data.name, data.from)
    send(data.from, { header("ACC", data.fid) })
    self:Hello(data.fid, data.from, true)
    ns.Print("Joining " .. ns.Escape(data.name) .. "...")
    ns.Fire("FELLOWSHIP_CHANGED")
end

function Sync:DeclineInvite(data)
    send(data.from, { header("DEC", data.fid, "declined") })
end

function Sync:OnAccept(sender, fid)
    local key = ns.Key(sender)
    local p = pendingInvites[key]
    if not p or p.fid ~= fid or p.expires < GetTime() then return end
    pendingInvites[key] = nil
    if ns.Store:ActiveId() ~= fid then return end
    self:MarkOnline(key)
    self:Publish("J", { sender })
end

function Sync:OnDecline(sender, fid, reason)
    local key = ns.Key(sender)
    local p = pendingInvites[key]
    if not p or p.fid ~= fid then return end
    pendingInvites[key] = nil
    if reason == "busy" then
        ns.Print(ns.Short(sender) .. " is already in another fellowship.")
    else
        ns.Print(ns.Short(sender) .. " declined your invitation.")
    end
end

function Sync:Leave()
    local f, fid = ns.Store:Active()
    if not f then
        ns.Print("You're not in a fellowship.")
        return
    end
    if not f.pendingFrom then self:Publish("L", {}) end
    -- Publishing "L" normally forgets the fellowship via OnRosterChanged; make sure either way.
    if ns.Store:ActiveId() == fid then
        ns.Store:Forget(fid)
        ns.Print("You left " .. ns.Escape(f.name) .. ".")
        ns.Fire("FELLOWSHIP_CHANGED")
    end
end

function Sync:Remove(target)
    local f, fid = ns.Store:Active()
    if not f then return end
    local roster, founder = ns.Store:Roster(fid)
    if founder ~= ns.me then
        ns.Print("Only the founder (" .. ns.Short(founder) .. ") can remove members.")
        return
    end
    local m = roster[ns.Key(ns.Trim(target))]
    if not m or ns.Key(m.name) == ns.meKey then
        ns.Print("No such member: " .. ns.Escape(target))
        return
    end
    local e = self:Publish("K", { m.name })
    if e and online[ns.Key(m.name)] then
        sendEvents(m.name, fid, { e }, true, false) -- let them know
    end
end

function Sync:PrintMembers()
    local f, fid = ns.Store:Active()
    if not f then
        ns.Print("You're not in a fellowship.")
        return
    end
    local roster, founder = ns.Store:Roster(fid)
    ns.Print(ns.Escape(f.name) .. " members:")
    local names = {}
    for _, m in pairs(roster) do names[#names + 1] = m.name end
    table.sort(names)
    for _, n in ipairs(names) do
        local status
        if ns.Key(n) == ns.meKey then status = "|cff33ff99you|r"
        elseif online[ns.Key(n)] then status = "|cff33ff99online|r"
        else status = "|cff9d9d9doffline|r" end
        DEFAULT_CHAT_FRAME:AddMessage("  " .. n .. " - " .. status .. (n == founder and " (founder)" or ""))
    end
end
