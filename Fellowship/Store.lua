-- Store: the persistent, replicated event log (SavedVariables: FellowshipDB).
--
-- Every chat line, achievement, level-up and membership change is an *event*
-- identified by (author, seq). Each author numbers their own events 1, 2, 3...
-- so any two members can work out what the other is missing by comparing a
-- tiny "high-water mark" vector: for each author, the highest seq N such that
-- events 1..N are all present (or were deliberately pruned, see `floor`).
--
-- FellowshipDB = {
--   version, settings,
--   fellowships = { [fid] = {
--       id, name, created, pendingFrom,
--       events = { [author] = { [seq] = { t = serverTime, r = receivedTime, k = kind, d = {fields} } } },
--       hwm    = { [author] = n },  -- contiguous high-water mark
--       floor  = { [author] = n },  -- everything <= n is pruned/skipped on purpose
--   } },
--   chars = { ["Name-Realm"] = { fid = activeFellowship, lastRead = { [fid] = time } } },
-- }
local _, ns = ...
local Store = {}
ns.Store = Store

local MEMBERSHIP = { N = true, J = true, L = true, K = true }
local KINDS = { N = true, J = true, L = true, K = true, C = true, A = true, M = true }
ns.MEMBERSHIP_KINDS = MEMBERSHIP
ns.EVENT_KINDS = KINDS

local MAX_FIELD = 1000

-- runtime caches (not saved)
local cache = {}
local function C(fid)
    local c = cache[fid]
    if not c then c = {}; cache[fid] = c end
    return c
end
local function invalidate(fid, membership)
    local c = C(fid)
    c.sorted = nil
    if membership then c.roster = nil; c.founder = nil end
end

function Store:Init()
    FellowshipDB = FellowshipDB or {}
    local db = FellowshipDB
    db.version = db.version or 1
    db.settings = db.settings or {}
    for k, v in pairs(ns.defaults) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    db.fellowships = db.fellowships or {}
    db.chars = db.chars or {}
    db.classes = db.classes or {} -- ["Name-Realm"] = "HUNTER", learned from members
    self.db = db
    ns.settings = db.settings
end

function Store:InitCharacter()
    local c = self.db.chars[ns.me] or {}
    c.lastRead = c.lastRead or {}
    self.db.chars[ns.me] = c
    self.char = c
    if c.fid and not self.db.fellowships[c.fid] then c.fid = nil end
    for fid in pairs(self.db.fellowships) do self:Prune(fid) end
end

function Store:ActiveId()
    return self.char and self.char.fid
end

function Store:Get(fid)
    return fid and self.db.fellowships[fid] or nil
end

function Store:Active()
    local fid = self:ActiveId()
    return self:Get(fid), fid
end

function Store:Create(fid, name, pendingFrom)
    local f = self.db.fellowships[fid]
    if not f then
        f = { id = fid, name = name, created = ns.Now(), events = {}, hwm = {}, floor = {} }
        self.db.fellowships[fid] = f
    end
    f.pendingFrom = pendingFrom
    self.char.fid = fid
    self.char.lastRead[fid] = self.char.lastRead[fid] or 0
    invalidate(fid, true)
    return f
end

-- The current character leaves. History is deleted unless an alt on this account still uses it.
function Store:Forget(fid)
    if self.char.fid == fid then self.char.fid = nil end
    self.char.lastRead[fid] = nil
    for _, c in pairs(self.db.chars) do
        if c.fid == fid then return end
    end
    self.db.fellowships[fid] = nil
    cache[fid] = nil
end

local function advance(f, author)
    local h = f.hwm[author] or 0
    local fl = f.floor[author] or 0
    if fl > h then h = fl end
    local evs = f.events[author]
    while evs and evs[h + 1] do h = h + 1 end
    f.hwm[author] = h
end

local function validEvent(e)
    if type(e) ~= "table" or type(e.a) ~= "string" or not e.a:find("-", 1, true) then return false end
    if type(e.s) ~= "number" or e.s < 1 or e.s ~= math.floor(e.s) then return false end
    if type(e.t) ~= "number" or not KINDS[e.k] then return false end
    if e.d ~= nil and type(e.d) ~= "table" then return false end
    for _, v in ipairs(e.d or {}) do
        if type(v) ~= "string" and type(v) ~= "number" then return false end
        if #tostring(v) > MAX_FIELD then return false end
    end
    return true
end

-- Returns true if the event was new.
function Store:AddEvent(fid, e)
    local f = self:Get(fid)
    if not f or not validEvent(e) then return false end
    local evs = f.events[e.a]
    if not evs then evs = {}; f.events[e.a] = evs end
    if evs[e.s] then return false end
    -- Below our floor means we pruned it on purpose; only membership events are kept forever.
    if e.s <= (f.floor[e.a] or 0) and not MEMBERSHIP[e.k] then return false end
    local d = {}
    for i, v in ipairs(e.d or {}) do d[i] = tostring(v) end
    evs[e.s] = { t = e.t, r = ns.Now(), k = e.k, d = d }
    advance(f, e.a)
    invalidate(fid, MEMBERSHIP[e.k])
    return true
end

function Store:NewLocalEvent(fid, kind, data)
    local f = self:Get(fid)
    if not f then return nil end
    local me = ns.me
    local max = math.max(f.hwm[me] or 0, f.floor[me] or 0)
    for s in pairs(f.events[me] or {}) do
        if s > max then max = s end
    end
    local e = { a = me, s = max + 1, t = ns.Now(), k = kind, d = data or {} }
    if not self:AddEvent(fid, e) then return nil end
    e.d = f.events[me][e.s].d
    return e
end

function Store:SetFloor(fid, author, n)
    local f = self:Get(fid)
    if not f or type(n) ~= "number" then return end
    if n > (f.floor[author] or 0) then
        f.floor[author] = n
        advance(f, author)
    end
end

-- Events by `author` with seq > from. Membership events are always included; the
-- rest is capped at the newest `limit`. Returns events, floor-to-announce (or nil).
function Store:EventsAfter(fid, author, from, limit)
    local f = self:Get(fid)
    if not f then return {}, nil end
    local evs = f.events[author] or {}
    local seqs = {}
    for s in pairs(evs) do
        if s > from then seqs[#seqs + 1] = s end
    end
    table.sort(seqs)
    local others = {}
    for _, s in ipairs(seqs) do
        if not MEMBERSHIP[evs[s].k] then others[#others + 1] = s end
    end
    local floor = f.floor[author] or 0
    local skipBelow = 0
    if limit and #others > limit then
        skipBelow = others[#others - limit + 1]
        floor = math.max(floor, skipBelow - 1)
    end
    local out = {}
    for _, s in ipairs(seqs) do
        local e = evs[s]
        if MEMBERSHIP[e.k] or s >= skipBelow then
            out[#out + 1] = { a = author, s = s, t = e.t, k = e.k, d = e.d }
        end
    end
    return out, (floor > from) and floor or nil
end

-- All events, oldest first.
function Store:Sorted(fid)
    local c = C(fid)
    if c.sorted then return c.sorted end
    local list = {}
    local f = self:Get(fid)
    if f then
        for a, evs in pairs(f.events) do
            for s, e in pairs(evs) do
                list[#list + 1] = { a = a, s = s, t = e.t, r = e.r, k = e.k, d = e.d }
            end
        end
    end
    table.sort(list, function(x, y)
        if x.t ~= y.t then return x.t < y.t end
        if x.a ~= y.a then return x.a < y.a end
        return x.s < y.s
    end)
    c.sorted = list
    return list
end

-- Membership is derived by replaying N/J/L/K events in time order.
-- Returns roster ({ [key] = { name, since } }), founder name.
function Store:Roster(fid)
    local c = C(fid)
    if c.roster then return c.roster, c.founder end
    local roster, founder = {}, nil
    for _, e in ipairs(self:Sorted(fid)) do
        if e.k == "N" then
            founder = founder or e.a
            roster[e.a:lower()] = { name = e.a, since = e.t }
        elseif e.k == "J" then
            local who = e.d[1]
            if who and who ~= "" and roster[e.a:lower()] then
                roster[who:lower()] = { name = who, since = e.t }
            end
        elseif e.k == "L" then
            roster[e.a:lower()] = nil
        elseif e.k == "K" then
            local who = e.d[1]
            if who and e.a == founder then roster[who:lower()] = nil end
        end
    end
    c.roster, c.founder = roster, founder
    return roster, founder
end

function Store:IsMember(fid, name)
    return self:Roster(fid)[ns.Key(name)] ~= nil
end

function Store:GetClass(name)
    return name and self.db and self.db.classes[name]
end

function Store:SetClass(name, token)
    if type(name) ~= "string" or type(token) ~= "string" then return false end
    if not token:match("^%u+$") or #token > 20 or self.db.classes[name] == token then return false end
    self.db.classes[name] = token
    return true
end

function Store:LastRead(fid)
    return self.char.lastRead[fid] or 0
end

function Store:MarkRead(fid)
    self.char.lastRead[fid] = ns.Now()
end

function Store:IsUnread(fid, e)
    return e.a ~= ns.me and (e.r or e.t) > self:LastRead(fid)
end

function Store:UnreadCounts(fid)
    local chats, achievements = 0, 0
    for _, e in ipairs(self:Sorted(fid)) do
        if self:IsUnread(fid, e) then
            if e.k == "C" then chats = chats + 1
            elseif e.k == "A" or e.k == "M" then achievements = achievements + 1 end
        end
    end
    return chats, achievements
end

function Store:LastActive(fid, author)
    local last
    local f = self:Get(fid)
    for _, e in pairs(f and f.events[author] or {}) do
        if not last or e.t > last then last = e.t end
    end
    return last
end

-- Drop old chat/achievements beyond maxEvents or maxAgeDays. Membership events stay.
function Store:Prune(fid)
    local f = self:Get(fid)
    if not f then return 0 end
    local s = ns.settings
    local cutoff = ns.Now() - (s.maxAgeDays or 180) * 86400
    local prunable = {}
    for _, e in ipairs(self:Sorted(fid)) do
        if not MEMBERSHIP[e.k] then prunable[#prunable + 1] = e end
    end
    local excess = #prunable - (s.maxEvents or 3000)
    local removed = 0
    for i, e in ipairs(prunable) do
        if i <= excess or e.t < cutoff then
            f.events[e.a][e.s] = nil
            if e.s > (f.floor[e.a] or 0) then f.floor[e.a] = e.s end
            removed = removed + 1
        end
    end
    if removed > 0 then
        for a in pairs(f.floor) do advance(f, a) end
        invalidate(fid, false)
    end
    return removed
end
