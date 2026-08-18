WailaFieldInspector = {}
local WailaFieldInspector_mt = Class(WailaFieldInspector)

function WailaFieldInspector.new()
    return setmetatable({}, WailaFieldInspector_mt)
end

-- Same lookup FieldManager.getFieldIdAtPlayerPosition uses internally
-- (confirmed via decompiling dataS.gar, scripts/field/FieldManager.lua) --
-- getFarmlandAtWorldPosition resolves a farmland at a position, and
-- farmland id == field id for the common case. That's the real base-game
-- function for "what field is at this position", not a raycast target --
-- fields have no collision mesh of their own to hit.
--
-- Returns (field, farmlandId) -- farmlandId is exposed separately (not
-- just field:getId()) because farmland ownership and field registration
-- are two different things: a farmland is a whole land parcel (typically
-- a large, irregular, often forest-including polygon used for the
-- buy/sell-land system), while a Field is the specific farmable area
-- registered within it. Standing in forest that's still part of the SAME
-- farmland number as a distant crop field is real, expected base-game
-- behavior, not a bug -- confirmed live (a "Field 14" HUD result while
-- standing in dense forest nowhere near field 14's own crop rows) that
-- this distinction matters enough to show both, not just the field.
function WailaFieldInspector:getFieldAtPosition(x, z)
    if g_farmlandManager == nil or g_fieldManager == nil then
        return nil, nil
    end

    local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
    if farmland == nil then
        return nil, nil
    end

    local farmlandId = farmland:getId()
    return g_fieldManager:getFieldById(farmlandId), farmlandId
end

-- field:updateState() + field:getFieldState() are the real per-field job-
-- state API (confirmed via Field.lua/FieldState.lua, dataS.gar) -- samples
-- density-map values at the field's own centroid, not a raw point probe we
-- built ourselves. Raw values only here, no derived "needs X" verdicts --
-- matches this mod's existing terrain/foliage inspectors, which show real
-- confirmed numbers and let the human read them, not opinionated judgments.
--
-- fieldId can come back nil: tillage tools create/expand "field" ground at
-- the density-map level (FSDensityMapUtil.updateCultivatorArea/
-- updatePlowArea's createField param, defaults true) completely independent
-- of the registered Field/Farmland objects (confirmed: MapOverlayGenerator's
-- own FIELDS map overlay is built purely from the raw GROUND_TYPE density
-- channel too, never consults g_fieldManager). So real, farmable, currently-
-- tilled ground can exist with no Field object at all -- when that happens
-- we still build a full FieldState by calling it standalone at the exact
-- point (FieldState doesn't require a Field to operate on, it's just a
-- density-map reader), instead of returning nothing for genuinely farmable
-- ground just because no map author registered it.
function WailaFieldInspector:inspectPoint(x, y, z)
    local field, farmlandId = self:getFieldAtPosition(x, z)
    if field ~= nil then
        field:updateState()
        return WailaField.new(field:getFieldState(), field, farmlandId)
    end

    local isOnField = FSDensityMapUtil.getFieldDataAtWorldPosition(x, y, z)
    if not isOnField then
        return nil
    end

    local fieldState = FieldState.new()
    fieldState:update(x, z)
    return WailaField.new(fieldState, nil, farmlandId)
end
