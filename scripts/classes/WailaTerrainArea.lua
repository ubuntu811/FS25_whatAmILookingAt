--[[
    WailaTerrainArea.lua

    Typed result class for WailaTerrainInspector:scanArea() -- an
    aggregate over many sampled points, not a single-position read like
    WailaTerrain. Kept as its own class rather than folded into
    WailaTerrain since it's a genuinely different shape (a histogram +
    coverage percentage, not a point's own attributes).
]]

WailaTerrainArea = {}
local WailaTerrainArea_mt = Class(WailaTerrainArea)

-- materials: WailaUtil.sortedCounts() output -- {{name, count, percent}, ...}
-- layers: same shape, keyed by the layer fingerprint "r/g/b/w" (first four returns of
-- getTerrainAttributesAtWorldPos) -- finer than the material bucket.
function WailaTerrainArea.new(sampleCount, materials, fieldPercent, layers)
    local self = setmetatable({}, WailaTerrainArea_mt)

    self.sampleCount = sampleCount
    self.materials = materials
    self.fieldPercent = fieldPercent
    self.layers = layers or {}

    return self
end

function WailaTerrainArea:toTable()
    return {
        sampleCount = self.sampleCount,
        materials = self.materials,
        fieldPercent = self.fieldPercent,
        layers = self.layers,
    }
end

function WailaTerrainArea:dumpHudJson()
    return self:toTable()
end

function WailaTerrainArea:dumpLogJson()
    return self:toTable()
end
