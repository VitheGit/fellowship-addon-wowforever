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

-- Membership/role events: never pruned, replayed to compute the roster.
--   N founded  J joined  L left  K removed  V roles switched on
--   R set role (inviter/member)  T admin offer  X admin offer accepted  W admin offer declined
--   Q "this character belongs to account <id>" (with the account's secret code)
--   Y an alt joins through its account (same id + secret code)
local MEMBERSHIP = { N = true, J = true, L = true, K = true, V = true, R = true, T = true, X = true, W = true,
    Q = true, Y = true }
local KINDS = { C = true, A = true, M = true }
for k in pairs(MEMBERSHIP) do KINDS[k] = true end
ns.MEMBERSHIP_KINDS = MEMBERSHIP
ns.EVENT_KINDS = KINDS

-- Kept forever (never pruned, always sent in a catch-up): membership events and
-- Fellowship Achievements ("M" events with subtype "feat").
local function keep(k, d)
    return MEMBERSHIP[k] or (k == "M" and type(d) == "table" and d[1] == "feat")
end
ns.KeepForever = keep

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
    if membership then c.roster = nil; c.admin = nil; c.state = nil end
end

function Store:Init()
    FellowshipDB = FellowshipDB or {}
    local db = FellowshipDB
    db.version = db.version or 1
    db.settings = db.settings or {}
    if db.settings.echoAchievements ~= nil then -- v0.1-0.6 had one switch for achievements and levels
        db.settings.showAchievements = db.settings.echoAchievements
        db.settings.showLevels = db.settings.echoAchievements
        db.settings.echoAchievements = nil
    end
    for k, v in pairs(ns.defaults) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    db.fellowships = db.fellowships or {}
    db.chars = db.chars or {}
    db.classes = db.classes or {} -- ["Name-Realm"] = "HUNTER", learned from members
    db.seen = db.seen or {}       -- ["Name-Realm"] = server time we last heard from them
    -- This WoW account's identity in fellowships: the id is shared with members, and so is the
    -- secret code, which is what lets an alt on this account join without an invite.
    if type(db.account) ~= "table" or not db.account.id then
        local function rand(n)
            local chars, out = "abcdefghijklmnopqrstuvwxyz0123456789", {}
            for i = 1, n do
                local k = math.random(1, #chars)
                out[i] = chars:sub(k, k)
            end
            return table.concat(out)
        end
        db.account = { id = "a" .. rand(11), secret = rand(16) }
    end
    ns.account = db.account
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

-- This account leaves: every character on it stops using the fellowship and its history is deleted.
function Store:Forget(fid)
    for _, c in pairs(self.db.chars) do
        if c.fid == fid then c.fid = nil end
        if c.lastRead then c.lastRead[fid] = nil end
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
    -- Below our floor means we pruned it on purpose; only membership events and feats are kept forever.
    if e.s <= (f.floor[e.a] or 0) and not keep(e.k, e.d) then return false end
    local d = {}
    for i, v in ipairs(e.d or {}) do d[i] = tostring(v) end
    evs[e.s] = { t = e.t, r = ns.Now(), k = e.k, d = d }
    advance(f, e.a)
    invalidate(fid, MEMBERSHIP[e.k])
    return true
end

function Store:NewLocalEvent(fid, kind, data, minTime)
    local f = self:Get(fid)
    if not f then return nil end
    local me = ns.me
    local max = math.max(f.hwm[me] or 0, f.floor[me] or 0)
    for s in pairs(f.events[me] or {}) do
        if s > max then max = s end
    end
    local e = { a = me, s = max + 1, t = math.max(ns.Now(), minTime or 0), k = kind, d = data or {} }
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
        if not keep(evs[s].k, evs[s].d) then others[#others + 1] = s end
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
        if keep(e.k, e.d) or s >= skipBelow then
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

-- Membership and roles are derived by replaying the membership events in time order,
-- so every member computes the same answer from the same history.
--
-- Members are *accounts*. A character joins through J (invite) or Y (an alt of a member
-- account); Q ties a character to its account id, merging characters that were invited
-- separately. Roles, Admin, leaving and removal all apply to the whole account.
--
-- Returns:
--   roster: { [charKey] = { name, since, role, account = acctKey, main = account's main name } }
--   admin:  the Admin account's main character name
--   state:  { founder, rolesOn, accounts = { [acctKey] = acct }, adminAccount, offer }
--           acct = { key, secret, main, since, role, chars = { name, ... } }
--           offer = { target = acctKey, targetName, author, seq, t }
local RANK = { admin = 3, inviter = 2, member = 1 }

function Store:Roster(fid)
    local c = C(fid)
    if c.roster then return c.roster, c.admin, c.state end
    local accounts, charAcct = {}, {}  -- acctKey -> acct, charKey -> acctKey
    local state = { rolesOn = false, accounts = accounts }
    local adminKey
    local function lower(n) return n and ns.Key(n) end
    local function acctOf(name) return name and charAcct[lower(name)] end
    local function addChar(acct, name)
        charAcct[lower(name)] = acct.key
        acct.chars[#acct.chars + 1] = name
    end
    local function newAccount(name, t)
        local acct = { key = "char:" .. lower(name), main = name, since = t, role = "member", chars = {} }
        accounts[acct.key] = acct
        addChar(acct, name)
        return acct
    end
    local function removeAccount(key)
        local acct = accounts[key]
        if not acct then return end
        for _, n in ipairs(acct.chars) do charAcct[lower(n)] = nil end
        accounts[key] = nil
        local o = state.offer
        if o and (o.target == key or acctOf(o.author) == nil) then state.offer = nil end
        if adminKey == key then
            adminKey = nil
            local best
            for _, a in pairs(accounts) do
                if not best or RANK[a.role] > RANK[best.role] or (RANK[a.role] == RANK[best.role]
                    and (a.since < best.since or (a.since == best.since and a.main < best.main))) then
                    best = a
                end
            end
            if best then adminKey = best.key; best.role = "admin" end
        end
    end
    local function setAdmin(key)
        if adminKey and accounts[adminKey] then accounts[adminKey].role = "inviter" end
        adminKey = key
        if accounts[key] then accounts[key].role = "admin" end
    end
    local function isAdmin(name) return adminKey ~= nil and acctOf(name) == adminKey end
    local function canInvite(name)
        local acct = accounts[acctOf(name) or ""]
        if not acct then return false end
        return not state.rolesOn or acct.role == "admin" or acct.role == "inviter"
    end
    local function offerMatches(e)
        local o = state.offer
        return o and acctOf(e.a) == o.target and o.author == e.d[1] and tostring(o.seq) == e.d[2]
            and isAdmin(o.author)
    end

    for _, e in ipairs(self:Sorted(fid)) do
        local k, d = e.k, e.d
        if k == "N" then
            if not state.founder then
                state.founder = e.a
                setAdmin(newAccount(e.a, e.t).key)
            end
        elseif k == "J" then
            local who = d[1]
            if who and who ~= "" and canInvite(e.a) and not acctOf(who) then newAccount(who, e.t) end
        elseif k == "L" then
            local key = acctOf(e.a)
            if key then removeAccount(key) end
        elseif k == "K" then
            local key = acctOf(d[1])
            if key and isAdmin(e.a) and key ~= adminKey then removeAccount(key) end
        elseif k == "V" then
            if isAdmin(e.a) then state.rolesOn = true end
        elseif k == "R" then
            local key, role = acctOf(d[1]), d[2]
            local acct = key and accounts[key]
            if isAdmin(e.a) and acct and key ~= adminKey and (role == "inviter" or role == "member") then
                acct.role = role
            end
        elseif k == "T" then
            if isAdmin(e.a) then
                local key = acctOf(d[1])
                if key and key ~= adminKey then
                    state.offer = { target = key, targetName = accounts[key].main, author = e.a, seq = e.s, t = e.t }
                else
                    state.offer = nil
                end
            end
        elseif k == "X" then
            if offerMatches(e) then
                local key = state.offer.target
                state.offer = nil
                setAdmin(key)
            end
        elseif k == "W" then
            if offerMatches(e) then state.offer = nil end
        elseif k == "Q" then
            local id, secret = d[1], d[2]
            local fromKey = acctOf(e.a)
            local from = fromKey and accounts[fromKey]
            if from and id and id ~= "" and secret and secret ~= "" and fromKey:sub(1, 5) == "char:" then
                local into = accounts[id]
                if into and into.secret == secret then
                    -- merge a separately invited character into its account
                    for _, n in ipairs(from.chars) do addChar(into, n) end
                    if RANK[from.role] > RANK[into.role] then into.role = from.role end
                    if from.since < into.since then into.since, into.main = from.since, from.main end
                    accounts[fromKey] = nil
                    if adminKey == fromKey then adminKey = id end
                    if state.offer and state.offer.target == fromKey then state.offer.target = id end
                elseif not into then
                    accounts[fromKey] = nil
                    from.key, from.secret = id, secret
                    accounts[id] = from
                    for _, n in ipairs(from.chars) do charAcct[lower(n)] = id end
                    if adminKey == fromKey then adminKey = id end
                    if state.offer and state.offer.target == fromKey then state.offer.target = id end
                end
            end
        elseif k == "Y" then
            local acct = accounts[d[1] or ""]
            if acct and acct.secret and acct.secret == d[2] and not acctOf(e.a) then addChar(acct, e.a) end
        end
    end

    local roster = {}
    for key, acct in pairs(accounts) do
        for _, n in ipairs(acct.chars) do
            roster[lower(n)] = { name = n, since = acct.since, role = acct.role, account = key, main = acct.main }
        end
    end
    state.adminAccount = adminKey
    local admin = adminKey and accounts[adminKey] and accounts[adminKey].main
    c.roster, c.admin, c.state = roster, admin, state
    return roster, admin, state
end

function Store:Role(fid, name)
    local m = self:Roster(fid)[ns.Key(name)]
    return m and m.role
end

function Store:IsAdmin(fid, name)
    local m = self:Roster(fid)[ns.Key(name)]
    return m ~= nil and m.role == "admin"
end

-- Are these two characters on the same member account?
function Store:SameAccount(fid, a, b)
    local roster = self:Roster(fid)
    local ma, mb = roster[ns.Key(a)], roster[ns.Key(b)]
    return ma ~= nil and mb ~= nil and ma.account == mb.account
end

function Store:CanInvite(fid, name)
    local roster, _, state = self:Roster(fid)
    local m = roster[ns.Key(name)]
    if not m then return false end
    return not state.rolesOn or m.role == "admin" or m.role == "inviter"
end

function Store:IsMember(fid, name)
    return self:Roster(fid)[ns.Key(name)] ~= nil
end

function Store:SetSeen(name)
    if self.db and name then self.db.seen[ns.Key(name)] = ns.Now() end
end

function Store:GetSeen(name)
    return name and self.db and (self.db.seen[ns.Key(name)] or self.db.seen[name])
end

function Store:GetClass(name)
    return name and self.db and (self.db.classes[ns.Key(name)] or self.db.classes[name])
end

function Store:SetClass(name, token)
    if type(name) ~= "string" or type(token) ~= "string" then return false end
    name = ns.Key(name)
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
        if not keep(e.k, e.d) then prunable[#prunable + 1] = e end
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
