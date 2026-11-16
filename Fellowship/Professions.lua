-- Professions: each member's Fellowship reads its own character's professions and skill levels
-- (GetProfessions / GetProfessionInfo) and shares them, so the Members tab can list them.
-- Nobody types anything: it updates by itself when a skill goes up or a profession is learned.
-- Synced like notes, outside the event log, so older versions just ignore it:
--   PL  fid proto "" ver | name v profs        one character's professions (newest v wins)
--   PV  fid proto reply ver | name v | ...     "these are the ones I have" (with a HI reply)
-- profs is "Mining:150:300;Cooking:75:150" (name:level:max). After it come the profession links
-- ("|Htrade:...|h[Blacksmithing]|h"), one field each: the game only hands those out while the
-- profession window is open, so each one is picked up the first time you open that profession.
-- Clicking one opens that member's recipe list, like a link in chat.
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

-- Keep only a well-formed profession link: "|cff...|Htrade:...|h[Name]|h|r"
function P.CleanLink(link, maxLen)
    if type(link) ~= "string" then return nil end
    local data, name = link:match("|H(trade:[^|]+)|h%[([^%]|]+)%]|h")
    if not data or #data > (maxLen or 200) then return nil end
    return "|cffffd000|H" .. data .. "|h[" .. name .. "]|h|r", name
end

-- { ["Blacksmithing"] = link, ... } for one character
function P:Links(name, fid)
    fid = fid or ns.Store:ActiveId()
    local all = fid and store(fid) or {}
    local key = ns.Key(name)
    local r = all[key]
    local f = fid and ns.Store:Get(fid)
    local seen = f and f.chatLinks and f.chatLinks[key]
    if not seen then return (r and r.links) or {} end
    local out = {}
    for k, v in pairs((r and r.links) or {}) do out[k] = v end
    for k, v in pairs(seen) do out[k] = v end -- links they posted in chat win
    return out
end

-- Open a member's recipe list, the same as clicking the link in chat.
-- For someone else's link it is also printed in chat, so it can be clicked there
-- (or shared) if the window doesn't open from the menu.
function P.Open(link, who)
    local data = type(link) == "string" and link:match("|H(trade:[^|]+)|h")
    if not data or not SetItemRef then return false end
    if who and ns.Key(who) ~= ns.meKey then
        ns.Print(ns.Short(who) .. "'s recipes: " .. link .. " (click it here if no window opened)")
    end
    local ok, err = pcall(SetItemRef, data, link, "LeftButton")
    if not ok then ns.Print("Opening recipes failed: " .. tostring(err)) end
    return ok
end

-- /fship recipes: every profession link you have from your fellowship, as clickable chat links.
local function esc(l) return (l:gsub("|", "||")) end
function P:PrintAll(fid, raw)
    fid = fid or ns.Store:ActiveId()
    local all = fid and store(fid)
    if not all then ns.Print("You're not in a fellowship.") return end
    local keys = {}
    for key in pairs(all) do keys[#keys + 1] = key end
    table.sort(keys)
    local any = false
    for _, key in ipairs(keys) do
        local r = all[key]
        local links = P:Links(r.name or key, fid)
        local names = {}
        for n in pairs(links) do names[#names + 1] = n end
        table.sort(names)
        if #names > 0 then
            local parts = {}
            for _, n in ipairs(names) do parts[#parts + 1] = links[n] end
            if not any then ns.Print("Profession links you have (click one to open it):") end
            any = true
            ns.Output("  " .. ns.Short(r.name or key) .. ": " .. table.concat(parts, " "))
            if raw then
                for _, n in ipairs(names) do
                    ns.Output("    shared: " .. esc((r.links or {})[n] or "none"))
                    local c = P.chatRaw and P.chatRaw[key .. ":" .. n]
                    if c then ns.Output("    chat: " .. esc(c)) end
                end
            end
        end
    end
    if not any then
        ns.Print("No profession links yet. Members need 0.19.1 or newer and to open each profession window once.")
    end
end

function P:Records(fid, key)
    local r = (store(fid) or {})[key]
    if not r then return nil end
    local rec = { r.name, r.v, r.text }
    local names = {}
    for n in pairs(r.links or {}) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do rec[#rec + 1] = r.links[n] end
    return { header("PL", fid), rec }
end

local function publish(fid, all, text, links)
    local cur = all[ns.meKey]
    all[ns.meKey] = { name = ns.me, v = math.max(((cur and cur.v) or 0) + 1, ns.Now()), text = text, links = links }
    local f = ns.Store:Get(fid)
    if not f.pendingFrom then ns.Sync:Broadcast(fid, P:Records(fid, ns.meKey)) end
    ns.Fire("PROFESSIONS_CHANGED", fid, ns.meKey)
end

-- Your profession window is open: remember its link (never someone else's linked window).
function P:CaptureLink()
    local T = C_TradeSkillUI
    if not (T and T.GetTradeSkillListLink) then return end
    for _, f in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting" }) do
        if T[f] then
            local ok, yes = pcall(T[f])
            if ok and yes then return end
        end
    end
    local ok, raw = pcall(T.GetTradeSkillListLink)
    local link, name = P.CleanLink(ok and raw)
    if not link then return end
    local fid = ns.Store:ActiveId()
    local all = fid and store(fid)
    if not all or not ns.me then return end
    local f = ns.Store:Get(fid)
    if f.myChatLinks and f.myChatLinks[name] then return end -- the one you posted in chat works better
    local cur = all[ns.meKey]
    local links = {}
    for k, v in pairs((cur and cur.links) or {}) do links[k] = v end
    if links[name] == link then return end
    links[name] = link
    publish(fid, all, (cur and cur.text) or P.Encode(P.Read() or {}), links)
end

-- A profession link someone posted in chat. The game's own chat links always open, so they
-- beat the one we read from the profession window: yours is shared with the fellowship, a
-- member's replaces what we had for them (on this computer only).
local function guidOf(link) return link:match("|Htrade:[^|]-(Player%-[%w%-]+)") end
local CHAT_MAX = 4000 -- links received through game chat can carry more data

-- A profession link in a Fellowship chat message is the sender's own copy, which only opens
-- for them. If we've received that profession's link through game chat, show that one instead.
function P.Upgrade(text)
    if type(text) ~= "string" or not text:find("|Htrade:", 1, true) then return text end
    local fid = ns.Store:ActiveId()
    local f = fid and ns.Store:Get(fid)
    local seen = f and f.chatLinks
    if not seen then return text end
    return (text:gsub("|c%x%x%x%x%x%x%x%x|Htrade:.-|h|r", function(raw)
        local link, pname = P.CleanLink(raw, CHAT_MAX)
        local g = link and guidOf(link)
        if not g then return raw end
        for _, links in pairs(seen) do
            local better = links[pname]
            if better and better ~= link and guidOf(better) == g then return better end
        end
        return raw
    end))
end
function P:OnChatLink(text, sender)
    if type(text) ~= "string" or not text:find("|Htrade:", 1, true) or not sender then return end
    local fid = ns.Store:ActiveId()
    local all = fid and store(fid)
    if not all or not ns.me then return end
    local name = ns.NormalizeName(sender)
    local key = name and ns.Key(name)
    if not key then return end
    for raw in text:gmatch("|c%x%x%x%x%x%x%x%x|Htrade:.-|h|r") do
        local link, pname = P.CleanLink(raw, key == ns.meKey and 200 or CHAT_MAX)
        if link then
            P.chatRaw = P.chatRaw or {}
            P.chatRaw[key .. ":" .. pname] = raw
            if key == ns.meKey then
                local mine = UnitGUID and UnitGUID("player")
                local cur = all[key]
                if (not mine or guidOf(link) == mine) and not (cur and cur.links and cur.links[pname] == link) then
                    local f = ns.Store:Get(fid)
                    f.myChatLinks = f.myChatLinks or {}
                    f.myChatLinks[pname] = link
                    local links = {}
                    for k, v in pairs((cur and cur.links) or {}) do links[k] = v end
                    links[pname] = link
                    publish(fid, all, (cur and cur.text) or P.Encode(P.Read() or {}), links)
                end
            elseif ns.Store:Roster(fid)[key] then
                local f = ns.Store:Get(fid)
                f.chatLinks = f.chatLinks or {}
                f.chatLinks[key] = f.chatLinks[key] or {}
                if f.chatLinks[key][pname] ~= link then
                    f.chatLinks[key][pname] = link
                    ns.Fire("PROFESSIONS_CHANGED", fid, key)
                end
            end
        end
    end
end

-- Read ours and share it if anything changed.
function P:Scan()
    local fid = ns.Store:ActiveId()
    local all = fid and store(fid)
    if not all or not ns.me then return end
    local list = P.Read()
    if not list then return end
    local text = P.Encode(list)
    local cur = all[ns.meKey]
    if cur and cur.text == text then return end
    -- drop links for professions you no longer have
    local have, links = {}, {}
    for _, p in ipairs(list) do have[p.name] = true end
    for k, v in pairs((cur and cur.links) or {}) do if have[k] then links[k] = v end end
    publish(fid, all, text, links)
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
    local links = {}
    for i = 4, math.min(#r, 11) do
        local link, pname = P.CleanLink(r[i])
        if link then links[pname] = link end
    end
    all[key] = { name = name, v = v, text = P.Encode(P.Decode(r[3])), links = links }
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
local linkQueued = false
local function queueLink()
    if linkQueued then return end
    linkQueued = true
    C_Timer.After(1, function() linkQueued = false; P:CaptureLink() end)
end
ns.On("TRADE_SKILL_SHOW", queueLink)
for _, ev in ipairs({ "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_GUILD",
    "CHAT_MSG_OFFICER", "CHAT_MSG_CHANNEL", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER" }) do
    ns.On(ev, function(text, sender)
        if ev == "CHAT_MSG_WHISPER_INFORM" then sender = ns.me end
        local ok, err = pcall(P.OnChatLink, P, text, sender)
        if not ok and ns.debugMode then ns.Print(tostring(err)) end
    end)
end
ns.On("TRADE_SKILL_LIST_UPDATE", queueLink)
ns.Listen("FELLOWSHIP_CHANGED", function() P:QueueScan() end)
