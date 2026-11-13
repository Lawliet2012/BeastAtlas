-- Chat tips: what the main pet can learn after a level-up, useful beasts on entering a zone,
-- and a reminder when a pet other than the main one is out. All gated by ns.db.notify.
local _, ns = ...
local L = ns.L
local S = ns.STATUS

local function Enabled()
    return ns.isHunter and ns.db and ns.db.notify
end

-- Nearest teacher of a rank the hunter can tame now; beasts without a distance rank last.
local function NearestTeacher(rk, playerLevel, cont, px, py)
    local bestId, bestD
    for _, id in ipairs(rk.beasts or {}) do
        local b = ns.BEASTS[id]
        if b and b.l[1] <= playerLevel then
            local d = cont and ns.BeastDistance(id, cont, px, py)
            if not bestId or (d and (not bestD or d < bestD)) then
                bestId, bestD = id, d
            end
        end
    end
    return bestId, bestD
end

ns.On("MAIN_LEVEL", function(old, new)
    if not Enabled() then return end
    local main = ns.cdb and ns.cdb.main
    if not main or not old or not new then return end
    local playerLevel = ns.Ctx().playerLevel
    local cont, px, py = ns.PlayerWorldPos()
    local lines = {}
    for _, entry in ipairs(ns.ABILITIES) do
        local ab = ns.Ability(entry.key) -- makes sure maxRank and rank.beasts are built
        if ab and not ab.trainer and ns.FamilyCanLearn(ab, main.family) then
            for r = 1, ab.maxRank do
                local rk = ab.ranks[r]
                if rk and old < rk.lvl and rk.lvl <= new then
                    local label = (ns.Names(ab)) .. " " .. r
                    if ns.KnownRank(ab.key) >= r then
                        lines[#lines + 1] = L.NOTIFY_TRAIN:format(label)
                    else
                        local id, d = NearestTeacher(rk, playerLevel, cont, px, py)
                        if id then
                            local b = ns.BEASTS[id]
                            local where = ns.ZoneName(b.z)
                            if d then where = where .. ", " .. L.YARDS:format(math.floor(d + 0.5)) end
                            lines[#lines + 1] = L.NOTIFY_LEARN:format(label, (ns.Names(b)), where)
                        else
                            lines[#lines + 1] = L.NOTIFY_NO_TEACHER:format(label)
                        end
                    end
                end
            end
        end
    end
    if #lines == 0 then return end
    ns.Print(L.NOTIFY_LEVEL:format(main.name, new))
    for _, line in ipairs(lines) do print(line) end
end)

local announced = {} -- [uiMapID] = true, per session

local function ZoneTip()
    if not Enabled() then return end
    local mapID = ns.PlayerZoneMap()
    if not mapID or announced[mapID] then return end
    local n, seen, names = 0, {}, {}
    for _, id in ipairs(ns.BeastsOnMap(mapID) or {}) do
        local best, list = ns.BeastUseful(id)
        if best == S.READY then
            n = n + 1
            for _, e in ipairs(list) do
                if e.status == S.READY then
                    local ab = ns.Ability(e.key)
                    local s = (ns.Names(ab)) .. " " .. e.rank
                    if not seen[s] then
                        seen[s] = true
                        names[#names + 1] = s
                    end
                end
            end
        end
    end
    if n > 0 then
        local shown = {}
        for i = 1, math.min(4, #names) do shown[i] = names[i] end
        local text = table.concat(shown, ", ")
        if #names > 4 then text = text .. ", " .. L.AND_MORE end
        ns.Print(L.NOTIFY_ZONE:format(n, text))
    end
    announced[mapID] = true
end

local function QueueZoneTip()
    C_Timer.After(2, ZoneTip)
end

ns.On("OTHER_PET", function(activeName, mainName)
    if not Enabled() then return end
    ns.Print(L.OTHER_PET:format(activeName, mainName))
end)

local f = CreateFrame("Frame")
f:SetScript("OnEvent", QueueZoneTip)
ns.On("LOGIN", function()
    if not ns.isHunter then return end
    f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    C_Timer.After(5, QueueZoneTip)
end)
