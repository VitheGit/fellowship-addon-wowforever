-- Run from the repo root:  lua5.1 tests/test_sync.lua
package.path = (arg[0]:match("^(.*)/tests/") or ".") .. "/tests/?.lua;" .. package.path
local World = require("wowmock")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        print("ok   " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. "\n     " .. tostring(err))
    end
end

local function eq(a, b, msg)
    if a ~= b then error((msg or "values differ") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local function sameHistory(a, b)
    local ha, hb = a:history(), b:history()
    if #ha ~= #hb then
        error(string.format("%s has %d events, %s has %d\n  %s\n  vs\n  %s", a.name, #ha, b.name, #hb,
            table.concat(ha, "\n  "), table.concat(hb, "\n  ")), 2)
    end
    for i = 1, #ha do
        if ha[i] ~= hb[i] then error("history differs at " .. i .. ": " .. ha[i] .. " vs " .. hb[i], 2) end
    end
end

local function count(client, kind)
    local n = 0
    for _, line in ipairs(client:history()) do
        if line:match("^%S+ " .. kind .. " ") then n = n + 1 end
    end
    return n
end

-- Three friends: Anna founds, invites Bob and Cara.
local function setup(before)
    local w = World.new()
    local anna, bob, cara = w:client("Anna"), w:client("Bob"), w:client("Cara", "Area52")
    if before then before(anna, bob, cara) end
    anna:login(); bob:login(); cara:login()
    w:advance(1)
    anna:slash("/fship create Friday Night Crew")
    anna:slash("/fship invite bob silvermoon")
    w:advance(1)
    assert(bob:acceptPopup("FELLOWSHIP_INVITE"), "bob got no invite popup")
    w:advance(5)
    anna:slash("/fship invite cara-Area52")
    w:advance(1)
    assert(cara:acceptPopup("FELLOWSHIP_INVITE"), "cara got no invite popup")
    w:advance(30)
    return w, anna, bob, cara
end

test("invite flow: everyone ends up a member with the same history", function()
    local w, anna, bob, cara = setup()
    for _, c in ipairs({ anna, bob, cara }) do
        local roster = c.ns.Store:Roster(c.ns.Store:ActiveId())
        assert(roster["anna-silvermoon"] and roster["bob-silvermoon"] and roster["cara-area52"],
            c.name .. " roster incomplete")
        assert(not c.ns.Store:Active().pendingFrom, c.name .. " still pending")
    end
    sameHistory(anna, bob)
    sameHistory(anna, cara)
end)

test("solo founder sees their own /fsay and a hint", function()
    local w = World.new()
    local solo = w:client("Solo"); solo:login(); w:advance(1)
    solo:slash("/fship create Just Me")
    solo:slash("/fsay Hi!")
    w:advance(1)
    assert(solo:logContains("Solo Silvermoon|r: |cff4fd1b5Hi!|r"), "own message not echoed in chat color")
    solo:slash("/fship color #FF00AA")
    assert(solo.ns.FormatEvent({ a = "Solo-Silvermoon", k = "C", d = { "x" } }):find("|cffff00aax|r", 1, true), "custom color")
    solo:slash("/fship color reset")
    assert(solo:logContains("only member"), "no solo hint")
    eq(count(solo, "C"), 1)
end)

test("names use class colors, learned for members who are offline", function()
    local w = World.new()
    local anna, bob, cara = w:client("Anna"), w:client("Bob"), w:client("Cara", "Area52")
    anna.class, bob.class, cara.class = "HUNTER", "MAGE", "DRUID"
    anna:login(); bob:login(); w:advance(1)
    anna:slash("/fship create Crew"); anna:slash("/fship invite bob silvermoon"); w:advance(1)
    bob:acceptPopup("FELLOWSHIP_INVITE"); w:advance(10)
    cara:login(); w:advance(1)
    anna:slash("/fship invite cara-Area52"); w:advance(1)
    cara:acceptPopup("FELLOWSHIP_INVITE"); w:advance(30)
    bob:slash("/fsay hi from bob")
    anna:slash("/fsay hi from anna")
    w:advance(2)
    bob:logout(); w:advance(5)
    -- a fourth friend joins after Bob logged off and still sees Bob in mage blue
    local dan = w:client("Dan"); dan.class = "WARRIOR"; dan:login(); w:advance(1)
    anna:slash("/fship invite dan silvermoon"); w:advance(1)
    dan:acceptPopup("FELLOWSHIP_INVITE"); w:advance(60)
    eq(dan.ns.Store:GetClass("Bob-Silvermoon"), "MAGE")
    eq(anna.ns.Store:GetClass("Dan-Silvermoon"), "WARRIOR")
    assert(anna:logContains("|cffaad372Anna Silvermoon|r: |cff4fd1b5hi from anna"), "anna's own line not hunter green")
    assert(dan.ns.FormatEvent({ a = "Bob-Silvermoon", k = "C", d = { "x" } }):find("|cff3fc7ebBob Silvermoon|r", 1, true), "bob not mage blue")
end)

test("/fs <message> chats, /fs alone opens the window, /fship runs commands", function()
    local w = World.new()
    local solo = w:client("Solo"); solo:login(); w:advance(1)
    solo:slash("/fship create Just Me")
    solo:slash("/fs quick one")
    eq(count(solo, "C"), 1)
    solo:slash("/fs")
    assert(solo.ns.UI:IsShown(), "window not open")
    solo:slash("/fship window")
    assert(not solo.ns.UI:IsShown(), "window not toggled closed")
    solo:slash("/fship help")
    assert(solo:logContains("/fs <message>"), "help missing chat line")
end)

test("right-click 'Invite to Fellowship' on a portrait and in chat", function()
    local w = World.new()
    local anna, bob, cara = w:client("Anna"), w:client("Bob"), w:client("Cara", "Area52")
    anna.units = {
        target = { name = "Bob", realm = "Silvermoon", player = true, faction = "Alliance" }, -- WoW Forever: (first, last)
        focus = { name = "Gnoll", player = false },
        party1 = { name = "Horde", realm = "Area52", player = true, faction = "Horde" },
    }
    anna:login(); bob:login(); cara:login(); w:advance(1)
    -- not in a fellowship yet: no option
    eq(#anna:openMenu("MENU_UNIT_TARGET", { unit = "target" }), 0)
    anna:slash("/fship create Crew")
    local b = anna:openMenu("MENU_UNIT_TARGET", { unit = "target" })
    eq(#b, 1); eq(b[1].text, "Invite to Fellowship")
    eq(#anna:openMenu("MENU_UNIT_FOCUS", { unit = "focus" }), 0, "NPCs get no option")
    eq(#anna:openMenu("MENU_UNIT_PARTY", { unit = "party1" }), 0, "other faction gets no option")
    b[1].fn(); w:advance(1)
    assert(bob:acceptPopup("FELLOWSHIP_INVITE")); w:advance(10)
    eq(#anna:openMenu("MENU_UNIT_TARGET", { unit = "target" }), 0, "already a member")
    -- name clicked in chat: "First Last" plus a realm
    b = anna:openMenu("MENU_UNIT_FRIEND", { name = "Cara Area52", server = "CAMWOWUS1Realm3PvE" })
    eq(#b, 1); b[1].fn(); w:advance(1)
    assert(cara:acceptPopup("FELLOWSHIP_INVITE")); w:advance(30)
    assert(anna.ns.Store:IsMember(anna.ns.Store:ActiveId(), "Cara-Area52"))
end)

test("Fellowship can be moved to another chat tab", function()
    local w, anna, bob = setup()
    local function in2(c, text) for _, l in ipairs(c.log2) do if l:find(text, 1, true) then return true end end end
    -- type "/fship tab" while in tab 2: adds tab 2
    bob.env.SELECTED_CHAT_FRAME = bob.env.ChatFrame2
    bob:slash("/fship tab")
    -- right-click tab 1 and untick "Show Fellowship"
    local b = bob:openMenu("MENU_FCF_TAB", nil, bob.env.ChatFrame1)
    eq(b[1].text, "Show Fellowship"); eq(b[1].checked(), true)
    b[1].fn()
    eq(b[1].checked(), false)
    local before = #bob.log
    anna:slash("/fs only in tab two")
    w:advance(2)
    assert(in2(bob, "only in tab two"), "not in tab 2")
    for i = before + 1, #bob.log do assert(not bob.log[i]:find("only in tab two", 1, true), "still in tab 1") end
    -- with no tabs selected, chat is silent but command replies still show in the main window
    bob:slash("/fship tab 2")
    bob:slash("/fship who")
    assert(bob:logContains("Anna Silvermoon|r  |cffffd100Admin"), "who output lost")
    bob:slash("/fship tab reset")
    eq(bob.ns.ChatFrameSet()[1], true)
end)

local function canInvite(c) return c.ns.Store:CanInvite(c.ns.Store:ActiveId(), c.ns.me) end
local function role(c, name) return c.ns.Store:Role(c.ns.Store:ActiveId(), name) end
local function admin(c) local _, a = c.ns.Store:Roster(c.ns.Store:ActiveId()); return a end

test("roles: invitees are Members; Admin can promote and demote Inviters", function()
    local w, anna, bob, cara = setup()
    eq(role(anna, "Anna-Silvermoon"), "admin")
    eq(role(anna, "Bob-Silvermoon"), "member")
    assert(not canInvite(bob), "member should not invite")
    local dan = w:client("Dan"); dan:login(); w:advance(1)
    bob:slash("/fship invite dan silvermoon"); w:advance(2)
    eq(#dan.popups, 0, "member's invite went out")
    assert(bob:logContains("Only the Admin"), "no explanation")
    bob:slash("/fship promote cara-Area52")
    w:advance(2)
    eq(role(cara, "Cara-Area52"), "member", "non-admin promoted someone")
    anna:slash("/fship promote bob silvermoon")
    w:advance(2)
    eq(role(cara, "Bob-Silvermoon"), "inviter", "cara sees bob as inviter")
    assert(canInvite(bob))
    bob:slash("/fship invite dan silvermoon"); w:advance(1)
    assert(dan:acceptPopup("FELLOWSHIP_INVITE"), "inviter's invite failed"); w:advance(30)
    eq(role(anna, "Dan-Silvermoon"), "member")
    anna:slash("/fship demote bob silvermoon"); w:advance(2)
    assert(not canInvite(bob), "demoted bob still invites")
    sameHistory(anna, dan)
end)

test("roles: passing Admin needs the new Admin to accept, even after logging in later", function()
    local w, anna, bob, cara = setup()
    bob:slash("/fship admin cara-Area52"); w:advance(2)
    eq(#cara.popups, 0, "non-admin made an offer")
    anna:slash("/fship admin cara-Area52"); w:advance(2)
    eq(cara.popups[1] and cara.popups[1].which, "FELLOWSHIP_ADMIN_OFFER", "no admin popup")
    -- Cara says No
    local p = table.remove(cara.popups, 1)
    cara.env.StaticPopupDialogs.FELLOWSHIP_ADMIN_OFFER.OnCancel(nil, p.data, "clicked")
    w:advance(2)
    eq(admin(anna), "Anna-Silvermoon")
    assert(anna:logContains("declined the Admin offer"))
    -- offer again while Cara is offline; she answers when she logs back in
    cara:logout(); w:advance(5)
    anna:slash("/fship admin cara-Area52"); w:advance(5)
    anna:slash("/fship leave")
    assert(anna:logContains("Pass Admin to someone first"), "admin allowed to leave")
    cara:login(); w:advance(60)
    assert(cara:acceptPopup("FELLOWSHIP_ADMIN_OFFER"), "no popup after login")
    w:advance(5)
    for _, c in ipairs({ anna, bob, cara }) do
        eq(admin(c), "Cara-Area52", c.name .. " admin")
        eq(role(c, "Anna-Silvermoon"), "inviter", c.name .. " old admin role")
    end
    anna:slash("/fship remove bob silvermoon"); w:advance(2)
    assert(bob.ns.Store:ActiveId(), "old admin could still remove")
    anna:slash("/fship leave"); w:advance(2)
    eq(anna.ns.Store:ActiveId(), nil, "anna could not leave after passing admin")
end)

test("roles: Admin leaving with nobody else, and fellowships from before roles", function()
    local w, anna, bob, cara = setup()
    -- turn this into a pre-roles fellowship by stripping the V event from everyone's saved data
    for _, c in ipairs({ anna, bob, cara }) do c:logout() end
    for _, c in ipairs({ anna, bob, cara }) do
        for _, f in pairs(c.saved.fellowships) do
            for _, evs in pairs(f.events) do
                for s, e in pairs(evs) do if e.k == "V" then e.k = "C"; e.d = { "(was V)" } end end
            end
        end
    end
    bob:login(); w:advance(1)
    assert(canInvite(bob), "legacy: every member could invite")
    anna:login(); w:advance(40) -- anna's client switches roles on
    assert(not canInvite(bob), "roles not switched on")
    eq(admin(bob), "Anna-Silvermoon")
end)

test("members show Online/Offline, and logouts are noticed within a minute", function()
    local w, anna, bob, cara = setup()
    local list, n = anna.ns.Sync:MemberList(anna.ns.Store:ActiveId())
    eq(n, 3, "all online")
    cara:logout()
    w:advance(70) -- one ping cycle, no chatting needed
    list, n = anna.ns.Sync:MemberList(anna.ns.Store:ActiveId())
    eq(n, 2, "cara still online")
    eq(list[#list].name, "Cara-Area52", "offline members sorted last")
    assert(list[#list].status:find("[Offline]", 1, true) and list[#list].status:find("last seen"), list[#list].status)
    anna:slash("/fship who")
    assert(anna:logContains("2 of 3 online"))
    assert(anna:logContains("[Online]|r |cff808080(you)"))
    cara:login(); w:advance(10)
    local _, n2 = anna.ns.Sync:MemberList(anna.ns.Store:ActiveId())
    eq(n2, 3, "cara back online")
    assert(not anna:logContains("SYSTEM: No player named"), "ping bounce leaked into chat")
end)

local function lastLine(c) local h = c:history(); return h[#h] end
local function showsInChat(c, text) return c:logContains(text) end

test("announcements: mounts, pets, toys, loot, dungeons, raids and deaths", function()
    local w, anna, bob = setup()
    local A = anna.ns.Announce
    anna:fire("NEW_MOUNT_ADDED", 7); w:advance(2)
    assert(showsInChat(bob, "learned a new mount: |cff71d5ff|Hspell:1007"), "mount")
    anna:fire("NEW_PET_ADDED", "BattlePet-1"); w:advance(2)
    assert(showsInChat(bob, "added a new pet: [Mechanical Squirrel]"), "pet")
    anna:fire("NEW_TOY_ADDED", 1234); w:advance(2)
    assert(showsInChat(bob, "added a new toy: [Toy 1234]"), "toy")
    -- loot: blue is shared, bob's default only shows Epic+
    anna:fire("CHAT_MSG_LOOT", "You receive loot: |cff0070dd|Hitem:100:3::|h[Blue Sword]|h|r.")
    anna:fire("CHAT_MSG_LOOT", "You receive loot: |cffa335ee|Hitem:200:4::|h[Purple Staff]|h|rx2.")
    anna:fire("CHAT_MSG_LOOT", "You receive loot: |cff1eff00|Hitem:300:2::|h[Green Junk]|h|r.")
    anna:fire("CHAT_MSG_LOOT", "Bob receives loot: |cffa335ee|Hitem:400:4::|h[Not Yours]|h|r.")
    w:advance(3)
    eq(count(bob, "M"), 5, "mount, pet, toy + 2 loot stored")
    assert(not showsInChat(bob, "Blue Sword"), "rare shown below bob's minimum")
    assert(showsInChat(bob, "looted |cffa335ee|Hitem:200:4::|h[Purple Staff]|h|r"), "epic not shown")
    bob.ns.settings.lootMinQuality = 3
    local blue = bob.ns.Store:Sorted(bob.ns.Store:ActiveId())
    local found = false
    for _, e in ipairs(blue) do if e.d[3] == "Blue Sword" then found = bob.ns.Announce.ShouldShow(e) end end
    assert(found, "rare not shown after lowering minimum")
    -- dungeon: only the final boss counts, once
    anna.instance = { name = "Deadmines", type = "party", difficulty = "Heroic", id = 36, bosses = { 11, 12, 13 } }
    anna:fire("ENCOUNTER_END", 11, "Boss 1", 2, 5, 1); w:advance(1)
    anna:fire("ENCOUNTER_END", 13, "Boss 3", 2, 5, 0); w:advance(1) -- wipe
    eq(count(bob, "M"), 5, "posted before the final boss died")
    anna:fire("ENCOUNTER_END", 13, "Boss 3", 2, 5, 1)
    anna:fire("ENCOUNTER_END", 13, "Boss 3", 2, 5, 1); w:advance(2)
    assert(showsInChat(bob, "completed Deadmines (Heroic)"), "dungeon completion")
    eq(count(bob, "M"), 6, "dungeon posted twice")
    anna:fire("CHALLENGE_MODE_COMPLETED"); w:advance(2)
    assert(showsInChat(bob, "at +15, in time!"), "keystone")
    anna.instance = { name = "Molten Core", type = "raid", difficulty = "Mythic", id = 409, bosses = { 21, 22 } }
    anna:fire("ZONE_CHANGED_NEW_AREA")
    anna:fire("ENCOUNTER_END", 22, "Ragnaros", 16, 20, 1); w:advance(2)
    assert(showsInChat(bob, "cleared Molten Core (Mythic)"), "raid")
    -- death in red, with killer
    anna.instance = nil
    anna:fire("PLAYER_DEAD"); w:advance(4)
    assert(showsInChat(bob, "|cffff4040 was killed in Elwynn Forest|r"), "death")
end)

test("announcements: share and show settings", function()
    local w, anna, bob = setup()
    anna.ns.settings.shareDeaths = false
    anna:fire("PLAYER_DEAD"); w:advance(4)
    eq(count(bob, "M"), 0, "death shared while sharing off")
    bob.ns.settings.showLevels = false
    anna.ns.Achievements:OnLevelUp(61); w:advance(2)
    eq(count(bob, "M"), 1, "level stored")
    assert(not showsInChat(bob, "reached level 61"), "hidden level still echoed")
    -- the settings window drives the same switches
    bob:slash("/fship settings")
    local cb = bob.ns.UI.settingsChecks.showLevels
    eq(cb:GetChecked(), false)
    cb:SetChecked(true); cb:Click()
    eq(bob.ns.settings.showLevels, true)
    anna.ns.Achievements:OnLevelUp(62); w:advance(2)
    assert(showsInChat(bob, "reached level 62"), "level not shown after re-enabling")
    anna.ns.Achievements:OnEarned(5, false); w:advance(2)
    assert(showsInChat(bob, "earned"), "achievement")
end)

test("online/offline notices and zone/level in the member list", function()
    local w, anna, bob, cara = setup()
    w:advance(30)
    cara.zone = "Stormwind City"; cara.level = 42
    cara:fire("ZONE_CHANGED_NEW_AREA"); w:advance(5)
    local list = anna.ns.Sync:MemberList(anna.ns.Store:ActiveId())
    local where
    for _, m in ipairs(list) do if m.name == "Cara-Area52" then where = m.where end end
    eq(where, "Level 42, Stormwind City")
    cara:logout(); w:advance(70)
    assert(anna:logContains("Cara Area52|r |cff9d9d9dwent offline."), "no offline notice")
    cara:login(); w:advance(10)
    assert(anna:logContains("Cara Area52|r |cff33ff99came online."), "no online notice")
    assert(not cara:logContains("came online"), "login spam for the person logging in")
    bob.ns.settings.shareLocation = false
    bob.ns.Sync:PingOnline(); w:advance(2)
    for _, m in ipairs(anna.ns.Sync:MemberList(anna.ns.Store:ActiveId())) do
        if m.name == "Bob-Silvermoon" then eq(m.where, nil, "bob's location still shown") end
    end
end)

test("no protected events are registered (avoids 'blocked from an action' popups)", function()
    local w = World.new()
    local c = w:client("Solo"); c:login()
    for _, f in ipairs(c.frames) do
        for ev in pairs(f._events) do
            assert(ev ~= "COMBAT_LOG_EVENT_UNFILTERED", "registers the combat log")
        end
    end
end)

local function memberPanel(c)
    for _, f in ipairs(c.frames) do if rawget(f, "rows") and rawget(f, "showOffline") then return f end end
end
local function rosterRows(p)
    local out = {}
    for _, r in ipairs(p.rows) do
        if r:IsShown() then
            local t = {}
            for k, fs in pairs(r.cells) do t[k] = fs:GetText() end
            out[#out + 1] = t
        end
    end
    return out
end

test("Members tab is a guild-style roster and the title count matches", function()
    local w, anna, bob, cara = setup()
    anna:slash("/fs")
    anna.ns.UI:SelectTab("members")
    local p = memberPanel(anna)
    assert(p, "members panel not found")
    eq(p.count:GetText(), "3 of 3 members online")
    local rows = rosterRows(p)
    eq(#rows, 3)
    local seen = {}
    for _, r in ipairs(rows) do
        for _, n in ipairs({ "Anna Silvermoon", "Bob Silvermoon", "Cara Area52" }) do
            if r.name:find(n .. "|r", 1, true) then seen[n] = r end
        end
    end
    for _, n in ipairs({ "Anna Silvermoon", "Bob Silvermoon", "Cara Area52" }) do assert(seen[n], n .. " missing") end
    assert(seen["Anna Silvermoon"].name:find("(you)", 1, true), "you not marked")
    assert(seen["Anna Silvermoon"].rank:find("Admin", 1, true), "admin rank missing")
    eq(seen["Bob Silvermoon"].seen, "|cff33ff99Online|r")
    local title
    for _, f in ipairs(anna.frames) do
        local t = rawget(f, "subtitle")
        if type(t) == "table" and type(t._text) == "string" and t._text:find("online") then title = t._text end
    end
    assert(title and title:find("3 of 3 online", 1, true), tostring(title))

    -- offline members are grey with last-online time; the checkbox hides them
    cara:logout(); w:advance(70)
    anna.ns.UI:Refresh()
    rows = rosterRows(p)
    eq(#rows, 3)
    local last = rows[3]
    eq(last.name, "|cff6e6e6eCara Area52|r")
    eq(last.zone, "|cff808080Offline|r")
    assert(last.seen:find("ago", 1, true), last.seen)
    p.showOffline:SetChecked(false); p.showOffline:Click()
    eq(#rosterRows(p), 2)
    eq(p.count:GetText(), "2 of 3 members online")
    p.showOffline:SetChecked(true); p.showOffline:Click()

    -- sorting by a column header (Name, reversed on a second click)
    p.cols[1]:Click()
    rows = rosterRows(p)
    assert(rows[1].name:find("Anna", 1, true) and rows[3].name:find("Cara", 1, true), "not sorted by name")
    p.cols[1]:Click()
    assert(rosterRows(p)[1].name:find("Cara", 1, true), "not reversed")

    -- hovering and right-clicking a row
    local bobRow
    for _, r in ipairs(p.rows) do local m = rawget(r, "member"); if m and m.main == "Bob-Silvermoon" then bobRow = r end end
    bobRow._scripts.OnEnter(bobRow)
    local labels = {}
    for _, item in ipairs(anna.ns.UI:MemberMenuItems(bobRow.member)) do labels[#labels + 1] = item[1] end
    eq(table.concat(labels, ","), "Whisper,Invite to Group,Make Inviter,Pass Admin,Remove from Fellowship")
    eq(#bob.ns.UI:MemberMenuItems(bob.ns.Sync:MemberList(bob.ns.Store:ActiveId())[1]), 2, "non-admin sees only whisper/invite")
    for _, item in ipairs(anna.ns.UI:MemberMenuItems(bobRow.member)) do
        if item[1] == "Make Inviter" then item[2]() end
    end
    w:advance(3)
    eq(bob.ns.Store:Role(bob.ns.Store:ActiveId(), "Bob-Silvermoon"), "inviter")
end)

test("minimap button: left-click opens the window, right-click menu has Settings", function()
    local w = World.new()
    local c = w:client("Solo"); c:login(); w:advance(1)
    local b = c.ns.MinimapButton.button
    assert(b and b:IsShown(), "button missing")
    b._scripts.OnEnter(b) -- tooltip shouldn't error
    b._scripts.OnClick(b, "LeftButton")
    assert(c.ns.UI:IsShown(), "window not opened")
    b._scripts.OnClick(b, "RightButton")
    eq(c.contextMenu[1].text, "Settings")
    c.contextMenu[1].fn()
    local settingsShown = false
    for _, f in ipairs(c.frames) do if rawget(f, "minimap") and f:IsShown() then settingsShown = true end end
    assert(settingsShown, "settings window not opened")
    c.contextMenu[2].fn()
    assert(not b:IsShown(), "hide from menu failed")
    c:slash("/fship minimap")
    assert(b:IsShown(), "slash did not bring it back")
    -- position survives a relog
    c.ns.settings.minimapAngle = 45
    c:logout(); c:login()
    eq(c.ns.settings.minimapAngle, 45)
end)

local function accounts(c)
    local _, _, state = c.ns.Store:Roster(c.ns.Store:ActiveId())
    local n = 0
    for _ in pairs(state.accounts) do n = n + 1 end
    return n
end

test("accounts: an alt joins automatically and shares its main's role", function()
    local w, anna, bob, cara = setup()
    local bobalt = w:client("Bobalt"); bobalt:sameAccountAs(bob)
    anna:slash("/fship promote bob silvermoon"); w:advance(2)
    bob:logout(); w:advance(5)
    bobalt:login(); w:advance(30)
    assert(bobalt.ns.Store:ActiveId(), "alt did not auto-join")
    assert(bobalt:logContains("joined Friday Night Crew with the rest of your account"))
    for _, c in ipairs({ anna, cara, bobalt }) do
        assert(c.ns.Store:SameAccount(c.ns.Store:ActiveId(), "Bob-Silvermoon", "Bobalt-Silvermoon"), c.name .. " not linked")
        eq(accounts(c), 3, c.name .. " account count")
        eq(c.ns.Store:Role(c.ns.Store:ActiveId(), "Bobalt-Silvermoon"), "inviter", c.name .. " alt role")
    end
    bobalt:slash("/fs hi from my alt"); w:advance(2)
    assert(anna:logContains("Bobalt Silvermoon|r |cff808080(Bob Silvermoon)|r: "), "alt name not shown with main")
    local list, n = anna.ns.Sync:MemberList(anna.ns.Store:ActiveId())
    eq(#list, 3); eq(n, 3, "bob's account counts as online via the alt")
    sameHistory(anna, bobalt)
end)

test("accounts: leaving on an alt takes the whole account out", function()
    local w, anna, bob, cara = setup()
    local bobalt = w:client("Bobalt"); bobalt:sameAccountAs(bob)
    bob:logout(); bobalt:login(); w:advance(30)
    bobalt:slash("/fship leave"); w:advance(3)
    for _, c in ipairs({ anna, cara }) do
        assert(not c.ns.Store:IsMember(c.ns.Store:ActiveId(), "Bob-Silvermoon"), "main still a member")
        assert(not c.ns.Store:IsMember(c.ns.Store:ActiveId(), "Bobalt-Silvermoon"), "alt still a member")
    end
    bobalt:logout(); bob:login(); w:advance(30)
    eq(bob.ns.Store:ActiveId(), nil, "main still thinks it's in")
end)

test("accounts: separately invited characters merge; wrong codes are rejected", function()
    local w, anna, bob, cara = setup()
    local dan, danalt = w:client("Dan"), w:client("Danalt")
    dan:login(); w:advance(1)
    -- Danalt is on Dan's account but (like an older version) was invited on its own
    danalt.saved = { account = { id = dan.env.FellowshipDB.account.id, secret = dan.env.FellowshipDB.account.secret } }
    anna:slash("/fship invite dan silvermoon"); w:advance(1); dan:acceptPopup("FELLOWSHIP_INVITE"); w:advance(30)
    dan:logout(); danalt:login(); w:advance(1)
    anna:slash("/fship invite danalt silvermoon"); w:advance(1); danalt:acceptPopup("FELLOWSHIP_INVITE"); w:advance(60)
    assert(anna.ns.Store:SameAccount(anna.ns.Store:ActiveId(), "Dan-Silvermoon", "Danalt-Silvermoon"), "not merged")
    eq(accounts(anna), 4)
    -- an outsider who knows the account id but not the secret can't link in
    local eve = w:client("Eve"); eve:login(); w:advance(1)
    local fid = anna.ns.Store:ActiveId()
    local S = eve.ns.Serializer
    eve.env.C_ChatInfo.SendAddonMessage("Fellowship", "1:1:1:" .. S.Encode({ { "LNK", fid, "1" },
        { "Eve-Silvermoon", 1, 0, "Y", dan.saved.account.id, "wrongsecret" } }), "WHISPER", "Anna")
    w:advance(2)
    assert(not anna.ns.Store:IsMember(fid, "Eve-Silvermoon"), "eve linked in with a wrong secret")
end)

test("accounts: Admin offer can be accepted on an alt", function()
    local w, anna, bob, cara = setup()
    local bobalt = w:client("Bobalt"); bobalt:sameAccountAs(bob)
    bob:logout(); w:advance(2)
    anna:slash("/fship admin bob silvermoon"); w:advance(2)
    bobalt:login(); w:advance(40)
    assert(bobalt:acceptPopup("FELLOWSHIP_ADMIN_OFFER"), "alt didn't get the admin offer")
    w:advance(5)
    for _, c in ipairs({ anna, cara, bobalt }) do
        local fid = c.ns.Store:ActiveId()
        assert(c.ns.Store:IsAdmin(fid, "Bob-Silvermoon") and c.ns.Store:IsAdmin(fid, "Bobalt-Silvermoon"), c.name)
        eq(c.ns.Store:Role(fid, "Anna-Silvermoon"), "inviter")
    end
end)

test("a member removed while offline finds out when they log back in", function()
    local w, anna, bob, cara = setup()
    -- make it harder: Admin changes hands while Cara is away, then the new Admin removes her
    cara:logout(); w:advance(5)
    anna:slash("/fship admin bob silvermoon"); w:advance(2)
    assert(bob:acceptPopup("FELLOWSHIP_ADMIN_OFFER")); w:advance(2)
    bob:slash("/fship remove cara-Area52"); w:advance(2)
    anna:slash("/fs secret plans"); w:advance(2)
    cara:login(); w:advance(30)
    eq(cara.ns.Store:ActiveId(), nil, "cara still thinks she's a member")
    assert(cara:logContains("no longer a member"), "cara wasn't told")
    for _, line in ipairs(cara:history()) do assert(not line:find("secret plans"), "removed member got new chat") end
end)

test("chat window sidebar: online in class color, offline greyed", function()
    local w, anna, bob, cara = setup()
    bob.class = "MAGE"
    cara:logout(); w:advance(70)
    anna:slash("/fs")
    local text, header
    for _, f in ipairs(anna.frames) do
        local m = rawget(f, "members")
        if type(m) == "table" then text = m._text; header = rawget(f, "membersHeader")._text end
    end
    assert(text, "no sidebar")
    eq(header, "Members  |cff8080802/3|r")
    assert(text:find("|cffaad372Anna Silvermoon|r |cffffd100*|r", 1, true), "admin anna not marked/colored: " .. text)
    assert(text:find("|cff6e6e6eCara Area52|r", 1, true), "offline cara not grey: " .. text)
    local annaPos, caraPos = text:find("Anna", 1, true), text:find("Cara", 1, true)
    assert(annaPos < caraPos, "online not listed first")
end)

test("live chat reaches online members and is echoed to their chat frame", function()
    local w, anna, bob, cara = setup()
    bob:slash("/fsay hey all, dungeon tonight?")
    w:advance(2)
    assert(anna:logContains("hey all, dungeon tonight?"), "anna did not see bob's message")
    assert(cara:logContains("hey all, dungeon tonight?"), "cara did not see bob's message")
    sameHistory(anna, cara)
end)

test("offline member catches up on chat and achievements after logging back in", function()
    local w, anna, bob, cara = setup()
    cara:logout()
    w:advance(10)
    anna:slash("/fsay cara is missing out")
    bob:slash("/fsay for real")
    bob.ns.Achievements:OnEarned(42, false)
    bob.ns.Achievements:OnLevelUp(60)
    -- Anna and Bob notice Cara is gone (whisper bounces are hidden from their chat)
    w:advance(400)
    assert(not anna:logContains("SYSTEM: No player named"), "offline error leaked into chat")
    eq(anna.ns.online["cara-area52"], false, "anna should see cara offline")
    cara:login()
    w:advance(60)
    sameHistory(anna, cara)
    eq(count(cara, "A"), 1, "cara achievements")
    eq(count(cara, "C"), 2, "cara chats")
    w:advance(20)
    assert(cara:logContains("While you were away: 2 messages and 2 achievements"), "no catch-up summary")
end)

test("history relays through whoever is online (author offline)", function()
    local w, anna, bob, cara = setup()
    cara:logout()
    w:advance(5)
    bob:slash("/fsay only anna will be here to tell cara")
    w:advance(2)
    bob:logout()
    w:advance(30)
    cara:login()
    w:advance(60)
    sameHistory(anna, cara)
    eq(count(cara, "C"), 1)
end)

test("history persists across logout/login (SavedVariables)", function()
    local w, anna, bob, cara = setup()
    anna:slash("/fsay remember me")
    w:advance(2)
    local before = anna:history()
    anna:logout(); bob:logout(); cara:logout()
    w:advance(100)
    anna:login()
    w:advance(10)
    eq(#anna:history(), #before, "anna lost history")
    eq(anna.ns.Store:Active().name, "Friday Night Crew")
end)

test("two members offline at different times converge", function()
    local w, anna, bob, cara = setup()
    bob:logout()
    w:advance(5)
    anna:slash("/fsay msg while bob away")
    w:advance(2)
    cara:logout()
    w:advance(5)
    anna:slash("/fsay msg while both away")
    anna:logout()
    w:advance(5)
    bob:login() -- nobody online
    w:advance(30)
    bob:slash("/fsay bob alone")
    w:advance(5)
    cara:login() -- bob online: cara gets bob's message, bob gets nothing new from cara
    w:advance(60)
    anna:login()
    w:advance(120)
    sameHistory(anna, bob)
    sameHistory(anna, cara)
    eq(count(anna, "C"), 3)
end)

test("long UTF-8 messages are chunked and reassembled intact", function()
    local w, anna, bob = setup()
    local text = string.rep("héllo wörld ✓ ", 18) -- > 255 bytes, multi-byte chars
    text = text:sub(1, 250)
    -- trim a possibly split trailing character
    while text:byte(#text) >= 0x80 do text = text:sub(1, -2) end
    text = text .. "!"
    anna.ns.Sync:PostChat(text)
    w:advance(5)
    local h = bob:history()
    assert(h[#h]:find(text, 1, true), "bob's copy differs")
end)

test("large backfill respects throttling and completes", function()
    local w, anna, bob, cara = setup()
    cara:logout()
    for i = 1, 150 do anna:slash("/fsay backlog message number " .. i) end
    w:advance(400)
    cara:login()
    w:advance(600)
    sameHistory(anna, cara)
    eq(count(cara, "C"), 150)
end)

test("over-long chat is cut at a character boundary", function()
    local w, anna, bob = setup()
    anna.ns.Sync:PostChat(string.rep("a", 254) .. "✓✓")
    w:advance(5)
    local h = bob:history()
    local text = h[#h]:match(" C (.*)$")
    eq(#text, 254, "length")
end)

test("separator bytes and escape codes in chat are neutralised", function()
    local w, anna, bob = setup()
    anna:slash("/fsay evil\30EV\31text |cffff0000red|r")
    w:advance(3)
    local h = bob:history()
    assert(h[#h]:find("evilEVtext |cffff0000red|r", 1, true), "unexpected: " .. h[#h])
    local formatted = bob.ns.FormatEvent(bob.ns.Store:Sorted(bob.ns.Store:ActiveId())[#h])
    assert(formatted:find("||cffff0000", 1, true), "pipe not escaped in display")
end)

test("non-members cannot inject events", function()
    local w, anna, bob = setup()
    local eve = w:client("Eve"); eve:login()
    w:advance(1)
    local fid = anna.ns.Store:ActiveId()
    local S = eve.ns.Serializer
    eve.env.C_ChatInfo.SendAddonMessage("Fellowship",
        "1:1:1:" .. S.Encode({ { "EV", fid, "1", "1" }, { "Eve-Silvermoon", 1, 0, "C", "spam" } }), "WHISPER", "Anna")
    w:advance(2)
    for _, line in ipairs(anna:history()) do assert(not line:find("spam"), "eve injected an event") end
end)

test("founder can remove a member; removed member stops receiving", function()
    local w, anna, bob, cara = setup()
    anna:slash("/fship remove cara-Area52")
    w:advance(3)
    eq(cara.ns.Store:ActiveId(), nil, "cara should have left")
    assert(cara:logContains("no longer a member"), "cara not told")
    bob:slash("/fsay after removal")
    w:advance(3)
    assert(not anna.ns.Store:IsMember(anna.ns.Store:ActiveId(), "Cara-Area52"))
end)

test("leaving removes you from everyone's roster", function()
    local w, anna, bob, cara = setup()
    bob:slash("/fship leave")
    w:advance(3)
    eq(bob.ns.Store:ActiveId(), nil)
    assert(not anna.ns.Store:IsMember(anna.ns.Store:ActiveId(), "Bob-Silvermoon"))
    assert(not cara.ns.Store:IsMember(cara.ns.Store:ActiveId(), "Bob-Silvermoon"))
end)

test("pruning keeps membership and sync still converges", function()
    local w, anna, bob, cara = setup()
    cara:logout()
    for i = 1, 40 do anna:slash("/fsay old " .. i) end
    w:advance(60)
    anna.ns.settings.maxEvents = 10
    bob.ns.settings.maxEvents = 10
    eq(anna.ns.Store:Prune(anna.ns.Store:ActiveId()), 30)
    bob.ns.Store:Prune(bob.ns.Store:ActiveId())
    cara:login()
    cara.ns.settings.maxEvents = 10
    w:advance(120)
    eq(count(cara, "C"), 10, "cara should get only the retained messages")
    local roster = cara.ns.Store:Roster(cara.ns.Store:ActiveId())
    assert(roster["bob-silvermoon"] and roster["cara-area52"], "membership lost by pruning")
    -- no endless re-requests: hwm reached anna's
    local fid = anna.ns.Store:ActiveId()
    eq(cara.ns.Store:Get(fid).hwm["Anna-Silvermoon"], anna.ns.Store:Get(fid).hwm["Anna-Silvermoon"])
end)

test("invite still works if the inviter reloads before the friend accepts", function()
    local w = World.new()
    local anna, bob = w:client("Anna"), w:client("Bob")
    anna:login(); bob:login(); w:advance(1)
    anna:slash("/fship create Crew"); anna:slash("/fship invite bob silvermoon"); w:advance(1)
    anna:logout(); anna:login(); w:advance(5)
    assert(bob:acceptPopup("FELLOWSHIP_INVITE")); w:advance(30)
    assert(bob.ns.Store:Roster(bob.ns.Store:ActiveId())["bob-silvermoon"] or bob.ns.Store:Roster(bob.ns.Store:ActiveId())["Bob-Silvermoon"], "bob not in his own roster")
    assert(not bob.ns.Store:Get(bob.ns.Store:ActiveId()).pendingFrom, "bob still joining")
end)

test("a lost accept is retried and the join completes", function()
    local w = World.new()
    local anna, bob = w:client("Anna"), w:client("Bob")
    anna:login(); bob:login(); w:advance(1)
    anna:slash("/fship create Crew"); anna:slash("/fship invite bob silvermoon"); w:advance(1)
    local dropped = 0
    w.dropper = function(from, to, text)
        if from == "Bob Silvermoon" and dropped < 3 then dropped = dropped + 1; return true end
    end
    assert(bob:acceptPopup("FELLOWSHIP_INVITE")); w:advance(60)
    assert(dropped == 3, "nothing was dropped")
    local fid = bob.ns.Store:ActiveId()
    assert(not bob.ns.Store:Get(fid).pendingFrom, "bob still joining after retries")
    assert(#anna.ns.Sync:MemberList(fid) == 2, "anna does not see bob")
end)

test("invitee with a non-ASCII name can join", function()
    local w = World.new()
    local anna, ael = w:client("Anna"), w:client("Ælfred")
    anna:login(); ael:login(); w:advance(1)
    anna:slash("/fship create Crew"); anna:slash("/fship invite Ælfred Silvermoon"); w:advance(1)
    assert(ael:acceptPopup("FELLOWSHIP_INVITE")); w:advance(30)
    local fid = ael.ns.Store:ActiveId()
    assert(not ael.ns.Store:Get(fid).pendingFrom, "ælfred still joining")
    assert(#anna.ns.Sync:MemberList(fid) == 2, "anna does not see ælfred")
end)

test("WoW Forever names: every shape the game uses becomes First-Last", function()
    local w = World.new()
    local c = w:client("Vithe", "Valestrider"); c:login()
    local N = c.ns.NormalizeName
    eq(c.ns.me, "Vithe-Valestrider")
    for _, input in ipairs({ "Vithe Valestrider", "vithe valestrider", "Vithe-Valestrider", "VitheValestrider",
        "Vithe Valestrider-CAMWOWUS1Realm3PvE", "Vithe-Valestrider-CAMWOWUS1Realm5PvE", "  Vithe   Valestrider " }) do
        eq(N(input), "Vithe-Valestrider", input)
        eq(c.ns.Key(input), "vithe-valestrider", input)
    end
    eq(c.ns.Short("Vithe-Valestrider"), "Vithe Valestrider")
end)

for _, style in ipairs({ "space", "camel", "hyphen" }) do
    test("WoW Forever: invite by right-click and chat both ways (sender style: " .. style .. ")", function()
        local w = World.new()
        w.senderStyle = style
        local vithe, valtri = w:client("Vithe", "Valestrider"), w:client("Valtri", "Brinkforge")
        vithe.units = { party1 = { name = "Valtri", realm = "Brinkforge", player = true, faction = "Alliance" } }
        vithe:login(); valtri:login(); w:advance(1)
        vithe:slash("/fship create Loot Kills")
        local b = vithe:openMenu("MENU_UNIT_PARTY", { unit = "party1" })
        eq(#b, 1); b[1].fn(); w:advance(1)
        assert(valtri:acceptPopup("FELLOWSHIP_INVITE"), "no invite popup")
        w:advance(20)
        local fid = valtri.ns.Store:ActiveId()
        assert(not valtri.ns.Store:Get(fid).pendingFrom, "still joining")
        assert(vithe.ns.Store:IsMember(fid, "Valtri Brinkforge"), "vithe doesn't see valtri")
        valtri:slash("/fs hello from valtri"); vithe:slash("/fs hi valtri"); w:advance(3)
        assert(vithe:logContains("Valtri Brinkforge|r: |cff4fd1b5hello from valtri"), "vithe missed valtri's line")
        assert(valtri:logContains("Vithe Valestrider|r: |cff4fd1b5hi valtri"), "valtri missed vithe's line")
    end)
end

test("inviting by first name only explains what to type", function()
    local w = World.new()
    local a = w:client("Vithe", "Valestrider"); a:login(); w:advance(1)
    a:slash("/fship create Loot Kills"); a:slash("/fship invite valtri")
    assert(a:logContains("Use their full name"), "no hint")
end)

test("minimap button goes through LibDBIcon when it is loaded", function()
    -- a minimal stand-in for LibDataBroker-1.1 + LibDBIcon-1.0
    local objects, icon = {}, { registered = {}, buttons = {} }
    local ldb = {
        GetDataObjectByName = function(_, n) return objects[n] end,
        NewDataObject = function(_, n, o) objects[n] = o; return o end,
    }
    function icon:IsRegistered(n) return self.registered[n] ~= nil end
    function icon:Register(n, o, db) self.registered[n] = { obj = o, db = db }; self.buttons[n] = { shown = not db.hide } end
    function icon:GetMinimapButton(n) return self.buttons[n] end
    function icon:Show(n) self.buttons[n].shown = true end
    function icon:Hide(n) self.buttons[n].shown = false end
    local libs = { ["LibDataBroker-1.1"] = ldb, ["LibDBIcon-1.0"] = icon }
    local w = World.new()
    local c = w:client("Solo")
    c.globals = { LibStub = function(name) return libs[name] end }
    c:login(); w:advance(1)
    local reg = icon.registered.Fellowship
    assert(reg, "not registered with LibDBIcon")
    eq(reg.obj.label, "Fellowship")
    eq(reg.db.minimapPos, 210, "old position carried over")
    local lines = {}
    reg.obj.OnTooltipShow({ AddLine = function(_, l) lines[#lines + 1] = l end })
    eq(lines[1], "Fellowship")
    reg.obj.OnClick(nil, "LeftButton")
    assert(c.ns.UI:IsShown(), "left-click didn't open the window")
    reg.obj.OnClick(nil, "RightButton")
    eq(c.contextMenu[1].text, "Settings")
    c:slash("/fship minimap")
    eq(icon.buttons.Fellowship.shown, false); eq(reg.db.hide, true)
    c:slash("/fship minimap")
    eq(icon.buttons.Fellowship.shown, true)
end)

test("window shows a Create Fellowship screen when you're not in one", function()
    local w = World.new()
    local c = w:client("Vithe", "Valestrider"); c:login(); w:advance(1)
    c:slash("/fs") -- open the window
    local none
    for _, f in ipairs(c.frames) do if rawget(f, "heading") then none = f end end
    assert(none and none:IsShown(), "create screen not shown")
    eq(none.heading:GetText(), "Create Fellowship")
    eq(none.create:GetText(), "Create")
    none.input:SetText("Loot Kills")
    none.create:Click()
    local f = c.ns.Store:Active()
    assert(f, "not created"); eq(f.name, "Loot Kills")
    c.ns.UI:Refresh()
    assert(not none:IsShown(), "create screen still showing")
end)

test("the inviter hears back when an invitation is accepted, declined or ignored", function()
    local w = World.new()
    local anna, bob, cara, dan = w:client("Anna"), w:client("Bob"), w:client("Cara"), w:client("Dan")
    anna:login(); bob:login(); cara:login(); dan:login(); w:advance(1)
    anna:slash("/fship create Loot Kills")
    anna:slash("/fship invite bob silvermoon"); anna:slash("/fship invite cara silvermoon")
    anna:slash("/fship invite dan silvermoon"); w:advance(1)
    assert(bob:acceptPopup("FELLOWSHIP_INVITE"))
    assert(cara:declinePopup("FELLOWSHIP_INVITE", "clicked"))
    assert(dan:declinePopup("FELLOWSHIP_INVITE", "timeout"))
    w:advance(5)
    assert(anna:logContains("Bob Silvermoon|r accepted your invitation and joined Loot Kills!"), "no accept notice")
    assert(anna:logContains("Cara Silvermoon|r declined your invitation to Loot Kills."), "no decline notice")
    assert(anna:logContains("Dan Silvermoon|r didn't answer your invitation in time"), "no timeout notice")
    -- a retried accept doesn't repeat the notice
    local n = 0
    w:advance(60)
    for _, l in ipairs(anna.log) do if l:find("accepted your invitation", 1, true) then n = n + 1 end end
    eq(n, 1)
end)

test("item links in chat stay clickable; other escape codes are neutralised", function()
    local w, anna, bob = setup()
    local link = "|cffa335ee|Hitem:19019::::::::60:::::|h[Thunderfury, Blessed Blade of the Windseeker]|h|r"
    local newLink = "|cnIQ4:|Hitem:19019::::::::60:::::|h[Thunderfury]|h|r"
    anna:slash("/fs look " .. link .. " and " .. newLink .. "!")
    w:advance(3)
    local color = "|cff4fd1b5"
    assert(bob:logContains(color .. "look " .. link .. color .. " and " .. newLink .. color .. "!|r"), "link not kept")
    local N = bob.ns.SafeChat
    eq(N("|TInterface\\Icons\\x:0|t hi"), "||TInterface\\Icons\\x:0||t hi", "texture not escaped")
    eq(N("|cffff0000fake|r"), "||cffff0000fake||r", "bare color not escaped")
    eq(N("|Hurl:evil|h[click]|h"), "||Hurl:evil||h[click]||h", "unknown link type not escaped")
    eq(N("half " .. link:sub(1, 40)), "half " .. bob.ns.Escape(link:sub(1, 40)), "broken link not escaped")
end)

test("members on an older version are told about the update, at most once an hour", function()
    local w, anna, bob = setup()
    w:advance(30)
    local function notices(c)
        local n = 0
        for _, l in ipairs(c.log) do if l:find("A new version of Fellowship is available", 1, true) then n = n + 1 end end
        return n
    end
    eq(notices(bob), 0, "no notice when everyone is on the same version")
    -- Anna updates to a newer version and logs back in
    anna:logout()
    local real = anna.ns.VERSION
    anna:login()
    anna.ns.VERSION = "99.0.0"
    anna.ns.Sync:HelloAll(); w:advance(5)
    eq(notices(bob), 1, "bob not told")
    assert(bob:logContains("99.0.0 (you have " .. real .. ")"), "version text")
    eq(notices(anna), 0, "the up-to-date member isn't nagged")
    w:advance(1800); eq(notices(bob), 1, "repeated within the hour")
    w:advance(1900); eq(notices(bob), 2, "no hourly reminder")
    -- a relog doesn't reset the hourly timer, and the reminder survives with nobody online
    anna:logout(); bob:logout(); bob:login(); w:advance(60)
    eq(notices(bob), 2, "reload spammed the notice")
    w:advance(3600); eq(notices(bob), 3, "reminder lost after relog")
    -- once bob has the new version, the reminders stop
    bob:logout(); bob:login(); bob.ns.VERSION = "99.0.0"; w:advance(7300)
    eq(notices(bob), 3)
    assert(bob.ns.VersionNewer("1.0.10", "1.0.9") and not bob.ns.VersionNewer("1.0.9", "1.0.10"), "version compare")
    assert(not bob.ns.VersionNewer("garbage", "0.9.8"), "garbage accepted")
end)

test("rare mobs: found from minimap markers, nameplates and target; announced once", function()
    local w = World.new()
    local vignettes = {
        ["V-1"] = { name = "RareMob01", atlasName = "VignetteKillElite", objectGUID = "Creature-0-3767-0-22-12345-0000AB" },
        ["V-2"] = { name = "Shiny Chest", atlasName = "VignetteLoot", objectGUID = "GameObject-0-3767-0-22-999-0" },
    }
    local units = {}
    local function world()
        return {
            C_VignetteInfo = {
                GetVignetteInfo = function(g) return vignettes[g] end,
                GetVignettes = function() return { "V-1", "V-2" } end,
                GetVignettePosition = function() return { GetXY = function() return 0.452, 0.601 end } end,
            },
            C_Map = { GetBestMapForUnit = function() return 37 end },
            IsInInstance = function() return false end,
            UnitClassification = function(u) return units[u] and units[u].class end,
            UnitIsDead = function() return false end,
        }
    end
    local anna, bob = w:client("Anna"), w:client("Bob")
    anna.globals, bob.globals = world(), world()
    anna:login(); bob:login(); w:advance(1)
    anna:slash("/fship create Loot Kills"); anna:slash("/fship invite bob silvermoon"); w:advance(1)
    bob:acceptPopup("FELLOWSHIP_INVITE"); w:advance(20)

    anna:fire("VIGNETTE_MINIMAP_UPDATED", "V-1", true); w:advance(2)
    local line = "Anna Silvermoon|r has encountered |cffff9933RareMob01|r! in Elwynn Forest |cffffff00|Hworldmap:37:4520:6010|h[Map Pin]|h|r"
    assert(bob:logContains(line), "bob didn't see the rare")
    anna:fire("VIGNETTE_MINIMAP_UPDATED", "V-2", true)          -- a treasure, not a rare
    anna:fire("VIGNETTES_UPDATED")                              -- the same rare again
    bob:fire("VIGNETTE_MINIMAP_UPDATED", "V-1", true)           -- bob sees it too, minutes later
    w:advance(2)
    local function count(c, pat) local n = 0; for _, l in ipairs(c.log) do if l:find(pat, 1, true) then n = n + 1 end end; return n end
    eq(count(bob, "has encountered"), 1, "rare announced more than once")
    assert(not bob:logContains("Shiny Chest"), "treasure announced")

    -- a rare nameplate (no marker), then the same mob targeted: one announcement
    anna.units.nameplate1 = { name = "Grumpy Gnoll", player = false }
    units.nameplate1 = { class = "rare" }
    anna.env.UnitGUID = function(u) if u == "nameplate1" or u == "target" then return "Creature-0-3767-0-22-777-00" end end
    anna:fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    anna.units.target = anna.units.nameplate1; units.target = units.nameplate1
    anna:fire("PLAYER_TARGET_CHANGED"); w:advance(2)
    eq(count(bob, "Grumpy Gnoll"), 1)

    -- switched off: nothing shared; bob can also hide others' rares
    w:advance(700)
    anna.ns.settings.shareRares = false
    anna:fire("VIGNETTE_MINIMAP_UPDATED", "V-1", true); w:advance(2)
    eq(count(bob, "RareMob01"), 1, "shared while switched off")
    anna.ns.settings.shareRares = true
    bob.ns.settings.showRares = false
    anna:fire("VIGNETTE_MINIMAP_UPDATED", "V-1", true); w:advance(2)
    eq(count(bob, "RareMob01"), 1, "shown while hidden")
    local mine = 0
    for _, e in ipairs(anna.ns.Store:Sorted(anna.ns.Store:ActiveId())) do
        if e.k == "M" and e.d[1] == "rare" and e.d[2] == "RareMob01" then mine = mine + 1 end
    end
    eq(mine, 2, "anna's history has both sightings")
end)

test("deaths say what killed you: Death Recap, falling, drowning, or who you were fighting", function()
    local w = World.new()
    local recap
    local falling, breath = false, nil
    local g = {
        C_DeathRecap = { GetRecapEvents = function() return recap end },
        IsFalling = function() return falling end,
        GetMirrorTimerProgress = function(t) if t == "BREATH" then return breath end end,
        UnitCanAttack = function() return true end,
    }
    local anna, bob = w:client("Anna"), w:client("Bob")
    anna.globals = g
    anna:login(); bob:login(); w:advance(1)
    anna:slash("/fship create Loot Kills"); anna:slash("/fship invite bob silvermoon"); w:advance(1)
    bob:acceptPopup("FELLOWSHIP_INVITE"); w:advance(20)
    local RED = "|cffff4040"
    local function died() anna:fire("PLAYER_DEAD"); w:advance(5) end

    recap = {
        { timestamp = 10, event = "SWING_DAMAGE", sourceName = "Kobold Miner", amount = 5 },
        { timestamp = 12, event = "SPELL_DAMAGE", sourceName = "Hogger", spellName = "Vicious Slice", amount = 40 },
    }
    died()
    assert(bob:logContains(RED .. " was killed by Hogger (Vicious Slice) in Elwynn Forest|r"), "recap mob + spell")
    recap = { { timestamp = 3, event = "SWING_DAMAGE", sourceName = "Hogger", spellName = "Melee" } }
    died()
    assert(bob:logContains(RED .. " was killed by Hogger in Elwynn Forest|r"), "melee")
    recap = { { timestamp = 3, event = "ENVIRONMENTAL_DAMAGE", environmentalType = "Falling", amount = 900 } }
    died()
    assert(bob:logContains(RED .. " fell to their death in Elwynn Forest|r"), "recap falling")
    recap = { { timestamp = 3, event = "ENVIRONMENTAL_DAMAGE", environmentalType = "Lava" } }
    died()
    assert(bob:logContains(RED .. " burned to death in lava"), "lava")

    -- no recap: falling noticed just before death
    recap = nil
    falling = true; w:advance(1); falling = false
    died()
    eq(#(function() local t = {}; for _, l in ipairs(bob.log) do if l:find("fell to their death", 1, true) then t[#t + 1] = l end end; return t end)(), 2)
    -- drowning: breath bar ran out
    w:advance(5)
    anna:fire("MIRROR_TIMER_START", "BREATH", 0, 180000, -1, false, "Breath"); breath = 0
    died()
    assert(bob:logContains(RED .. " drowned in Elwynn Forest|r"), "drowning")
    anna:fire("MIRROR_TIMER_STOP", "BREATH"); breath = nil
    -- the enemy you had targeted
    anna.units.target = { name = "Defias Bandit", player = false }
    died()
    assert(bob:logContains(RED .. " died fighting Defias Bandit in Elwynn Forest|r"), "fight")
    -- nothing known: plain message, as before
    anna.units.target = nil
    died()
    assert(bob:logContains(RED .. " was killed in Elwynn Forest|r"), "plain")
end)

test("a chat line that gets lost on the way is filled in and still shown in chat", function()
    local w, anna, bob, cara = setup()
    w:advance(90) -- past the login catch-up window
    local drop = true
    w.dropper = function(from, to, text)
        if drop and from == "Anna Silvermoon" and to:lower():find("cara") and text:find("first line", 1, true) then
            drop = false
            return true
        end
    end
    anna:slash("/fs first line"); w:advance(2)
    assert(bob:logContains("first line"), "bob missed it")
    assert(not cara:logContains("first line"), "test setup: cara should have missed it")
    anna:slash("/fs second line"); w:advance(3)
    assert(cara:logContains("first line"), "gap not filled by the next message")
    assert(cara:logContains("second line"), "second line missing")

    -- lost with no follow-up message: the regular check-in fills it within a couple of minutes
    w.dropper = function(from, to, text)
        return from == "Bob Silvermoon" and to:lower():find("cara") and text:find("quiet line", 1, true)
    end
    bob:slash("/fs quiet line"); w:advance(3)
    assert(not cara:logContains("quiet line"), "test setup")
    w.dropper = nil
    w:advance(130)
    assert(cara:logContains("quiet line"), "not caught up by the check-in")
    assert(cara:logContains("ago)"), "late line not marked with when it was sent")
end)

test("messages sent while the game blocks addon messages go out once it allows them again", function()
    local w, anna, bob = setup()
    anna.lockdown = true
    anna:slash("/fs during the boss fight"); w:advance(5)
    assert(not bob:logContains("during the boss fight"), "test setup")
    anna.lockdown = false
    w:advance(2)
    assert(bob:logContains("during the boss fight"), "message lost during lockdown")
end)

-- Put `c` in a group with `others` ({ client or { name, realm, player } }).
local function joinGroup(c, others, raid)
    c.group, c.raid = {}, raid
    for i, o in ipairs(others) do
        local u = { name = o.name or o[1], realm = o.realm or o[2], player = o.player ~= false and o[3] ~= false }
        c.group[i] = u
        c.units[(raid and "raid" or "party") .. i] = u
    end
end

local function feats(c)
    local fid = c.ns.Store:ActiveId()
    local earned = c.ns.Feats:Earned(fid)
    local n = 0
    for _ in pairs(earned) do n = n + 1 end
    return earned, n
end

test("Fellowship Achievements: dungeons and raids completed with only fellowship members", function()
    local w, anna, bob, cara = setup()
    local dana = w:client("Dana"); dana:login(); w:advance(1) -- not in the fellowship
    local dm = { name = "Deadmines", type = "party", difficulty = "Normal", id = 36, bosses = { 11, 12 } }
    -- a stranger in the group: no achievement (but the dungeon is still announced)
    for _, c in ipairs({ anna, bob }) do c.instance = dm end
    joinGroup(anna, { bob, dana }); joinGroup(bob, { anna, dana })
    anna:fire("ENCOUNTER_END", 12, "Boss 2", 1, 5, 1); bob:fire("ENCOUNTER_END", 12, "Boss 2", 1, 5, 1)
    w:advance(3)
    local _, n = feats(cara)
    eq(n, 0, "earned with a non-member in the group")
    assert(cara:logContains("completed Deadmines (Normal)"), "dungeon still announced")
    -- solo doesn't count
    cara.instance = dm; cara.group = nil
    cara:fire("ENCOUNTER_END", 12, "Boss 2", 1, 5, 1); w:advance(3)
    _, n = feats(anna)
    eq(n, 0, "earned solo")
    -- all three members (plus an NPC follower): earned once, announced once
    for _, c in ipairs({ anna, bob, cara }) do c:fire("ZONE_CHANGED_NEW_AREA"); c.instance = nil; c:fire("ZONE_CHANGED_NEW_AREA") end
    for _, c in ipairs({ anna, bob, cara }) do c.instance = dm end
    local follower = { "Captain Garrick", "", false }
    joinGroup(anna, { bob, cara, follower }); joinGroup(bob, { anna, cara, follower }); joinGroup(cara, { anna, bob, follower })
    local before = #bob.log
    for _, c in ipairs({ anna, bob, cara }) do c:fire("ENCOUNTER_END", 12, "Boss 2", 1, 5, 1) end
    w:advance(5)
    for _, c in ipairs({ anna, bob, cara }) do
        local earned, count = feats(c)
        eq(count, 1, c.name .. " achievements")
        local a = earned["dungeon|deadmines|normal"]
        assert(a, c.name .. " has no Deadmines achievement")
        eq(#a.members, 3, "members recorded")
        eq(table.concat(a.members, ","), "Anna-Silvermoon,Bob-Silvermoon,Cara-Area52", "members")
        assert(a.t > 0, "date")
    end
    local shown = 0
    for i = before + 1, #bob.log do
        if bob.log[i]:find("Friday Night Crew has completed Deadmines!", 1, true) then shown = shown + 1 end
    end
    eq(shown, 1, "announced once in bob's chat")
    for i = before + 1, #bob.log do
        assert(not bob.log[i]:find("completed Deadmines (Normal)", 1, true), "per-member line when the group was all fellowship")
    end
    -- the Activity feed shows it once too
    local fid = bob.ns.Store:ActiveId()
    local inFeed = 0
    for _, e in ipairs(bob.ns.Store:Sorted(fid)) do
        if bob.ns.Feats.IsFeat(e) and bob.ns.Announce.ShouldShow(e) then inFeed = inFeed + 1 end
    end
    eq(inFeed, 1, "one feed line")
    -- doing it again doesn't add another; a raid is its own achievement
    local stored = #bob:history()
    for _, c in ipairs({ anna, bob, cara }) do c:fire("ZONE_CHANGED_NEW_AREA") end
    anna.instance = nil; anna:fire("ZONE_CHANGED_NEW_AREA"); anna.instance = dm
    anna:fire("ENCOUNTER_END", 12, "Boss 2", 1, 5, 1); w:advance(3)
    eq(#bob:history(), stored, "nothing new for a repeat run with the whole fellowship")
    anna.instance = { name = "Molten Core", type = "raid", difficulty = "Normal", id = 409, bosses = { 21, 22 } }
    anna:fire("ZONE_CHANGED_NEW_AREA")
    joinGroup(anna, { bob, cara }, true)
    anna:fire("ENCOUNTER_END", 22, "Ragnaros", 14, 20, 1); w:advance(3)
    local earned, count = feats(cara)
    eq(count, 2, "raid achievement")
    eq(earned["raid|molten core|normal"].category, "raid", "raid category")
    assert(cara:logContains("Friday Night Crew has completed Molten Core!"), "raid announced")
    -- no Encounter Journal info (WoW Forever): the built-in final boss names finish the run
    local stocks = { name = "Stormwind Stockade", type = "party", difficulty = "Normal", id = 34, bosses = {} }
    for _, c in ipairs({ anna, bob, cara }) do c.instance = stocks; c:fire("ZONE_CHANGED_NEW_AREA") end
    joinGroup(anna, { bob, cara })
    anna:fire("ENCOUNTER_END", 1716, "Targorr the Dread", 1, 5, 1); w:advance(2)
    assert(not feats(cara)["dungeon|stormwind stockade|normal"], "a middle boss finished the Stockade")
    anna:fire("ENCOUNTER_END", 1717, "Bazil Thredd", 1, 5, 1); w:advance(3)
    assert(feats(cara)["dungeon|stormwind stockade|normal"], "Bazil Thredd didn't finish the Stockade")
    anna:slash("/fship dungeons")
    assert(anna:logContains("Killed Bazil Thredd (1717) in Stormwind Stockade"), "boss kill listed by /fship dungeons")
    -- WoW Forever's own dungeons: Excavation Site ends with the Relic Guardian
    local dig = { name = "Excavation Site: Wetlands", type = "party", difficulty = "Normal", id = 2001, bosses = {} }
    anna.instance = dig; anna:fire("ZONE_CHANGED_NEW_AREA")
    anna:fire("ENCOUNTER_END", 3481, "Shadetooth", 1, 5, 1); w:advance(2)
    assert(not feats(cara)["dungeon|excavation site: wetlands|normal"], "Shadetooth finished the dig")
    anna:fire("ENCOUNTER_END", 3482, "Relic Guardian", 1, 5, 1); w:advance(3)
    assert(feats(cara)["dungeon|excavation site: wetlands|normal"], "Relic Guardian didn't finish the dig")
    -- every WoW Forever dungeon has a final boss on the list, under the names the game uses
    for inst, boss in pairs({ ["Hall of Thanes"] = "Durgen Dirgehammer", ["The Drowned City"] = "Min'loth the Serpent",
            ["Krol'dok Stronghold"] = "Overseer Mugg", ["Alcaz Prison"] = "Blazeroar",
            ["Blackmaw Hold"] = "the Unbound Spirit", ["The Shaper's Terrace"] = "Nanaya",
            ["Ruins of Lordaeron"] = "Rath'mael",
            ["City of Dalaran"] = "Shade of the Archmage", ["Barrows Deep"] = "Sonya Darkhallow", ["Sunken Temple"] = "Shade of Eranikus" }) do
        assert(anna.ns.Feats.IsFinalBoss(inst, boss), boss .. " should finish " .. inst)
    end
    assert(not anna.ns.Feats.IsFinalBoss("Blackmaw Hold", "Withermaw"), "first boss of Blackmaw Hold")
    -- no encounter events at all: seeing the final boss dead (target or nameplate) finishes it
    local sfk = { name = "Shadowfang Keep", type = "party", difficulty = "Normal", id = 33, bosses = {} }
    anna.instance = sfk; anna:fire("ZONE_CHANGED_NEW_AREA")
    anna.units.target = { name = "Lord Godfrey", player = false, dead = false }
    anna:fire("UNIT_HEALTH", "target"); w:advance(2)
    assert(not feats(cara)["dungeon|shadowfang keep|normal"], "counted while the boss was alive")
    anna.units.target.dead = true
    anna:fire("UNIT_HEALTH", "target"); anna:fire("PLAYER_TARGET_CHANGED"); w:advance(3)
    assert(feats(cara)["dungeon|shadowfang keep|normal"], "final boss seen dead didn't count")
    anna.units.target = nil
    for _, c in ipairs({ anna, bob, cara }) do c.instance = nil; c:fire("ZONE_CHANGED_NEW_AREA") end
    -- achievements survive pruning and reach someone who joins later
    anna.ns.settings.maxEvents = 1
    anna.ns.Store:Prune(anna.ns.Store:ActiveId())
    eq(select(2, feats(anna)), 5, "pruned")
    -- Achievements tab: Dungeons and Raids cards, from the Dungeon Finder list (levels, art)
    -- and the Encounter Journal, sorted by level; completed ones carry the date
    local lfg = {
        [1] = { "The Deadmines", 1, 1, 15, 25, 0, 17, 26, 0, 0, "DEADMINES" },
        [2] = { "Wailing Caverns", 1, 1, 15, 25, 0, 16, 23, 0, 0, "WAILINGCAVERNS" },
        [3] = { "The Deadmines", 1, 2, 60, 60, 0, 60, 60, 0, 0, "DEADMINES" }, -- heroic
        [4] = { "Random Classic Dungeon", 6, 1, 15, 60, 0, 15, 60, 0, 0, "" },
        [5] = { "Molten Core", 2, 3, 60, 60, 0, 60, 60, 0, 0, "MOLTENCORE" },
        -- WoW Forever's group finder also lists zones and battlegrounds (level 1)
        [6] = { "Alterac Mountains", 1, 1, 1, 1, 0, 1, 1, 0, 0, "" },
        [7] = { "Arathi Basin", 1, 1, 1, 1, 0, 1, 1, 0, 0, "" },
        [8] = { "Shadowfang Keep", 1, 1, 1, 1, 0, 1, 1, 0, 0, "" },
    }
    anna.env.GetLFGDungeonInfo = function(id) if lfg[id] then return unpack(lfg[id]) end end
    anna.env.EJ_GetInstanceByIndex = function(i, isRaid)
        local list = isRaid and { "Molten Core", "Onyxia's Lair" } or { "Deadmines", "Hall of Thanes" }
        if list[i] then return i, list[i], "", "", "Interface\\EJ\\" .. list[i] end
    end
    local fid = anna.ns.Store:ActiveId()
    -- no dungeon list from the game: the built-in one still gives every card
    local bare = cara.ns.Feats:Cards(cara.ns.Store:ActiveId(), "dungeon")
    assert(#bare >= 20, "built-in dungeon list")
    local cards, done = anna.ns.Feats:Cards(fid, "dungeon")
    local byName = {}
    for i, c in ipairs(cards) do byName[c.name] = c; c.index = i end
    eq(#cards, #bare, "game's dungeons merged with the built-in list (random queue skipped)")
    eq(done, 4, "dungeons done (Deadmines, Stockade, Excavation Site, Shadowfang Keep)")
    assert(byName["The Deadmines"].done and byName["The Deadmines"].done.t > 0, "Deadmines completed with a date")
    eq(byName["The Deadmines"].minLevel, 17, "recommended level range")
    eq(byName["Wailing Caverns"].minLevel, 16, "the game's levels win over the built-in ones")
    eq(byName["Wailing Caverns"].maxLevel, 23, "game max level")
    eq(byName["The Deadmines"].art, "Interface\\LFGFrame\\UI-LFG-BACKGROUND-DEADMINES", "dungeon finder art")
    eq(byName["Hall of Thanes"].ejArt, "Interface\\EJ\\Hall of Thanes", "journal art")
    assert(not byName["Wailing Caverns"].done, "Wailing Caverns incomplete")
    assert(byName["Ragefire Chasm"].index < byName["Shadowfang Keep"].index, "sorted by level")
    assert(not byName["Random Classic Dungeon"], "random queue is not a dungeon")
    assert(not byName["Alterac Mountains"] and not byName["Arathi Basin"], "zones are not dungeons")
    eq(byName["Shadowfang Keep"].minLevel, 22, "a level-1 entry doesn't replace the real range")
    local raids, raidsDone = anna.ns.Feats:Cards(fid, "raid")
    eq(#raids, 8, "raid cards"); eq(raidsDone, 1, "raids done")
    anna:slash("/fs")
    anna.ns.UI:SelectTab("feats")
    local p
    for _, f in ipairs(anna.frames) do if type(rawget(f, "cards")) == "table" then p = f end end
    assert(p, "achievements panel")
    local function statusOf(name)
        for _, c in ipairs(p.cards) do
            if c.card and c.card.name == name then return c.status:GetText() end
        end
    end
    assert(statusOf("The Deadmines"):find("Completed: ", 1, true), "completed card")
    assert(statusOf("Wailing Caverns"):find("|cffff3333Incomplete", 1, true), "incomplete card in red")
    p.subTabs.raid:Click()
    assert(statusOf("Molten Core"):find("Completed: ", 1, true), "raids sub-tab")
end)

local function chan(c) return c.ns.Channel end

test("hidden channel: one message reaches everyone; unique name and password per fellowship", function()
    local w, anna, bob, cara = setup()
    w:advance(10)
    local name = chan(anna):Name()
    assert(chan(anna):Ready() and chan(bob):Ready() and chan(cara):Ready(), "not everyone joined the channel")
    eq(chan(bob):Name(), name, "bob on another channel"); eq(chan(cara):Name(), name, "cara on another channel")
    assert(name:match("^Fs%w+$") and #name == 12, "channel name " .. name)
    assert(not name:lower():find("friday", 1, true), "name gives away the fellowship")
    local ch = w.channels[name:lower()]
    assert(ch.password and #ch.password == 10, "no password")
    eq(chan(anna):PeerCount(), 2, "anna hasn't heard bob and cara on the channel")
    -- a chat line: one channel message, no whispers
    local sent, viaChannel = w.sent, w.channelSent
    anna:slash("/fs one message for all"); w:advance(1)
    eq(w.channelSent - viaChannel, 1, "channel messages for one chat line")
    eq(w.sent - sent, 1, "whispers sent as well")
    assert(bob:logContains("one message for all") and cara:logContains("one message for all"), "not delivered")
    -- the join notices stay out of chat
    for _, c in ipairs({ anna, bob, cara }) do assert(not c:logContains(name), "channel name shown in chat") end
    -- another fellowship with the same name gets a different channel
    local w2 = World.new()
    local x = w2:client("Xan"); x:login(); w2:advance(1)
    x:slash("/fship create Friday Night Crew"); w2:advance(10)
    assert(chan(x):Name() ~= name, "two fellowships share a channel")
    x:slash("/fship channel")
    assert(x:logContains("Fellowship channel: joined"), "/fship channel status")
end)

test("hidden channel: a taken name moves everyone to the same next name", function()
    local w, anna, bob, cara = setup()
    w:advance(10)
    local name = chan(anna):Name()
    for _, c in ipairs({ anna, bob, cara }) do c.env.LeaveChannelByName(name) end
    w.channels[name:lower()] = { name = name, password = "someoneelse", members = { ["Zed-Elsewhere"] = true } }
    for _, c in ipairs({ anna, bob, cara }) do chan(c):Refresh() end
    w:advance(10)
    for _, c in ipairs({ anna, bob, cara }) do eq(chan(c):Name(), name .. "2", c.name .. "'s channel") end
    assert(chan(anna):Ready(), "not joined")
    bob:slash("/fs after the move"); w:advance(1)
    assert(anna:logContains("after the move") and cara:logContains("after the move"), "not delivered")
    assert(not w.channels[name:lower()].members["Anna-Silvermoon"], "joined the stranger's channel")
end)

test("hidden channel: members without it still get whispers; removal moves to a new channel", function()
    local w, anna, bob, cara = setup(function(_, _, cara) cara.channelSlotsFull = true end)
    w:advance(30)
    assert(chan(anna):Ready() and chan(bob):Ready(), "anna and bob not on the channel")
    assert(not chan(cara):Ready(), "cara has no free channel slot")
    anna:slash("/fs whisper fallback"); w:advance(2)
    assert(bob:logContains("whisper fallback"), "bob (channel) missed it")
    assert(cara:logContains("whisper fallback"), "cara (whispers) missed it")
    cara:slash("/fs from cara"); w:advance(2)
    assert(anna:logContains("from cara") and bob:logContains("from cara"), "cara's whispers")
    -- no channel support at all in this game client: whispers only, nothing breaks
    -- removing a member moves the others to a fresh channel and password
    local old = chan(anna):Name()
    cara.channelSlotsFull = false; w:advance(360) -- retried every few minutes
    eq(chan(cara):Name(), old, "cara joined once a slot was free")
    anna:slash("/fship remove Cara Area52"); w:advance(15)
    local new = chan(anna):Name()
    assert(new ~= old, "removal didn't move the channel")
    eq(chan(bob):Name(), new, "bob didn't move")
    assert(not w.channels[new:lower()].members["Cara-Area52"], "removed member is on the new channel")
    anna:slash("/fs after removal"); w:advance(2)
    assert(bob:logContains("after removal"), "bob missed it")
    assert(not cara:logContains("after removal"), "removed member still hears the fellowship")
end)

test("no channel support in the client: whispers only", function()
    local w, anna, bob, cara = setup(function(a, b, c) a.noChannels = true; b.noChannels = true; c.noChannels = true end)
    w:advance(10)
    assert(not chan(anna):Ready(), "channel without support")
    anna:slash("/fs plain whispers"); w:advance(2)
    assert(bob:logContains("plain whispers") and cara:logContains("plain whispers"), "whispers broken")
    anna:slash("/fship channel")
    assert(anna:logContains("using whispers"), "status")
end)

-- Wishlists ---------------------------------------------------------------
local ORE = "|cffffffff|Hitem:2770:1::|h[Copper Ore]|h|r"
local BOW = "|cffa335ee|Hitem:900:4::|h[Epic Bow]|h|r"
local HAT = "|cff1eff00|Hitem:950:2::|h[Green Hat]|h|r"

ITEM_DB = {
    [2770] = { "Copper Ore", 1, 7 }, [2771] = { "Tin Ore", 1, 7 }, [2772] = { "Iron Ore", 1, 7 },
    [2775] = { "Silver Ore", 2, 7 }, [3858] = { "Mithril Ore", 1, 7 }, [2840] = { "Copper Bar", 1, 7 },
    [900] = { "Epic Bow", 4, 2 }, [950] = { "Green Hat", 2, 4 }, [7911] = { "Truesilver Ore", 2, 7 },
    [4000] = { "Boots of the Oregon Trail", 3, 4 }, [12345] = { "Thing", 1, 15 },
}

local function withItems(...)
    local clients = { ... }
    return function()
        for _, c in ipairs(clients) do
            c.bags = c.bags or {}
            c.globals = c.globals or {}
            c.globals.GetItemCount = function(id) return c.bags[id] or 0 end
            c.globals.GetItemInfoInstant = function(id)
                if not ITEM_DB[id] then return nil end
                return id, nil, nil, nil, nil, ITEM_DB[id][3]
            end
            c.globals.GetItemInfo = function(id)
                if type(id) == "string" then
                    for k, v in pairs(ITEM_DB) do
                        if v[1] == id and (not c.serverSlow or c.cached[k]) then return v[1], "|cffffffff|Hitem:" .. k .. "|h[" .. v[1] .. "]|h|r", v[2] end
                    end
                    return nil
                end
                local v = ITEM_DB[id]
                if not v then return "Item " .. tostring(id), nil, nil end
                if c.serverSlow and not (c.cached and c.cached[id]) then return nil end
                return v[1], "|cffffffff|Hitem:" .. id .. "|h[" .. v[1] .. "]|h|r", v[2]
            end
            c.globals.GetLootRollItemLink = function(rollID) return c.rolls and c.rolls[rollID] end
            c.globals.PlaySound = function(id) c.sounds = (c.sounds or 0) + 1 end
            c.globals.SOUNDKIT = { RAID_WARNING = 8959 }
        end
    end
end

local function chatMatch(c, pattern)
    for _, l in ipairs(c.log) do if l:find(pattern) then return true end end
    return false
end

local function tooltip(c, id)
    return table.concat(c.ns.Wishlist:TooltipLines(id), " / ")
end

test("wishlist: items are shared live, kinds default by item type, tooltips say who wants them", function()
    local before = function(anna, bob, cara) withItems(anna, bob, cara)() end
    local w, anna, bob, cara = setup(before)
    anna.bags[2770] = 14
    anna:slash("/fship wish " .. BOW .. " for my hunter")
    anna:slash("/fship wish " .. ORE .. " 40")
    w:advance(2)
    local W = anna.ns.Wishlist
    eq(#W:Mine(), 2, "two wishes")
    eq(W:Find(900).mode, "once", "gear is one-time")
    eq(W:Find(900).note, "for my hunter", "note kept")
    eq(W:Find(2770).mode, "always", "ore is always wanted")
    eq(W:Find(2770).want, 40, "amount")
    eq(W:Find(2770).have, 14, "bag count")
    assert(tooltip(bob, 2770):find("wanted by .*Anna Silvermoon.*14/40"), "bob's ore tooltip: " .. tooltip(bob, 2770))
    assert(tooltip(cara, 900):find("Anna Silvermoon"), "cara's bow tooltip")
    assert(tooltip(anna, 900):find("on your wishlist"), "own tooltip")
    eq(tooltip(bob, 12345), "", "unwanted item has no line")
    -- adding the same item twice doesn't duplicate it; removing works
    anna.ns.Wishlist:Add(BOW)
    eq(#W:Mine(), 2, "no duplicate")
    anna:slash("/fship wish " .. HAT)
    w:advance(2)
    assert(tooltip(bob, 950) ~= "", "hat shared")
    anna:slash("/fship unwish " .. HAT)
    w:advance(2)
    eq(tooltip(bob, 950), "", "hat removed for bob")
    -- typed names only work for items the game knows
    local _, err = W:Add("Some Unknown Thing")
    assert(err and err:find("Shift%-click"), "explains how to add")
end)

test("wishlist: offline members get lists from whoever is online, and a wiped list comes back", function()
    local before = function(anna, bob, cara) withItems(anna, bob, cara)() end
    local w, anna, bob, cara = setup(before)
    cara:logout()
    w:advance(5)
    anna.ns.Wishlist:Add(BOW)
    w:advance(2)
    anna:logout()
    w:advance(5)
    cara:login()
    w:advance(30)
    assert(tooltip(cara, 900):find("Anna Silvermoon"), "cara learned anna's wish from bob")
    -- anna's saved list is lost (reinstall); a friend restores it
    anna.saved.fellowships[next(anna.saved.fellowships)].wishes = nil
    anna:login()
    w:advance(30)
    eq(#anna.ns.Wishlist:Mine(), 1, "list restored from a friend")
end)

test("wishlist: loot pings the wanter, a one-time wish is granted, always-wanted stays quiet", function()
    local before = function(anna, bob, cara) withItems(anna, bob, cara)() end
    local w, anna, bob, cara = setup(before)
    anna.ns.Wishlist:Add(BOW)
    anna.ns.Wishlist:Add(ORE, 40)
    anna.ns.Wishlist:Add(HAT) -- a green: normally too low to announce
    w:advance(2)
    -- bob loots the hat anna wants: anna is pinged, cara sees it too
    bob:fire("CHAT_MSG_LOOT", "You receive loot: " .. HAT .. ".")
    w:advance(2)
    assert(chatMatch(anna, "looted .*Green Hat.* %- .*Anna Silvermoon.* wanted this!"), "anna pinged: " .. table.concat(anna.log, "\n", math.max(1, #anna.log - 4)))
    eq(anna.sounds, 1, "anna heard a sound")
    assert(chatMatch(cara, "Green Hat.*wanted this!"), "cara sees it")
    assert(not cara.sounds, "no sound for cara")
    -- bob loots ore: always-wanted without pings stays quiet
    bob:fire("CHAT_MSG_LOOT", "You receive loot: " .. ORE .. "x5.")
    w:advance(2)
    assert(not chatMatch(anna, "Copper Ore.*wanted"), "no ore ping")
    -- with pings on: one ping, then quiet for 10 minutes
    anna.ns.Wishlist:SetNotify(2770, true)
    w:advance(2)
    bob:fire("CHAT_MSG_LOOT", "You receive loot: " .. ORE .. "x2.")
    w:advance(2)
    bob:fire("CHAT_MSG_LOOT", "You receive loot: " .. ORE .. "x2.")
    w:advance(2)
    local n = 0
    for _, l in ipairs(anna.log) do if l:find("Copper Ore.*wanted this") then n = n + 1 end end
    eq(n, 1, "one ore ping")
    -- anna loots her own ore: no message; loots the bow: wish granted
    anna:fire("CHAT_MSG_LOOT", "You receive loot: " .. ORE .. ".")
    anna:fire("CHAT_MSG_LOOT", "You receive loot: " .. BOW .. ".")
    w:advance(2)
    assert(chatMatch(anna, "Wish granted!"), "anna told")
    assert(chatMatch(bob, "Anna Silvermoon.*looted .*Epic Bow.*Wish granted!"), "bob sees it")
    assert(not anna.ns.Wishlist:Find(900), "bow off the list")
    assert(anna.ns.Wishlist:Find(2770), "ore still on the list")
    eq(tooltip(bob, 900), "", "bob no longer sees the bow wanted")
end)

test("wishlist: counts update and show stocked; mailbox and loot roll reminders", function()
    local before = function(anna, bob, cara) withItems(anna, bob, cara)() end
    local w, anna, bob, cara = setup(before)
    anna.ns.Wishlist:Add(ORE, 40)
    anna.ns.Wishlist:Add(BOW)
    w:advance(2)
    -- bob at a mailbox with ore in his bags
    bob.bags[2770] = 12
    bob:fire("MAIL_SHOW")
    assert(chatMatch(bob, "Anna Silvermoon.* wants .*item:2770.*0/40.* %- you have 12"), "mailbox reminder: " .. table.concat(bob.log, "\n", math.max(1, #bob.log - 3)))
    local before2 = #bob.log
    bob:fire("MAIL_SHOW")
    eq(#bob.log, before2, "not repeated right away")
    -- anna's bags fill up: friends see her stocked after a short delay
    anna.bags[2770] = 40
    anna:fire("BAG_UPDATE_DELAYED")
    w:advance(35)
    assert(tooltip(bob, 2770):find("stocked"), "stocked: " .. tooltip(bob, 2770))
    cara.bags[2770] = 3
    cara:fire("MAIL_SHOW")
    assert(not chatMatch(cara, "wants .*item:2770"), "no mailbox reminder once stocked")
    -- a loot roll for the bow in cara's group
    cara.rolls = { [7] = BOW }
    cara:fire("START_LOOT_ROLL", 7)
    assert(chatMatch(cara, "Wishlist:.*Epic Bow.* is wanted by .*Anna Silvermoon"), "roll reminder")
end)

test("wishlist: older versions ignore it, removed members' lists disappear, UI menu works", function()
    local before = function(anna, bob, cara) withItems(anna, bob, cara)() end
    local w, anna, bob, cara = setup(before)
    bob.ns.Wishlist:Add(BOW)
    w:advance(2)
    assert(tooltip(anna, 900):find("Bob Silvermoon"), "anna sees bob's wish")
    -- garbage and lists for non-members are dropped
    anna.ns.Wishlist:OnList("Bob-Silvermoon", anna.ns.Store:ActiveId(),
        { { "WL" }, { "Evil-Stranger", "99999999999" }, { "900", "o", "0", "0", "", "", "", "" } })
    eq(#anna.ns.Wishlist:Wanters(900), 1, "stranger ignored")
    anna:slash("/fship remove bob silvermoon")
    w:advance(2)
    eq(tooltip(anna, 900), "", "removed member's wish gone")
    -- right-click menu on my own row
    anna.ns.Wishlist:Add(ORE)
    local e = anna.ns.Wishlist:Find(2770)
    local labels = {}
    for _, item in ipairs(anna.ns.UI:WishMenuItems(e)) do labels[#labels + 1] = item[1] end
    assert(table.concat(labels, "|"):find("Set amount"), "amount option")
    anna.ns.UI:WishMenuItems(e)[1][2]() -- make it one-time
    eq(anna.ns.Wishlist:Find(2770).mode, "once", "switched")
end)

test("wishlist: shift-clicking a stack with the Wishlist tab open adds it instead of splitting", function()
    local before = function(anna, bob, cara)
        withItems(anna, bob, cara)()
        local split = { shown = false }
        function split:IsShown() return self.shown end
        function split:Hide() self.shown = false end
        function split:OpenStackSplitFrame() self.shown = true end
        anna.split = split
        anna.globals.StackSplitFrame = split
        anna.globals.IsModifiedClick = function() return true end
        anna.globals.HandleModifiedItemClick = function() return false end
        anna.globals.hooksecurefunc = function(a, b, c)
            local env = anna.env
            if type(a) == "table" then
                local orig = a[b]; a[b] = function(...) local r = orig(...); c(...); return r end
            else
                local orig = env[a]; rawset(env, a, function(...) local r = orig(...); b(...); return r end)
            end
        end
        anna.globals.GetCursorInfo = function() return anna.cursor and "item", 2770, anna.cursor end
        anna.globals.ClearCursor = function() anna.cursor = nil end
    end
    local w, anna = setup(before)
    local env = anna.env
    -- tab closed: shift-click behaves normally (splits the stack)
    env.HandleModifiedItemClick(ORE); anna.split:OpenStackSplitFrame()
    eq(#anna.ns.Wishlist:Mine(), 0, "not added while the window is closed")
    anna.split:Hide()
    anna.ns.UI:Show("wishlist")
    -- a bag click: HandleModifiedItemClick returns false, then the bag opens the splitter
    env.HandleModifiedItemClick(ORE); anna.split:OpenStackSplitFrame()
    assert(anna.ns.Wishlist:Find(2770), "ore added")
    assert(not anna.split:IsShown(), "stack splitter closed")
    -- dropping an item picked up from the bags onto the tab
    anna.cursor = BOW
    anna.ns.UI.WishlistPanelForTest().dropItem()
    assert(anna.ns.Wishlist:Find(900), "bow added by dropping it")
    eq(anna.cursor, nil, "cursor cleared")
end)

test("wishlist: Fellowship Wishes shows how many of each item you have", function()
    local w, anna, bob = setup(function(a, b, c) withItems(a, b, c)() end)
    bob.ns.Wishlist:Add(2770); bob.ns.Wishlist:Add(900)
    w:advance(5)
    anna.bags[2770] = 23
    anna.ns.UI:Show("wishlist")
    local p = anna.ns.UI.WishlistPanelForTest()
    p.subTabs.all:Click()
    local function cell(id, col)
        for _, r in ipairs(p.rows) do
            if r:IsShown() and r.wish and r.wish.id == id then return r.cells[col]:GetText() end
        end
    end
    eq(p.cols[2]:GetText(), "I have", "column header")
    assert(tostring(cell(2770, 2)):find("23", 1, true), "shows 23 ore")
    assert(tostring(cell(900, 2)):find("0", 1, true), "shows 0 bows")
    assert(tostring(cell(2770, 3)):find("Bob", 1, true), "wanted by Bob")
    anna.bags[900] = 1
    anna:fire("BAG_UPDATE_DELAYED"); w:advance(2)
    assert(tostring(cell(900, 2)):find("1", 1, true), "updates when bags change")
end)

test("item search: learns item names slowly in the background and finds them as you type", function()
    local before = function(anna, bob, cara)
        withItems(anna, bob, cara)()
        anna.serverSlow, anna.cached = true, {}
        anna.globals.C_Item = {
            GetItemQualityByID = function() return 1 end,
            RequestLoadItemDataByID = function(id)
                anna.requests = (anna.requests or 0) + 1
                anna.world:schedule(anna.world.time + 0.5, function()
                    anna.cached[id] = true
                    anna:fire("GET_ITEM_INFO_RECEIVED", id, true)
                end)
            end,
        }
        anna.globals.GetBuildInfo = function() return "1.60.1", anna.build or "70399" end
        anna.globals.InCombatLockdown = function() return anna.inCombat == true end
    end
    local w, anna = setup(before)
    local S = anna.ns.ItemSearch
    S.MAX_ID = 20000
    eq(#S:Search("ore"), 0, "nothing known before the scan")
    anna.inCombat = true
    w:advance(60)
    eq(S:Count(), 0, "paused in combat")
    anna.inCombat = false
    w:advance(60)
    eq(S:Progress(), nil, "scan finished")
    eq(S:Count(), 11, "every item learned")
    assert(anna.requests <= 11, "each item asked about once")
    local names = {}
    for _, h in ipairs(S:Search("ore")) do names[#names + 1] = h.name end
    eq(table.concat(names, ","), "Tin Ore,Iron Ore,Copper Ore,Silver Ore,Mithril Ore,Truesilver Ore,Boots of the Oregon Trail",
        "word matches first, shortest first")
    eq(S:Search("iron ore")[1].name, "Iron Ore", "several words")
    eq(S:Search("cop")[1].name, "Copper Bar", "prefix")
    eq(#S:Search("o"), 0, "needs two letters")
    -- typing in the wishlist box shows suggestions; Enter adds the top one
    anna.ns.UI:Show("wishlist")
    local wl = anna.ns.UI.WishlistPanelForTest()
    wl.input:SetText("silver o")
    wl.input._scripts.OnTextChanged(wl.input, true)
    assert(wl.suggest:IsShown(), "suggestions shown")
    eq(wl.suggest.results[1].name, "Silver Ore", "top suggestion")
    wl.input._scripts.OnEnterPressed(wl.input)
    assert(anna.ns.Wishlist:Find(2775), "silver ore added")
    -- clicking a suggestion
    wl.input:SetText("mithril")
    wl.input._scripts.OnTextChanged(wl.input, true)
    wl.suggest.rows[1]:Click()
    assert(anna.ns.Wishlist:Find(3858), "mithril added by clicking")
    -- names survive a relog; a patch only looks for new items
    anna:logout(); w:advance(5)
    anna.build = "70500"
    anna:login(); w:advance(2)
    eq(anna.ns.ItemSearch:Count(), 11, "names kept")
    eq(anna.ns.ItemSearch:Search("tin")[1].name, "Tin Ore", "search works right after login")
end)

test("item search and bag counts use C_Item when the old item globals are gone", function()
    local before = function(anna, bob, cara)
        withItems(anna, bob, cara)()
        local gi, gc = anna.globals.GetItemInfo, anna.globals.GetItemCount
        anna.globals.C_Item = { GetItemInfo = gi, GetItemCount = gc, GetItemInfoInstant = anna.globals.GetItemInfoInstant,
            GetItemQualityByID = function() return 1 end }
        anna.globals.GetItemInfo, anna.globals.GetItemCount, anna.globals.GetItemInfoInstant = false, false, false
    end
    local w, anna = setup(before)
    for _, k in ipairs({ "GetItemInfo", "GetItemCount", "GetItemInfoInstant" }) do rawset(anna.env, k, nil) end
    anna.ns.ItemSearch.MAX_ID = 20000
    anna.bags[2770] = 9
    w:advance(120)
    eq(anna.ns.ItemSearch:Count(), 11, "items learned through C_Item")
    eq(anna.ns.ItemSearch:Search("ore")[1].name, "Tin Ore", "search works")
    anna.ns.Wishlist:Add(2770, 20)
    eq(anna.ns.Wishlist:Find(2770).have, 9, "bag count through C_Item")
    anna:slash("/fship items")
    assert(anna:logContains("Item search knows 11 items"), "status command")
end)

-- Calendar -----------------------------------------------------------------
local function cal(c) return c.ns.Calendar end
local function plan(c, offset, typ, title, note)
    return cal(c):Create({ time = c.ns.Now() + offset, type = typ or "dungeon", title = title or "Gnomeregan", note = note })
end

test("calendar: anyone plans an event, everyone sees it and signs up", function()
    local w, anna, bob, cara = setup()
    local key = plan(bob, 86400, "dungeon", "Gnomeregan", "Meet at the stone")
    assert(key, "bob (a regular member) can plan")
    w:advance(2)
    local ev = cal(anna):Get(key)
    assert(ev, "anna sees the event")
    eq(ev.title, "Gnomeregan"); eq(ev.note, "Meet at the stone")
    assert(chatMatch(anna, "Bob Silvermoon.* planned .*Gnomeregan.* for Tomorrow"), "anna told about it")
    eq(cal(anna):MyStatus(ev), nil, "anna hasn't answered")
    eq(cal(bob):MyStatus(cal(bob):Get(key)), "y", "creator is going")
    cal(anna):Respond(key, "y")
    cal(cara):Respond(key, "n")
    w:advance(2)
    local a = cal(bob):Answers(cal(bob):Get(key))
    eq(#a.y, 2, "two going"); eq(#a.n, 1, "one can't")
    assert(chatMatch(bob, "Anna Silvermoon.*is going.* to .*Gnomeregan"), "creator told who's going")
    assert(chatMatch(bob, "Cara Area52.*can't make it"), "creator told who can't")
    -- changing your mind
    cal(cara):Respond(key, "m")
    w:advance(2)
    a = cal(anna):Answers(cal(anna):Get(key))
    eq(#a.m, 1, "cara now maybe"); eq(#a.n, 0, "no can't")
    -- a raid and an "other" event, sorted by time
    plan(anna, 3 * 86400, "raid", "Molten Core")
    plan(cara, 2 * 86400, "other", "Fishing contest")
    w:advance(2)
    local up = cal(bob):Upcoming()
    eq(#up, 3, "three upcoming")
    eq(up[2].title, "Fishing contest", "sorted by time")
end)

test("calendar: only the creator edits or cancels; bad events are refused", function()
    local w, anna, bob = setup()
    local key = plan(anna, 7200)
    w:advance(2)
    assert(not cal(bob):Edit(key, { time = bob.ns.Now() + 9000, type = "dungeon", title = "Hijacked" }), "bob can't edit")
    assert(not cal(bob):Cancel(key), "bob can't cancel")
    assert(not cal(bob):CanEdit(key), "no edit buttons for bob")
    assert(cal(anna):Edit(key, { time = anna.ns.Now() + 9000, type = "dungeon", title = "Uldaman" }), "anna edits")
    w:advance(2)
    eq(cal(bob):Get(key).title, "Uldaman", "edit reached bob")
    cal(bob):Respond(key, "y")
    w:advance(2)
    cal(anna):Cancel(key)
    w:advance(2)
    assert(cal(bob):Get(key).cancelled, "cancelled for bob")
    assert(chatMatch(bob, "Anna Silvermoon.* cancelled .*Uldaman"), "bob told")
    eq(#cal(bob):Upcoming(), 0, "cancelled events leave Upcoming")
    local _, err = cal(anna):Create({ time = anna.ns.Now() - 3600, type = "dungeon", title = "Late" })
    assert(err and err:find("passed"), "past time refused")
    _, err = cal(anna):Create({ time = anna.ns.Now() + 3600, type = "dungeon", title = "" })
    assert(err and err:find("Pick a dungeon"), "needs a dungeon")
    _, err = cal(anna):Create({ time = anna.ns.Now() + 3600, type = "other", title = " " })
    assert(err and err:find("name"), "needs a name")
end)

test("calendar: members who were offline get events and answers when they log in", function()
    local w, anna, bob, cara = setup()
    cara:logout()
    w:advance(5)
    local key = plan(anna, 86400)
    w:advance(2)
    assert(cal(bob):Respond(key, "y"), "bob answers")
    w:advance(2)
    anna:logout()
    w:advance(5)
    cara:login()
    w:advance(40)
    local ev = cal(cara):Get(key)
    assert(ev, "cara got anna's event from bob")
    eq(#cal(cara):Answers(ev).y, 2, "and the answers")
    assert(chatMatch(cara, "waiting for your answer"), "login reminder to answer")
    -- anna comes back and sees cara's answer
    cal(cara):Respond(key, "m")
    w:advance(2)
    anna:login()
    w:advance(40)
    eq(#cal(anna):Answers(cal(anna):Get(key)).m, 1, "anna caught up on cara's answer")
end)

test("calendar: reminder 15 minutes before, except for people who can't come", function()
    local w, anna, bob, cara = setup()
    local key = plan(anna, 3600)
    w:advance(2)
    cal(bob):Respond(key, "y")
    cal(cara):Respond(key, "n")
    w:advance(60 * 30)
    assert(not chatMatch(bob, "Reminder:"), "not yet")
    w:advance(60 * 20)
    assert(chatMatch(bob, "Reminder:.*Gnomeregan.* starts in 1%d minutes"), "bob reminded")
    assert(chatMatch(anna, "Reminder:"), "creator reminded")
    assert(not chatMatch(cara, "Reminder:"), "cara not reminded")
    local n = 0
    for _, l in ipairs(bob.log) do if l:find("Reminder:") then n = n + 1 end end
    w:advance(300)
    local n2 = 0
    for _, l in ipairs(bob.log) do if l:find("Reminder:") then n2 = n2 + 1 end end
    eq(n2, n, "reminded once")
end)

test("calendar: the tab and the New Event window", function()
    local w, anna, bob = setup()
    local UI = anna.ns.UI
    UI:Show("calendar")
    local p = UI.CalendarPanel()
    local dungeons, raids = UI.CalendarInstances("dungeon"), UI.CalendarInstances("raid")
    assert(#dungeons >= 25 and #raids >= 8, "dungeon and raid lists")
    eq(dungeons[1].name, "Hall of Thanes", "lowest level first")
    UI:OpenEventEditor(nil, nil)
    local ed = UI:BuildEventEditor()
    UI:SaveEventEditor() -- no dungeon picked yet
    assert(ed.error:GetText():find("Pick a dungeon"), "explains what's missing")
    eq(#anna.ns.Calendar:Upcoming(), 0, "nothing saved")
    -- pick a raid, date tomorrow, 9:30 PM
    ed.state.type = "raid"; ed.state.title = "Molten Core"
    ed.state.day = ed.state.day + 1; ed.state.hour = 9; ed.state.minute = 30; ed.state.pm = true
    UI:RefreshEventEditor()
    UI:SaveEventEditor()
    w:advance(2)
    local up = anna.ns.Calendar:Upcoming()
    eq(#up, 1, "event saved")
    eq(up[1].title, "Molten Core")
    eq(os.date("*t", up[1].time).hour, 21, "9 PM"); eq(os.date("*t", up[1].time).min, 30)
    assert(#bob.ns.Calendar:Upcoming() == 1, "bob has it")
    -- "other" with a name
    UI:OpenEventEditor(nil, nil)
    ed.state.type = "other"; UI:RefreshEventEditor()
    ed.titleInput:SetText("Guild photo"); ed.state.title = "Guild photo"
    ed.state.day = ed.state.day + 2
    UI:SaveEventEditor()
    w:advance(2)
    eq(#anna.ns.Calendar:Upcoming(), 2, "two events")
    -- render the tab: select a day, an event, sign-up buttons
    UI:SelectTab("calendar")
    p.details.buttons[2]:Click()
    p.cells[15]:Click()
    UI:Refresh()
    anna:slash("/fship events")
    assert(chatMatch(anna, "Upcoming events"), "/fship events")
    anna:slash("/fship calendar")
end)

test("window: sidebar badges, feed filters and the hideable member list", function()
    local w, anna, bob = setup()
    local UI = anna.ns.UI
    UI:Show("calendar")
    bob:slash("/fsay anyone around?")
    bob:fire("PLAYER_LEVEL_UP", 30)
    w:advance(2)
    UI:Refresh()
    local nav
    for _, f in ipairs(anna.frames) do if type(rawget(f, "nav")) == "table" then nav = f end end
    local chatBtn
    for _, f in ipairs(anna.frames) do if rawget(f, "id") == "chat" and rawget(f, "badge") then chatBtn = f end end
    assert(chatBtn and chatBtn.badge:IsShown(), "chat badge shown while on another page")
    eq(chatBtn.badge.text:GetText(), "2", "two new lines")
    -- an event waiting for an answer badges the calendar
    bob.ns.Calendar:Create({ time = bob.ns.Now() + 86400, type = "raid", title = "Molten Core" })
    w:advance(2)
    UI:SelectTab("chat")
    local calBtn
    for _, f in ipairs(anna.frames) do if rawget(f, "id") == "calendar" and rawget(f, "badge") then calBtn = f end end
    eq(calBtn.badge.text:GetText(), "1", "one event to answer")
    assert(not chatBtn.badge:IsShown(), "no chat badge while reading chat")
    UI:SelectTab("members")
    assert(not chatBtn.badge:IsShown(), "seen lines don't come back as new")
    -- filters
    local F = UI.FeedFilter
    local chat = { k = "C", d = { "hi" } }
    local lvl = { k = "M", d = { "level", "30" } }
    local loot = { k = "M", d = { "loot", "item:1", "X", "4" } }
    local mount = { k = "M", d = { "mount", "Horse", "1" } }
    assert(F(chat, "chat") and not F(lvl, "chat"), "chat filter")
    assert(F(lvl, "level") and F(loot, "loot") and F(mount, "other") and not F(loot, "other"), "other filters")
    assert(F(mount, "all"), "all")
    UI:SelectTab("chat")
    local p = UI.CalendarPanel and nil
    for _, f in ipairs(anna.frames) do if type(rawget(f, "filters")) == "table" then p = f end end
    p.filters[2]:Click() -- Chat only
    eq(anna.ns.settings.feedFilter, "chat", "filter remembered")
    local shown = table.concat(p.log._lines or {}, "\n")
    assert(shown:find("anyone around"), "chat line shown")
    assert(not shown:find("reached level"), "level line filtered out")
    p.toggleMembers:Click()
    eq(anna.ns.settings.feedMembers, false, "member list hidden")
    assert(not p.members:IsShown(), "member list hidden on screen")
end)

test("@mentions: tagged members hear a sound and see an alert; Tab completes names", function()
    local before = function(anna, bob, cara)
        for _, c in ipairs({ anna, bob, cara }) do
            c.globals = c.globals or {}
            c.globals.PlaySound = function() c.sounds = (c.sounds or 0) + 1 end
            c.globals.SOUNDKIT = { TELL_MESSAGE = 3081 }
            c.globals.FlashClientIcon = function() c.flashed = true end
            c.globals.UIErrorsFrame = { AddMessage = function(_, m) c.alert = m end }
        end
    end
    local w, anna, bob, cara = setup(before)
    bob:slash("/fs @anna want to run Gnomeregan?")
    w:advance(2)
    eq(anna.sounds, 1, "anna heard it"); assert(anna.flashed, "icon flashed")
    eq(anna.alert, "Bob Silvermoon mentioned you in Fellowship chat")
    assert(not cara.sounds, "cara wasn't tagged")
    assert(anna:logContains("|cffff9933@anna|r"), "tag highlighted")
    -- full name, and @all
    cara:slash("/fs @Bob Silvermoon thanks!")
    w:advance(2)
    eq(bob.sounds, 1, "bob tagged by full name")
    assert(bob:logContains("|cffff9933@Bob Silvermoon|r"), "full name highlighted")
    anna:slash("/fs @all dungeon in 10")
    w:advance(2)
    eq(bob.sounds, 2, "bob by @all"); eq(cara.sounds, 1, "cara by @all")
    eq(anna.sounds, 1, "you don't ping yourself")
    -- not a member: nothing happens, text stays as typed
    bob:slash("/fs email me @ home")
    bob:slash("/fs @Zed hi")
    w:advance(2)
    eq(anna.sounds, 1, "no ping for non-members")
    -- turned off
    anna.ns.settings.mentionAlert = false
    bob:slash("/fs @anna again")
    w:advance(2)
    eq(anna.sounds, 1, "setting turns it off")
    anna.ns.settings.mentionAlert = true
    -- Tab completion
    local Mn = anna.ns.Mentions
    eq(Mn.Complete("hey @b"), "hey @Bob ", "completes a first name")
    eq(Mn.Complete("hey @"), "hey @Bob ", "first match alphabetically, never yourself")
    eq(Mn.Complete("hey @zz"), nil, "no match")
    eq(Mn.Complete("hi there"), nil, "only after @")
    -- suggestions while typing
    local hits = Mn.Suggest("hey @b")
    eq(#hits, 1, "one member starts with b"); eq(hits[1].text, "hey @Bob ", "picking it fills the name")
    eq(#Mn.Suggest("hey @a"), 1, "your own characters aren't suggested, @all is")
    eq(#Mn.Suggest("mail me@b"), 0, "not inside a word")
    anna.ns.UI:Show("chat")
    local chat
    for _, f in ipairs(anna.frames) do if rawget(f, "mentionSuggest") then chat = f end end
    assert(chat, "chat panel has a suggestion list")
    local input = chat.input
    input:SetText("hey @"); input._scripts.OnTextChanged(input, true)
    assert(chat.mentionSuggest:IsShown(), "list pops up after @")
    input._scripts.OnEnterPressed(input)
    eq(input:GetText(), "hey @Bob ", "Enter picks the top suggestion instead of sending")
    assert(not chat.mentionSuggest:IsShown(), "list closes after picking")
    -- missed while offline: counted in the login summary
    anna.ns.Store:MarkRead(anna.ns.Store:ActiveId())
    anna:logout(); w:advance(5)
    bob:slash("/fs @anna are you coming tonight?")
    w:advance(2)
    anna:login(); w:advance(30)
    assert(anna:logContains("You were mentioned 1 time"), "away summary counts mentions")
end)

test("blocked actions are recorded and shown by /fship blocked", function()
    local w, anna = setup()
    anna:fire("ADDON_ACTION_FORBIDDEN", "OtherAddon", "CastSpellByName()")
    anna:fire("ADDON_ACTION_FORBIDDEN", "Fellowship", "ClearTarget()")
    anna:fire("ADDON_ACTION_BLOCKED", "Fellowship", "FocusUnit()")
    assert(anna:logContains("blocked Fellowship from using"), "tells the player once")
    anna:slash("/fship blocked")
    assert(anna:logContains("ClearTarget() (forbidden)"), "lists the forbidden call")
    assert(anna:logContains("FocusUnit() (blocked)"), "lists the blocked call")
    assert(not anna:logContains("CastSpellByName"), "ignores other addons")
end)

test("UI builds and renders without errors", function()
    local w, anna, bob, cara = setup()
    bob:slash("/fsay hi")
    w:advance(2)
    anna:slash("/fs")
    anna.ns.Wishlist:Add("|cffa335ee|Hitem:900:4::|h[Epic Bow]|h|r")
    for _, tab in ipairs({ "chat", "feats", "members", "wishlist", "calendar" }) do anna.ns.UI:SelectTab(tab) end
    anna.ns.UI.panelsForTest = nil
    anna:slash("/fship wish")
    w:advance(1)
    anna:slash("/fship who")
    anna:slash("/fship help")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
