-- Member notes: each member can write a short note about themselves ("Main: Hunter, alt: Mage",
-- "Leveling Mining"), shown to everyone in the Members tab. Only you can set your own note.
-- Synced like wishlists, outside the event log, so older versions just ignore it:
--   NL  fid proto "" ver | name v note        one character's note (newest v wins)
--   NV  fid proto reply ver | name v | ...    "these are the notes I have" (with a HI reply)
local _, ns = ...
local N = {}
ns.Notes = N

N.MAX_LEN = 60

local function notes(fid)
    local f = ns.Store:Get(fid)
    if not f then return nil end
    f.notes = f.notes or {}
    return f.notes
end

local function header(typ, fid, extra)
    return { typ, fid, ns.PROTOCOL, extra or "", ns.VERSION }
end

function N.Clean(text)
    text = tostring(text or ""):gsub("[%c|]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #text > N.MAX_LEN then text = text:sub(1, N.MAX_LEN) end
    return text
end

-- The note for an account: the newest one set from any of its characters.
function N:ForChars(chars, fid)
    fid = fid or ns.Store:ActiveId()
    local all = fid and notes(fid) or {}
    local best
    for _, name in ipairs(chars or {}) do
        local n = all[ns.Key(name)]
        if n and (not best or (n.v or 0) > (best.v or 0)) then best = n end
    end
    return best and best.text ~= "" and best.text or nil
end

function N:Mine()
    local fid = ns.Store:ActiveId()
    if not fid then return "" end
    local roster, _, state = ns.Store:Roster(fid)
    local me = roster[ns.meKey]
    local acct = me and state and state.accounts and state.accounts[me.account]
    return self:ForChars(acct and acct.chars or { ns.me }, fid) or ""
end

function N:Records(fid, key)
    local n = (notes(fid) or {})[key]
    if not n then return nil end
    return { header("NL", fid), { n.name, n.v, n.text } }
end

function N:Set(text)
    local fid = ns.Store:ActiveId()
    local all = fid and notes(fid)
    if not all then return false end
    local cur = all[ns.meKey]
    all[ns.meKey] = { name = ns.me, v = math.max(((cur and cur.v) or 0) + 1, ns.Now()), text = N.Clean(text) }
    local f = ns.Store:Get(fid)
    if not f.pendingFrom then ns.Sync:Broadcast(fid, self:Records(fid, ns.meKey)) end
    ns.Fire("NOTES_CHANGED", fid, ns.meKey)
    return true
end

function N:OnNote(sender, fid, records)
    local r = records[2]
    local name, v = r and ns.NormalizeName(r[1]), r and tonumber(r[2])
    if not name or not v then return end
    local key = ns.Key(name)
    if not ns.Store:Roster(fid)[key] then return end
    local all = notes(fid)
    local cur = all[key]
    if cur and (cur.v or 0) >= v then return end
    all[key] = { name = name, v = v, text = N.Clean(r[3]) }
    ns.Fire("NOTES_CHANGED", fid, key)
end

function N:SendSummary(fid, target, wantReply)
    local rec = { header("NV", fid, wantReply and "1" or "0") }
    local roster = ns.Store:Roster(fid)
    for key, n in pairs(notes(fid) or {}) do
        if roster[key] then rec[#rec + 1] = { n.name, n.v } end
    end
    -- nothing to offer: skip it (whoever has notes sends theirs, and asks back if behind)
    if #rec == 1 and wantReply then return end
    ns.Sync:SendRaw(target, rec, true)
end

function N:OnSummary(sender, fid, records, wantReply)
    local theirs = {}
    for i = 2, #records do
        local name, v = records[i][1], tonumber(records[i][2])
        if name and v then theirs[ns.Key(name)] = v end
    end
    local roster = ns.Store:Roster(fid)
    local all = notes(fid) or {}
    for key, n in pairs(all) do
        if roster[key] and (theirs[key] or -1) < (n.v or 0) then
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

-- /fship note <text> sets it, /fship note alone shows it, /fship note clear removes it
function N:Slash(rest)
    rest = ns.Trim and ns.Trim(rest or "") or (rest or "")
    if not ns.Store:Active() then ns.Print("You're not in a fellowship yet.") return end
    if rest == "" then
        local mine = self:Mine()
        ns.Print(mine ~= "" and ("Your note: " .. mine) or "You have no note. Set one with /fship note <text>.")
        return
    end
    if rest:lower() == "clear" then rest = "" end
    self:Set(rest)
    ns.Print(rest ~= "" and ("Note set: " .. N.Clean(rest)) or "Note cleared.")
end
