-- Feats: Fellowship Achievements, earned together.
--
-- A dungeon or raid counts when its final boss dies and every player in the group is a
-- member of your fellowship (at least two of you; NPC followers don't count either way).
-- Every member in the group detects it and posts the same feat; the earliest one is the
-- date it was earned, and only that one is announced.
--
-- Feats are "M" events, so older versions still store and relay them (they show them as
-- "hit a milestone: Deadmines (Heroic)"). Unlike other activity they are never pruned.
--   feat data: { "feat", title, category ("dungeon"|"raid"), instance, difficulty, members }
--   members: "First-Last,First-Last,..."
local _, ns = ...
local F = {}
ns.Feats = F

local GOLD = "|cffffd100"

function F.IsFeat(e)
    return e ~= nil and e.k == "M" and type(e.d) == "table" and e.d[1] == "feat"
end

local function lower(s) return tostring(s or ""):lower() end

-- One achievement per instance and difficulty.
function F.KeyOf(d)
    return lower(d[3]) .. "|" .. lower(d[4]) .. "|" .. lower(d[5])
end

function F.Title(name, difficulty)
    if difficulty and difficulty ~= "" then return name .. " (" .. difficulty .. ")" end
    return name
end

function F.Members(d)
    local out = {}
    for n in tostring(d[6] or ""):gmatch("[^,]+") do out[#out + 1] = n end
    return out
end

-- "Anna, Bob and Cara"
function F.JoinNames(names, color)
    local parts = {}
    for i, n in ipairs(names) do parts[i] = color and ns.ColorName(n) or ns.Short(n) end
    if #parts <= 1 then return parts[1] or "" end
    return table.concat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts]
end

---------------------------------------------------------------------------
-- What has been earned (derived from the event log, cached per sorted list)
---------------------------------------------------------------------------
local cacheList, cacheEarned, cacheFirst

-- Returns { [key] = { key, title, category, instance, difficulty, t, members, author } }
-- and a set of the events that earned each one (the first of each key).
function F:Earned(fid)
    local list = ns.Store:Sorted(fid)
    if list == cacheList then return cacheEarned, cacheFirst end
    local earned, first = {}, {}
    for _, e in ipairs(list) do -- oldest first, so the first one seen wins
        if F.IsFeat(e) then
            local key = F.KeyOf(e.d)
            if not earned[key] then
                earned[key] = {
                    key = key, title = e.d[2], category = e.d[3], instance = e.d[4], difficulty = e.d[5],
                    t = e.t, members = F.Members(e.d), author = e.a,
                }
                first[e.a .. "#" .. e.s] = true
            end
        end
    end
    cacheList, cacheEarned, cacheFirst = list, earned, first
    return earned, first
end

-- Is this the event that earned its feat (not a duplicate from another member of the group)?
function F:IsFirst(e)
    local fid = ns.Store:ActiveId()
    if not fid then return false end
    local _, first = self:Earned(fid)
    return first[e.a .. "#" .. e.s] == true
end

-- Printed in chat at most once per achievement per session; returns true the first time.
local announced = {}
function F:MarkAnnounced(e)
    local key = F.KeyOf(e.d)
    if announced[key] then return false end
    announced[key] = true
    return true
end

function F.Format(e)
    local d = e.d
    local names = F.Members(d)
    local with = #names > 0 and (" with " .. F.JoinNames(names, true)) or ""
    local verb = d[3] == "raid" and "cleared " or "completed "
    return GOLD .. "Fellowship Achievement:|r " .. verb .. GOLD .. "[" .. ns.Escape(d[2]) .. "]|r" .. with .. "!"
end

---------------------------------------------------------------------------
-- Detecting a completion
---------------------------------------------------------------------------
-- Everyone in your group as "First-Last", or nil if any player can't be identified yet.
function F:GroupPlayers()
    if not (IsInGroup and IsInGroup()) then return { ns.me } end
    local names, seen = {}, {}
    local function add(full)
        local key = ns.Key(full)
        if not seen[key] then seen[key] = true; names[#names + 1] = full end
    end
    add(ns.me)
    local raid = IsInRaid and IsInRaid()
    local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
    local ok = true
    local function check(unit)
        if not (UnitExists and UnitExists(unit)) then return end
        if UnitIsUnit and UnitIsUnit(unit, "player") then return end
        if not UnitIsPlayer(unit) then return end -- NPC followers
        local name, realm = UnitFullName(unit)
        if not name or name == "" or name == UNKNOWNOBJECT then ok = false; return end
        local full = ns.NormalizeName(realm and realm ~= "" and (name .. "-" .. realm) or name)
        if full then add(full) else ok = false end
    end
    if raid then
        for i = 1, n do check("raid" .. i) end
    else
        for i = 1, math.max(0, n - 1) do check("party" .. i) end
    end
    if not ok then return nil end
    return names
end

-- Called by Announce when the final boss of a dungeon or raid dies.
-- Returns the feat event if one was posted (and why not, otherwise).
function F:OnInstanceComplete(category, instance, difficulty)
    local f, fid = ns.Store:Active()
    if not f or f.pendingFrom or not instance or instance == "" then return nil, "no fellowship" end
    local players = self:GroupPlayers()
    if not players then return nil, "unknown player" end
    if #players < 2 then return nil, "solo" end
    for _, name in ipairs(players) do
        if not ns.Store:IsMember(fid, name) then return nil, "not everyone is a member" end
    end
    local d = { "feat", F.Title(instance, difficulty), category, instance, difficulty or "", "" }
    local key = F.KeyOf(d)
    local earned = self:Earned(fid)
    if earned[key] then return nil, "already earned" end
    table.sort(players, function(a, b) return ns.Short(a):lower() < ns.Short(b):lower() end)
    d[6] = ns.Truncate(table.concat(players, ","), 900)
    local e = ns.Sync:Publish("M", d)
    if e and self:IsFirst(e) and self:MarkAnnounced(e) then
        ns.Echo(F.Format(e))
        local sound = SOUNDKIT and (SOUNDKIT.UI_PERSONAL_ACHIEVEMENT_EARNED or SOUNDKIT.LEVELUP)
        if PlaySound and sound then pcall(PlaySound, sound) end
    end
    return e
end

---------------------------------------------------------------------------
-- Every dungeon and raid the game knows about (Encounter Journal), for the
-- not-yet-earned rows. Empty if the journal isn't available.
---------------------------------------------------------------------------
local allInstances

function F:AllInstances()
    if allInstances then return allInstances end
    local list, seen = {}, {}
    if EJ_GetInstanceByIndex then
        pcall(function()
            local tiers = (EJ_GetNumTiers and EJ_GetNumTiers()) or 1
            local current = EJ_GetCurrentTier and EJ_GetCurrentTier()
            for tier = 1, tiers do
                if EJ_SelectTier then EJ_SelectTier(tier) end
                for _, isRaid in ipairs({ false, true }) do
                    local i = 1
                    while i < 200 do
                        local id, name = EJ_GetInstanceByIndex(i, isRaid)
                        if not id then break end
                        if name and not seen[name:lower()] then
                            seen[name:lower()] = true
                            list[#list + 1] = { name = name, category = isRaid and "raid" or "dungeon" }
                        end
                        i = i + 1
                    end
                end
            end
            if current and EJ_SelectTier then EJ_SelectTier(current) end
        end)
    end
    allInstances = list
    return list
end

-- Rows for the Achievements tab: earned (newest first), then not yet earned (A-Z).
function F:Rows(fid)
    local earned = self:Earned(fid)
    local rows, done = {}, {}
    for _, a in pairs(earned) do
        rows[#rows + 1] = a
        done[lower(a.instance)] = true
    end
    table.sort(rows, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        return a.title < b.title
    end)
    local earnedCount = #rows
    local todo = {}
    for _, inst in ipairs(self:AllInstances()) do
        if not done[lower(inst.name)] then
            todo[#todo + 1] = { title = inst.name, category = inst.category, instance = inst.name }
        end
    end
    table.sort(todo, function(a, b)
        if a.category ~= b.category then return a.category == "dungeon" end
        return a.title < b.title
    end)
    for _, r in ipairs(todo) do rows[#rows + 1] = r end
    return rows, earnedCount, #todo
end
