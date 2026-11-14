local ADDON, ns = ...
local L = ns.L

BeastAtlas = ns -- public handle for macros / other addons

local DEFAULTS = {
    mapPins = true,     -- beasts on the world map
    areasAlways = false, -- habitat areas of every beast at once (otherwise only under the mouse)
    stables = true,      -- stable masters on the map
    trainers = true,    -- pet trainer NPCs on the world map
    petOnly = true,     -- only abilities the main pet's family can learn
    showLearned = false,
    lookahead = 6,      -- also show ranks this many levels ahead
    names = "both",     -- "both" or "local"
    notify = true,      -- chat tips
    helper = true,      -- training helper panel
    helperPos = {},
    scale = 1.0,        -- window scale
    minimap = { angle = 215, hide = false },
    window = {},
    observed = {},      -- the player's own tame observations (Collect.lua)
    familyNames = {},   -- localized family name (lower case) -> family key, learned from known beasts
}

ns.STATUS = { READY = 1, SOON = 2, LATER = 3, LEARNED = 4, OBSOLETE = 5 }
local S = ns.STATUS
ns.STATUS_COLOR = {
    [S.READY] = { 0.30, 1.00, 0.30 },
    [S.SOON] = { 1.00, 0.82, 0.10 },
    [S.LATER] = { 0.62, 0.62, 0.62 },
    [S.LEARNED] = { 0.38, 0.38, 0.38 },
    [S.OBSOLETE] = { 0.45, 0.45, 0.45 },
}
function ns.StatusHex(st)
    local c = ns.STATUS_COLOR[st] or ns.STATUS_COLOR[S.LATER]
    return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
end

ns.callbacks = {}
function ns.On(name, fn) ns.callbacks[name] = ns.callbacks[name] or {}; table.insert(ns.callbacks[name], fn) end
function ns.Fire(name, ...)
    for _, fn in ipairs(ns.callbacks[name] or {}) do fn(...) end
end

function ns.Print(msg) print("|cffabd473" .. L.TITLE .. "|r: " .. tostring(msg)) end

local function IsSecret(v) return issecretvalue and issecretvalue(v) or false end
ns.IsSecret = IsSecret

-------------------------------------------------------------------------------
-- Context (cached until ns.Changed())
-------------------------------------------------------------------------------
local ctxCache

function ns.Ctx()
    if ctxCache then return ctxCache end
    local playerLevel = UnitLevel("player")
    if IsSecret(playerLevel) then playerLevel = nil end
    playerLevel = playerLevel or 1
    local main = ns.cdb and ns.cdb.main
    ctxCache = {
        playerLevel = playerLevel,
        main = main,
        petLevel = main and main.level or playerLevel,
        family = main and main.family or nil,
        look = ns.db and ns.db.lookahead or 0,
        plan = {},
        info = {},
    }
    return ctxCache
end

-- The one invalidation entry point; consumers debounce their own redraw.
function ns.Changed()
    ctxCache = nil
    ns.Fire("CHANGED")
end

-------------------------------------------------------------------------------
-- Indexes (built once, on first use; dropped by ns.RebuildIndexes)
-------------------------------------------------------------------------------
local abilityByKey, abilityByName
local function BuildAbilityIndex()
    abilityByKey, abilityByName = {}, {}
    for i, ab in ipairs(ns.ABILITIES) do
        ab.order = i
        ab.maxRank = 0
        for r in pairs(ab.ranks) do if r > ab.maxRank then ab.maxRank = r end end
        abilityByKey[ab.key] = ab
        abilityByName[ns.Lower(ab.en)] = ab
        if ab.ru then abilityByName[ns.Lower(ab.ru)] = ab end
        -- teaching beasts per rank
        for _, rank in pairs(ab.ranks) do rank.beasts = {} end
    end
    -- Other client languages: the game's own names of the rank spells are accepted too.
    if C_Spell and C_Spell.GetSpellName then
        for _, ab in ipairs(ns.ABILITIES) do
            for _, rank in pairs(ab.ranks) do
                if rank.spell then
                    local ok, name = pcall(C_Spell.GetSpellName, rank.spell)
                    if ok and type(name) == "string" and name ~= "" and not IsSecret(name) then
                        local k = ns.Lower(name)
                        if not abilityByName[k] then abilityByName[k] = ab end
                    end
                end
            end
        end
    end
    for id, b in pairs(ns.BEASTS) do
        b.id = id
        for i = 1, #b.t, 2 do
            local ab = abilityByKey[b.t[i]]
            local rank = ab and ab.ranks[b.t[i + 1]]
            if rank then table.insert(rank.beasts, id) end
        end
    end
    for _, ab in ipairs(ns.ABILITIES) do
        for _, rank in pairs(ab.ranks) do
            table.sort(rank.beasts, function(a, b) return ns.BEASTS[a].l[1] < ns.BEASTS[b].l[1] end)
        end
    end
end

function ns.Ability(key)
    if not abilityByKey then BuildAbilityIndex() end
    return abilityByKey[key]
end

-- Ability by any localized/English spell name (case-insensitive).
function ns.AbilityByName(name)
    if not abilityByKey then BuildAbilityIndex() end
    if not name or IsSecret(name) then return nil end
    return abilityByName[ns.Lower(name)]
end

-- Family key from a localized family name (UnitCreatureFamily result).
local familyByName
function ns.FamilyKey(localName)
    if not localName or IsSecret(localName) then return nil end
    if not familyByName then
        familyByName = {}
        for key, f in pairs(ns.FAMILIES) do
            familyByName[ns.Lower(f.en)] = key
            if f.ru then familyByName[ns.Lower(f.ru)] = key end
        end
    end
    local k = ns.Lower(localName)
    return familyByName[k] or (ns.db and ns.db.familyNames and ns.db.familyNames[k]) or nil
end

-- Remembers what this client calls a family (seen on a beast whose family the data knows).
function ns.LearnFamily(localName, key)
    if not localName or IsSecret(localName) or localName == "" or not ns.FAMILIES[key] then return end
    if ns.FamilyKey(localName) or not (ns.db and ns.db.familyNames) then return end
    ns.db.familyNames[ns.Lower(localName)] = key
end

function ns.FamilyIcon(key)
    local f = key and ns.FAMILIES[key]
    return "Interface\\Icons\\" .. (f and f.icon or "ability_hunter_beasttaming")
end

function ns.FamilyCanLearn(ab, family)
    if not family then return true end
    for _, f in ipairs(ab.families) do
        if f == "*" or f == family then return true end
    end
    return false
end

-------------------------------------------------------------------------------
-- Zones -> uiMapID
-------------------------------------------------------------------------------
local mapNameIndex
local function BuildMapNameIndex()
    mapNameIndex = {}
    if not (C_Map and C_Map.GetMapChildrenInfo) then return end
    for _, root in ipairs({ 947, 1414, 1415 }) do
        pcall(function()
            for _, info in ipairs(C_Map.GetMapChildrenInfo(root, nil, true) or {}) do
                if info.name and not mapNameIndex[ns.Lower(info.name)] then
                    mapNameIndex[ns.Lower(info.name)] = info.mapID
                end
            end
        end)
    end
end

local function MapExists(mapID)
    if not (C_Map and C_Map.GetMapInfo) then return false end
    local ok, info = pcall(C_Map.GetMapInfo, mapID)
    return ok and type(info) == "table"
end

local zoneMapCache = {}
function ns.ZoneMap(zone)
    if not zone then return nil end
    local cached = zoneMapCache[zone]
    if cached ~= nil then return cached or nil end
    local z = ns.ZONES[zone]
    local mapID = z and z.map
    -- The hard-coded id is trusted only if this client knows that map.
    if mapID and not MapExists(mapID) then mapID = nil end
    if not mapID and z and z.area and C_Map and C_Map.GetAreaInfo then
        -- New / unknown zone: match the localized area name against the map list.
        local areaName = C_Map.GetAreaInfo(z.area)
        if areaName and not IsSecret(areaName) then
            if not mapNameIndex then BuildMapNameIndex() end
            mapID = mapNameIndex[ns.Lower(areaName)]
        end
    end
    zoneMapCache[zone] = mapID or false
    return mapID
end

local zoneNameCache = {}
function ns.ZoneName(zone)
    if not zone then return L.ZONE_UNKNOWN end
    local cached = zoneNameCache[zone]
    if cached then return cached end
    local name
    local mapID = ns.ZoneMap(zone)
    local info = mapID and C_Map.GetMapInfo(mapID)
    if info and info.name and not IsSecret(info.name) then name = info.name end
    if not name then
        local z = ns.ZONES[zone]
        local areaName = z and z.area and C_Map and C_Map.GetAreaInfo and C_Map.GetAreaInfo(z.area)
        if areaName and not IsSecret(areaName) then name = areaName end
    end
    name = name or zone
    zoneNameCache[zone] = name
    return name
end

local mapToZone
function ns.ZoneByMap(mapID)
    if not mapID then return nil end
    if not mapToZone then
        mapToZone = {}
        local names = {}
        for zone in pairs(ns.ZONES) do names[#names + 1] = zone end
        table.sort(names) -- deterministic winner when two zones share a map
        for _, zone in ipairs(names) do
            local m = ns.ZoneMap(zone)
            if m and not mapToZone[m] then mapToZone[m] = zone end
        end
    end
    return mapToZone[mapID]
end

local byMap
function ns.BeastsByMap()
    if not byMap then
        byMap = {}
        for id, b in pairs(ns.BEASTS) do
            local m = #b.c > 0 and ns.ZoneMap(b.z)
            if m then
                byMap[m] = byMap[m] or {}
                table.insert(byMap[m], id)
            end
        end
    end
    return byMap
end

function ns.BeastsOnMap(mapID)
    return ns.BeastsByMap()[mapID]
end

-- Service NPCs (pet trainers, stable masters): only those the player's faction can use.
local function PlayerSide()
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    if IsSecret(faction) then faction = nil end
    return faction == "Alliance" and "A" or faction == "Horde" and "H" or nil
end

-- an unknown player faction shows every NPC rather than none
local function ForMySide(t, side)
    return not t.side or not side or t.side == side
end

-- [uiMapID] = { npcId, ... } for the entries of src whose zone has a map in this client
local function ServicesByMap(src)
    local out, side = {}, PlayerSide()
    for id, t in pairs(src or {}) do
        local m = ForMySide(t, side) and ns.ZoneMap(t.z)
        if m then
            out[m] = out[m] or {}
            table.insert(out[m], id)
        end
    end
    return out
end

-- Pet trainers / stable masters on a zone map: { npcId, ... } | nil. Built once (reset at login).
local trainersByMap, stablesByMap
function ns.TrainersOnMap(mapID)
    trainersByMap = trainersByMap or ServicesByMap(ns.TRAINERS)
    return trainersByMap[mapID]
end

function ns.StablesOnMap(mapID)
    stablesByMap = stablesByMap or ServicesByMap(ns.STABLES)
    return stablesByMap[mapID]
end

-- Map the player is on, with micro maps (caves, buildings) folded into their parent.
function ns.PlayerZoneMap()
    if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID or IsSecret(mapID) then return nil end
    if C_Map.GetMapInfo and Enum and Enum.UIMapType then
        local info = C_Map.GetMapInfo(mapID)
        local steps = 0
        while info and info.mapType == Enum.UIMapType.Micro and info.parentMapID and info.parentMapID > 0
            and steps < 10 do
            mapID = info.parentMapID
            info = C_Map.GetMapInfo(mapID)
            steps = steps + 1
        end
    end
    return mapID
end

-------------------------------------------------------------------------------
-- Known ranks, plan and statuses (§2.3)
-------------------------------------------------------------------------------
-- Highest rank the hunter has learned (and can teach to any pet).
function ns.KnownRank(key)
    return ns.cdb and ns.cdb.known[key] or 0
end

-- Highest rank that needs no more work for the main pet: learned by the hunter, or already on the pet
-- (a tamed pet can come with ranks the hunter never learned).
function ns.HaveRank(key)
    local known = ns.KnownRank(key)
    local main = ns.cdb and ns.cdb.main
    local onPet = main and main.ranks and main.ranks[key] or 0
    return onPet > known and onPet or known
end

-- Is some beast teaching this rank tameable at the given hunter level? (beasts are sorted by level)
-- With onMap, only beasts that can be shown on a zone map count (not dungeon-only ones).
local function TeacherAt(rank, level, onMap)
    for _, id in ipairs(rank.beasts or {}) do
        local b = ns.BEASTS[id]
        if b.l[1] > level then return false end
        if not onMap or (#b.c > 0 and ns.ZoneMap(b.z)) then return true end
    end
    return false
end

function ns.Plan(key)
    local ctx = ns.Ctx()
    local p = ctx.plan[key]
    if p then return p end
    local known = ns.HaveRank(key)
    local ab = ns.Ability(key)
    local target, alt
    if ab and not ab.trainer then
        for r = ab.maxRank, known + 1, -1 do
            local rk = ab.ranks[r]
            if rk and rk.lvl <= ctx.petLevel then
                if not target then
                    if TeacherAt(rk, ctx.playerLevel) then
                        target = r
                        -- every teacher of the best rank is off the map (a dungeon): the best rank that can
                        -- be learned outdoors stays worth showing as well
                        if TeacherAt(rk, ctx.playerLevel, true) then break end
                    end
                elseif TeacherAt(rk, ctx.playerLevel, true) then
                    alt = r
                    break
                end
            end
        end
    end
    p = { known = known, hunter = ns.KnownRank(key), target = target, alt = alt }
    ctx.plan[key] = p
    return p
end

function ns.RankStatus(key, rank)
    local ab = ns.Ability(key)
    if not ab then return S.LATER end
    local p = ns.Plan(key)
    if rank <= p.known then return S.LEARNED end
    if ab.trainer then return S.LATER end
    local rk = ab.ranks[rank]
    if not rk then return S.LATER end
    if p.target then
        if rank == p.target or rank == p.alt then return S.READY end
        if rank < p.target then return S.OBSOLETE end
    end
    local ctx = ns.Ctx()
    if rk.lvl <= ctx.petLevel then
        -- usable, but no teacher is tameable yet
        return TeacherAt(rk, ctx.playerLevel + ctx.look) and S.SOON or S.LATER
    end
    return rk.lvl <= ctx.petLevel + ctx.look and S.SOON or S.LATER
end

-- Status of learning a rank from one specific beast: the hunter must also be able to tame it
-- (beasts above your level can't be tamed). Returns status and the tame level if that's what blocks.
function ns.BeastRankStatus(id, key, rank)
    local st = ns.RankStatus(key, rank)
    if st == S.LEARNED or st == S.OBSOLETE then return st end
    local b = ns.BEASTS[id]
    local ctx = ns.Ctx()
    if not b or b.l[1] <= ctx.playerLevel then return st end
    local tame = (b.l[1] <= ctx.playerLevel + ctx.look) and S.SOON or S.LATER
    return math.max(st, tame), b.l[1]
end

function ns.StatusNote(st, key, rank, tameLevel)
    if st == S.LEARNED then return L.LEARNED end
    if st == S.OBSOLETE then return L.OBSOLETE end
    if tameLevel then return L.TAME_AT:format(tameLevel) end
    if st == S.READY then return L.NEW end
    local ab = ns.Ability(key)
    local rk = ab and ab.ranks[rank]
    if rk and rk.lvl > ns.Ctx().petLevel then return L.SOON:format(rk.lvl) end
    if not rk or #rk.beasts == 0 then return L.NO_SOURCE end
    return L.NO_TAMEABLE
end

-- Does the current filter want this ability at all?
function ns.AbilityPassesFilter(ab)
    if ab.trainer then return false end
    local family = ns.Ctx().family
    if ns.db.petOnly and family and not ns.FamilyCanLearn(ab, family) then return false end
    return true
end

local function BuildBeastInfo(id)
    local b = ns.BEASTS[id]
    if not b then return nil end
    local list, best = {}, nil
    for i = 1, #b.t, 2 do
        local key, rank = b.t[i], b.t[i + 1]
        local ab = ns.Ability(key)
        if ab and ns.AbilityPassesFilter(ab) then
            local st, tame = ns.BeastRankStatus(id, key, rank)
            if st ~= S.LEARNED or ns.db.showLearned then
                list[#list + 1] = { key = key, rank = rank, status = st, tame = tame }
                if st ~= S.OBSOLETE and (not best or st < best) then best = st end
            end
        end
    end
    if #list == 0 then return nil end
    return { best = best or S.OBSOLETE, list = list }
end

-- Best status of what a beast teaches, plus the list of {key, rank, status, tame}.
-- Memoised per context: callers must not modify the list.
function ns.BeastInfo(id)
    local info = ns.Ctx().info
    local e = info[id]
    if e == nil then
        e = BuildBeastInfo(id) or false
        info[id] = e
    end
    if e then return e.best, e.list end
    return nil
end

-- Useful = shows on the map / nearby list with the current filters.
function ns.BeastUseful(id)
    local best, list = ns.BeastInfo(id)
    if best == S.READY or best == S.SOON or (best == S.LEARNED and ns.db.showLearned) then
        return best, list
    end
    return nil
end

-------------------------------------------------------------------------------
-- Distances (world coordinates, yards)
-------------------------------------------------------------------------------
local worldCache = {}
local function WorldPos(mapID, x, y)
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))
    if not ok or not cont or not pos then return nil end
    return cont, pos.x, pos.y
end

-- { { cont, wx, wy, clusterIndex, radiusYd }, ... } for the habitat clusters of a beast
function ns.BeastWorldSpots(id)
    local spots = worldCache[id]
    if spots then return spots end
    spots = {}
    local b = ns.BEASTS[id]
    local mapID = b and #b.c > 0 and ns.ZoneMap(b.z)
    if mapID then
        for i = 1, #b.c, 3 do
            local x, y, r = b.c[i] / 1000, b.c[i + 1] / 1000, (b.c[i + 2] or 0) / 1000
            local cont, wx, wy = WorldPos(mapID, x, y)
            if cont then
                local radius = 0
                local econt, ex, ey = WorldPos(mapID, x + r, y)
                if econt == cont then radius = math.sqrt((ex - wx) ^ 2 + (ey - wy) ^ 2) end
                spots[#spots + 1] = { cont, wx, wy, i, radius }
            end
        end
    end
    worldCache[id] = spots
    return spots
end

function ns.PlayerWorldPos()
    if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID or IsSecret(mapID) then return nil end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil end
    local x, y = pos.x, pos.y
    if pos.GetXY then x, y = pos:GetXY() end
    if not x or IsSecret(x) then return nil end
    return WorldPos(mapID, x, y)
end

-- Distance in yards to the edge of the nearest habitat of a beast (0 inside it), and the cluster index.
function ns.BeastDistance(id, cont, px, py)
    if not cont then return nil end
    local best, bestIdx
    for _, s in ipairs(ns.BeastWorldSpots(id)) do
        if s[1] == cont then
            local d = math.max(0, math.sqrt((s[2] - px) ^ 2 + (s[3] - py) ^ 2) - s[5])
            if not best or d < best then best, bestIdx = d, s[4] end
        end
    end
    return best, bestIdx
end

function ns.DistanceText(d)
    if not d then return nil end
    if d == 0 then return L.HERE end
    if d >= 1000 then return L.KYARDS:format(d / 1000) end
    return L.YARDS:format(d)
end

-------------------------------------------------------------------------------
-- Stable masters: the nearest one, as the crow flies (the atlas knows no roads)
-------------------------------------------------------------------------------
-- { { cont, wx, wy, npcId, spot }, ... } for every stable master the player can use. Built once (reset at login).
local stableSpots
local function StableSpots()
    if stableSpots then return stableSpots end
    stableSpots = {}
    local side = PlayerSide()
    for id, t in pairs(ns.STABLES or {}) do
        local mapID = ForMySide(t, side) and ns.ZoneMap(t.z)
        if mapID then
            for spot = 1, #t.c, 2 do
                local cont, wx, wy = WorldPos(mapID, t.c[spot] / 1000, t.c[spot + 1] / 1000)
                if cont then stableSpots[#stableSpots + 1] = { cont, wx, wy, id, spot } end
            end
        end
    end
    return stableSpots
end

-- Nearest stable master to a point of the world: npcId, spot, yards. nil when none is known on that continent.
function ns.NearestStable(cont, x, y)
    if not cont then return nil end
    local best, bestId, bestSpot
    for _, s in ipairs(StableSpots()) do
        if s[1] == cont then
            local d = math.sqrt((s[2] - x) ^ 2 + (s[3] - y) ^ 2)
            if not best or d < best then best, bestId, bestSpot = d, s[4], s[5] end
        end
    end
    return bestId, bestSpot, best
end

function ns.NearestStableToPlayer()
    return ns.NearestStable(ns.PlayerWorldPos())
end

-- The stable master closest to any habitat of a beast: npcId, spot, yards from the edge of that habitat.
function ns.NearestStableToBeast(beastId)
    local best, bestId, bestSpot
    for _, h in ipairs(ns.BeastWorldSpots(beastId)) do
        for _, s in ipairs(StableSpots()) do
            if s[1] == h[1] then
                local d = math.max(0, math.sqrt((s[2] - h[2]) ^ 2 + (s[3] - h[3]) ^ 2) - h[5])
                if not best or d < best then best, bestId, bestSpot = d, s[4], s[5] end
            end
        end
    end
    return bestId, bestSpot, best
end

-- Yards from the player to one spot of a stable master; nil on another continent or with no position.
function ns.StableDistance(id, spot)
    local cont, px, py = ns.PlayerWorldPos()
    if not cont then return nil end
    spot = spot or 1
    for _, s in ipairs(StableSpots()) do
        if s[4] == id and s[5] == spot and s[1] == cont then
            return math.sqrt((s[2] - px) ^ 2 + (s[3] - py) ^ 2)
        end
    end
    return nil
end

-- "Name, Zone, 340 yd"
function ns.StableText(id, dist)
    local t = ns.STABLES and ns.STABLES[id]
    if not t then return "" end
    local text = (ns.Names(t)) .. ", " .. ns.ZoneName(t.z)
    if dist then text = text .. ", " .. ns.DistanceText(dist) end
    return text
end

-------------------------------------------------------------------------------
-- Pet training points, options, resets
-------------------------------------------------------------------------------
function ns.TrainingPoints()
    if not (C_PetInfo and C_PetInfo.GetPetTrainingPoints) then return nil end
    local ok, total, used = pcall(C_PetInfo.GetPetTrainingPoints)
    if not ok or IsSecret(total) or IsSecret(used) then return nil end
    if type(total) ~= "number" then return nil end
    return total - (tonumber(used) or 0), total
end

function ns.SetOption(key, value)
    ns.db[key] = value
    ns.Changed()
    ns.Fire("OPTION", key)
end

function ns.ResetKnown()
    wipe(ns.cdb.known)
    ns.Print(L.RESET_DONE)
    ns.Changed()
end

function ns.RebuildIndexes()
    abilityByKey, abilityByName = nil, nil
    byMap = nil
    worldCache = {}
    ns.Changed()
end

-------------------------------------------------------------------------------
-- Waypoints / world map
-------------------------------------------------------------------------------
function ns.OpenMapFor(id)
    local b = ns.BEASTS[id]
    local mapID = b and ns.ZoneMap(b.z)
    ns.highlight = id
    if mapID then
        if OpenWorldMap then
            OpenWorldMap(mapID)
        else
            if not WorldMapFrame:IsShown() then
                if ToggleWorldMap then ToggleWorldMap() else ShowUIPanel(WorldMapFrame) end
            end
            WorldMapFrame:SetMapID(mapID)
        end
    end
    ns.Fire("MAP_REFRESH")
    return mapID ~= nil
end

function ns.ClearHighlight()
    if ns.highlight == nil then return end
    ns.highlight = nil
    ns.Fire("MAP_REFRESH")
end

-- obj: a beast or trainer entry (for the names); x, y: 0..1 on mapID
local function WaypointAt(obj, mapID, x, y)
    local name = ns.DisplayName(obj, true)
    if TomTom and TomTom.AddWaypoint then
        TomTom:AddWaypoint(mapID, x, y, { title = (ns.Names(obj)), persistent = false })
        return ns.Print(L.WP_SET:format(name))
    end
    if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapID) then
        return ns.Print(L.WP_FAIL)
    end
    local ok = UiMapPoint and pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(mapID, x, y))
    if ok and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    ns.Print(ok and L.WP_SET:format(name) or L.WP_FAIL)
end

function ns.SetWaypoint(id, clusterIdx)
    local b = ns.BEASTS[id]
    local mapID = b and ns.ZoneMap(b.z)
    if not mapID or #b.c == 0 then return ns.Print(L.WP_FAIL) end
    clusterIdx = clusterIdx or 1
    WaypointAt(b, mapID, b.c[clusterIdx] / 1000, b.c[clusterIdx + 1] / 1000)
end

-- spot: index of the x in the NPC's coordinate pairs (1, 3, ...)
local function ServiceWaypoint(src, id, spot)
    local t = src and src[id]
    local mapID = t and ns.ZoneMap(t.z)
    spot = spot or 1
    if not mapID or not t.c[spot + 1] then return ns.Print(L.WP_FAIL) end
    WaypointAt(t, mapID, t.c[spot] / 1000, t.c[spot + 1] / 1000)
end

function ns.SetTrainerWaypoint(id, spot) ServiceWaypoint(ns.TRAINERS, id, spot) end
function ns.SetStableWaypoint(id, spot) ServiceWaypoint(ns.STABLES, id, spot) end

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------
local function CopyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        BeastAtlasDB = BeastAtlasDB or {}
        CopyDefaults(BeastAtlasDB, DEFAULTS)
        BeastAtlasCharDB = BeastAtlasCharDB or {}
        BeastAtlasCharDB.known = BeastAtlasCharDB.known or {}
        BeastAtlasCharDB.manual = nil -- v0.1 leftover
        ns.db, ns.cdb = BeastAtlasDB, BeastAtlasCharDB
        ns.isHunter = select(2, UnitClass("player")) == "HUNTER"
        ctxCache = nil
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        -- Map data and the player's level are reliable from here on. Observations are merged now, not at
        -- ADDON_LOADED: a zone lookup that fails too early would stay cached for the whole session.
        if ns.MergeObserved then ns.MergeObserved() end
        abilityByKey, abilityByName, byMap = nil, nil, nil
        trainersByMap, stablesByMap, stableSpots = nil, nil, nil
        ctxCache = nil
        ns.Fire("LOGIN")
    end
end)

SLASH_BEASTATLAS1 = "/ba"
SLASH_BEASTATLAS2 = "/beastatlas"
SLASH_BEASTATLAS3 = "/атлас"
SlashCmdList.BEASTATLAS = function(msg)
    if not ns.isHunter then return ns.Print(L.NOT_HUNTER) end
    msg = ns.Lower(msg or ""):match("^[ \t]*(.-)[ \t]*$")
    if msg == "map" then
        ns.SetOption("mapPins", not ns.db.mapPins)
        ns.Print(ns.db.mapPins and L.PINS_ON or L.PINS_OFF)
    elseif msg == "main" then
        ns.SetMainPet()
    elseif msg == "trainer" then
        ns.DumpTrainer()
    elseif msg == "stable" or msg == "stables" or msg == "стойла" then
        local id, spot, dist = ns.NearestStableToPlayer()
        if not id then return ns.Print(L.STABLE_NONE) end
        ns.Print(L.STABLE_NEAREST:format(ns.StableText(id, dist)))
        ns.SetStableWaypoint(id, spot)
    elseif msg == "reset" then
        ns.ResetKnown()
    elseif msg == "help" or msg == "?" then
        ns.Print(L.HELP)
    else
        ns.ToggleWindow()
    end
end
