-- Announce: things worth telling the fellowship about, posted automatically.
-- Each kind can be switched off for sharing (your own) and for showing (everyone else's).
--
-- All of these are "M" (milestone) events: d[1] is the subtype, so older versions of the
-- addon still store and relay them and show them as a generic milestone.
--   level   level                       mount  name, spellID
--   pet     name                        toy    name, itemID
--   loot    itemString, name, quality   dungeon/raid  instance, difficulty, keyLevel, onTime
--   death   killer, zone
--   rare    name, npcID, zone, mapID, x, y   (x/y in 1/10000 of the map, for a map pin)
local _, ns = ...
local A = {}
ns.Announce = A
ns.Achievements = A -- older name, kept for tests and other code

-- Which setting governs each kind of announcement (share = post mine, show = see others').
A.TYPES = {
    achievement = { share = "shareAchievements", show = "showAchievements" },
    level       = { share = "shareLevels",       show = "showLevels" },
    collection  = { share = "shareCollections",  show = "showCollections" },
    loot        = { share = "shareLoot",         show = "showLoot" },
    instance    = { share = "shareInstances",    show = "showInstances" },
    death       = { share = "shareDeaths",       show = "showDeaths" },
    rare        = { share = "shareRares",        show = "showRares" },
}
local SUBTYPE_GROUP = {
    level = "level", mount = "collection", pet = "collection", toy = "collection",
    loot = "loot", dungeon = "instance", raid = "instance", death = "death", rare = "rare",
}

function A.GroupOf(e)
    if ns.Feats.IsFeat(e) then return nil end
    if e.k == "A" then return "achievement" end
    if e.k == "M" then return SUBTYPE_GROUP[e.d and e.d[1]] or "level" end
    return nil
end

-- Should this event be shown to me (chat echo and the window)?
function A.ShouldShow(e)
    -- Fellowship Achievements: everyone in the group posts one; show only the first
    if ns.Feats.IsFeat(e) then return ns.Feats:IsFirst(e) end
    local group = A.GroupOf(e)
    if not group then return true end
    if e.a == ns.me then return true end -- your own things always show in the window
    local s = ns.settings
    if not s[A.TYPES[group].show] then return false end
    if group == "loot" then
        local q = tonumber(e.d[4]) or 0
        return q >= (s.lootMinQuality or 4)
    end
    return true
end

-- Should this event be printed in chat? Like ShouldShow, but a Fellowship Achievement is
-- printed only once even when several members of the group post it at the same moment.
function A.ShouldEcho(e)
    if not A.ShouldShow(e) then return false end
    if ns.Feats.IsFeat(e) then return ns.Feats:MarkAnnounced(e) end
    return true
end

local function share(group, data)
    if not ns.settings[A.TYPES[group].share] then return end
    return ns.Sync:Publish("M", data)
end

---------------------------------------------------------------------------
-- Achievements and level-ups
---------------------------------------------------------------------------
function A:OnEarned(id, alreadyEarned)
    -- alreadyEarned is true for account-wide achievements another character already has
    if alreadyEarned or not id or not GetAchievementInfo then return end
    local _, name, points, _, _, _, _, _, _, _, _, isGuild = GetAchievementInfo(id)
    if not name or isGuild or not ns.settings.shareAchievements then return end
    ns.Sync:Publish("A", { id, name, points or 0 })
end

function A:OnLevelUp(level)
    if level then share("level", { "level", level }) end
end

---------------------------------------------------------------------------
-- Mounts, pets, toys
---------------------------------------------------------------------------
function A:OnMount(mountID)
    if not (C_MountJournal and C_MountJournal.GetMountInfoByID) then return end
    local name, spellID = C_MountJournal.GetMountInfoByID(mountID)
    if name then share("collection", { "mount", name, spellID or "" }) end
end

function A:OnPet(petGUID)
    if not (C_PetJournal and C_PetJournal.GetPetInfoByPetID) then return end
    local _, customName, _, _, _, _, _, name = C_PetJournal.GetPetInfoByPetID(petGUID)
    name = name or customName
    if name then share("collection", { "pet", name }) end
end

function A:OnToy(itemID)
    local name
    if C_ToyBox and C_ToyBox.GetToyInfo then
        local _, toyName = C_ToyBox.GetToyInfo(itemID)
        name = toyName
    end
    if not name and GetItemInfo then name = GetItemInfo(itemID) end
    if name then share("collection", { "toy", name, itemID }) end
end

---------------------------------------------------------------------------
-- Loot (Rare and better is shared; each viewer picks their own minimum)
---------------------------------------------------------------------------
local lootPatterns

local function toPattern(fmt)
    local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
    return "^" .. p .. "$"
end

local function itemQuality(link)
    if C_Item and C_Item.GetItemQualityByID then
        local q = C_Item.GetItemQualityByID(link)
        if q then return q end
    end
    if GetItemInfo then
        local _, _, q = GetItemInfo(link)
        return q
    end
end

function A:OnLoot(text)
    if type(text) ~= "string" then return end
    if not lootPatterns then
        lootPatterns = {}
        for _, fmt in ipairs({ LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_SELF, LOOT_ITEM_PUSHED_SELF_MULTIPLE, LOOT_ITEM_PUSHED_SELF }) do
            if fmt then lootPatterns[#lootPatterns + 1] = toPattern(fmt) end
        end
    end
    local link
    for _, p in ipairs(lootPatterns) do
        link = text:match(p)
        if link then break end
    end
    if not link then return end
    local itemString = link:match("|H(item:[%-%d:]+)|h")
    local name = link:match("|h%[(.-)%]|h")
    if not itemString or not name then return end
    local q = itemQuality(link)
    if not q or q < 3 then return end -- only Rare and better
    share("loot", { "loot", itemString, name, q })
end

-- Safe item link rebuilt from parts (never display a link someone else typed).
function A.ItemLink(itemString, name, quality)
    if type(itemString) ~= "string" or not itemString:match("^item:[%-%d:]+$") then
        return "[" .. ns.Escape(name) .. "]"
    end
    local hex
    local q = tonumber(quality)
    if q and C_Item and C_Item.GetItemQualityColor then
        local _, _, _, h = C_Item.GetItemQualityColor(q)
        hex = h
    end
    if not hex and q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q] then
        hex = ITEM_QUALITY_COLORS[q].hex and ITEM_QUALITY_COLORS[q].hex:gsub("^|c", "")
    end
    hex = (type(hex) == "string" and hex:match("^%x%x%x%x%x%x%x%x$")) and hex or "ffffffff"
    local safeName = tostring(name or "?"):gsub("[|%[%]]", "")
    return "|c" .. hex .. "|H" .. itemString .. "|h[" .. safeName .. "]|h|r"
end

---------------------------------------------------------------------------
-- Dungeon and raid completions (final boss only, once per run)
---------------------------------------------------------------------------
local postedRun

local function finalEncounterID()
    if not (EJ_GetInstanceForMap and C_Map and C_Map.GetBestMapForUnit and EJ_GetEncounterInfoByIndex) then return end
    local mapID = C_Map.GetBestMapForUnit("player")
    local journalInstance = mapID and EJ_GetInstanceForMap(mapID)
    if not journalInstance or journalInstance == 0 then return end
    local last, i = nil, 1
    while true do
        local name, _, _, _, _, _, dungeonEncounterID = EJ_GetEncounterInfoByIndex(i, journalInstance)
        if not name then break end
        last = dungeonEncounterID
        i = i + 1
    end
    return last
end

local function runKey()
    local name, instanceType, difficultyID, _, _, _, _, instanceID = GetInstanceInfo()
    return tostring(instanceID or name) .. ":" .. tostring(difficultyID), name, instanceType
end

function A:PostInstance(keyLevel, onTime)
    local key, name, instanceType = runKey()
    if instanceType ~= "party" and instanceType ~= "raid" then return end
    if postedRun == key then return end
    postedRun = key
    local _, _, _, difficultyName = GetInstanceInfo()
    ns.Feats:OnInstanceComplete(instanceType == "raid" and "raid" or "dungeon", name, difficultyName or "")
    share("instance", { instanceType == "raid" and "raid" or "dungeon", name, difficultyName or "",
        keyLevel or "", onTime == nil and "" or (onTime and "1" or "0") })
end

function A:OnEncounterEnd(encounterID, _, _, _, success)
    if success ~= 1 and success ~= true then return end
    local final = finalEncounterID()
    if final and final == encounterID then self:PostInstance() end
end

function A:OnChallengeCompleted()
    local level, onTime
    if C_ChallengeMode and C_ChallengeMode.GetChallengeCompletionInfo then
        local info = C_ChallengeMode.GetChallengeCompletionInfo()
        if info then level, onTime = info.level, info.onTime end
    elseif C_ChallengeMode and C_ChallengeMode.GetCompletionInfo then
        local _, l, _, ot = C_ChallengeMode.GetCompletionInfo()
        level, onTime = l, ot
    end
    postedRun = nil -- a keystone run is its own completion even if the last boss already posted
    self:PostInstance(level, onTime)
end

function A:OnZoneChanged()
    local key, _, instanceType = runKey()
    if instanceType ~= "party" and instanceType ~= "raid" then postedRun = nil end
    if postedRun and postedRun ~= key then postedRun = nil end
end

-- Deaths: what killed you comes from the game's Death Recap (the "Recap" button on the
-- death popup), never the combat log. Reading the combat log is blocked on WoW Forever:
-- registering COMBAT_LOG_EVENT_UNFILTERED triggers the "blocked from an action" popup.
-- Without a recap we fall back to: falling, drowning/fatigue (breath bars), or the enemy
-- you had targeted.
--   death data: { "death", killer (text older versions show), zone, cause, source, spell }
--   cause: mob, falling, drowning, fatigue, lava, fire, slime, fight, or ""
local ENVIRONMENT = {
    falling = "falling", drowning = "drowning", fatigue = "fatigue",
    lava = "lava", fire = "fire", slime = "slime",
}
local lastFalling = 0

local function recapEvents()
    local list
    if C_DeathRecap and C_DeathRecap.GetRecapEvents then
        local ok, ev = pcall(C_DeathRecap.GetRecapEvents)
        if ok and type(ev) == "table" and #ev > 0 then list = ev end
    end
    if not list and DeathRecap_GetEvents then
        local ok, ev = pcall(DeathRecap_GetEvents)
        if ok and type(ev) == "table" and #ev > 0 then list = ev end
    end
    return list
end

-- The killing blow: the latest event in the recap.
function A.CauseFromRecap(events)
    local last
    for _, ev in ipairs(events or {}) do
        if type(ev) == "table" and (not last or (tonumber(ev.timestamp) or 0) >= (tonumber(last.timestamp) or 0)) then
            last = ev
        end
    end
    if not last then return nil end
    local env = type(last.environmentalType) == "string" and ENVIRONMENT[last.environmentalType:lower()]
    if env then return env end
    local source = type(last.sourceName) == "string" and last.sourceName ~= "" and last.sourceName or nil
    if not source then return nil end
    local spell = type(last.spellName) == "string" and last.spellName or nil
    if last.event == "SWING_DAMAGE" then spell = nil end
    return "mob", source, spell
end

local function breathCause()
    if not GetMirrorTimerProgress then return nil end
    for timer, cause in pairs({ BREATH = "drowning", EXHAUSTION = "fatigue" }) do
        local ok, left = pcall(GetMirrorTimerProgress, timer)
        if ok and tonumber(left) and tonumber(left) <= 0 and A.mirror and A.mirror[timer] then return cause end
    end
end

function A:DeathCause()
    local cause, source, spell = A.CauseFromRecap(recapEvents())
    if cause then return cause, source, spell end
    if GetTime() - lastFalling < 1.5 then return "falling" end
    cause = breathCause()
    if cause then return cause end
    if UnitExists and UnitExists("target") and UnitCanAttack and UnitCanAttack("player", "target")
        and not UnitIsPlayer("target") then
        return "fight", UnitName("target")
    end
    return ""
end

local KILLER_TEXT = { falling = "falling", drowning = "drowning", fatigue = "fatigue", lava = "lava", fire = "fire", slime = "slime" }

function A:OnDeath()
    local zone = (GetZoneText and GetZoneText()) or ""
    -- the recap fills in just after death; read it a moment later (and once more if needed)
    local tries = 0
    local function post()
        tries = tries + 1
        local ok, cause, source, spell = pcall(A.DeathCause, A)
        if not ok then cause, source, spell = "", nil, nil end
        local recapAPI = (C_DeathRecap and C_DeathRecap.GetRecapEvents) or DeathRecap_GetEvents
        if cause == "" and recapAPI and tries < 3 then return C_Timer.After(1, post) end
        ns.Debug("death cause: " .. tostring(cause) .. " / " .. tostring(source) .. " / " .. tostring(spell)
            .. " (recap events: " .. tostring(recapEvents() and #recapEvents() or 0) .. ")")
        local killer = KILLER_TEXT[cause] or source or ""
        share("death", { "death", killer, zone, cause, source or "", spell or "" })
    end
    C_Timer.After(0.5, post)
end

function A:InitDeaths()
    if IsFalling then
        C_Timer.NewTicker(0.25, function() if IsFalling() then lastFalling = GetTime() end end)
    end
    A.mirror = {}
    ns.On("MIRROR_TIMER_START", function(timer) if timer then A.mirror[timer] = true end end)
    ns.On("MIRROR_TIMER_STOP", function(timer) if timer then A.mirror[timer] = nil end end)
end

---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Rare mobs: found the same way RareScanner finds them, from the rare markers
-- (vignettes) the game puts on the minimap, plus nameplates, target and mouseover.
---------------------------------------------------------------------------
A.RARE_REPEAT = 600     -- don't re-announce the same rare from this character for 10 minutes
A.RARE_SHARED = 300     -- skip it if any member announced it in the last 5 minutes
local rareSeen = {}

local function npcIDFromGUID(guid)
    if type(guid) ~= "string" then return nil end
    -- Creature-0-[server]-[instance]-[zone]-[npcID]-[spawn]
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
end

local function mapPosition(vignetteGUID)
    if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end
    local pos
    if vignetteGUID and C_VignetteInfo and C_VignetteInfo.GetVignettePosition then
        pos = C_VignetteInfo.GetVignettePosition(vignetteGUID, mapID)
    end
    if not pos and C_Map.GetPlayerMapPosition then pos = C_Map.GetPlayerMapPosition(mapID, "player") end
    local x, y
    if pos and pos.GetXY then x, y = pos:GetXY() end
    if not x or not y then return mapID end
    return mapID, math.floor(x * 10000 + 0.5), math.floor(y * 10000 + 0.5)
end

function A:FoundRare(name, npcID, vignetteGUID)
    if type(name) ~= "string" or name == "" or not ns.settings.shareRares then return end
    if IsInInstance and IsInInstance() then return end -- open-world rares only
    local f, fid = ns.Store:Active()
    if not f or f.pendingFrom then return end
    local id = npcID or name
    local now = ns.Now()
    if rareSeen[id] and now - rareSeen[id] < A.RARE_REPEAT then return end
    rareSeen[id] = now
    -- someone in the fellowship already called this one out
    local events = ns.Store:Sorted(fid)
    for i = #events, 1, -1 do
        local e = events[i]
        if now - (e.t or 0) > A.RARE_SHARED then break end
        if e.k == "M" and e.d[1] == "rare" then
            local same = (npcID and e.d[3] == tostring(npcID)) or (not npcID and e.d[2] == name)
            if same then return end
        end
    end
    local zone = (GetZoneText and GetZoneText()) or ""
    local mapID, x, y = mapPosition(vignetteGUID)
    share("rare", { "rare", name, npcID or "", zone, mapID or "", x or "", y or "" })
end

local function checkVignette(guid)
    if not (C_VignetteInfo and C_VignetteInfo.GetVignetteInfo) then return end
    local info = C_VignetteInfo.GetVignetteInfo(guid)
    if not info or info.isDead or type(info.name) ~= "string" then return end
    local atlas = type(info.atlasName) == "string" and info.atlasName:lower() or ""
    local npcID = npcIDFromGUID(info.objectGUID)
    if atlas:find("vignettekill", 1, true) and npcID then A:FoundRare(info.name, npcID, guid) end
end

local function checkUnit(unit)
    if not (UnitExists and UnitExists(unit)) or UnitIsPlayer(unit) or (UnitIsDead and UnitIsDead(unit)) then return end
    local class = UnitClassification and UnitClassification(unit)
    if class ~= "rare" and class ~= "rareelite" then return end
    A:FoundRare(UnitName(unit), npcIDFromGUID(UnitGUID(unit)))
end

-- Game data can be restricted in combat; a failed lookup just means no announcement.
local function safely(fn, ...) pcall(fn, ...) end

function A:InitRares()
    ns.On("VIGNETTE_MINIMAP_UPDATED", function(guid, onMinimap)
        if guid and onMinimap ~= false then safely(checkVignette, guid) end
    end)
    ns.On("VIGNETTES_UPDATED", function()
        if not (C_VignetteInfo and C_VignetteInfo.GetVignettes) then return end
        for _, guid in ipairs(C_VignetteInfo.GetVignettes() or {}) do safely(checkVignette, guid) end
    end)
    ns.On("NAME_PLATE_UNIT_ADDED", function(unit) safely(checkUnit, unit) end)
    ns.On("PLAYER_TARGET_CHANGED", function() safely(checkUnit, "target") end)
    ns.On("UPDATE_MOUSEOVER_UNIT", function() safely(checkUnit, "mouseover") end)
end

function A:Init()
    ns.On("ACHIEVEMENT_EARNED", function(id, alreadyEarned) A:OnEarned(id, alreadyEarned) end)
    ns.On("PLAYER_LEVEL_UP", function(level) A:OnLevelUp(level) end)
    ns.On("NEW_MOUNT_ADDED", function(id) A:OnMount(id) end)
    ns.On("NEW_PET_ADDED", function(guid) A:OnPet(guid) end)
    ns.On("NEW_TOY_ADDED", function(id) A:OnToy(id) end)
    ns.On("CHAT_MSG_LOOT", function(text) A:OnLoot(text) end)
    ns.On("ENCOUNTER_END", function(...) A:OnEncounterEnd(...) end)
    ns.On("CHALLENGE_MODE_COMPLETED", function() A:OnChallengeCompleted() end)
    ns.On("ZONE_CHANGED_NEW_AREA", function() A:OnZoneChanged() end)
    ns.On("PLAYER_DEAD", function() A:OnDeath() end)
    self:InitDeaths()
    self:InitRares()
end
