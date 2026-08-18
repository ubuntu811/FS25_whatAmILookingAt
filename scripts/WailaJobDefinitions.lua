--[[
    WailaJobDefinitions.lua

    Ported from SmartMinimapAuto's JOB_DEFINITIONS -- same thresholds,
    proven correct via extensive live testing this session (see that
    file's own comments for where each one comes from:
    MapOverlayGenerator:buildSoilStateMapOverlay's own NEEDS_PLOWING/
    NEEDS_ROLLING/NEEDS_LIME colors, SowMission.isAvailableForField,
    FertilizeMission's contract-vs-real-action distinction, ...). Kept as
    its own file rather than folded into WailaField.lua -- "what does a
    field need" is a genuinely separate, substantial concern from "what
    does a field currently look like", same reasoning SmartMinimapAuto
    already used to keep this as its own clearly-delimited block rather
    than scattering it through the rest of that file.

    Each definition carries a descriptive type name ("needs_lime", the
    canonical identifier, what WailaField.jobs actually stores) AND a
    single letter (SmartMinimapAuto's original H/W/P/S/R/F/L map-label
    convention, predates WAILA owning this data at all) -- the letter is
    offered as a default via getLetter() below, not baked into .jobs
    itself, so a consumer wanting different presentation (icons, colors,
    ...) can just ignore it and key off .type directly instead of being
    forced into one mod's original label scheme.
]]

WailaJobDefinitions = {}

WailaJobDefinitions.DEFINITIONS = {
    {
        type = "ready_to_harvest",
        letter = "H",
        check = function(fieldState)
            if fieldState.fruitTypeIndex == FruitType.UNKNOWN then
                return false
            end
            local desc = g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
            return desc ~= nil and desc.minHarvestingGrowthState ~= nil and desc.minHarvestingGrowthState >= 0
                and fieldState.growthState >= desc.minHarvestingGrowthState
                and fieldState.growthState <= desc.maxHarvestingGrowthState
        end,
    },
    {
        type = "needs_weeding",
        letter = "W",
        check = function(fieldState)
            if not g_currentMission.missionInfo.weedsEnabled or fieldState.weedState == 0 then
                return false
            end
            return g_currentMission.weedSystem:getWeededState(fieldState.weedState) == 0
        end,
    },
    {
        type = "needs_plowing",
        letter = "P",
        check = function(fieldState, field)
            if (field ~= nil and field.grassMissionOnly) or fieldState.fruitTypeIndex == FruitType.UNKNOWN then
                return false
            end
            local desc = g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
            if desc == nil then
                return false
            end
            if desc:getIsCatchCrop() and fieldState.growthState <= 1 then
                return false
            end
            return desc:getIsCut(fieldState.growthState) or desc:getIsWithered(fieldState.growthState)
        end,
    },
    {
        type = "needs_seeding",
        letter = "S",
        check = function(fieldState, field)
            return not (field ~= nil and field.grassMissionOnly)
                and fieldState.fruitTypeIndex == FruitType.UNKNOWN
        end,
    },
    {
        type = "needs_rolling",
        letter = "R",
        check = function(fieldState)
            return Platform.gameplay.useRolling
                and fieldState.rollerLevel == 1
        end,
    },
    {
        type = "needs_fertilizing",
        letter = "F",
        check = function(fieldState)
            local maxLevel = g_currentMission.fieldGroundSystem:getMaxValue(FieldDensityMap.SPRAY_LEVEL)
            if maxLevel <= fieldState.sprayLevel then
                return false
            end
            local fruitTypeIndex = fieldState.fruitTypeIndex
            if fruitTypeIndex ~= FruitType.UNKNOWN then
                local desc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
                if desc ~= nil then
                    if desc:getIsCatchCrop() then
                        return false
                    end
                    if desc:getIsHarvestable(fieldState.growthState) then
                        return false
                    end
                end
            end
            local environment = g_currentMission.environment
            return environment == nil or environment.currentSeason ~= Season.WINTER
        end,
    },
    {
        type = "needs_lime",
        letter = "L",
        check = function(fieldState)
            return Platform.gameplay.useLimeCounter
                and g_currentMission.missionInfo.limeRequired
                and fieldState.limeLevel == 0
        end,
    },
}

-- Meadow (player-converted pasture, or map-authored grassMissionOnly)
-- never has open field jobs, regardless of what the raw thresholds above
-- would otherwise say -- same check SmartMinimapAuto already applies
-- before drawing any letters.
function WailaJobDefinitions.evaluate(fieldState, field)
    local isMeadow = fieldState.groundType == FieldGroundType.GRASS
        or fieldState.groundType == FieldGroundType.GRASS_CUT
    if isMeadow then
        return {}
    end

    local jobs = {}
    for _, definition in ipairs(WailaJobDefinitions.DEFINITIONS) do
        if definition.check(fieldState, field) then
            table.insert(jobs, definition.type)
        end
    end
    return jobs
end

-- The default single-letter label for a job type (see file header) --
-- nil for an unrecognized type, not an error, so a consumer using this
-- alongside its own additional job types degrades gracefully.
function WailaJobDefinitions.getLetter(jobType)
    for _, definition in ipairs(WailaJobDefinitions.DEFINITIONS) do
        if definition.type == jobType then
            return definition.letter
        end
    end
    return nil
end
