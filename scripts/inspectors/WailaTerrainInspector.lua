WailaTerrainInspector = {}
local WailaTerrainInspector_mt = Class(WailaTerrainInspector)

local MATERIAL_NAMES = {
    [1] = "DIRT",
    [2] = "GRASS",
    [3] = "SAND",
    [6] = "GRAVEL",
    [7] = "STONE"
}

function WailaTerrainInspector.new()
    return setmetatable({}, WailaTerrainInspector_mt)
end

function WailaTerrainInspector:getMaterialName(materialId)
    return MATERIAL_NAMES[materialId] or string.format("material-%s", tostring(materialId))
end

-- Investigation, not confirmed useful yet - getTerrainAttributesAtWorldPos
-- (above) is confirmed as the only real per-position ground-type read, a
-- coarse materialId bucket (DIRT/GRASS/etc, ~7 values). These candidate
-- names are guesses at whether some OTHER named "terrain detail" density
-- system exists that's more granular than that bucket - none of them are
-- confirmed to resolve to anything. Real, confirmed: getTerrainDetailByName
-- resolving a name to a dataPlaneId, and getDensityTypeIndexAtWorldPos/
-- getDensityStatesAtWorldPos reading that dataPlaneId at a position - just
-- not confirmed whether any of THESE SPECIFIC names are the right ones.
-- This does NOT reveal which of the map's 62 individual paint layers
-- (dirt01/grass01/gravel01/etc) is under a point, even in the best case -
-- that's a different subsystem (TerrainDeformation paint layers) with no
-- per-position read at all, confirmed separately. At most this could
-- surface a ground classification more granular than the coarse bucket
-- but coarser than the 62 layers.
local DENSITY_PROBE_CANDIDATE_NAMES = {
    "groundType", "GROUND_TYPE", "material", "terrainType", "ground",
}

function WailaTerrainInspector:resolveDensityProbeIds()
    if self.densityProbeIdsResolved then
        return
    end

    self.densityProbeIdsResolved = true
    self.densityProbeIds = {}

    -- 0 is this engine's "not found" sentinel for getTerrainDetailByName
    -- (confirmed live: a candidate name resolved to 0, then
    -- getDensityTypeIndexAtWorldPos(0, ...) errored every frame with
    -- "Unknown entity id 0" since this runs continuously via the always-on
    -- point raycast, not just while the full HUD is open) - nil alone
    -- wasn't a strict enough guard.
    if g_currentMission.terrainDetailId ~= nil and g_currentMission.terrainDetailId ~= 0 then
        self.densityProbeIds["terrainDetailId"] = g_currentMission.terrainDetailId
    end

    for _, name in ipairs(DENSITY_PROBE_CANDIDATE_NAMES) do
        local okId, detailId = pcall(getTerrainDetailByName, g_terrainNode, name)

        if okId and detailId ~= nil and detailId ~= 0 then
            self.densityProbeIds[name] = detailId
        end
    end
end

function WailaTerrainInspector:inspectPoint(x, y, z)
    local isOnField, densityBits, groundType = FSDensityMapUtil.getFieldDataAtWorldPosition(x, y, z)
    local r, g, b, depth, materialId = getTerrainAttributesAtWorldPos(
        g_terrainNode, x, y, z, true, true, true, true, false
    )

    self:resolveDensityProbeIds()

    local densityProbe = {}
    for label, dataPlaneId in pairs(self.densityProbeIds) do
        local okType, typeIndex = pcall(getDensityTypeIndexAtWorldPos, dataPlaneId, x, y, z)
        local okStates, states = pcall(getDensityStatesAtWorldPos, dataPlaneId, x, y, z)

        densityProbe[label] = {
            typeIndex = okType and typeIndex or nil,
            states = okStates and states or nil,
        }
    end

    return {
        x = x,
        y = y,
        z = z,
        isOnField = isOnField,
        densityBits = densityBits,
        groundType = groundType,
        r = r,
        g = g,
        b = b,
        depth = depth,
        materialId = materialId,
        materialName = self:getMaterialName(materialId),
        densityProbe = densityProbe
    }
end

function WailaTerrainInspector:scanArea(centerX, centerZ, size, step)
    local half = size * 0.5
    local materials = {}
    local fieldSamples = 0
    local samples = 0

    for x = centerX - half, centerX + half - 0.0001, step do
        for z = centerZ - half, centerZ + half - 0.0001, step do
            local _, _, _, _, materialId = getTerrainAttributesAtWorldPos(
                g_terrainNode, x, 0, z, true, true, true, true, false
            )
            local isOnField = FSDensityMapUtil.getFieldDataAtWorldPosition(x, 0, z)

            samples = samples + 1
            materials[self:getMaterialName(materialId)] = (materials[self:getMaterialName(materialId)] or 0) + 1
            if isOnField then
                fieldSamples = fieldSamples + 1
            end
        end
    end

    return {
        sampleCount = samples,
        materials = WailaUtil.sortedCounts(materials, samples),
        fieldPercent = samples > 0 and fieldSamples / samples * 100 or 0
    }
end
