-- A tiny simulated WoW world: several game clients, whispers, timers, a server clock,
-- addon-message throttling and SavedVariables that survive logout/login.
-- Each client loads the real addon files into its own sandboxed global environment.
local World = {}
World.__index = World

local ADDON_DIR = (arg and arg[0] and arg[0]:match("^(.*)/tests/")) or "."
ADDON_DIR = ADDON_DIR .. "/Fellowship/"
local FILES = { "Core.lua", "Serializer.lua", "Store.lua", "Comm.lua", "Sync.lua", "Announce.lua", "Menu.lua", "Minimap.lua", "UI.lua" }

local function deepcopy(v)
    if type(v) ~= "table" then
        if type(v) == "function" then error("function in SavedVariables") end
        return v
    end
    local out = {}
    for k, x in pairs(v) do out[deepcopy(k)] = deepcopy(x) end
    return out
end

function World.new()
    return setmetatable({ time = 1000, epoch = 1762700000, clients = {}, timers = {}, mail = {}, seq = 0 }, World)
end

function World:schedule(at, fn, owner)
    self.seq = self.seq + 1
    table.insert(self.timers, { at = at, fn = fn, owner = owner, id = self.seq })
end

function World:advance(seconds)
    local target = self.time + seconds
    while true do
        table.sort(self.timers, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.id < b.id end)
        local nxt = self.timers[1]
        if not nxt or nxt.at > target then break end
        table.remove(self.timers, 1)
        self.time = math.max(self.time, nxt.at)
        if not nxt.owner or nxt.owner.session == nxt.session then nxt.fn() end
    end
    self.time = target
end

-- A stub UI object: remembers scripts/text/shown, ignores everything else.
local function newStub()
    local stub = { _scripts = {}, _shown = true, _text = "", _events = {} }
    local methods = {
        SetScript = function(self, name, fn) self._scripts[name] = fn end,
        GetScript = function(self, name) return self._scripts[name] end,
        RegisterEvent = function(self, ev) self._events[ev] = true end,
        UnregisterEvent = function(self, ev) self._events[ev] = nil end,
        Show = function(self)
            local was = self._shown; self._shown = true
            if not was and self._scripts.OnShow then self._scripts.OnShow(self) end
        end,
        Hide = function(self)
            local was = self._shown; self._shown = false
            if was and self._scripts.OnHide then self._scripts.OnHide(self) end
        end,
        IsShown = function(self) return self._shown end,
        SetText = function(self, t) self._text = t end,
        GetText = function(self) return self._text end,
        AddMessage = function(self, m) self._lines = self._lines or {}; table.insert(self._lines, m) end,
        Clear = function(self) self._lines = {} end,
        CreateFontString = function() return newStub() end,
        SetChecked = function(self, v) self._checked = v end,
        GetChecked = function(self) return self._checked end,
        Click = function(self) if self._scripts.OnClick then self._scripts.OnClick(self) end end,
        CreateTexture = function() return newStub() end,
    }
    return setmetatable(stub, { __index = function(_, k) return methods[k] or function() end end })
end

local Client = {}
Client.__index = Client

function World:client(name, realm)
    local c = setmetatable({ world = self, name = name, realm = realm or "Silvermoon", saved = nil,
        online = false, log = {}, popups = {}, session = 0 }, Client)
    c.full = c.name .. "-" .. c.realm
    self.clients[c.full:lower()] = c
    return c
end

function World:find(target, realm)
    local full = target:find("-", 1, true) and target or (target .. "-" .. realm)
    return self.clients[full:lower()]
end

function Client:fire(event, ...)
    for _, f in ipairs(self.frames) do
        if f._events[event] and f._scripts.OnEvent then f._scripts.OnEvent(f, event, ...) end
    end
end

function Client:login()
    local world = self.world
    self.session = self.session + 1
    local session = self.session
    local client = self
    self.online = true
    self.frames = {}
    self.filters = {}
    self.menus = {}
    self.units = self.units or {}
    self.bucket = { tokens = 10, last = world.time }
    local env = {}
    self.env = env
    local function after(delay, fn)
        world:schedule(world.time + delay, fn, client)
        world.timers[#world.timers].session = session
    end
    local base = {
        string = string, table = table, math = math, pairs = pairs, ipairs = ipairs, type = type,
        tostring = tostring, tonumber = tonumber, select = select, next = next, error = error,
        pcall = pcall, xpcall = xpcall, setmetatable = setmetatable, getmetatable = getmetatable,
        unpack = unpack, rawget = rawget, rawset = rawset,
        date = os.date, time = os.time,
        tinsert = table.insert,
        print = function(...) local t = {}; for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end; table.insert(client.log, table.concat(t, " ")) end,
        geterrorhandler = function() return function(err) error(err, 0) end end,
        GetTime = function() return world.time end,
        GetServerTime = function() return world.epoch + math.floor(world.time) end,
        UnitFullName = function(unit)
            if unit and unit ~= "player" then local u = client.units[unit]; return u.name, u.realm end
            return client.name, client.realm
        end,
        Menu = { ModifyMenu = function(tag, fn) client.menus[tag] = client.menus[tag] or {}; table.insert(client.menus[tag], fn) end },
        UnitExists = function(unit) return client.units[unit] ~= nil end,
        UnitIsPlayer = function(unit) return client.units[unit] and client.units[unit].player end,
        UnitFactionGroup = function(unit) if unit == "player" then return "Alliance" end return client.units[unit] and client.units[unit].faction end,
        UnitLevel = function() return client.level or 60 end,
        UnitGUID = function(unit) return unit == "player" and ("Player-" .. client.name) or nil end,
        GetZoneText = function() return client.zone or "Elwynn Forest" end,
        LOOT_ITEM_SELF = "You receive loot: %s.",
        LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d.",
        LOOT_ITEM_PUSHED_SELF = "You receive item: %s.",
        ITEM_QUALITY_COLORS = { [3] = { hex = "|cff0070dd" }, [4] = { hex = "|cffa335ee" }, [5] = { hex = "|cffff8000" } },
        C_Item = { GetItemQualityByID = function(link) local q = tonumber(link:match("|cff%x+|Hitem:%d+:(%d)")); return q end },
        GetItemInfo = function(id) return "Item " .. tostring(id), nil, nil end,
        C_MountJournal = { GetMountInfoByID = function(id) return "Mount " .. id, 1000 + id end },
        C_PetJournal = { GetPetInfoByPetID = function() return 1, nil, 1, 0, 0, 0, false, "Mechanical Squirrel" end },
        C_ToyBox = { GetToyInfo = function(id) return id, "Toy " .. id end },
        C_Spell = { GetSpellLink = function(id) return "|cff71d5ff|Hspell:" .. id .. "|h[Mount spell]|h|r" end },
        GetInstanceInfo = function()
            local i = client.instance
            if not i then return client.zone or "Elwynn Forest", "none", 0, "", 5, 0, false, 0 end
            return i.name, i.type, i.difficultyID or 1, i.difficulty or "Normal", 5, 0, false, i.id or 99
        end,
        C_Map = { GetBestMapForUnit = function() return client.instance and 500 or 1 end },
        EJ_GetInstanceForMap = function(mapID) return mapID == 500 and 77 or 0 end,
        EJ_GetEncounterInfoByIndex = function(i)
            local bosses = client.instance and client.instance.bosses or {}
            if not bosses[i] then return nil end
            return "Boss " .. i, "", 0, 0, "", 77, bosses[i], 0
        end,
        C_ChallengeMode = { GetChallengeCompletionInfo = function() return { level = 15, onTime = true } end },
        CombatLogGetCurrentEventInfo = function() return unpack(client.cleu or {}) end,
        UnitClass = function() return client.class or "Hunter", (client.class or "HUNTER"):upper(), 3 end,
        RAID_CLASS_COLORS = { HUNTER = { r = 0.67, g = 0.83, b = 0.45, colorStr = "ffaad372" } },
        GetNormalizedRealmName = function() return client.realm end,
        CreateFrame = function() local f = newStub(); f._shown = true; table.insert(client.frames, f); return f end,
        UIParent = newStub(), ChatFontNormal = newStub(),
        UISpecialFrames = {}, StaticPopupDialogs = {}, SlashCmdList = {},
        StaticPopup_Show = function(which, a, b, data) table.insert(client.popups, { which = which, a = a, b = b, data = data }) end,
        SetItemRef = function() end, IsShiftKeyDown = function() return false end,
        ACCEPT = "Accept", DECLINE = "Decline", YES = "Yes", NO = "No",
        ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing.",
        NUM_CHAT_WINDOWS = 10,
        GetChatWindowInfo = function(i) return ({ "General", "Fellowship" })[i] end,
        ChatFrame_AddMessageEventFilter = function(event, fn)
            client.filters[event] = client.filters[event] or {}
            table.insert(client.filters[event], fn)
        end,
        GetAchievementInfo = function(id) return id, "Achievement #" .. id, 10, false, nil, nil, nil, "", 0, 0, "", false end,
        GetAchievementLink = function(id) return "|cffffff00|Hachievement:" .. id .. "|h[Achievement #" .. id .. "]|h|r" end,
        Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3 } },
        C_Timer = {
            After = after,
            NewTicker = function(interval, fn)
                local t = { cancelled = false }
                function t:Cancel() self.cancelled = true end
                local function tick() if not t.cancelled then fn(); after(interval, tick) end end
                after(interval, tick)
                return t
            end,
        },
        C_ChatInfo = {
            RegisterAddonMessagePrefix = function() return true end,
            SendAddonMessage = function(prefix, text, channel, target)
                assert(#text <= 255, "addon message too long: " .. #text)
                assert(#prefix <= 16)
                -- server-side throttle: 10 burst, 1/sec
                local b = client.bucket
                b.tokens = math.min(10, b.tokens + (world.time - b.last))
                b.last = world.time
                if b.tokens < 1 then world.throttled = (world.throttled or 0) + 1; return 3 end
                b.tokens = b.tokens - 1
                world.sent = (world.sent or 0) + 1
                local from = client.full
                world:schedule(world.time + 0.05, function()
                    local dest = world:find(target, client.realm)
                    if dest and dest.online then
                        dest:fire("CHAT_MSG_ADDON", prefix, text, channel, from)
                    elseif client.online then
                        client:system(string.format("No player named '%s' is currently playing.", target))
                    end
                end)
                return 0
            end,
        },
    }
    client.log2 = {}
    base.ChatFrame1 = { AddMessage = function(_, m) table.insert(client.log, m) end, GetID = function() return 1 end }
    base.ChatFrame2 = { AddMessage = function(_, m) table.insert(client.log2, m) end, GetID = function() return 2 end }
    base.DEFAULT_CHAT_FRAME = base.ChatFrame1
    base.Minimap = newStub()
    base.GameTooltip = newStub()
    base.GetCursorPosition = function() return 0, 0 end
    base.MenuUtil = { CreateContextMenu = function(owner, gen)
        local items = {}
        local root = { CreateTitle = function() end,
            CreateButton = function(_, text, fn) table.insert(items, { text = text, fn = fn }) end }
        gen(owner, root)
        client.contextMenu = items
    end }
    base.SELECTED_CHAT_FRAME = base.ChatFrame1
    setmetatable(env, { __index = base })
    env._G = env
    local acct = self.accountOf
    if acct and acct.saved then self.saved = acct.saved end
    if self.saved then env.FellowshipDB = deepcopy(self.saved) end
    local ns = {}
    for _, file in ipairs(FILES) do
        local chunk = assert(loadfile(ADDON_DIR .. file))
        setfenv(chunk, env)
        chunk("Fellowship", ns)
    end
    self.ns = ns
    self:fire("ADDON_LOADED", "Fellowship")
    self:fire("PLAYER_LOGIN")
    self:fire("PLAYER_ENTERING_WORLD")
    return self
end

-- Open a right-click menu; returns the button labels and a click function.
function Client:openMenu(tag, contextData, owner)
    local buttons = {}
    local root = {
        CreateDivider = function() end,
        CreateTitle = function() end,
        CreateButton = function(_, text, fn) table.insert(buttons, { text = text, fn = fn }) end,
        CreateCheckbox = function(_, text, isSelected, setSelected)
            table.insert(buttons, { text = text, checked = isSelected, fn = setSelected })
        end,
    }
    for _, fn in ipairs(self.menus[tag] or {}) do fn(owner, root, contextData) end
    return buttons
end

function Client:system(msg)
    for _, fn in ipairs(self.filters["CHAT_MSG_SYSTEM"] or {}) do
        if fn(nil, "CHAT_MSG_SYSTEM", msg) then return end
    end
    table.insert(self.log, "SYSTEM: " .. msg)
end

-- Make `other` a character on the same WoW account (they share SavedVariables).
function Client:sameAccountAs(other)
    self.accountOf = other
    other.accountOf = other
end

function Client:logout()
    self:fire("PLAYER_LOGOUT")
    self.saved = deepcopy(self.env.FellowshipDB)
    if self.accountOf then self.accountOf.saved = self.saved end
    self.online = false
    self.session = self.session + 1 -- kills pending timers
end

function Client:slash(line)
    local cmd, rest = line:match("^(%S+)%s*(.-)$")
    local list = self.env.SlashCmdList
    for key, fn in pairs(list) do
        for i = 1, 5 do
            if self.env["SLASH_" .. key .. i] == cmd then return fn(rest) end
        end
    end
    error("unknown slash " .. cmd)
end

function Client:acceptPopup(which)
    for i, p in ipairs(self.popups) do
        if p.which == which then
            table.remove(self.popups, i)
            self.env.StaticPopupDialogs[which].OnAccept(nil, p.data)
            return true
        end
    end
    return false
end

-- Signature of the visible history: one line per event, oldest first.
function Client:history()
    local Store = self.ns.Store
    local fid = Store:ActiveId()
    local out = {}
    if not fid then return out end
    for _, e in ipairs(Store:Sorted(fid)) do
        out[#out + 1] = e.a .. "#" .. e.s .. " " .. e.k .. " " .. table.concat(e.d, ",")
    end
    return out
end

function Client:logContains(pattern)
    for _, l in ipairs(self.log) do
        if l:find(pattern, 1, true) then return true end
    end
    return false
end

return World
