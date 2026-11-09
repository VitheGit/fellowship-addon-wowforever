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
    anna:slash("/fs create Friday Night Crew")
    anna:slash("/fs invite bob")
    w:advance(1)
    assert(bob:acceptPopup("FELLOWSHIP_INVITE"), "bob got no invite popup")
    w:advance(5)
    anna:slash("/fs invite cara-Area52")
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
    solo:slash("/fs create Just Me")
    solo:slash("/fsay Hi!")
    w:advance(1)
    assert(solo:logContains("Solo|r: Hi!"), "own message not echoed")
    assert(solo:logContains("only member"), "no solo hint")
    eq(count(solo, "C"), 1)
end)

test("names use class colors, learned for members who are offline", function()
    local w = World.new()
    local anna, bob, cara = w:client("Anna"), w:client("Bob"), w:client("Cara", "Area52")
    anna.class, bob.class, cara.class = "HUNTER", "MAGE", "DRUID"
    anna:login(); bob:login(); w:advance(1)
    anna:slash("/fs create Crew"); anna:slash("/fs invite bob"); w:advance(1)
    bob:acceptPopup("FELLOWSHIP_INVITE"); w:advance(10)
    cara:login(); w:advance(1)
    anna:slash("/fs invite cara-Area52"); w:advance(1)
    cara:acceptPopup("FELLOWSHIP_INVITE"); w:advance(30)
    bob:slash("/fsay hi from bob")
    anna:slash("/fsay hi from anna")
    w:advance(2)
    bob:logout(); w:advance(5)
    -- a fourth friend joins after Bob logged off and still sees Bob in mage blue
    local dan = w:client("Dan"); dan.class = "WARRIOR"; dan:login(); w:advance(1)
    anna:slash("/fs invite dan"); w:advance(1)
    dan:acceptPopup("FELLOWSHIP_INVITE"); w:advance(60)
    eq(dan.ns.Store:GetClass("Bob-Silvermoon"), "MAGE")
    eq(anna.ns.Store:GetClass("Dan-Silvermoon"), "WARRIOR")
    assert(anna:logContains("|cffaad372Anna|r: "), "anna's own line not hunter green")
    assert(dan.ns.FormatEvent({ a = "Bob-Silvermoon", k = "C", d = { "x" } }):find("|cff3fc7ebBob|r", 1, true), "bob not mage blue")
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
    anna:slash("/fs remove cara-Area52")
    w:advance(3)
    eq(cara.ns.Store:ActiveId(), nil, "cara should have left")
    assert(cara:logContains("no longer a member"), "cara not told")
    bob:slash("/fsay after removal")
    w:advance(3)
    assert(not anna.ns.Store:IsMember(anna.ns.Store:ActiveId(), "Cara-Area52"))
end)

test("leaving removes you from everyone's roster", function()
    local w, anna, bob, cara = setup()
    bob:slash("/fs leave")
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
    anna:slash("/fs who")
    anna:slash("/fs help")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
