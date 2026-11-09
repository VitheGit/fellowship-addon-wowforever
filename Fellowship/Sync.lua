-- Sync: the fellowship protocol (all messages are whispers between members).
--
--   HI  fid proto wantReply | author hwm | ...   presence + "here is what I have"
--   REQ fid proto           | author fromSeq | ... "send me author's events after fromSeq"
--   EV  fid proto live      | event | event ...   events (live = just happened)
--   FL  fid proto           | author floor | ...  "I pruned everything <= floor, stop asking"
--   INV fid proto name                           invitation
--   ACC fid proto                                invitation accepted
--   DEC fid proto reason                         invitation declined
--   LNK fid proto | event                         an alt introduces itself with its Y (account) event
--   PI  fid proto | level zone                   presence ping + where I am (a bounce means they logged off)
--
-- Catch-up: whenever two members meet (login, periodic ping, new member) they swap HI
-- vectors; each side REQuests only the ranges it is missing. Because every member keeps
-- the full log, anyone online can fill you in, not just the original author.
local _, ns = ...
local Sync = {}
ns.Sync = Sync

local S
local online = {}        -- key -> true (seen) / false (whisper bounced)
local status = {}        -- key -> { level, zone } from members who share their location
ns.memberStatus = status
local pendingReq = {}    -- fid -> author -> GetTime() expiry
local pendingInvites = {} -- invitee key -> { fid, expires }
ns.online = online

local HELLO_INTERVAL = 300
local PING_INTERVAL = 60
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

-- Every character of every *other* member account (alts included).
local function otherMembers(fid)
    local roster = ns.Store:Roster(fid)
    local mine = roster[ns.meKey] and roster[ns.meKey].account
    local out = {}
    for key, m in pairs(roster) do
        if key ~= ns.meKey and (not mine or m.account ~= mine) then out[#out + 1] = m.name end
    end
    table.sort(out)
    return out
end
Sync.OtherMembers = otherMembers

local function myAccountKey(fid)
    local m = ns.Store:Roster(fid)[ns.meKey]
    return m and m.account
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function Sync:Init()
    S = ns.Serializer
    C_Timer.After(4, function() Sync:HelloAll() end)
    -- after catching up: switch roles on for fellowships made before roles existed
    C_Timer.After(20, function() Sync:EnsureRoles() Sync:EnsureAccount() Sync:CheckAdminOffer() end)
    self:AutoJoinAlt()
    C_Timer.NewTicker(HELLO_INTERVAL, function() Sync:HelloAll() end)
    C_Timer.NewTicker(PING_INTERVAL, function() Sync:PingOnline() end)
    ns.On("ZONE_CHANGED_NEW_AREA", function() Sync:QueueStatus() end)
    ns.On("PLAYER_LEVEL_UP", function() Sync:QueueStatus() end)
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
        if h > 0 or author == ns.me then
            rec[#rec + 1] = { author, h, ns.Store:GetClass(author) }
        end
    end
    if not f.hwm[ns.me] then rec[#rec + 1] = { ns.me, 0, ns.Store:GetClass(ns.me) } end
    send(target, rec)
end

-- Cheap check that members we think are online still are: if they logged off,
-- the whisper bounces and Comm marks them offline.
local function pingRecords(fid)
    local rec = { header("PI", fid) }
    if ns.settings.shareLocation then
        rec[2] = { UnitLevel and UnitLevel("player") or "", (GetZoneText and GetZoneText()) or "" }
    end
    return rec
end

function Sync:Ping(fid, target)
    send(target, pingRecords(fid))
end

function Sync:PingOnline()
    local f, fid = ns.Store:Active()
    if not f or f.pendingFrom then return end
    for _, name in ipairs(otherMembers(fid)) do
        if online[ns.Key(name)] then self:Ping(fid, name) end
    end
end

-- zone/level changed: tell online members soon (debounced)
local statusQueued = false
function Sync:QueueStatus()
    if statusQueued then return end
    statusQueued = true
    C_Timer.After(3, function()
        statusQueued = false
        Sync:PingOnline()
    end)
end

function Sync:OnPing(sender, records)
    local r = records[2]
    local key = ns.Key(sender)
    if r and (tonumber(r[1]) or (r[2] and r[2] ~= "")) then
        status[key] = { level = tonumber(r[1]), zone = r[2] ~= "" and r[2] or nil }
    else
        status[key] = nil
    end
    ns.Fire("STATUS", key)
end

function Sync:HelloAll()
    local f, fid = ns.Store:Active()
    if not f then return end
    local targets = otherMembers(fid)
    if f.pendingFrom and not ns.Store:IsMember(fid, f.pendingFrom) then
        targets[#targets + 1] = f.pendingFrom
    end
    local link = self:MyLinkEvent(fid)
    for _, name in ipairs(targets) do
        if link then send(name, { header("LNK", fid), encodeEvent(link) }) end
        self:Hello(fid, name, true)
    end
end

---------------------------------------------------------------------------
-- Accounts: alts join automatically
---------------------------------------------------------------------------
-- If this character joined as an alt, its Y event (sent ahead of HI so members trust us).
function Sync:MyLinkEvent(fid)
    local f = ns.Store:Get(fid)
    for s, e in pairs(f and f.events[ns.me] or {}) do
        if e.k == "Y" then return { a = ns.me, s = s, t = e.t, k = e.k, d = e.d } end
    end
end

-- Tie this character to our account (Q) once we're a member, so our alts can join.
function Sync:EnsureAccount()
    local f, fid = ns.Store:Active()
    if not f or f.pendingFrom then return end
    local m = ns.Store:Roster(fid)[ns.meKey]
    if m and m.account ~= ns.account.id then
        self:Publish("Q", { ns.account.id, ns.account.secret })
    end
end

-- Logged into a character that isn't in a fellowship, but this account is: join it.
function Sync:AutoJoinAlt()
    if ns.Store:ActiveId() then return end
    for fid, f in pairs(ns.Store.db.fellowships) do
        local roster, _, state = ns.Store:Roster(fid)
        local acct = state.accounts[ns.account.id]
        if acct and not f.pendingFrom and not roster[ns.meKey] then
            ns.Store.char.fid = fid
            ns.Store.char.lastRead[fid] = ns.Store.char.lastRead[fid] or ns.Now()
            if self:Publish("Y", { ns.account.id, ns.account.secret }) then
                ns.Print("This character joined " .. ns.Escape(f.name) .. " with the rest of your account.")
                ns.Fire("FELLOWSHIP_CHANGED")
                return
            end
            ns.Store.char.fid = nil
        end
    end
end

-- Someone who used to be a member (removed or left while offline) says hello. We don't trust
-- them, but we send them the membership history they're missing so their own client sees
-- the removal and cleans up.
local toldFormer = {}

function Sync:TellFormerMember(sender, fid, records)
    local key = ns.Key(sender)
    if toldFormer[key] and toldFormer[key] > GetTime() then return end
    local f = ns.Store:Get(fid)
    local wasMember = false
    for _, e in ipairs(ns.Store:Sorted(fid)) do
        if ns.Key(e.a) == key or (e.k == "J" and ns.Key(e.d[1]) == key) then
            wasMember = true
            break
        end
    end
    if not wasMember then return end
    toldFormer[key] = GetTime() + 300
    local theirs = {}
    for i = 2, #records do
        local author, h = records[i][1], tonumber(records[i][2])
        if author and h then theirs[author] = h end
    end
    local missing = {}
    for _, e in ipairs(ns.Store:Sorted(fid)) do
        if ns.MEMBERSHIP_KINDS[e.k] and e.s > (theirs[e.a] or 0) then missing[#missing + 1] = e end
    end
    if #missing > 0 then sendEvents(sender, fid, missing, false, true) end
end

function Sync:OnLink(sender, fid, records)
    local r = records[2]
    if not r then return end
    local e = decodeEvent(r)
    if e.k ~= "Y" or ns.Key(e.a) ~= ns.Key(sender) then return end
    local f = ns.Store:Get(fid)
    local acct = ns.Store:Roster(fid) and select(3, ns.Store:Roster(fid)).accounts[e.d[1] or ""]
    if not f or not acct or acct.secret ~= e.d[2] then return end
    if ns.Store:AddEvent(fid, e) then
        e.d = f.events[e.a][e.s].d
        self:AfterAdded(fid, { e }, true)
    end
end

function Sync:OnHello(sender, fid, f, wantReply, records)
    local now = GetTime()
    pendingReq[fid] = pendingReq[fid] or {}
    local pend = pendingReq[fid]
    local wants = { header("REQ", fid) }
    local classesChanged = false
    for i = 2, #records do
        local author, theirs = records[i][1], tonumber(records[i][2])
        local class = records[i][3]
        -- the sender is the authority on their own class; otherwise only fill gaps
        if author and class and class ~= "" and (ns.Key(author) == ns.Key(sender) or not ns.Store:GetClass(author)) then
            if ns.Store:SetClass(author, class) then classesChanged = true end
        end
        if author and author ~= "" and theirs then
            local mine = f.hwm[author] or 0
            if theirs > mine and not (pend[author] and pend[author] > now) then
                wants[#wants + 1] = { author, mine }
                pend[author] = now + REQ_TIMEOUT
            end
        end
    end
    if #wants > 1 then send(sender, wants) end
    if classesChanged then ns.Fire("PRESENCE") end -- repaint names
    if wantReply then self:Hello(fid, sender, false) end
    self:Ping(fid, sender) -- share where I am
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
            self:EnsureAccount()
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
    self:CheckAdminOffer()
    for _, e in ipairs(added) do
        -- say hi to brand-new members so they can sync with us too
        if e.k == "J" and e.a ~= ns.me and e.d[1] and ns.Key(e.d[1]) ~= ns.meKey then
            self:Hello(fid, e.d[1], true)
        elseif e.k == "Y" and not ns.Store:SameAccount(fid, e.a, ns.me) then
            self:MarkOnline(ns.Key(e.a))
            self:Hello(fid, e.a, true)
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
    if typ == "LNK" then return self:OnLink(sender, fid, records) end
    if not self:Trusted(fid, f, key) then
        if typ == "HI" then self:TellFormerMember(sender, fid, records) end
        return
    end
    self:MarkOnline(key)
    ns.Store:SetSeen(sender)

    if typ == "HI" then
        self:OnHello(sender, fid, f, h[4] == "1", records)
    elseif typ == "REQ" then
        self:OnRequest(sender, fid, records)
    elseif typ == "EV" then
        self:OnEvents(fid, h[4] == "1", records)
    elseif typ == "PI" then
        self:OnPing(sender, records)
    elseif typ == "FL" then
        self:OnFloor(fid, records)
    end
end

---------------------------------------------------------------------------
-- Publishing
---------------------------------------------------------------------------
function Sync:Publish(kind, data, minTime)
    local f, fid = ns.Store:Active()
    if not f or f.pendingFrom then return nil end
    local e = ns.Store:NewLocalEvent(fid, kind, data, minTime)
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
        ns.Print("You're not in a fellowship yet. Use /fship create <name> or ask a friend to invite you.")
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
            ns.Print("You're the only member so far. Invite friends with /fship invite <player>; they'll see this history when they join.")
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
        ns.Print("Usage: /fship create <name> (up to 48 bytes)")
        return
    end
    if ns.Store:ActiveId() then
        ns.Print("You're already in a fellowship. /fship leave first.")
        return
    end
    local fid = ns.me .. ":" .. ns.Now()
    ns.Store:Create(fid, name)
    self:Publish("N", { name })
    self:Publish("V", {})
    self:Publish("Q", { ns.account.id, ns.account.secret })
    ns.Print("Created " .. ns.Escape(name) .. ". Invite friends with /fship invite <player>.")
    ns.Fire("FELLOWSHIP_CHANGED")
end

function Sync:Invite(target)
    local f, fid = ns.Store:Active()
    if not f or f.pendingFrom then
        ns.Print("You need to be in a fellowship to invite people.")
        return
    end
    if not ns.Store:CanInvite(fid, ns.me) then
        local _, admin = ns.Store:Roster(fid)
        ns.Print("Only the Admin (" .. ns.Short(admin) .. ") and Inviters can invite people.")
        return
    end
    local name = ns.NormalizeName(ns.Trim(target))
    if not name then
        ns.Print("Usage: /fship invite <player> or <player-realm>")
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
    if ns.Store:ActiveId() ~= fid or not ns.Store:CanInvite(fid, ns.me) then return end
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
    if not f.pendingFrom then
        local _, _, state = ns.Store:Roster(fid)
        local others = 0
        for key in pairs(state.accounts) do if key ~= myAccountKey(fid) then others = others + 1 end end
        if ns.Store:IsAdmin(fid, ns.me) and others > 0 then
            ns.Print("You're the Admin. Pass Admin to someone first with /fship admin <player>.")
            return
        end
        self:Publish("L", {})
    end
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
    local roster, admin = ns.Store:Roster(fid)
    if not ns.Store:IsAdmin(fid, ns.me) then
        ns.Print("Only the Admin (" .. ns.Short(admin) .. ") can remove members.")
        return
    end
    local m = roster[ns.Key(ns.Trim(target))]
    if not m or m.account == myAccountKey(fid) then
        ns.Print("No such member: " .. ns.Escape(target))
        return
    end
    local chars = {}
    for _, other in pairs(roster) do
        if other.account == m.account then chars[#chars + 1] = other.name end
    end
    local e = self:Publish("K", { m.name })
    for _, n in ipairs(chars) do
        if e and online[ns.Key(n)] then sendEvents(n, fid, { e }, true, false) end -- let them know
    end
end

---------------------------------------------------------------------------
-- Roles
---------------------------------------------------------------------------
ns.ROLE_LABEL = { admin = "Admin", inviter = "Inviter", member = "Member" }

-- Returns fid, roster, member entry for `target` if I'm the Admin; prints why not otherwise.
local function adminTarget(target)
    local f, fid = ns.Store:Active()
    if not f or f.pendingFrom then
        ns.Print("You're not in a fellowship.")
        return nil
    end
    local roster, admin = ns.Store:Roster(fid)
    if not ns.Store:IsAdmin(fid, ns.me) then
        ns.Print("Only the Admin (" .. ns.Short(admin) .. ") can do that.")
        return nil
    end
    local m = roster[ns.Key(ns.Trim(target))]
    if not m then
        ns.Print("No such member: " .. ns.Escape(target))
        return nil
    end
    if m.account == myAccountKey(fid) then
        ns.Print("That's you (or one of your characters).")
        return nil
    end
    return fid, roster, m
end

function Sync:EnsureRoles()
    local f, fid = ns.Store:Active()
    if not f or f.pendingFrom then return end
    local _, _, state = ns.Store:Roster(fid)
    if ns.Store:IsAdmin(fid, ns.me) and not state.rolesOn then self:Publish("V", {}) end
end

function Sync:SetRole(target, role)
    local fid, _, m = adminTarget(target)
    if not fid then return end
    if m.role == role then
        ns.Print(ns.Short(m.name) .. " is already " .. (role == "inviter" and "an Inviter" or "a Member") .. ".")
        return
    end
    self:EnsureRoles()
    self:Publish("R", { m.name, role })
end

function Sync:OfferAdmin(target)
    if ns.Trim(target):lower() == "cancel" then
        local f, fid = ns.Store:Active()
        if not f then return end
        local _, _, state = ns.Store:Roster(fid)
        if not ns.Store:IsAdmin(fid, ns.me) or not state.offer then
            ns.Print("There's no Admin offer to cancel.")
            return
        end
        self:Publish("T", { "" })
        return
    end
    local fid, _, m = adminTarget(target)
    if not fid then return end
    self:Publish("T", { m.name })
    ns.Print("Asked " .. ns.ColorName(m.name) .. " to become Admin. You stay Admin until they accept"
        .. (online[ns.Key(m.name)] and "." or "; they'll be asked next time they log in."))
end

local promptedOffers = {}

function Sync:CheckAdminOffer()
    local f, fid = ns.Store:Active()
    if not f or f.pendingFrom then return end
    local _, _, state = ns.Store:Roster(fid)
    local o = state.offer
    if not o or o.target ~= myAccountKey(fid) then return end
    local id = o.author .. "#" .. o.seq
    if promptedOffers[id] then return end
    promptedOffers[id] = true
    ns.UI:ShowAdminOffer({ fid = fid, name = f.name, from = o.author, seq = o.seq, t = o.t })
end

function Sync:AnswerAdminOffer(data, accept)
    local f, fid = ns.Store:Active()
    if not f or fid ~= data.fid then return end
    local _, _, state = ns.Store:Roster(fid)
    local o = state.offer
    if not o or o.author ~= data.from or o.seq ~= data.seq or o.target ~= myAccountKey(fid) then
        ns.Print("That Admin offer is no longer open.")
        return
    end
    -- record after the offer, even if clocks tick within the same second
    self:Publish(accept and "X" or "W", { o.author, tostring(o.seq) }, o.t + 1)
end

-- One entry per member *account*, online first, then by name.
-- An account is online if any of its characters is; the line shows that character.
function Sync:MemberList(fid)
    local _, _, state = ns.Store:Roster(fid)
    local mine = myAccountKey(fid)
    local achievements = {}
    for _, e in ipairs(ns.Store:Sorted(fid)) do
        if e.k == "A" then achievements[e.a:lower()] = (achievements[e.a:lower()] or 0) + 1 end
    end
    local list = {}
    for key, acct in pairs(state.accounts) do
        local isMe = key == mine
        local shown, on, seen, count = acct.main, isMe, nil, 0
        for _, n in ipairs(acct.chars) do
            local k = n:lower()
            count = count + (achievements[k] or 0)
            if isMe and k == ns.meKey then shown = n
            elseif not isMe and online[k] == true and not on then shown, on = n, true end
            local s = ns.Store:GetSeen(n) or ns.Store:LastActive(fid, n)
            if s and (not seen or s > seen) then seen = s end
        end
        local status
        if on then
            status = "|cff33ff99[Online]|r" .. (isMe and " |cff808080(you)|r" or "")
        else
            status = "|cff9d9d9d[Offline]|r" .. (seen and (" |cff808080last seen " .. ns.Ago(seen) .. "|r") or "")
        end
        local where
        local st = isMe and { level = UnitLevel and UnitLevel("player"), zone = GetZoneText and GetZoneText() }
            or (on and ns.memberStatus[shown:lower()])
        if st and (st.level or st.zone) then
            where = (st.level and ("Level " .. st.level) or "") .. ((st.level and st.zone) and ", " or "")
                .. (st.zone and ns.Escape(st.zone) or "")
        end
        list[#list + 1] = { key = shown:lower(), account = key, name = shown, main = acct.main, chars = acct.chars,
            since = acct.since, role = acct.role, online = on, status = status, where = where,
            achievements = count, roleLabel = ns.ROLE_LABEL[acct.role] or "Member",
            display = ns.WhoName(shown, acct.main) }
    end
    table.sort(list, function(a, b)
        if a.online ~= b.online then return a.online end
        return a.main < b.main
    end)
    local count = 0
    for _, m in ipairs(list) do if m.online then count = count + 1 end end
    return list, count
end

function Sync:PrintMembers()
    local f, fid = ns.Store:Active()
    if not f then
        ns.Print("You're not in a fellowship.")
        return
    end
    local list, onlineCount = self:MemberList(fid)
    ns.Print(string.format("%s: %d of %d online", ns.Escape(f.name), onlineCount, #list))
    for _, m in ipairs(list) do
        ns.Output("  " .. m.status .. "  " .. m.display .. "  |cffffd100" .. m.roleLabel .. "|r"
            .. (m.where and ("  |cffcccccc" .. m.where .. "|r") or ""))
    end
end
