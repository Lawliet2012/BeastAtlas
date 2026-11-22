-- Minimal stand-ins for the WoW Forever client API, for offline tests (tools/test_load.py).
-- Shapes follow the client's UI source (Blizzard_MapCanvas, Blizzard_TrainerUI, API docs), not the addon.
-- Globals set by the runner before this file: __LOCALE, __CLASS, __TEMPLATES ({ name = { mixin=, keys={} } }).

local function noop() end

__out = {}     -- everything printed
__frames = {}
__clock = 0
__combat = false
__SHIFT = false
__U = {        -- unit state; a unit that is nil doesn't exist
    player = { name = "Hunter", level = 30 },
}
__spellText, __spellRequests = {}, 0
__petSpells = {}       -- { { "Bite", "Rank 2" }, ... }
__knownSpells = {}     -- [spellID] = true
__trainerType = nil
__trainer = {}         -- { { name, serviceType, subText }, ... }
__playerMap = 1429
__playerPos = { x = 0.5, y = 0.5 }

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    __out[#__out + 1] = table.concat(parts, " ")
end

-------------------------------------------------------------------------------
-- frames
-------------------------------------------------------------------------------
local Mock
local NUM = { GetWidth = 600, GetHeight = 400, GetFrameLevel = 5, GetEffectiveScale = 1, GetModelFileID = 12345,
    GetStringWidth = 100 }

local function newMock(kind, name)
    return setmetatable({ __kind = kind, __shown = true, __scripts = {}, __hooks = {}, __events = {},
        __name = name }, Mock)
end

function __run(f, ev, ...)
    local s = f.__scripts[ev]
    if s then s(f, ...) end
    for _, h in ipairs(f.__hooks[ev] or {}) do h(f, ...) end
end

Mock = { __index = function(t, k)
    -- only widget methods (Capitalised) resolve; plain fields stay nil like on a real frame
    if type(k) ~= "string" or not k:sub(1, 1):match("%u") then return nil end
    if NUM[k] then return function() return NUM[k] end end
    if k == "CreateTexture" or k == "CreateFontString" or k == "CreateMaskTexture" or k == "GetFontString" then
        return function() return newMock(k) end
    end
    if k == "SetScript" then return function(self, ev, fn) self.__scripts[ev] = fn end end
    if k == "HookScript" then
        return function(self, ev, fn)
            self.__hooks[ev] = self.__hooks[ev] or {}
            table.insert(self.__hooks[ev], fn)
        end
    end
    if k == "GetScript" then return function(self, ev) return self.__scripts[ev] end end
    if k == "RegisterEvent" then return function(self, ev) self.__events[ev] = true end end
    if k == "UnregisterEvent" then return function(self, ev) self.__events[ev] = nil end end
    if k == "Show" then return function(self) if not self.__shown then self.__shown = true; __run(self, "OnShow") end end end
    if k == "Hide" then return function(self) if self.__shown then self.__shown = false; __run(self, "OnHide") end end end
    if k == "SetShown" then return function(self, v) if v then self:Show() else self:Hide() end end end
    if k == "IsShown" then return function(self) return self.__shown end end
    if k == "SetChecked" then return function(self, v) self.__checked = v and true or false end end
    if k == "GetChecked" then return function(self) return self.__checked end end
    if k == "HasFocus" then return function() return false end end
    if k == "GetText" then return function(self) return self.__text or "" end end
    -- a wrapped string is as tall as its text needs at its width (6 px per byte, 12 px per line)
    if k == "SetWidth" then return function(self, w) self.__width = w end end
    if k == "SetSize" then return function(self, w, h) self.__w, self.__h = w, h end end
    if k == "SetHeight" then return function(self, h) self.__h = h end end
    if k == "SetVertexColor" then return function(self, r, g, b, a) self.__color = { r, g, b, a } end end
    if k == "SetPosition" then return function(self, x, y) self.__x, self.__y = x, y end end
    if k == "GetStringHeight" then
        return function(self)
            local w = rawget(self, "__width")
            if not w or w <= 0 then return 12 end
            return 12 * math.max(1, math.ceil(#(self.__text or "") * 6 / w))
        end
    end
    if k == "SetText" then return function(self, v) self.__text = v end end
    if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
    if k == "GetCenter" then return function() return 100, 100 end end
    if k == "GetName" then return function(self) return self.__name end end
    if k == "GetParent" then return function(self) return self.__parent end end
    if k == "IsMouseClickEnabled" or k == "IsMouseMotionEnabled" then return function(self) return self.__mouse end end
    return noop
end }

function CreateFrame(kind, name, parent, template)
    local f = newMock(kind, name)
    f.__parent = parent
    if name then _G[name] = f end
    if template == "ButtonFrameTemplate" then
        f.Inset = newMock("Frame")
        f.CloseButton = newMock("Button")
    elseif template == "SearchBoxTemplate" then
        f.Instructions = newMock("FontString")
    elseif template == "WowScrollBoxList" then
        -- like the real scroll box: rows come from a pool and are (re)initialised for the visible data
        f.__pool, f.__active = {}, {}
        f.SetDataProvider = function(self, provider, retain)
            assert(type(provider) == "table" and provider.__tbl, "SetDataProvider needs CreateDataProvider(tbl)")
            assert(type(retain) == "boolean", "retainScrollPosition must be a ScrollBoxConstants value")
            local view = assert(self.__view, "scroll box used before InitScrollBoxListWithScrollBar")
            self.__active, self.__used = {}, {}
            for i = 1, math.min(#provider.__tbl, 40) do
                local d = provider.__tbl[i]
                assert(type(view.extent(i, d)) == "number", "row extent must be a number")
                -- like the real one: the factory names a template, rows are pooled per template
                local made
                view.factory(function(template, init)
                    assert(__ROW_TEMPLATES[template], "row template not defined in UI.xml: " .. tostring(template))
                    -- the view sizes each row to the calculated extent (ResizeFrame); only the paragraph
                    -- template is meant to vary, the others must match their XML height
                    if template == "BeastAtlasTextRowTemplate" then
                        assert(view.extent(i, d) >= __ROW_TEMPLATES[template], "paragraph row shorter than its template")
                    else
                        assert(__ROW_TEMPLATES[template] == view.extent(i, d), "extent differs from the template height")
                    end
                    local pool = self.__pool[template] or {}
                    self.__pool[template] = pool
                    local n = (self.__used[template] or 0) + 1
                    self.__used[template] = n
                    made = pool[n]
                    if not made then
                        made = CreateFrame("Button", nil, self, template)
                        pool[n] = made
                    end
                    made.__extent = view.extent(i, d)
                    init(made)
                end, d)
                assert(made, "the element factory did not create a frame")
                self.__active[i] = made
            end
        end
        f.ForEachFrame = function(self, fn)
            for _, row in ipairs(self.__active) do fn(row) end
        end
    end
    table.insert(__frames, f)
    return f
end

function __fire(event, ...)
    for _, f in ipairs(__frames) do
        if f.__events[event] and f.__scripts.OnEvent then f.__scripts.OnEvent(f, event, ...) end
    end
end

-------------------------------------------------------------------------------
-- timers with a controllable clock
-------------------------------------------------------------------------------
local timers = {}
local function addTimer(delay, fn, period)
    local t = { due = __clock + delay, fn = fn, period = period }
    t.Cancel = function(self) self.cancelled = true end
    timers[#timers + 1] = t
    return t
end
C_Timer = {
    After = function(d, fn) addTimer(d, fn) end,
    NewTimer = function(d, fn) return addTimer(d, fn) end,
    NewTicker = function(d, fn) return addTimer(d, fn, d) end,
}
function GetTime() return __clock end

function __advance(seconds)
    local target = __clock + seconds
    while true do
        local idx, best
        for i, t in ipairs(timers) do
            if not t.cancelled and t.due <= target and (not best or t.due < best.due) then idx, best = i, t end
        end
        if not best then break end
        __clock = best.due
        if best.period then best.due = best.due + best.period else table.remove(timers, idx) end
        best.fn()
    end
    for i = #timers, 1, -1 do if timers[i].cancelled then table.remove(timers, i) end end
    __clock = target
end

-------------------------------------------------------------------------------
-- units, spells, trainer
-------------------------------------------------------------------------------
function GetLocale() return __LOCALE end
function UnitClass() return __CLASS, __CLASS end
__FACTION = __FACTION or "Horde" -- the runner may ask for an Alliance player
function UnitFactionGroup() return __FACTION, __FACTION end
-- Secret values: in instances the client hands addons opaque values (here: marked tables). The Unit*
-- functions refuse a secret unit token from addon code, exactly as the game does.
__secrets = setmetatable({}, { __mode = "k" })
function __secret() local v = {}; __secrets[v] = true; return v end
local function U(u)
    if __secrets[u] then
        error("Secret values are only allowed during untainted execution for this argument.", 3)
    end
    return __U[u]
end
function UnitExists(u) return U(u) ~= nil end
function UnitIsDead() return false end
__onTaxi = false
function UnitOnTaxi() return __onTaxi end
function UnitLevel(u) u = U(u); return u and u.level end
function UnitName(u) u = U(u); return u and u.name end
function UnitGUID(u) u = U(u); return u and u.guid end
function UnitCreatureFamily(u) u = U(u); return u and u.family end
function GetCursorPosition() return 0, 0 end
function IsShiftKeyDown() return __SHIFT end
function InCombatLockdown() return __combat end
function issecretvalue(v) return type(v) == "table" and __secrets[v] == true end
date = os.date

Enum = {
    UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5, Orphan = 6 },
    TrainerType = { General = 0, TalentsObsolete = 1, Tradeskills = 2, Pet = 3 },
    SpellBookSpellBank = { Player = 0, Pet = 1 },
    TooltipDataType = { Unit = 2 },
}
C_SpellBook = {
    HasPetSpells = function() if __U.pet and #__petSpells > 0 then return #__petSpells, "PET" end end,
    GetSpellBookItemName = function(i, bank)
        assert(bank == Enum.SpellBookSpellBank.Pet, "pet bank expected")
        local s = __petSpells[i]
        if s then return s[1], s[2] or "" end
    end,
    IsSpellKnown = function(id) return __knownSpells[id] or false end,
}
C_Spell = {
    GetSpellName = function(id) if id == 1515 then return "Tame Beast" end return "Spell" .. tostring(id) end,
    GetSpellTexture = function() return 132162 end,
    -- like the client: empty until the spell's text has been requested once
    GetSpellDescription = function(id) return __spellText[id] and ("Description " .. id) or "" end,
    RequestLoadSpellData = function(id) __spellText[id] = true; __spellRequests = __spellRequests + 1 end,
}
C_PetInfo = { GetPetTrainingPoints = function() return 30, 12 end }
C_Trainer = { GetTrainerType = function() return __trainerType end }
function GetNumTrainerServices() return #__trainer end
function GetTrainerServiceInfo(i)
    local r = __trainer[i]
    if r then return r[1], r[2], 136243, 1, r[3], "cat" end
end

-------------------------------------------------------------------------------
-- maps: zone ids are Zone maps; 1414 (Kalimdor) / 1415 (Eastern Kingdoms) continents; ids >= 9000 unknown
-------------------------------------------------------------------------------
local function continentOf(id) return (id % 2 == 0) and 1414 or 1415 end
function CreateVector2D(x, y) return { x = x, y = y } end
C_Map = {
    GetMapInfo = function(id)
        if type(id) ~= "number" or id >= 9000 then return nil end
        if id == 947 then return { mapID = id, name = "Azeroth", mapType = 1, parentMapID = 946 } end
        if id == 1414 or id == 1415 then return { mapID = id, name = "Continent" .. id, mapType = 2, parentMapID = 947 } end
        if id == 8000 then return { mapID = id, name = "Cave", mapType = 5, parentMapID = 1429 } end
        return { mapID = id, name = "Map" .. id, mapType = 3, parentMapID = continentOf(id) }
    end,
    GetAreaInfo = function(id) return "Area" .. id end,
    GetMapChildrenInfo = function()
        return { { mapID = 2521, name = "Area16593", mapType = 3 }, { mapID = 2523, name = "Area16591", mapType = 3 } }
    end,
    GetBestMapForUnit = function() return __playerMap end,
    GetPlayerMapPosition = function() return __playerPos and { x = __playerPos.x, y = __playerPos.y } end,
    GetWorldPosFromMapPos = function(id, v)
        return continentOf(id) == 1414 and 1 or 0, { x = v.x * 3000 + (id % 50) * 3000, y = v.y * 2000 }
    end,
    GetMapRectOnMap = function(zone, top)
        if continentOf(zone) ~= top then return 0, 0, 0, 0 end
        local k = (zone % 50) / 50
        return k * 0.8, k * 0.8 + 0.1, 0.3, 0.4
    end,
    CanSetUserWaypointOnMap = function() return true end,
    SetUserWaypoint = function(p) __waypoint = p end,
}
UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { m, x, y } end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = noop }

-------------------------------------------------------------------------------
-- world map canvas (behaviour copied from Blizzard_MapCanvas AcquirePin)
-------------------------------------------------------------------------------
function CreateFromMixins(...)
    local t = {}
    for i = 1, select("#", ...) do for k, v in pairs((select(i, ...))) do t[k] = v end end
    return t
end
MapCanvasPinMixin = {
    OnLoad = noop, OnAcquired = noop, OnMouseEnter = noop, OnMouseLeave = noop,
    UseFrameLevelType = function(self, t) self.__levelType = t end,
    SetScalingLimits = noop,
    ApplyFrameLevel = function(self) self:SetFrameLevel(10) end,
    SetPosition = function(self, x, y)
        assert(x >= 0 and x <= 1 and y >= 0 and y <= 1, "pin position out of the map")
        self.__x, self.__y = x, y
    end,
    GetMap = function(self) return self.owningMap end,
    SetNudgeTargetFactor = function(self, v) self.__nudgeTarget = v end,
    SetNudgeSourceRadius = function(self, v) self.__nudgeRadius = v end,
    SetNudgeSourceMagnitude = function(self, out, inn) self.__nudgeMagOut, self.__nudgeMagIn = out, inn end,
    SetNudgeZoomedOutFactor = function(self, v) self.__nudgeOut = v end,
    SetNudgeZoomedInFactor = function(self, v) self.__nudgeIn = v end,
    OnClick = function(self, ...) if self.OnMouseClickAction then self:OnMouseClickAction(...) end end,
    -- the real one calls the protected SetPassThroughButtons; an addon pin must not get here
    CheckMouseButtonPassthrough = function() error("protected SetPassThroughButtons called from addon pin") end,
}
MapCanvasDataProviderMixin = { GetMap = function(self) return self.owningMap end }

local Map = { pins = {}, id = 1429 }
__map = Map
function Map:GetMapID() return self.id end
function Map:GetCanvas() return self.canvas end
-- Released pins go back to their template's pool and are handed out again, last released first.
function Map:RemoveAllPinsByTemplate(tpl)
    self.pool = self.pool or {}
    local pool = self.pool[tpl] or {}
    self.pool[tpl] = pool
    for _, pin in ipairs(self.pins[tpl] or {}) do
        pin.__nudgeOut, pin.__nudgeIn = nil, nil
        pool[#pool + 1] = pin
    end
    self.pins[tpl] = {}
end
function Map:AcquirePin(tpl, ...)
    assert(not __combat, "AcquirePin during combat")
    local def = assert(__TEMPLATES[tpl], "unknown pin template " .. tostring(tpl))
    local pin = self.pool and self.pool[tpl] and table.remove(self.pool[tpl])
    if not pin then
        -- a new frame: the mixin's OnLoad runs once, never again when the pin is reused
        pin = CreateFrame("Frame")
        for k, v in pairs(assert(_G[def.mixin], "mixin " .. def.mixin .. " missing")) do pin[k] = v end
        for key in pairs(def.keys) do pin[key] = CreateFrame("Region") end
        pin.__mouse = def.mouse
        pin.owningMap = self
        assert(pin:GetScript("OnEnter") == nil and pin:GetScript("OnLeave") == nil, "pin has OnEnter/OnLeave")
        pin:OnLoad()
    end
    pin:OnAcquired(...)
    pin:CheckMouseButtonPassthrough("RightButton")
    pin:ApplyFrameLevel()
    self.pins[tpl] = self.pins[tpl] or {}
    table.insert(self.pins[tpl], pin)
    return pin
end
function __pinCount(tpl)
    return #(Map.pins[tpl] or {})
end
-- Where a pin is drawn at a zoom level (0 = zoomed out, 1 = zoomed in): its position plus the push of the
-- first source pin near enough, as MapCanvasMixin:CalculatePinNudging and ApplyPinPosition do it.
function __drawnAt(target, zoom)
    local x, y = target.__x, target.__y
    local factor = target.__nudgeTarget or 0
    if factor <= 0 then return x, y end
    for _, list in pairs(Map.pins) do
        for _, source in ipairs(list) do
            local radius = source.__nudgeRadius or 0
            if source ~= target and radius > 0 then
                local limit = factor * radius
                local dx, dy = x - source.__x, y - source.__y
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist < limit then
                    local vx, vy = 1, 0
                    if dist > 0 then vx, vy = dx / dist, dy / dist end
                    local lerp = function(a, b) return a + (b - a) * zoom end
                    local push = (1 - dist / limit) * factor * lerp(target.__nudgeOut or 0, target.__nudgeIn or 0)
                        * lerp(source.__nudgeMagOut or 0, source.__nudgeMagIn or 0)
                    return x + vx * push, y + vy * push
                end
            end
        end
    end
    return x, y
end

UIParent = CreateFrame("Frame", "UIParent")
Minimap = CreateFrame("Frame", "Minimap")
WorldMapFrame = CreateFrame("Frame", "WorldMapFrame")
WorldMapFrame.__shown = false
Map.canvas = CreateFrame("Frame")
WorldMapFrame.AddDataProvider = function(self, p)
    p.owningMap = Map
    self.__provider = p
end
WorldMapFrame.SetMapID = function(self, id)
    Map.id = id
    if self.__provider then self.__provider:RefreshAllData() end
end
function OpenWorldMap(id)
    WorldMapFrame:Show()
    WorldMapFrame:SetMapID(id)
end

-------------------------------------------------------------------------------
-- misc
-------------------------------------------------------------------------------
function strsplit(sep, s)
    local out = {}
    for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%-", "%%-")) do out[#out + 1] = part end
    return unpack(out)
end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
tinsert = table.insert
UISpecialFrames = {}
SlashCmdList = {}
-- scroll box API (Blizzard_SharedXML/Shared/Scroll)
ScrollBoxConstants = { RetainScrollPosition = true, DiscardScrollPosition = false }
function CreateDataProvider(tbl) return { __tbl = tbl } end
function CreateScrollBoxListLinearView()
    local view = {}
    function view:SetElementExtent(n) self.extent = function() return n end end
    function view:SetElementExtentCalculator(fn) self.extent = fn end
    function view:SetElementFactory(fn) self.factory = fn end
    return view
end
ScrollUtil = { InitScrollBoxListWithScrollBar = function(box, bar, view)
    assert(view.factory and view.extent, "view needs an element factory and an extent calculator")
    box.__view = view
end }
function PanelTemplates_SetNumTabs(frame, n) frame.numTabs = n end
function PanelTemplates_SetTab(frame, i)
    assert(frame.numTabs and i >= 1 and i <= frame.numTabs, "bad tab index")
    frame.selectedTab = i
end

GameTooltip = CreateFrame("GameTooltip", "GameTooltip")
GameTooltip.__lines = {}
GameTooltip.SetOwner = function(self) self.__lines = {}; self.__shown = true end
GameTooltip.AddLine = function(self, t) table.insert(self.__lines, tostring(t)) end
GameTooltip.AddDoubleLine = function(self, a, b) table.insert(self.__lines, tostring(a) .. " | " .. tostring(b)) end
GameTooltip.GetUnit = function() return UnitName("mouseover"), "mouseover" end
GameTooltip.SetSpellByID = function(self, id) table.insert(self.__lines, "<spell " .. id .. ">"); return true end
TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) __unitTooltip = fn end }

if __LOCALE == "ruRU" then
    ERR_LEARN_SPELL_S = "Вы выучили новое заклинание: \"%s\"."
end
if __LOCALE == "enUS" then
    ERR_LEARN_ABILITY_S = "You have learned a new ability: %s."
    ERR_LEARN_SPELL_S = "You have learned a new spell: %s."
    ERR_SPELL_UNLEARNED_S = "You have unlearned %s."
end
