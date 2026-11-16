-- Channel: a hidden, password-protected chat channel for the fellowship, so one addon
-- message reaches every online member instead of one whisper each.
--
-- Name and password both come from the fellowship's id (the founder's name and the second
-- it was founded), which only members know. So every fellowship has its own channel, and
-- nobody can join it without being (or having been) a member. Senders are still checked
-- against the roster, exactly as for whispers.
--   name:     "Fs" + 10 letters/digits      password: 10 letters/digits
-- The code also includes how many members have been removed, so a removal moves everyone
-- to a fresh channel with a new password.
--
-- If the name is taken (wrong password), every member tries the same next names in the same
-- order: <name>2, <name>3 ... <name>5. If none works (or the game has no channel slot
-- free), Fellowship keeps using whispers. Whispers are also used for any member we haven't
-- heard on the channel yet (for example someone on an older version).
local _, ns = ...
local Ch = {}
ns.Channel = Ch

Ch.TARGET = "#channel" -- Comm target meaning "the fellowship channel"
local MAX_TRIES = 5
local JOIN_CHECK = 3   -- seconds to wait before checking that a join worked

local state = {}       -- { fid, base, password, try, name, id, joining, failed }
local peers = {}       -- member key -> true once we've heard them on the channel
local lastReply = 0

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

-- A short code from a string (plain arithmetic, so it's the same on every client).
local function code(s, seed, len)
    local h = seed
    for i = 1, #s do h = (h * 31 + s:byte(i) + i) % 2147483647 end
    local out = {}
    for i = 1, len do
        h = (h * 48271) % 2147483647
        local r = h % 36
        out[i] = DIGITS:sub(r + 1, r + 1)
    end
    return table.concat(out)
end

function Ch.Keys(fid, removals)
    local material = tostring(fid) .. "#" .. tostring(removals or 0)
    return "Fs" .. code(material, 7919, 10), code(material, 104729, 10)
end

local function removals(fid)
    local n = 0
    for _, e in ipairs(ns.Store:Sorted(fid)) do
        if e.k == "K" then n = n + 1 end
    end
    return n
end

local function channelId(name)
    if not (GetChannelName and name) then return 0 end
    local ok, id = pcall(GetChannelName, name)
    return (ok and tonumber(id)) or 0
end

---------------------------------------------------------------------------
-- Joining
---------------------------------------------------------------------------
function Ch:Available()
    return (JoinTemporaryChannel or JoinChannelByName) ~= nil and GetChannelName ~= nil
        and C_ChatInfo ~= nil and C_ChatInfo.SendAddonMessage ~= nil
end

local function hide(name)
    local remove = ChatFrame_RemoveChannel or (ChatFrameUtil and ChatFrameUtil.RemoveChannel)
    if not remove then return end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local frame = _G["ChatFrame" .. i]
        if frame then pcall(remove, frame, name) end
    end
end

function Ch:Leave()
    if state.name and channelId(state.name) > 0 and LeaveChannelByName then
        pcall(LeaveChannelByName, state.name)
    end
    state = {}
    peers = {}
end

-- Join (or move to) the channel for the active fellowship. Safe to call any time.
function Ch:Refresh()
    if not self:Available() then return end
    local f, fid = ns.Store:Active()
    if not f or f.pendingFrom then
        if state.name then self:Leave() end
        return
    end
    local base, password = Ch.Keys(fid, removals(fid))
    if state.base == base then
        -- same channel: rejoin only if we dropped out of it (e.g. after a disconnect)
        if state.joining or channelId(state.name) > 0 then return end
        -- couldn't get one: try again every few minutes (a channel slot may have come free)
        if state.failed and GetTime() - state.failedAt < 300 then return end
    else
        self:Leave()
    end
    state = { fid = fid, base = base, password = password, try = 1 }
    self:TryJoin()
end

function Ch:NameFor(try)
    return try == 1 and state.base or (state.base .. try)
end

function Ch:TryJoin()
    local name = self:NameFor(state.try)
    state.name, state.joining, state.id = name, true, 0
    local join = JoinTemporaryChannel or JoinChannelByName
    pcall(join, name, state.password)
    C_Timer.After(JOIN_CHECK, function() Ch:CheckJoined(name) end)
end

function Ch:CheckJoined(name)
    if state.name ~= name then return end
    local id = channelId(name)
    if id > 0 then
        state.id, state.joining = id, false
        hide(name)
        ns.Debug("fellowship channel joined (" .. name .. ")")
        self:Announce(true)
        return
    end
    -- taken by someone with another password, or no free channel slot: try the next name
    state.try = state.try + 1
    if state.try > MAX_TRIES then
        state.joining, state.failed, state.failedAt = false, true, GetTime()
        ns.Debug("no fellowship channel available; using whispers")
        return
    end
    ns.Debug("channel " .. name .. " unavailable, trying the next name")
    self:TryJoin()
end

-- The channel's number right now, or 0 when we're not on it.
function Ch:Id()
    if not state.name or state.joining then return 0 end
    local id = channelId(state.name)
    state.id = id
    return id
end

function Ch:Ready()
    return self:Id() > 0
end

function Ch:Name()
    return state.name
end

function Ch:IsOurs(name, localID)
    if not state.name then return false end
    if type(name) == "string" and name ~= "" then
        return name:lower() == state.name:lower() or name:lower():find(state.name:lower(), 1, true) ~= nil
    end
    return tonumber(localID) ~= nil and tonumber(localID) == state.id
end

---------------------------------------------------------------------------
-- Who is listening
---------------------------------------------------------------------------
function Ch:HasPeer(key)
    return peers[key] == true and self:Ready()
end

function Ch:PeerHeard(key)
    peers[key] = true
end

function Ch:PeerGone(key)
    peers[key] = nil
end

function Ch:PeerCount()
    local n = 0
    for _ in pairs(peers) do n = n + 1 end
    return n
end

-- "I'm on the channel" (wantReply asks everyone else to say so too).
function Ch:Announce(wantReply)
    local f, fid = ns.Store:Active()
    if not f or not self:Ready() then return end
    ns.Sync:SendChannel(fid, { { "CH", fid, ns.PROTOCOL, wantReply and "1" or "0", ns.VERSION } })
end

function Ch:OnAnnounce(key, wantReply)
    peers[key] = true
    if wantReply and GetTime() - lastReply > 5 then
        lastReply = GetTime()
        self:Announce(false)
    end
end

---------------------------------------------------------------------------
-- Keep the join notices ("Joined Channel: [6. Fs...]") out of chat
---------------------------------------------------------------------------
local function noticeFilter(_, _, text, _, _, channelName, _, _, _, _, baseName)
    if not state.base then return false end
    local b = state.base:lower()
    for _, s in ipairs({ baseName, channelName, text }) do
        if type(s) == "string" and s:lower():find(b, 1, true) then return true end
    end
    return false
end

function Ch:Init()
    local addFilter = ChatFrame_AddMessageEventFilter or (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)
    if addFilter then
        addFilter("CHAT_MSG_CHANNEL_NOTICE", noticeFilter)
        addFilter("CHAT_MSG_CHANNEL_NOTICE_USER", noticeFilter)
        addFilter("CHAT_MSG_CHANNEL_JOIN", noticeFilter)
        addFilter("CHAT_MSG_CHANNEL_LEAVE", noticeFilter)
    end
    -- the game joins its own channels first at login; ours after that
    C_Timer.After(6, function() Ch:Refresh() end)
    ns.Listen("FELLOWSHIP_CHANGED", function() Ch:Refresh() end)
    ns.Listen("EVENTS_ADDED", function(_, added)
        for _, e in ipairs(added) do
            if e.k == "K" or e.k == "J" or e.k == "N" then Ch:Refresh() return end
        end
    end)
    ns.Listen("PRESENCE", function(key, isOnline) if not isOnline then peers[key] = nil end end)
    -- rejoin if we ever drop out (disconnects, a channel reset)
    C_Timer.NewTicker(60, function() Ch:Refresh() end)
end

-- /fship channel
function Ch:PrintStatus()
    if not self:Available() then
        ns.Print("Fellowship channel: not supported by this game client; using whispers.")
    elseif self:Ready() then
        ns.Print(string.format("Fellowship channel: joined (%s, channel %d). %d member%s heard on it.",
            state.name, state.id, self:PeerCount(), self:PeerCount() == 1 and "" or "s"))
    elseif state.joining then
        ns.Print("Fellowship channel: joining " .. tostring(state.name) .. "...")
    elseif state.failed then
        ns.Print("Fellowship channel: couldn't join one (no free channel slot?); using whispers.")
    else
        ns.Print("Fellowship channel: not joined; using whispers.")
    end
end
