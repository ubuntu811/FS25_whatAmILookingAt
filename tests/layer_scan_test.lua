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

-- A big yard with a big placeable pad (own stone layer, 44 x 44 m: larger than the hole-size limit
-- and nearly the size of a chunk): the pad belongs to the yard, no island.
do
    T.foliageAvailable = function() return true end
    T.hasFoliageAt = function() return false end
    T.getLayerCellAt = function(x, z)
        if x >= 16 and x <= 60 and z >= 16 and z <= 60 then return nil, 7 end            -- the pad
        if x >= 4 and x <= 72 and z >= 4 and z <= 72 then return T.LAYER_CLASS_FOREST, 1 end -- the yard
        return nil, 2
    end
    local yard = T.scanLayerChunk(0, 0, 64)
    local yardArea = totalArea(yard.trail)
    local expected = 60 * 60            -- the yard inside the chunk window, x/z 4..64
    check("yard with a big placeable pad: one polygon, no island", #yard.trail == 1)
    check("yard area includes the pad (no hole)", yardArea > expected * 0.9)
    check("a yard is not forest", #yard.forest == 0)
end


-- Trees instead of a forest layer (a map where the forest is "grass with trees"): a grove of trunks
-- every 5 m inside a disc r=16 at (32,32), one isolated tree, and a 3 m dirt path through the grove.
do
    local trunks = {}
    for gx = 16, 48, 5 do
        for gz = 16, 48, 5 do
            if (gx - 32) ^ 2 + (gz - 32) ^ 2 <= 16 * 16 then trunks[#trunks + 1] = { gx, gz } end
        end
    end
    trunks[#trunks + 1] = { 58, 8 }                       -- the lone tree
    overlapBox = function(x, y, z, rx, ry, rz, ex, ey, ez, callbackName, target, mask)
        local count = 0
        for _, tr in ipairs(trunks) do
            if math.abs(tr[1] - x) <= ex and math.abs(tr[2] - z) <= ez then count = count + 1 end
        end
        return count
    end
    T.foliageAvailable = function() return false end
    T.getLayerCellAt = function(x, z)
        if x >= 0 and x <= 64 and math.abs(z - 32) <= 1.5 then return nil, 1 end    -- dirt path (E-W through the grove)
        return nil, 2
    end
    local tree = T.scanLayerChunk(0, 0, 64)
    check("trees: one forest polygon from trunk counts alone (no forest layer)", tree ~= nil and #tree.forest == 1)
    check("trees: forest roughly the grove disc (area between 0.6x and 1.8x of a 16 m disc)", totalArea(tree.forest) > 0.6 * math.pi * 256 and totalArea(tree.forest) < 1.8 * math.pi * 256)
    local pathArea = totalArea(tree.trail)
    check("trees: the dirt path through the grove survives as a trail (about 3 x 64 = 192 m2)", pathArea > 110 and pathArea < 260)
    local loneTreeIsForest = false
    for _, p in ipairs(tree.forest) do
        local cx, cz = 0, 0
        for _, q in ipairs(p) do cx, cz = cx + q[1], cz + q[2] end
        if cx / #p > 50 then loneTreeIsForest = true end
    end
    check("trees: an isolated tree is not a forest", not loneTreeIsForest)
    overlapBox = nil
    T.getLayerCellAt = function() return nil, 2 end
    check("no overlapBox in the engine: no trees, chunk is empty", T.scanLayerChunk(0, 0, 64) == nil)
end


-- Stone hills: stone material on a layer of its own is built ground on flat land (the pad above) but a rock
-- face where it is steep. Flat stone x 4..20, steep stone x 24..44 (1 m rise per metre), flat stone x 48..60.
do
    T.foliageAvailable = function() return false end
    T.hasFoliageAt = function() return false end
    overlapBox = nil
    getTerrainHeightAtWorldPos = function(node, x, y, z)
        if x < 24 then return 100 end
        if x < 44 then return 100 + (x - 24) end
        return 120
    end
    T.getLayerCellAt = function(x, z)
        if z >= 20 and z <= 44 and x >= 4 and x <= 60 then return nil, 7 end
        return nil, 2
    end
    local hills = T.scanLayerChunk(0, 0, 64)
    local flatArea, steepLeak = 0, false
    for _, p in ipairs(hills.trail) do
        local cx, cz = 0, 0
        for _, q in ipairs(p) do cx, cz = cx + q[1], cz + q[2] end
        cx = cx / #p
        flatArea = flatArea + polygonArea(p)
        if cx > 26 and cx < 42 then steepLeak = true end
    end
    check("stone hills: the flat stone ground on both sides is still worn ground", flatArea > 200)
    check("stone hills: the steep stone slope is not drawn as worn ground", not steepLeak)
    getTerrainHeightAtWorldPos = function() return 100 end
end

finish("layer_scan_test")
