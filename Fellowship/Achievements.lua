-- Achievements: share achievements and level-ups with the fellowship.
local _, ns = ...
local A = {}
ns.Achievements = A

function A:Init()
    ns.On("ACHIEVEMENT_EARNED", function(id, alreadyEarned) A:OnEarned(id, alreadyEarned) end)
    ns.On("PLAYER_LEVEL_UP", function(level) A:OnLevelUp(level) end)
end

function A:OnEarned(id, alreadyEarned)
    -- alreadyEarned is true for account-wide achievements another character already has
    if alreadyEarned or not id or not GetAchievementInfo then return end
    local _, name, points, _, _, _, _, _, _, _, _, isGuild = GetAchievementInfo(id)
    if not name or isGuild then return end
    ns.Sync:Publish("A", { id, name, points or 0 })
end

function A:OnLevelUp(level)
    if not ns.settings.shareLevels or not level then return end
    ns.Sync:Publish("M", { "level", level })
end
