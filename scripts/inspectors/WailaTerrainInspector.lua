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

function WailaTerrainInspector:inspectPoint(x, y, z)
    local isOnField, densityBits, groundType = FSDensityMapUtil.getFieldDataAtWorldPosition(x, y, z)
    local r, g, b, depth, materialId = getTerrainAttributesAtWorldPos(
        g_terrainNode, x, y, z, true, true, true, true, false
    )

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
        materialName = self:getMaterialName(materialId)
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
