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
local function setup()
    local w = World.new()
    local anna, bob, cara = w:client("Anna"), w:client("Bob"), w:client("Cara", "Area52")
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
        local t = rawget(f, "title")
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
        if bob.log[i]:find("Fellowship Achievement:", 1, true) then shown = shown + 1 end
    end
    eq(shown, 1, "announced once in bob's chat")
    assert(bob:logContains("[Deadmines (Normal)]"), "title in chat")
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
    eq(#bob:history(), stored + 1, "only the dungeon announcement is new") -- the normal dungeon line
    anna.instance = { name = "Molten Core", type = "raid", difficulty = "Normal", id = 409, bosses = { 21, 22 } }
    anna:fire("ZONE_CHANGED_NEW_AREA")
    joinGroup(anna, { bob, cara }, true)
    anna:fire("ENCOUNTER_END", 22, "Ragnaros", 14, 20, 1); w:advance(3)
    local earned, count = feats(cara)
    eq(count, 2, "raid achievement")
    eq(earned["raid|molten core|normal"].category, "raid", "raid category")
    assert(cara:logContains("cleared |cffffd100[Molten Core (Normal)]"), "raid announced")
    -- achievements survive pruning and reach someone who joins later
    anna.ns.settings.maxEvents = 1
    anna.ns.Store:Prune(anna.ns.Store:ActiveId())
    eq(select(2, feats(anna)), 2, "pruned")
    -- Achievements tab renders, earned first then the journal's unearned ones
    anna.env.EJ_GetInstanceByIndex = function(i, isRaid)
        local list = isRaid and { "Molten Core", "Onyxia's Lair" } or { "Deadmines", "Wailing Caverns" }
        if list[i] then return i, list[i] end
    end
    local rows, got, todo = anna.ns.Feats:Rows(anna.ns.Store:ActiveId())
    eq(got, 2, "earned rows"); eq(todo, 2, "unearned rows")
    eq(rows[1].title, "Molten Core (Normal)", "newest first")
    eq(rows[3].title, "Wailing Caverns", "dungeons before raids in the not-yet list")
    anna:slash("/fs")
    anna.ns.UI:SelectTab("feats")
end)

test("UI builds and renders without errors", function()
    local w, anna, bob, cara = setup()
    bob:slash("/fsay hi")
    w:advance(2)
    anna:slash("/fs")
    for _, tab in ipairs({ "chat", "achievements", "feats", "members" }) do anna.ns.UI:SelectTab(tab) end
    w:advance(1)
    anna:slash("/fship who")
    anna:slash("/fship help")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
