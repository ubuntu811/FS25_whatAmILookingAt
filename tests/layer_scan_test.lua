dofile("tests/stubs.lua")
local T = loadTracer()
T.layerClassLearned = true

-- Synthetic chunk (0..64):
--  * forest disc r=12 at (18,30): forest-floor layer WITH foliage, dirt flecks among grass
--  * parking lot x 36..56, z 16..34 with a 12 x 10 placeable footprint inside: the SAME forest-floor layer, DIRT material, NO foliage
--  * IW-style worn path (gravel, 3m wide, (0,55)->(64,45)) whose layer signal is only dashes
--  * road 4m wide along z=10
T.foliageAvailable = function() return true end
T.hasFoliageAt = function(x, z) return (x - 18) ^ 2 + (z - 30) ^ 2 <= 12 * 12 end
local function world(x, z)
    if math.abs(z - 10) <= 2 then return T.LAYER_CLASS_ROAD, 7 end
    if (x - 18) ^ 2 + (z - 30) ^ 2 <= 12 * 12 then
        return T.LAYER_CLASS_FOREST, (math.floor(x / 3) % 4 == 0) and 1 or 2
    end
    -- a placeable on the lot: its own ground layer (no class), stone material
    if x >= 42 and x <= 54 and z >= 20 and z <= 30 then return nil, 7 end
    if x >= 36 and x <= 56 and z >= 16 and z <= 34 then return T.LAYER_CLASS_FOREST, 1 end
    local lz = 55 - (10 / 64) * x
    if math.abs(z - lz) <= 1.5 and x >= 0 and x <= 64 then
        return (math.floor(x / 6) % 3 == 0) and T.LAYER_CLASS_FOREST or nil, 6
    end
    return nil, 2
end
T.getLayerCellAt = world
T.scanRoadLayerChunk = function() return { { { 0, 8 }, { 64, 8 }, { 64, 12 }, { 0, 12 } } }, 1000 end

local r = T.scanLayerChunk(0, 0, 64)
check("chunk with content returns a result", r ~= nil)
check("forest: exactly one polygon (the foliage disc, not the parking lot)", #r.forest == 1)
local disc = math.pi * 12 * 12
check("forest area within 12% of the disc", math.abs(totalArea(r.forest) / disc - 1) < 0.12)
local function centroid(p)
    local cx, cz = 0, 0
    for _, q in ipairs(p) do cx, cz = cx + q[1], cz + q[2] end
    return cx / #p, cz / #p
end
local fx, fz = centroid(r.forest[1])
check("the forest polygon is the disc, not the lot", fx < 30)
local lotTrail, pathTrail = 0, 0
for _, p in ipairs(r.trail) do
    local cx, cz = centroid(p)
    if cx >= 36 and cx <= 56 and cz >= 16 and cz <= 34 then lotTrail = lotTrail + polygonArea(p) else pathTrail = pathTrail + polygonArea(p) end
end
check("parking lot is worn ground (trail layer), about 360 m2 with the placeable footprint filled in", lotTrail > 320 and lotTrail < 440)
check("worn path is a continuous trail, about 190 m2", pathTrail > 120 and pathTrail < 260)
local leak = false
for _, p in ipairs(r.trail) do
    local cx, cz = centroid(p)
    if (cx - 18) ^ 2 + (cz - 30) ^ 2 < 8 * 8 then leak = true end
end
check("forest-floor dirt inside the forest area is not a trail", not leak)
check("road comes from the road pass", #r.road == 1)
local points = 0
for _, list in ipairs({ r.forest, r.trail }) do for _, p in ipairs(list) do points = points + #p end end
check("few points (curve fit)", points < 150)
T.getLayerCellAt = function() return nil, 2 end
check("empty chunk returns nil", T.scanLayerChunk(1000, 1000, 64) == nil)
finish("layer_scan_test")
