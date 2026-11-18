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
-- Real live bug found on a map with multiple actual fields sharing one
-- farmland id: getFieldAtPosition's farmland->getFieldById substitution
-- mirrors a genuine base-game assumption (confirmed: FieldManager's own
-- getFieldIdAtPlayerPosition does the identical farmland:getId()
-- substitution, no getFieldById call at all -- this isn't a WAILA
-- mistake, it's the base game's own standing "farmland id ~= field id
-- but close enough" shortcut). That assumption holds for the common
-- one-field-per-farmland map but not here -- field:getId() itself
-- delegates to its farmland's id (confirmed, Field.lua), so two
-- genuinely different fields under the same farmland report the SAME
-- id, making getFieldById(farmlandId) structurally ambiguous: whichever
-- field last claimed that id wins, for every query under that farmland,
-- regardless of which one you're actually standing in.
--
-- Real fix: never let the resolved field object's own cached state gate
-- what gets shown. field/farmlandId are kept purely as loose,
-- informational context (still useful -- "which farmland owns this
-- ground" is real and often correct) -- the actual status always comes
-- from the same direct, position-accurate density-map read the no-field
-- fallback path already used, since that's the one thing here that
-- doesn't depend on the original map's authored Field/Farmland structure
-- at all, only on what's actually planted/tilled right now.
function WailaFieldInspector:inspectPoint(x, y, z)
    local field, farmlandId = self:getFieldAtPosition(x, z)

    local isOnField = FSDensityMapUtil.getFieldDataAtWorldPosition(x, y, z)
    if not isOnField then
        return nil
    end

    local fieldState = FieldState.new()
    fieldState:update(x, z)
    return WailaField.new(fieldState, field, farmlandId)
end
