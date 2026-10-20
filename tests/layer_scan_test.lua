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

-- A lakebed: worn-looking dirt x, z 8..48; the water covers z >= 28 (mask from the building scan's ray)
do
    T.foliageAvailable = function() return true end
    T.hasFoliageAt = function() return false end
    T.getLayerCellAt = function(x, z)
        if x >= 8 and x <= 48 and z >= 8 and z <= 48 then return nil, 1 end
        return nil, 2
    end
    local dry = T.scanLayerChunk(0, 0, 64)
    local waterMask = {}
    for row = 0, 31 do
        waterMask[row] = {}
        for col = 0, 31 do waterMask[row][col] = (row + 0.5) * 2 >= 28 end
    end
    local wet = T.scanLayerChunk(0, 0, 64, waterMask)
    check("lakebed without a water mask: the whole 40 x 40 pad is a trail", totalArea(dry.trail) > 1400)
    check("lakebed with a water mask: only the dry half (20 x 40) is left", totalArea(wet.trail) > 600 and totalArea(wet.trail) < 900)
    local wetLowest = math.huge
    for _, p in ipairs(wet.trail) do for _, v in ipairs(p) do wetLowest = math.min(wetLowest, -v[2]) end end
    local maxZ = -math.huge
    for _, p in ipairs(wet.trail) do for _, v in ipairs(p) do maxZ = math.max(maxZ, v[2]) end end
    check("no trail polygon reaches into the water (z <= 29)", maxZ <= 29.5)
    local allWater = {}
    for row = 0, 31 do allWater[row] = {} for col = 0, 31 do allWater[row][col] = true end end
    check("a chunk fully under water has no trail", #T.scanLayerChunk(0, 0, 64, allWater).trail == 0)
end

-- tree probe: a trunk at (842.4, -531.3) on the global 4 m cell grid (origin -2048 for a 4096 m map)
do
    local trunkX, trunkZ = 842.4, -531.3
    overlapBox = function(x, y, z, rx, ry, rz, ex, ey, ez, cb, target, mask)
        local n = 0
        if math.abs(trunkX - x) <= ex and math.abs(trunkZ - z) <= ez then
            n = 1
            target[cb](target, 900)
        end
        return n
    end
    local count, cx, cz = T.logTreeProbe(842.19, -531.89)
    check("tree probe: the 4 m cell holding the point counts the trunk", count == 1)
    check("tree probe: cell centre sits on the global 4 m grid", (cx + 2048) % 4 == 2 and (cz + 2048) % 4 == 2)
    local farCount = T.logTreeProbe(900, -400)
    check("tree probe: an empty spot counts nothing", farCount == 0)
    overlapBox = nil
end

-- planted-tree list of the base game's TreePlantManager (growing + split), counted near a point
do
    g_treePlantManager = { treesData = {
        growingTrees = { { node = 1 }, { node = 2 } },
        splitTrees = { { node = 3 }, { node = 4 } },
    } }
    local positions = { [1] = { 100, -50 }, [2] = { 300, 0 }, [3] = { 103, -52 }, [4] = { 500, 500 } }
    getWorldTranslation = function(node) return positions[node][1], 0, positions[node][2] end
    entityExists = function() return true end
    local growing, split, nearby = T.countManagedTreesNear(100, -50, 8)
    check("manager trees: totals per list", growing == 2 and split == 2)
    check("manager trees: two of the four are within 8 m of the point", nearby == 2)
    g_treePlantManager = nil
    check("manager trees: no manager = nil", T.countManagedTreesNear(0, 0, 8) == nil)
end

-- tree dots: positions come from the overlap callback, the chunk keeps only its own trees
do
    local trunks = { { 10, 10 }, { 10.2, 10.1 }, { 30, 40 }, { 70, 20 }, { -5, 20 } }   -- 2 colliders of one tree, one in range, two outside the chunk
    getWorldTranslation = function(node) return trunks[node][1], 0, trunks[node][2] end
    overlapBox = function(x, y, z, rx, ry, rz, ex, ey, ez, cb, target)
        local n = 0
        for i, t in ipairs(trunks) do
            if math.abs(t[1] - x) <= ex and math.abs(t[2] - z) <= ez then
                n = n + 1
                target[cb](target, i)
            end
        end
        return n
    end
    local count, list, nodes = T.collectTrees(32, 32, 48, true)
    check("collect: every hit shape has a position", count == 5 and #list == 5)
    check("collect: distinct node ids are counted", nodes == 5)
    local trees = T.chunkTrees(list, 0, 0, 64)
    check("chunk keeps its own trees only (x 70 and x -5 are outside)", #trees == 2)
    check("two colliders of one tree are one dot (0.5 m merge): 10.0 and 30.0 remain", #trees == 2 and trees[1][1] == 10 and trees[2][1] == 30)
    local dots = T.treeDots({ { 10, 10 } })
    check("a dot is a hexagon of the dot radius", #dots == 1 and #dots[1] == 6 and math.abs(math.sqrt((dots[1][1][1] - 10) ^ 2 + (dots[1][1][2] - 10) ^ 2) - T.TREE_DOT_RADIUS) < 1e-9)
    check("a hexagon covers about 2.6 r^2 (area of a regular hexagon)", math.abs(polygonArea(dots[1]) / (2.598 * T.TREE_DOT_RADIUS ^ 2) - 1) < 0.01)
    overlapBox = nil
    local noneCount, noneList = T.collectTrees(0, 0, 10)
    check("without overlapBox: nothing, no error", noneCount == 0 and #noneList == 0)
end

-- A capped big query: the engine returns only a few results for a large box. Dots must still
-- come from the small per-cell queries.
do
    local trunks = {}
    for gx = 12, 52, 8 do
        for gz = 12, 52, 8 do trunks[#trunks + 1] = { gx, gz } end
    end                                                         -- 36 trunks, 8 m apart
    getWorldTranslation = function(node) return trunks[node][1], 0, trunks[node][2] end
    overlapBox = function(x, y, z, rx, ry, rz, ex, ey, ez, cb, target)
        local n, cap = 0, (ex > 20) and 3 or math.huge        -- the window query reports 3 shapes at most
        for i, t in ipairs(trunks) do
            if n < cap and math.abs(t[1] - x) <= ex and math.abs(t[2] - z) <= ez then
                n = n + 1
                target[cb](target, i)
            end
        end
        return n
    end
    T.foliageAvailable = function() return false end
    T.getLayerCellAt = function() return nil, 2 end
    local capped = T.scanLayerChunk(0, 0, 64)
    check("capped window query: every one of the 36 trunks is still a dot", capped ~= nil and #capped.trees == 36)
    check("capped window query: the window reported only its cap, the cells saw all", capped ~= nil and capped.treeShapes == 3 and capped.treeCellShapes >= 36)
    overlapBox = nil
end

-- Hillside: the window's centre terrain is at 100 m, a grove stands on a slope 40 m lower. The small
-- default box (10 m below, 40 m above the centre) cannot see it; the tall window box does.
do
    local baseHeight = getTerrainHeightAtWorldPos
    getTerrainHeightAtWorldPos = function(_, x, _, z) if x > 40 then return 60 end return 100 end
    local trunks = { { 50, 20 }, { 54, 24 }, { 58, 28 } }                 -- on the low ground, base at y = 60
    getWorldTranslation = function(node) return trunks[node][1], 60, trunks[node][2] end
    overlapBox = function(x, y, z, rx, ry, rz, ex, ey, ez, cb, target)
        local n = 0
        for i, t in ipairs(trunks) do
            if math.abs(t[1] - x) <= ex and math.abs(t[2] - z) <= ez and math.abs(60 - y) <= ey then
                n = n + 1
                target[cb](target, i)
            end
        end
        return n
    end
    local lowBox = T.countTrees(32, 32, 40)
    check("hillside: the default box centred on the window's terrain misses trees 40 m lower", lowBox == 0)
    local tallCount = T.collectTrees(32, 32, 40, false, T.TREE_WINDOW_HALF_HEIGHT)
    check("hillside: the tall window box finds all three", tallCount == 3)
    T.foliageAvailable = function() return false end
    T.getLayerCellAt = function() return nil, 2 end
    local chunk = T.scanLayerChunk(0, 0, 64)
    check("hillside: the chunk is not skipped as empty, and its trees are dots", chunk ~= nil and #chunk.trees == 3)
    getTerrainHeightAtWorldPos = baseHeight
    overlapBox = nil
end

finish("layer_scan_test")
