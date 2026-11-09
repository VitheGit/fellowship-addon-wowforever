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
    anna:slash("/fship invite bob")
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
    assert(solo:logContains("Solo|r: |cff4fd1b5Hi!|r"), "own message not echoed in chat color")
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
    anna:slash("/fship create Crew"); anna:slash("/fship invite bob"); w:advance(1)
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
    anna:slash("/fship invite dan"); w:advance(1)
    dan:acceptPopup("FELLOWSHIP_INVITE"); w:advance(60)
    eq(dan.ns.Store:GetClass("Bob-Silvermoon"), "MAGE")
    eq(anna.ns.Store:GetClass("Dan-Silvermoon"), "WARRIOR")
    assert(anna:logContains("|cffaad372Anna|r: |cff4fd1b5hi from anna"), "anna's own line not hunter green")
    assert(dan.ns.FormatEvent({ a = "Bob-Silvermoon", k = "C", d = { "x" } }):find("|cff3fc7ebBob|r", 1, true), "bob not mage blue")
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
        target = { name = "Bob", player = true, faction = "Alliance" },
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
    -- name clicked in chat, cross-realm
    b = anna:openMenu("MENU_UNIT_FRIEND", { name = "Cara", server = "Area52" })
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
    assert(bob:logContains("Anna|r  |cffffd100Admin"), "who output lost")
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
    bob:slash("/fship invite dan"); w:advance(2)
    eq(#dan.popups, 0, "member's invite went out")
    assert(bob:logContains("Only the Admin"), "no explanation")
    bob:slash("/fship promote cara-Area52")
    w:advance(2)
    eq(role(cara, "Cara-Area52"), "member", "non-admin promoted someone")
    anna:slash("/fship promote bob")
    w:advance(2)
    eq(role(cara, "Bob-Silvermoon"), "inviter", "cara sees bob as inviter")
    assert(canInvite(bob))
    bob:slash("/fship invite dan"); w:advance(1)
    assert(dan:acceptPopup("FELLOWSHIP_INVITE"), "inviter's invite failed"); w:advance(30)
    eq(role(anna, "Dan-Silvermoon"), "member")
    anna:slash("/fship demote bob"); w:advance(2)
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
    anna:slash("/fship remove bob"); w:advance(2)
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
    anna:fire("PLAYER_DEAD"); w:advance(2)
    assert(showsInChat(bob, "|cffff4040 was killed in Elwynn Forest|r"), "death")
end)

test("announcements: share and show settings", function()
    local w, anna, bob = setup()
    anna.ns.settings.shareDeaths = false
    anna:fire("PLAYER_DEAD"); w:advance(2)
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
    assert(anna:logContains("Cara|r |cff9d9d9dwent offline."), "no offline notice")
    cara:login(); w:advance(10)
    assert(anna:logContains("Cara|r |cff33ff99came online."), "no online notice")
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

test("Members tab lists every member and the title count matches", function()
    local w, anna, bob, cara = setup()
    anna:slash("/fs")
    anna.ns.UI:SelectTab("members")
    -- find the members font string: the one whose text has the online count
    local found
    for _, f in ipairs(anna.frames) do
        local list = rawget(f, "list")
        if type(list) == "table" and type(list._text) == "string" and list._text:find("online") then
            found = list._text
        end
    end
    assert(found, "members text not found")
    assert(found:find("3 of 3 online", 1, true), found)
    for _, n in ipairs({ "Anna", "Bob", "Cara" }) do assert(found:find(n .. "|r", 1, true), n .. " missing: " .. found) end
    local title
    for _, f in ipairs(anna.frames) do
        local t = rawget(f, "title")
        if type(t) == "table" and type(t._text) == "string" and t._text:find("online") then title = t._text end
    end
    assert(title and title:find("3 of 3 online", 1, true), tostring(title))
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
    anna:slash("/fship promote bob"); w:advance(2)
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
    assert(anna:logContains("Bobalt|r |cff808080(Bob)|r: "), "alt name not shown with main")
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
    anna:slash("/fship invite dan"); w:advance(1); dan:acceptPopup("FELLOWSHIP_INVITE"); w:advance(30)
    dan:logout(); danalt:login(); w:advance(1)
    anna:slash("/fship invite danalt"); w:advance(1); danalt:acceptPopup("FELLOWSHIP_INVITE"); w:advance(60)
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
    anna:slash("/fship admin bob"); w:advance(2)
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
    anna:slash("/fship admin bob"); w:advance(2)
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
    assert(text:find("|cffaad372Anna|r |cffffd100*|r", 1, true), "admin anna not marked/colored: " .. text)
    assert(text:find("|cff6e6e6eCara|r", 1, true), "offline cara not grey: " .. text)
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

test("UI builds and renders without errors", function()
    local w, anna, bob, cara = setup()
    bob:slash("/fsay hi")
    w:advance(2)
    anna:slash("/fs")
    for _, tab in ipairs({ "chat", "achievements", "members" }) do anna.ns.UI:SelectTab(tab) end
    w:advance(1)
    anna:slash("/fship who")
    anna:slash("/fship help")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
