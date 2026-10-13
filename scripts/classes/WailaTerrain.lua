--[[
    WailaTerrain.lua

    Typed result class for WailaTerrainInspector:inspectPoint() -- second
    class in the dumpHudJson/dumpLogJson pattern (see WailaField.lua for
    the pilot and the reasoning). Material-name resolution (previously a
    method on the inspector) lives here now as a class-level (not
    instance) function, since WailaTerrainArea also needs the same lookup
    for its per-material histogram and shouldn't duplicate the table.
]]

WailaTerrain = {}
local WailaTerrain_mt = Class(WailaTerrain)

local MATERIAL_NAMES = {
    [1] = "DIRT",
    [2] = "GRASS",
    [3] = "SAND",
    [6] = "GRAVEL",
    [7] = "STONE",
}

function WailaTerrain.getMaterialName(materialId)
    return MATERIAL_NAMES[materialId] or string.format("material-%s", tostring(materialId))
end

function WailaTerrain.new(x, y, z, isOnField, densityBits, groundType, r, g, b, depth, materialId, isClearOfStructures)
    local self = setmetatable({}, WailaTerrain_mt)

    self.x = x
    self.y = y
    self.z = z
    self.isOnField = isOnField
    self.densityBits = densityBits
    self.groundType = groundType
    self.r = r
    self.g = g
    self.b = b
    self.depth = depth
    self.materialId = materialId
    self.materialName = WailaTerrain.getMaterialName(materialId)
    self.isClearOfStructures = isClearOfStructures

    return self
end

function WailaTerrain:toTable()
    return {
        x = self.x,
        y = self.y,
        z = self.z,
        isOnField = self.isOnField,
        densityBits = self.densityBits,
        groundType = self.groundType,
        r = self.r,
        g = self.g,
        b = self.b,
        depth = self.depth,
        materialId = self.materialId,
        materialName = self.materialName,
        isClearOfStructures = self.isClearOfStructures,
    }
end

function WailaTerrain:dumpHudJson()
    return self:toTable()
end

function WailaTerrain:dumpLogJson()
    return self:toTable()
end
