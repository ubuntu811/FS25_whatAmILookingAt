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
local nodeFlags = { [500] = CollisionFlag.BUILDING, [501] = CollisionFlag.BUILDING, [600] = CollisionFlag.STATIC_OBJECT, [700] = CollisionFlag.WATER }
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
check("the ray mask is BUILDING | STATIC_OBJECT | WATER", check_mask == bit32.bor(bit32.bor(CollisionFlag.BUILDING, CollisionFlag.STATIC_OBJECT), CollisionFlag.WATER))
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

-- water: a pond (plane 0.5 m above the terrain) at x, z 20..40; everywhere else the plane
-- lies 5 m BELOW the terrain (what every land cell sees) and must not count
raycastClosest = function(x, y, z, dx, dy, dz, distance, callbackName, target, mask)
    if x >= 20 and x <= 40 and z >= 20 and z <= 40 then
        target[callbackName](target, 700, x, 100.5, z)
    else
        target[callbackName](target, 700, x, 95, z)
    end
end
local none, water, waterPolys = T.scanBuildingChunk(0, 0, 64)
check("water: a pond gives a water mask", water ~= nil)
check("water: cell inside the pond is water", water ~= nil and water[15][15] == true)
check("water: land cell with the plane below the terrain is not water", water ~= nil and water[2][2] == false)
check("water: the mask is grown by a cell (pond edge x=20 -> cell 9 is water)", water ~= nil and water[15][9] == true)
check("water: pond is not a building", #none == 0)
check("water layer: one polygon for the pond", #waterPolys == 1)
check("water layer: area about the pond's 20 x 20 m (not the grown mask)", #waterPolys == 1 and math.abs(polygonArea(waterPolys[1]) / 400 - 1) < 0.2)
raycastClosest = function(x, y, z, dx, dy, dz, distance, callbackName, target, mask)
    target[callbackName](target, 700, x, 95, z)
end
local _, noWater, noWaterPolys = T.scanBuildingChunk(0, 0, 64)
check("water: a chunk with the plane only below the terrain has no water mask", noWater == nil and #noWaterPolys == 0)
finish("building_scan_test")
