--[[
    WailaFoliageArea.lua

    Typed result class for WailaFoliageInspector:scanArea() -- mirrors
    WailaTerrainArea's shape (sampleCount + a sortedCounts list) so
    WailaHud can render both alike, per the original comment in
    WailaFoliageInspector.lua. Kept as its own class rather than reusing
    WailaTerrainArea since the list here is keyed differently (foliage
    "name L<level>" vs. terrain material name) and they're conceptually
    different things, just a shared shape.
]]

WailaFoliageArea = {}
local WailaFoliageArea_mt = Class(WailaFoliageArea)

-- foliage: WailaUtil.sortedCounts() output -- {{name, count, percent}, ...}
function WailaFoliageArea.new(sampleCount, foliage)
    local self = setmetatable({}, WailaFoliageArea_mt)

    self.sampleCount = sampleCount
    self.foliage = foliage

    return self
end

function WailaFoliageArea:toTable()
    return {
        sampleCount = self.sampleCount,
        foliage = self.foliage,
    }
end

function WailaFoliageArea:dumpHudJson()
    return self:toTable()
end

function WailaFoliageArea:dumpLogJson()
    return self:toTable()
end
