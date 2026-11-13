-- Learns from the player's own tames: the shipped data is young, so when the hunter tames a beast
-- we record what the new pet really knows (BeastAtlasDB.observed) and merge it into ns.BEASTS.
local _, ns = ...
local L = ns.L

-- Tame Beast is 1515 in Classic; not verified for Forever, so the spell name is compared as well.
local TAME_SPELL = 1515
local SNAPSHOT_TTL = 60
local CHECK_DELAY = 1.5
local MAX_RETRIES = 3

local snapshot   -- the target of the last Tame Beast cast
local checkToken = 0

local tameName -- name of spell 1515, resolved once (false = not available)
local function IsTameSpell(spellID)
    if not spellID or ns.IsSecret(spellID) then return false end
    if spellID == TAME_SPELL then return true end
    if not (C_Spell and C_Spell.GetSpellName) then return false end
    if tameName == nil then
        local n = C_Spell.GetSpellName(TAME_SPELL)
        tameName = (n ~= nil and not ns.IsSecret(n)) and n or false
    end
    if not tameName then return false end
    local name = C_Spell.GetSpellName(spellID)
    return name ~= nil and not ns.IsSecret(name) and name == tameName
end

-- Creature-0-server-instance-zoneUID-npcID-spawnUID
local function NpcId(guid)
    if not guid or ns.IsSecret(guid) then return nil end
    return tonumber(guid:match("^Creature%-[^%-]*%-[^%-]*%-[^%-]*%-[^%-]*%-([0-9]+)"))
end

local function Snapshot()
    local id = NpcId(UnitGUID("target"))
    if not id then return nil end
    local name = UnitName("target")
    if not name or ns.IsSecret(name) then return nil end
    local level = UnitLevel("target")
    if not level or ns.IsSecret(level) or level <= 0 then return nil end
    local family = UnitCreatureFamily("target")
    if not family or ns.IsSecret(family) then return nil end
    family = ns.FamilyKey(family)
    if not family then return nil end
    local oldPet = UnitGUID("pet")
    if ns.IsSecret(oldPet) then return nil end

    local mapID = ns.PlayerZoneMap()
    if not mapID or not (C_Map and C_Map.GetPlayerMapPosition) then return nil end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil end
    local x, y = pos.x, pos.y
    if pos.GetXY then x, y = pos:GetXY() end
    if not x or not y or ns.IsSecret(x) or ns.IsSecret(y) then return nil end
    return { id = id, name = name, level = level, f = family, oldPet = oldPet, time = GetTime(),
             m = mapID, x = math.floor(x * 1000 + 0.5), y = math.floor(y * 1000 + 0.5) }
end

-- Valid (key, rank) pairs of an observation; unknown ability keys and ranks are ignored.
local function ValidPairs(t, abilities)
    local out = {}
    for i = 1, #(t or {}), 2 do
        local ab = abilities[t[i]]
        local rank = t[i + 1]
        if ab and type(rank) == "number" and ab.ranks[rank] then
            out[#out + 1] = t[i]
            out[#out + 1] = rank
        end
    end
    return out
end

local function HasPair(t, key, rank)
    for i = 1, #t, 2 do
        if t[i] == key and t[i + 1] == rank then return true end
    end
    return false
end

function ns.MergeObserved()
    local observed = ns.db and ns.db.observed
    if not observed or not ns.BEASTS or not ns.ABILITIES then return end
    -- Own key lookup: ns.Ability() would build its index before the beasts below are added.
    local abilities = {}
    for _, ab in ipairs(ns.ABILITIES) do abilities[ab.key] = ab end
    for id, obs in pairs(observed) do
        local pairsT = ValidPairs(obs.t, abilities)
        local b = ns.BEASTS[id]
        if b then
            local added = false
            for i = 1, #pairsT, 2 do
                if not HasPair(b.t, pairsT[i], pairsT[i + 1]) then
                    b.t[#b.t + 1] = pairsT[i]
                    b.t[#b.t + 1] = pairsT[i + 1]
                    added = true
                end
            end
            if added then b.o = true end
        elseif #pairsT > 0 and obs.m and obs.x and obs.y and obs.l then
            local zone = ns.ZoneByMap(obs.m)
            if zone then
                ns.BEASTS[id] = { en = obs.n, ru = obs.n, f = obs.f, l = { obs.l, obs.l }, z = zone,
                                  t = pairsT, c = { obs.x, obs.y, 30 }, o = true }
            end
        end
    end
end

local function Record(snap, ranks)
    local observed = ns.db.observed
    local o = observed[snap.id]
    if not o then
        o = { t = {} }
        observed[snap.id] = o
    end
    o.n, o.loc, o.f, o.l = snap.name, GetLocale(), snap.f, snap.level
    o.m, o.x, o.y = snap.m, snap.x, snap.y
    o.d = date("%Y-%m-%d")

    local best = {}
    for i = 1, #o.t, 2 do
        local key, rank = o.t[i], o.t[i + 1]
        if not best[key] or best[key] < rank then best[key] = rank end
    end
    for key, rank in pairs(ranks) do
        if not best[key] or best[key] < rank then best[key] = rank end
    end
    local keys = {}
    for key in pairs(best) do keys[#keys + 1] = key end
    table.sort(keys)
    local t = {}
    for _, key in ipairs(keys) do
        t[#t + 1] = key
        t[#t + 1] = best[key]
    end
    o.t = t
end

local function OnPetReady(token, attempt)
    if token ~= checkToken then return end
    local snap = snapshot
    if not snap or not UnitExists("pet") then return end
    local guid = UnitGUID("pet")
    if not guid or ns.IsSecret(guid) or guid == snap.oldPet then return end
    local family = UnitCreatureFamily("pet")
    if ns.FamilyKey(family) ~= snap.f then return end
    -- A fresh tame is still called after the beast (or after its family). A renamed pet summoned from the
    -- stable after a failed tame must not be recorded under the wild beast's id.
    local petName = UnitName("pet")
    if not petName or ns.IsSecret(petName) or (petName ~= snap.name and petName ~= family) then
        snapshot = nil
        return
    end

    ns.ScanPetSpellbook()
    local ranks, any = {}, false
    for key, rank in pairs(ns.petRanks or {}) do
        local ab = ns.Ability(key)
        if ab and not ab.trainer then
            ranks[key] = rank
            any = true
        end
    end
    if not any or ns.petRanksPartial then
        if attempt < MAX_RETRIES then
            C_Timer.After(CHECK_DELAY, function() OnPetReady(token, attempt + 1) end)
        else
            snapshot = nil
        end
        return
    end
    snapshot = nil

    -- What does this tame add to what the atlas already shows for the beast?
    -- (An earlier observation counts too, so a beast that could not be placed doesn't repeat the message.)
    local b = ns.BEASTS[snap.id]
    local old = ns.db.observed[snap.id]
    local oldT = old and old.t or {}
    local news = {}
    local keys = {}
    for key in pairs(ranks) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        if not (b and HasPair(b.t, key, ranks[key])) and not HasPair(oldT, key, ranks[key]) then
            news[#news + 1] = (ns.Names(ns.Ability(key))) .. " " .. ranks[key]
        end
    end

    Record(snap, ranks)
    if #news > 0 then
        ns.MergeObserved()
        ns.RebuildIndexes()
        ns.Print(L.OBSERVED:format(snap.name, table.concat(news, ", ")))
    end
end

local f = CreateFrame("Frame")
ns.On("LOGIN", function()
    if not ns.isHunter then return end
    f:RegisterEvent("UNIT_SPELLCAST_SENT")
    f:RegisterEvent("UNIT_SPELLCAST_START")
    f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    f:RegisterEvent("UNIT_PET")
end)

f:SetScript("OnEvent", function(_, event, unit, ...)
    if unit ~= "player" then return end
    if event == "UNIT_PET" then
        if snapshot and GetTime() - snapshot.time < SNAPSHOT_TTL then
            checkToken = checkToken + 1
            local token = checkToken
            C_Timer.After(CHECK_DELAY, function() OnPetReady(token, 0) end)
        end
        return
    end
    local spellID
    if event == "UNIT_SPELLCAST_SENT" then
        spellID = select(3, ...) -- target, castGUID, spellID
    else
        spellID = select(2, ...) -- castGUID, spellID
    end
    if not IsTameSpell(spellID) then return end
    -- SENT, START and CHANNEL_START may all fire for one cast; keep the last good snapshot.
    snapshot = Snapshot() or snapshot
end)
