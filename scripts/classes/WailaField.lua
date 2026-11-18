--[[
    WailaField.lua

    Typed result class for WailaFieldInspector -- pilot for the
    dumpHudJson/dumpLogJson pattern this mod's inspectors are moving to:
    a stateless inspector scans the world and returns one of these,
    instead of an ad hoc plain table only WailaHud.lua knows the shape of.
    Nothing here is scanning logic (that stays in WailaFieldInspector,
    which decides *where* to sample from -- registered Field vs standalone
    FieldState fallback) -- this class only shapes already-read field data
    into something with a stable, named, externally-callable contract.

    Data fields are stored directly on the instance (self.fieldId, ...),
    not hidden behind accessors -- same-mod code (WailaHud.lua) reads them
    directly, exactly like it read the old plain table, no changes needed
    there. dumpHudJson/dumpLogJson exist for external consumers (other
    mods calling in, or the Shift+J log dump) that want a plain,
    serializable snapshot without depending on this class's metatable.
]]

WailaField = {}
local WailaField_mt = Class(WailaField)

-- fieldState: a FieldState (either field:getFieldState() or a standalone
-- FieldState.new():update(x,z) -- see WailaFieldInspector for why both
-- exist). field: the registered Field object, or nil for real, tilled
-- field ground with no Field behind it. farmlandId: the raw land-parcel
-- id at this position (or nil off any farmland at all) -- distinct from
-- fieldId, since a farmland's own land boundary is typically much larger
-- than any Field registered within it (see WailaFieldInspector).
function WailaField.new(fieldState, field, farmlandId)
    local self = setmetatable({}, WailaField_mt)

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

    self.farmlandId = farmlandId
    self.fieldId = field ~= nil and field:getId() or nil
    self.areaHa = field ~= nil and field:getAreaHa() or nil
    self.ownerFarmId = field ~= nil and field:getOwner() or nil
    self.isValid = fieldState.isValid
    self.grassMissionOnly = field ~= nil and field.grassMissionOnly or nil
    self.fruitTypeName = fruitTypeName
    self.growthState = fieldState.growthState
    self.growthStateName = growthStateName
    self.groundTypeName = FieldGroundType.getName(fieldState.groundType)
    self.weedState = fieldState.weedState
    self.weededState = weededState
    self.stoneLevel = fieldState.stoneLevel
    self.sprayTypeName = FieldSprayType.getName(fieldState.sprayType)
    self.sprayLevel = fieldState.sprayLevel
    self.maxSprayLevel = maxSprayLevel
    self.limeLevel = fieldState.limeLevel
    self.maxLimeLevel = maxLimeLevel
    self.plowLevel = fieldState.plowLevel
    self.maxPlowLevel = maxPlowLevel
    self.rollerLevel = fieldState.rollerLevel
    self.stubbleShredLevel = fieldState.stubbleShredLevel

    -- Derived "needs X" verdicts (see WailaJobDefinitions.lua) --
    -- deliberately NOT surfaced on the live WailaHud panel (that stays
    -- raw numbers only, on purpose, see docs on that design), but real
    -- consumers like WailaFieldIndex need this, not just the raw state
    -- every one of them would otherwise have to re-derive independently.
    self.jobs = WailaJobDefinitions.evaluate(fieldState, field)

    return self
end

-- Plain, JSON-serializable snapshot of everything this class knows.
function WailaField:toTable()
    return {
        farmlandId = self.farmlandId,
        fieldId = self.fieldId,
        areaHa = self.areaHa,
        ownerFarmId = self.ownerFarmId,
        isValid = self.isValid,
        grassMissionOnly = self.grassMissionOnly,
        fruitTypeName = self.fruitTypeName,
        growthState = self.growthState,
        growthStateName = self.growthStateName,
        groundTypeName = self.groundTypeName,
        weedState = self.weedState,
        weededState = self.weededState,
        stoneLevel = self.stoneLevel,
        sprayTypeName = self.sprayTypeName,
        sprayLevel = self.sprayLevel,
        maxSprayLevel = self.maxSprayLevel,
        limeLevel = self.limeLevel,
        maxLimeLevel = self.maxLimeLevel,
        plowLevel = self.plowLevel,
        maxPlowLevel = self.maxPlowLevel,
        rollerLevel = self.rollerLevel,
        stubbleShredLevel = self.stubbleShredLevel,
        jobs = self.jobs,
    }
end

-- What an on-screen HUD panel needs. Same fields as dumpLogJson right now
-- -- nothing here is cramped enough to trim for screen space -- kept as
-- its own method anyway so a class with more raw detail than fits on
-- screen (e.g. a future WailaVehicle) can diverge without breaking this
-- contract.
function WailaField:dumpHudJson()
    return self:toTable()
end

-- Everything worth logging/dumping to file. Same as dumpHudJson for this
-- class specifically (nothing hidden from the HUD) -- won't generally be
-- true for classes with more raw spec data than screen space allows.
function WailaField:dumpLogJson()
    return self:toTable()
end
