-- World map integration: a MapCanvas data provider with three pooled pin types.
--   * area pins: soft circles showing roughly where a beast lives (scale with map zoom); drawn only
--     for the beast under the mouse or opened from the atlas, unless the "always" option is on,
--   * icon pins: family icon with a status-colored ring; nearby beasts are stacked into one pin,
--   * zone pins (continent maps): one summary per zone with the number of READY / SOON beasts.
-- Pins are rebuilt only when the map changes or the shared context changes. No OnUpdate.
local _, ns = ...
local L = ns.L
local S = ns.STATUS

local AREA_TEMPLATE = "BeastAtlasAreaPinTemplate"
local ICON_TEMPLATE = "BeastAtlasIconPinTemplate"
local ZONE_TEMPLATE = "BeastAtlasZonePinTemplate"
local TRAINER_TEMPLATE = "BeastAtlasTrainerPinTemplate"
local TRAINER_COLOR = { 0.35, 0.65, 1.00 }
local TRAINER_ICON = "Interface\\Icons\\Ability_Hunter_BeastTaming"
local BEAST_TRAINING_SPELL = 5149 -- its icon marks trainers, when the client knows the spell
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
-- own textures (white shapes, tinted here): see tools/make_media.py
local TEX_AREA = "Interface\\AddOns\\BeastAtlas\\Media\\Area"
local TEX_RING = "Interface\\AddOns\\BeastAtlas\\Media\\Ring"
local TEX_DISC = "Interface\\AddOns\\BeastAtlas\\Media\\Disc"
local STACK_DIST = 0.025 -- normalized map distance under which icons are merged
local ZONE_PIN_LINES = 6 -- distinct READY ranks listed in a zone pin tooltip

local function AddRoundMask(frame, tex)
    local mask = frame:CreateMaskTexture()
    mask:SetAllPoints(tex)
    mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    tex:AddMaskTexture(mask)
end

-- Round pin look: dark disc behind, round icon, anti-aliased ring tinted per pin.
local function SetupRoundPin(pin, hasIcon)
    pin.Backdrop:SetTexture(TEX_DISC)
    pin.Backdrop:SetVertexColor(0, 0, 0, 0.85)
    pin.Ring:SetTexture(TEX_RING)
    if hasIcon then AddRoundMask(pin, pin.Icon) end
end

-- The default implementation calls the protected SetPassThroughButtons; our pins don't need
-- right-click passthrough.
local function NoPassthrough() end

-------------------------------------------------------------------------------
-- Area pin
-------------------------------------------------------------------------------
BeastAtlasAreaPinMixin = CreateFromMixins(MapCanvasPinMixin)
BeastAtlasAreaPinMixin.CheckMouseButtonPassthrough = NoPassthrough
local areaPins = {} -- [npcId] = { pin, ... } on the map being shown

function BeastAtlasAreaPinMixin:OnLoad()
    self:UseFrameLevelType("PIN_FRAME_LEVEL_MAP_HIGHLIGHT") -- above fog of war, below icons
    self:EnableMouse(false)
    self.Fill:SetTexture(TEX_AREA)
end

-- pinned: drawn without the mouse (the "always" option, or the beast opened from the atlas)
function BeastAtlasAreaPinMixin:OnAcquired(x, y, r, status, id, pinned, highlighted)
    local canvas = self:GetMap():GetCanvas()
    -- r is a fraction of the map, and the map is wider than tall: the mean of both keeps it a circle
    local size = math.max(16, (canvas:GetWidth() + canvas:GetHeight()) * r)
    self:SetSize(size, size)
    self.color = ns.STATUS_COLOR[status] or ns.STATUS_COLOR[S.LATER]
    self.pinned = pinned
    self.baseAlpha = highlighted and 1 or 0.6
    local list = areaPins[id]
    if not list then
        list = {}
        areaPins[id] = list
    end
    list[#list + 1] = self
    self:SetHover(false)
    self:SetPosition(x, y)
end

function BeastAtlasAreaPinMixin:SetHover(on)
    local c = self.color
    self.Fill:SetVertexColor(c[1], c[2], c[3], on and 1 or self.baseAlpha)
    self.Fill:SetShown(on or self.pinned)
end

-- Show or hide every habitat of a beast on the current map (the mouse is over its pin).
local function HoverAreas(id, on)
    for _, pin in ipairs(areaPins[id] or {}) do pin:SetHover(on) end
end

-------------------------------------------------------------------------------
-- Icon pin
-------------------------------------------------------------------------------
BeastAtlasIconPinMixin = CreateFromMixins(MapCanvasPinMixin)
BeastAtlasIconPinMixin.CheckMouseButtonPassthrough = NoPassthrough

function BeastAtlasIconPinMixin:OnLoad()
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    self:SetScalingLimits(1, 0.9, 1.25)
    SetupRoundPin(self, true)
    self.Badge:SetTexture(TEX_DISC)
    self.Badge:SetVertexColor(0, 0, 0, 0.9)
end

function BeastAtlasIconPinMixin:OnAcquired(stack)
    self.stack = stack
    local lead = ns.BEASTS[stack.ids[1]]
    self.Icon:SetTexture(ns.FamilyIcon(lead and lead.f))
    local c = ns.STATUS_COLOR[stack.status] or ns.STATUS_COLOR[S.LATER]
    self.Ring:SetVertexColor(c[1], c[2], c[3], 1)
    local many = #stack.ids > 1
    self.Badge:SetShown(many)
    self.Count:SetShown(many)
    if many then self.Count:SetText(#stack.ids) end
    self.baseSize = stack.highlighted and 30 or 24
    self:SetSize(self.baseSize, self.baseSize)
    self:SetPosition(stack.x, stack.y)
end

local function AddBeastLines(tt, id)
    local b = ns.BEASTS[id]
    local main, second = ns.DisplayName(b)
    local fam = ns.FAMILIES[b.f]
    local lvl = b.l[1] == b.l[2] and tostring(b.l[1]) or (b.l[1] .. "-" .. b.l[2])
    tt:AddDoubleLine(main, lvl, 1, 0.82, 0, 1, 1, 1)
    if second then tt:AddLine(second, 0.6, 0.6, 0.6) end
    local famName = fam and (ns.Names(fam)) or b.f
    if b.s then famName = famName .. "  |cffaaaaaa" .. L.ATTACK_SPEED:format(b.s) .. "|r" end
    tt:AddLine(famName, 0.8, 0.8, 0.8)
    local _, list = ns.BeastInfo(id)
    if not list then return end
    for _, e in ipairs(list) do
        local ab = ns.Ability(e.key)
        local note = ns.StatusNote(e.status, e.key, e.rank, e.tame)
        tt:AddDoubleLine("  " .. ns.StatusHex(e.status) .. (ns.Names(ab)) .. " " .. e.rank .. "|r",
            ns.StatusHex(e.status) .. note .. "|r")
    end
end

function BeastAtlasIconPinMixin:OnMouseEnter()
    self:SetSize(self.baseSize + 6, self.baseSize + 6)
    -- where the beast on top of the stack lives (the same one the model shows)
    self.hoverId = self.stack.ids[1]
    HoverAreas(self.hoverId, true)
    local tt = GameTooltip
    tt:SetOwner(self, "ANCHOR_RIGHT")
    tt:AddLine(L.TT_HEADER, 0.67, 0.83, 0.45)
    local ids = self.stack.ids
    for i, id in ipairs(ids) do
        if i > 1 then tt:AddLine(" ") end
        if i > 6 then
            tt:AddLine(L.STACK:format(#ids), 0.7, 0.7, 0.7)
            break
        end
        AddBeastLines(tt, id)
    end
    tt:AddLine(#ids > 1 and L.PIN_HINT_STACK or L.PIN_HINT, 0.5, 0.5, 0.5)
    tt:Show()
    if ns.ShowTooltipModel then ns.ShowTooltipModel(ids[1]) end
end

function BeastAtlasIconPinMixin:OnMouseLeave()
    self:SetSize(self.baseSize, self.baseSize)
    if self.hoverId then HoverAreas(self.hoverId, false) end
    self.hoverId = nil
    GameTooltip:Hide()
    if ns.HideTooltipModel then ns.HideTooltipModel() end
end

-- Called by MapCanvasPinMixin:OnClick.
function BeastAtlasIconPinMixin:OnMouseClickAction(button)
    if button ~= "LeftButton" then return end
    local ids = self.stack.ids
    if IsShiftKeyDown() then
        ns.SetWaypoint(ids[1], self.stack.cluster)
    elseif #ids > 1 then
        ns.ShowStack(ids)
    else
        ns.ShowBeast(ids[1])
    end
end

-------------------------------------------------------------------------------
-- Pet trainer pin
-------------------------------------------------------------------------------
BeastAtlasTrainerPinMixin = CreateFromMixins(MapCanvasPinMixin)
BeastAtlasTrainerPinMixin.CheckMouseButtonPassthrough = NoPassthrough

local trainerIcon
local function TrainerIcon()
    if trainerIcon == nil then
        local tex
        if C_Spell and C_Spell.GetSpellTexture then
            local ok, v = pcall(C_Spell.GetSpellTexture, BEAST_TRAINING_SPELL)
            if ok and v and not ns.IsSecret(v) then tex = v end
        end
        trainerIcon = tex or TRAINER_ICON
    end
    return trainerIcon
end

function BeastAtlasTrainerPinMixin:OnLoad()
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    self:SetScalingLimits(1, 0.9, 1.25)
    SetupRoundPin(self, true)
    self.Ring:SetVertexColor(TRAINER_COLOR[1], TRAINER_COLOR[2], TRAINER_COLOR[3], 1)
end

function BeastAtlasTrainerPinMixin:OnAcquired(id, spot)
    self.trainerId, self.spot = id, spot
    self.Icon:SetTexture(TrainerIcon())
    local c = ns.TRAINERS[id].c
    self:SetPosition(c[spot] / 1000, c[spot + 1] / 1000)
end

function BeastAtlasTrainerPinMixin:OnMouseEnter()
    local t = ns.TRAINERS[self.trainerId]
    local tt = GameTooltip
    tt:SetOwner(self, "ANCHOR_RIGHT")
    local main, second = ns.DisplayName(t)
    tt:AddLine(main, 1, 0.82, 0)
    if second then tt:AddLine(second, 0.6, 0.6, 0.6) end
    tt:AddLine(L.TRAINER_ONLY, TRAINER_COLOR[1], TRAINER_COLOR[2], TRAINER_COLOR[3])
    local names = {}
    for _, ab in ipairs(ns.ABILITIES) do
        if ab.trainer then names[#names + 1] = (ns.Names(ab)) end
    end
    if #names > 0 then tt:AddLine(L.TRAINER_TEACHES:format(table.concat(names, ", ")), 0.8, 0.8, 0.8, true) end
    tt:AddLine(L.TRAINER_PIN_HINT, 0.5, 0.5, 0.5)
    tt:Show()
end

function BeastAtlasTrainerPinMixin:OnMouseLeave()
    GameTooltip:Hide()
end

function BeastAtlasTrainerPinMixin:OnMouseClickAction(button)
    if button == "LeftButton" then ns.SetTrainerWaypoint(self.trainerId, self.spot) end
end

-------------------------------------------------------------------------------
-- Zone summary pin (continent maps)
-------------------------------------------------------------------------------
BeastAtlasZonePinMixin = CreateFromMixins(MapCanvasPinMixin)
BeastAtlasZonePinMixin.CheckMouseButtonPassthrough = NoPassthrough

function BeastAtlasZonePinMixin:OnLoad()
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    self:SetScalingLimits(1, 0.9, 1.25)
    SetupRoundPin(self)
end

function BeastAtlasZonePinMixin:OnAcquired(summary)
    self.summary = summary
    local st = summary.ready > 0 and S.READY or S.SOON
    local c = ns.STATUS_COLOR[st]
    self.Ring:SetVertexColor(c[1], c[2], c[3], 1)
    self.Count:SetTextColor(c[1], c[2], c[3])
    self.Count:SetText(summary.ready > 0 and summary.ready or summary.soon)
    self:SetPosition(summary.x, summary.y)
end

function BeastAtlasZonePinMixin:OnMouseEnter()
    local sm = self.summary
    local tt = GameTooltip
    tt:SetOwner(self, "ANCHOR_RIGHT")
    tt:AddLine(ns.ZoneName(ns.ZoneByMap(sm.mapID)), 1, 0.82, 0)
    if sm.ready > 0 then
        local c = ns.STATUS_COLOR[S.READY]
        tt:AddLine(L.ZONE_READY:format(sm.ready), c[1], c[2], c[3])
    end
    if sm.soon > 0 then
        local c = ns.STATUS_COLOR[S.SOON]
        tt:AddLine(L.ZONE_SOON:format(sm.soon), c[1], c[2], c[3])
    end
    -- distinct READY ranks taught in this zone; built on hover only
    local seen, shown = {}, 0
    local c = ns.STATUS_COLOR[S.READY]
    for _, id in ipairs(sm.readyIds) do
        local _, list = ns.BeastInfo(id)
        for _, e in ipairs(list or {}) do
            if shown >= ZONE_PIN_LINES then break end
            if e.status == S.READY then
                local text = (ns.Names(ns.Ability(e.key))) .. " " .. e.rank
                if not seen[text] then
                    seen[text] = true
                    shown = shown + 1
                    tt:AddLine("  " .. text, c[1], c[2], c[3])
                end
            end
        end
        if shown >= ZONE_PIN_LINES then break end
    end
    tt:AddLine(L.ZONE_PIN_HINT, 0.5, 0.5, 0.5)
    tt:Show()
end

function BeastAtlasZonePinMixin:OnMouseLeave()
    GameTooltip:Hide()
end

function BeastAtlasZonePinMixin:OnMouseClickAction(button)
    if button ~= "LeftButton" then return end
    WorldMapFrame:SetMapID(self.summary.mapID)
end

-------------------------------------------------------------------------------
-- Data provider
-------------------------------------------------------------------------------
local Provider = CreateFromMixins(MapCanvasDataProviderMixin)

function Provider:RemoveAllData()
    wipe(areaPins)
    local map = self:GetMap()
    if not map then return end
    map:RemoveAllPinsByTemplate(AREA_TEMPLATE)
    map:RemoveAllPinsByTemplate(ICON_TEMPLATE)
    map:RemoveAllPinsByTemplate(ZONE_TEMPLATE)
    map:RemoveAllPinsByTemplate(TRAINER_TEMPLATE)
end

function Provider:RefreshTrainers(map, mapID)
    if not (ns.db.mapPins and ns.db.trainers) then return end
    for _, id in ipairs(ns.TrainersOnMap(mapID) or {}) do
        local c = ns.TRAINERS[id].c
        for spot = 1, #c, 2 do map:AcquirePin(TRAINER_TEMPLATE, id, spot) end
    end
end

function Provider:RefreshZone(map, mapID)
    local ids = ns.BeastsOnMap(mapID)
    if not ids then return end

    local spots = {}
    for _, id in ipairs(ids) do
        local highlighted = ns.highlight == id
        local best = ns.BeastUseful(id)
        if highlighted and not best then best = ns.BeastInfo(id) or S.LATER end
        if best and (ns.db.mapPins or highlighted) then
            local c = ns.BEASTS[id].c
            for i = 1, #c, 3 do
                local x, y, r = c[i] / 1000, c[i + 1] / 1000, c[i + 2] / 1000
                map:AcquirePin(AREA_TEMPLATE, x, y, r, best, id, ns.db.areasAlways or highlighted, highlighted)
                spots[#spots + 1] = { x = x, y = y, id = id, status = best, cluster = i, highlighted = highlighted }
            end
        end
    end

    -- merge icons that would overlap; the most relevant beast leads the stack
    table.sort(spots, function(a, b)
        if a.highlighted ~= b.highlighted then return a.highlighted end
        if a.status ~= b.status then return a.status < b.status end
        return a.id < b.id
    end)
    local stacks = {}
    for _, s in ipairs(spots) do
        local target
        for _, st in ipairs(stacks) do
            if math.abs(st.x - s.x) < STACK_DIST and math.abs(st.y - s.y) < STACK_DIST * 1.5 then
                target = st
                break
            end
        end
        if target then
            local dup = false
            for _, id in ipairs(target.ids) do if id == s.id then dup = true break end end
            if not dup then table.insert(target.ids, s.id) end
        else
            stacks[#stacks + 1] = { x = s.x, y = s.y, ids = { s.id }, status = s.status,
                cluster = s.cluster, highlighted = s.highlighted }
        end
    end
    for _, st in ipairs(stacks) do map:AcquirePin(ICON_TEMPLATE, st) end
end

-- Centre of a zone on a continent map, cached (false = not placeable there).
local zoneCentre = {} -- [continentMapID][zoneMapID] = { x, y } | false
local function ZoneCentre(zoneMapID, continentMapID)
    local perContinent = zoneCentre[continentMapID]
    if not perContinent then
        perContinent = {}
        zoneCentre[continentMapID] = perContinent
    end
    local cached = perContinent[zoneMapID]
    if cached == nil then
        cached = false
        local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, zoneMapID, continentMapID)
        if ok and minX and maxX and minY and maxY and maxX > minX and maxY > minY then
            local x, y = (minX + maxX) / 2, (minY + maxY) / 2
            if x >= 0 and x <= 1 and y >= 0 and y <= 1 then cached = { x, y } end
        end
        perContinent[zoneMapID] = cached
    end
    if cached then return cached[1], cached[2] end
    return nil
end

function Provider:RefreshContinent(map, mapID)
    if not ns.db.mapPins or not C_Map.GetMapRectOnMap then return end
    for zoneMapID, ids in pairs(ns.BeastsByMap()) do
        local ready, soon, readyIds = 0, 0, nil
        for _, id in ipairs(ids) do
            local best = ns.BeastUseful(id)
            if best == S.READY then
                ready = ready + 1
                readyIds = readyIds or {}
                readyIds[#readyIds + 1] = id
            elseif best == S.SOON then
                soon = soon + 1
            end
        end
        if ready > 0 or soon > 0 then
            local x, y = ZoneCentre(zoneMapID, mapID)
            if x then
                map:AcquirePin(ZONE_TEMPLATE, { mapID = zoneMapID, x = x, y = y, ready = ready, soon = soon,
                    readyIds = readyIds or {} })
            end
        end
    end
end

function Provider:RefreshAllData()
    self:RemoveAllData()
    if InCombatLockdown() then
        self.refreshOwed = true
        return
    end
    self.refreshOwed = nil
    local map = self:GetMap()
    if not map or not ns.db or not ns.isHunter then return end
    local mapID = map:GetMapID()
    local info = mapID and C_Map.GetMapInfo(mapID)
    if not info then return end
    local t = info.mapType
    if t == Enum.UIMapType.Continent then
        self:RefreshContinent(map, mapID)
    elseif t == Enum.UIMapType.Zone or t == Enum.UIMapType.Micro then
        self:RefreshZone(map, mapID)
        self:RefreshTrainers(map, mapID)
    end
end

-------------------------------------------------------------------------------
-- Toggle button on the world map
-------------------------------------------------------------------------------
local function CreateMapButton()
    local parent = WorldMapFrame.ScrollContainer or WorldMapFrame
    local b = CreateFrame("Button", "BeastAtlasMapButton", parent)
    b:SetSize(28, 28)
    b:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, -8)
    b:SetFrameStrata("HIGH")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 3, -3)
    icon:SetPoint("BOTTOMRIGHT", -3, 3)
    icon:SetTexture("Interface\\Icons\\Ability_Hunter_BeastTaming")
    b.icon = icon
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(icon)
    hl:SetColorTexture(1, 1, 1, 0.2)
    local function Update() icon:SetDesaturated(not ns.db.mapPins) end
    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ns.SetOption("areasAlways", not ns.db.areasAlways)
        else
            local on = not ns.db.mapPins
            if not on then ns.ClearHighlight() end
            ns.SetOption("mapPins", on)
        end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(L.MAP_TOGGLE, 1, 1, 1)
        GameTooltip:AddLine(L.MAP_TOGGLE_HINT, 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ns.On("OPTION", Update)
    Update()
    return b
end

ns.On("LOGIN", function()
    if not ns.isHunter then return end
    if not (WorldMapFrame and WorldMapFrame.AddDataProvider and MapCanvasDataProviderMixin) then return end
    WorldMapFrame:AddDataProvider(Provider)
    ns.mapButton = CreateMapButton()
    WorldMapFrame:HookScript("OnHide", function() ns.ClearHighlight() end)

    local queued
    local function Refresh()
        queued = nil
        if WorldMapFrame:IsShown() then Provider:RefreshAllData() end
    end
    local function Queue()
        if queued then return end
        queued = true
        C_Timer.After(0.1, Refresh)
    end
    ns.On("CHANGED", Queue)
    ns.On("MAP_REFRESH", Queue)

    -- a refresh skipped during combat is done once combat ends
    local events = CreateFrame("Frame")
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    events:SetScript("OnEvent", function()
        if Provider.refreshOwed then Queue() end
    end)
end)
