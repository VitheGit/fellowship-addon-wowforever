-- Fellowship: private chat and achievement feed for small friend groups.
-- Core: namespace, event dispatch, helpers, slash commands.
local ADDON_NAME, ns = ...
Fellowship = ns -- exposed for debugging (/dump Fellowship.Store:Active())

ns.VERSION = "0.3.0"
ns.PREFIX = "Fellowship" -- addon message prefix (max 16 chars)
ns.PROTOCOL = "1"

ns.defaults = {
    echoChat = true,         -- print live fellowship chat into the main chat frame
    echoAchievements = true, -- print live achievements into the main chat frame
    shareLevels = true,      -- share level-ups as milestones
    maxEvents = 3000,        -- history kept per fellowship (membership events are never pruned)
    maxAgeDays = 180,        -- history older than this is pruned at login
    backfillLimit = 500,
    textColor = "4fd1b5",    -- chat text color (sea green; distinct from guild, party, whisper, BNet...)     -- max events per author sent in one catch-up request
}

---------------------------------------------------------------------------
-- WoW event dispatch
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}

function ns.On(event, fn)
    local list = handlers[event]
    if not list then
        list = {}
        handlers[event] = list
        eventFrame:RegisterEvent(event)
    end
    list[#list + 1] = fn
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do list[i](...) end
end)

---------------------------------------------------------------------------
-- Internal callbacks (module to module)
---------------------------------------------------------------------------
local listeners = {}

function ns.Listen(name, fn)
    listeners[name] = listeners[name] or {}
    table.insert(listeners[name], fn)
end

function ns.Fire(name, ...)
    local list = listeners[name]
    if not list then return end
    for i = 1, #list do list[i](...) end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[Fellowship]|r " .. tostring(msg))
end

function ns.Now()
    return GetServerTime()
end

function ns.Trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Cut s to at most max bytes without splitting a UTF-8 character.
function ns.Truncate(s, max)
    if #s <= max then return s end
    local n = max
    while n > 0 do
        local b = s:byte(n + 1)
        if b < 0x80 or b >= 0xC0 then break end
        n = n - 1
    end
    return s:sub(1, n)
end

-- "bob" -> "Bob-Realm", "bob-Area52" -> "Bob-Area52"
function ns.NormalizeName(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("[%s%c]", "")
    if name == "" then return nil end
    local short, realm = name:match("^([^%-]+)%-(.+)$")
    if not short then
        short, realm = name, GetNormalizedRealmName()
    end
    local b = short:byte(1)
    if b and b < 128 then
        short = short:sub(1, 1):upper() .. short:sub(2):lower()
    end
    if not realm or realm == "" then return short end
    return short .. "-" .. realm
end

-- Case-insensitive lookup key for a character name.
function ns.Key(name)
    local n = ns.NormalizeName(name)
    return n and n:lower() or ""
end

function ns.Short(full)
    if not full then return "?" end
    return (full:match("^[^%-]+")) or full
end

-- Neutralise WoW escape sequences in user-supplied text.
function ns.Escape(text)
    return (tostring(text or ""):gsub("|", "||"))
end

function ns.TimeStamp(t)
    if not t then return "" end
    if date("%Y%m%d", t) == date("%Y%m%d", ns.Now()) then
        return date("%H:%M", t)
    end
    return date("%b %d %H:%M", t)
end

local GOLD, GREY = "|cffffd100", "|cff9d9d9d"

-- Standard class colors, used if the game's own table isn't available.
local FALLBACK_CLASS_COLORS = {
    WARRIOR = "ffc69b6d", PALADIN = "fff48cba", HUNTER = "ffaad372", ROGUE = "fffff468",
    PRIEST = "ffffffff", DEATHKNIGHT = "ffc41e3a", SHAMAN = "ff0070dd", MAGE = "ff3fc7eb",
    WARLOCK = "ff8788ee", MONK = "ff00ff98", DRUID = "ffff7c0a", DEMONHUNTER = "ffa330c9",
    EVOKER = "ff33937f",
}

function ns.ClassColorHex(token)
    if not token then return nil end
    -- CUSTOM_CLASS_COLORS is the convention used by class-color addons
    local c = (CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[token]) or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[token])
    if c then
        if c.colorStr then return c.colorStr end
        if c.r then return string.format("ff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
    end
    return FALLBACK_CLASS_COLORS[token]
end

-- Short name in the member's class color (gold if we don't know their class yet).
function ns.ColorName(full)
    local hex = ns.ClassColorHex(ns.Store:GetClass(full))
    return (hex and ("|c" .. hex) or GOLD) .. ns.Short(full) .. "|r"
end

function ns.TextColor()
    local c = ns.settings and ns.settings.textColor
    if type(c) == "string" and c:match("^%x%x%x%x%x%x$") then return c end
    return ns.defaults.textColor
end

function ns.FormatEvent(e)
    local who = ns.ColorName(e.a)
    local d = e.d or {}
    if e.k == "C" then
        return who .. ": |cff" .. ns.TextColor() .. ns.Escape(d[1]) .. "|r"
    elseif e.k == "A" then
        local id = tonumber(d[1])
        local link = id and GetAchievementLink and GetAchievementLink(id)
        local pts = tonumber(d[3])
        return who .. " earned " .. (link or ("[" .. ns.Escape(d[2] or "?") .. "]"))
            .. ((pts and pts > 0) and (" (" .. pts .. " pts)") or "")
    elseif e.k == "M" then
        if d[1] == "level" then
            return who .. " reached level " .. (tonumber(d[2]) or "?") .. "!"
        end
        return who .. " hit a milestone: " .. ns.Escape(d[2])
    elseif e.k == "N" then
        return GREY .. ns.Short(e.a) .. " founded the fellowship " .. ns.Escape(d[1]) .. "|r"
    elseif e.k == "J" then
        return GREY .. ns.Short(d[1]) .. " joined (invited by " .. ns.Short(e.a) .. ")|r"
    elseif e.k == "L" then
        return GREY .. ns.Short(e.a) .. " left the fellowship|r"
    elseif e.k == "K" then
        return GREY .. ns.Short(e.a) .. " removed " .. ns.Short(d[1]) .. "|r"
    end
    return GREY .. "?|r"
end

---------------------------------------------------------------------------
-- Live echo + "while you were away" summary
---------------------------------------------------------------------------
local summaryToken = 0

function ns.ScheduleSummary(delay)
    summaryToken = summaryToken + 1
    local token = summaryToken
    C_Timer.After(delay or 6, function()
        if token ~= summaryToken then return end
        if ns.UI and ns.UI:IsShown() then return end
        local fid = ns.Store:ActiveId()
        if not fid then return end
        local chats, achievements = ns.Store:UnreadCounts(fid)
        if chats + achievements > 0 then
            ns.Print(string.format("While you were away: %d message%s and %d achievement%s. Type /fs to read.",
                chats, chats == 1 and "" or "s", achievements, achievements == 1 and "" or "s"))
        end
    end)
end

ns.Listen("EVENTS_ADDED", function(fid, added, live)
    if not live then
        ns.ScheduleSummary()
        return
    end
    for _, e in ipairs(added) do
        if e.a == ns.me then
            -- show your own chat lines too, like a sent whisper, so /fsay always gives feedback
            if e.k == "C" and ns.settings.echoChat then ns.Print(ns.FormatEvent(e)) end
        else
            if e.k == "C" and ns.settings.echoChat then
                ns.Print(ns.FormatEvent(e))
            elseif (e.k == "A" or e.k == "M") and ns.settings.echoAchievements then
                ns.Print(ns.FormatEvent(e))
            elseif ns.MEMBERSHIP_KINDS[e.k] then
                ns.Print(ns.FormatEvent(e))
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
ns.On("ADDON_LOADED", function(name)
    if name == ADDON_NAME then ns.Store:Init() end
end)

ns.On("PLAYER_LOGIN", function()
    local name, realm = UnitFullName("player")
    if not realm or realm == "" then realm = GetNormalizedRealmName() end
    ns.me = name .. "-" .. realm
    ns.meKey = ns.me:lower()
    ns.Store:InitCharacter()
    local _, classToken = UnitClass("player")
    ns.Store:SetClass(ns.me, classToken)
    ns.Comm:Init()
    ns.Sync:Init()
    ns.Achievements:Init()
    ns.UI:Init()
    ns.ScheduleSummary(15)
end)

ns.On("PLAYER_LOGOUT", function()
    if ns.UI and ns.UI:IsShown() then
        local fid = ns.Store:ActiveId()
        if fid then ns.Store:MarkRead(fid) end
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local HELP = {
    "|cffffd100/fs <message>|r - talk to your fellowship",
    "|cffffd100/fs|r or |cffffd100/fship|r - open the Fellowship window",
    "|cffffd100/fship create <name>|r - start a new fellowship",
    "|cffffd100/fship invite <player>|r - invite someone (they need Fellowship installed)",
    "|cffffd100/fship who|r - list members and who is online",
    "|cffffd100/fship leave|r - leave your fellowship",
    "|cffffd100/fship remove <player>|r - remove a member (founder only)",
    "|cffffd100/fship sync|r - ask online members for anything you missed",
    "|cffffd100/fship color <hex>|r - change the chat text color (/fship color reset for default)",
    "|cffffd100/fship echo|r, |cffffd100/fship levels|r - toggle chat echo / level-up sharing",
}

function ns.HandleSlash(input)
    local cmd, rest = tostring(input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "" or cmd == "window" or cmd == "show" then
        ns.UI:Toggle()
    elseif cmd == "create" then
        ns.Sync:Create(rest)
    elseif cmd == "invite" then
        ns.Sync:Invite(rest)
    elseif cmd == "leave" then
        ns.Sync:Leave()
    elseif cmd == "remove" or cmd == "kick" then
        ns.Sync:Remove(rest)
    elseif cmd == "who" or cmd == "members" then
        ns.Sync:PrintMembers()
    elseif cmd == "sync" then
        ns.Sync:HelloAll()
        ns.Print("Asking online members for anything you missed.")
    elseif cmd == "say" then
        ns.Sync:PostChat(rest)
    elseif cmd == "color" or cmd == "colour" then
        local hex = rest:gsub("^#", ""):lower()
        if hex == "reset" or hex == "" then
            ns.settings.textColor = ns.defaults.textColor
        elseif hex:match("^%x%x%x%x%x%x$") then
            ns.settings.textColor = hex
        else
            ns.Print("Usage: /fship color <hex like 4fd1b5> or /fship color reset")
            return
        end
        ns.Print("|cff" .. ns.TextColor() .. "Fellowship chat will look like this.|r")
        if ns.UI then ns.UI:QueueRefresh() end
    elseif cmd == "echo" then
        ns.settings.echoChat = not ns.settings.echoChat
        ns.Print("Chat echo " .. (ns.settings.echoChat and "on" or "off") .. ".")
    elseif cmd == "levels" then
        ns.settings.shareLevels = not ns.settings.shareLevels
        ns.Print("Level-up sharing " .. (ns.settings.shareLevels and "on" or "off") .. ".")
    else
        ns.Print("Commands:")
        for _, line in ipairs(HELP) do DEFAULT_CHAT_FRAME:AddMessage("  " .. line) end
    end
end

-- /fship (or /fellowship): commands and settings
SLASH_FELLOWSHIP1 = "/fship"
SLASH_FELLOWSHIP2 = "/fellowship"
SlashCmdList.FELLOWSHIP = function(input) ns.HandleSlash(input) end

-- /fs <message>: talk. /fs on its own opens the window.
SLASH_FELLOWSHIPSAY1 = "/fs"
SLASH_FELLOWSHIPSAY2 = "/fsay"
SlashCmdList.FELLOWSHIPSAY = function(text)
    if ns.Trim(text) == "" then
        ns.UI:Toggle()
    else
        ns.Sync:PostChat(text)
    end
end

function Fellowship_OnAddonCompartmentClick()
    ns.UI:Toggle()
end
