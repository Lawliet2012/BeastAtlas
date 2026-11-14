-- Tracks which ability ranks the hunter knows, and the main pet.
-- Known ranks (BeastAtlasCharDB.known[abilityKey] = highest rank) come from:
--   * "You have learned ..." system messages,
--   * the hunter's own spell ids (IsSpellKnown),
--   * the Beast Training window (opened by the hunter's own spell),
--   * manual marks from the UI.
-- The summoned pet's spellbook never marks anything as known: a tamed beast knows its rank, but the
-- hunter learns it only after the pet has used it. It only fills ns.petRanks.
local _, ns = ...
local L = ns.L

ns.petRanks = {} -- abilityKey -> rank, for the currently summoned pet only

-- Raises the known rank; on success appends "<ability> <rank>" to `raised`.
local function Mark(ab, rank, raised)
    if not ab or not rank then return false end
    local known = ns.cdb.known
    if (known[ab.key] or 0) < rank then
        known[ab.key] = rank
        raised[#raised + 1] = (ns.Names(ab)) .. " " .. rank
        return true
    end
    return false
end

-- One chat line per source and scan, then one invalidation.
local function Report(raised, source)
    if #raised == 0 then return end
    ns.Print(L.MARKED:format(table.concat(raised, ", "), source))
    ns.Changed()
end

-- "Bite", "Rank 2" / "Укус", "Уровень 2" -> ability, rank (no rank text = rank 1)
local function Parse(name, sub)
    local ab = ns.AbilityByName(name)
    if not ab then return nil end
    local rank = sub and not ns.IsSecret(sub) and tonumber(sub:match("([0-9]+)")) or 1
    if not ab.ranks[rank] then rank = 1 end
    return ab, rank
end

-------------------------------------------------------------------------------
-- Summoned pet
-------------------------------------------------------------------------------
-- ns.petRanksPartial: some rank text was not loaded yet (the client may return an empty sub-name), so
-- the ranks read are incomplete and must not be stored anywhere.
function ns.ScanPetSpellbook()
    wipe(ns.petRanks)
    ns.petRanksPartial = false
    if not UnitExists("pet") then return end
    local count
    if C_SpellBook and C_SpellBook.HasPetSpells then count = C_SpellBook.HasPetSpells()
    elseif HasPetSpells then count = HasPetSpells() end
    if ns.IsSecret(count) then return end
    for i = 1, tonumber(count) or 0 do
        local name, sub
        if C_SpellBook and C_SpellBook.GetSpellBookItemName and Enum.SpellBookSpellBank then
            name, sub = C_SpellBook.GetSpellBookItemName(i, Enum.SpellBookSpellBank.Pet)
        elseif GetSpellBookItemName then
            name, sub = GetSpellBookItemName(i, BOOKTYPE_PET or "pet")
        end
        local ab, rank = Parse(name, sub)
        if ab then
            local noRank = sub == nil or ns.IsSecret(sub) or not sub:find("[0-9]")
            if noRank and ab.maxRank > 1 then
                ns.petRanksPartial = true -- "Bite" without its rank: don't guess rank 1
            elseif (ns.petRanks[ab.key] or 0) < rank then
                ns.petRanks[ab.key] = rank
            end
        end
    end
end

-- id ("Name|FamilyKey"), name, family key of the summoned pet; nil if unknown.
local function PetIdentity()
    if not UnitExists("pet") then return nil end
    local name = UnitName("pet")
    local family = UnitCreatureFamily("pet")
    if not name or not family or ns.IsSecret(name) or ns.IsSecret(family) then return nil end
    local key = ns.FamilyKey(family)
    if not key then return nil end
    return name .. "|" .. key, name, key
end

local function PetLevel()
    local lvl = UnitLevel("pet")
    if ns.IsSecret(lvl) then return nil end
    return tonumber(lvl)
end

local function CopyRanks()
    local t = {}
    for k, v in pairs(ns.petRanks) do t[k] = v end
    return t
end

local function SameRanks(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

function ns.PetId()
    return (PetIdentity())
end

function ns.ActivePetIsMain()
    local main = ns.cdb and ns.cdb.main
    local id = ns.PetId()
    return id ~= nil and main ~= nil and id == main.id
end

function ns.SetMainPet()
    ns.ScanPetSpellbook()
    local id, name, family = PetIdentity()
    if not id then return ns.Print(L.NO_ACTIVE_PET) end
    local old = ns.cdb.main
    -- an incomplete spellbook read keeps what was stored for the same pet
    local ranks = (ns.petRanksPartial and old and old.id == id and old.ranks) or CopyRanks()
    ns.cdb.main = { id = id, name = name, family = family, level = PetLevel() or 1, ranks = ranks }
    ns.Print(L.MAIN_SET:format(name))
    ns.Changed()
end

local otherAnnounced = {} -- pet id -> true, once per session

-- Keeps the stored main pet up to date; never switches the main pet by itself.
local function SyncMain()
    local id, name = PetIdentity()
    if not id then return end
    local main = ns.cdb.main
    if not main then return ns.SetMainPet() end
    if id == main.id then
        local old, lvl = main.level, PetLevel()
        local changed = false
        if lvl and lvl ~= old then
            main.level = lvl
            changed = true
        end
        if not ns.petRanksPartial and (not main.ranks or not SameRanks(main.ranks, ns.petRanks)) then
            main.ranks = CopyRanks()
            changed = true
        end
        -- Invalidate first so MAIN_LEVEL listeners see the new level in ns.Ctx().
        if changed then ns.Changed() end
        if lvl and old and lvl > old then ns.Fire("MAIN_LEVEL", old, lvl) end
    elseif not otherAnnounced[id] then
        otherAnnounced[id] = true
        ns.Fire("OTHER_PET", name, main.name)
    end
end

-------------------------------------------------------------------------------
-- Known ranks: hunter's spell ids
-------------------------------------------------------------------------------
local function SpellKnownFn()
    if C_SpellBook and C_SpellBook.IsSpellKnown then return C_SpellBook.IsSpellKnown end
    return IsPlayerSpell or IsSpellKnown
end

local function ScanPlayerSpells()
    local isKnown = SpellKnownFn()
    if not isKnown then return end
    local raised = {}
    for _, ab in ipairs(ns.ABILITIES) do
        if not ab.trainer then
            for rank, r in pairs(ab.ranks) do
                if rank > ns.KnownRank(ab.key) then
                    for _, id in ipairs(r.spells or {}) do
                        local ok, known = pcall(isKnown, id)
                        if ok and known then
                            Mark(ab, rank, raised)
                            break
                        end
                    end
                end
            end
        end
    end
    Report(raised, L.SRC_SPELLBOOK)
end

-------------------------------------------------------------------------------
-- Known ranks: Beast Training window
-------------------------------------------------------------------------------
local function IsOwnBeastTraining()
    if not (C_Trainer and C_Trainer.GetTrainerType and Enum and Enum.TrainerType) then return false end
    local ok, trainerType = pcall(C_Trainer.GetTrainerType)
    -- A trainer NPC shows the same window; only the hunter's own Beast Training spell has no npc unit.
    return ok and trainerType == Enum.TrainerType.Pet and not UnitExists("npc")
end

local function ScanTrainer()
    if not (GetNumTrainerServices and GetTrainerServiceInfo) or not IsOwnBeastTraining() then return end
    local okN, n = pcall(GetNumTrainerServices)
    if not okN or ns.IsSecret(n) then return end
    n = tonumber(n)
    if not n then return end
    local raised = {}
    for i = 1, n do
        local ok, name, serviceType, _, _, sub = pcall(GetTrainerServiceInfo, i)
        if ok and (serviceType == "available" or serviceType == "used") then
            local ab, rank = Parse(name, sub)
            if ab then Mark(ab, rank, raised) end
        end
    end
    Report(raised, L.SRC_TRAINER)
end

function ns.DumpTrainer()
    local n
    if GetNumTrainerServices then
        local ok, v = pcall(GetNumTrainerServices)
        if ok and not ns.IsSecret(v) then n = tonumber(v) end
    end
    if not n or n == 0 then return ns.Print(L.TRAINER_CLOSED) end
    local trainerType
    if C_Trainer and C_Trainer.GetTrainerType then
        local ok, v = pcall(C_Trainer.GetTrainerType)
        if ok then trainerType = v end
    end
    ns.Print(L.TRAINER_DUMP:format(tostring(trainerType), tostring(UnitExists("npc")), n))
    for i = 1, math.min(n, 40) do
        local ok, name, serviceType, _, _, sub = pcall(GetTrainerServiceInfo, i)
        if ok then
            print(i .. ": " .. tostring(name) .. " | " .. tostring(sub) .. " | " .. tostring(serviceType))
        end
    end
end

-------------------------------------------------------------------------------
-- Known ranks: system messages
-------------------------------------------------------------------------------
local function GlobalPattern(g)
    local s = _G[g]
    if type(s) ~= "string" then return nil end
    local p = s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)")
    return "^" .. p .. "$"
end

local learnPatterns, unlearnPattern
local function BuildPatterns()
    learnPatterns = {}
    for _, g in ipairs({ "ERR_LEARN_ABILITY_S", "ERR_LEARN_SPELL_S" }) do
        local p = GlobalPattern(g)
        if p then learnPatterns[#learnPatterns + 1] = p end
    end
    unlearnPattern = GlobalPattern("ERR_SPELL_UNLEARNED_S") or false
end

local HEX8 = "|c" .. string.rep("[0-9a-fA-F]", 8)
local function StripLinks(s)
    return (s:gsub(HEX8, ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", ""):gsub("[%[%]]", ""))
end

-- Fallback: the whole message is "<... ability name> (<anything> N)", optionally ending in . or !
local function ParseFallback(msg)
    local before, num = StripLinks(msg):match("^(.*) %([^()]-([0-9]+)%)[%.!]?$")
    if not before then return nil end
    local best, bestLen
    for _, ab in ipairs(ns.ABILITIES) do
        for _, n in ipairs({ ab.en, ab.ru }) do
            if n and #before >= #n and before:sub(-#n) == n and (not bestLen or #n > bestLen) then
                -- the name must start the text or follow a separator ("...: Bite", not "Frostbite")
                local pre = before:sub(-#n - 1, -#n - 1)
                if #before == #n or pre == " " or pre == ":" or pre == '"' or pre == "'" or pre == "\171" then -- \171: last byte of «
                    best, bestLen = ab, #n
                end
            end
        end
    end
    if not best then return nil end
    local rank = tonumber(num)
    if not best.ranks[rank] then rank = 1 end
    return best, rank
end

-- The client does not always put the rank into the message: "[Bite (Rank 3)]" one time, plain "[Claw]"
-- another (the rank text of a spell is loaded on demand). Then the rank comes from elsewhere:
--   1. the spell id in the message's link, when it is one of the ids the data has for a rank;
--   2. the summoned pet: the hunter learns exactly the rank that pet has just used.
local spellIndex -- [spellId] = { ab, rank }; ids listed for more than one rank are left out
local function RankBySpellId(ab, id)
    if not id then return nil end
    if not spellIndex then
        spellIndex = {}
        for _, a in ipairs(ns.ABILITIES) do
            for rank, r in pairs(a.ranks) do
                for _, sid in ipairs(r.spells or {}) do
                    spellIndex[sid] = spellIndex[sid] == nil and { a, rank } or false
                end
            end
        end
    end
    local e = spellIndex[id]
    return e and e[1] == ab and e[2] or nil
end

local function RankFromPet(ab)
    -- trainer abilities are bought, not learned from the pet that happens to be out
    if ab.trainer or not UnitExists("pet") then return nil end
    return ns.petRanks[ab.key]
end

local function MarkFromChat(ab, rank)
    local raised = {}
    Mark(ab, rank, raised)
    Report(raised, L.SRC_CHAT)
end

-- The pet's spellbook may still be loading (its ranks arrive a moment later): look again a few times.
local function ResolveRankLater(ab, tries)
    C_Timer.After(1.5, function()
        local rank = RankFromPet(ab)
        if rank then return MarkFromChat(ab, rank) end
        if tries > 1 and UnitExists("pet") then return ResolveRankLater(ab, tries - 1) end
        -- nothing tells the rank: rank 1 is certain at least, the rest is for the hunter to mark
        if ns.KnownRank(ab.key) == 0 then MarkFromChat(ab, 1) end
        if ab.maxRank > 1 then ns.Print(L.LEARNED_NO_RANK:format((ns.Names(ab)))) end
    end)
end

local function OnSystemMessage(msg)
    if type(msg) ~= "string" or ns.IsSecret(msg) then return end
    if not learnPatterns then BuildPatterns() end
    if unlearnPattern and msg:match(unlearnPattern) then return end
    local ab, rank, matched, hasRank
    for _, p in ipairs(learnPatterns) do
        local what = msg:match(p)
        if what then
            matched = true
            -- "Bite (Rank 2)" / "Укус (Уровень 2)" / "Bite"
            what = StripLinks(what)
            local name, sub = what:match("^(.-) *%((.-)%)$")
            ab, rank = Parse(name or what, sub)
            hasRank = sub ~= nil and sub:find("[0-9]") ~= nil
            if ab then break end
        end
    end
    if not matched then
        ab, rank = ParseFallback(msg)
        hasRank = true -- the fallback only accepts messages that end in "(... N)"
    end
    if not ab then return end
    if not hasRank and ab.maxRank > 1 then
        rank = RankBySpellId(ab, tonumber(msg:match("|Hspell:([0-9]+)"))) or RankFromPet(ab)
        if not rank then return ResolveRankLater(ab, 3) end
    end
    MarkFromChat(ab, rank)
end

-------------------------------------------------------------------------------
-- Manual marks
-------------------------------------------------------------------------------
function ns.SetKnown(key, rank)
    local ab = ns.Ability(key)
    if not ab then return end
    if ns.KnownRank(key) >= rank then
        ns.cdb.known[key] = rank - 1 > 0 and rank - 1 or nil
    else
        ns.cdb.known[key] = rank
    end
    ns.Changed()
end

-- Ranks the hunter knows that the main pet doesn't have yet and is old enough for.
function ns.PetTrainable()
    local main = ns.cdb and ns.cdb.main
    if not main then return nil end
    local petRanks = main.ranks or {}
    local out = {}
    for _, ab in ipairs(ns.ABILITIES) do
        if not ab.trainer and ns.FamilyCanLearn(ab, main.family) then
            local best
            for r = ns.KnownRank(ab.key), 1, -1 do
                if ab.ranks[r] and ab.ranks[r].lvl <= (main.level or 0) then
                    best = r
                    break
                end
            end
            if best and best > (petRanks[ab.key] or 0) then
                out[#out + 1] = { ab = ab, rank = best, tp = ab.ranks[best].tp }
            end
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- Events (throttled: many of these fire in bursts)
-------------------------------------------------------------------------------
local pending, lastPetId
local function Rescan()
    pending = nil
    ns.ScanPetSpellbook()
    SyncMain()
    ScanPlayerSpells()
    -- a pet was summoned, dismissed or swapped, or its spellbook changed (header, training helper)
    local parts = { ns.PetId() or "", ns.petRanksPartial and "?" or "" }
    for _, ab in ipairs(ns.ABILITIES) do
        if ns.petRanks[ab.key] then parts[#parts + 1] = ab.key .. ns.petRanks[ab.key] end
    end
    local id = table.concat(parts, ",")
    if id ~= lastPetId then
        lastPetId = id
        ns.Fire("PET")
    end
end
local function QueueRescan(delay)
    if pending then return end
    pending = true
    C_Timer.After(delay or 0.5, Rescan)
end

local f = CreateFrame("Frame")
ns.On("LOGIN", function()
    if not ns.isHunter then return end
    f:RegisterEvent("UNIT_PET")
    f:RegisterEvent("UNIT_LEVEL")
    f:RegisterEvent("PLAYER_LEVEL_UP")
    f:RegisterEvent("SPELLS_CHANGED")
    f:RegisterEvent("CHAT_MSG_SYSTEM")
    f:RegisterEvent("TRAINER_SHOW")
    f:RegisterEvent("TRAINER_UPDATE")
    f:RegisterEvent("UNIT_PET_TRAINING_POINTS")
    QueueRescan(2)
end)

f:SetScript("OnEvent", function(_, event, arg1)
    if event == "CHAT_MSG_SYSTEM" then
        OnSystemMessage(arg1)
        QueueRescan(1)
    elseif event == "TRAINER_SHOW" or event == "TRAINER_UPDATE" then
        ScanTrainer()
    elseif event == "UNIT_PET_TRAINING_POINTS" then
        ns.Fire("TP")
    elseif event == "UNIT_PET" or event == "UNIT_LEVEL" then
        if arg1 == "player" or arg1 == "pet" then QueueRescan(0.5) end
    elseif event == "PLAYER_LEVEL_UP" then
        -- UnitLevel("player") still returns the old level right now.
        C_Timer.After(1, ns.Changed)
        QueueRescan(0.5)
    else
        QueueRescan(0.5)
    end
end)
