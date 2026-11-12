-- Comm: addon messaging (whispers, plus the hidden fellowship channel) with chunking,
-- throttling and offline detection.
--
-- Wire frame: "<msgId>:<index>:<total>:<data>", at most 255 bytes.
-- Two queues: "live" (chat, presence, requests) always goes before "bulk" (history catch-up),
-- so a long backfill never delays a new chat line.
local _, ns = ...
local Comm = {}
ns.Comm = Comm

local MAX_DATA = 238       -- 255 minus room for the frame header
Comm.BURST = 10            -- addon message allowance per prefix
Comm.RATE = 1              -- allowance regained per second (conservative Mainline value)

local liveQueue, bulkQueue = {}, {}
local tokens, lastRefill = Comm.BURST, nil
local ticker
local msgCounter = 0
local recentTargets = {}   -- key -> GetTime() expiry; used to recognise our own "player not found" errors
local partials = {}        -- sender|msgId -> reassembly state
local notFoundPattern

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX)
end

local function toBase36(n)
    local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    local s = ""
    repeat
        local r = n % 36
        s = digits:sub(r + 1, r + 1) .. s
        n = math.floor(n / 36)
    until n == 0
    return s
end

-- Length of the longest prefix of s (starting at pos) that is <= max bytes and
-- does not split a UTF-8 character.
local function safeCut(s, pos, max)
    local remaining = #s - pos + 1
    if remaining <= max then return remaining end
    local n = max
    while n > 0 do
        local b = s:byte(pos + n) -- first byte of the next chunk
        if not b or b < 0x80 or b >= 0xC0 then break end
        n = n - 1
    end
    if n == 0 then n = max end
    return n
end

local function buildNotFoundPattern()
    local fmt = ERR_CHAT_PLAYER_NOT_FOUND_S or "No player named '%s' is currently playing."
    local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%%%s", "(.+)")
    return "^" .. p .. "$"
end

local function systemFilter(_, _, msg, ...)
    if type(msg) ~= "string" then return false end
    local name = msg:match(notFoundPattern)
    if not name then return false end
    name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
    local key = ns.Key(name)
    local exp = recentTargets[key]
    if exp and exp > GetTime() then
        Comm:DropTarget(key)
        ns.Sync:MarkOffline(key)
        return true -- hide the error; it was caused by us
    end
    return false
end

function Comm:Init()
    notFoundPattern = buildNotFoundPattern()
    local addFilter = ChatFrame_AddMessageEventFilter
        or (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)
    if addFilter then addFilter("CHAT_MSG_SYSTEM", systemFilter) end
    ns.On("CHAT_MSG_ADDON", function(prefix, text, channel, sender, _, _, localID, channelName)
        if prefix ~= ns.PREFIX then return end
        if channel == "WHISPER" then
            Comm:OnFrame(text, sender, false)
        elseif channel == "CHANNEL" and ns.Channel:IsOurs(channelName, localID) then
            Comm:OnFrame(text, sender, true)
        end
    end)
    lastRefill = GetTime()
end

-- Queue `payload` for `target`. bulk = true for history catch-up traffic.
function Comm:Send(target, payload, bulk)
    ns.Debug("-> " .. (payload:match("^[^\30\31]*") or "?") .. " to " .. tostring(target) .. " (" .. #payload .. " bytes)")
    msgCounter = (msgCounter % 46655) + 1
    local id = toBase36(msgCounter)
    local parts, pos = {}, 1
    while pos <= #payload do
        local n = safeCut(payload, pos, MAX_DATA)
        parts[#parts + 1] = payload:sub(pos, pos + n - 1)
        pos = pos + n
    end
    if #parts == 0 then parts[1] = "" end
    local q = bulk and bulkQueue or liveQueue
    for i, p in ipairs(parts) do
        q[#q + 1] = { target = target, key = ns.Key(target), text = id .. ":" .. i .. ":" .. #parts .. ":" .. p }
    end
    self:Pump()
end

function Comm:DropTarget(key)
    for _, q in ipairs({ liveQueue, bulkQueue }) do
        for i = #q, 1, -1 do
            if q[i].key == key then table.remove(q, i) end
        end
    end
end

function Comm:Pending()
    return #liveQueue + #bulkQueue
end

local function rawSend(item)
    local result
    if item.target == ns.Channel.TARGET then
        local id = ns.Channel:Id()
        if id == 0 then return "sent" end -- left the channel meanwhile; gap fill will cover it
        result = C_ChatInfo.SendAddonMessage(ns.PREFIX, item.text, "CHANNEL", id)
    else
        recentTargets[item.key] = GetTime() + 30
        result = C_ChatInfo.SendAddonMessage(ns.PREFIX, item.text, "WHISPER", item.target)
    end
    local E = Enum and Enum.SendAddonMessageResult
    if not E or result == nil or result == true or result == E.Success then return "sent" end
    -- the game wouldn't send it right now (throttled, or addon messages locked down, e.g. in
    -- combat inside an instance): keep it and try again shortly instead of losing it
    if result == E.AddonMessageThrottle or result == E.ChannelThrottle or result == E.AddOnMessageLockdown
        or result == E.AddonMessageLockdown or result == E.GeneralError then
        return "retry"
    end
    if result == E.TargetOffline and item.target ~= ns.Channel.TARGET then
        ns.Sync:MarkOffline(item.key)
        return "drop-target"
    end
    ns.Debug("send to " .. tostring(item.target) .. " failed (result " .. tostring(result) .. ")")
    return "sent" -- not recoverable by retrying; drop this frame
end

function Comm:Pump()
    local now = GetTime()
    tokens = math.min(Comm.BURST, tokens + (now - (lastRefill or now)) * Comm.RATE)
    lastRefill = now
    while tokens >= 1 do
        local q = (#liveQueue > 0) and liveQueue or bulkQueue
        local item = q[1]
        if not item then break end
        local r = rawSend(item)
        if r == "sent" then
            table.remove(q, 1)
            tokens = tokens - 1
        elseif r == "drop-target" then
            self:DropTarget(item.key)
            tokens = tokens - 1
        else
            tokens = 0 -- server says slow down; retry later
            break
        end
    end
    local busy = (#liveQueue + #bulkQueue) > 0
    if busy and not ticker then
        ticker = C_Timer.NewTicker(0.25, function() Comm:Pump() end)
    elseif not busy and ticker then
        ticker:Cancel()
        ticker = nil
    end
end

function Comm:OnFrame(text, sender, viaChannel)
    sender = ns.NormalizeName(sender)
    if not sender or type(text) ~= "string" then return end
    local id, idx, total, data = text:match("^(%w+):(%d+):(%d+):(.*)$")
    if not id then return end
    idx, total = tonumber(idx), tonumber(total)
    if total < 1 or total > 4000 or idx < 1 or idx > total then return end
    if total == 1 then return self:Deliver(sender, data, viaChannel) end

    local now = GetTime()
    local key = sender .. "|" .. id .. (viaChannel and "|c" or "")
    local p = partials[key]
    if not p or p.total ~= total then
        for k, old in pairs(partials) do
            if old.expires < now then partials[k] = nil end
        end
        p = { total = total, n = 0, parts = {} }
        partials[key] = p
    end
    p.expires = now + 120
    if not p.parts[idx] then
        p.parts[idx] = data
        p.n = p.n + 1
    end
    if p.n == p.total then
        partials[key] = nil
        self:Deliver(sender, table.concat(p.parts), viaChannel)
    end
end

function Comm:Deliver(sender, data, viaChannel)
    local records = ns.Serializer.Decode(data)
    xpcall(function() ns.Sync:OnMessage(sender, records, viaChannel) end, geterrorhandler())
end
