-- World map integration: a MapCanvas data provider with four pooled pin types.
--   * area pins: soft circles showing roughly where a beast lives (scale with map zoom); drawn only
--     for the beast under the mouse or opened from the atlas, unless the "always" option is on,
--   * icon pins: family icon with a status-colored ring; nearby beasts are stacked into one pin,
--   * service pins: pet trainers and stable masters of the player's faction,
--   * zone pins (continent maps): one summary per zone with the number of READY / SOON beasts.
-- Pins are rebuilt only when the map changes or the shared context changes. No OnUpdate.
local _, ns = ...
local L = ns.L
local S = ns.STATUS

local AREA_TEMPLATE = "BeastAtlasAreaPinTemplate"
local ICON_TEMPLATE = "BeastAtlasIconPinTemplate"
local ZONE_TEMPLATE = "BeastAtlasZonePinTemplate"
local TRAINER_TEMPLATE = "BeastAtlasTrainerPinTemplate"
-- Service NPCs share one pin template. icon: the icon of a spell the client knows, else the fallback texture.
local SERVICE = {
    trainer = { color = { 0.35, 0.65, 1.00 }, spell = 5149, -- Beast Training
        fallback = "Interface\\Icons\\Ability_Hunter_BeastTaming", label = "TRAINER_ONLY" },
    stable = { color = { 0.80, 0.62, 1.00 }, spell = 883,   -- Call Pet
        fallback = "Interface\\Icons\\Ability_Hunter_BeastCall", label = "STABLE_MASTER" },
}
-- A trainer and a stable master often stand together. The map canvas has its own way to keep such pins
-- apart (MapCanvasMixin:CalculatePinNudging, used for flight points): a "source" pin pushes "target" pins
-- away. The stable master is pushed away from a trainer closer than this fraction of the map - fully when
-- the map is zoomed out, not at all when it is zoomed in and both can be shown where they really stand.
local SERVICE_NUDGE = 0.035
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
-- own textures (white shapes, tinted here): see tools/make_media.py
local TEX_AREA = "Interface\\AddOns\\BeastAtlas\\Media\\Area"
local TEX_RING = "Interface\\AddOns\\BeastAtlas\\Media\\Ring"
local TEX_DISC = "Interface\\AddOns\\BeastAtlas\\Media\\Disc"
local STACK_DIST = 0.025 -- normalized map distance under which icons are merged
local AREA_MIN_R = 0.045  -- smallest habitat radius drawn, as a fraction of the map
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
    -- (a tight cluster still gets a circle clearly wider than the pin on top of it)
    local size = math.max(16, (canvas:GetWidth() + canvas:GetHeight()) * math.max(r, AREA_MIN_R))
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
    local focus = ns.focus
    local focusShown = false
    for _, e in ipairs(list or {}) do
        local ab = ns.Ability(e.key)
        local note = ns.StatusNote(e.status, e.key, e.rank, e.tame)
        tt:AddDoubleLine("  " .. ns.StatusHex(e.status) .. (ns.Names(ab)) .. " " .. e.rank .. "|r",
            ns.StatusHex(e.status) .. note .. "|r")
        if focus and e.key == focus.key and e.rank == focus.rank then focusShown = true end
    end
    -- the rank the map is filtered by, also when the window's filters leave it out of the list above
    if focus and focus.ids[id] and not focusShown then
        local st, tame = ns.BeastRankStatus(id, focus.key, focus.rank)
        tt:AddDoubleLine("  " .. ns.StatusHex(st) .. focus.label .. "|r",
            ns.StatusHex(st) .. ns.StatusNote(st, focus.key, focus.rank, tame) .. "|r")
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
-- Service pin: a pet trainer or a stable master (kind = "trainer" | "stable")
-------------------------------------------------------------------------------
BeastAtlasTrainerPinMixin = CreateFromMixins(MapCanvasPinMixin)
BeastAtlasTrainerPinMixin.CheckMouseButtonPassthrough = NoPassthrough

local function ServiceIcon(service)
    if service.icon == nil then
        local tex
        if C_Spell and C_Spell.GetSpellTexture then
            local ok, v = pcall(C_Spell.GetSpellTexture, service.spell)
            if ok and v and not ns.IsSecret(v) then tex = v end
        end
        service.icon = tex or service.fallback
    end
    return service.icon
end

local function ServiceEntry(kind, id)
    local src = kind == "stable" and ns.STABLES or ns.TRAINERS
    return src and src[id]
end

function BeastAtlasTrainerPinMixin:OnLoad()
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    self:SetScalingLimits(1, 0.9, 1.25)
    SetupRoundPin(self, true)
end

-- Pins are pooled and shared by both kinds: everything that tells them apart is set here, not in OnLoad.
function BeastAtlasTrainerPinMixin:OnAcquired(kind, id, spot)
    self.kind, self.npcId, self.spot = kind, id, spot
    local service = SERVICE[kind]
    self.Icon:SetTexture(ServiceIcon(service))
    self.Ring:SetVertexColor(service.color[1], service.color[2], service.color[3], 1)
    -- nudging has to be set up before the position: SetPosition is what queues the calculation
    if kind == "stable" then
        self:SetNudgeSourceRadius(0)
        self:SetNudgeTargetFactor(SERVICE_NUDGE)
        self:SetNudgeZoomedOutFactor(1)
        self:SetNudgeZoomedInFactor(0)
    else
        self:SetNudgeTargetFactor(0)
        self:SetNudgeSourceRadius(1)
        self:SetNudgeSourceMagnitude(1, 1)
    end
    local c = ServiceEntry(kind, id).c
    self:SetPosition(c[spot] / 1000, c[spot + 1] / 1000)
end

function BeastAtlasTrainerPinMixin:OnMouseEnter()
    local service = SERVICE[self.kind]
    local t = ServiceEntry(self.kind, self.npcId)
    local tt = GameTooltip
    tt:SetOwner(self, "ANCHOR_RIGHT")
    local main, second = ns.DisplayName(t)
    tt:AddLine(main, 1, 0.82, 0)
    if second then tt:AddLine(second, 0.6, 0.6, 0.6) end
    tt:AddLine(L[service.label], service.color[1], service.color[2], service.color[3])
    if self.kind == "stable" then
        tt:AddLine(L.STABLE_TIP, 0.8, 0.8, 0.8, true)
    else
        local names = {}
        for _, ab in ipairs(ns.ABILITIES) do
            if ab.trainer then names[#names + 1] = (ns.Names(ab)) end
        end
        if #names > 0 then tt:AddLine(L.TRAINER_TEACHES:format(table.concat(names, ", ")), 0.8, 0.8, 0.8, true) end
    end
    tt:AddLine(L.TRAINER_PIN_HINT, 0.5, 0.5, 0.5)
    tt:Show()
end

function BeastAtlasTrainerPinMixin:OnMouseLeave()
    GameTooltip:Hide()
end

function BeastAtlasTrainerPinMixin:OnMouseClickAction(button)
    if button ~= "LeftButton" then return end
    if self.kind == "stable" then
        ns.SetStableWaypoint(self.npcId, self.spot)
    else
        ns.SetTrainerWaypoint(self.npcId, self.spot)
    end
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
    -- with a rank focus: how many of its teachers live in the zone, coloured by the best of them
    local st = summary.focus and summary.status or (summary.ready > 0 and S.READY or S.SOON)
    local c = ns.STATUS_COLOR[st] or ns.STATUS_COLOR[S.LATER]
    self.Ring:SetVertexColor(c[1], c[2], c[3], 1)
    self.Count:SetTextColor(c[1], c[2], c[3])
    self.Count:SetText(summary.focus and summary.count or (summary.ready > 0 and summary.ready or summary.soon))
    self:SetPosition(summary.x, summary.y)
end

function BeastAtlasZonePinMixin:OnMouseEnter()
    local sm = self.summary
    local tt = GameTooltip
    tt:SetOwner(self, "ANCHOR_RIGHT")
    tt:AddLine(ns.ZoneName(ns.ZoneByMap(sm.mapID)), 1, 0.82, 0)
    if sm.focus then
        local c = ns.STATUS_COLOR[sm.status] or ns.STATUS_COLOR[S.LATER]
        tt:AddLine(L.FOCUS_ZONE:format(sm.focus, sm.count), c[1], c[2], c[3])
        tt:AddLine(L.ZONE_PIN_HINT, 0.5, 0.5, 0.5)
        tt:Show()
        return
    end
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

-- Pet trainers and stable masters, each with its own option.
function Provider:RefreshServices(map, mapID)
    if not ns.db.mapPins then return end
    local function Pin(kind, src, ids)
        for _, id in ipairs(ids or {}) do
            for spot = 1, #src[id].c, 2 do map:AcquirePin(TRAINER_TEMPLATE, kind, id, spot) end
        end
    end
    if ns.db.trainers then Pin("trainer", ns.TRAINERS, ns.TrainersOnMap(mapID)) end
    if ns.db.stables then Pin("stable", ns.STABLES, ns.StablesOnMap(mapID)) end
end

function Provider:RefreshZone(map, mapID)
    local ids = ns.BeastsOnMap(mapID)
    if not ids then return end

    local spots = {}
    local focus = ns.focus
    for _, id in ipairs(ids) do
        local highlighted = ns.highlight == id
        local best
        if focus then
            -- only the teachers of the chosen rank, coloured by what that rank is to the hunter
            best = focus.ids[id] and ns.BeastRankStatus(id, focus.key, focus.rank) or nil
        else
            best = ns.BeastUseful(id)
            if highlighted and not best then best = ns.BeastInfo(id) or S.LATER end
        end
        if best and (ns.db.mapPins or highlighted or focus) then
            local c = ns.BEASTS[id].c
            for i = 1, #c, 3 do
                local x, y, r = c[i] / 1000, c[i + 1] / 1000, c[i + 2] / 1000
                -- the few beasts of a focus are shown with their habitats
                map:AcquirePin(AREA_TEMPLATE, x, y, r, best, id, ns.db.areasAlways or highlighted or focus ~= nil, highlighted)
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
    if not C_Map.GetMapRectOnMap then return end
    local focus = ns.focus
    if focus then
        -- one pin per zone where a teacher of the chosen rank lives
        for zoneMapID, ids in pairs(ns.BeastsByMap()) do
            local count, status = 0, nil
            for _, id in ipairs(ids) do
                if focus.ids[id] then
                    count = count + 1
                    local st = ns.BeastRankStatus(id, focus.key, focus.rank)
                    if not status or st < status then status = st end
                end
            end
            local x, y
            if count > 0 then x, y = ZoneCentre(zoneMapID, mapID) end
            if x then
                map:AcquirePin(ZONE_TEMPLATE, { mapID = zoneMapID, x = x, y = y, focus = focus.label, count = count,
                    status = status, ready = 0, soon = 0, readyIds = {} })
            end
        end
        return
    end
    if not ns.db.mapPins then return end
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
        self:RefreshServices(map, mapID)
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

    -- While a rank focus is on, a bar on the map says so; a click on it shows everything again.
    local parent = WorldMapFrame.ScrollContainer or WorldMapFrame
    local bar = CreateFrame("Button", "BeastAtlasMapFocus", parent)
    bar:SetHeight(22)
    bar:SetPoint("TOPRIGHT", ns.mapButton, "TOPLEFT", -6, -3)
    bar:SetFrameStrata("HIGH")
    local barBg = bar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(0, 0, 0, 0.75)
    local barHl = bar:CreateTexture(nil, "HIGHLIGHT")
    barHl:SetAllPoints()
    barHl:SetColorTexture(1, 1, 1, 0.12)
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("CENTER")
    bar:SetScript("OnClick", function() ns.ClearFocus() end)
    bar:Hide()
    ns.On("MAP_REFRESH", function()
        local focus = ns.focus
        bar:SetShown(focus ~= nil)
        if focus then
            bar.text:SetText("|cffffd100" .. L.FOCUS_BAR:format(focus.label) .. "|r  " .. L.FOCUS_BAR_CLEAR)
            bar:SetWidth((bar.text:GetStringWidth() or 200) + 18)
        end
    end)
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
