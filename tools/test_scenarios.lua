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
    check(pin.__w == pin.__h and pin.__w >= 16, "a habitat is not a circle")
end
do
    local hoverPin = __map.pins[ICON][1]
    local spots = #ns.BEASTS[hoverPin.stack.ids[1]].c / 3
    hoverPin:OnMouseEnter()
    check(habitatsShown() == spots, ("hovering a pin shows %d habitats, the beast has %d spots"):format(habitatsShown(), spots))
    hoverPin:OnMouseLeave()
    check(habitatsShown() == 0, "habitats stay after the mouse leaves the pin")
    -- after a redraw the old pins are back in the pool: hovering must not touch them
    local old = {}
    for i, pin in ipairs(__map.pins[AREA]) do old[i] = pin end
    WorldMapFrame:SetMapID(someZone)
    hoverPin = __map.pins[ICON][1]
    hoverPin:OnMouseEnter()
    for _, pin in ipairs(old) do check(not pin.Fill:IsShown(), "hovering lit a habitat pin of the previous redraw") end
    hoverPin:OnMouseLeave()
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
    for _, pin in ipairs(__map.pins[TRAINER] or {}) do
        local pt = ns.TRAINERS[pin.trainerId]
        check(pt.side ~= "A", "Alliance trainer shown to a Horde player: " .. pin.trainerId)
        if pin.trainerId == id then mine = mine + 1 end
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
check(__pinCount(TRAINER) == 1, "Orgrimmar should show one trainer pin")
__waypoint = nil
__map.pins[TRAINER][1]:OnClick("LeftButton")
check(__waypoint ~= nil, "trainer pin click did not set a waypoint")
ns.SetOption("trainers", false)
__advance(0.5)
check(__pinCount(TRAINER) == 0, "trainer pins shown with the option off")
ns.SetOption("trainers", true)
__advance(0.5)
check(__pinCount(TRAINER) == 1, "trainer pins not restored")
for _, cont in ipairs({ 1414, 1415 }) do
    WorldMapFrame:SetMapID(cont)
    check(__pinCount(TRAINER) == 0, "trainer pins on a continent map")
end
__combat = true
WorldMapFrame:SetMapID(ns.ZoneMap("Orgrimmar"))
check(__pinCount(TRAINER) == 0, "trainer pins acquired in combat")
__combat = false

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
    -- no pet out: just "tame your target"
    local keepPet = __U.pet
    __U.pet = nil
    __fire("UNIT_PET", "player")
    settle()
    check(panelShown() and panelText():find(L.HELPER_STEP1_TARGET:format(teacherName), 1, true)
        and not panelText():find(L.HELPER_STEP1_STABLE:format(teacherName), 1, true),
        "helper step 1 without a pet should just name the target")
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
    -- ... but not on a flight path, where the pet is only hidden
    __onTaxi = true
    ns.Changed()
    settle()
    check(#ns.TrainingGoals() == 0 and not panelShown(), "helper nags on a flight path")
    __onTaxi = false
    -- training points: the rank being replaced is refunded (30 total, 12 used in the stub = 18 free)
    __U.pet = { name = "Fang", family = wolf, level = 24, guid = "Pet-0-1-1-1-100-0001" }
    __fire("UNIT_PET", "player")
    settle()
    local r3, r4 = ability("bite").ranks[3].tp, ability("bite").ranks[4].tp
    check(goal() and goal().stage == 4 and r4 - r3 <= 18, "helper setup: Bite 4 should be affordable after the refund")
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
    for _, b in pairs(ns.BEASTS) do if b.s and b.s < minSpeed then minSpeed = b.s end end
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
    for id, b in pairs(ns.BEASTS) do
        if b.s and b.s < 2 and b.l[1] <= level then want[#want + 1] = id end
    end
    table.sort(want, function(a, b)
        local ba, bb = ns.BEASTS[a], ns.BEASTS[b]
        if ba.s ~= bb.s then return ba.s < bb.s end
        if ba.l[2] ~= bb.l[2] then return ba.l[2] > bb.l[2] end
        return a < b
    end)
    check(nowList and #fastNow == math.min(5, #want) and #want >= 5, "fastest tameable beasts: list missing or wrong length: " .. #fastNow)
    for i, d in ipairs(fastNow) do
        check(d.id == want[i], "fastest tameable beasts: wrong beast at " .. i)
        check(d.tame and ns.BEASTS[d.id].l[1] <= level, "a beast that cannot be tamed yet among the tameable ones")
    end
    check(#fastest == 5 and ns.BEASTS[fastest[1].id].s == minSpeed, "fastest beasts: wrong count or not the fastest first")
    for i = 2, #fastest do
        check(ns.BEASTS[fastest[i - 1].id].s <= ns.BEASTS[fastest[i].id].s, "fastest beasts not sorted by speed")
    end
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
    check(petRow and petRow.sub.__text:find(L["ROLE_" .. ns.FAMILIES[ns.BEASTS[petRow.data.id].f].role], 1, true),
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
        check(not (d.kind == "pet" and d.tame and ns.BEASTS[d.id].l[1] > 9), "beast above level 9 marked tameable")
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
    local cards = 0
    for _, entry in ipairs(families().data) do
        if entry.kind == "family" then
            local key, fam = entry.key, ns.FAMILIES[entry.key]
            click(entry)
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
                    local b = ns.BEASTS[d.id]
                    pets = pets + 1
                    check(b.f == key, "beast of another family in the card: " .. b.en)
                    check(d.tame == (b.l[1] <= level), "tameable flag wrong: " .. b.en)
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
            local inAtlas = 0
            for _, b in pairs(ns.BEASTS) do if b.f == key then inAtlas = inAtlas + 1 end end
            check(pets == inAtlas and pets > 0, ("card beasts: %d of %d: %s"):format(pets, inAtlas, key))
            -- the rows are drawn from raw data: with "only my pet's family" on they still say what the beast knows
            for _, d in ipairs(card) do
                local row = d.kind == "pet" and rowOf(d)
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
            check(rowOf(entry) and rowOf(entry).sel:IsShown(), "selected family not highlighted: " .. key)
        end
    end
    check(cards == 18, "family cards opened: " .. cards)

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

slash("reset")
check(next(ns.cdb.known) == nil, "/ba reset did not clear known ranks")
slash("")
return table.concat(fails, "\n"), table.concat(info, " ")
