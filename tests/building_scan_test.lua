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
raycastClosest = function(x, y, z, dx, dy, dz, distance, callbackName, target, mask)
    check_mask = mask
    if inRoof(x, z) and not (x > 24 and x < 26 and z > 14 and z < 16) then      -- 2m x 2m gap in the roof
        target[callbackName](target, 500, x, 109, z)
    elseif x >= 50 and x <= 60 and z >= 50 and z <= 52 then
        target[callbackName](target, 501, x, 100.8, z)                            -- low wall
    end
end
local polygons = T.scanBuildingChunk(0, 0, 64)
check("the ray mask is the BUILDING bit only", check_mask == CollisionFlag.BUILDING)
check("one polygon: the L-shaped roof (gap closed, low wall ignored)", #polygons == 1)
local expected = 30 * 10 + 10 * 20        -- the two wings: 300 + 200
check("roof area close to the true L (within 12%)", math.abs(polygonArea(polygons[1]) / expected - 1) < 0.12)
check("the outline keeps the L's corners: 6 to 10 points, not a rectangle", #polygons[1] >= 6 and #polygons[1] <= 10)
raycastClosest = function() end
check("a chunk without buildings returns nothing", #T.scanBuildingChunk(1000, 1000, 64) == 0)
finish("building_scan_test")
