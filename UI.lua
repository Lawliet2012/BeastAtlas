-- The atlas window, built from the game's own widgets so it looks like a stock panel:
-- ButtonFrameTemplate (portrait, title, close button, inset), PanelTabButtonTemplate tabs,
-- SearchBoxTemplate, WowScrollBoxList + MinimalScrollBar lists, InsetFrameTemplate for the detail pane.
local _, ns = ...
local L = ns.L
local S = ns.STATUS

local W, H = 900, 560
local ATTIC = 88                 -- area above the inset: main pet, training points, filters, search
local DETAIL_W = 300
local ABILITY_W = 244
local ROW_H, GROUP_H, HEADER_H = 32, 24, 36
local RIGHT_W = 110
local NEARBY_MAX, SEARCH_MAX = 60, 250
local MOVE_YARDS = 40
local ICON = "Interface\\Icons\\Ability_Hunter_BeastTaming"
local GUIDE_ICON = "Interface\\Icons\\INV_Misc_Note_02"
local ICON_BORDER = "Interface\\AddOns\\BeastAtlas\\Media\\Frame" -- white square frame, tinted per row
local GREY, GOLD, RED = "|cff8a8a8a", "|cffffd100", "|cffff6060"
-- wrapped paragraphs in a list (the family card, the guide): the same width for measuring and drawing
local TEXT_X, TEXT_W, TEXT_PAD, TEXT_SPACING = 10, 286, 6, 3
local TEXT_FONT = "GameFontHighlightSmall"
local TEXT_MIN_H = 20
local ROLE_ORDER = { "O", "G", "D" }     -- Petopia's family categories: offense, general, defense
local CLOSE_LEVELS = 3                    -- a pet keeps the level it was tamed at: suggest beasts this close
local PER_ROLE, FASTEST_MAX = 2, 5
local PET_SEARCH_MAX = 200                -- rows of a search over the whole pet list
local USUAL_SPEED = 2.0                   -- the attack speed most beasts have
local NEUTRAL, TAMEABLE = { 0.55, 0.55, 0.55 }, { 0.30, 1.00, 0.30 }

local frame, state
-- family: the family shown on the Families tab; nil = the "how to choose a pet" guide
-- rareOnly: the Families tab lists only the beasts Petopia marks as rare, elite or otherwise special
state = { tab = "nearby", ability = nil, beast = nil, family = nil, search = "", stack = nil, expanded = {},
    rareOnly = false }

-------------------------------------------------------------------------------
-- helpers
-------------------------------------------------------------------------------
local Lower = ns.Lower

local function Matches(q, ...)
    if q == "" then return true end
    for i = 1, select("#", ...) do
        local s = select(i, ...)
        if s and Lower(s):find(q, 1, true) then return true end
    end
    return false
end

local function LevelText(b)
    if b.l[1] <= 0 then return "??" end -- level unknown
    return b.l[1] == b.l[2] and tostring(b.l[1]) or (b.l[1] .. "-" .. b.l[2])
end

local DistanceText = ns.DistanceText

local function CostText(tp)
    return tp and L.TP:format(tp) or L.TP_UNKNOWN
end

local function SpeedText(s)
    return string.format("%.1f", s)
end

-------------------------------------------------------------------------------
-- model (shared helper; falls back to the family icon if the model won't load)
-------------------------------------------------------------------------------
local function CreateModel(parent, w, h)
    local m = CreateFrame("PlayerModel", nil, parent)
    m:SetSize(w, h)
    m.fallback = m:CreateTexture(nil, "OVERLAY")
    m.fallback:SetSize(64, 64)
    m.fallback:SetPoint("CENTER")
    m.fallback:Hide()
    m.rotation = 0.6
    m:EnableMouse(true)
    m:EnableMouseWheel(true)
    m:SetScript("OnMouseDown", function(self)
        self.dragX = GetCursorPosition()
        self:SetScript("OnUpdate", function(s)
            local x = GetCursorPosition()
            s.rotation = s.rotation + (x - s.dragX) * 0.012
            s.dragX = x
            s:SetRotation(s.rotation)
        end)
    end)
    m:SetScript("OnMouseUp", function(self) self:SetScript("OnUpdate", nil) end)
    m:SetScript("OnHide", function(self) self:SetScript("OnUpdate", nil) end)
    m:SetScript("OnMouseWheel", function(self, delta)
        self.zoom = math.min(2.5, math.max(0.6, (self.zoom or 1) - delta * 0.1))
        if self.SetCamDistanceScale then self:SetCamDistanceScale(self.zoom) end
    end)
    return m
end

local function SetModelBeast(m, id)
    m.npcId = id
    m.fallback:Hide()
    m:ClearModel()
    local b = ns.Creature(id)
    if not b then return end
    m.fallback:SetTexture(ns.FamilyIcon(b.f))
    m:SetCreature(id)
    m.zoom = 1
    if m.SetCamDistanceScale then m:SetCamDistanceScale(1) end
    if m.SetPortraitZoom then m:SetPortraitZoom(0) end
    m:SetRotation(m.rotation)
    if not m.GetModelFileID then return end
    local tries = 0
    local function Check()
        if m.npcId ~= id then return end
        local ok, fileID = pcall(m.GetModelFileID, m)
        if ok and fileID and fileID ~= 0 then
            m.fallback:Hide()
            m:SetRotation(m.rotation)
            return
        end
        tries = tries + 1
        if tries <= 5 then
            m:SetCreature(id) -- the creature may need a server query on first view
            C_Timer.After(0.35, Check)
        else
            m.fallback:Show()
        end
    end
    C_Timer.After(0.2, Check)
end

-- small model next to GameTooltip (map pin hover)
local ttModel
function ns.HideTooltipModel() if ttModel then ttModel:Hide() end end

function ns.ShowTooltipModel(id)
    if not ttModel then
        local holder = CreateFrame("Frame", nil, GameTooltip, "BackdropTemplate")
        holder:SetSize(150, 150)
        holder:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 14,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        holder:SetBackdropColor(0.04, 0.05, 0.06, 0.9)
        holder:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        holder.model = CreateModel(holder, 142, 142)
        holder.model:SetPoint("CENTER")
        holder.model:EnableMouse(false)
        ttModel = holder
        -- otherwise it would reappear under the next, unrelated tooltip
        GameTooltip:HookScript("OnHide", ns.HideTooltipModel)
    end
    ttModel:ClearAllPoints()
    ttModel:SetPoint("TOPLEFT", GameTooltip, "BOTTOMLEFT", 0, -2)
    ttModel:Show()
    SetModelBeast(ttModel.model, id)
end

-------------------------------------------------------------------------------
-- list widget: the game's ScrollBox with rows of BeastAtlasRowTemplate (UI.xml)
-------------------------------------------------------------------------------
-- One template per row kind (UI.xml): the scroll box positions rows by the height of their template.
local function RowTemplate(d)
    if d.kind == "group" then return "BeastAtlasGroupRowTemplate", GROUP_H end
    if d.kind == "header" then return "BeastAtlasHeaderRowTemplate", HEADER_H end
    -- a paragraph: as tall as its text. The scroll box sizes each row to the calculated extent
    -- (ScrollBoxListLinearViewMixin:ResizeFrame), so one template serves every height.
    if d.kind == "text" then return "BeastAtlasTextRowTemplate", d.height end
    return "BeastAtlasRowTemplate", ROW_H
end

local function RowExtent(_, d)
    local _, height = RowTemplate(d)
    return height
end

local PetTooltip -- defined with the rows of the Families tab

local function BuildRow(r, onClick)
    r.built = true
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- section bar (group rows), like the category bars of the profession window
    r.groupBg = r:CreateTexture(nil, "BACKGROUND")
    r.groupBg:SetPoint("TOPLEFT", 0, -1)
    r.groupBg:SetPoint("BOTTOMRIGHT", 0, 1)
    r.groupBg:SetAtlas("common-button-list-collapseExpand")
    -- faint strip under rank headers
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetPoint("TOPLEFT", 0, -1)
    r.bg:SetPoint("BOTTOMRIGHT", 0, 1)
    r.bg:SetColorTexture(1, 1, 1, 0.05)
    r.sel = r:CreateTexture(nil, "BORDER")
    r.sel:SetAllPoints()
    r.sel:SetAtlas("Professions_Recipe_Active")
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetAtlas("Professions_Recipe_Hover")
    r.hl:SetAlpha(0.5)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(26, 26)
    r.icon:SetPoint("LEFT", 6, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.border = r:CreateTexture(nil, "OVERLAY")
    r.border:SetTexture(ICON_BORDER)
    r.border:SetSize(28, 28)
    r.border:SetPoint("CENTER", r.icon)
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.text:SetJustifyH("LEFT")
    r.text:SetWordWrap(false)
    r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.sub:SetJustifyH("LEFT")
    r.sub:SetWordWrap(false)
    r.right = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.right:SetPoint("TOPRIGHT", -6, -5)
    r.right:SetWordWrap(false)
    r.right:SetJustifyH("RIGHT")
    r:SetScript("OnClick", function(self, button) if self.data then onClick(self.data, button) end end)
    r:SetScript("OnEnter", function(self)
        local d = self.data
        if d and d.kind == "pet" then return PetTooltip(self, d) end
        local multi = d and (d.ready or 0) >= 2
        if not d or not (d.tip or d.spell or d.fallbackTip or multi) then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        -- the game's own tooltip of the ability (in the client's language), when we know its spell
        local native = d.spell and GameTooltip.SetSpellByID and GameTooltip:SetSpellByID(d.spell)
        if not native and d.fallbackTip then GameTooltip:AddLine(d.fallbackTip, 0.8, 0.8, 0.8, true) end
        if multi then GameTooltip:AddLine(L.MULTI_TIP:format(d.ready), 1, 0.82, 0, true) end
        if d.tip then GameTooltip:AddLine(d.tip, 0.6, 0.6, 0.6, true) end
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- rank headers: show the teachers of this rank on the map
    r.mapBtn = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    r.mapBtn:SetSize(72, 17)
    r.mapBtn:SetPoint("BOTTOMRIGHT", -5, 3)
    r.mapBtn:SetNormalFontObject("GameFontHighlightSmall")
    r.mapBtn:SetHighlightFontObject("GameFontHighlightSmall")
    r.mapBtn:SetText(L.ON_MAP)
    r.mapBtn:SetScript("OnClick", function(self)
        local row = self:GetParent().data
        if row and row.kind == "header" then ns.FocusRank(row.ab.key, row.rank) end
    end)
    r.mapBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.FOCUS_BUTTON_TIP, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    r.mapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r.mapBtn:Hide()
end

-- Rows are recycled between kinds: re-anchor the texts only when the kind changes.
local function Layout(r, kind)
    if r.kind == kind then return end
    r.kind = kind
    local icon = kind == "beast" or kind == "ability"
    r.icon:SetShown(icon)
    r.border:SetShown(icon)
    r.groupBg:SetShown(kind == "group")
    r.bg:SetShown(kind == "header")
    r.sub:SetShown(kind ~= "group" and kind ~= "text")
    local x = icon and 40 or 10
    r.text:ClearAllPoints()
    r.sub:ClearAllPoints()
    if kind == "text" then
        -- rows of the text template are never reused for another kind
        r.text:SetFontObject(TEXT_FONT)
        r.text:SetPoint("TOPLEFT", TEXT_X, -TEXT_PAD)
        r.text:SetWidth(TEXT_W)
        r.text:SetWordWrap(true)
        r.text:SetJustifyV("TOP")
        r.text:SetSpacing(TEXT_SPACING)
        r.right:SetText("")
        r.sel:Hide()
        r:EnableMouse(false) -- plain text: no hover bar, no clicks
    elseif kind == "group" then
        r.text:SetPoint("LEFT", x, 0)
        r.text:SetPoint("RIGHT", -6, 0)
    else
        local top = kind == "header" and -5 or -3
        r.text:SetPoint("TOPLEFT", x, top)
        r.text:SetPoint("TOPRIGHT", -6, top)
        r.sub:SetPoint("BOTTOMLEFT", x, kind == "header" and 5 or 3)
        r.sub:SetPoint("BOTTOMRIGHT", -6, kind == "header" and 5 or 3)
    end
    r.rightW = 0
end

-- The right label is only as wide as its text (up to RIGHT_W); the main text ends before it.
local function SetRight(r, text)
    text = text or ""
    r.right:SetWidth(0) -- natural width first, then cap it
    r.right:SetText(text)
    local w = 0
    if text ~= "" then
        w = math.min(RIGHT_W, math.ceil(r.right:GetStringWidth() or RIGHT_W) + 2)
        r.right:SetWidth(w)
    end
    if r.rightW ~= w and r.kind ~= "group" then
        r.text:SetPoint("TOPRIGHT", w > 0 and -(w + 12) or -6, r.kind == "header" and -5 or -3)
        r.rightW = w
    end
end

local function CreateList(parent, onUpdateRow, onClick)
    local holder = CreateFrame("Frame", nil, parent)
    local bar = CreateFrame("EventFrame", nil, holder, "MinimalScrollBar")
    bar:SetPoint("TOPRIGHT", -6, -6)
    bar:SetPoint("BOTTOMRIGHT", -6, 6)
    local box = CreateFrame("Frame", nil, holder, "WowScrollBoxList")
    box:SetPoint("TOPLEFT", 2, -2)
    box:SetPoint("BOTTOMRIGHT", bar, "BOTTOMLEFT", -6, -4)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtentCalculator(RowExtent)
    view:SetElementFactory(function(factory, d)
        factory((RowTemplate(d)), function(r)
            if not r.built then BuildRow(r, onClick) end
            r.data = d
            onUpdateRow(r, d)
        end)
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)

    holder.data = {}
    function holder:SetData(data, keepScroll)
        self.data = data
        box:SetDataProvider(CreateDataProvider(data),
            keepScroll and ScrollBoxConstants.RetainScrollPosition or ScrollBoxConstants.DiscardScrollPosition)
    end
    -- redraw the visible rows in place (selection, loaded descriptions)
    function holder:Refresh()
        box:ForEachFrame(function(r)
            if r.data then onUpdateRow(r, r.data) end
        end)
    end
    return holder
end

-------------------------------------------------------------------------------
-- row renderers
-------------------------------------------------------------------------------

-- Description of a rank in the client's language (C_Spell); the shipped English text only on English clients.
local descPending = false
local descRequested = {} -- [spellID] = true
local function SpellDesc(rank)
    if rank.spell and C_Spell and C_Spell.GetSpellDescription then
        local ok, text = pcall(C_Spell.GetSpellDescription, rank.spell)
        if ok and type(text) == "string" and not ns.IsSecret(text) then
            if text ~= "" then return (text:gsub("[\r\n]+", " ")) end
            -- not loaded yet: ask for it once; SPELL_TEXT_UPDATE redraws the list
            if not descRequested[rank.spell] and C_Spell.RequestLoadSpellData then
                descRequested[rank.spell] = true
                pcall(C_Spell.RequestLoadSpellData, rank.spell)
                descPending = true
            end
        end
    end
    if GetLocale():sub(1, 2) == "en" then return rank.desc or "" end
    return ""
end

local function TeachText(list, max)
    local parts = {}
    for i, e in ipairs(list or {}) do
        if i > (max or 4) then break end
        local ab = ns.Ability(e.key)
        if ab then
            parts[#parts + 1] = ns.StatusHex(e.status) .. (ns.Names(ab)) .. " " .. e.rank .. "|r"
        end
    end
    return table.concat(parts, ", ")
end

-- How many ranks worth learning now a beast teaches: with two or more, one tame does the work of several.
local function ReadyCount(list)
    local n = 0
    for _, e in ipairs(list or {}) do
        if e.status == S.READY then n = n + 1 end
    end
    return n
end

local function SetStatusBorder(r, status)
    local c = ns.STATUS_COLOR[status] or ns.STATUS_COLOR[S.LATER]
    r.border:SetVertexColor(c[1], c[2], c[3], 1)
end

-- Like recipe difficulty in the profession window, the name's colour carries the status.
local function BeastRow(r, d)
    Layout(r, "beast")
    local b = ns.BEASTS[d.id]
    local status = d.status or S.LATER
    r.icon:SetTexture(ns.FamilyIcon(b.f))
    SetStatusBorder(r, status)
    r.text:SetFontObject("GameFontHighlight")
    local main, second = ns.DisplayName(b)
    r.text:SetText(ns.StatusHex(status) .. main .. "|r  " .. LevelText(b) .. (second and ("  " .. GREY .. second .. "|r") or ""))
    SetRight(r, d.dist and DistanceText(d.dist) or (GREY .. ns.ZoneName(b.z) .. "|r"))
    -- at the start of the line, where a long list of ranks cannot push it out of sight
    d.ready = ReadyCount(d.list)
    local multi = d.ready >= 2 and (GOLD .. L.MULTI:format(d.ready) .. "|r ") or ""
    r.sub:SetText(multi .. TeachText(d.list) .. (d.dist and ("  " .. GREY .. ns.ZoneName(b.z) .. "|r") or ""))
    r.sel:SetShown(state.beast == d.id)
end

local function AbilityRow(r, d)
    Layout(r, "ability")
    local ab = d.ab
    r.icon:SetTexture("Interface\\Icons\\" .. ab.icon)
    SetStatusBorder(r, d.status)
    r.text:SetFontObject("GameFontNormal")
    r.text:SetText(ns.DisplayName(ab, true))
    SetRight(r, d.right or "")
    local p = ns.Plan(ab.key)
    local main = ns.Ctx().main
    local onPet = main and main.ranks and main.ranks[ab.key] or 0
    -- with a main pet: what the pet has; the hunter's own rank only when it is ahead (can be taught)
    local have = main and onPet or p.known
    local sub = L.YOUR_RANK:format(have > 0 and have or L.NONE) .. " / " .. ab.maxRank
    if main and p.hunter > onPet then sub = sub .. " " .. GREY .. "(" .. L.KNOWN_BY_YOU:format(p.hunter) .. ")|r" end
    if d.next then sub = sub .. "   " .. ns.StatusHex(d.status) .. "> " .. d.next .. "|r" end
    r.sub:SetText(sub)
    r.sel:SetShown(not d.jump and state.ability == ab.key)
end

local function HeaderRow(r, d)
    Layout(r, "header")
    local ab, rank = d.ab, d.ab.ranks[d.rank]
    r.text:SetFontObject("GameFontHighlight")
    local trainer = ab.trainer or rank.trainer
    -- StatusNote would claim "source unknown" for trainer ranks; the right label says where they come from
    local note = ""
    if not trainer or d.status == S.LEARNED then note = ns.StatusNote(d.status, ab.key, d.rank) end
    r.text:SetText(ns.StatusHex(d.status) .. L.RANK:format(d.rank) .. "|r  " .. L.PET_LEVEL:format(rank.lvl)
        .. "  " .. CostText(rank.tp))
    r.sub:SetText("|cffaaaaaa" .. SpellDesc(rank) .. "|r")
    -- the button sits at the end of the description line
    r.mapBtn:SetShown(d.onMap and true or false)
    r.sub:SetPoint("BOTTOMRIGHT", d.onMap and -82 or -6, 5)
    if trainer and d.status ~= S.LEARNED then
        SetRight(r, GREY .. L.TRAINER_ONLY .. "|r")
    else
        SetRight(r, ns.StatusHex(d.status) .. note .. "|r")
    end
    r.sel:Hide()
end

local function GroupRow(r, d)
    Layout(r, "group")
    r.text:SetFontObject("GameFontNormal")
    r.text:SetText(d.text)
    r.right:SetText("")
    r.sel:Hide()
end

local function TextRow(r, d)
    Layout(r, "text")
    r.text:SetText(d.text)
end

local function DietText(fam)
    local parts = {}
    for i, food in ipairs(fam.diet or {}) do parts[i] = L["FOOD_" .. food] or food end
    return table.concat(parts, ", ")
end

local function GuideRow(r)
    Layout(r, "ability")
    r.icon:SetTexture(GUIDE_ICON)
    r.border:SetVertexColor(1, 0.82, 0.1, 1)
    r.text:SetFontObject("GameFontNormal")
    r.text:SetText(L.GUIDE_TITLE)
    SetRight(r, "")
    r.sub:SetText(GREY .. L.GUIDE_SUB .. "|r")
    r.sel:SetShown(state.family == nil)
end

local function FamilyRow(r, d)
    Layout(r, "ability")
    local fam = ns.FAMILIES[d.key]
    r.icon:SetTexture(ns.FamilyIcon(d.key))
    local c = d.main and TAMEABLE or NEUTRAL
    r.border:SetVertexColor(c[1], c[2], c[3], 1)
    r.text:SetFontObject("GameFontNormal")
    r.text:SetText(ns.DisplayName(fam, true))
    SetRight(r, "")
    local sub = L.FAM_ROW_SUB:format(d.stats.count, d.stats.minLevel, d.stats.maxLevel)
    if d.main then sub = sub .. "  |cff4dff4d" .. L.FAM_MAIN_TAG .. "|r" end
    r.sub:SetText(sub)
    r.sel:SetShown(state.family == d.key)
end

local function KnowsText(b)
    local parts = {}
    for i = 1, #b.t, 2 do
        local ab = ns.Ability(b.t[i])
        if ab then parts[#parts + 1] = (ns.Names(ab)) .. " " .. b.t[i + 1] end
    end
    return table.concat(parts, ", ")
end

-- Where a creature lives: the zone in the client's language and, when Petopia says more, its own text.
-- (A teacher carries a zone key; the wider list a text such as "Jasperlode Mine, Elwynn Forest".)
local function PlaceOf(id)
    local b = ns.BEASTS[id]
    if b then return ns.ZoneName(b.z) end
    local p = ns.PETS and ns.PETS[id]
    if not p or not p.z or p.z == "" then return L.ZONE_UNKNOWN end
    local first = p.z:match("^([^;]+)") or p.z -- "Westfall; Redridge Mountains": the first of them
    local zone = (first:match("([^,]+)$") or first):match("^%s*(.-)%s*$")
    if ns.ZONES[zone] then return ns.ZoneName(zone), p.z ~= zone and p.z or nil end
    return p.z
end

-- "rare", "elite", ... : Petopia's mark, whichever of the two lists the creature is in
local function TagText(id)
    local p = ns.PETS and ns.PETS[id]
    return p and p.tag and (L["TAG_" .. p.tag] or p.tag) or nil
end

-- why a beast cannot be tamed right now, for a row or a tooltip
local function WhyNotText(d, e)
    if d.why == "level" then return L.TAME_AT:format(e.l[1]), L.TAME_FROM:format(e.l[1]) end
    if d.why == "never" then return L.PET_NEVER, L.PET_NEVER end
    if d.why == "side" then
        local p = ns.PETS[d.id]
        local text = p and p.side == "A" and L.PET_SIDE_A or L.PET_SIDE_H
        return text, text
    end
    return nil
end

-- A beast as a pet to keep (Families tab): the colour says whether it can be tamed now,
-- not which ranks it teaches - that is what the other tabs are for.
local function PetRow(r, d)
    Layout(r, "beast")
    local b = ns.Creature(d.id)
    r.icon:SetTexture(ns.FamilyIcon(b.f))
    local c = d.tame and TAMEABLE or NEUTRAL
    r.border:SetVertexColor(c[1], c[2], c[3], 1)
    r.text:SetFontObject("GameFontHighlight")
    local main, second = ns.DisplayName(b)
    local tag = TagText(d.id)
    r.text:SetText((d.tame and main or (GREY .. main .. "|r")) .. "  " .. LevelText(b)
        .. (tag and ("  " .. GOLD .. tag .. "|r") or "")
        .. (second and ("  " .. GREY .. second .. "|r") or ""))
    -- only the distance on the right: a zone name there would squeeze the beast's name and level
    SetRight(r, d.dist and DistanceText(d.dist) or "")
    local parts = {}
    local fam = ns.FAMILIES[b.f]
    if d.role and fam then parts[#parts + 1] = GOLD .. (ns.Names(fam)) .. ", " .. L["ROLE_" .. fam.role] .. "|r" end
    if b.s then parts[#parts + 1] = L.PET_SPEED:format(SpeedText(b.s)) end
    local _, why = WhyNotText(d, b)
    if why then parts[#parts + 1] = (d.why == "level" and RED or GREY) .. why .. "|r" end
    if d.knows and b.t then parts[#parts + 1] = GREY .. L.PET_KNOWS:format(KnowsText(b)) .. "|r" end
    parts[#parts + 1] = GREY .. PlaceOf(d.id) .. "|r" -- last: the first thing to go when the line is full
    r.sub:SetText(table.concat(parts, "  "))
    r.sel:SetShown(state.beast == d.id)
end

PetTooltip = function(owner, d)
    local b = ns.Creature(d.id)
    if not b then return end
    local fam = ns.FAMILIES[b.f]
    local main, second = ns.Names(b)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(main, 1, 1, 1)
    if second and second ~= main then GameTooltip:AddLine(second, 0.55, 0.55, 0.55) end
    if fam then GameTooltip:AddLine((ns.Names(fam)) .. ", " .. L["ROLE_" .. fam.role], 1, 0.82, 0) end
    local tag = TagText(d.id)
    GameTooltip:AddLine(L.LEVEL:format(LevelText(b)) .. (tag and (", " .. tag) or ""), 0.85, 0.85, 0.85)
    local where, more = PlaceOf(d.id)
    if d.dist and d.dist > 0 then where = where .. ", " .. DistanceText(d.dist) end
    GameTooltip:AddLine(where, 0.85, 0.85, 0.85, true)
    if more then GameTooltip:AddLine(more, 0.6, 0.6, 0.6, true) end
    if b.s then GameTooltip:AddLine(L.ATTACK_SPEED:format(SpeedText(b.s)), 0.85, 0.85, 0.85) end
    local knows = b.t and KnowsText(b) or ""
    if knows ~= "" then
        GameTooltip:AddLine(L.PET_KNOWS:format(knows), 0.85, 0.85, 0.85, true)
    else
        GameTooltip:AddLine(L.PET_NO_RANKS, 0.6, 0.6, 0.6, true)
    end
    if d.tame then
        GameTooltip:AddLine(L.PET_CAN_TAME, 0.3, 1, 0.3)
    else
        local why = WhyNotText(d, b)
        if why then GameTooltip:AddLine(why, 1, 0.38, 0.38) end
    end
    if d.tip then GameTooltip:AddLine(d.tip, 0.6, 0.6, 0.6, true) end
    GameTooltip:Show()
end

local function MixedRow(r, d)
    if d.kind == "header" then HeaderRow(r, d)
    elseif d.kind == "group" then GroupRow(r, d)
    elseif d.kind == "ability" then AbilityRow(r, d)
    elseif d.kind == "text" then TextRow(r, d)
    elseif d.kind == "family" then FamilyRow(r, d)
    elseif d.kind == "guide" then GuideRow(r)
    elseif d.kind == "pet" then PetRow(r, d)
    else BeastRow(r, d) end
end

-------------------------------------------------------------------------------
-- data builders
-------------------------------------------------------------------------------
local lastPos -- player position at the last Nearby build: { cont, x, y }

local function ByStatusThenDist(a, b)
    if a.status ~= b.status then return a.status < b.status end
    -- among the beasts worth taming now, the ones that teach more needed ranks at once come first
    if (a.ready or 0) ~= (b.ready or 0) then return (a.ready or 0) > (b.ready or 0) end
    if (a.dist ~= nil) ~= (b.dist ~= nil) then return a.dist ~= nil end
    if a.dist and b.dist and a.dist ~= b.dist then return a.dist < b.dist end
    return ns.BEASTS[a.id].l[1] < ns.BEASTS[b.id].l[1]
end

local function ByDist(a, b)
    if a.dist ~= b.dist then return a.dist < b.dist end
    if a.status ~= b.status then return a.status < b.status end
    return ns.BEASTS[a.id].l[1] < ns.BEASTS[b.id].l[1]
end

local function BuildNearby()
    local q = state.search
    local cont, px, py = ns.PlayerWorldPos()
    lastPos = cont and { cont, px, py } or nil
    local out = {}

    if state.stack then
        out[1] = { kind = "group", stack = true, text = L.GROUP_STACK:format(#state.stack) }
        for _, id in ipairs(state.stack) do
            local b = ns.BEASTS[id]
            if b then
                local best, list = ns.BeastInfo(id)
                out[#out + 1] = { id = id, status = best or S.LATER, list = list,
                    dist = ns.BeastDistance(id, cont, px, py), tip = (#b.c == 0) and L.NO_COORDS or nil }
            end
        end
        return out
    end

    local zoneMap = ns.PlayerZoneMap()
    local here, elsewhere, nowhere = {}, {}, {}
    for id, b in pairs(ns.BEASTS) do
        local best, list
        if q ~= "" then best, list = ns.BeastInfo(id) else best, list = ns.BeastUseful(id) end
        if best then
            local ok = q == ""
            if not ok then
                ok = Matches(q, b.en, b.ru, ns.ZoneName(b.z))
                for _, e in ipairs(list) do
                    local ab = ns.Ability(e.key)
                    ok = ok or (ab and Matches(q, ab.en, ab.ru))
                end
            end
            if ok then
                local dist = ns.BeastDistance(id, cont, px, py)
                local e = { id = id, status = best, list = list, dist = dist, ready = ReadyCount(list),
                    tip = (#b.c == 0) and L.NO_COORDS or nil }
                if zoneMap and ns.ZoneMap(b.z) == zoneMap then
                    here[#here + 1] = e
                elseif dist then
                    elsewhere[#elsewhere + 1] = e
                elseif q ~= "" then
                    nowhere[#nowhere + 1] = e
                end
            end
        end
    end

    if #here > 0 then
        table.sort(here, ByStatusThenDist)
        out[#out + 1] = { kind = "group", text = L.GROUP_HERE:format(ns.ZoneName(ns.BEASTS[here[1].id].z)) }
        for _, e in ipairs(here) do out[#out + 1] = e end
    end

    table.sort(elsewhere, ByDist)
    if q ~= "" then
        table.sort(nowhere, ByStatusThenDist)
        for _, e in ipairs(nowhere) do elsewhere[#elsewhere + 1] = e end
    end
    local limit = q ~= "" and SEARCH_MAX or NEARBY_MAX
    if #elsewhere > 0 then
        out[#out + 1] = { kind = "group", text = L.GROUP_ELSEWHERE }
        for i = 1, math.min(#elsewhere, limit) do out[#out + 1] = elsewhere[i] end
    end
    return out
end

local function AbilityEntry(ab)
    if ab.trainer then
        local r1 = ab.ranks[math.max(1, ns.HaveRank(ab.key))] or ab.ranks[1]
        return { kind = "ability", ab = ab, status = S.LATER, spell = r1 and r1.spell, fallbackTip = ab.desc }
    end
    local p = ns.Plan(ab.key)
    local nextRank, status
    if p.target then
        nextRank, status = p.target, S.READY
    else
        for r = p.known + 1, ab.maxRank do
            if ab.ranks[r] and ns.RankStatus(ab.key, r) == S.SOON then
                nextRank, status = r, S.SOON
                break
            end
        end
        if not status then status = p.known >= ab.maxRank and S.LEARNED or S.LATER end
    end
    -- tooltip: the rank to get next, else the best known one
    local shown = ab.ranks[nextRank or math.max(1, p.known)] or ab.ranks[1]
    return { kind = "ability", ab = ab, next = nextRank, status = status, spell = shown and shown.spell,
        fallbackTip = ab.desc }
end

local function BuildAbilities()
    local q = state.search
    local out, trainer = {}, {}
    for _, ab in ipairs(ns.ABILITIES) do
        if Matches(q, ab.en, ab.ru) then
            if ab.trainer then
                trainer[#trainer + 1] = ab
            elseif ns.AbilityPassesFilter(ab) then
                out[#out + 1] = AbilityEntry(ab)
            end
        end
    end
    if #trainer > 0 then
        out[#out + 1] = { kind = "group", text = L.GROUP_TRAINER }
        for _, ab in ipairs(trainer) do out[#out + 1] = AbilityEntry(ab) end
    end
    return out
end

local function BuildRanks(ab)
    local out = {}
    if not ab then return out end
    local cont, px, py = ns.PlayerWorldPos()
    for rank = 1, ab.maxRank do
        local r = ab.ranks[rank]
        if r then
            local st = ns.RankStatus(ab.key, rank)
            local collapsible = st == S.OBSOLETE or (st == S.LEARNED and not ns.db.showLearned)
            local k = ab.key .. ":" .. rank
            out[#out + 1] = { kind = "header", ab = ab, rank = rank, status = st, collapsible = collapsible,
                expandKey = k, spell = r.spell, fallbackTip = r.desc, onMap = #ns.RankTeachersOnMap(ab.key, rank) > 0,
                tip = not ab.trainer and L.RIGHTCLICK_TOGGLE or nil }
            if not collapsible or state.expanded[k] then
                local beasts = {}
                for _, id in ipairs(r.beasts or {}) do
                    local bst, tame = ns.BeastRankStatus(id, ab.key, rank)
                    beasts[#beasts + 1] = { id = id, status = bst, dist = ns.BeastDistance(id, cont, px, py),
                        list = { { key = ab.key, rank = rank, status = bst, tame = tame } } }
                end
                table.sort(beasts, function(a, b)
                    if (a.dist ~= nil) ~= (b.dist ~= nil) then return a.dist ~= nil end
                    if a.dist and b.dist and a.dist ~= b.dist then return a.dist < b.dist end
                    return ns.BEASTS[a.id].l[1] < ns.BEASTS[b.id].l[1]
                end)
                for _, e in ipairs(beasts) do
                    -- show everything the beast teaches, not just this rank
                    local _, list = ns.BeastInfo(e.id)
                    e.list = list or e.list
                    out[#out + 1] = e
                end
            end
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- Families tab: the families by role, a card per family, and the "how to choose a pet" guide.
-- Roles and diets are Petopia's (Data/Beasts.lua); everything else is counted from the atlas itself.
-------------------------------------------------------------------------------
local measure -- a font string that is never seen: the height of a paragraph at the row's width

local function TextHeight(text)
    if not measure then
        measure = frame:CreateFontString(nil, "BACKGROUND", TEXT_FONT)
        measure:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        measure:SetWidth(TEXT_W)
        measure:SetJustifyH("LEFT")
        measure:SetWordWrap(true)
        measure:SetSpacing(TEXT_SPACING)
        measure:SetAlpha(0)
    end
    measure:SetText(text)
    return math.max(TEXT_MIN_H, math.ceil(measure:GetStringHeight() or 0) + 2 * TEXT_PAD)
end

local function TextEntry(text)
    return { kind = "text", text = text, height = TextHeight(text) }
end

-- Every creature a hunter of the player's faction can tame at some level: the teachers and the rest of
-- Petopia's list. fn(npcId, entry)
local function EachPet(fn)
    for id, b in pairs(ns.BEASTS) do
        if ns.TameState(id, 1000) then fn(id, b) end
    end
    for id, p in pairs(ns.PETS or {}) do
        if not ns.BEASTS[id] and ns.TameState(id, 1000) then fn(id, p) end
    end
end

-- [family] = { ids = { npcId, ... }, count, minLevel, maxLevel, fast, slow } over all those creatures
local function FamilyStats()
    local stats = {}
    EachPet(function(id, b)
        local st = stats[b.f]
        if not st then
            st = { ids = {}, count = 0, minLevel = b.l[1], maxLevel = b.l[2] }
            stats[b.f] = st
        end
        st.count = st.count + 1
        st.ids[st.count] = id
        st.minLevel = math.min(st.minLevel, b.l[1])
        st.maxLevel = math.max(st.maxLevel, b.l[2])
        if b.s then
            st.fast = math.min(st.fast or b.s, b.s)
            st.slow = math.max(st.slow or b.s, b.s)
        end
    end)
    return stats
end

local function SortedFamilies(stats, test)
    local keys = {}
    for key, fam in pairs(ns.FAMILIES) do
        if stats[key] and test(fam, key) then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b) return (ns.Names(ns.FAMILIES[a])) < (ns.Names(ns.FAMILIES[b])) end)
    return keys
end

local function FamilyNames(keys, suffix)
    local parts = {}
    for i, key in ipairs(keys) do
        parts[i] = (ns.Names(ns.FAMILIES[key])) .. (suffix and suffix(ns.FAMILIES[key]) or "")
    end
    return table.concat(parts, ", ")
end

local function BuildFamilies()
    local q = state.search
    local stats = FamilyStats()
    local mainFamily = ns.Ctx().family
    local out = { { kind = "guide" } }
    for _, role in ipairs(ROLE_ORDER) do
        local keys = SortedFamilies(stats, function(fam) return fam.role == role and Matches(q, fam.en, fam.ru) end)
        if #keys > 0 then
            out[#out + 1] = { kind = "group", text = L["ROLE_" .. role] }
            for _, key in ipairs(keys) do
                out[#out + 1] = { kind = "family", key = key, stats = stats[key], main = key == mainFamily }
            end
        end
    end
    return out
end

local function PetEntry(id, playerLevel, cont, px, py)
    local b = ns.BEASTS[id] -- only a teacher has coordinates, and so a distance
    local tame, why = ns.TameState(id, playerLevel)
    return { kind = "pet", id = id, tame = tame, why = why, dist = b and ns.BeastDistance(id, cont, px, py) or nil,
        tip = (b and #b.c == 0) and L.NO_COORDS or nil }
end

-- can be tamed now first (nearest first, then the higher level), then the rest by level
local function ByTameThenDist(a, b)
    if a.tame ~= b.tame then return a.tame end
    local la, lb = ns.Creature(a.id).l, ns.Creature(b.id).l
    if a.tame then
        if (a.dist ~= nil) ~= (b.dist ~= nil) then return a.dist ~= nil end
        if a.dist and b.dist and a.dist ~= b.dist then return a.dist < b.dist end
        if la[2] ~= lb[2] then return la[2] > lb[2] end
    elseif la[1] ~= lb[1] then
        return la[1] < lb[1]
    end
    return a.id < b.id
end

local function BuildFamilyCard(key, st)
    local fam = ns.FAMILIES[key]
    local ctx = ns.Ctx()
    local cont, px, py = ns.PlayerWorldPos()
    local out = { { kind = "group", text = ns.DisplayName(fam, true) } }

    local lines = {
        GOLD .. L.FAM_ROLE .. "|r " .. L["ROLE_" .. fam.role] .. ". " .. L["ROLE_" .. fam.role .. "_DESC"],
        GOLD .. L.FAM_DIET .. "|r " .. DietText(fam) .. ".",
    }
    if st.fast then
        local speed = st.fast == st.slow and L.FAM_SPEED_ONE:format(SpeedText(st.fast))
            or L.FAM_SPEED_RANGE:format(SpeedText(st.fast), SpeedText(st.slow))
        lines[#lines + 1] = GOLD .. L.FAM_SPEED .. "|r " .. speed
    end
    if ctx.family == key then lines[#lines + 1] = "|cff4dff4d" .. L.FAM_YOURS .. "|r" end
    out[#out + 1] = TextEntry(table.concat(lines, "\n"))

    -- abilities learned from wild beasts; the family's own one first
    local own, shared = {}, {}
    for _, ab in ipairs(ns.ABILITIES) do
        if not ab.trainer and ns.FamilyCanLearn(ab, key) then
            local e = AbilityEntry(ab)
            e.jump = true -- a click opens it on the Abilities tab
            -- exactly one family and not the "*" wildcard (Cower is open to all)
            if #ab.families == 1 and ab.families[1] == key then
                e.right = GOLD .. L.FAM_OWN .. "|r"
                own[#own + 1] = e
            else
                shared[#shared + 1] = e
            end
        end
    end
    out[#out + 1] = { kind = "group", text = L.FAM_ABILITIES }
    for _, e in ipairs(own) do out[#out + 1] = e end
    for _, e in ipairs(shared) do out[#out + 1] = e end
    out[#out + 1] = TextEntry(GREY .. L.FAM_TRAINER_NOTE .. "|r")

    local pets = {}
    for _, id in ipairs(st.ids) do
        if not state.rareOnly or TagText(id) then
            local e = PetEntry(id, ctx.playerLevel, cont, px, py)
            e.knows = true
            pets[#pets + 1] = e
        end
    end
    table.sort(pets, ByTameThenDist)
    out[#out + 1] = { kind = "group", text = (state.rareOnly and L.FAM_BEASTS_RARE or L.FAM_BEASTS):format(#pets) }
    out[#out + 1] = TextEntry(GREY .. (#pets > 0 and L.FAM_BEASTS_NOTE or L.FAM_NONE_RARE) .. "|r")
    for _, e in ipairs(pets) do out[#out + 1] = e end
    return out
end

-- The search box on the Families tab looks through every pet: name, family, place.
local function BuildPetSearch(q)
    local ctx = ns.Ctx()
    local cont, px, py = ns.PlayerWorldPos()
    local found = {}
    EachPet(function(id, b)
        if not state.rareOnly or TagText(id) then
            local fam = ns.FAMILIES[b.f]
            local place, more = PlaceOf(id)
            if Matches(q, b.en, b.ru, fam and fam.en, fam and fam.ru, place, more) then
                local e = PetEntry(id, ctx.playerLevel, cont, px, py)
                e.role, e.knows = true, true
                found[#found + 1] = e
            end
        end
    end)
    table.sort(found, ByTameThenDist)
    local out = {}
    if #found == 0 then
        out[1] = { kind = "group", text = L.PET_FOUND:format(0) }
        out[2] = TextEntry(GREY .. L.PET_NOT_FOUND .. "|r")
        return out
    end
    local shown = math.min(#found, PET_SEARCH_MAX)
    local title = shown < #found and L.PET_FOUND_MORE:format(#found, shown) or L.PET_FOUND:format(#found)
    if q == "" then title = L.FAM_BEASTS_RARE:format(#found) end -- no query: the rare filter over every family
    out[1] = { kind = "group", text = title }
    for i = 1, shown do out[#out + 1] = found[i] end
    return out
end

local function BuildGuide()
    local stats = FamilyStats()
    local level = ns.Ctx().playerLevel
    local cont, px, py = ns.PlayerWorldPos()
    lastPos = cont and { cont, px, py } or nil
    local out = {}
    local function Head(text) out[#out + 1] = { kind = "group", text = text } end
    local function Text(text) out[#out + 1] = TextEntry(text) end

    Head(L.GUIDE_TITLE)
    Text(L.GUIDE_INTRO)

    Head(L.GUIDE_H_ROLE)
    local lines = { L.GUIDE_ROLE }
    for _, role in ipairs(ROLE_ORDER) do
        local keys = SortedFamilies(stats, function(fam) return fam.role == role end)
        lines[#lines + 1] = GOLD .. L["ROLE_" .. role] .. ".|r " .. L["ROLE_" .. role .. "_DESC"] .. " " .. FamilyNames(keys) .. "."
    end
    Text(table.concat(lines, "\n"))

    Head(L.GUIDE_H_FOOD)
    lines = { L.GUIDE_FOOD }
    local most = 0
    for key, fam in pairs(ns.FAMILIES) do
        if stats[key] then most = math.max(most, #fam.diet) end
    end
    local wide = SortedFamilies(stats, function(fam) return #fam.diet == most end)
    local narrow = SortedFamilies(stats, function(fam) return #fam.diet == 1 end)
    if #wide > 0 and most > 1 then lines[#lines + 1] = GOLD .. L.GUIDE_FOOD_WIDE .. "|r " .. FamilyNames(wide) .. "." end
    if #narrow > 0 then
        lines[#lines + 1] = GOLD .. L.GUIDE_FOOD_ONE .. "|r "
            .. FamilyNames(narrow, function(fam) return " (" .. DietText(fam) .. ")" end) .. "."
    end
    Text(table.concat(lines, "\n"))

    Head(L.GUIDE_H_ABIL)
    Text(L.GUIDE_ABIL)

    Head(L.GUIDE_H_SPEED)
    Text(L.GUIDE_SPEED)
    local fastest = {}
    EachPet(function(id, b)
        if b.s then fastest[#fastest + 1] = id end
    end)
    table.sort(fastest, function(a, b)
        local ba, bb = ns.Creature(a), ns.Creature(b)
        if ba.s ~= bb.s then return ba.s < bb.s end
        if ba.l[1] ~= bb.l[1] then return ba.l[1] < bb.l[1] end
        return a < b
    end)
    local allTame = true
    for i = 1, math.min(#fastest, FASTEST_MAX) do
        local e = PetEntry(fastest[i], level, cont, px, py)
        e.role = true
        allTame = allTame and e.tame
        out[#out + 1] = e
    end
    -- ... and the fastest of those the hunter can tame already, unless that is the same list.
    -- Only beasts quicker than the usual 2.0; among equals the higher level first (less to catch up).
    if level >= 10 and not allTame then
        local now = {}
        for _, id in ipairs(fastest) do
            local b = ns.Creature(id)
            if b.s < USUAL_SPEED and ns.TameState(id, level) then now[#now + 1] = id end
        end
        table.sort(now, function(a, b)
            local ba, bb = ns.Creature(a), ns.Creature(b)
            if ba.s ~= bb.s then return ba.s < bb.s end
            if ba.l[2] ~= bb.l[2] then return ba.l[2] > bb.l[2] end
            return a < b
        end)
        if #now > 0 then
            Text(L.GUIDE_FASTEST_NOW:format(level))
            for i = 1, math.min(#now, FASTEST_MAX) do
                local e = PetEntry(now[i], level, cont, px, py)
                e.role = true
                out[#out + 1] = e
            end
        end
    end

    Head(L.GUIDE_H_LEVEL)
    Text(L.GUIDE_LEVEL)

    -- beasts worth taming right now: not above the hunter, not far below, nearest first, a few per role
    Head(L.GUIDE_H_NEARBY)
    local picked = 0
    if level >= 10 then
        local near = {}
        for id, b in pairs(ns.BEASTS) do
            if b.l[1] <= level and b.l[2] >= level - CLOSE_LEVELS then
                local e = PetEntry(id, level, cont, px, py)
                if e.dist then near[#near + 1] = e end
            end
        end
        table.sort(near, function(a, b)
            if a.dist ~= b.dist then return a.dist < b.dist end
            return a.id < b.id
        end)
        local rows = {}
        for _, role in ipairs(ROLE_ORDER) do
            local n, seen = 0, {}
            for _, e in ipairs(near) do
                local f = ns.BEASTS[e.id].f
                local fam = ns.FAMILIES[f]
                if n < PER_ROLE and fam and fam.role == role and not seen[f] then
                    seen[f] = true
                    n = n + 1
                    e.role = true
                    rows[#rows + 1] = e
                end
            end
        end
        picked = #rows
        if picked > 0 then
            Text(L.GUIDE_NEARBY:format(level, CLOSE_LEVELS))
            for _, e in ipairs(rows) do out[#out + 1] = e end
        end
    end
    if picked == 0 then Text(level < 10 and L.GUIDE_NEARBY_L10 or L.GUIDE_NEARBY_NONE) end

    Text(GREY .. L.GUIDE_SOURCE .. "|r")
    return out
end

local function BuildFamilyPane()
    if state.search ~= "" then return BuildPetSearch(state.search) end
    local key = state.family
    local st = key and ns.FAMILIES[key] and FamilyStats()[key]
    if st then return BuildFamilyCard(key, st) end
    state.family = nil -- nothing chosen, or a family the atlas has no beasts of
    -- no family chosen and "only rare" ticked: the rare beasts of every family
    if state.rareOnly then return BuildPetSearch("") end
    return BuildGuide()
end

-------------------------------------------------------------------------------
-- detail pane
-------------------------------------------------------------------------------
local detail
local function UpdateDetail()
    if not detail then return end
    local id = state.beast
    local b = id and ns.BEASTS[id]
    local e = b or (id and ns.PETS and ns.PETS[id]) or nil
    detail.content:SetShown(e ~= nil)
    detail.empty:SetShown(e == nil)
    if not e then return end
    local main, second = ns.Names(e)
    detail.name:SetText(main)
    detail.name2:SetText(second ~= main and second or "")
    local fam = ns.FAMILIES[e.f]
    local tag = TagText(id)
    detail.info:SetText((fam and (ns.DisplayName(fam, true)) or e.f) .. ",  " .. L.LEVEL:format(LevelText(e))
        .. (tag and (",  " .. GOLD .. tag .. "|r") or ""))
    if not b then
        -- a pet of the wider list: no coordinates, no ranks to learn from it
        local place, more = PlaceOf(id)
        detail.zone:SetText(place .. (more and ("  " .. GREY .. "(" .. more .. ")|r") or ""))
        detail.speed:SetText(e.s and L.ATTACK_SPEED:format(SpeedText(e.s)) or "")
        detail.stable.stableId = nil
        detail.stable:Hide()
        detail.teachTitle:ClearAllPoints()
        detail.teachTitle:SetPoint("TOPLEFT", detail.speed, "BOTTOMLEFT", 0, -12)
        local tame, why = ns.TameState(id, ns.Ctx().playerLevel)
        local state1 = tame and ("|cff4dff4d" .. L.PET_CAN_TAME .. "|r")
            or (RED .. (WhyNotText({ id = id, why = why }, e) or L.PET_NEVER) .. "|r")
        detail.teaches:SetText(GREY .. L.PET_NO_RANKS .. "|r\n" .. state1)
        detail.mapBtn:SetEnabled(false)
        detail.wpBtn:SetEnabled(false)
        if detail.model.npcId ~= id then SetModelBeast(detail.model, id) end
        return
    end
    local zone = ns.ZoneName(b.z)
    if #b.c == 0 then zone = zone .. "  " .. GREY .. "(" .. L.NO_COORDS .. ")|r" end
    detail.zone:SetText(zone)
    local extra = {}
    if b.s then extra[#extra + 1] = L.ATTACK_SPEED:format(SpeedText(b.s)) end
    if b.o then extra[#extra + 1] = GREY .. L.OBSERVED_TAG .. "|r" end
    detail.speed:SetText(table.concat(extra, "   "))
    local stableId, stableSpot, stableDist = ns.NearestStableToBeast(id)
    local stable = detail.stable
    stable.stableId, stable.spot, stable.dist = stableId, stableSpot, stableDist
    stable:SetShown(stableId ~= nil)
    if stableId then
        local st = ns.STABLES[stableId]
        -- the zone only when it is not the beast's own: the line has to stay short
        local who = (ns.Names(st)) .. (st.z ~= b.z and (", " .. ns.ZoneName(st.z)) or "")
        stable.text:SetText(GOLD .. L.STABLE_NEAR_HABITAT:format("|r" .. who))
        local parts = {}
        local fromYou = ns.StableDistance(stableId, stableSpot)
        if fromYou then parts[#parts + 1] = L.STABLE_FROM_YOU:format(DistanceText(math.floor(fromYou + 0.5))) end
        parts[#parts + 1] = stableDist < 1 and L.STABLE_AT_HABITAT
            or L.STABLE_TO_HABITAT:format(DistanceText(math.floor(stableDist + 0.5)))
        stable.sub:SetText(table.concat(parts, ", "))
    end
    detail.teachTitle:ClearAllPoints()
    detail.teachTitle:SetPoint("TOPLEFT", stableId and stable or detail.speed, "BOTTOMLEFT", 0, -12)
    -- teaches (all ranks, ignoring filters)
    local lines = {}
    for i = 1, #b.t, 2 do
        local ab = ns.Ability(b.t[i])
        local rank = b.t[i + 1]
        local r = ab and ab.ranks[rank]
        if r then
            local st, tame = ns.BeastRankStatus(id, ab.key, rank)
            lines[#lines + 1] = ns.StatusHex(st) .. ns.DisplayName(ab, true) .. " " .. rank .. "|r\n   |cffbbbbbb"
                .. L.PET_LEVEL:format(r.lvl) .. ", " .. CostText(r.tp) .. "|r   "
                .. ns.StatusHex(st) .. ns.StatusNote(st, ab.key, rank, tame) .. "|r"
        end
    end
    detail.teaches:SetText(table.concat(lines, "\n"))
    local onMap = #b.c > 0 and ns.ZoneMap(b.z) ~= nil
    detail.mapBtn:SetEnabled(onMap)
    detail.wpBtn:SetEnabled(onMap)
    if detail.model.npcId ~= id then SetModelBeast(detail.model, id) end
end

local function CreateDetail(parent)
    local d = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
    d:SetWidth(DETAIL_W)
    d.empty = d:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    d.empty:SetPoint("CENTER")
    d.empty:SetWidth(DETAIL_W - 40)
    d.empty:SetText(L.PICK_BEAST)

    local c = CreateFrame("Frame", nil, d)
    c:SetAllPoints()
    d.content = c
    local shade = c:CreateTexture(nil, "BACKGROUND")
    shade:SetPoint("TOPLEFT", 4, -4)
    shade:SetPoint("TOPRIGHT", -4, -4)
    shade:SetHeight(196)
    shade:SetColorTexture(0, 0, 0, 0.35)
    d.model = CreateModel(c, DETAIL_W - 8, 196)
    d.model:SetPoint("TOP", 0, -4)
    d.name = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    d.name:SetPoint("TOPLEFT", d.model, "BOTTOMLEFT", 8, -8)
    d.name:SetWidth(DETAIL_W - 24)
    d.name:SetWordWrap(false)
    d.name:SetJustifyH("LEFT")
    d.name2 = c:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    d.name2:SetPoint("TOPLEFT", d.name, "BOTTOMLEFT", 0, -2)
    d.info = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.info:SetPoint("TOPLEFT", d.name2, "BOTTOMLEFT", 0, -8)
    d.info:SetWidth(DETAIL_W - 24)
    d.info:SetJustifyH("LEFT")
    d.zone = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.zone:SetPoint("TOPLEFT", d.info, "BOTTOMLEFT", 0, -3)
    d.zone:SetWidth(DETAIL_W - 24)
    d.zone:SetJustifyH("LEFT")
    d.speed = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.speed:SetPoint("TOPLEFT", d.zone, "BOTTOMLEFT", 0, -3)
    -- the stable master nearest to the beast's habitat: a click sets a waypoint
    -- two lines: who and where, then how far (from the hunter, and from there to the beast)
    d.stable = CreateFrame("Button", nil, c)
    d.stable:SetSize(DETAIL_W - 24, 28)
    d.stable:SetPoint("TOPLEFT", d.speed, "BOTTOMLEFT", 0, -4)
    d.stable.text = d.stable:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.stable.text:SetPoint("TOPLEFT", 0, -1)
    d.stable.text:SetWidth(DETAIL_W - 24)
    d.stable.text:SetJustifyH("LEFT")
    d.stable.text:SetWordWrap(false)
    d.stable.sub = d.stable:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.stable.sub:SetPoint("BOTTOMLEFT", 0, 1)
    d.stable.sub:SetWidth(DETAIL_W - 24)
    d.stable.sub:SetJustifyH("LEFT")
    d.stable.sub:SetWordWrap(false)
    local stableHl = d.stable:CreateTexture(nil, "HIGHLIGHT")
    stableHl:SetAllPoints()
    stableHl:SetColorTexture(1, 1, 1, 0.08)
    d.stable:SetScript("OnClick", function(self)
        if self.stableId then ns.SetStableWaypoint(self.stableId, self.spot) end
    end)
    d.stable:SetScript("OnEnter", function(self)
        if not self.stableId then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.STABLE_NEAR_HABITAT:format(ns.StableText(self.stableId)), 1, 1, 1, true)
        GameTooltip:AddLine(self.sub:GetText(), 0.85, 0.85, 0.85, true)
        GameTooltip:AddLine(L.STABLE_STRAIGHT, 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    d.stable:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local teachTitle = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    teachTitle:SetText(L.TEACHES .. ":")
    d.teachTitle = teachTitle -- anchored in UpdateDetail: under the stable line when there is one
    d.teaches = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.teaches:SetPoint("TOPLEFT", teachTitle, "BOTTOMLEFT", 0, -4)
    d.teaches:SetWidth(DETAIL_W - 24)
    d.teaches:SetJustifyH("LEFT")
    d.teaches:SetSpacing(3)
    d.mapBtn = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    d.mapBtn:SetSize(138, 22)
    d.mapBtn:SetPoint("BOTTOMLEFT", 8, 8)
    d.mapBtn:SetText(L.SHOW_ON_MAP)
    d.mapBtn:SetScript("OnClick", function() if state.beast then ns.OpenMapFor(state.beast) end end)
    d.wpBtn = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    d.wpBtn:SetSize(138, 22)
    d.wpBtn:SetPoint("BOTTOMRIGHT", -8, 8)
    d.wpBtn:SetText(L.WAYPOINT)
    d.wpBtn:SetScript("OnClick", function()
        if not state.beast then return end
        local cont, px, py = ns.PlayerWorldPos()
        local _, idx = ns.BeastDistance(state.beast, cont, px, py)
        ns.SetWaypoint(state.beast, idx)
    end)
    return d
end

-------------------------------------------------------------------------------
-- main window
-------------------------------------------------------------------------------
local nearbyList, abilityList, rankList, familyList, familyPane, settings
local minimapButton
local checks = {} -- { cb = CheckButton, get = function() -> bool }

local function SyncControls()
    for _, c in ipairs(checks) do c.cb:SetChecked(c.get()) end
    if frame then
        frame.look:SetText(L.LOOKAHEAD:format(ns.db.lookahead or 0))
        if settings then settings.scaleText:SetText(L.OPT_SCALE:format(math.floor((ns.db.scale or 1) * 100 + 0.5))) end
    end
end

local function UpdateHeader()
    if not frame then return end
    local ctx = ns.Ctx()
    local main = ctx.main
    if main then
        local fam = main.family and ns.FAMILIES[main.family]
        local famName = fam and (ns.Names(fam)) or main.family or "?"
        frame.pet:SetText(L.PET_LINE:format(main.name or "?", famName, main.level or ctx.petLevel))
    else
        frame.pet:SetText(L.NO_PET:format(ctx.playerLevel))
    end

    local isMain = ns.ActivePetIsMain()
    local petName = UnitExists("pet") and not isMain and UnitName("pet")
    if petName and not ns.IsSecret(petName) then
        frame.makeMain:SetText(L.MAKE_MAIN:format(petName))
        frame.makeMain:SetWidth(frame.makeMain:GetFontString():GetStringWidth() + 24)
        frame.makeMain:Show()
    else
        frame.makeMain:Hide()
    end

    local line2 = ""
    local free, total
    if isMain then free, total = ns.TrainingPoints() end
    if free then
        line2 = L.TP_LINE:format(free, total)
        local parts = {}
        for _, e in ipairs(ns.PetTrainable() or {}) do
            parts[#parts + 1] = (ns.Names(e.ab)) .. " " .. e.rank .. " (" .. CostText(e.tp) .. ")"
        end
        if #parts > 0 then
            line2 = line2 .. "   |cff4dff4d" .. L.PETCAN:format(table.concat(parts, ", ")) .. "|r"
        end
    end
    frame.petcan:SetText(line2)
    frame.look:SetText(L.LOOKAHEAD:format(ns.db.lookahead or 0))
end

local TAB_INDEX = { nearby = 1, abilities = 2, families = 3, settings = 4 }

local function Refresh(keepScroll)
    if not frame or not frame:IsShown() then return end
    UpdateHeader()
    local tab = state.tab
    PanelTemplates_SetTab(frame, TAB_INDEX[tab])
    nearbyList:SetShown(tab == "nearby")
    abilityList:SetShown(tab == "abilities")
    rankList:SetShown(tab == "abilities")
    familyList:SetShown(tab == "families")
    familyPane:SetShown(tab == "families")
    frame.divider:SetShown(tab == "abilities" or tab == "families")
    settings:SetShown(tab == "settings")
    detail:SetShown(tab ~= "settings")
    -- the rank filters mean nothing for families and settings
    for _, control in ipairs(frame.filters) do control:SetShown(tab == "nearby" or tab == "abilities") end
    frame.rareOnly:SetShown(tab == "families")
    frame.empty:Hide()
    if tab == "nearby" then
        local data = BuildNearby()
        nearbyList:SetData(data, keepScroll)
        frame.empty:SetShown(#data == 0)
    elseif tab == "abilities" then
        local abilities = BuildAbilities()
        if not state.ability or not ns.Ability(state.ability) then
            local first
            for _, d in ipairs(abilities) do
                if d.kind == "ability" then first = d.ab.key; break end
            end
            state.ability = first
        end
        abilityList:SetData(abilities, keepScroll)
        rankList:SetData(BuildRanks(ns.Ability(state.ability)), keepScroll)
    elseif tab == "families" then
        familyList:SetData(BuildFamilies(), keepScroll)
        familyPane:SetData(BuildFamilyPane(), keepScroll)
    else
        SyncControls()
    end
    UpdateDetail()
end
ns.RefreshWindow = Refresh

local function SelectBeast(d)
    if not d.id then return end -- headers, groups, paragraphs
    state.beast = d.id
    nearbyList:Refresh()
    rankList:Refresh()
    familyPane:Refresh()
    UpdateDetail()
end

local function MakeTab(index, text, key)
    local t = CreateFrame("Button", "BeastAtlasFrameTab" .. index, frame, "PanelTabButtonTemplate")
    t:SetID(index)
    t:SetText(text)
    if index == 1 then t:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 11, 2) end
    t:SetScript("OnClick", function()
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
        state.tab = key
        state.stack = nil
        Refresh()
    end)
    return t
end

-- Checkbox with a label; get() reads the current state, set(checked) applies it.
local function MakeCheck(parent, label, x, y, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", x, y)
    local t = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    t:SetText(label)
    cb:SetChecked(get())
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    checks[#checks + 1] = { cb = cb, get = get }
    return cb, t
end

local function OptionCheck(parent, label, x, y, key)
    return MakeCheck(parent, label, x, y,
        function() return ns.db[key] and true or false end,
        function(v) ns.SetOption(key, v) end)
end

local function StepButton(parent, text, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(22, 20)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function CreateSettings(parent)
    local p = CreateFrame("Frame", nil, parent)
    local y, STEP = -14, 28
    local function NextY() local v = y; y = y - STEP; return v end

    OptionCheck(p, L.OPT_MAP_PINS, 14, NextY(), "mapPins")
    OptionCheck(p, L.OPT_AREAS, 14, NextY(), "areasAlways")
    OptionCheck(p, L.OPT_TRAINERS, 14, NextY(), "trainers")
    OptionCheck(p, L.OPT_STABLES, 14, NextY(), "stables")
    OptionCheck(p, L.OPT_NOTIFY, 14, NextY(), "notify")
    OptionCheck(p, L.OPT_HELPER, 14, NextY(), "helper")
    MakeCheck(p, L.OPT_BOTH_NAMES, 14, NextY(),
        function() return ns.db.names == "both" end,
        function(v) ns.SetOption("names", v and "both" or "local") end)
    MakeCheck(p, L.OPT_MINIMAP, 14, NextY(),
        function() return not ns.db.minimap.hide end,
        function(v)
            ns.db.minimap.hide = not v
            if minimapButton then minimapButton:SetShown(v) end
        end)

    local function Scale(delta)
        local v = math.floor(((ns.db.scale or 1) + delta) * 100 + 0.5) / 100
        v = math.max(0.7, math.min(1.3, v))
        if v ~= ns.db.scale then ns.SetOption("scale", v) end
    end
    local minus = StepButton(p, "-", function() Scale(-0.05) end)
    minus:SetPoint("TOPLEFT", 16, NextY() - 2)
    local plus = StepButton(p, "+", function() Scale(0.05) end)
    plus:SetPoint("LEFT", minus, "RIGHT", 2, 0)
    p.scaleText = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.scaleText:SetPoint("LEFT", plus, "RIGHT", 8, 0)

    local reset = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    reset:SetSize(300, 22)
    reset:SetPoint("TOPLEFT", 16, NextY() - 8)
    reset:SetText(L.OPT_RESET_KNOWN)
    reset:SetScript("OnClick", function() if IsShiftKeyDown() then ns.ResetKnown() end end)

    local help = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", 18, NextY() - 18)
    help:SetWidth(500)
    help:SetJustifyH("LEFT")
    help:SetSpacing(3)
    help:SetText(L.SETTINGS_HELP)

    local data = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    data:SetPoint("BOTTOMLEFT", 18, 12)
    data:SetText(L.DATA_INFO:format(ns.DATA_VERSION.game, ns.DATA_VERSION.built))

    p:SetScript("OnShow", SyncControls)
    return p
end

local function CreateWindow()
    frame = CreateFrame("Frame", "BeastAtlasFrame", UIParent, "ButtonFrameTemplate")
    frame:SetSize(W, H)
    frame:SetScale(ns.db.scale or 1)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    if frame.SetTitle then frame:SetTitle(L.TITLE) end
    if frame.SetPortraitToAsset then frame:SetPortraitToAsset(ICON) end
    local p = ns.db.window
    if p.point then frame:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y) else frame:SetPoint("CENTER") end
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ns.db.window = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    tinsert(UISpecialFrames, "BeastAtlasFrame")

    -- the template's inset becomes the content area below our header
    local inset = frame.Inset
    inset:ClearAllPoints()
    inset:SetPoint("TOPLEFT", 4, -ATTIC)
    inset:SetPoint("BOTTOMRIGHT", -6, 26)

    -- header: main pet, training points, filters; search on the right
    frame.pet = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.pet:SetPoint("TOPLEFT", 66, -30)
    frame.makeMain = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.makeMain:SetSize(140, 20)
    frame.makeMain:SetPoint("LEFT", frame.pet, "RIGHT", 10, 0)
    frame.makeMain:SetScript("OnClick", function() ns.SetMainPet() end)
    frame.makeMain:Hide()
    frame.petcan = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.petcan:SetPoint("TOPLEFT", 66, -48)
    frame.petcan:SetWidth(W - 66 - 250)
    frame.petcan:SetJustifyH("LEFT")
    frame.petcan:SetWordWrap(false)

    local petOnly, petOnlyLabel = OptionCheck(frame, L.FILTER_PET, 62, -61, "petOnly")
    local learned = OptionCheck(frame, L.FILTER_LEARNED, 62, -61, "showLearned")
    learned:ClearAllPoints()
    learned:SetPoint("LEFT", petOnlyLabel, "RIGHT", 18, 0)
    local minus = StepButton(frame, "-", function()
        ns.SetOption("lookahead", math.max(0, (ns.db.lookahead or 0) - 1))
    end)
    minus:SetPoint("TOPRIGHT", -150, -63)
    local plus = StepButton(frame, "+", function()
        ns.SetOption("lookahead", math.min(60, (ns.db.lookahead or 0) + 1))
    end)
    plus:SetPoint("LEFT", minus, "RIGHT", 2, 0)
    frame.look = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.look:SetPoint("LEFT", plus, "RIGHT", 8, 0)
    frame.filters = { petOnly, learned, minus, plus, frame.look }
    -- Families tab: only the beasts Petopia marks as rare, elite or otherwise special
    frame.rareOnly = MakeCheck(frame, L.FILTER_RARE, 62, -61,
        function() return state.rareOnly end,
        function(v)
            state.rareOnly = v
            ns.RefreshWindow()
        end)
    frame.rareOnly:Hide()

    local search = CreateFrame("EditBox", "BeastAtlasSearch", frame, "SearchBoxTemplate")
    search:SetSize(210, 20)
    search:SetPoint("TOPRIGHT", -14, -32)
    search:SetAutoFocus(false)
    if search.Instructions then search.Instructions:SetText(L.SEARCH) end
    local pendingSearch, lastText = nil, ""
    search:HookScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        if text == lastText then return end
        lastText = text
        state.stack = nil
        if pendingSearch then pendingSearch:Cancel() end
        pendingSearch = C_Timer.NewTimer(0.2, function()
            state.search = Lower(text:match("^[ \t]*(.-)[ \t]*$"))
            Refresh()
        end)
    end)

    -- content: lists on the left, the beast on the right
    detail = CreateDetail(frame)
    detail:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -3, -3)
    detail:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -3, 3)

    local function OnNearbyClick(d)
        if d.kind == "group" then
            if d.stack then
                state.stack = nil
                Refresh()
            end
            return
        end
        SelectBeast(d)
    end
    nearbyList = CreateList(frame, MixedRow, OnNearbyClick)
    nearbyList:SetPoint("TOPLEFT", inset, "TOPLEFT", 3, -3)
    nearbyList:SetPoint("BOTTOMRIGHT", detail, "BOTTOMLEFT", -2, 0)

    abilityList = CreateList(frame, MixedRow, function(d)
        if d.kind ~= "ability" then return end
        state.ability = d.ab.key
        abilityList:Refresh()
        rankList:SetData(BuildRanks(d.ab))
    end)
    abilityList:SetPoint("TOPLEFT", inset, "TOPLEFT", 3, -3)
    abilityList:SetPoint("BOTTOMLEFT", inset, "BOTTOMLEFT", 3, 3)
    abilityList:SetWidth(ABILITY_W)

    rankList = CreateList(frame, MixedRow, function(d, button)
        if d.kind == "header" then
            if button == "RightButton" then
                if not d.ab.trainer then ns.SetKnown(d.ab.key, d.rank) end
            elseif d.collapsible then
                state.expanded[d.expandKey] = not state.expanded[d.expandKey] or nil
                rankList:SetData(BuildRanks(d.ab), true)
            end
            return
        end
        SelectBeast(d)
    end)
    rankList:SetPoint("TOPLEFT", abilityList, "TOPRIGHT", 2, 0)
    rankList:SetPoint("BOTTOMRIGHT", detail, "BOTTOMLEFT", -2, 0)

    -- families: the list in the place of the abilities, the card or the guide in the place of the ranks
    familyList = CreateList(frame, MixedRow, function(d)
        if d.kind == "family" then
            state.family = d.key
        elseif d.kind == "guide" then
            state.family = nil
            state.rareOnly = false
        else
            return
        end
        if state.search ~= "" then
            state.search = ""
            BeastAtlasSearch:SetText("")
            Refresh() -- the list on the left was narrowed by the search too
            return
        end
        SyncControls()
        familyList:Refresh()
        familyPane:SetData(BuildFamilyPane())
    end)
    familyList:SetPoint("TOPLEFT", inset, "TOPLEFT", 3, -3)
    familyList:SetPoint("BOTTOMLEFT", inset, "BOTTOMLEFT", 3, 3)
    familyList:SetWidth(ABILITY_W)

    familyPane = CreateList(frame, MixedRow, function(d)
        if d.kind == "ability" then
            -- an ability of the family: show its ranks and teachers
            state.tab = "abilities"
            state.ability = d.ab.key
            Refresh()
            return
        end
        SelectBeast(d)
    end)
    familyPane:SetPoint("TOPLEFT", familyList, "TOPRIGHT", 2, 0)
    familyPane:SetPoint("BOTTOMRIGHT", detail, "BOTTOMLEFT", -2, 0)

    frame.divider = frame:CreateTexture(nil, "ARTWORK")
    frame.divider:SetColorTexture(1, 1, 1, 0.08)
    frame.divider:SetWidth(1)
    frame.divider:SetPoint("TOPLEFT", abilityList, "TOPRIGHT", 0, -4)
    frame.divider:SetPoint("BOTTOMLEFT", abilityList, "BOTTOMRIGHT", 0, 4)

    settings = CreateSettings(frame)
    settings:SetPoint("TOPLEFT", inset, "TOPLEFT", 3, -3)
    settings:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -3, 3)
    settings:Hide()

    frame.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    frame.empty:SetPoint("CENTER", nearbyList, "CENTER")
    frame.empty:SetText(L.NEARBY_EMPTY)

    -- tabs under the frame, like the character window
    frame.tabNearby = MakeTab(1, L.TAB_NEARBY, "nearby")
    frame.tabAbilities = MakeTab(2, L.TAB_ABILITIES, "abilities")
    frame.tabFamilies = MakeTab(3, L.TAB_FAMILIES, "families")
    frame.tabSettings = MakeTab(4, L.TAB_SETTINGS, "settings")
    PanelTemplates_SetNumTabs(frame, 4)
    PanelTemplates_SetTab(frame, 1)

    -- distances change as you move: rebuild the nearby list only after a real move
    frame:SetScript("OnShow", function(self)
        Refresh()
        self.ticker = C_Timer.NewTicker(5, function()
            local guide = state.tab == "families" and state.family == nil and state.search == "" and not state.rareOnly
            if not (state.tab == "nearby" or guide) or search:HasFocus() then return end
            local cont, px, py = ns.PlayerWorldPos()
            if not cont then return end
            if not lastPos or lastPos[1] ~= cont
                or (px - lastPos[2]) ^ 2 + (py - lastPos[3]) ^ 2 > MOVE_YARDS * MOVE_YARDS then
                Refresh(true)
            end
        end)
    end)
    frame:SetScript("OnHide", function(self)
        if self.ticker then self.ticker:Cancel(); self.ticker = nil end
    end)
    -- spell descriptions load asynchronously: redraw the visible rows once they arrive
    frame:RegisterEvent("SPELL_TEXT_UPDATE")
    frame:SetScript("OnEvent", function(self)
        if not descPending or self.descQueued or not self:IsShown() then return end
        self.descQueued = true
        C_Timer.After(0.3, function()
            self.descQueued, descPending = nil, false
            if self:IsShown() and state.tab == "abilities" then rankList:Refresh() end
        end)
    end)
    frame:Hide()
end

function ns.ToggleWindow()
    if not frame then CreateWindow() end
    frame:SetShown(not frame:IsShown())
end

function ns.ShowBeast(id)
    if not frame then CreateWindow() end
    state.beast = id
    if state.tab == "settings" then state.tab = "nearby" end
    if not frame:IsShown() then frame:Show() else Refresh(true) end
end

function ns.ShowStack(ids)
    if not ids or #ids == 0 then return end
    if not frame then CreateWindow() end
    local copy = {}
    for i, id in ipairs(ids) do copy[i] = id end
    state.stack = copy
    state.tab = "nearby"
    state.beast = copy[1]
    if not frame:IsShown() then frame:Show() else Refresh() end
end

local queued
local function QueueRefresh()
    if queued or not frame or not frame:IsShown() then return end
    queued = true
    C_Timer.After(0.15, function() queued = nil; Refresh(true) end)
end
ns.On("CHANGED", QueueRefresh)
local function HeaderOnly()
    if frame and frame:IsShown() then UpdateHeader() end
end
ns.On("TP", HeaderOnly)
ns.On("PET", HeaderOnly)
ns.On("OPTION", function(key)
    if key == "scale" and frame then frame:SetScale(ns.db.scale or 1) end
    SyncControls()
end)

-------------------------------------------------------------------------------
-- minimap button (no libraries)
-------------------------------------------------------------------------------
local function CreateMinimapButton()
    local b = CreateFrame("Button", "BeastAtlasMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local overlay = b:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)

    local function Place()
        local a = math.rad(ns.db.minimap.angle or 215)
        -- on the rim of the minimap, whatever its size (the same rule the common minimap-button library uses)
        local radius = (Minimap:GetWidth() or 140) / 2 + 5
        b:ClearAllPoints()
        b:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * radius, math.sin(a) * radius)
    end
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local x, y = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()
            ns.db.minimap.angle = math.deg(math.atan2(y / s - my, x / s - mx))
            Place()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ns.SetOption("mapPins", not ns.db.mapPins)
            ns.Print(ns.db.mapPins and L.PINS_ON or L.PINS_OFF)
        else
            ns.ToggleWindow()
        end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cffabd473" .. L.TITLE .. "|r")
        GameTooltip:AddLine(L.MINIMAP_HINT, 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    Place()
    C_Timer.After(2, Place) -- other addons may resize the minimap right after login
    b:SetShown(not ns.db.minimap.hide)
    minimapButton = b
end

ns.On("LOGIN", function()
    if ns.isHunter then CreateMinimapButton() end
end)
