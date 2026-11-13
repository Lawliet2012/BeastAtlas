-- Training helper: a small panel that walks the hunter through learning one ability rank and
-- teaching it to the main pet. It shows only while there is something to do:
--   1. stable your pet, tame a beast that knows the rank   (the target is such a beast)
--   2. fight until the chat says it is learned             (a teacher pet is out)
--   3. get the main pet back                               (the rank is learned, the main pet is not out)
--   4. teach it at Beast Training                          (the main pet is out)
-- The steps follow Petopia's training guide (tools/cache/petopia/training.html).
-- Everything is derived from what the other modules already track; nothing is polled.
local _, ns = ...
local L = ns.L
local S = ns.STATUS

local WIDTH = 290
local CHECK = "|TInterface\\AddOns\\BeastAtlas\\Media\\Check:13:13:0:0|t "
local GOLD, WHITE, GREY, GREEN, RED = "|cffffd100", "|cffffffff", "|cff808080", "|cff4dff4d", "|cffff4040"
-- which stage the panel leads with when several things are possible at once
local STAGE_ORDER = { [2] = 1, [4] = 2, [1] = 3, [3] = 4 }

local function Label(goal)
    return (ns.Names(goal.ab)) .. " " .. goal.rank
end

-- npc id of a living wild beast from the atlas that is targeted right now
local function TargetBeast()
    if not UnitExists("target") or UnitIsDead("target") then return nil end
    local guid = UnitGUID("target")
    if not guid or ns.IsSecret(guid) then return nil end
    local id = tonumber(guid:match("^Creature%-[^%-]*%-[^%-]*%-[^%-]*%-[^%-]*%-([0-9]+)"))
    return id and ns.BEASTS[id] and id or nil
end

-- What can be done right now: { { ab=, rank=, stage=1..4, forMain=bool, minLevel=n|nil, tp=, targetId= }, ... },
-- the most relevant first. Empty when there is nothing to do.
function ns.TrainingGoals()
    local goals, seen = {}, {}
    if not (ns.isHunter and ns.cdb) then return goals end
    local main = ns.cdb.main
    local mainOut = ns.ActivePetIsMain()

    local function Add(ab, rank, stage, extra)
        local k = ab.key .. ":" .. rank
        if seen[k] then return end
        seen[k] = true
        local g = extra or {}
        g.ab, g.rank, g.stage = ab, rank, stage
        g.forMain = main ~= nil and ns.FamilyCanLearn(ab, main.family)
        local lvl = ab.ranks[rank] and ab.ranks[rank].lvl
        if main and lvl and lvl > (main.level or 0) then g.minLevel = lvl end
        goals[#goals + 1] = g
    end

    -- a pet that is not the main one is out and knows ranks the hunter hasn't learned: it is a teacher
    if UnitExists("pet") and main and not mainOut and not ns.petRanksPartial then
        for key, rank in pairs(ns.petRanks) do
            local ab = ns.Ability(key)
            if ab and not ab.trainer and ns.KnownRank(key) < rank then Add(ab, rank, 2) end
        end
    end
    -- learned by the hunter, missing on the main pet, and the pet is old enough.
    -- No pet out is the usual state after abandoning the teacher (the main pet waits in the stable);
    -- on a flight path the pet is merely hidden, so nothing is prompted there.
    if UnitExists("pet") or not (UnitOnTaxi and UnitOnTaxi("player")) then
        for _, e in ipairs(ns.PetTrainable() or {}) do
            Add(e.ab, e.rank, mainOut and 4 or 3, { tp = e.tp })
        end
    end
    -- the target would teach something that is needed now
    local id = TargetBeast()
    if id then
        local _, list = ns.BeastInfo(id)
        for _, e in ipairs(list or {}) do
            local ab = ns.Ability(e.key)
            if ab and e.status == S.READY then Add(ab, e.rank, 1, { targetId = id }) end
        end
    end

    table.sort(goals, function(a, b)
        if a.stage ~= b.stage then return STAGE_ORDER[a.stage] < STAGE_ORDER[b.stage] end
        if a.forMain ~= b.forMain then return a.forMain end
        if a.ab.order ~= b.ab.order then return a.ab.order < b.ab.order end
        return a.rank > b.rank
    end)
    return goals
end

-------------------------------------------------------------------------------
-- panel
-------------------------------------------------------------------------------
local panel

local function Line(parent, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetWidth(WIDTH - 24)
    fs:SetJustifyH("LEFT")
    fs:SetSpacing(2)
    return fs
end

local function CreatePanel()
    local f = CreateFrame("Frame", "BeastAtlasHelperFrame", UIParent, "BackdropTemplate")
    f:SetWidth(WIDTH)
    f:SetFrameStrata("MEDIUM")
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.07, 0.92)
    f:SetBackdropBorderColor(0.7, 0.6, 0.3, 1)
    local p = ns.db.helperPos
    if p and p.point then f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y) else f:SetPoint("LEFT", UIParent, "LEFT", 40, 120) end
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ns.db.helperPos = { point = point, relPoint = relPoint, x = x, y = y }
    end)

    f.title = Line(f, "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 12, -10)
    f.title:SetWidth(WIDTH - 44)
    f.lines = {}
    for i = 1, 7 do f.lines[i] = Line(f) end

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    close:SetScale(0.8)
    close:SetScript("OnClick", function()
        -- this step stays hidden (also after a relog) until the rank is done; other steps still show
        ns.cdb.helperDismissed[f.signature] = true
        f:Hide()
    end)
    f.close = close
    f:Hide()
    return f
end

local function StepText(index, stage, text)
    if index < stage then return CHECK .. GREY .. text .. "|r" end
    if index == stage then return GOLD .. index .. ".|r " .. WHITE .. text .. "|r" end
    return GREY .. index .. ". " .. text .. "|r"
end

local function Cost(tp)
    return tp and L.TP:format(tp) or L.TP_UNKNOWN
end

local function Render(goals)
    local g = goals[1]
    local main = ns.cdb.main
    local mainName = main and main.name or "?"
    local out = {}

    local step1 = L.HELPER_STEP1
    if g.stage == 1 and g.targetId then
        local name = (ns.Names(ns.BEASTS[g.targetId]))
        -- a hunter cannot tame while a pet is out: it has to go to the stable first
        step1 = (UnitExists("pet") and L.HELPER_STEP1_STABLE or L.HELPER_STEP1_TARGET):format(name)
    end
    out[#out + 1] = StepText(1, g.stage, step1)
    out[#out + 1] = StepText(2, g.stage, L.HELPER_STEP2)
    if g.stage == 2 then out[#out + 1] = GREY .. L.HELPER_STEP2_HINT .. "|r" end
    if g.forMain then
        out[#out + 1] = StepText(3, g.stage, L.HELPER_STEP3:format(mainName))
        local tp = g.tp
        if tp == nil and g.ab.ranks[g.rank] then tp = g.ab.ranks[g.rank].tp end
        out[#out + 1] = StepText(4, g.stage, L.HELPER_STEP4:format(Label(g) .. " (" .. Cost(tp) .. ")"))
        if g.stage == 4 and tp then
            -- the points of the rank being replaced are refunded, so only the difference is needed
            local onPet = main and main.ranks and main.ranks[g.ab.key]
            local refund = onPet and g.ab.ranks[onPet] and g.ab.ranks[onPet].tp or 0
            local need, free = tp - refund, ns.TrainingPoints()
            if free and free < need then out[#out + 1] = RED .. L.HELPER_TP_SHORT:format(need, free) .. "|r" end
        elseif g.minLevel then
            out[#out + 1] = GREY .. L.HELPER_TOO_YOUNG:format(mainName, g.minLevel) .. "|r"
        end
    else
        out[#out + 1] = GREY .. L.HELPER_NOT_FOR_MAIN:format(mainName) .. "|r"
    end
    if #goals > 1 then
        local more = {}
        for i = 2, math.min(#goals, 5) do more[#more + 1] = Label(goals[i]) end
        out[#out + 1] = GREEN .. L.HELPER_MORE:format(table.concat(more, ", ")) .. "|r"
    end

    panel.title:SetText(L.HELPER_TITLE:format(Label(g)))
    local height = 10 + panel.title:GetStringHeight() + 6
    local prev = panel.title
    for i, fs in ipairs(panel.lines) do
        local text = out[i]
        fs:SetShown(text ~= nil)
        if text then
            fs:SetText(text)
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, i == 1 and -6 or -5)
            height = height + fs:GetStringHeight() + 5
            prev = fs
        end
    end
    panel:SetHeight(height + 10)
end

-- Closed steps are remembered per "ability:rank:stage"; forget those whose rank is no longer needed.
local function Dismissed()
    local set = ns.cdb.helperDismissed
    if type(set) ~= "table" then
        set = {}
        ns.cdb.helperDismissed = set
    end
    for signature in pairs(set) do
        local key, rank = signature:match("^([a-z]+):([0-9]+):")
        local main = ns.cdb.main
        local onPet = main and main.ranks and main.ranks[key] or 0
        if not key or onPet >= tonumber(rank) then set[signature] = nil end
    end
    return set
end

local function Update()
    if not (ns.isHunter and ns.db) then return end
    Dismissed()
    local goals = ns.db.helper and ns.TrainingGoals() or {}
    local g = goals[1]
    if not g then
        if panel then panel:Hide() end
        return
    end
    local signature = g.ab.key .. ":" .. g.rank .. ":" .. g.stage
    if ns.cdb.helperDismissed[signature] then
        if panel then panel:Hide() end
        return
    end
    if not panel then panel = CreatePanel() end
    panel.signature = signature
    Render(goals)
    panel:Show()
end

local queued
local function Queue()
    if queued then return end
    queued = true
    C_Timer.After(0.2, function()
        queued = nil
        Update()
    end)
end

ns.On("CHANGED", Queue) -- known ranks, main pet, options
ns.On("PET", Queue)     -- summoned pet or its spellbook changed
ns.On("TP", Queue)

local f = CreateFrame("Frame")
f:SetScript("OnEvent", Queue)
ns.On("LOGIN", function()
    if not ns.isHunter then return end
    f:RegisterEvent("PLAYER_TARGET_CHANGED")
    C_Timer.After(4, Queue)
end)
