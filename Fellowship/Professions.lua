-- Professions: each member's Fellowship reads its own character's professions and skill levels
-- (GetProfessions / GetProfessionInfo) and shares them, so the Members tab can list them.
-- Nobody types anything: it updates by itself when a skill goes up or a profession is learned.
-- Synced like notes, outside the event log, so older versions just ignore it:
--   PL  fid proto "" ver | name v profs deaths one character's professions and death count (newest v wins)
--   PV  fid proto reply ver | name v | ...     "these are the ones I have" (with a HI reply)
-- profs is "Mining:150:300;Cooking:75:150" (name:level:max). deaths is the game's lifetime
-- "Total deaths" statistic (GetStatistic(60)), so it counts deaths from before Fellowship too.
local _, ns = ...
local P = {}
ns.Professions = P

P.SCAN_DELAY = 3

local function store(fid)
    local f = ns.Store:Get(fid)
    if not f then return nil end
    f.profs = f.profs or {}
    return f.profs
end

local function header(typ, fid, extra)
    return { typ, fid, ns.PROTOCOL, extra or "", ns.VERSION }
end

local function cleanName(s)
    return (tostring(s or ""):gsub("[%c|:;]", ""):sub(1, 40))
end

function P.Encode(list)
    local parts = {}
    for _, p in ipairs(list) do
        parts[#parts + 1] = cleanName(p.name) .. ":" .. (tonumber(p.level) or 0) .. ":" .. (tonumber(p.max) or 0)
    end
    return table.concat(parts, ";")
end

function P.Decode(s)
    local out = {}
    for part in tostring(s or ""):gmatch("[^;]+") do
        local name, level, max = part:match("^([^:]+):(%d+):(%d+)$")
        if name and #out < 8 then out[#out + 1] = { name = name, level = tonumber(level), max = tonumber(max) } end
    end
    return out
end

-- This character's professions, read from the game: primary ones first, then the rest.
function P.Read()
    if not (GetProfessions and GetProfessionInfo) then return nil end
    local ids = { GetProfessions() } -- prof1, prof2, archaeology, fishing, cooking (some may be nil)
    local n = select("#", GetProfessions())
    local out = {}
    for i = 1, n do
        local idx = ids[i]
        if idx then
            local ok, name, _, level, max = pcall(GetProfessionInfo, idx)
            if ok and name and name ~= "" then
                out[#out + 1] = { name = name, level = level or 0, max = max or 0, primary = i <= 2 }
            end
        end
    end
    return out
end

-- Professions of one character: { { name, level, max }, ... }
function P:For(name, fid)
    fid = fid or ns.Store:ActiveId()
    local all = fid and store(fid) or {}
    local r = all[ns.Key(name)]
    return r and P.Decode(r.text) or {}
end

-- "Mining 150, Blacksmithing 120" (the first `limit` professions)
function P.Short(list, limit)
    local parts = {}
    for i, p in ipairs(list) do
        if limit and i > limit then break end
        parts[#parts + 1] = p.name .. " " .. p.level
    end
    return table.concat(parts, ", ")
end

function P:Records(fid, key)
    local r = (store(fid) or {})[key]
    if not r then return nil end
    return { header("PL", fid), { r.name, r.v, r.text, r.deaths and tostring(r.deaths) or "" } }
end

-- Lifetime deaths of this character from the game's statistics, or nil if unavailable.
P.DEATH_STAT = 60
function P.ReadDeaths()
    if not GetStatistic then return nil end
    local ok, v = pcall(GetStatistic, P.DEATH_STAT)
    if not ok then return nil end
    if v == "--" or v == "" then return 0 end
    return tonumber(v)
end

-- How many times one character has died (nil if unknown)
function P:Deaths(name, fid)
    fid = fid or ns.Store:ActiveId()
    local all = fid and store(fid) or {}
    local r = all[ns.Key(name)]
    return r and r.deaths
end

local function publish(fid, all, text, deaths)
    local cur = all[ns.meKey]
    all[ns.meKey] = { name = ns.me, v = math.max(((cur and cur.v) or 0) + 1, ns.Now()), text = text, deaths = deaths }
    local f = ns.Store:Get(fid)
    if not f.pendingFrom then ns.Sync:Broadcast(fid, P:Records(fid, ns.meKey)) end
    ns.Fire("PROFESSIONS_CHANGED", fid, ns.meKey)
end

-- You just died: returns your new death count and shares it. The statistic can lag a moment
-- behind the death, so it never goes backwards or repeats the last number.
function P:NoteDeath()
    local stat = P.ReadDeaths()
    local fid = ns.Store:ActiveId()
    local all = fid and store(fid)
    local cur = all and ns.me and all[ns.meKey]
    local last = (cur and cur.deaths) or ns.charDeaths
    local n = stat
    if not n then n = (last or 0) + 1
    elseif last and n <= last then n = last + 1 end
    ns.charDeaths = n
    if all and ns.me then publish(fid, all, (cur and cur.text) or P.Encode(P.Read() or {}), n) end
    return n
end

-- Read ours and share it if anything changed.
function P:Scan()
    local fid = ns.Store:ActiveId()
    local all = fid and store(fid)
    if not all or not ns.me then return end
    local cur = all[ns.meKey]
    local list = P.Read()
    local text = list and P.Encode(list) or (cur and cur.text) or ""
    local deaths = P.ReadDeaths()
    if deaths and cur and cur.deaths and deaths < cur.deaths then deaths = cur.deaths end
    deaths = deaths or (cur and cur.deaths)
    if cur and cur.text == text and cur.deaths == deaths then return end
    if not cur and not list and not deaths then return end
    publish(fid, all, text, deaths)
end

local queued = false
function P:QueueScan(delay)
    if queued then return end
    queued = true
    C_Timer.After(delay or P.SCAN_DELAY, function()
        queued = false
        P:Scan()
    end)
end

function P:OnList(sender, fid, records)
    local r = records[2]
    local name, v = r and ns.NormalizeName(r[1]), r and tonumber(r[2])
    if not name or not v then return end
    local key = ns.Key(name)
    if not ns.Store:Roster(fid)[key] then return end
    local all = store(fid)
    local cur = all[key]
    if cur and (cur.v or 0) >= v then return end
    all[key] = { name = name, v = v, text = P.Encode(P.Decode(r[3])), deaths = tonumber(r[4]) }
    ns.Fire("PROFESSIONS_CHANGED", fid, key)
end

function P:SendSummary(fid, target, wantReply)
    local rec = { header("PV", fid, wantReply and "1" or "0") }
    local roster = ns.Store:Roster(fid)
    for key, r in pairs(store(fid) or {}) do
        if roster[key] then rec[#rec + 1] = { r.name, r.v } end
    end
    if #rec == 1 and wantReply then return end -- nothing to offer
    ns.Sync:SendRaw(target, rec, true)
end

function P:OnSummary(sender, fid, records, wantReply)
    local theirs = {}
    for i = 2, #records do
        local name, v = records[i][1], tonumber(records[i][2])
        if name and v then theirs[ns.Key(name)] = v end
    end
    local roster = ns.Store:Roster(fid)
    local all = store(fid) or {}
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

ns.On("PLAYER_LOGIN", function() P:QueueScan(10) end)
ns.On("SKILL_LINES_CHANGED", function() P:QueueScan() end)
ns.On("CHAT_MSG_SKILL", function() P:QueueScan() end)
ns.On("PLAYER_ALIVE", function() P:QueueScan(5) end)
ns.Listen("FELLOWSHIP_CHANGED", function() P:QueueScan() end)
