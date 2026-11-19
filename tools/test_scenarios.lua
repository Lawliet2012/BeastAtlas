-- Offline scenarios for BeastAtlas v0.2 (run by tools/test_load.py after wow_stubs.lua and the addon files).
local ns = __NS
local RU = __LOCALE == "ruRU"
local fails, info = {}, {}
local function check(cond, msg) if not cond then fails[#fails + 1] = msg end end
local function loc(o) return RU and o.ru or o.en end
local function rankText(n) return (RU and "Уровень " or "Rank ") .. n end
local function outHas(text, from)
    for i = (from or 1), #__out do if __out[i]:find(text, 1, true) then return true end end
    return false
end
local function slash(msg) SlashCmdList.BEASTATLAS(msg) end
local function ability(key) return ns.Ability(key) end
local function petSpell(key, rank) return { loc(ability(key)), rankText(rank) } end

-------------------------------------------------------------------------------
-- non-hunter: everything stays inert
-------------------------------------------------------------------------------
if __CLASS ~= "HUNTER" then
    __fire("ADDON_LOADED", "BeastAtlas")
    __fire("PLAYER_LOGIN")
    __advance(10)
    check(BeastAtlasMinimapButton == nil, "non-hunter got a minimap button")
    check(WorldMapFrame.__provider == nil, "non-hunter got a map provider")
    slash("")
    check(outHas(ns.L.NOT_HUNTER), "non-hunter slash should print NOT_HUNTER")
    check(BeastAtlasFrame == nil, "non-hunter slash opened the window")
    return table.concat(fails, "\n"), "non-hunter ok"
end

-------------------------------------------------------------------------------
-- an Alliance hunter: the other half of the faction rules for trainers and stable masters
-- (the full scenario below plays a Horde hunter, who never sees the NPCs with two spots)
-------------------------------------------------------------------------------
if __FACTION == "Alliance" then
    __U.player.level = 30
    __fire("ADDON_LOADED", "BeastAtlas")
    __fire("PLAYER_LOGIN")
    __advance(3)
    local SERVICE_PIN = "BeastAtlasTrainerPinTemplate"
    local function pinsOf(kind, id)
        local n = 0
        for _, pin in ipairs(__map.pins[SERVICE_PIN] or {}) do
            if pin.kind == kind and (id == nil or pin.npcId == id) then n = n + 1 end
        end
        return n
    end
    WorldMapFrame:Show()
    local seenA, twoSpots = 0, 0
    for kind, src in pairs({ stable = ns.STABLES, trainer = ns.TRAINERS }) do
        for id, t in pairs(src) do
            local mapID = ns.ZoneMap(t.z)
            if mapID then
                WorldMapFrame:SetMapID(mapID)
                local want = t.side == "H" and 0 or #t.c / 2
                check(pinsOf(kind, id) == want, ("Alliance: %s %d has %d pins, expected %d"):format(kind, id, pinsOf(kind, id), want))
                if want > 0 then seenA = seenA + 1 end
                if want > 1 then twoSpots = twoSpots + 1 end
            end
        end
    end
    check(seenA >= 25 and twoSpots >= 3, ("Alliance: %d NPCs pinned, %d with two spots"):format(seenA, twoSpots))
    WorldMapFrame:SetMapID(ns.ZoneMap("Stormwind City"))
    check(pinsOf("stable") == 4, "Stormwind: two stable masters with two spots each, got " .. pinsOf("stable"))
    WorldMapFrame:SetMapID(ns.ZoneMap("The Barrens"))
    check(pinsOf("stable") == 1, "The Barrens for the Alliance: only the neutral stable master in Ratchet")
    -- a trainer and a stable master standing together are drawn side by side (Teldrassil: the same spot)
    WorldMapFrame:SetMapID(ns.ZoneMap("Teldrassil"))
    local stablePin, trainerPin
    for _, pin in ipairs(__map.pins[SERVICE_PIN] or {}) do
        if pin.kind == "stable" then stablePin = pin else trainerPin = pin end
    end
    check(stablePin and trainerPin, "Teldrassil: one trainer and one stable master expected")
    if stablePin and trainerPin then
        local tx, ty = __drawnAt(trainerPin, 0)
        local sx, sy = __drawnAt(stablePin, 0)
        check(tx == trainerPin.__x and ty == trainerPin.__y, "Teldrassil: the trainer pin must stay where the trainer stands")
        check(math.sqrt((sx - tx) ^ 2 + (sy - ty) ^ 2) >= 0.03, "Teldrassil: zoomed out, the stable master's pin lies on the trainer's")
        sx, sy = __drawnAt(stablePin, 1)
        check(sx == stablePin.__x and sy == stablePin.__y, "Teldrassil: zoomed in, the stable master's pin must be on its real spot")
    end
    -- standing on any spot of any usable stable master, that very spot is the nearest one
    local spots = 0
    for id, t in pairs(ns.STABLES) do
        local mapID = t.side ~= "H" and ns.ZoneMap(t.z)
        if mapID then
            for spot = 1, #t.c, 2 do
                __playerMap, __playerPos = mapID, { x = t.c[spot] / 1000, y = t.c[spot + 1] / 1000 }
                local nid, nspot, dist = ns.NearestStableToPlayer()
                check(nid == id and nspot == spot and dist < 0.01,
                    ("Alliance: standing on stable %d spot %d, the nearest is %s spot %s"):format(id, spot, tostring(nid), tostring(nspot)))
                spots = spots + 1
            end
        end
    end
    check(spots >= 25, "Alliance: stable spots checked: " .. spots)
    -- pets only Horde hunters can tame are not for this hunter, whatever the level
    local hordeOnly = 0
    for id, p in pairs(ns.PETS) do
        local ok, why = ns.TameState(id, 60)
        if p.side == "H" and p.tame ~= false then
            hordeOnly = hordeOnly + 1
            check(ok == false and why == "side", "Alliance: a Horde-only pet counts as tameable: " .. p.en)
        elseif p.tame ~= false and p.l[1] > 0 then
            check(ok == true, "Alliance: an ordinary pet is not tameable at 60: " .. p.en)
        end
    end
    check(hordeOnly >= 1, "test setup: no Horde-only pet in the data")
    return table.concat(fails, "\n"), ("alliance ok: pinned=%d stableSpots=%d"):format(seenA, spots)
end

-------------------------------------------------------------------------------
-- 1. login with a pet: it becomes the main pet; its spellbook marks nothing as known
-------------------------------------------------------------------------------
local L, S = ns.L, ns.STATUS
__U.player.level = 30
__U.pet = { name = "Fang", family = loc(ns.FAMILIES.Wolf), level = 24, guid = "Pet-0-1-1-1-100-0001" }
__fire("ADDON_LOADED", "BeastAtlas")
__fire("PLAYER_LOGIN")
__petSpells = { petSpell("bite", 2), petSpell("growl", 3) }
__advance(3)
local main = ns.cdb.main
check(main and main.name == "Fang" and main.family == "Wolf" and main.level == 24, "main pet not set from the first pet")
check(main and main.ranks and main.ranks.bite == 2, "main pet ranks not stored")
check(ns.KnownRank("bite") == 0, "pet spellbook leaked into known ranks")
check(ns.ActivePetIsMain(), "ActivePetIsMain false for the main pet")
check(outHas(L.MAIN_SET:format("Fang")), "MAIN_SET not printed")
check(ns.cdb.manual == nil, "cdb.manual should be gone")

-------------------------------------------------------------------------------
-- 2. data consistency
-------------------------------------------------------------------------------
local nBeasts, nCoords = 0, 0
for id, b in pairs(ns.BEASTS) do
    nBeasts = nBeasts + 1
    check(b.en and b.en ~= "" and b.ru and b.ru ~= "", "beast without names " .. id)
    check(ns.FAMILIES[b.f], "unknown family " .. tostring(b.f) .. " for " .. id)
    check(#b.t >= 2 and #b.t % 2 == 0, "bad teaches " .. id)
    for i = 1, #b.t, 2 do
        local ab = ability(b.t[i])
        check(ab and ab.ranks[b.t[i + 1]], "bad rank ref " .. id)
        check(ab and not ab.trainer, "beast teaches a trainer ability " .. id)
    end
    check(#b.c % 3 == 0, "bad coords " .. id)
    for i = 1, #b.c do check(b.c[i] >= 0 and b.c[i] <= 1000, "coord out of range " .. id) end
    if #b.c > 0 then nCoords = nCoords + 1 end
end
info[#info + 1] = ("beasts=%d withCoords=%d"):format(nBeasts, nCoords)

-------------------------------------------------------------------------------
-- 3. chat messages
-------------------------------------------------------------------------------
local mark = #__out
if RU then
    -- no ERR_* globals in this run: the strict fallback must handle a localized message
    __fire("CHAT_MSG_SYSTEM", "Вы изучили новую способность: |cff71d5ff[Укус (Уровень 3)]|r.")
    check(ns.KnownRank("bite") == 3, "fallback parse failed: bite=" .. ns.KnownRank("bite"))
    __fire("CHAT_MSG_SYSTEM", "Изучено: СуперУкус (Уровень 5).")
    check(ns.KnownRank("bite") == 3, "fallback accepted a name inside another word")
    __fire("CHAT_MSG_SYSTEM", "Питомец получает Укус (Уровень 6) и ещё что-то (2).")
    check(ns.KnownRank("bite") == 3, "fallback accepted a message that doesn't end with the ability")
else
    __fire("CHAT_MSG_SYSTEM", "You have learned a new ability: Bite (Rank 3).")
    check(ns.KnownRank("bite") == 3, "ERR_LEARN parse failed: bite=" .. ns.KnownRank("bite"))
    __fire("CHAT_MSG_SYSTEM", "You have unlearned Bite (Rank 5).")
    check(ns.KnownRank("bite") == 3, "unlearn message raised a rank")
    __fire("CHAT_MSG_SYSTEM", "You have learned a new spell: Frostbite (Rank 5).")
    check(ns.KnownRank("bite") == 3, "foreign spell raised a rank")
end
check(outHas(L.MARKED:format(loc(ability("bite")) .. " 3", L.SRC_CHAT), mark), "MARKED line missing for chat")
__advance(2)

-- 3b. the same message without the rank ("[Claw]" instead of "[Claw (Rank 3)]"), as the client sometimes sends it
do
    local clawName = loc(ability("claw"))
    local function learned(text) __fire("CHAT_MSG_SYSTEM", ERR_LEARN_SPELL_S:format(text)) end
    local function link(id, text) return "|cff71d5ff|Hspell:" .. id .. ":0|h[" .. text .. "]|h|r" end
    local keepPet, keepSpells = __U.pet, __petSpells
    local function teacher(spells)
        __U.pet = spells and { name = "Bear", family = loc(ns.FAMILIES.Bear), level = 21, guid = "Pet-0-1-1-1-900-0077" } or nil
        __petSpells = spells or {}
        __fire("UNIT_PET", "player")
        __advance(2)
    end
    local claw3 = ability("claw").ranks[3].spells[1]

    -- with the rank in the text and a teacher that knows another rank: the text wins
    teacher({ petSpell("claw", 3) })
    ns.cdb.known.claw = 2
    learned(link(ability("claw").ranks[4].spells[1], clawName .. " (" .. rankText(4) .. ")"))
    check(ns.KnownRank("claw") == 4, "rank from the text ignored: claw=" .. ns.KnownRank("claw"))

    -- no rank in the text, a spell link of Claw 3 and no pet: the link tells the rank
    teacher(nil)
    ns.cdb.known.claw = 2
    local from = #__out + 1
    learned(link(claw3, clawName))
    check(ns.KnownRank("claw") == 3, "rank not taken from the spell link: claw=" .. ns.KnownRank("claw"))
    check(outHas(L.MARKED:format(clawName .. " 3", L.SRC_CHAT), from), "no MARKED line for a rank taken from the link")
    -- a link of another ability does not count
    ns.cdb.known.claw = 2
    learned(link(ability("bite").ranks[4].spells[1], clawName))
    __advance(6)
    check(ns.KnownRank("claw") == 2, "rank taken from a link of another ability: claw=" .. ns.KnownRank("claw"))

    -- no rank, no link, the teacher is out and knows Claw 3: that is the rank just learned
    teacher({ petSpell("claw", 3), petSpell("bite", 3) })
    ns.cdb.known.claw = 2
    learned("[" .. clawName .. "]")
    check(ns.KnownRank("claw") == 3, "rank not taken from the summoned teacher: claw=" .. ns.KnownRank("claw"))

    -- the teacher's spellbook is not loaded yet (no rank text): resolved a moment later
    teacher({ { clawName, "" } })
    check(ns.petRanksPartial and ns.petRanks.claw == nil, "test setup: the pet's Claw rank should be unknown")
    ns.cdb.known.claw = 2
    learned("[" .. clawName .. "]")
    check(ns.KnownRank("claw") == 2, "rank guessed while the teacher's spellbook was still loading")
    __petSpells = { petSpell("claw", 3) }
    __fire("SPELLS_CHANGED")
    __advance(4)
    check(ns.KnownRank("claw") == 3, "rank not resolved after the teacher's spellbook loaded: claw=" .. ns.KnownRank("claw"))

    -- a trainer ability is bought, not learned from the pet that is out
    teacher({ petSpell("growl", 2) })
    ns.cdb.known.growl = 1
    learned("[" .. loc(ability("growl")) .. "]")
    __advance(6)
    check(ns.KnownRank("growl") == 1, "a trainer ability took its rank from the summoned pet")
    ns.cdb.known.growl = nil

    -- nothing tells the rank: a higher rank is not guessed, and the hunter is told to mark it
    teacher(nil)
    ns.cdb.known.claw = 2
    from = #__out + 1
    learned("[" .. clawName .. "]")
    __advance(6)
    check(ns.KnownRank("claw") == 2, "rank guessed with nothing to go by: claw=" .. ns.KnownRank("claw"))
    check(outHas(L.LEARNED_NO_RANK:format(clawName), from), "no hint when the rank could not be told")
    -- ... but rank 1 is certain when the ability was not known at all
    ns.cdb.known.claw = nil
    learned("[" .. clawName .. "]")
    __advance(6)
    check(ns.KnownRank("claw") == 1, "an unknown ability learned without a rank should count as rank 1")

    ns.cdb.known.claw = nil
    __U.pet, __petSpells = keepPet, keepSpells
    __fire("UNIT_PET", "player")
    ns.Changed()
    __advance(2)
end

-------------------------------------------------------------------------------
-- 4. Beast Training window
-------------------------------------------------------------------------------
__trainerType = Enum.TrainerType.Pet
__trainer = {
    { loc(ability("claw")), "available", rankText(2) },
    { loc(ability("dash")), "unavailable", rankText(1) },
    { loc(ability("bite")), "used", rankText(5) },
}
mark = #__out
__fire("TRAINER_SHOW")
check(ns.KnownRank("claw") == 2 and ns.KnownRank("bite") == 5, "trainer scan missed available/used rows")
check(ns.KnownRank("dash") == 0, "trainer scan marked an 'unavailable' row")
check(outHas(L.SRC_TRAINER, mark), "MARKED line missing for trainer")
-- a trainer NPC shows the same window: nothing may be marked from it
__U.npc = { name = "Pet Trainer", level = 30 }
__trainer = { { loc(ability("dash")), "available", rankText(2) } }
__fire("TRAINER_UPDATE")
check(ns.KnownRank("dash") == 0, "NPC trainer window marked a rank")
mark = #__out
slash("trainer")
check(outHas("1: " .. loc(ability("dash")), mark), "/ba trainer did not dump rows")
__U.npc = nil
__trainer, __trainerType = {}, nil

-------------------------------------------------------------------------------
-- 5. statuses: compare ns.RankStatus with an independent reading of the spec table
-------------------------------------------------------------------------------
local savedPet = __U.pet
__U.pet = nil -- no summoned pet, so the tracker doesn't touch cdb.main during this block
local function mappable(id)
    local b = ns.BEASTS[id]
    return #b.c > 0 and ns.ZoneMap(b.z) ~= nil
end
local function teacher(ab, r, lvl, onMap)
    for _, id in ipairs(ab.ranks[r].beasts) do
        if ns.BEASTS[id].l[1] <= lvl and (not onMap or mappable(id)) then return true end
    end
    return false
end
local function refStatus(ab, rank, known, petLevel, playerLevel, look)
    if rank <= known then return S.LEARNED end
    if ab.trainer then return S.LATER end
    local target
    for r = known + 1, ab.maxRank do
        if ab.ranks[r] and ab.ranks[r].lvl <= petLevel and teacher(ab, r, playerLevel) then target = r end
    end
    local alt -- the best rank's teachers are all off the map: the best outdoor rank stays READY too
    if target and not teacher(ab, target, playerLevel, true) then
        for r = known + 1, target - 1 do
            if ab.ranks[r] and ab.ranks[r].lvl <= petLevel and teacher(ab, r, playerLevel, true) then alt = r end
        end
    end
    if target then
        if rank == target or rank == alt then return S.READY end
        if rank < target then return S.OBSOLETE end
    end
    if ab.ranks[rank].lvl <= petLevel then return teacher(ab, rank, playerLevel + look) and S.SOON or S.LATER end
    return ab.ranks[rank].lvl <= petLevel + look and S.SOON or S.LATER
end
local savedKnown = {}
for k, v in pairs(ns.cdb.known) do savedKnown[k] = v end
local compared = 0
for _, case in ipairs({ { 1, 10, 0, 6 }, { 24, 30, 0, 6 }, { 24, 30, 2, 0 }, { 40, 20, 1, 10 }, { 60, 60, 0, 6 },
    { 33, 60, 4, 3 } }) do
    local petLevel, playerLevel, known, look = case[1], case[2], case[3], case[4]
    __U.player.level = playerLevel
    ns.db.lookahead = look
    ns.cdb.main = { id = "T|Wolf", name = "T", family = "Wolf", level = petLevel, ranks = {} }
    wipe(ns.cdb.known)
    for _, ab in ipairs(ns.ABILITIES) do ns.cdb.known[ab.key] = known > 0 and math.min(known, ability(ab.key).maxRank) or nil end
    ns.Changed()
    for _, e in ipairs(ns.ABILITIES) do
        local ab = ability(e.key)
        local k = ns.KnownRank(ab.key)
        for r = 1, ab.maxRank do
            if ab.ranks[r] then
                local want, got = refStatus(ab, r, k, petLevel, playerLevel, look), ns.RankStatus(ab.key, r)
                compared = compared + 1
                if want ~= got then
                    check(false, ("status %s %d (pet %d, player %d, known %d, look %d): want %d got %d")
                        :format(ab.key, r, petLevel, playerLevel, k, look, want, got))
                end
                if ab.trainer then check(got ~= S.READY and got ~= S.SOON, "trainer ability got READY/SOON " .. ab.key) end
            end
        end
        check(not ab.trainer or not ns.AbilityPassesFilter(ab), "trainer ability passes the filter " .. ab.key)
    end
    for id, b in pairs(ns.BEASTS) do
        local best, list = ns.BeastInfo(id)
        for _, e in ipairs(list or {}) do
            local st, tame = ns.BeastRankStatus(id, e.key, e.rank)
            check(st == e.status, "BeastInfo status differs from BeastRankStatus " .. id)
            if b.l[1] > playerLevel then
                check(st ~= S.READY, "untameable beast is READY " .. id)
                check(st == S.LEARNED or st == S.OBSOLETE or tame == b.l[1], "tame level missing " .. id)
            end
            check(type(ns.StatusNote(st, e.key, e.rank, tame)) == "string", "StatusNote not a string")
        end
        local useful = ns.BeastUseful(id)
        check(useful == nil or useful == S.READY or useful == S.SOON, "BeastUseful returned " .. tostring(useful))
        check(not useful or best == useful, "BeastUseful differs from BeastInfo")
    end
end
info[#info + 1] = "statusesCompared=" .. compared
-- a dungeon-only top rank (Bite 8: Blackrock Spire) must not hide the best outdoor rank
__U.player.level = 60
ns.cdb.main = { id = "T|Wolf", name = "T", family = "Wolf", level = 60, ranks = {} }
wipe(ns.cdb.known)
ns.Changed()
local bp = ns.Plan("bite")
check(bp.target == 8 and bp.alt == 7, ("bite plan at 60: target %s alt %s"):format(tostring(bp.target), tostring(bp.alt)))
check(ns.RankStatus("bite", 7) == S.READY and ns.RankStatus("bite", 6) == S.OBSOLETE, "outdoor alternative rank not READY")
-- restore
__U.player.level = 30
ns.db.lookahead = 6
wipe(ns.cdb.known)
for k, v in pairs(savedKnown) do ns.cdb.known[k] = v end
ns.cdb.main = main
ns.Changed()
__U.pet = savedPet

-- a rank the main pet already has is done, even if the hunter never learned it (the pet came with it)
do
    local saved = ns.cdb.main.ranks.cower
    ns.cdb.main.ranks.cower = 1
    ns.Changed()
    check(ns.KnownRank("cower") == 0 and ns.HaveRank("cower") == 1, "HaveRank ignores the main pet's own rank")
    check(ns.Plan("cower").known == 1 and ns.RankStatus("cower", 1) == ns.STATUS.LEARNED,
        "a rank the main pet has is not LEARNED")
    check(ns.RankStatus("cower", 2) ~= ns.STATUS.LEARNED, "rank above the pet's own is LEARNED")
    ns.cdb.main.ranks.cower = saved
    ns.Changed()
end

-- a spellbook read without rank text (not loaded yet) must not overwrite the stored ranks
__petSpells = { { loc(ability("bite")), "" }, petSpell("growl", 3) }
__fire("SPELLS_CHANGED")
__advance(1)
check(ns.petRanksPartial == true, "empty rank text not flagged as a partial read")
check(ns.cdb.main.ranks.bite == 2, "partial spellbook read overwrote main pet ranks: " .. tostring(ns.cdb.main.ranks.bite))
__petSpells = { petSpell("bite", 2), petSpell("growl", 3) }
__fire("SPELLS_CHANGED")
__advance(1)
check(ns.petRanksPartial == false, "partial flag not cleared")

-------------------------------------------------------------------------------
-- 6. another pet is out: the main pet does not change until /ba main
-------------------------------------------------------------------------------
mark = #__out
__U.pet = { name = "Prowler", family = loc(ns.FAMILIES.Wolf), level = 9, guid = "Pet-0-1-1-1-118-0002" }
__petSpells = { petSpell("bite", 2) }
__fire("UNIT_PET", "player")
__advance(1)
check(ns.cdb.main.name == "Fang" and ns.cdb.main.level == 24, "main pet switched by itself")
check(not ns.ActivePetIsMain(), "ActivePetIsMain true for another pet")
check(outHas(L.OTHER_PET:format("Prowler", "Fang"), mark), "OTHER_PET tip missing")
check(ns.KnownRank("bite") == 5, "another pet's spellbook changed known ranks")
slash("main")
check(ns.cdb.main.name == "Prowler" and ns.cdb.main.level == 9, "/ba main did not switch")
__U.pet = savedPet
__petSpells = { petSpell("bite", 2), petSpell("growl", 3) }
__fire("UNIT_PET", "player")
__advance(1)
slash("main")
check(ns.cdb.main.name == "Fang", "/ba main did not switch back")

-------------------------------------------------------------------------------
-- 7. main pet level-up: tip in chat
-------------------------------------------------------------------------------
wipe(ns.cdb.known)
ns.Changed()
mark = #__out
__U.pet.level = 32
__fire("UNIT_LEVEL", "pet")
__advance(1)
check(ns.cdb.main.level == 32, "main level not updated")
check(outHas(L.NOTIFY_LEVEL:format("Fang", 32), mark), "level-up tip missing")
check(outHas(loc(ability("bite")) .. " 5", mark), "level-up tip does not mention Bite 5")
ns.db.notify = false
mark = #__out
__U.pet.level = 40
__fire("UNIT_LEVEL", "pet")
__advance(1)
check(not outHas(L.NOTIFY_LEVEL:format("Fang", 40), mark), "tip printed with notify off")
ns.db.notify = true

-------------------------------------------------------------------------------
-- 8. world map
-------------------------------------------------------------------------------
check(WorldMapFrame.__provider, "no map provider")
local AREA, ICON, ZONE = "BeastAtlasAreaPinTemplate", "BeastAtlasIconPinTemplate", "BeastAtlasZonePinTemplate"
local zonesWithPins, totalPins = 0, 0
local someZone, stackSeen
WorldMapFrame:Show()
for mapID, ids in pairs(ns.BeastsByMap()) do
    WorldMapFrame:SetMapID(mapID)
    local n = __pinCount(ICON)
    if n > 0 then
        zonesWithPins = zonesWithPins + 1
        someZone = someZone or mapID
    end
    totalPins = totalPins + n + __pinCount(AREA)
    for _, pin in ipairs(__map.pins[ICON] or {}) do
        pin:OnMouseEnter(); pin:OnMouseLeave()
        if #pin.stack.ids > 1 then stackSeen = pin end
        for _, id in ipairs(pin.stack.ids) do check(ns.BeastUseful(id), "pin for a beast that is not useful " .. id) end
    end
    check(__pinCount(ZONE) == 0, "zone summary pin on a zone map")
end
check(zonesWithPins > 0, "no zone produced pins")
info[#info + 1] = ("zonesWithPins=%d pins=%d"):format(zonesWithPins, totalPins)
-- combat: nothing is acquired, the refresh happens afterwards
__combat = true
WorldMapFrame:SetMapID(someZone)
check(__pinCount(ICON) == 0 and __pinCount(AREA) == 0, "pins acquired in combat")
__combat = false
__fire("PLAYER_REGEN_ENABLED")
__advance(0.5)
check(__pinCount(ICON) > 0, "owed refresh after combat did not happen")
-- options
ns.SetOption("mapPins", false)
__advance(0.5)
check(__pinCount(ICON) == 0, "pins still shown with mapPins off")
ns.SetOption("mapPins", true)
__advance(0.5)
-- habitats: a circle per spot of every beast on the map, drawn only for the beast under the mouse
local function habitatsShown()
    local n = 0
    for _, pin in ipairs(__map.pins[AREA] or {}) do
        if pin.Fill:IsShown() then n = n + 1 end
    end
    return n
end
WorldMapFrame:SetMapID(someZone)
check(ns.db.areasAlways == false, "habitats of all beasts should be off by default")
check(__pinCount(AREA) > 0 and habitatsShown() == 0, "habitats drawn with no beast under the mouse")
for _, pin in ipairs(__map.pins[AREA]) do
    check(pin.__w == pin.__h, "a habitat is not a circle")
    -- the stub's canvas is 600 x 400: the smallest radius drawn is 0.045 of the map
    check(pin.__w >= 45 - 0.001, "a habitat circle is smaller than the minimum: " .. tostring(pin.__w))
end
do
    local hoverPin = __map.pins[ICON][1]
    local spots = #ns.BEASTS[hoverPin.stack.ids[1]].c / 3
    hoverPin:OnMouseEnter()
    check(habitatsShown() == spots, ("hovering a pin shows %d habitats, the beast has %d spots"):format(habitatsShown(), spots))
    hoverPin:OnMouseLeave()
    check(habitatsShown() == 0, "habitats stay after the mouse leaves the pin")
    -- after a redraw the same pins come back from the pool: each must be switched once, not once per redraw
    WorldMapFrame:SetMapID(someZone)
    local calls, originals = 0, {}
    for _, pin in ipairs(__map.pins[AREA]) do
        local original = pin.SetHover
        originals[pin] = original
        pin.SetHover = function(self, on)
            if on then calls = calls + 1 end
            return original(self, on)
        end
    end
    hoverPin = __map.pins[ICON][1]
    spots = #ns.BEASTS[hoverPin.stack.ids[1]].c / 3
    hoverPin:OnMouseEnter()
    check(calls == spots, ("hovering switched habitat pins %d times for %d spots (stale pins from an earlier redraw?)"):format(calls, spots))
    hoverPin:OnMouseLeave()
    for pin, original in pairs(originals) do pin.SetHover = original end
    ns.SetOption("areasAlways", true)
    __advance(0.5)
    check(__pinCount(AREA) > 0 and habitatsShown() == __pinCount(AREA), "the 'always' option does not draw every habitat")
    hoverPin = __map.pins[ICON][1]
    hoverPin:OnMouseEnter(); hoverPin:OnMouseLeave()
    check(habitatsShown() == __pinCount(AREA), "hovering hides habitats while the 'always' option is on")
    ns.SetOption("areasAlways", false)
    __advance(0.5)
    check(habitatsShown() == 0, "habitats stay after the 'always' option is switched off")
end
-- continent summary
local zonePins = 0
for _, cont in ipairs({ 1414, 1415 }) do
    WorldMapFrame:SetMapID(cont)
    check(__pinCount(ICON) == 0 and __pinCount(AREA) == 0, "beast pins on a continent map")
    for _, pin in ipairs(__map.pins[ZONE] or {}) do
        zonePins = zonePins + 1
        local sm = pin.summary
        check(sm.ready + sm.soon > 0, "empty zone summary")
        check(C_Map.GetMapInfo(sm.mapID).parentMapID == cont, "zone summary on the wrong continent")
        pin:OnMouseEnter(); pin:OnMouseLeave()
    end
end
check(zonePins > 0, "no zone summary pins on continents")
info[#info + 1] = "zoneSummaryPins=" .. zonePins

-- pet trainers: the player's faction only (the stub player is Horde), every spot of a trainer, own option
local TRAINER = "BeastAtlasTrainerPinTemplate"
-- trainers and stable masters share the template: the pins of one kind on the map being shown
local function servicePins(kind)
    local out = {}
    for _, pin in ipairs(__map.pins[TRAINER] or {}) do
        if pin.kind == kind then out[#out + 1] = pin end
    end
    return out
end
local nTrainers, shown = 0, 0
for id, t in pairs(ns.TRAINERS) do
    nTrainers = nTrainers + 1
    check(t.en ~= "" and t.ru ~= "" and ns.ZONES[t.z], "bad trainer entry " .. id)
    check(#t.c >= 2 and #t.c % 2 == 0, "bad trainer coords " .. id)
    for i = 1, #t.c do check(t.c[i] >= 0 and t.c[i] <= 1000, "trainer coord out of range " .. id) end
    local mapID = ns.ZoneMap(t.z)
    check(mapID, "trainer zone has no map " .. id)
    WorldMapFrame:SetMapID(mapID)
    local mine = 0
    for _, pin in ipairs(servicePins("trainer")) do
        local pt = ns.TRAINERS[pin.npcId]
        check(pt.side ~= "A", "Alliance trainer shown to a Horde player: " .. pin.npcId)
        if pin.npcId == id then mine = mine + 1 end
        pin:OnMouseEnter(); pin:OnMouseLeave()
    end
    if t.side == "A" then
        check(mine == 0, "Alliance trainer pinned " .. id)
    else
        check(mine == #t.c / 2, ("trainer %d: %d pins for %d spots"):format(id, mine, #t.c / 2))
        shown = shown + 1
    end
end
check(nTrainers >= 10 and shown >= 3, ("trainers=%d shown=%d"):format(nTrainers, shown))
info[#info + 1] = ("trainers=%d shownToHorde=%d"):format(nTrainers, shown)
WorldMapFrame:SetMapID(ns.ZoneMap("Orgrimmar"))
check(#servicePins("trainer") == 1, "Orgrimmar should show one trainer pin")
__waypoint = nil
servicePins("trainer")[1]:OnClick("LeftButton")
check(__waypoint ~= nil, "trainer pin click did not set a waypoint")
ns.SetOption("trainers", false)
__advance(0.5)
check(#servicePins("trainer") == 0, "trainer pins shown with the option off")
ns.SetOption("trainers", true)
__advance(0.5)
check(#servicePins("trainer") == 1, "trainer pins not restored")
for _, cont in ipairs({ 1414, 1415 }) do
    WorldMapFrame:SetMapID(cont)
    check(__pinCount(TRAINER) == 0, "trainer or stable pins on a continent map")
end
__combat = true
WorldMapFrame:SetMapID(ns.ZoneMap("Orgrimmar"))
check(__pinCount(TRAINER) == 0, "trainer or stable pins acquired in combat")
__combat = false

-------------------------------------------------------------------------------
-- 8b. stable masters: data, pins, the nearest one
-------------------------------------------------------------------------------
do
    local nStables, usable, noMap = 0, 0, 0
    for id, t in pairs(ns.STABLES) do
        nStables = nStables + 1
        check(t.en ~= "" and t.ru ~= "" and ns.ZONES[t.z], "bad stable entry " .. id)
        check(not t.ru:find("^%[") , "untranslated placeholder name kept: " .. id)
        check(#t.c >= 2 and #t.c % 2 == 0, "bad stable coords " .. id)
        check(t.side == nil or t.side == "A" or t.side == "H", "bad stable side " .. id)
        for i = 1, #t.c do check(t.c[i] >= 0 and t.c[i] <= 1000, "stable coord out of range " .. id) end
        local mapID = ns.ZoneMap(t.z)
        if not mapID then
            -- a zone the client has no map for (new zones are found by name; this stub knows none of them)
            noMap = noMap + 1
            check(ns.ZONES[t.z].map == nil, "stable zone with a map id that the stub rejects: " .. t.z)
        else
            WorldMapFrame:SetMapID(mapID)
            local mine = 0
            for _, pin in ipairs(servicePins("stable")) do
                check(ns.STABLES[pin.npcId].side ~= "A", "Alliance stable master shown to a Horde player: " .. pin.npcId)
                if pin.npcId == id then mine = mine + 1 end
            end
            if t.side == "A" then
                check(mine == 0, "Alliance stable master pinned " .. id)
            else
                check(mine == #t.c / 2, ("stable %d: %d pins for %d spots"):format(id, mine, #t.c / 2))
                usable = usable + 1
            end
        end
    end
    check(nStables >= 45 and usable >= 20 and noMap >= 1, ("stables=%d usable=%d noMap=%d"):format(nStables, usable, noMap))
    info[#info + 1] = ("stables=%d shownToHorde=%d"):format(nStables, usable)

    -- The Barrens for a Horde hunter: Sikwa, Kelsuwa and the neutral Reggifuz - the three to look for in game
    WorldMapFrame:SetMapID(ns.ZoneMap("The Barrens"))
    local names = {}
    for _, pin in ipairs(servicePins("stable")) do names[#names + 1] = ns.STABLES[pin.npcId].en end
    table.sort(names)
    check(table.concat(names, ",") == "Kelsuwa,Reggifuz,Sikwa", "stable masters in the Barrens: " .. table.concat(names, ","))

    -- Orgrimmar: one trainer, one stable master; pooled pins must not keep the other kind's look
    WorldMapFrame:SetMapID(ns.ZoneMap("Orgrimmar"))
    local sp, tp = servicePins("stable"), servicePins("trainer")
    check(#sp == 1 and #tp == 1, ("Orgrimmar: %d stable pins, %d trainer pins"):format(#sp, #tp))
    local function look(pin) return table.concat(pin.Ring.__color, ",") end
    local stableLook, trainerLook = look(sp[1]), look(tp[1])
    check(stableLook ~= trainerLook, "stable and trainer pins share a ring colour")
    for i = 1, 3 do
        -- redraws hand the pooled frames out in another order: the look must follow the kind, not the frame
        ns.SetOption("trainers", i % 2 == 0)
        __advance(0.5)
        for _, pin in ipairs(servicePins("stable")) do check(look(pin) == stableLook, "a reused pin kept the trainer's ring colour") end
        for _, pin in ipairs(servicePins("trainer")) do check(look(pin) == trainerLook, "a reused pin kept the stable's ring colour") end
    end
    ns.SetOption("trainers", true)
    __advance(0.5)
    sp = servicePins("stable")
    GameTooltip.__lines = {}
    sp[1]:OnMouseEnter()
    local tip = table.concat(GameTooltip.__lines, "\n")
    check(tip:find(loc(ns.STABLES[sp[1].npcId]), 1, true) and tip:find(L.STABLE_MASTER, 1, true)
        and not tip:find(L.TRAINER_ONLY, 1, true), "stable pin tooltip is wrong: " .. tip)
    sp[1]:OnMouseLeave()
    __waypoint = nil
    sp[1]:OnClick("LeftButton")
    local c = ns.STABLES[sp[1].npcId].c
    check(__waypoint and __waypoint[1] == ns.ZoneMap("Orgrimmar") and math.abs(__waypoint[2] - c[1] / 1000) < 1e-9,
        "stable pin click did not set a waypoint on the stable master")
    -- Durotar: the two stand 1.7% of the map apart. Zoomed out the stable master's pin is pushed off the
    -- trainer's; zoomed in both are exactly where the NPCs stand. Every pin sits on its true spot in the data.
    WorldMapFrame:SetMapID(ns.ZoneMap("Durotar"))
    local sd, td = servicePins("stable"), servicePins("trainer")
    check(#sd == 1 and #td == 1, "Durotar: one trainer and one stable master expected")
    if #sd == 1 and #td == 1 then
        local sPin, tPin = sd[1], td[1]
        local sc, tc = ns.STABLES[sPin.npcId].c, ns.TRAINERS[tPin.npcId].c
        check(sPin.__x == sc[1] / 1000 and sPin.__y == sc[2] / 1000 and tPin.__x == tc[1] / 1000 and tPin.__y == tc[2] / 1000,
            "Durotar: a pin is not placed on the NPC's own coordinates")
        local tx, ty = __drawnAt(tPin, 0)
        local sx, sy = __drawnAt(sPin, 0)
        local real = math.sqrt((sPin.__x - tPin.__x) ^ 2 + (sPin.__y - tPin.__y) ^ 2)
        check(real < 0.03, "test setup: the Durotar pair should be close together")
        check(tx == tPin.__x and ty == tPin.__y, "Durotar: the trainer pin moved")
        check(math.sqrt((sx - tx) ^ 2 + (sy - ty) ^ 2) >= 0.03, "Durotar: zoomed out, the stable master's pin overlaps the trainer's")
        sx, sy = __drawnAt(sPin, 1)
        check(sx == sPin.__x and sy == sPin.__y, "Durotar: zoomed in, the stable master's pin is not on its real spot")
        -- without the trainer pins there is nothing to move away from
        ns.SetOption("trainers", false)
        __advance(0.5)
        local alone = servicePins("stable")[1]
        sx, sy = __drawnAt(alone, 0)
        check(sx == alone.__x and sy == alone.__y, "Durotar: the stable master's pin is pushed with no trainer pin shown")
        ns.SetOption("trainers", true)
        __advance(0.5)
        -- pooled frames change kind between redraws: a trainer pin must never keep a stable pin's settings
        for _, pin in ipairs(servicePins("trainer")) do
            check((pin.__nudgeTarget or 0) == 0 and (pin.__nudgeRadius or 0) > 0, "a trainer pin is set up to be pushed like a stable pin")
        end
        for _, pin in ipairs(servicePins("stable")) do
            check((pin.__nudgeRadius or 0) == 0 and (pin.__nudgeTarget or 0) > 0, "a stable pin is set up to push like a trainer pin")
        end
    end
    WorldMapFrame:SetMapID(ns.ZoneMap("Orgrimmar"))
    ns.SetOption("stables", false)
    __advance(0.5)
    check(#servicePins("stable") == 0 and #servicePins("trainer") == 1, "stable pins shown with the option off")
    ns.SetOption("stables", true)
    __advance(0.5)
    check(#servicePins("stable") == 1, "stable pins not restored")

    -- the nearest stable master, against a plain search with the stub's world formula
    local function world(mapID, x, y) return (mapID % 2 == 0) and 1 or 0, x * 3000 + (mapID % 50) * 3000, y * 2000 end
    local function nearest(cont, px, py, radiusOf)
        local best, bestId
        for id, t in pairs(ns.STABLES) do
            local mapID = t.side ~= "A" and ns.ZoneMap(t.z)
            if mapID then
                for spot = 1, #t.c, 2 do
                    local sc, sx, sy = world(mapID, t.c[spot] / 1000, t.c[spot + 1] / 1000)
                    if sc == cont then
                        local d = math.max(0, math.sqrt((sx - px) ^ 2 + (sy - py) ^ 2) - (radiusOf or 0))
                        if not best or d < best then best, bestId = d, id end
                    end
                end
            end
        end
        return bestId, best
    end
    for _, place in ipairs({ { ns.ZoneMap("The Barrens"), 0.5, 0.5 }, { ns.ZoneMap("Elwynn Forest"), 0.2, 0.8 },
        { ns.ZoneMap("Tanaris"), 0.9, 0.1 }, { ns.ZoneMap("Orgrimmar"), 0.5, 0.5 } }) do
        __playerMap, __playerPos = place[1], { x = place[2], y = place[3] }
        local wantId, wantDist = nearest(world(place[1], place[2], place[3]))
        local id, spot, dist = ns.NearestStableToPlayer()
        check(id ~= nil and wantId ~= nil, "no nearest stable master on map " .. place[1])
        check(dist and math.abs(dist - wantDist) < 0.01, ("nearest stable from map %d: %s at %s, expected %s at %s"):format(
            place[1], tostring(id), tostring(dist), tostring(wantId), tostring(wantDist)))
        check(ns.STABLES[id].side ~= "A", "the nearest stable master belongs to the other faction")
        check(spot and ns.STABLES[id].c[spot + 1], "nearest stable: bad spot")
    end
    -- a place where a stable master of the other continent is closer on paper: it must not win
    local decisive = 0
    for _, t in pairs(ns.STABLES) do
        local mapID = ns.ZoneMap(t.z)
        if mapID and decisive == 0 then
            for gx = 0, 4 do
                for gy = 0, 4 do
                    local x, y = gx / 4, gy / 4
                    local cont, wx, wy = world(mapID, x, y)
                    local _, same = nearest(cont, wx, wy)
                    local _, other = nearest(1 - cont, wx, wy)
                    if same and other and other < same - 1 and decisive == 0 then
                        __playerMap, __playerPos = mapID, { x = x, y = y }
                        local _, _, dist = ns.NearestStableToPlayer()
                        check(dist and math.abs(dist - same) < 0.01, "the nearest stable master was taken from another continent")
                        decisive = decisive + 1
                    end
                end
            end
        end
    end
    check(decisive == 1, "test setup: no place where the other continent's stable master is closer")
    -- /ba stable: says which one and sets the waypoint there
    __playerMap, __playerPos = ns.ZoneMap("The Barrens"), { x = 0.5, y = 0.5 }
    local id, spot, dist = ns.NearestStableToPlayer()
    __waypoint = nil
    local from = #__out + 1
    slash("stable")
    check(outHas(L.STABLE_NEAREST:format(ns.StableText(id, dist)), from), "/ba stable did not name the nearest stable master")
    check(__waypoint and __waypoint[1] == ns.ZoneMap(ns.STABLES[id].z)
        and math.abs(__waypoint[2] - ns.STABLES[id].c[spot] / 1000) < 1e-9, "/ba stable set no waypoint on it")
    check(ns.StableText(id, dist):find(loc(ns.STABLES[id]), 1, true) and ns.StableText(id, dist):find(ns.ZoneName(ns.STABLES[id].z), 1, true),
        "StableText lacks the name or the zone")
    -- no position (an instance): nothing to offer
    __playerPos = nil
    check(ns.NearestStableToPlayer() == nil, "a nearest stable master without a player position")
    from = #__out + 1
    slash("stable")
    check(outHas(L.STABLE_NONE, from), "/ba stable without a position should say there is none")
    -- a stable master in a zone without a map: no waypoint, no error
    for sid, t in pairs(ns.STABLES) do
        if not ns.ZoneMap(t.z) then
            __waypoint = nil
            ns.SetStableWaypoint(sid, 1)
            check(__waypoint == nil, "waypoint set for a stable master whose zone has no map")
            break
        end
    end
    -- near a beast's habitat: measured from the edge of the nearest habitat, not from the player
    __playerMap, __playerPos = 1429, { x = 0.5, y = 0.5 }
    local checked = 0
    for bid, b in pairs(ns.BEASTS) do
        local mapID = #b.c > 0 and ns.ZoneMap(b.z)
        if mapID and checked < 40 then
            local best, bestId
            for i = 1, #b.c, 3 do
                local cont, bx, by = world(mapID, b.c[i] / 1000, b.c[i + 1] / 1000)
                local wantId, wantDist = nearest(cont, bx, by, b.c[i + 2] / 1000 * 3000)
                if wantId and (not best or wantDist < best) then best, bestId = wantDist, wantId end
            end
            local sid, _, sdist = ns.NearestStableToBeast(bid)
            check((sid == nil) == (bestId == nil), "stable near habitat: presence differs for " .. b.en)
            if sid and best then
                check(math.abs(sdist - best) < 0.01, ("stable near %s: %s yd, expected %s yd"):format(b.en, tostring(sdist), tostring(best)))
                checked = checked + 1
            end
        end
    end
    check(checked >= 20, "stable near habitat checked for " .. checked .. " beasts")
    __playerMap, __playerPos = 1429, { x = 0.5, y = 0.5 }
end

-------------------------------------------------------------------------------
-- 9. window
-------------------------------------------------------------------------------
slash("")
check(BeastAtlasFrame and BeastAtlasFrame:IsShown(), "window did not open")
ns.RefreshWindow()
for i, tab in ipairs({ "tabAbilities", "tabFamilies", "tabSettings", "tabNearby" }) do
    BeastAtlasFrame[tab].__scripts.OnClick(BeastAtlasFrame[tab])
    check(BeastAtlasFrame.selectedTab == ({ 2, 3, 4, 1 })[i], "native tab not selected: " .. tab)
end
check(BeastAtlasFrame.numTabs == 4 and BeastAtlasFrameTab4 ~= nil, "four tabs expected")
-- every non-trainer rank (except the two Lava Breath ones Wowhead doesn't list) has a clean pet spell id
local noSpell = 0
for _, e in ipairs(ns.ABILITIES) do
    for r, rk in pairs(e.ranks) do
        if not rk.spell then noSpell = noSpell + 1 end
        check(not rk.spell or rk.spells[1] == rk.spell, "spells[1] should be the pet spell " .. e.key)
    end
end
check(noSpell <= 2, "ranks without a pet spell id: " .. noSpell)
-- hovering list rows shows the game's own spell tooltip; rank descriptions come from the client
BeastAtlasFrame.tabAbilities.__scripts.OnClick(BeastAtlasFrame.tabAbilities)
local hovered, native = 0, 0
for _, f in ipairs(__frames) do
    if f.__kind == "Button" and f.data and f.__scripts.OnEnter and (f.data.spell or f.data.tip) then
        GameTooltip.__lines = {}
        f.__scripts.OnEnter(f)
        hovered = hovered + 1
        if f.data.spell then
            check(GameTooltip.__lines[1] == "<spell " .. f.data.spell .. ">", "row tooltip is not the native spell tooltip")
            native = native + 1
        end
        f.__scripts.OnLeave(f)
    end
end
check(hovered > 0 and native > 0, ("row tooltips: hovered %d, native %d"):format(hovered, native))
check(__spellRequests > 0, "rank descriptions were not requested from the client")
__fire("SPELL_TEXT_UPDATE", 17253)
__advance(0.5)
BeastAtlasFrame.tabNearby.__scripts.OnClick(BeastAtlasFrame.tabNearby)

BeastAtlasSearch.__text = RU and "волк" or "wolf"
__run(BeastAtlasSearch, "OnTextChanged")
__advance(0.5)
BeastAtlasSearch.__text = ""
__run(BeastAtlasSearch, "OnTextChanged")
__advance(0.5)
ns.ShowBeast(next(ns.BEASTS))
do
    -- the detail pane names the stable master nearest to the beast's habitat; a click sets a waypoint there
    local line
    for _, f in ipairs(__frames) do
        if f.__kind == "Button" and rawget(f, "text") and rawget(f, "stableId") ~= nil and f ~= (BeastAtlasHelperFrame and BeastAtlasHelperFrame.stable) then line = f end
    end
    local shownFor, hiddenFor, fromYouSeen = 0, 0, 0
    for bid, b in pairs(ns.BEASTS) do
        if shownFor < 5 or hiddenFor < 2 or fromYouSeen < 3 then
            ns.ShowBeast(bid)
            local sid, spot, dist = ns.NearestStableToBeast(bid)
            if not line then
                for _, f in ipairs(__frames) do
                    if f.__kind == "Button" and rawget(f, "text") and rawget(f, "stableId") ~= nil
                        and f ~= (BeastAtlasHelperFrame and BeastAtlasHelperFrame.stable) then line = f end
                end
            end
            if sid then
                shownFor = shownFor + 1
                check(line and line:IsShown() and line.text:GetText():find(loc(ns.STABLES[sid]), 1, true),
                    "detail pane: no stable master near the habitat of " .. b.en)
                -- how far: from the hunter to the stable master (counted here from the map API), then on to the beast
                local st = ns.STABLES[sid]
                local _, sp = C_Map.GetWorldPosFromMapPos(ns.ZoneMap(st.z), CreateVector2D(st.c[spot] / 1000, st.c[spot + 1] / 1000))
                local pc, pp = C_Map.GetWorldPosFromMapPos(__playerMap, CreateVector2D(__playerPos.x, __playerPos.y))
                local sc = C_Map.GetWorldPosFromMapPos(ns.ZoneMap(st.z), CreateVector2D(0, 0))
                local subText = line and line.sub:GetText() or ""
                if sc == pc then
                    local yards = math.floor(math.sqrt((sp.x - pp.x) ^ 2 + (sp.y - pp.y) ^ 2) + 0.5)
                    check(subText:find(L.STABLE_FROM_YOU:format(ns.DistanceText(yards)), 1, true),
                        ("detail pane: distance from the hunter to the stable master missing or wrong for %s: %s"):format(b.en, subText))
                    fromYouSeen = fromYouSeen + 1
                else
                    check(not subText:find(L.STABLE_FROM_YOU:format(""), 1, true), "detail pane: a distance to a stable master on another continent")
                end
                check(subText:find(dist < 1 and L.STABLE_AT_HABITAT or L.STABLE_TO_HABITAT:format(ns.DistanceText(math.floor(dist + 0.5))), 1, true),
                    "detail pane: distance from the stable master to the habitat missing for " .. b.en)
                check((line.text:GetText():find(ns.ZoneName(st.z), 1, true) ~= nil) == (st.z ~= b.z), "detail pane: the zone is named only when it differs: " .. b.en)
                __waypoint = nil
                if line then line.__scripts.OnClick(line) end
                check(__waypoint and __waypoint[1] == ns.ZoneMap(ns.STABLES[sid].z)
                    and math.abs(__waypoint[2] - ns.STABLES[sid].c[spot] / 1000) < 1e-9, "detail pane: stable click set no waypoint")
                if line then line.__scripts.OnEnter(line); line.__scripts.OnLeave(line) end
            else
                hiddenFor = hiddenFor + 1
                check(not line or not line:IsShown(), "detail pane: stable line shown for a beast with no known habitat: " .. b.en)
            end
        end
    end
    check(shownFor >= 5 and hiddenFor >= 1 and fromYouSeen >= 3,
        ("detail pane stable line: shown %d, hidden %d, with the hunter's distance %d"):format(shownFor, hiddenFor, fromYouSeen))
end
ns.ShowStack({ next(ns.BEASTS) })
if stackSeen then
    stackSeen:OnClick("LeftButton")
    __SHIFT = true; stackSeen:OnClick("LeftButton"); __SHIFT = false
end
WorldMapFrame:SetMapID(someZone)
local onePin = __map.pins[ICON][1]
onePin:OnClick("LeftButton")
onePin:OnClick("RightButton")
ns.SetOption("scale", 1.1)
ns.SetOption("names", "local")
ns.SetOption("showLearned", true)
ns.SetOption("petOnly", false)
__advance(1)
ns.RefreshWindow()
BeastAtlasFrame.tabAbilities.__scripts.OnClick(BeastAtlasFrame.tabAbilities)
ns.SetOption("names", "both")
ns.SetOption("showLearned", false)
ns.SetOption("petOnly", true)
__advance(6) -- ticker
-- open on map + highlight reset
local withCoords
for id, b in pairs(ns.BEASTS) do if #b.c > 0 and ns.ZoneMap(b.z) then withCoords = id break end end
check(ns.OpenMapFor(withCoords), "OpenMapFor failed")
check(ns.highlight == withCoords, "highlight not set")
__advance(0.5)
check(habitatsShown() == #ns.BEASTS[withCoords].c / 3, "the beast opened from the atlas should have its habitats drawn")
ns.SetWaypoint(withCoords)
check(__waypoint ~= nil, "waypoint not set")
WorldMapFrame:Hide()
check(ns.highlight == nil, "highlight not cleared when the map closes")
slash("map"); slash("map"); slash("help")

-------------------------------------------------------------------------------
-- 10. tooltip on a wild beast
-------------------------------------------------------------------------------
check(__unitTooltip, "unit tooltip hook not installed")
__U.mouseover = { name = "Wild", guid = "Creature-0-1-1-1-" .. withCoords .. "-000A" }
GameTooltip.__lines = {}
__unitTooltip(GameTooltip)
check(#GameTooltip.__lines > 0, "tooltip added no lines")
-- another client language: the family name seen on a known beast is remembered
__U.mouseover.family = "Zzfamilie"
__unitTooltip(GameTooltip)
check(ns.FamilyKey("Zzfamilie") == ns.BEASTS[withCoords].f, "localized family name not learned")
check(ns.FamilyKey("ZZFAMILIE") == ns.BEASTS[withCoords].f, "learned family name is case-sensitive")
-- in a dungeon the tooltip's unit is a secret value: the hook must leave it alone (UnitGUID would raise)
do
    local getUnit = GameTooltip.GetUnit
    GameTooltip.GetUnit = function() return __secret(), __secret() end
    GameTooltip.__lines = {}
    local ok, err = pcall(__unitTooltip, GameTooltip)
    check(ok, "the tooltip hook fails on a secret unit: " .. tostring(err))
    check(#GameTooltip.__lines == 0, "the tooltip hook added lines for a secret unit")
    GameTooltip.GetUnit = getUnit
    -- a readable unit whose GUID and name are secret: no lines, no error
    local guid = __U.mouseover.guid
    __U.mouseover.guid = __secret()
    ok, err = pcall(__unitTooltip, GameTooltip)
    check(ok, "the tooltip hook fails on a secret GUID: " .. tostring(err))
    check(#GameTooltip.__lines == 0, "the tooltip hook added lines for a secret GUID")
    __U.mouseover.guid, __U.mouseover.name = guid, __secret()
    ok, err = pcall(__unitTooltip, GameTooltip)
    check(ok, "the tooltip hook fails on a secret unit name: " .. tostring(err))
    check(#GameTooltip.__lines > 0, "a secret unit name should not hide the tooltip lines")
end
__U.mouseover = nil

-------------------------------------------------------------------------------
-- 11. learning from a tame
-------------------------------------------------------------------------------
local catName = loc(ns.FAMILIES.Cat)
local function tame(npcId, beastName, petName)
    __U.target = { name = beastName, family = catName, level = 20, guid = "Creature-0-1-1-1-" .. npcId .. "-00FF" }
    __fire("UNIT_SPELLCAST_SENT", "player", beastName, "Cast-1", 1515)
    __fire("UNIT_SPELLCAST_CHANNEL_START", "player", "Cast-1", 1515)
    __U.target = nil
    __U.pet = { name = petName, family = catName, level = 20, guid = "Pet-0-1-1-1-" .. npcId .. "-0003" }
    -- the first read has no rank text yet: it must be retried, not stored as rank 1
    __petSpells = { { loc(ability("claw")), "" }, petSpell("bite", 2), petSpell("growl", 1) }
    __fire("UNIT_PET", "player")
    __advance(1.6)
    __petSpells = { petSpell("claw", 3), petSpell("bite", 2), petSpell("growl", 1) }
    __advance(3)
end
__playerMap, __playerPos = 1429, { x = 0.4, y = 0.5 }
mark = #__out
tame(99999, "Test Stalker", "Test Stalker")
local obs = ns.db.observed[99999]
check(obs and #obs.t == 4 and obs.t[1] == "bite" and obs.t[2] == 2 and obs.t[3] == "claw" and obs.t[4] == 3,
    "tame not recorded completely (partial read must be retried, trainer abilities skipped)")
local nb = ns.BEASTS[99999]
check(nb and nb.o and nb.z == "Elwynn Forest" and nb.c[1] == 400 and nb.c[2] == 500, "observed beast not merged")
local found = false
for _, id in ipairs(ability("claw").ranks[3].beasts) do if id == 99999 then found = true end end
check(found, "indexes not rebuilt after a tame")
check(outHas(L.OBSERVED:format("Test Stalker", loc(ability("bite")) .. " 2, " .. loc(ability("claw")) .. " 3"), mark),
    "OBSERVED line missing")
check(ns.cdb.main.name == "Fang", "a tame changed the main pet")
check(ns.KnownRank("claw") == 0, "a tame marked a rank as known")
local before = #ns.BEASTS[99999].t
ns.MergeObserved(); ns.MergeObserved()
check(#ns.BEASTS[99999].t == before, "MergeObserved is not idempotent")
-- a renamed pet from the stable after a failed tame must not be recorded
tame(88888, "Other Stalker", "Fluffy")
check(ns.db.observed[88888] == nil, "a renamed stable pet was recorded as a tame")
-- a non-tame cast is ignored
__U.target = { name = "X", family = catName, level = 20, guid = "Creature-0-1-1-1-77777-00FF" }
__fire("UNIT_SPELLCAST_SENT", "player", "X", "Cast-2", 75)
__U.pet = { name = "X", family = catName, level = 20, guid = "Pet-0-1-1-1-77777-0004" }
__fire("UNIT_PET", "player")
__advance(3)
check(ns.db.observed[77777] == nil, "a non-tame cast was recorded")
__U.target = nil

-------------------------------------------------------------------------------
-- 12. zone tip
-------------------------------------------------------------------------------
__U.pet = savedPet
__petSpells = { petSpell("bite", 2) }
__fire("UNIT_PET", "player")
__advance(1)
local readyZone, readyCount
for mapID, ids in pairs(ns.BeastsByMap()) do
    local n = 0
    for _, id in ipairs(ids) do if ns.BeastUseful(id) == S.READY then n = n + 1 end end
    if n > 0 and mapID ~= 1429 then readyZone, readyCount = mapID, n break end
end
check(readyZone, "no zone with READY beasts for the main pet")
if readyZone then
    __playerMap = readyZone
    mark = #__out
    __fire("ZONE_CHANGED_NEW_AREA")
    __advance(3)
    local prefix = L.NOTIFY_ZONE:match("^(.-)%%d") -- text before the count, same in both locales' order
    local seen = false
    for i = mark + 1, #__out do if __out[i]:find(tostring(readyCount), 1, true) and __out[i]:find("/ba", 1, true) then seen = true end end
    check(seen, "zone tip missing")
    mark = #__out
    __fire("ZONE_CHANGED_NEW_AREA")
    __advance(3)
    check(#__out == mark, "zone tip repeated for the same zone")
end

-------------------------------------------------------------------------------
-- 13. training helper: the four steps for one rank, start to finish
-------------------------------------------------------------------------------
do
    local function goal() return ns.TrainingGoals()[1] end
    local function settle() __advance(1.5) end
    local function panelShown() return BeastAtlasHelperFrame ~= nil and BeastAtlasHelperFrame:IsShown() end
    local function panelText()
        local t = {}
        for _, fs in ipairs(BeastAtlasHelperFrame.lines) do if fs:IsShown() then t[#t + 1] = fs:GetText() end end
        return BeastAtlasHelperFrame.title:GetText() .. "\n" .. table.concat(t, "\n")
    end
    local wolf = loc(ns.FAMILIES.Wolf)
    local bite3 = loc(ability("bite")) .. " 3"
    -- the line with the nearest stable master (a button under the steps)
    local function stableLine()
        local s = BeastAtlasHelperFrame and BeastAtlasHelperFrame.stable
        return s and s:IsShown() and s.text:GetText() or nil
    end
    local function expectedStable()
        local id, spot, dist = ns.NearestStableToPlayer()
        return id and ns.StableText(id, dist), id, spot
    end
    __playerMap, __playerPos = ns.ZoneMap("The Barrens"), { x = 0.5, y = 0.5 }

    -- start: main pet Fang (Wolf, 24) with Bite 2, the hunter knows nothing
    __U.target = nil
    __U.player.level = 30
    __U.pet = { name = "Fang", family = wolf, level = 24, guid = "Pet-0-1-1-1-100-0001" }
    __petSpells = { petSpell("bite", 2) }
    wipe(ns.cdb.known)
    ns.Changed()
    __fire("UNIT_PET", "player")
    settle()
    slash("main")
    settle()
    check(ns.cdb.main.name == "Fang" and ns.cdb.main.ranks.bite == 2, "helper setup: main pet")
    check(#ns.TrainingGoals() == 0, "helper shows goals when there is nothing to do")
    check(not panelShown(), "helper panel visible with nothing to do")

    -- step 1: target a wild beast that teaches a rank the pet needs now
    local teacherId
    for _, id in ipairs(ability("bite").ranks[4].beasts) do
        if ns.BEASTS[id].l[1] <= 30 then teacherId = id break end
    end
    check(teacherId, "helper setup: no tameable Bite 4 teacher")
    __U.target = { name = "Wild", level = 25, guid = "Creature-0-1-1-1-" .. teacherId .. "-00AA" }
    __fire("PLAYER_TARGET_CHANGED")
    settle()
    local g = goal()
    check(g and g.stage == 1 and g.ab.key == "bite" and g.rank == 4 and g.targetId == teacherId,
        "helper step 1 (target teaches a needed rank)")
    -- a pet is out: taming is impossible until it is stabled, and the panel must say so
    local teacherName = (ns.Names(ns.BEASTS[teacherId]))
    check(panelShown() and panelText():find(L.HELPER_STEP1_STABLE:format(teacherName), 1, true),
        "helper step 1 does not say to stable the current pet first")
    -- ... and where the nearest stable master is; a click sets the waypoint there
    do
        local text, sid, spot = expectedStable()
        check(text and stableLine() and stableLine():find(text, 1, true), "helper step 1: no nearest stable master while a pet is out")
        check(stableLine() and stableLine():find(L.STABLE_STRAIGHT, 1, true), "helper: the stable line does not say the distance is a straight line")
        local stable = BeastAtlasHelperFrame.stable
        __waypoint = nil
        stable.__scripts.OnClick(stable)
        check(__waypoint and sid and __waypoint[1] == ns.ZoneMap(ns.STABLES[sid].z)
            and math.abs(__waypoint[2] - ns.STABLES[sid].c[spot] / 1000) < 1e-9, "helper: clicking the stable line set no waypoint on it")
        -- the panel is tall enough for it: the same step without the line is shorter
        local withLine = BeastAtlasHelperFrame.__h
        __playerPos = nil
        ns.Changed()
        settle()
        check(panelShown() and not stableLine(), "helper: stable line shown without a player position")
        check(BeastAtlasHelperFrame.__h < withLine, "helper: the panel height ignores the stable line")
        __playerPos = { x = 0.5, y = 0.5 }
        ns.Changed()
        settle()
        check(stableLine(), "helper: stable line not restored")
    end
    -- no pet out: just "tame your target"
    local keepPet = __U.pet
    __U.pet = nil
    __fire("UNIT_PET", "player")
    settle()
    check(panelShown() and panelText():find(L.HELPER_STEP1_TARGET:format(teacherName), 1, true)
        and not panelText():find(L.HELPER_STEP1_STABLE:format(teacherName), 1, true),
        "helper step 1 without a pet should just name the target")
    check(not stableLine(), "helper step 1 without a pet out needs no stable master")
    __U.pet = keepPet
    __fire("UNIT_PET", "player")
    settle()
    -- closing this step keeps it closed when the same beast is targeted again
    BeastAtlasHelperFrame.close.__scripts.OnClick(BeastAtlasHelperFrame.close)
    __U.target = nil
    __fire("PLAYER_TARGET_CHANGED")
    settle()
    __U.target = { name = "Wild", level = 25, guid = "Creature-0-1-1-1-" .. teacherId .. "-00AA" }
    __fire("PLAYER_TARGET_CHANGED")
    settle()
    check(goal() and goal().stage == 1 and not panelShown(), "a closed step 1 came back on re-targeting")
    -- a target that only teaches a rank below the one worth getting is not a step 1
    local lowId
    for _, id in ipairs(ability("bite").ranks[3].beasts) do -- Bite 3: above the pet's Bite 2, below the Bite 4 it can get
        local b = ns.BEASTS[id]
        if #b.t == 2 and b.l[1] <= 30 then lowId = id break end
    end
    check(lowId, "helper setup: no Bite 3-only beast")
    __U.target = { name = "Low", level = 3, guid = "Creature-0-1-1-1-" .. lowId .. "-00AB" }
    __fire("PLAYER_TARGET_CHANGED")
    settle()
    check(#ns.TrainingGoals() == 0 and not panelShown(), "helper suggests taming for an obsolete rank")
    __U.target = nil
    __fire("PLAYER_TARGET_CHANGED")
    settle()
    check(not panelShown(), "helper panel stays after the target is gone")

    -- step 2: a tamed teacher is out (not the main pet) and knows Bite 3
    __U.pet = { name = "Worg", family = wolf, level = 16, guid = "Pet-0-1-1-1-200-0009" }
    __petSpells = { petSpell("bite", 3) }
    __fire("UNIT_PET", "player")
    settle()
    g = goal()
    check(g and g.stage == 2 and g.rank == 3 and g.forMain, "helper step 2 (teacher pet is out)")
    check(panelShown() and not stableLine(), "helper step 2 should not point to a stable master")
    check(panelShown() and panelText():find(bite3, 1, true), "helper panel not shown for the teacher")
    -- closing the panel hides it until the situation changes
    check(panelText():find(L.HELPER_STEP2_HINT, 1, true), "helper step 2 hint missing")
    BeastAtlasHelperFrame.close.__scripts.OnClick(BeastAtlasHelperFrame.close)
    check(not panelShown(), "helper panel did not close")
    ns.Changed() -- a redraw with the same step must not bring it back
    settle()
    check(not panelShown(), "a closed helper panel came back without any change")
    -- another step in between must not make it forget what was closed
    __U.target = { name = "Wild", level = 25, guid = "Creature-0-1-1-1-" .. teacherId .. "-00AA" }
    __fire("PLAYER_TARGET_CHANGED")
    settle()
    __U.target = nil
    __fire("PLAYER_TARGET_CHANGED")
    settle()
    check(not panelShown(), "a closed step came back after an unrelated step was shown")
    check(ns.cdb.helperDismissed["bite:4:1"] and ns.cdb.helperDismissed["bite:3:2"],
        "closing a second step forgot the first one")

    -- the chat says the rank is learned: step 3 (summon the main pet)
    ns.cdb.known.bite = 3
    ns.Changed()
    settle()
    g = goal()
    check(g and g.stage == 3 and g.rank == 3, "helper step 3 (learned, main pet not out): " .. tostring(g and g.stage))
    check(panelShown() and panelText():find(L.HELPER_STEP3:format("Fang"), 1, true), "helper panel step 3 text")

    -- step 4: the main pet is out
    __U.pet = { name = "Fang", family = wolf, level = 24, guid = "Pet-0-1-1-1-100-0001" }
    __petSpells = { petSpell("bite", 2) }
    __fire("UNIT_PET", "player")
    settle()
    g = goal()
    check(g and g.stage == 4 and g.tp == ability("bite").ranks[3].tp, "helper step 4 (main pet out)")
    check(panelShown() and panelText():find(L.TP:format(ability("bite").ranks[3].tp), 1, true), "helper panel step 4 cost")

    -- taught at Beast Training: the pet's spellbook now has Bite 3 and the helper is done
    __petSpells = { petSpell("bite", 3) }
    __fire("SPELLS_CHANGED")
    settle()
    check(#ns.TrainingGoals() == 0, "helper goal not finished after the pet learned the rank")
    check(not panelShown(), "helper panel visible after the goal is done")

    -- no pet out at all (flight path, dismissed): nothing to prompt for, even with a rank waiting
    ns.cdb.known.bite = 4
    ns.Changed()
    settle()
    check(goal() and goal().stage == 4 and goal().rank == 4, "helper: rank waiting to be taught")
    __U.pet = nil
    __fire("UNIT_PET", "player")
    settle()
    -- the teacher was abandoned and the main pet is in the stable: still step 3 ...
    check(goal() and goal().stage == 3 and panelShown(), "helper: no step 3 when no pet is out")
    -- the main pet waits in a stable: say where the nearest one is, and keep the distance fresh while walking
    do
        local text = expectedStable()
        check(text and stableLine() and stableLine():find(text, 1, true), "helper step 3: no nearest stable master")
        __playerPos = { x = 0.9, y = 0.1 }
        local moved = expectedStable()
        check(moved ~= text, "helper setup: moving should change the stable text")
        __advance(6)
        check(stableLine() and stableLine():find(moved, 1, true), "helper: the distance to the stable master is not refreshed")
        __playerPos = { x = 0.5, y = 0.5 }
        __advance(6)
    end
    -- ... but not on a flight path, where the pet is only hidden
    __onTaxi = true
    ns.Changed()
    settle()
    check(#ns.TrainingGoals() == 0 and not panelShown(), "helper nags on a flight path")
    check(BeastAtlasHelperFrame.ticker == nil, "helper: the stable ticker keeps running after the panel is hidden")
    __onTaxi = false
    -- training points: the rank being replaced is refunded (30 total, 12 used in the stub = 18 free)
    __U.pet = { name = "Fang", family = wolf, level = 24, guid = "Pet-0-1-1-1-100-0001" }
    __fire("UNIT_PET", "player")
    settle()
    local r3, r4 = ability("bite").ranks[3].tp, ability("bite").ranks[4].tp
    check(goal() and goal().stage == 4 and r4 - r3 <= 18, "helper setup: Bite 4 should be affordable after the refund")
    check(panelShown() and not stableLine() and BeastAtlasHelperFrame.ticker == nil, "helper step 4 should not point to a stable master")
    -- from step 3 (line and timer on) straight to step 4, the panel never hidden: the timer must stop
    __U.pet = nil
    __fire("UNIT_PET", "player")
    settle()
    check(goal().stage == 3 and stableLine() and BeastAtlasHelperFrame.ticker ~= nil, "helper setup: step 3 with the stable timer")
    __U.pet = { name = "Fang", family = wolf, level = 24, guid = "Pet-0-1-1-1-100-0001" }
    __fire("UNIT_PET", "player")
    settle()
    check(goal().stage == 4 and panelShown() and BeastAtlasHelperFrame.ticker == nil, "helper: the stable timer keeps running on step 4")
    local warning = L.HELPER_TP_SHORT:match("^[^%%]+") -- the text before the first number
    check(not panelText():find(warning, 1, true), "helper warns although the refund covers the cost")
    ns.cdb.known.bite = 3
    ns.Changed()

    -- an ability the main pet's family cannot learn: only steps 1-2 and a note
    __U.pet = { name = "Boar", family = loc(ns.FAMILIES.Boar), level = 12, guid = "Pet-0-1-1-1-300-0010" }
    __petSpells = { petSpell("charge", 2) }
    __fire("UNIT_PET", "player")
    settle()
    g = goal()
    check(g and g.stage == 2 and g.ab.key == "charge" and not g.forMain, "helper: teacher of an ability the main pet can't learn")
    check(panelShown() and panelText():find(L.HELPER_NOT_FOR_MAIN:format("Fang"), 1, true), "helper note for other pets missing")
    ns.cdb.known.charge = 2
    ns.Changed()
    settle()
    check(#ns.TrainingGoals() == 0, "helper keeps a goal the main pet can never use")

    -- option off
    __petSpells = { petSpell("charge", 3) }
    __fire("SPELLS_CHANGED")
    settle()
    check(panelShown(), "helper did not react to a spellbook change of the same pet")
    ns.SetOption("helper", false)
    settle()
    check(not panelShown(), "helper panel shown with the option off")
    ns.SetOption("helper", true)
    settle()
    check(panelShown(), "helper panel not restored")
    __U.pet = { name = "Fang", family = wolf, level = 24, guid = "Pet-0-1-1-1-100-0001" }
    __petSpells = { petSpell("bite", 3) }
    __fire("UNIT_PET", "player")
    settle()
    __playerMap, __playerPos = 1429, { x = 0.5, y = 0.5 }
end

-------------------------------------------------------------------------------
-- 14. Families tab: the guide, the family cards, the beasts as pets
-------------------------------------------------------------------------------
do
    local wasShown = BeastAtlasFrame:IsShown()
    if not wasShown then slash("") end
    local win = BeastAtlasFrame
    local function tab(name) win[name].__scripts.OnClick(win[name]) end
    -- the list (holder) whose data satisfies pred, among the shown ones
    local function list(pred)
        for _, f in ipairs(__frames) do
            if rawget(f, "SetData") and f:IsShown() and pred(f.data) then return f end
        end
    end
    local function rowOf(d)
        for _, f in ipairs(__frames) do
            for _, row in ipairs(rawget(f, "__active") or {}) do
                if row.data == d then return row end
            end
        end
    end
    local function click(d)
        local row = rowOf(d)
        check(row, "row not drawn: " .. tostring(d.kind))
        if row then row.__scripts.OnClick(row, "LeftButton") end
    end
    local function families() return list(function(data) return data[1] and data[1].kind == "guide" end) end
    local function pane() return list(function(data) return data[1] and data[1].kind == "group" and data[2] and data[2].kind == "text" end) end
    local function allText(data)
        local parts = {}
        for _, d in ipairs(data) do parts[#parts + 1] = d.text or "" end
        return table.concat(parts, "\n")
    end
    local level = 30
    __U.player.level = level
    __playerMap, __playerPos = 1429, { x = 0.5, y = 0.5 }
    -- The test's own reading of the data: a creature is a teacher (ns.BEASTS) or only in the wider list
    -- (ns.PETS). A Horde hunter can tame it some day unless Petopia says "cannot be tamed", it is for
    -- Alliance hunters only, or its level is unknown; and now, when it is not above the hunter.
    local function entry(id) return ns.BEASTS[id] or ns.PETS[id] end
    local function everTame(id)
        local p = ns.PETS[id]
        return not (p and (p.tame == false or p.side == "A")) and entry(id).l[1] > 0
    end
    local function tameNow(id, lvl) return everTame(id) and entry(id).l[1] <= lvl end
    local allPets, teachersOnly, extraOnly = {}, 0, 0
    for id in pairs(ns.BEASTS) do
        if everTame(id) then allPets[#allPets + 1] = id; teachersOnly = teachersOnly + 1 end
    end
    for id in pairs(ns.PETS) do
        if not ns.BEASTS[id] and everTame(id) then allPets[#allPets + 1] = id; extraOnly = extraOnly + 1 end
    end
    check(teachersOnly >= 370 and extraOnly >= 200, ("test setup: %d teachers, %d other pets"):format(teachersOnly, extraOnly))
    for id in pairs(ns.PETS) do
        local ok, why = ns.TameState(id, level)
        check(ok == tameNow(id, level), "TameState differs from the data for " .. id)
        local p = ns.PETS[id]
        local want = p.tame == false and "never" or p.side == "A" and "side" or entry(id).l[1] <= 0 and "unknown"
            or entry(id).l[1] > level and "level" or nil
        check(why == want, ("TameState reason for %d: %s, expected %s"):format(id, tostring(why), tostring(want)))
    end
    ns.SetOption("petOnly", true) -- must not hide anything here: this tab is not about the main pet's ranks
    ns.Changed()
    tab("tabFamilies")
    check(win.selectedTab == 3, "Families tab not selected")
    for _, control in ipairs(win.filters) do check(not control:IsShown(), "rank filters shown on the Families tab") end

    -- the list: the guide first, then every family once, under its role
    local fl = families()
    check(fl, "family list not shown")
    local seen, count, role = {}, 0, nil
    local roleByText = { [L.ROLE_O] = "O", [L.ROLE_G] = "G", [L.ROLE_D] = "D" }
    for i, d in ipairs(fl and fl.data or {}) do
        if d.kind == "group" then
            role = roleByText[d.text]
            check(role, "unknown role group: " .. tostring(d.text))
        elseif d.kind == "family" then
            check(ns.FAMILIES[d.key].role == role, "family under the wrong role: " .. d.key)
            check(not seen[d.key], "family listed twice: " .. d.key)
            seen[d.key] = true
            count = count + 1
            check(d.main == (d.key == "Wolf"), "main pet's family flag wrong: " .. d.key)
            local row = rowOf(d)
            check(row and row.text.__text:find(loc(ns.FAMILIES[d.key]), 1, true), "family row has no name: " .. d.key)
        else
            check(i == 1 and d.kind == "guide", "unexpected row in the family list: " .. tostring(d.kind))
        end
    end
    local total = 0
    for _ in pairs(ns.FAMILIES) do total = total + 1 end
    check(count == total and total == 18, ("families listed: %d of %d"):format(count, total))

    -- the guide is what opens first
    local gp = pane()
    check(gp and gp.data[1].text == L.GUIDE_TITLE, "the guide is not the first view of the Families tab")
    local guide = gp and gp.data or {}
    local text = allText(guide)
    for _, key in ipairs({ "GUIDE_INTRO", "GUIDE_ABIL", "GUIDE_SPEED", "GUIDE_LEVEL", "GUIDE_ROLE", "GUIDE_FOOD", "GUIDE_SOURCE" }) do
        check(text:find(L[key], 1, true), "guide lacks " .. key)
    end
    for key, fam in pairs(ns.FAMILIES) do
        check(text:find(loc(fam), 1, true), "guide does not place the family under a role: " .. key)
    end
    -- the widest and the one-food diets, counted independently
    local most = 0
    for _, fam in pairs(ns.FAMILIES) do most = math.max(most, #fam.diet) end
    for _, d in ipairs(guide) do
        if d.kind == "text" and d.text:find(L.GUIDE_FOOD_WIDE, 1, true) then
            -- the rest of the line that carries the given label (plain search: the labels are not patterns)
            local function lineAfter(label)
                local _, e = d.text:find(label, 1, true)
                if not e then return nil end
                return d.text:sub(e + 1, (d.text:find("\n", e, true) or #d.text + 1) - 1)
            end
            local wide, one = lineAfter(L.GUIDE_FOOD_WIDE), lineAfter(L.GUIDE_FOOD_ONE)
            check(wide and one, "diet lines missing")
            for _, fam in pairs(ns.FAMILIES) do
                check(((wide or ""):find(loc(fam), 1, true) ~= nil) == (#fam.diet == most), "widest diet list wrong for " .. fam.en)
                check(((one or ""):find(loc(fam) .. " (", 1, true) ~= nil) == (#fam.diet == 1), "one-food list wrong for " .. fam.en)
            end
        end
    end
    -- paragraphs: each row is as tall as its own text at its own width
    local paragraphs = 0
    for _, d in ipairs(guide) do
        local row = d.kind == "text" and rowOf(d)
        if row then
            paragraphs = paragraphs + 1
            check(row.text.__text == d.text, "paragraph row shows another text")
            check(row.__extent == d.height, "paragraph extent differs from the measured height")
            check(d.height == math.max(20, row.text:GetStringHeight() + 12),
                "paragraph height was measured at another width or for another text")
        end
    end
    check(paragraphs >= 6, "guide paragraphs drawn: " .. paragraphs)
    local short, long = guide[2].height, 0
    for _, d in ipairs(guide) do if d.kind == "text" then long = math.max(long, d.height) end end
    check(long > short or long > 20, "all paragraphs have the same height: nothing was measured")

    -- the fastest beasts follow the speed paragraph, fastest first
    local minSpeed = 99
    for _, id in ipairs(allPets) do
        local b = entry(id)
        if b.s and b.s < minSpeed then minSpeed = b.s end
    end
    local fastest, fastNow, nearby, section, nowList = {}, {}, {}, nil, false
    local nowText = L.GUIDE_FASTEST_NOW:format(level)
    for _, d in ipairs(guide) do
        if d.kind == "group" then section = d.text
        elseif d.kind == "text" and d.text == nowText then nowList = true
        elseif d.kind == "pet" and section == L.GUIDE_H_SPEED then
            if nowList then fastNow[#fastNow + 1] = d else fastest[#fastest + 1] = d end
        elseif d.kind == "pet" and section == L.GUIDE_H_NEARBY then nearby[#nearby + 1] = d end
    end
    -- the fastest of those a level 30 hunter can tame: quicker than 2.0, fastest first, then the higher level
    local want = {}
    for _, id in ipairs(allPets) do
        local b = entry(id)
        if b.s and b.s < 2 and tameNow(id, level) then want[#want + 1] = id end
    end
    table.sort(want, function(a, b)
        local ba, bb = entry(a), entry(b)
        if ba.s ~= bb.s then return ba.s < bb.s end
        if ba.l[2] ~= bb.l[2] then return ba.l[2] > bb.l[2] end
        return a < b
    end)
    check(nowList and #fastNow == math.min(5, #want) and #want >= 5, "fastest tameable beasts: list missing or wrong length: " .. #fastNow)
    for i, d in ipairs(fastNow) do
        check(d.id == want[i], "fastest tameable beasts: wrong beast at " .. i)
        check(d.tame and tameNow(d.id, level), "a beast that cannot be tamed yet among the tameable ones")
    end
    check(#fastest == 5 and entry(fastest[1].id).s == minSpeed, "fastest beasts: wrong count or not the fastest first")
    for i = 2, #fastest do
        check(entry(fastest[i - 1].id).s <= entry(fastest[i].id).s, "fastest beasts not sorted by speed")
    end
    for _, d in ipairs(fastest) do check(everTame(d.id), "a beast nobody can tame among the fastest: " .. entry(d.id).en) end
    -- "worth taming now": level window, known distance, at most two families per role, the nearest of each role
    local cont, px, py = ns.PlayerWorldPos()
    check(cont, "test setup: no player position")
    local best, perRole, famSeen = {}, {}, {}
    for id, b in pairs(ns.BEASTS) do
        local dist = ns.BeastDistance(id, cont, px, py)
        local r = ns.FAMILIES[b.f].role
        if dist and b.l[1] <= level and b.l[2] >= level - 3 and (not best[r] or dist < best[r]) then best[r] = dist end
    end
    check(#nearby > 0, "no beasts suggested for a level 30 hunter in Elwynn")
    for _, d in ipairs(nearby) do
        local b = ns.BEASTS[d.id]
        local r = ns.FAMILIES[b.f].role
        check(d.tame and b.l[1] <= level, "suggested a beast above the hunter's level: " .. b.en)
        check(b.l[2] >= level - 3, "suggested a beast far below the hunter: " .. b.en)
        check(d.dist ~= nil, "suggested a beast with no known distance: " .. b.en)
        check(not famSeen[b.f], "suggested the same family twice: " .. b.f)
        famSeen[b.f] = true
        if not perRole[r] then check(d.dist == best[r], "the first pick of role " .. r .. " is not the nearest one") end
        perRole[r] = (perRole[r] or 0) + 1
        check(perRole[r] <= 2, "more than two picks for role " .. r)
    end
    for r, dist in pairs(best) do check(perRole[r], "role " .. r .. " has candidates but no pick") end
    local petRow = rowOf(nearby[1] or fastest[1])
    check(petRow and petRow.sub.__text:find(L.PET_SPEED:format(""), 1, true), "pet row shows no attack speed")
    check(petRow and petRow.sub.__text:find(L["ROLE_" .. ns.FAMILIES[entry(petRow.data.id).f].role], 1, true),
        "pet row in the guide shows no role")

    -- below level 10 nothing can be tamed
    __U.player.level = 9
    ns.Changed()
    ns.RefreshWindow()
    local low = pane().data
    check(allText(low):find(L.GUIDE_NEARBY_L10, 1, true), "no level 10 note for a level 9 hunter")
    section = nil
    for _, d in ipairs(low) do
        if d.kind == "group" then section = d.text end
        check(not (d.kind == "pet" and section == L.GUIDE_H_NEARBY), "taming suggested below level 10")
        check(not (d.kind == "pet" and d.tame and entry(d.id).l[1] > 9), "beast above level 9 marked tameable")
        check(not (d.kind == "text" and d.text == L.GUIDE_FASTEST_NOW:format(9)), "tameable list offered below level 10")
    end
    -- at 60 every beast can be tamed: the second list would repeat the first one
    __U.player.level = 60
    ns.Changed()
    ns.RefreshWindow()
    for _, d in ipairs(pane().data) do
        check(not (d.kind == "text" and d.text == L.GUIDE_FASTEST_NOW:format(60)), "the tameable list repeats the fastest list at level 60")
    end
    __U.player.level = level
    ns.Changed()
    ns.RefreshWindow()

    -- every family card
    local cards, plainRows = 0, 0
    for _, entry0 in ipairs(families().data) do
        if entry0.kind == "family" then
            local key, fam = entry0.key, ns.FAMILIES[entry0.key]
            click(entry0)
            local card = pane().data
            cards = cards + 1
            check(card[1].kind == "group" and card[1].text:find(loc(fam), 1, true), "card title: " .. key)
            local info = card[2].text
            check(info:find(L["ROLE_" .. fam.role], 1, true), "card lacks the role: " .. key)
            for _, food in ipairs(fam.diet) do
                check(info:find(L["FOOD_" .. food], 1, true), "card lacks food " .. food .. ": " .. key)
            end
            check((info:find(L.FAM_YOURS, 1, true) ~= nil) == (key == "Wolf"), "'your pet' line wrong: " .. key)
            -- abilities: exactly the beast-taught ones this family can learn, its own one first
            local want, got, firstOwn = {}, {}, nil
            for _, ab in ipairs(ns.ABILITIES) do
                local can = false
                for _, f in ipairs(ab.families) do can = can or f == "*" or f == key end
                if can and not ab.trainer then want[ab.key] = true end
            end
            local function learners(ab) -- how many families of the atlas can learn it
                local n = 0
                for famKey in pairs(ns.FAMILIES) do
                    for _, f in ipairs(ab.families) do
                        if f == "*" or f == famKey then n = n + 1 break end
                    end
                end
                return n
            end
            local pets, tameEnded, flagged = 0, false, 0
            for _, d in ipairs(card) do
                if d.kind == "ability" then
                    check(want[d.ab.key] and not got[d.ab.key], "card lists a wrong ability: " .. key .. " " .. d.ab.key)
                    got[d.ab.key] = true
                    if firstOwn == nil then firstOwn = d.right ~= nil end
                    check((d.right ~= nil) == (learners(d.ab) == 1), "'this family only' flag wrong: " .. key .. " " .. d.ab.key)
                    check(not (d.right and d.ab.key == "cower"), "Cower is open to every family: " .. key)
                    if d.right then flagged = flagged + 1 end
                elseif d.kind == "pet" then
                    local b = entry(d.id)
                    pets = pets + 1
                    check(b.f == key, "beast of another family in the card: " .. b.en)
                    check(everTame(d.id), "a beast nobody can tame in the card: " .. b.en)
                    check(d.tame == tameNow(d.id, level), "tameable flag wrong: " .. b.en)
                    check((d.dist ~= nil) == (ns.BEASTS[d.id] ~= nil and ns.BeastDistance(d.id, ns.PlayerWorldPos()) ~= nil),
                        "only a teacher with a known habitat has a distance: " .. b.en)
                    if not d.tame then tameEnded = true end
                    check(not (d.tame and tameEnded), "tameable beasts must come first: " .. key)
                end
            end
            for k in pairs(want) do check(got[k], "card misses an ability: " .. key .. " " .. k) end
            local hasOwn = false
            for k in pairs(want) do hasOwn = hasOwn or learners(ability(k)) == 1 end
            check(firstOwn == hasOwn, "the family's own ability is not first: " .. key)
            -- as of this data: every family but the Bat has exactly one ability of its own
            check(flagged == (key == "Bat" and 0 or 1), ("own abilities flagged: %d: %s"):format(flagged, key))
            local inAtlas, teachers = 0, 0
            for _, id in ipairs(allPets) do
                if entry(id).f == key then
                    inAtlas = inAtlas + 1
                    if ns.BEASTS[id] then teachers = teachers + 1 end
                end
            end
            check(pets == inAtlas and pets > 0, ("card beasts: %d of %d: %s"):format(pets, inAtlas, key))
            check(card[#card - pets].text:find(tostring(inAtlas), 1, true) or card[#card - pets - 1].text:find(tostring(inAtlas), 1, true),
                "the card does not say how many beasts the family has: " .. key)
            -- the family row on the left counts the same beasts
            check(rowOf(entry0) == nil or rowOf(entry0).sub.__text:find(L.FAM_ROW_SUB:format(inAtlas, 0, 0):match("^[^,]+"), 1, true),
                "the family list counts other beasts than the card: " .. key)
            -- the rows are drawn from raw data: with "only my pet's family" on they still say what the beast knows
            -- a pet that teaches nothing: no "knows" part, the place from Petopia's text, a plain tooltip
            for _, d in ipairs(card) do
                local row = d.kind == "pet" and not ns.BEASTS[d.id] and rowOf(d)
                if row then
                    local p = ns.PETS[d.id]
                    plainRows = plainRows + 1
                    check(row.text.__text:find(loc(p), 1, true), "plain pet row has no name: " .. p.en)
                    check(not row.sub.__text:find(L.PET_KNOWS:format(""), 1, true), "a pet that teaches nothing says what it knows: " .. p.en)
                    check(row.right.__text == "", "a pet without coordinates shows a distance: " .. p.en)
                    GameTooltip.__lines = {}
                    row.__scripts.OnEnter(row)
                    local tipText = table.concat(GameTooltip.__lines, "\n")
                    check(tipText:find(loc(p), 1, true) and tipText:find(L.PET_NO_RANKS, 1, true), "plain pet tooltip is wrong: " .. p.en)
                    if p.z:find(",", 1, true) then
                        check(tipText:find(p.z, 1, true), "the tooltip lacks Petopia's place text: " .. p.z)
                    end
                    if p.tag then
                        check(row.text.__text:find(L["TAG_" .. p.tag], 1, true), "no rare/elite mark on the row: " .. p.en)
                    end
                    row.__scripts.OnLeave(row)
                    break
                end
            end
            for _, d in ipairs(card) do
                local row = d.kind == "pet" and ns.BEASTS[d.id] and rowOf(d)
                if row then
                    local b = ns.BEASTS[d.id]
                    check(row.text.__text:find(loc(b), 1, true), "pet row has no name: " .. b.en)
                    check(row.sub.__text:find(loc(ability(b.t[1])) .. " " .. b.t[2], 1, true),
                        "pet row does not say what the beast knows: " .. b.en)
                    check((row.sub.__text:find(L.TAME_FROM:format(b.l[1]), 1, true) ~= nil) == (not d.tame),
                        "'tame at' note wrong: " .. b.en)
                    -- the right label is the distance or nothing: a zone name there squeezed the name and level
                    check(row.right.__text == "" or d.dist ~= nil, "zone name in the right label: " .. b.en)
                    check(row.sub.__text:find(ns.ZoneName(b.z), 1, true), "pet row has no zone: " .. b.en)
                    -- hovering gives everything the row may have had to cut
                    GameTooltip.__lines = {}
                    row.__scripts.OnEnter(row)
                    local tipText = table.concat(GameTooltip.__lines, "\n")
                    check(tipText:find(loc(b), 1, true) and tipText:find(ns.ZoneName(b.z), 1, true),
                        "pet tooltip lacks the name or the zone: " .. b.en)
                    for i = 1, #b.t, 2 do
                        check(tipText:find(loc(ability(b.t[i])) .. " " .. b.t[i + 1], 1, true),
                            "pet tooltip lacks an ability: " .. b.en .. " " .. b.t[i])
                    end
                    check((tipText:find(L.PET_CAN_TAME, 1, true) ~= nil) == d.tame
                        and (tipText:find(L.TAME_AT:format(b.l[1]), 1, true) ~= nil) == (not d.tame),
                        "pet tooltip: tameable line wrong: " .. b.en)
                    row.__scripts.OnLeave(row)
                    break
                end
            end
            check(rowOf(entry0) and rowOf(entry0).sel:IsShown(), "selected family not highlighted: " .. key)
        end
    end
    check(cards == 18, "family cards opened: " .. cards)
    check(plainRows >= 5, "rows of pets that teach nothing were drawn for " .. plainRows .. " families")

    -- only the rare, elite and special ones
    check(win.rareOnly:IsShown(), "the rare filter is not shown on the Families tab")
    win.rareOnly.__checked = true
    win.rareOnly.__scripts.OnClick(win.rareOnly)
    for _, entry0 in ipairs(families().data) do
        if entry0.kind == "family" then
            click(entry0)
            local wantRare, gotRare = 0, 0
            for _, id in ipairs(allPets) do
                if entry(id).f == entry0.key and ns.PETS[id] and ns.PETS[id].tag then wantRare = wantRare + 1 end
            end
            for _, d in ipairs(pane().data) do
                if d.kind == "pet" then
                    gotRare = gotRare + 1
                    check(ns.PETS[d.id] and ns.PETS[d.id].tag, "an ordinary beast passed the rare filter: " .. entry(d.id).en)
                end
            end
            check(gotRare == wantRare, ("rare filter: %d of %d in %s"):format(gotRare, wantRare, entry0.key))
            if wantRare == 0 then
                check(allText(pane().data):find(L.FAM_NONE_RARE, 1, true), "no note for a family without rare beasts: " .. entry0.key)
            end
        end
    end
    -- no family chosen (the guide): the rare beasts of every family at once
    click(families().data[1])
    check(win.rareOnly.__checked == false, "opening the guide should untick the rare filter")
    check(pane().data[1].text == L.GUIDE_TITLE, "the guide row does not open the guide while the rare filter is on")
    win.rareOnly.__checked = true
    win.rareOnly.__scripts.OnClick(win.rareOnly)
    local allRare, listed = 0, 0
    for _, id in ipairs(allPets) do
        if ns.PETS[id] and ns.PETS[id].tag then allRare = allRare + 1 end
    end
    local rareList = list(function(data) return data[1] and data[1].kind == "group" and data[1].text == L.FAM_BEASTS_RARE:format(allRare) end)
    check(rareList, "ticking the rare filter on the guide does not list the rare beasts of all families")
    for _, d in ipairs(rareList and rareList.data or {}) do
        if d.kind == "pet" then
            listed = listed + 1
            check(ns.PETS[d.id] and ns.PETS[d.id].tag, "an ordinary beast in the list of rare ones: " .. entry(d.id).en)
        end
    end
    check(listed == allRare and allRare >= 100, ("rare beasts of all families: %d listed of %d"):format(listed, allRare))
    win.rareOnly.__checked = false
    win.rareOnly.__scripts.OnClick(win.rareOnly)
    check(pane() and pane().data[1].text == L.GUIDE_TITLE, "unticking the rare filter does not bring the guide back")

    -- a pet that teaches nothing in the detail pane: name, no ranks, no stable line
    local plain
    for _, entry0 in ipairs(families().data) do
        if entry0.kind == "family" and not plain then
            click(entry0)
            for _, d in ipairs(pane().data) do
                if d.kind == "pet" and not ns.BEASTS[d.id] and rowOf(d) and not plain then plain = d end
            end
        end
    end
    check(plain, "test setup: no drawn row of a pet that teaches nothing")
    if plain then
        click(plain)
        local detailFrame
        for _, f in ipairs(__frames) do
            if rawget(f, "teaches") and rawget(f, "stable") then detailFrame = f end
        end
        check(detailFrame and detailFrame.name:GetText() == loc(ns.PETS[plain.id]), "detail pane does not show the chosen pet")
        check(detailFrame and detailFrame.teaches:GetText():find(L.PET_NO_RANKS, 1, true), "detail pane: no 'teaches nothing' note")
        check(detailFrame and not detailFrame.stable:IsShown(), "detail pane: stable line for a pet without coordinates")
        check(rowOf(plain).sel:IsShown(), "the chosen pet is not highlighted")
    end

    -- a beast in the card: selecting it shows it in the detail pane
    local firstPet, firstAbility
    for _, d in ipairs(pane().data) do
        if d.kind == "pet" and not firstPet then firstPet = d end
        if d.kind == "ability" and not firstAbility then firstAbility = d end
    end
    click(firstPet)
    check(rowOf(firstPet).sel:IsShown(), "selected beast not highlighted in the card")
    -- tabs back and forth: rows are recycled between kinds
    tab("tabNearby"); tab("tabFamilies"); tab("tabAbilities"); tab("tabFamilies"); tab("tabSettings"); tab("tabFamilies")
    check(pane() and pane().data[1].kind == "group", "the card is gone after switching tabs")
    for _, control in ipairs(win.filters) do check(not control:IsShown(), "rank filters back on the Families tab") end
    -- an ability of the card opens on the Abilities tab
    for _, d in ipairs(pane().data) do if d.kind == "ability" then firstAbility = d break end end
    click(firstAbility)
    check(win.selectedTab == 2, "clicking a family ability did not open the Abilities tab")
    for _, control in ipairs(win.filters) do check(control:IsShown(), "rank filters hidden on the Abilities tab") end
    local picked
    for _, f in ipairs(__frames) do
        for _, row in ipairs(rawget(f, "__active") or {}) do
            if row.data.kind == "ability" and row.data.ab == firstAbility.ab and not row.data.jump and row.sel:IsShown() then picked = true end
        end
    end
    check(picked or ns.db.petOnly, "the clicked ability is not selected on the Abilities tab")

    -- search narrows the family list; the guide entry returns to the guide
    tab("tabFamilies")
    BeastAtlasSearch.__text = loc(ns.FAMILIES.Cat)
    __run(BeastAtlasSearch, "OnTextChanged")
    __advance(0.5)
    local n = 0
    for _, d in ipairs(families().data) do
        if d.kind == "family" then
            n = n + 1
            check(d.key == "Cat", "search left another family: " .. d.key)
        end
    end
    check(n == 1, "search for a family found " .. n)
    -- the pane lists what was found in the whole pet list: at least every cat, and nothing unrelated
    local q = ns.Lower(loc(ns.FAMILIES.Cat))
    local found, cats = {}, 0
    local results = list(function(data) return data[1] and data[1].kind == "group" and data[1].text:find(L.PET_FOUND:format(0):match("^[^0-9]+"), 1, true) end)
    check(results, "no search results pane on the Families tab")
    for _, d in ipairs(results and results.data or {}) do
        if d.kind == "pet" then
            found[d.id] = true
            local e, fam = entry(d.id), ns.FAMILIES[entry(d.id).f]
            local hay = ns.Lower(table.concat({ e.en, e.ru or "", fam.en, fam.ru, ns.PETS[d.id] and ns.PETS[d.id].z or "",
                ns.BEASTS[d.id] and ns.ZoneName(ns.BEASTS[d.id].z) or "" }, "|"))
            check(hay:find(q, 1, true), "search result that matches nothing: " .. e.en)
        end
    end
    local shownCats = 0
    for _, id in ipairs(allPets) do
        if entry(id).f == "Cat" then
            cats = cats + 1
            if found[id] then shownCats = shownCats + 1 end
        end
    end
    check(cats >= 60 and (shownCats == cats or shownCats == 100), ("search for cats: %d of %d shown"):format(shownCats, cats))
    -- with a search on, clicking a family opens its card and drops the search (it is not a dead end)
    local catRow
    for _, d in ipairs(families().data) do if d.kind == "family" and d.key == "Cat" then catRow = d end end
    click(catRow)
    check(BeastAtlasSearch:GetText() == "", "clicking a family did not clear the search box")
    local fams = 0
    for _, d in ipairs(families().data) do if d.kind == "family" then fams = fams + 1 end end
    check(fams == 18, "the family list stays narrowed after a family was clicked: " .. fams)
    check(pane() and pane().data[1].text:find(loc(ns.FAMILIES.Cat), 1, true) and pane().data[2].kind == "text",
        "clicking a family during a search did not open its card")
    __advance(0.5)
    BeastAtlasSearch.__text = "zzzz-no-such-beast"
    __run(BeastAtlasSearch, "OnTextChanged")
    __advance(0.5)
    check(allText(pane and (list(function(data) return data[2] and data[2].kind == "text" end) or {}).data or {}):find(L.PET_NOT_FOUND, 1, true),
        "no 'nothing found' note")
    BeastAtlasSearch.__text = ""
    __run(BeastAtlasSearch, "OnTextChanged")
    __advance(0.5)
    click(families().data[1])
    check(pane().data[1].text == L.GUIDE_TITLE, "the guide entry does not open the guide")
    __advance(6) -- the ticker redraws the guide's picks without errors
    ns.SetOption("petOnly", false)
    tab("tabNearby")
    if not wasShown then slash("") end
end

-------------------------------------------------------------------------------
-- 15. beasts that teach several needed ranks at once; "on the map" for one rank
-------------------------------------------------------------------------------
do
    local wasShown = BeastAtlasFrame:IsShown()
    if not wasShown then slash("") end
    local win = BeastAtlasFrame
    local AREA, ICON, ZONE = "BeastAtlasAreaPinTemplate", "BeastAtlasIconPinTemplate", "BeastAtlasZonePinTemplate"
    local function tab(name) win[name].__scripts.OnClick(win[name]) end
    local function rowOf(d)
        for _, f in ipairs(__frames) do
            for _, row in ipairs(rawget(f, "__active") or {}) do
                if row.data == d then return row end
            end
        end
    end
    local function shownList(pred)
        for _, f in ipairs(__frames) do
            if rawget(f, "SetData") and f:IsShown() and pred(f.data) then return f end
        end
    end
    local function readyOf(list)
        local n = 0
        for _, e in ipairs(list or {}) do if e.status == S.READY then n = n + 1 end end
        return n
    end

    -- ---- several ranks at once: find a hunter level at which some zone has such a beast
    ns.SetOption("petOnly", false)
    ns.SetOption("showLearned", false)
    wipe(ns.cdb.known)
    local multiZone, multiId
    for _, lvl in ipairs({ 30, 24, 36, 42, 48, 54, 60, 18, 12 }) do
        __U.player.level = lvl
        ns.Changed()
        for mapID, ids in pairs(ns.BeastsByMap()) do
            for _, id in ipairs(ids) do
                local _, list = ns.BeastUseful(id)
                if readyOf(list) >= 2 then multiZone, multiId = mapID, id end
            end
        end
        if multiId then break end
    end
    check(multiId, "test setup: no beast teaches two ranks worth learning at once")
    if multiId then
        __playerMap, __playerPos = multiZone, { x = 0.5, y = 0.5 }
        ns.Changed()
        tab("tabNearby")
        ns.RefreshWindow()
        local nearby = shownList(function(data) return data[1] and data[1].kind == "group" and data[2] and data[2].id end)
        check(nearby, "nearby list not shown")
        local seenMulti, inHere, lastReady = 0, false, nil
        for _, d in ipairs(nearby and nearby.data or {}) do
            if d.kind == "group" then
                inHere = d.text == L.GROUP_HERE:format(ns.ZoneName(ns.BEASTS[multiId].z))
                lastReady = nil
            elseif d.id then
                local n = readyOf(d.list)
                check(d.ready == n, "ready count of a nearby beast is wrong: " .. ns.BEASTS[d.id].en)
                local row = rowOf(d)
                if row then
                    local marked = row.sub.__text:find(L.MULTI:format(n), 1, true) == 11 -- right after the colour code
                    check((n >= 2) == (marked or false), ("'%d at once' mark wrong for %s: %s"):format(n, ns.BEASTS[d.id].en, row.sub.__text))
                    if n >= 2 then
                        seenMulti = seenMulti + 1
                        GameTooltip.__lines = {}
                        row.__scripts.OnEnter(row)
                        check(table.concat(GameTooltip.__lines, "\n"):find(L.MULTI_TIP:format(n), 1, true), "no tooltip line about several ranks at once")
                        row.__scripts.OnLeave(row)
                    end
                end
                -- in the hunter's zone, among the beasts to tame now, more ranks at once come first
                if inHere and d.status == S.READY then
                    check(not lastReady or lastReady >= n, "beasts with more needed ranks should come first in the zone")
                    lastReady = n
                end
            end
        end
        check(seenMulti >= 1, "no row is marked as teaching several ranks at once")
    end
    __U.player.level = 30
    ns.Changed()

    -- ---- the teachers of one rank on the map
    local function mappable(key, rank)
        local set, n, zones = {}, 0, {}
        for _, id in ipairs(ability(key).ranks[rank].beasts or {}) do
            local b = ns.BEASTS[id]
            if #b.c > 0 and ns.ZoneMap(b.z) then
                set[id] = true
                n = n + 1
                zones[ns.ZoneMap(b.z)] = (zones[ns.ZoneMap(b.z)] or 0) + 1
            end
        end
        return set, n, zones
    end
    -- a rank whose teachers live in at least two zones, and a rank nobody on a map teaches
    local fKey, fRank, noneKey, noneRank
    for _, ab in ipairs(ns.ABILITIES) do
        for rank in pairs(ab.ranks) do
            local _, n, zones = mappable(ab.key, rank)
            local nz = 0
            for _ in pairs(zones) do nz = nz + 1 end
            local forWolf = false
            for _, f in ipairs(ab.families) do forWolf = forWolf or f == "*" or f == "Wolf" end
            if nz >= 2 and n >= 3 and rank > 1 and not forWolf and not fKey then fKey, fRank = ab.key, rank end
            if n == 0 and not noneKey then noneKey, noneRank = ab.key, rank end
            check(#ns.RankTeachersOnMap(ab.key, rank) == n, "RankTeachersOnMap differs from the data for " .. ab.key .. " " .. rank)
        end
    end
    check(fKey and noneKey, "test setup: need a rank with teachers in two zones and one with none on a map")
    local set, total, zones = mappable(fKey, fRank)
    local label = loc(ability(fKey)) .. " " .. fRank

    -- nothing to show: no focus, a message
    local from = #__out + 1
    check(ns.FocusRank(noneKey, noneRank) == false and ns.focus == nil, "focus set for a rank with no teacher on a map")
    check(outHas(L.FOCUS_NONE, from), "no message for a rank that cannot be shown")

    -- the zone of the nearest teacher opens
    ns.SetOption("petOnly", true) -- the rank is not for the main pet's family: the usual filters would hide it
    local someZoneMap = next(zones)
    __playerMap, __playerPos = someZoneMap, { x = 0.5, y = 0.5 }
    do
        local cont, px, py = ns.PlayerWorldPos()
        local best
        for id in pairs(set) do
            local d = ns.BeastDistance(id, cont, px, py)
            if d and (not best or d < best) then best, someZoneMap = d, ns.ZoneMap(ns.BEASTS[id].z) end
        end
    end
    WorldMapFrame:Show()
    ns.SetOption("mapPins", false) -- the focus is shown even with the beasts on the map switched off
    __advance(0.5)
    from = #__out + 1
    check(ns.FocusRank(fKey, fRank) == true, "FocusRank failed")
    __advance(0.5)
    check(ns.focus and ns.focus.label == label, "focus label wrong")
    for id in pairs(set) do check(ns.focus.ids[id], "focus misses a teacher " .. id) end
    for id in pairs(ns.focus and ns.focus.ids or {}) do check(set[id], "focus has a beast that does not teach the rank " .. id) end
    check(__map.id == someZoneMap, "focus did not open the zone of the nearest teacher")
    check(outHas(label, from) and outHas(ns.ZoneName(ns.ZoneByMap(someZoneMap)), from), "focus message lacks the rank or the zones")
    check(BeastAtlasMapFocus:IsShown() and BeastAtlasMapFocus.text:GetText():find(label, 1, true), "no bar on the map while the focus is on")
    -- every zone of the focus: exactly its teachers, with their habitats drawn
    for mapID, count in pairs(zones) do
        WorldMapFrame:SetMapID(mapID)
        local seen, n = {}, 0
        for _, pin in ipairs(__map.pins[ICON] or {}) do
            for _, id in ipairs(pin.stack.ids) do
                check(set[id], "a beast that does not teach the rank is on the map: " .. ns.BEASTS[id].en)
                if not seen[id] then seen[id] = true; n = n + 1 end
            end
        end
        check(n == count, ("zone %d shows %d teachers of the rank, expected %d"):format(mapID, n, count))
        local fills = 0
        for _, pin in ipairs(__map.pins[AREA] or {}) do if pin.Fill:IsShown() then fills = fills + 1 end end
        check(fills == __pinCount(AREA) and fills > 0, "habitats of the focused teachers are not drawn")
        local pin = __map.pins[ICON][1]
        GameTooltip.__lines = {}
        pin:OnMouseEnter()
        check(table.concat(GameTooltip.__lines, "\n"):find(label, 1, true), "pin tooltip does not name the focused rank")
        pin:OnMouseLeave()
    end
    -- a zone with beasts but no teacher of the rank shows none of them
    for mapID in pairs(ns.BeastsByMap()) do
        if not zones[mapID] then
            WorldMapFrame:SetMapID(mapID)
            check(__pinCount(ICON) == 0 and __pinCount(AREA) == 0, "beasts shown in a zone without teachers of the focused rank")
            break
        end
    end
    -- continents: one pin per zone with teachers, carrying their number
    local zonePins = 0
    for _, cont in ipairs({ 1414, 1415 }) do
        WorldMapFrame:SetMapID(cont)
        for _, pin in ipairs(__map.pins[ZONE] or {}) do
            local sm = pin.summary
            zonePins = zonePins + 1
            check(sm.focus == label and sm.count == zones[sm.mapID], "zone pin of a focus has a wrong count")
            GameTooltip.__lines = {}
            pin:OnMouseEnter()
            check(table.concat(GameTooltip.__lines, "\n"):find(L.FOCUS_ZONE:format(label, sm.count), 1, true), "zone pin tooltip of a focus is wrong")
            pin:OnMouseLeave()
        end
    end
    local nz = 0
    for _ in pairs(zones) do nz = nz + 1 end
    check(zonePins == nz, ("zone pins of a focus: %d, zones with teachers: %d"):format(zonePins, nz))
    -- closing the map keeps the focus; the bar clears it and everything is back
    WorldMapFrame:Hide()
    WorldMapFrame:Show()
    check(ns.focus ~= nil, "the focus was lost when the map was closed")
    BeastAtlasMapFocus.__scripts.OnClick(BeastAtlasMapFocus)
    __advance(0.5)
    check(ns.focus == nil and not BeastAtlasMapFocus:IsShown(), "clicking the bar did not clear the focus")
    WorldMapFrame:SetMapID(someZoneMap)
    check(__pinCount(ICON) == 0, "beasts drawn with the map option off and no focus")
    ns.SetOption("mapPins", true)
    __advance(0.5)

    -- standing elsewhere on the continent: the zone of the nearest teacher opens
    local elsewhere
    for mapID in pairs(ns.BeastsByMap()) do
        if not zones[mapID] and (mapID % 2) == (someZoneMap % 2) then elsewhere = mapID break end
    end
    if elsewhere then
        __playerMap, __playerPos = elsewhere, { x = 0.5, y = 0.5 }
        local cont, px, py = ns.PlayerWorldPos()
        local best, bestMap
        for id in pairs(set) do
            local d = ns.BeastDistance(id, cont, px, py)
            if d and (not best or d < best) then best, bestMap = d, ns.ZoneMap(ns.BEASTS[id].z) end
        end
        ns.FocusRank(fKey, fRank)
        __advance(0.5)
        if bestMap then check(__map.id == bestMap, "focus did not open the zone of the nearest teacher") end
    end
    -- asking for one beast drops the focus: the filter would hide it
    local other
    for id, b in pairs(ns.BEASTS) do
        if not set[id] and #b.c > 0 and ns.ZoneMap(b.z) then other = id break end
    end
    ns.OpenMapFor(other)
    __advance(0.5)
    check(ns.focus == nil and ns.highlight == other, "opening one beast on the map should drop the rank focus")
    WorldMapFrame:Hide()

    -- the button on the rank headers of the Abilities tab: only where there is something to show
    ns.SetOption("petOnly", false)
    tab("tabAbilities")
    local buttons, hidden, clicked = 0, 0, false
    for _, key in ipairs({ fKey, noneKey }) do
        local abRow
        for _, f in ipairs(__frames) do
            for _, row in ipairs(rawget(f, "__active") or {}) do
                if row.data and row.data.kind == "ability" and row.data.ab.key == key then abRow = row end
            end
        end
        check(abRow, "ability not in the list: " .. key)
        if abRow then abRow.__scripts.OnClick(abRow, "LeftButton") end
        for _, f in ipairs(__frames) do
            for _, row in ipairs(rawget(f, "__active") or {}) do
                local d = row.data
                if d and d.kind == "header" and d.ab.key == key then
                    local _, n = mappable(d.ab.key, d.rank)
                    check(row.mapBtn:IsShown() == (n > 0), "map button on a rank header wrong: " .. d.ab.key .. " " .. d.rank)
                    if n > 0 and d.rank > 1 and not clicked then
                        clicked = true
                        row.mapBtn.__scripts.OnClick(row.mapBtn)
                        __advance(0.5)
                        check(ns.focus and ns.focus.key == d.ab.key and ns.focus.rank == d.rank, "the map button did not focus its rank")
                        ns.ClearFocus()
                    end
                    if n > 0 then buttons = buttons + 1 else hidden = hidden + 1 end
                elseif d and d.kind ~= "header" and row.mapBtn then
                    check(not row.mapBtn:IsShown(), "map button on a row that is not a rank header")
                end
            end
        end
    end
    check(buttons >= 1 and hidden >= 1 and clicked, ("rank headers: %d with a map button, %d without"):format(buttons, hidden))
    WorldMapFrame:Hide()
    __playerMap, __playerPos = 1429, { x = 0.5, y = 0.5 }
    ns.SetOption("petOnly", true)
    tab("tabNearby")
    if not wasShown then slash("") end
end

slash("reset")
check(next(ns.cdb.known) == nil, "/ba reset did not clear known ranks")
slash("")
return table.concat(fails, "\n"), table.concat(info, " ")
