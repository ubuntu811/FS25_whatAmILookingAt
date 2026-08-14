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
function WailaFieldInspector:getFieldAtPosition(x, z)
    if g_farmlandManager == nil or g_fieldManager == nil then
        return nil
    end

    local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
    if farmland == nil then
        return nil
    end

    return g_fieldManager:getFieldById(farmland:getId())
end

-- Builds the display table from any FieldState -- shared by both the
-- registered-Field path and the unregistered-ground fallback below, since
-- FieldState itself doesn't care which one produced it (see fieldId==nil
-- comment in inspectPoint for why they can diverge at all).
function WailaFieldInspector:buildResult(fieldState, field)
    local fruitTypeName = nil
    local growthStateName = nil
    if fieldState.fruitTypeIndex ~= FruitType.UNKNOWN then
        local desc = g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
        if desc ~= nil then
            fruitTypeName = desc.name
            growthStateName = desc:getGrowthStateName(fieldState.growthState)
        end
    end

    local groundSystem = g_currentMission.fieldGroundSystem
    local maxPlowLevel = groundSystem ~= nil and groundSystem:getMaxValue(FieldDensityMap.PLOW_LEVEL) or nil
    local maxLimeLevel = groundSystem ~= nil and groundSystem:getMaxValue(FieldDensityMap.LIME_LEVEL) or nil
    local maxSprayLevel = groundSystem ~= nil and groundSystem:getMaxValue(FieldDensityMap.SPRAY_LEVEL) or nil

    local weededState = nil
    if g_currentMission.weedSystem ~= nil and fieldState.weedState ~= nil then
        weededState = g_currentMission.weedSystem:getWeededState(fieldState.weedState)
    end

    return {
        fieldId = field ~= nil and field:getId() or nil,
        areaHa = field ~= nil and field:getAreaHa() or nil,
        ownerFarmId = field ~= nil and field:getOwner() or nil,
        isValid = fieldState.isValid,
        grassMissionOnly = field ~= nil and field.grassMissionOnly or nil,
        fruitTypeName = fruitTypeName,
        growthState = fieldState.growthState,
        growthStateName = growthStateName,
        groundTypeName = FieldGroundType.getName(fieldState.groundType),
        weedState = fieldState.weedState,
        weededState = weededState,
        stoneLevel = fieldState.stoneLevel,
        sprayTypeName = FieldSprayType.getName(fieldState.sprayType),
        sprayLevel = fieldState.sprayLevel,
        maxSprayLevel = maxSprayLevel,
        limeLevel = fieldState.limeLevel,
        maxLimeLevel = maxLimeLevel,
        plowLevel = fieldState.plowLevel,
        maxPlowLevel = maxPlowLevel,
        rollerLevel = fieldState.rollerLevel,
        stubbleShredLevel = fieldState.stubbleShredLevel,
    }
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
    local field = self:getFieldAtPosition(x, z)
    if field ~= nil then
        field:updateState()
        return self:buildResult(field:getFieldState(), field)
    end

    local isOnField = FSDensityMapUtil.getFieldDataAtWorldPosition(x, y, z)
    if not isOnField then
        return nil
    end

    local fieldState = FieldState.new()
    fieldState:update(x, z)
    return self:buildResult(fieldState, nil)
end
