dofile("tests/stubs.lua")
local T = loadTracer()
g_terrainNode = 1
getTerrainHeightAtWorldPos = function() return 100 end
-- two buildings in the chunk (0..64): an L-shaped factory (roof 9m) and a low shed wall (0.8m, ignored);
-- a roof "gap" (a ray between two roof parts) inside the L
local function inRoof(x, z)
    local inA = x >= 10 and x <= 40 and z >= 10 and z <= 20
    local inB = x >= 10 and x <= 20 and z >= 20 and z <= 40
    return inA or inB
end
local nodeFlags = { [500] = CollisionFlag.BUILDING, [501] = CollisionFlag.BUILDING, [600] = CollisionFlag.STATIC_OBJECT }
CollisionFlag.getHasGroupFlagSet = function(node, flag) return bit32.band(nodeFlags[node] or 0, flag) ~= 0 end
raycastClosest = function(x, y, z, dx, dy, dz, distance, callbackName, target, mask)
    check_mask = mask
    if inRoof(x, z) and not (x > 24 and x < 26 and z > 14 and z < 16) then      -- 2m x 2m gap in the roof
        target[callbackName](target, 500, x, 109, z)
    elseif x >= 50 and x <= 60 and z >= 50 and z <= 52 then
        target[callbackName](target, 501, x, 100.8, z)                            -- low wall
    end
end
local polygons = T.scanBuildingChunk(0, 0, 64)
check("the ray mask is BUILDING | STATIC_OBJECT", check_mask == bit32.bor(CollisionFlag.BUILDING, CollisionFlag.STATIC_OBJECT))
check("one polygon: the L-shaped roof (gap closed, low wall ignored)", #polygons == 1)
local expected = 30 * 10 + 10 * 20        -- the two wings: 300 + 200
check("roof area close to the true L (within 12%)", math.abs(polygonArea(polygons[1]) / expected - 1) < 0.12)
check("the outline keeps the L's corners: 6 to 10 points, not a rectangle", #polygons[1] >= 6 and #polygons[1] <= 10)
raycastClosest = function() end
check("a chunk without buildings returns nothing", #T.scanBuildingChunk(1000, 1000, 64) == 0)

-- map-baked buildings: STATIC_OBJECT only (Estancia harbour). A 24 x 14 m warehouse
-- (roof 8 m), a 40 m long 1 m thick fence wall (3 m), a 1 x 1 m pole (6 m), a low static wall (1.5 m)
raycastClosest = function(x, y, z, dx, dy, dz, distance, callbackName, target, mask)
    if x >= 10 and x <= 34 and z >= 10 and z <= 24 then
        target[callbackName](target, 600, x, 108, z)
    elseif z >= 40 and z <= 41 and x >= 10 and x <= 50 then
        target[callbackName](target, 600, x, 103, z)
    elseif x >= 56 and x <= 57 and z >= 56 and z <= 57 then
        target[callbackName](target, 600, x, 106, z)
    elseif z >= 30 and z <= 36 and x >= 40 and x <= 60 then
        target[callbackName](target, 600, x, 101.5, z)
    end
end
local statics = T.scanBuildingChunk(0, 0, 64)
check("static warehouse found, fence / pole / low wall ignored: one polygon", #statics == 1)
check("warehouse area close to 24 x 14 (within 15%)", #statics == 1 and math.abs(polygonArea(statics[1]) / (24 * 14) - 1) < 0.15)
finish("building_scan_test")
