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
function WailaTerrainArea.new(sampleCount, materials, fieldPercent)
    local self = setmetatable({}, WailaTerrainArea_mt)

    self.sampleCount = sampleCount
    self.materials = materials
    self.fieldPercent = fieldPercent

    return self
end

function WailaTerrainArea:toTable()
    return {
        sampleCount = self.sampleCount,
        materials = self.materials,
        fieldPercent = self.fieldPercent,
    }
end

function WailaTerrainArea:dumpHudJson()
    return self:toTable()
end

function WailaTerrainArea:dumpLogJson()
    return self:toTable()
end
