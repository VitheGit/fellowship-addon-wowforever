-- ItemSearch: find items by name for the wishlist box ("ore" -> Copper Ore, Iron Ore...).
--
-- The game has no search-by-name for addons: an item's name is only known once the client
-- has asked the server about it. So we build our own index, saved account-wide:
--   1. Every item we come across (loot, tooltips, chat links, friends' wishlists) is learned.
--   2. A slow background scan: first find which item numbers exist (a local, instant check),
--      then ask the server for their names a few at a time. It pauses in combat and in
--      dungeons/raids, picks up where it left off after a logout, and runs again after a patch.
--
-- FellowshipDB.items = { names = { [id] = name }, quality = { [id] = q },
--                        scan = { build, phase = "find"|"names"|"done", next, todo = { ids } } }
local _, ns = ...
local S = {}
ns.ItemSearch = S

S.MAX_ID = 300000      -- highest item number checked
S.FIND_PER_TICK = 4000 -- local existence checks per tick
S.NAMES_PER_TICK = 4   -- server name requests per tick (ticks are 0.2s: about 20 per second)
S.TICK = 0.2
S.START_DELAY = 45     -- let login traffic settle first

local db

local function instant(id)
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    return fn and fn(id)
end

local function build()
    if not GetBuildInfo then return "?" end
    local version, buildNum = GetBuildInfo()
    return tostring(version) .. "_" .. tostring(buildNum)
end

function S:Init()
    local root = ns.Store.db
    root.items = root.items or {}
    db = root.items
    db.names = db.names or {}
    db.quality = db.quality or {}
    local b = build()
    if type(db.scan) ~= "table" or db.scan.build ~= b then
        -- new install or a patch: look for new items again (names already learned are kept)
        db.scan = { build = b, phase = "find", next = 1, todo = {} }
    end
    ns.On("GET_ITEM_INFO_RECEIVED", function(id, success)
        if success ~= false then S:Learn(id) end
    end)
    C_Timer.After(self.START_DELAY, function()
        C_Timer.NewTicker(S.TICK, function() S:Tick() end)
    end)
end

-- Remember an item's name if the game knows it now. Returns the name.
function S:Learn(id, name, quality)
    id = tonumber(id)
    if not db or not id then return nil end
    if not name and GetItemInfo then
        local n, _, q = GetItemInfo(id)
        name, quality = n, quality or q
    end
    if type(name) == "string" and name ~= "" then
        db.names[id] = name
        if tonumber(quality) then db.quality[id] = tonumber(quality) end
    end
    return db.names[id]
end

function S:Count()
    local n = 0
    for _ in pairs(db and db.names or {}) do n = n + 1 end
    return n
end

-- "learning 40%" while the scan runs, nil once done
function S:Progress()
    local scan = db and db.scan
    if not scan or scan.phase == "done" then return nil end
    if scan.phase == "find" then return math.floor(10 * (scan.next or 1) / S.MAX_ID) end
    local total = scan.total or #scan.todo
    if total == 0 then return 100 end
    return 10 + math.floor(90 * (total - #scan.todo) / total)
end

local function busy()
    if InCombatLockdown and InCombatLockdown() then return true end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return true end
    if IsInInstance and IsInInstance() then return true end
    return false
end

function S:Tick()
    local scan = db and db.scan
    if not scan or scan.phase == "done" or busy() then return end
    if scan.phase == "find" then
        local last = math.min(S.MAX_ID, scan.next + S.FIND_PER_TICK - 1)
        for id = scan.next, last do
            if not db.names[id] and instant(id) then scan.todo[#scan.todo + 1] = id end
        end
        scan.next = last + 1
        if scan.next > S.MAX_ID then
            scan.phase = "names"
            scan.total = #scan.todo
        end
        return
    end
    -- names: ask the server about a few items; GET_ITEM_INFO_RECEIVED fills them in
    for _ = 1, S.NAMES_PER_TICK do
        local id = table.remove(scan.todo)
        if not id then
            scan.phase = "done"
            scan.total = nil
            ns.Fire("ITEM_SEARCH_READY")
            return
        end
        if not db.names[id] then
            if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
            self:Learn(id) -- already cached: learned right away
        end
    end
end

-- Up to `limit` matches for what was typed: { { id, name, quality }, ... }, best first.
-- Every word typed must appear; names starting with it come first, then words starting with it.
function S:Search(text, limit)
    limit = limit or 12
    text = ns.Trim(text):lower()
    if #text < 2 or not db then return {} end
    local words = {}
    for w in text:gmatch("%S+") do words[#words + 1] = w end
    local first = words[1]
    local hits = {}
    for id, name in pairs(db.names) do
        local low = name:lower()
        local ok = true
        for _, w in ipairs(words) do
            if not low:find(w, 1, true) then ok = false; break end
        end
        if ok then
            local rank = 2
            if low:sub(1, #text) == text then rank = 0
            elseif low:find(" " .. first, 1, true) or low:sub(1, #first) == first then rank = 1 end
            hits[#hits + 1] = { id = id, name = name, quality = db.quality[id], rank = rank }
        end
    end
    table.sort(hits, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if #a.name ~= #b.name then return #a.name < #b.name end
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
    local out, seen = {}, {}
    for _, h in ipairs(hits) do
        if #out >= limit then break end
        if not seen[h.name] then -- same name, different item number: show it once
            seen[h.name] = true
            out[#out + 1] = h
        end
    end
    return out, #hits
end
