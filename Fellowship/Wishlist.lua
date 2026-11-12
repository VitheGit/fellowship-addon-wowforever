-- Wishlist: items each member is hunting for, shared with the fellowship.
--
-- Two kinds of wish:
--   once   gear, mounts, recipes: looting it marks it obtained ("Wish granted!"), and the
--          member who wants it is pinged when a fellowship member loots one.
--   always ore, herbs, cloth: stays on the list. No ping when you loot it yourself, an
--          optional quantity ("want 40") with your bag+bank count, a "Wanted by" tooltip
--          line, and a quiet reminder for members at a mailbox. Pings only if you ask.
--
-- Each character's list is one replicated record (newest version wins), kept outside the
-- event log so older Fellowship versions simply ignore it:
--   WL fid proto | author version | item... (id, mode, want, have, notify, note, name, quality)
--   WV fid proto | author version | ...      "these are the lists I have" (sent with HI);
--                                            whoever has a newer list sends it back
-- Any member can pass on anyone's list, so offline members' wishes still reach you.
local _, ns = ...
local W = {}
ns.Wishlist = W

W.MAX_ITEMS = 60
W.MAX_NOTE = 40
local PING_EVERY = 600      -- an "always" item with pings on: at most one ping per item per 10 minutes
local MAIL_EVERY = 1800     -- mailbox reminder: once per wanter and item per 30 minutes
local COUNT_DELAY = 30      -- bag counts are re-shared at most this often

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------
local function info(id)
    local name, link, quality
    if GetItemInfo then name, link, quality = GetItemInfo(id) end
    return name, link, quality
end

local function instantClass(id)
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not fn then return nil end
    local _, _, _, _, _, classID = fn(id)
    return classID
end

-- Trade goods (7) and reagents (5) default to "always wanted".
function W.DefaultMode(id)
    local c = instantClass(id)
    if c == 7 or c == 5 then return "always" end
    return "once"
end

-- An item link, an item id, "item:123", or a name the game already knows.
function W.ParseItem(text)
    if type(text) == "number" then return text end
    if type(text) ~= "string" then return nil end
    local id = text:match("|Hitem:(%d+)") or text:match("^%s*item:(%d+)") or text:match("^%s*(%d+)%s*$")
    if id then return tonumber(id) end
    local name = ns.Trim(text):gsub("^%[", ""):gsub("%]$", "")
    if name == "" then return nil end
    local _, link = info(name)
    id = link and link:match("|Hitem:(%d+)")
    return id and tonumber(id) or nil
end

-- Split "<item> [x40 | 40] [note]" typed after /fship wish.
function W.ParseCommand(rest)
    rest = ns.Trim(rest)
    local link, after = rest:match("^(|c.-|Hitem:.-|h|r)(.*)$")
    if not link then link, after = rest:match("^(|Hitem:.-|h)(.*)$") end
    local want
    if link then
        after = ns.Trim(after)
        local n, tail = after:match("^x?(%d+)%s*(.*)$")
        if n then want, after = tonumber(n), tail end
        return link, want, ns.Trim(after)
    end
    local name, n = rest:match("^(.-)%s+x?(%d+)$")
    if name then return name, tonumber(n), "" end
    return rest, nil, ""
end

-- Safe link for display (never shows a link someone else typed).
function W.Link(entry)
    local _, link = info(entry.id)
    if link then return link end
    return ns.Announce.ItemLink("item:" .. entry.id, entry.name or ("item " .. entry.id), entry.quality)
end

function W.Stocked(entry)
    return entry.mode == "always" and (entry.want or 0) > 0 and (entry.have or 0) >= entry.want
end

-- "14/40", "stocked 40/40", "" for a wish without a quantity
function W.Progress(entry)
    if entry.mode ~= "always" or (entry.want or 0) <= 0 then return "" end
    if W.Stocked(entry) then return "stocked" end
    return (entry.have or 0) .. "/" .. entry.want
end

---------------------------------------------------------------------------
-- Storage: f.wishes[charKey] = { name, v, items = { entry... } }
---------------------------------------------------------------------------
local function lists(fid)
    local f = ns.Store:Get(fid)
    if not f then return nil end
    f.wishes = f.wishes or {}
    return f.wishes
end

function W:List(fid, name)
    local all = lists(fid)
    local l = all and all[ns.Key(name)]
    return l and l.items or {}
end

function W:Mine()
    local fid = ns.Store:ActiveId()
    return fid and self:List(fid, ns.me) or {}
end

function W:Find(id)
    for i, e in ipairs(self:Mine()) do
        if e.id == id then return e, i end
    end
end

-- Every member's lists (yours included), skipping anyone no longer in the fellowship.
function W:AllLists(fid)
    local out = {}
    local roster = ns.Store:Roster(fid)
    for key, l in pairs(lists(fid) or {}) do
        if roster[key] and l.items and #l.items > 0 then out[#out + 1] = l end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- { { name = "Brad-Smith", entry = {...} }, ... } for one item
function W:Wanters(id, fid)
    fid = fid or ns.Store:ActiveId()
    local out = {}
    if not fid or not id then return out end
    for _, l in ipairs(self:AllLists(fid)) do
        for _, e in ipairs(l.items) do
            if e.id == id then out[#out + 1] = { name = l.name, entry = e } end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Wire format
---------------------------------------------------------------------------
local function encodeItem(e)
    return { e.id, e.mode == "always" and "a" or "o", e.want or 0, e.have or 0, e.notify and "1" or "",
        e.note or "", e.name or "", e.quality or "" }
end

local function decodeItem(r)
    local id = tonumber(r[1])
    if not id or id <= 0 or id ~= math.floor(id) then return nil end
    local note = ns.Truncate(tostring(r[6] or ""):gsub("%c", ""), W.MAX_NOTE)
    local name = ns.Truncate(tostring(r[7] or ""):gsub("[%c|%[%]]", ""), 100)
    return {
        id = id, mode = r[2] == "a" and "always" or "once",
        want = math.max(0, math.min(9999, math.floor(tonumber(r[3]) or 0))),
        have = math.max(0, math.min(99999, math.floor(tonumber(r[4]) or 0))),
        notify = r[5] == "1" or nil, note = note ~= "" and note or nil,
        name = name ~= "" and name or nil, quality = tonumber(r[8]),
    }
end

local function header(typ, fid)
    return { typ, fid, ns.PROTOCOL, "", ns.VERSION }
end

function W:Records(fid, key)
    local l = (lists(fid) or {})[key]
    if not l then return nil end
    local rec = { header("WL", fid), { l.name, l.v } }
    for _, e in ipairs(l.items or {}) do rec[#rec + 1] = encodeItem(e) end
    return rec
end

-- "These are the lists I have": sent with a HI reply. The other side sends back any list
-- we're behind on, and (when wantReply) its own summary if it is behind on any of ours.
local function header2(typ, fid, extra)
    return { typ, fid, ns.PROTOCOL, extra or "", ns.VERSION }
end

function W:SendSummary(fid, target, wantReply)
    local rec = { header2("WV", fid, wantReply and "1" or "0") }
    local roster = ns.Store:Roster(fid)
    for key, l in pairs(lists(fid) or {}) do
        if roster[key] then rec[#rec + 1] = { l.name, l.v } end
    end
    ns.Sync:SendRaw(target, rec, true)
end

function W:OnSummary(sender, fid, records, wantReply)
    local theirs = {}
    for i = 2, #records do
        local name, v = records[i][1], tonumber(records[i][2])
        if name and v then theirs[ns.Key(name)] = v end
    end
    local roster = ns.Store:Roster(fid)
    local all = lists(fid) or {}
    for key, l in pairs(all) do
        if roster[key] and (theirs[key] or -1) < (l.v or 0) then
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

function W:OnList(sender, fid, records)
    local r = records[2]
    local name, v = r and ns.NormalizeName(r[1]), r and tonumber(r[2])
    if not name or not v then return end
    local key = ns.Key(name)
    if not ns.Store:Roster(fid)[key] then return end
    local all = lists(fid)
    local cur = all[key]
    if cur and (cur.v or 0) >= v then return end
    local items, seen = {}, {}
    for i = 3, math.min(#records, W.MAX_ITEMS + 2) do
        local e = decodeItem(records[i])
        if e and not seen[e.id] then
            seen[e.id] = true
            items[#items + 1] = e
        end
    end
    all[key] = { name = name, v = v, items = items }
    for _, e in ipairs(items) do
        if e.name and not ns.ItemSearch:Learn(e.id) then ns.ItemSearch:Learn(e.id, e.name, e.quality) end
    end
    if key == ns.meKey then self:UpdateCounts(true) end -- our own list, restored from a friend
    ns.Fire("WISHLIST_CHANGED", fid, key)
end

---------------------------------------------------------------------------
-- Changing my list
---------------------------------------------------------------------------
function W:Publish()
    local fid = ns.Store:ActiveId()
    local all = fid and lists(fid)
    if not all then return end
    local l = all[ns.meKey]
    if not l then l = { name = ns.me, v = 0, items = {} }; all[ns.meKey] = l end
    l.name = ns.me
    l.v = math.max((l.v or 0) + 1, ns.Now())
    local f = ns.Store:Get(fid)
    if not f.pendingFrom then ns.Sync:Broadcast(fid, self:Records(fid, ns.meKey)) end
    ns.Fire("WISHLIST_CHANGED", fid, ns.meKey)
end

local function myItems()
    local fid = ns.Store:ActiveId()
    local all = fid and lists(fid)
    if not all then return nil end
    local l = all[ns.meKey]
    if not l then l = { name = ns.me, v = 0, items = {} }; all[ns.meKey] = l end
    return l.items
end

local function itemName(id)
    local name = info(id)
    return name
end

-- Returns the entry, or nil and a reason.
function W:Add(item, want, note, mode)
    if not ns.Store:Active() then return nil, "You're not in a fellowship yet." end
    local id = self.ParseItem(item)
    if not id then
        return nil, "Couldn't find that item. Shift-click or drag the item instead of typing its name."
    end
    local items = myItems()
    local e = self:Find(id)
    if not e then
        if #items >= W.MAX_ITEMS then return nil, "Your wishlist is full (" .. W.MAX_ITEMS .. " items)." end
        local name, _, quality = info(id)
        if not name and type(item) == "string" then name = item:match("|h%[(.-)%]|h") end
        e = { id = id, mode = mode or W.DefaultMode(id), want = 0, have = 0, name = name, quality = quality }
        items[#items + 1] = e
    elseif mode then
        e.mode = mode
    end
    if want then e.want = math.max(0, math.min(9999, math.floor(want))) end
    if note and ns.Trim(note) ~= "" then e.note = ns.Truncate(ns.Trim(note):gsub("%c", ""), W.MAX_NOTE) end
    if e.mode == "always" and GetItemCount then e.have = GetItemCount(id, true) or 0 end
    self:Publish()
    return e
end

function W:Remove(id)
    local _, i = self:Find(id)
    if not i then return false end
    table.remove(myItems(), i)
    self:Publish()
    return true
end

function W:SetMode(id, mode)
    local e = self:Find(id)
    if not e or e.mode == mode then return end
    e.mode = mode
    if mode == "always" and GetItemCount then e.have = GetItemCount(id, true) or 0 end
    self:Publish()
end

function W:SetWant(id, want)
    local e = self:Find(id)
    if not e then return end
    e.want = math.max(0, math.min(9999, math.floor(tonumber(want) or 0)))
    self:Publish()
end

function W:SetNote(id, note)
    local e = self:Find(id)
    if not e then return end
    note = ns.Truncate(ns.Trim(note):gsub("%c", ""), W.MAX_NOTE)
    e.note = note ~= "" and note or nil
    self:Publish()
end

function W:SetNotify(id, on)
    local e = self:Find(id)
    if not e then return end
    e.notify = on and true or nil
    self:Publish()
end

-- Bag + bank counts for "always" items; shared (debounced) when they change.
local countQueued = false
function W:UpdateCounts(quiet)
    if not GetItemCount then return end
    local changed = false
    for _, e in ipairs(self:Mine()) do
        if e.mode == "always" then
            local n = GetItemCount(e.id, true) or 0
            if n ~= (e.have or 0) then e.have = n; changed = true end
        end
    end
    if not changed then return end
    ns.Fire("WISHLIST_CHANGED", ns.Store:ActiveId(), ns.meKey)
    if quiet or countQueued then return end
    countQueued = true
    C_Timer.After(COUNT_DELAY, function()
        countQueued = false
        W:Publish()
    end)
end

---------------------------------------------------------------------------
-- Loot: called for every item you loot (Announce.lua posts the result)
---------------------------------------------------------------------------
local pinged = {} -- itemID -> GetTime() of the last ping for an "always" item

-- Returns granted (a "once" wish of yours), and the names of other members to tell.
function W:OnOwnLoot(id)
    local fid = ns.Store:ActiveId()
    if not fid or not id then return false, {} end
    local granted = false
    local e, i = self:Find(id)
    if e and e.mode == "once" then
        table.remove(myItems(), i)
        granted = true
        self:Publish()
    end
    local wanters, now = {}, GetTime()
    for _, w in ipairs(self:Wanters(id, fid)) do
        local x = w.entry
        if ns.Key(w.name) ~= ns.meKey then
            if x.mode == "once" or (x.notify and not W.Stocked(x)) then
                if x.mode == "once" or not pinged[id] or now - pinged[id] >= PING_EVERY then
                    wanters[#wanters + 1] = w.name
                end
            end
        end
    end
    for _, n in ipairs(wanters) do
        for _, w in ipairs(self:Wanters(id, fid)) do
            if w.name == n and w.entry.mode == "always" then pinged[id] = now end
        end
    end
    return granted, wanters
end

-- Is this loot event about something on my wishlist (or my alt's)?
function W.IsForMe(e)
    local csv = e.d and e.d[6]
    if not csv or csv == "" then return false end
    local fid = ns.Store:ActiveId()
    for n in csv:gmatch("[^,]+") do
        if ns.Key(n) == ns.meKey or (fid and ns.Store:SameAccount(fid, n, ns.me)) then return true end
    end
    return false
end

function W.WantersText(csv)
    local names = {}
    for n in tostring(csv or ""):gmatch("[^,]+") do names[#names + 1] = ns.ColorName(n) end
    if #names == 0 then return "" end
    if #names == 1 then return names[1] end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

---------------------------------------------------------------------------
-- Reminders: loot rolls and mailboxes
---------------------------------------------------------------------------
local function wantedLines(id, includeMe)
    local parts = {}
    for _, w in ipairs(W:Wanters(id)) do
        if (includeMe or ns.Key(w.name) ~= ns.meKey) and not W.Stocked(w.entry) then
            local p = W.Progress(w.entry)
            parts[#parts + 1] = (ns.Key(w.name) == ns.meKey and "you" or ns.ColorName(w.name))
                .. (p ~= "" and (" |cff808080(" .. p .. ")|r") or "")
        end
    end
    return parts
end

function W:OnLootRoll(rollID)
    local link = GetLootRollItemLink and GetLootRollItemLink(rollID)
    local id = link and W.ParseItem(link)
    if not id then return end
    local parts = wantedLines(id, true)
    if #parts == 0 then return end
    ns.Print("|cffffd100Wishlist:|r " .. link .. " is wanted by " .. table.concat(parts, ", ") .. ".")
end

local mailed = {} -- "key:id" -> GetTime()
function W:OnMailbox()
    local fid = ns.Store:ActiveId()
    if not fid or not GetItemCount then return end
    local now, lines = GetTime(), {}
    for _, l in ipairs(self:AllLists(fid)) do
        local key = ns.Key(l.name)
        if key ~= ns.meKey then
            for _, e in ipairs(l.items) do
                local n = GetItemCount(e.id) or 0
                local tag = key .. ":" .. e.id
                if n > 0 and not W.Stocked(e) and (not mailed[tag] or now - mailed[tag] >= MAIL_EVERY) then
                    mailed[tag] = now
                    lines[#lines + 1] = ns.ColorName(l.name) .. " wants " .. W.Link(e)
                        .. (W.Progress(e) ~= "" and (" |cff808080(" .. W.Progress(e) .. ")|r") or "")
                        .. " - you have " .. n .. "."
                end
            end
        end
    end
    for i = 1, math.min(#lines, 8) do ns.Print("|cffffd100Wishlist:|r " .. lines[i]) end
    if #lines > 8 then ns.Print("|cffffd100Wishlist:|r ...and " .. (#lines - 8) .. " more. See the Wishlist tab.") end
end

---------------------------------------------------------------------------
-- Tooltips: "Fellowship: wanted by Brad Smith (14/40)"
---------------------------------------------------------------------------
function W:TooltipLines(id)
    local mine, others = nil, {}
    for _, w in ipairs(self:Wanters(id)) do
        local p = W.Progress(w.entry)
        if ns.Key(w.name) == ns.meKey then
            mine = "|cff66ccffFellowship:|r on your wishlist" .. (p ~= "" and (" (" .. p .. ")") or "")
        else
            others[#others + 1] = ns.ColorName(w.name) .. (p ~= "" and (" |cffbbbbbb(" .. p .. ")|r") or "")
        end
    end
    local out = {}
    if #others > 0 then out[#out + 1] = "|cff66ccffFellowship:|r wanted by " .. table.concat(others, ", ") end
    if mine then out[#out + 1] = mine end
    return out
end

local function addTooltip(tooltip, id)
    if not tooltip or not id or not tooltip.AddLine then return end
    ns.ItemSearch:Learn(id)
    local lines = W:TooltipLines(id)
    for _, line in ipairs(lines) do tooltip:AddLine(line, 1, 1, 1, true) end
    if #lines > 0 and tooltip.Show and tooltip.IsShown and tooltip:IsShown() then tooltip:Show() end
end

function W:InitTooltips()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType
        and Enum.TooltipDataType.Item then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            local id = data and data.id
            if not id and tooltip.GetItem then
                local _, link = tooltip:GetItem()
                id = link and W.ParseItem(link)
            end
            addTooltip(tooltip, id)
        end)
        return
    end
    for _, tt in ipairs({ GameTooltip, ItemRefTooltip }) do
        if tt and tt.HookScript then
            tt:HookScript("OnTooltipSetItem", function(self)
                local _, link = self:GetItem()
                addTooltip(self, link and W.ParseItem(link))
            end)
        end
    end
end

---------------------------------------------------------------------------
-- Right-click an item link in chat: "Add to Fellowship Wishlist"
---------------------------------------------------------------------------
function W:OfferMenu(link)
    local id = W.ParseItem(link)
    if not id or not ns.Store:Active() or not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(UIParent, function(_, root)
        root:CreateTitle("Fellowship Wishlist")
        if W:Find(id) then
            root:CreateButton("Remove from Wishlist", function() W:Remove(id); ns.Print("Removed from your wishlist.") end)
        else
            root:CreateButton("Add to Wishlist", function() W:AddAndSay(link) end)
        end
    end)
end

function W:AddAndSay(item, want, note, mode)
    local e, err = self:Add(item, want, note, mode)
    if not e then ns.Print(err); return end
    ns.Print("Added " .. W.Link(e) .. " to your wishlist"
        .. (e.mode == "always" and " (always wanted" .. (e.want > 0 and (", want " .. e.want) or "") .. ")" or "")
        .. ". Right-click it in the Wishlist tab to change it.")
end

function W:Slash(rest)
    rest = ns.Trim(rest)
    if rest == "" then ns.UI:Show("wishlist"); return end
    local item, want, note = W.ParseCommand(rest)
    self:AddAndSay(item, want, note)
end

function W:SlashRemove(rest)
    local id = W.ParseItem(rest)
    if id and self:Remove(id) then ns.Print("Removed from your wishlist.")
    else ns.Print("That item isn't on your wishlist.") end
end

---------------------------------------------------------------------------
function W:Init()
    self:InitTooltips()
    ns.On("BAG_UPDATE_DELAYED", function() W:UpdateCounts() end)
    ns.On("PLAYERBANKSLOTS_CHANGED", function() W:UpdateCounts() end)
    ns.On("BANKFRAME_OPENED", function() W:UpdateCounts() end)
    ns.On("START_LOOT_ROLL", function(rollID) W:OnLootRoll(rollID) end)
    ns.On("MAIL_SHOW", function() W:OnMailbox() end)
    C_Timer.After(10, function() W:UpdateCounts() end)
    -- the wanter hears a sound when someone loots an item they want
    ns.Listen("EVENTS_ADDED", function(_, added, live)
        if not live then return end
        for _, e in ipairs(added) do
            if e.k == "M" and e.d and e.d[1] == "loot" and e.a ~= ns.me and W.IsForMe(e) then
                if PlaySound and SOUNDKIT then
                    PlaySound(SOUNDKIT.RAID_WARNING or SOUNDKIT.UI_EPICLOOT_TOAST or SOUNDKIT.LEVELUP)
                end
                break
            end
        end
    end)
    -- right-click an item link in chat
    if hooksecurefunc and SetItemRef then
        hooksecurefunc("SetItemRef", function(link, _, button)
            if button == "RightButton" and type(link) == "string" and link:match("^item:") then
                W:OfferMenu(link)
            end
        end)
    end
end
