-- Adds "tame to learn" lines to tooltips of wild beasts in the world.
local _, ns = ...
local L = ns.L
local S = ns.STATUS

local function NpcIdFromGUID(guid)
    if not guid or ns.IsSecret(guid) then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind ~= "Creature" then return nil end
    return tonumber(id)
end

local function OnUnitTooltip(tt)
    if not ns.isHunter or tt ~= GameTooltip then return end
    local ok, _, unit = pcall(tt.GetUnit, tt)
    -- in dungeons and raids the unit token itself is a secret value: addon code may not pass it to
    -- the Unit* functions at all (UnitGUID raises an error), so there is nothing to look up
    if not ok or ns.IsSecret(unit) or not unit then return end
    local id = NpcIdFromGUID(UnitGUID(unit))
    local b = id and ns.BEASTS[id]
    if not b then return end
    ns.LearnFamily(UnitCreatureFamily(unit), b.f) -- lets other client languages recognise the pet's family
    local lines = {}
    for i = 1, #b.t, 2 do
        local ab = ns.Ability(b.t[i])
        local rank = b.t[i + 1]
        if ab and not ab.trainer and ab.ranks[rank] then
            local st, tame = ns.BeastRankStatus(id, ab.key, rank)
            local note = ns.StatusNote(st, ab.key, rank, tame)
            lines[#lines + 1] = { "  " .. ns.StatusHex(st) .. (ns.DisplayName(ab, true)) .. " " .. rank .. "|r",
                ns.StatusHex(st) .. note .. "|r" }
        end
    end
    if #lines == 0 then return end
    tt:AddLine(" ")
    tt:AddLine("|cffabd473" .. L.TT_HEADER .. "|r  |cffaaaaaa" .. L.TT_TAMES .. "|r")
    for _, l in ipairs(lines) do tt:AddDoubleLine(l[1], l[2]) end
    if b.s then tt:AddLine("  |cffaaaaaa" .. L.ATTACK_SPEED:format(b.s) .. "|r") end
    local _, other = ns.Names(b)
    local shown = UnitName(unit)
    if other and not ns.IsSecret(shown) and other ~= shown then tt:AddLine("  |cff8a8a8a" .. other .. "|r") end
    tt:Show()
end

ns.On("LOGIN", function()
    if not ns.isHunter then return end
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnitTooltip)
    else
        GameTooltip:HookScript("OnTooltipSetUnit", OnUnitTooltip)
    end
end)
