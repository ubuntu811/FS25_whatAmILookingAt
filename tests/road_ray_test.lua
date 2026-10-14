dofile("tests/stubs.lua")
local T = loadTracer()
g_terrainNode = 1
getTerrainHeightAtWorldPos = function() return 100 end

-- a 6 m wide collision road along x, z = 20..26, crossing the whole chunk (0..64);
-- a second chunk (200..264) has no road
local rayMask
raycastClosest = function(x, y, z, dx, dy, dz, distance, callbackName, target, mask)
    rayMask = mask
    if z >= 20 and z <= 26 and x >= 0 and x <= 64 then
        target[callbackName](target, 700, x, 100.1, z)
    end
end

local polygons = T.scanRoadRayChunk(0, 0, 64)
check("the ray mask is the ROAD bit only", rayMask == CollisionFlag.ROAD)
check("one polygon: the road strip", #polygons == 1)
local expected = 64 * 6
check("area close to length x width (within 15%)", #polygons >= 1 and math.abs(totalArea(polygons) / expected - 1) < 0.15)
check("a chunk without road returns nothing", #T.scanRoadRayChunk(200, 200, 64) == 0)

-- probe: splines on the collision road vs splines beside it
local onRoad, offRoad = {}, {}
for x = 2, 60, 6 do
    table.insert(onRoad, { x, 23 })
    table.insert(offRoad, { x, 40 })
end
local share = T.probeRoadCollision({ onRoad })
check("splines on the collider: probe share 100%", share == 1)
check("splines beside it: probe share 0%", T.probeRoadCollision({ offRoad }) == 0)
local mixed = T.probeRoadCollision({ onRoad, offRoad })
check("half on, half off: share about 50%", math.abs(mixed - 0.5) < 0.1)
check("no splines: probe share 0", T.probeRoadCollision({}) == 0)
finish("road_ray_test")
