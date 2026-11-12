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

-- "Loot Kills has completed Gnomeregan!" (difficulty shown when it isn't Normal)
function F.Format(e)
    local d = e.d
    local f = ns.Store:Active()
    local fellowship = f and f.name or "The fellowship"
    local diff = d[5] or ""
    local place = (diff ~= "" and diff ~= "Normal") and F.Title(d[4] or d[2], diff) or (d[4] or d[2])
    return GOLD .. ns.Escape(fellowship) .. " has completed " .. ns.Escape(place) .. "!|r"
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
    if not players then self:Note("No achievement: couldn't read everyone's name"); return nil, "unknown player" end
    if #players < 2 then self:Note("No achievement: you need at least two players"); return nil, "solo" end
    for _, name in ipairs(players) do
        if not ns.Store:IsMember(fid, name) then
            self:Note("No achievement: " .. ns.Short(name) .. " isn't in the fellowship")
            return nil, "not everyone is a member"
        end
    end
    local d = { "feat", F.Title(instance, difficulty), category, instance, difficulty or "", "" }
    local key = F.KeyOf(d)
    local earned = self:Earned(fid)
    if earned[key] then self:Note("Already earned: " .. d[2]); return nil, "already earned", true end
    table.sort(players, function(a, b) return ns.Short(a):lower() < ns.Short(b):lower() end)
    d[6] = ns.Truncate(table.concat(players, ","), 900)
    local e = ns.Sync:Publish("M", d)
    self:Note("Fellowship Achievement earned: " .. d[2])
    if e and self:IsFirst(e) and self:MarkAnnounced(e) then
        ns.Echo(F.Format(e))
        local sound = SOUNDKIT and (SOUNDKIT.UI_PERSONAL_ACHIEVEMENT_EARNED or SOUNDKIT.LEVELUP)
        if PlaySound and sound then pcall(PlaySound, sound) end
    end
    return e
end

---------------------------------------------------------------------------
-- Every dungeon and raid the game knows about, for the Achievements cards.
-- Names, level ranges and artwork come from the Dungeon Finder list (the same art as the
-- game's dungeon picker), with the Encounter Journal as a second source. Both are read
-- defensively: anything missing just means a card without a picture or level range.
---------------------------------------------------------------------------
local LFG_ART = "Interface\\LFGFrame\\UI-LFG-BACKGROUND-"

-- "The Deadmines" and "Deadmines" are the same place.
-- Different names for the same place (WoW Forever calls it "Stormwind Stockade").
local ALIASES = {
    stockade = "stormwindstockade", stockades = "stormwindstockade", stormwindstockades = "stormwindstockade",
    templeofatalhakkar = "sunkentemple",
    barrowsdeep = "barrowdeeps", barrowsdeeps = "barrowdeeps", barrowdeep = "barrowdeeps",
    dalaran = "cityofdalaran",
}

function F.NameKey(name)
    local n = lower(name):gsub("^the ", ""):gsub("[^%w]", "")
    return ALIASES[n] or n
end

local function addInstance(list, byKey, name, category, fields)
    if type(name) ~= "string" or name == "" or name:find("^Random ") then return end
    local key = F.NameKey(name)
    local inst = byKey[key]
    if not inst then
        inst = { name = name, key = key, category = category }
        byKey[key] = inst
        list[#list + 1] = inst
    end
    for k, v in pairs(fields) do
        if inst[k] == nil and v ~= nil and v ~= "" and v ~= 0 then inst[k] = v end
    end
    -- the lowest level range across difficulties (heroic versions start higher)
    if fields.minLevel and fields.minLevel > 0 and fields.minLevel < (inst.minLevel or math.huge) then
        inst.minLevel, inst.maxLevel = fields.minLevel, fields.maxLevel
    end
end

-- Built in, so the cards always show even when the game doesn't hand addons its dungeon
-- list (and only these, plus the Encounter Journal's, count as dungeons). Levels are WoW Forever's where known (from its dungeon picker), classic otherwise;
-- the game's own numbers win when it does give them. art = Dungeon Finder picture name.
local BUILTIN = {
    dungeon = {
        { "Hall of Thanes", 13, 18, nil },
        { "Ragefire Chasm", 13, 18, "RAGEFIRECHASM" },
        { "Ruins of Lordaeron", 15, 20, nil },
        { "Wailing Caverns", 17, 24, "WAILINGCAVERNS" },
        { "The Deadmines", 17, 26, "DEADMINES" },
        { "Shadowfang Keep", 22, 30, "SHADOWFANGKEEP" },
        { "Blackfathom Deeps", 24, 32, "BLACKFATHOMDEEPS" },
        { "Stormwind Stockade", 24, 32, "STORMWINDSTOCKADES" },
        { "Excavation Site: Wetlands", 26, 31, nil },
        { "City of Dalaran", 28, 33, nil },
        { "Gnomeregan", 29, 38, "GNOMEREGAN" },
        { "Razorfen Kraul", 29, 38, "RAZORFENKRAUL" },
        { "Scarlet Monastery", 30, 46, "SCARLETMONASTERY" },
        { "The Drowned City", 35, 40, nil },
        { "Razorfen Downs", 37, 46, "RAZORFENDOWNS" },
        { "Krol'dok Stronghold", 40, 45, nil },
        { "Uldaman", 41, 51, "ULDAMAN" },
        { "Zul'Farrak", 44, 54, "ZULFARAK" },
        { "Maraudon", 46, 55, "MARAUDON" },
        { "Alcaz Prison", 48, 53, nil },
        { "Sunken Temple", 50, 60, "SUNKENTEMPLE" },
        { "Blackrock Depths", 52, 60, "BLACKROCKDEPTHS" },
        { "Dire Maul", 54, 60, "DIREMAUL" },
        { "Blackmaw Hold", 55, 60, nil },
        { "Lower Blackrock Spire", 55, 60, "BLACKROCKSPIRE" },
        { "Scholomance", 58, 60, "SCHOLOMANCE" },
        { "Shaper's Terrace", 58, 60, nil },
        { "Stratholme", 58, 60, "STRATHOLME" },
        { "Upper Blackrock Spire", 59, 60, "BLACKROCKSPIRE" },
    },
    raid = {
        { "Zul'Gurub", 60, 60, "ZULGURUB" },
        { "Ruins of Ahn'Qiraj", 60, 60, "AQRUINS" },
        { "Onyxia's Lair", 60, 60, "ONYXIASLAIR" },
        { "Molten Core", 60, 60, "MOLTENCORE" },
        { "Barrow Deeps", 60, 60, nil },
        { "Blackwing Lair", 60, 60, "BLACKWINGLAIR" },
        { "Temple of Ahn'Qiraj", 60, 60, "AQTEMPLE" },
        { "Naxxramas", 60, 60, "NAXXRAMAS" },
    },
}

-- The last boss (or bosses: wings, or several ways to finish) of each instance, for when the
-- Encounter Journal can't tell us which boss ends it. Matched against ENCOUNTER_END's name.
local FINAL_BOSSES = {
    ["ragefire chasm"] = { "Bazzalan", "Taragaman the Hungerer", "Lava Guard Gordoth" },
    ["wailing caverns"] = { "Mutanus the Devourer" },
    ["deadmines"] = { "Edwin VanCleef", "Cookie", "Captain Cookie", "Vanessa VanCleef" },
    ["shadowfang keep"] = { "Archmage Arugal", "Lord Godfrey" },
    ["blackfathom deeps"] = { "Aku'mai" },
    ["stockade"] = { "Bazil Thredd", "Dextren Ward", "Randolph Moloch" },
    ["gnomeregan"] = { "Mekgineer Thermaplugg" },
    ["razorfen kraul"] = { "Charlga Razorflank" },
    ["scarlet monastery"] = { "High Inquisitor Whitemane", "Herod", "Arcanist Doan", "Bloodmage Thalnos" },
    ["razorfen downs"] = { "Amnennar the Coldbringer" },
    ["uldaman"] = { "Archaedas" },
    ["zul'farrak"] = { "Chief Ukorz Sandscalp" },
    ["maraudon"] = { "Princess Theradras" },
    ["temple of atal'hakkar"] = { "Shade of Eranikus" },
    ["sunken temple"] = { "Shade of Eranikus" },
    ["blackrock depths"] = { "Emperor Dagran Thaurissan" },
    ["lower blackrock spire"] = { "Overlord Wyrmthalak" },
    ["upper blackrock spire"] = { "General Drakkisath" },
    ["blackrock spire"] = { "Overlord Wyrmthalak", "General Drakkisath" },
    ["dire maul"] = { "Immol'thar", "Prince Tortheldrin", "Alzzin the Wildshaper", "King Gordok" },
    ["scholomance"] = { "Darkmaster Gandling" },
    ["stratholme"] = { "Baron Rivendare", "Balnazzar" },
    ["zul'gurub"] = { "Hakkar" },
    ["ruins of ahn'qiraj"] = { "Ossirian the Unscarred" },
    ["onyxia's lair"] = { "Onyxia" },
    ["molten core"] = { "Ragnaros" },
    ["blackwing lair"] = { "Nefarian" },
    ["temple of ahn'qiraj"] = { "C'Thun" },
    ["naxxramas"] = { "Kel'Thuzad" },
    -- WoW Forever's own dungeons (from published guides; boss order can vary in some)
    ["hall of thanes"] = { "Durgen Dirgehammer" },
    ["ruins of lordaeron"] = { "Rath'mael" },
    ["excavation site"] = { "Relic Guardian" },
    ["drowned city"] = { "Min'loth the Serpent", "Min'loth" },
    ["krol'dok stronghold"] = { "Overseer Mugg" },
    ["alcaz prison"] = { "Blazeroar" },
    ["blackmaw hold"] = { "The Unbound Spirit" },
    ["shaper's terrace"] = { "Nanaya" },
    ["city of dalaran"] = { "Shade of the Archmage" },
    ["barrow deeps"] = { "Sonya Darkhallow" },
}
local FINAL_BY_KEY = {}

function F.IsFinalBoss(instance, bossName)
    if not instance or not bossName then return false end
    if not next(FINAL_BY_KEY) then
        for inst, bosses in pairs(FINAL_BOSSES) do
            local set = {}
            for _, b in ipairs(bosses) do set[F.NameKey(b)] = true end
            FINAL_BY_KEY[F.NameKey(inst)] = set
        end
    end
    -- "Excavation Site: Wetlands" and the like: a WoW Forever dungeon that exists in several zones
    local set = FINAL_BY_KEY[F.NameKey(instance)] or FINAL_BY_KEY[F.NameKey((tostring(instance):match("^(.-):")))]
    if set then return set[F.NameKey(bossName)] == true end
    -- an instance name we don't recognise: go by the boss alone (these names are unique)
    for _, bosses in pairs(FINAL_BY_KEY) do
        if bosses[F.NameKey(bossName)] then return true end
    end
    return false
end

-- Recent boss kills and why a run did or didn't count, shown by /fship dungeons.
-- Saved, so it can still be read after a reload or the next login.
function F:Log()
    local db = ns.Store.db
    if not db then return {} end
    if type(db.bossLog) ~= "table" then db.bossLog = {} end
    return db.bossLog
end

function F:Note(text)
    local log = self:Log()
    table.insert(log, date("%b %d %H:%M") .. " " .. text)
    while #log > 15 do table.remove(log, 1) end
    ns.Debug(text)
end

-- Backup for when the game doesn't report the encounter: a final boss seen dead
-- (targeted, on a nameplate or boss frame) while you're in its instance.
local deadSeen = {}
function F:CheckDead(unit)
    if not (UnitExists and UnitExists(unit)) or UnitIsPlayer(unit) then return end
    if not (UnitIsDead and UnitIsDead(unit)) then return end
    local instance, instanceType = GetInstanceInfo()
    if instanceType ~= "party" and instanceType ~= "raid" then return end
    local name = UnitName(unit)
    if not self.IsFinalBoss(instance, name) then return end
    local guid = (UnitGUID and UnitGUID(unit)) or name
    if deadSeen[guid] then return end
    deadSeen[guid] = true
    self:Note("Saw " .. tostring(name) .. " dead in " .. tostring(instance))
    ns.Announce:PostInstance()
end

local catalog, builtAt, fromGame

-- What the game's own lists return (Dungeon Finder, then Encounter Journal). Each call is
-- guarded separately, so one odd entry can't hide the rest. Returns the number found.
local function readGame(list, byKey)
    local found = 0
    -- The Dungeon Finder list also holds zones, battlegrounds and world PvP (WoW Forever's
    -- group finder lists every zone), so it only adds detail (levels, art) to dungeons and
    -- raids we already know from the built-in list or the Encounter Journal.
    for category, entries in pairs(BUILTIN) do
        for _, b in ipairs(entries) do addInstance(list, byKey, b[1], category, {}) end
    end
    if EJ_GetInstanceByIndex then
        local okT, tiers = pcall(function() return EJ_GetNumTiers and EJ_GetNumTiers() or 1 end)
        local _, current = pcall(function() return EJ_GetCurrentTier and EJ_GetCurrentTier() end)
        for tier = 1, (okT and tonumber(tiers)) or 1 do
            if EJ_SelectTier then pcall(EJ_SelectTier, tier) end
            for _, isRaid in ipairs({ false, true }) do
                for i = 1, 200 do
                    local ok, id, name, _, _, buttonImage = pcall(EJ_GetInstanceByIndex, i, isRaid)
                    if not ok or not id then break end
                    addInstance(list, byKey, name, isRaid and "raid" or "dungeon", { ejArt = buttonImage })
                    found = found + 1
                end
            end
        end
        if current and EJ_SelectTier then pcall(EJ_SelectTier, current) end
    end
    if GetLFGDungeonInfo then
        for id = 1, 3000 do
            local ok, name, typeID, _, minLevel, maxLevel, _, minRec, maxRec, _, _, texture =
                pcall(GetLFGDungeonInfo, id)
            local inst = ok and type(name) == "string" and typeID ~= 6 and byKey[F.NameKey(name)]
            if inst then
                local lo, hi = tonumber(minRec) or 0, tonumber(maxRec) or 0
                if lo <= 1 or hi <= 1 then lo, hi = tonumber(minLevel) or 0, tonumber(maxLevel) or 0 end
                if lo > 1 and hi > 1 and lo < (inst.gameMin or math.huge) then
                    inst.gameMin, inst.minLevel, inst.maxLevel = lo, lo, hi
                end
                if not inst.art and type(texture) == "string" and texture ~= "" then
                    inst.art = LFG_ART .. texture
                end
                found = found + 1
            end
        end
    end
    return found
end

function F:Catalog()
    -- rebuilt now and then until the game's lists answer (they may not be ready at login)
    if catalog and (fromGame or GetTime() - builtAt < 60) then return catalog end
    local list, byKey = {}, {}
    local found = readGame(list, byKey)
    -- the game's numbers and pictures win; the built-in ones fill in what it left out
    for _, entries in pairs(BUILTIN) do
        for _, b in ipairs(entries) do
            local inst = byKey[F.NameKey(b[1])]
            if not inst.minLevel then inst.minLevel, inst.maxLevel = b[2], b[3] end
            if not inst.art and b[4] then inst.art = LFG_ART .. b[4] end
        end
    end
    catalog, builtAt, fromGame = list, GetTime(), found > 0
    return list
end

-- /fship dungeons: what the game's lists give us, for working out missing cards or art.
function F:Diagnose()
    local list, byKey = {}, {}
    local found = readGame(list, byKey)
    ns.Print(string.format("Dungeon Finder: %s. Encounter Journal: %s. %d matches from the game.",
        GetLFGDungeonInfo and "yes" or "missing", EJ_GetInstanceByIndex and "yes" or "missing", found))
    local shown = 0
    for _, inst in ipairs(list) do
        if inst.gameMin or inst.art or inst.ejArt then
            shown = shown + 1
            if shown <= 15 then
                ns.Output(string.format("  %s (%s) LV %s-%s art: %s", inst.name, inst.category,
                    tostring(inst.minLevel or "?"), tostring(inst.maxLevel or "?"),
                    tostring(inst.art or inst.ejArt or "none")))
            end
        end
    end
    if shown > 15 then ns.Output("  ... and " .. (shown - 15) .. " more") end
    local name, instanceType = GetInstanceInfo()
    ns.Output("  You are in: " .. tostring(name) .. " (" .. tostring(instanceType) .. ")")
    local log = self:Log()
    if #log == 0 then
        ns.Output("  No boss kills seen yet.")
    else
        ns.Output("  Recent boss kills and dungeon runs:")
        for _, line in ipairs(log) do ns.Output("    " .. line) end
    end
end

-- Cards for one Achievements sub-tab ("dungeon" or "raid"), by level range like the
-- dungeon picker. Each card: { name, category, minLevel, maxLevel, art, ejArt,
--   done = { t, members, difficulties = { "Normal", ... } } or nil }.
function F:Cards(fid, category)
    local earned = self:Earned(fid)
    local done = {}
    for _, a in pairs(earned) do
        local key = F.NameKey(a.instance)
        local d = done[key]
        if not d then
            d = { t = a.t, members = a.members, difficulties = {}, category = a.category, name = a.instance }
            done[key] = d
        elseif a.t < d.t then
            d.t, d.members = a.t, a.members
        end
        d.difficulties[#d.difficulties + 1] = (a.difficulty ~= "" and a.difficulty) or "Normal"
    end
    local cards, seen = {}, {}
    for _, inst in ipairs(self:Catalog()) do
        if inst.category == category then
            local card = {}
            for k, v in pairs(inst) do card[k] = v end
            card.done = done[inst.key]
            cards[#cards + 1] = card
            seen[inst.key] = true
        end
    end
    -- completed somewhere the game's lists don't show: still gets a card
    for key, d in pairs(done) do
        if not seen[key] and d.category == category then
            cards[#cards + 1] = { name = d.name, key = key, category = category, done = d }
        end
    end
    table.sort(cards, function(a, b)
        local la, lb = a.minLevel or math.huge, b.minLevel or math.huge
        if la ~= lb then return la < lb end
        return F.NameKey(a.name) < F.NameKey(b.name)
    end)
    local completed = 0
    for _, c in ipairs(cards) do
        if c.done then completed = completed + 1 end
    end
    return cards, completed
end
