WailaFoliageInspector = {}
local WailaFoliageInspector_mt = Class(WailaFoliageInspector)

function WailaFoliageInspector.new()
    local self = setmetatable({}, WailaFoliageInspector_mt)
    self.layers = nil
    return self
end

function WailaFoliageInspector:loadLayers()
    if self.layers ~= nil then
        return self.layers
    end

    self.layers = {}
    local foliageSystem = g_currentMission ~= nil and g_currentMission.foliageSystem or nil
    if foliageSystem == nil then
        return self.layers
    end

    local function collect(list)
        for _, foliage in ipairs(list or {}) do
            if foliage.layerName ~= nil and foliage.terrainDataPlaneId ~= nil then
                table.insert(self.layers, {
                    name = foliage.layerName,
                    planeId = foliage.terrainDataPlaneId
                })
            end
        end
    end

    collect(foliageSystem.decoFoliages)
    collect(foliageSystem.paintableFoliages)
    return self.layers
end

function WailaFoliageInspector:inspectPoint(x, z)
    local hits = {}
    for _, layer in ipairs(self:loadLayers()) do
        local density = getDensityAtWorldPos(layer.planeId, x, 0, z)
        if density ~= nil and density > 0 then
            table.insert(hits, {name = layer.name, density = density})
        end
    end
    return hits
end

function WailaFoliageInspector:scanArea(centerX, centerZ, size, step)
    local half = size * 0.5
    local counts = {}
    local samples = 0
    local occupiedSamples = 0
    local layers = self:loadLayers()

    for x = centerX - half, centerX + half - 0.0001, step do
        for z = centerZ - half, centerZ + half - 0.0001, step do
            samples = samples + 1
            local occupied = false

            for _, layer in ipairs(layers) do
                local density = getDensityAtWorldPos(layer.planeId, x, 0, z)
                if density ~= nil and density > 0 then
                    counts[layer.name] = (counts[layer.name] or 0) + 1
                    occupied = true
                end
            end

            if occupied then
                occupiedSamples = occupiedSamples + 1
            end
        end
    end

    counts["<empty>"] = math.max(0, samples - occupiedSamples)

    return {
        sampleCount = samples,
        foliage = WailaUtil.sortedCounts(counts, samples)
    }
end
