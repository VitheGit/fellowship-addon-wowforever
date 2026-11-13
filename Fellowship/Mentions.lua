-- Mentions: "@Kara" or "@Kara Dunmore" in fellowship chat tags a member. The tagged member
-- (any character on their account) hears a sound, sees an alert and their game icon flashes.
-- "@all" or "@everyone" tags everybody. Mentions are just text, so nothing new is sent and
-- older versions simply show the "@" as written.
local _, ns = ...
local M = {}
ns.Mentions = M

local EVERYONE = { all = true, everyone = true, fellowship = true }
local HIGHLIGHT = "|cffff9933"

local function split(name) -- "Kara-Dunmore" -> "kara", "dunmore"
    local first, last = tostring(name or ""):match("^([^%-]+)%-?(.*)$")
    return (first or ""):lower(), (last or ""):lower()
end

-- first name (lowercase) -> { { name, last, account } ... }, for every character of every member
function M.Names(fid)
    fid = fid or ns.Store:ActiveId()
    local out = {}
    if not fid then return out end
    for _, m in pairs(ns.Store:Roster(fid)) do
        local first, last = split(m.name)
        if first ~= "" then
            out[first] = out[first] or {}
            table.insert(out[first], { name = m.name, last = last, account = m.account })
        end
    end
    return out
end

-- Accounts tagged in a chat line: { [accountKey] = true }, and whether it was @all.
function M.Parse(text, fid)
    local names, tagged, all = M.Names(fid), {}, false
    text = tostring(text or "")
    for word, rest in text:gmatch("@([^%s%p]+)%s?([^%s%p]*)") do
        local w = word:lower()
        if EVERYONE[w] then
            all = true
        else
            local list = names[w]
            if list then
                -- "@Kara Dunmore" picks that Kara; "@Kara" tags every Kara
                local exact
                for _, c in ipairs(list) do
                    if rest ~= "" and c.last == rest:lower() then exact = c end
                end
                if exact then tagged[exact.account] = true
                else for _, c in ipairs(list) do tagged[c.account] = true end end
            end
        end
    end
    return tagged, all
end

function M.MentionsMe(text, fid)
    fid = fid or ns.Store:ActiveId()
    if not fid then return false end
    local me = ns.Store:Roster(fid)[ns.meKey]
    if not me then return false end
    local tagged, all = M.Parse(text, fid)
    return all or tagged[me.account] == true
end

-- Colour the @names in a chat line that's already safe for display. `resume` is the line's
-- own colour, restored after each tag.
function M.Highlight(text, resume, fid)
    local names = M.Names(fid)
    resume = resume or "|r"
    return (text:gsub("@([^%s%p]+)(%s?)([^%s%p]*)", function(word, space, rest)
        local w = word:lower()
        local list = names[w]
        if EVERYONE[w] then return HIGHLIGHT .. "@" .. word .. "|r" .. resume .. space .. rest end
        if not list then return nil end
        for _, c in ipairs(list) do
            if rest ~= "" and c.last == rest:lower() then
                return HIGHLIGHT .. "@" .. word .. space .. rest .. "|r" .. resume
            end
        end
        return HIGHLIGHT .. "@" .. word .. "|r" .. resume .. space .. rest
    end))
end

-- Tab in the chat box: "@ka" -> "@Kara ". Returns the new text, or nil.
function M.Complete(text, fid)
    local before, prefix = tostring(text or ""):match("^(.-)@([^%s%p]*)$")
    if not before then return nil end
    local p = prefix:lower()
    local best
    for first, list in pairs(M.Names(fid)) do
        if first:sub(1, #p) == p and list[1] and ns.Key(list[1].name) ~= ns.meKey then
            local display = list[1].name:match("^([^%-]+)")
            if not best or display < best then best = display end
        end
    end
    if not best and ("all"):sub(1, #p) == p and #p > 0 then best = "all" end
    if not best then return nil end
    return before .. "@" .. best .. " "
end

function M:Alert(e)
    if ns.settings.mentionAlert == false then return end
    if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.TELL_MESSAGE or 3081) end
    if UIErrorsFrame and UIErrorsFrame.AddMessage then
        UIErrorsFrame:AddMessage(ns.Short(e.a) .. " mentioned you in Fellowship chat", 0.31, 0.82, 0.71)
    end
    if FlashClientIcon then FlashClientIcon() end
end

-- Unread chat lines that tag you (for "While you were away").
function M.UnreadCount(fid)
    local n = 0
    for _, e in ipairs(ns.Store:Sorted(fid)) do
        if e.k == "C" and ns.Store:IsUnread(fid, e) and not ns.Store:SameAccount(fid, e.a, ns.me)
            and M.MentionsMe(e.d and e.d[1], fid) then
            n = n + 1
        end
    end
    return n
end

ns.Listen("EVENTS_ADDED", function(fid, added, live)
    if not live then return end
    for _, e in ipairs(added) do
        if e.k == "C" and e.a ~= ns.me and not ns.Store:SameAccount(fid, e.a, ns.me)
            and M.MentionsMe(e.d and e.d[1], fid) then
            M:Alert(e)
            break
        end
    end
end)
