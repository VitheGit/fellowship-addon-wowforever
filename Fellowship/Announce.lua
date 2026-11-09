-- Announce: things worth telling the fellowship about, posted automatically.
-- Each kind can be switched off for sharing (your own) and for showing (everyone else's).
--
-- All of these are "M" (milestone) events: d[1] is the subtype, so older versions of the
-- addon still store and relay them and show them as a generic milestone.
--   level   level                       mount  name, spellID
--   pet     name                        toy    name, itemID
--   loot    itemString, name, quality   dungeon/raid  instance, difficulty, keyLevel, onTime
--   death   killer, zone
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
}
local SUBTYPE_GROUP = {
    level = "level", mount = "collection", pet = "collection", toy = "collection",
    loot = "loot", dungeon = "instance", raid = "instance", death = "death",
}

function A.GroupOf(e)
    if e.k == "A" then return "achievement" end
    if e.k == "M" then return SUBTYPE_GROUP[e.d and e.d[1]] or "level" end
    return nil
end

-- Should this event be shown to me (chat echo and the window)?
function A.ShouldShow(e)
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

---------------------------------------------------------------------------
-- Deaths
---------------------------------------------------------------------------
-- Note: we deliberately don't read the combat log to name the killer. On current Mainline
-- clients registering COMBAT_LOG_EVENT_UNFILTERED is a protected action and triggers the
-- "Fellowship has been blocked from an action only available to the Blizzard UI" popup.
-- The killer field stays in the format (empty) so it can be filled in later.
function A:OnDeath()
    share("death", { "death", "", (GetZoneText and GetZoneText()) or "" })
end

---------------------------------------------------------------------------
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
end
