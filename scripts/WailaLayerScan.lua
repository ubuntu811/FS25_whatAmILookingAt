--[[
    WailaLayerScan.lua

    Whole-map scan driven by the learned terrain-layer classes
    (WailaTrailTracer.learnLayerClasses): ONE terrain read per cell gives the
    layer class (road / forest-floor / neither) and the material id, and the
    rest follows from shape.

      forest  = trees (trunk collision counted per 4m cell: the signal that works on
                any map, e.g. grass with trees) OR forest-floor-layer cells WITH foliage. The forest-floor layer alone
                is not enough: a parking lot or a worn path carries the same
                layer, but its foliage is empty (wear and placeables clear it)
      trail   = worn ground: dirt or gravel material outside the road layer and
                clear of the forest area (IW wear, yards, parking lots). Worn
                material is continuous where the layer signal fragments
      road    = the road layer, found by a 1m pass in chunks that have any
      building = the roof outline: a ray straight down from above lands on the
                roof, and a hit on a BUILDING collision body more than 1.5m above
                the terrain is a building cell (about 1.4us per ray, so a 2m grid
                over the whole map is a few seconds)

    Replaces the window forest classifier, the 1m border refinement and the 1m
    material scan for a whole-map pass; shares the overlays, the polygon store
    and the persistence with the original scan, so the two can be compared.
]]

-- Cells are 2m: roads are a separate 1m pass, and forest/trail polygons are
-- curve-fitted afterwards, so the coarser grid costs no visible precision.
WailaTrailTracer.LAYER_SCAN_CELL_SIZE = 2.0
-- Window halo around the 64m chunk, in cells: opening needs 2 * radius cells of
-- context so a structure straddling a chunk seam is classified the same way
-- from both sides.
WailaTrailTracer.LAYER_SCAN_HALO_CELLS = 4
-- Closing radius for the forest mask: foliage is patchy, a single missing sample
-- must not punch a hole in the forest.
WailaTrailTracer.LAYER_SCAN_FOREST_CLOSE_RADIUS = 1
-- Small worn patches stay this many cells away from the forest area (forest-floor dirt
-- among the trees is not a trail)...
WailaTrailTracer.LAYER_SCAN_TRAIL_EDGE_GAP_CELLS = 1
-- ...but a connected worn component of at least this many cells is a path or a yard, kept
-- wherever it lies: a path through the woods is a long strip, a floor patch is a blob.
WailaTrailTracer.LAYER_SCAN_TRAIL_KEEP_CELLS = 40
-- Position-independent island/hole rule (a component touching the window edge
-- is never judged, so seams are consistent): smaller than this is dropped.
WailaTrailTracer.LAYER_SCAN_MIN_AREA_CELLS = 25
-- Holes: a placeable on a yard or in a wood carries its own ground layer, so its
-- footprint is neither forest nor worn material and shows up as an island. An
-- ENCLOSED hole up to this size is filled (a hole touching the window edge never
-- is, so chunk seams stay consistent). Trail (yard) holes may be big: a placeable
-- footprint; forest holes smaller: a real clearing should stay a clearing.
WailaTrailTracer.LAYER_SCAN_TRAIL_MIN_HOLE_CELLS = 400
WailaTrailTracer.LAYER_SCAN_FOREST_MIN_HOLE_CELLS = 100
WailaTrailTracer.LAYER_SCAN_MIN_THIN_CELLS = 6
WailaTrailTracer.LAYER_SCAN_FOREST_TOLERANCE = 2.0
WailaTrailTracer.LAYER_SCAN_TRAIL_TOLERANCE = 1.0
-- materials that mean worn ground outside the learned classes (DIRT, GRAVEL)
local WORN_MATERIALS = { [1] = true, [6] = true }
function WailaTrailTracer.isWornMaterial(materialId)
    return WORN_MATERIALS[materialId] == true
end
local STONE_MATERIAL = 7

-- Trees: a standing tree has a static collision body with the TREE bit; overlapBox
-- returns the NUMBER of overlapping shapes, so one call per cell counts trunks.
-- A forest is where trunks are, however the ground under them was painted.
WailaTrailTracer.TREE_CELL_SIZE = 4.0
WailaTrailTracer.TREE_MIN_COUNT = 1
-- closing radius (in 2m cells) that joins the gaps between trunks into one area
WailaTrailTracer.TREE_CLOSE_RADIUS = 2
local TREE_BOX_HALF_HEIGHT = 25
-- the big per-chunk window query covers any elevation difference inside the window
WailaTrailTracer.TREE_WINDOW_HALF_HEIGHT = 250
local treeOverlapTarget = { seenNodes = nil, uniqueNodes = 0 }
function treeOverlapTarget:onTreeOverlap(nodeId)
    -- while collecting (collectTrees), every hit shape's position is recorded
    if self.collect ~= nil and nodeId ~= nil and nodeId ~= 0 then
        local x, _, z = getWorldTranslation(nodeId)
        self.collect[#self.collect + 1] = { x, z }
        if self.seenNodes ~= nil and not self.seenNodes[nodeId] then
            self.seenNodes[nodeId] = true
            self.uniqueNodes = self.uniqueNodes + 1
        end
    end
    return false
end

-- Same query as countTrees, but also returns the positions of the shapes it hit:
-- count, { {x, z}, ... }, number of distinct node ids. One shape per trunk is the normal case; a tree with more than
-- one collider is merged by position elsewhere (see dedupeTrees).
function WailaTrailTracer.collectTrees(x, z, half, trackNodes, halfHeight)
    if overlapBox == nil then
        return 0, {}
    end
    local list = {}
    treeOverlapTarget.collect = list
    treeOverlapTarget.seenNodes = trackNodes and {} or nil
    treeOverlapTarget.uniqueNodes = 0
    local count = WailaTrailTracer.countTrees(x, z, half, halfHeight)
    treeOverlapTarget.collect = nil
    treeOverlapTarget.seenNodes = nil
    return count, list, treeOverlapTarget.uniqueNodes
end

-- Trees inside the chunk [minX, minX + size) x [minZ, minZ + size) only (the query box
-- overlaps neighbours), one per 0.5 m cell so a tree with two colliders is drawn once.
function WailaTrailTracer.chunkTrees(list, minX, minZ, size)
    local seen, trees = {}, {}
    for _, p in ipairs(list) do
        if p[1] >= minX and p[1] < minX + size and p[2] >= minZ and p[2] < minZ + size then
            local key = math.floor(p[1] * 2) .. "_" .. math.floor(p[2] * 2)
            if not seen[key] then
                seen[key] = true
                trees[#trees + 1] = p
            end
        end
    end
    return trees
end

-- Tree dots for the map: one small hexagon per tree.
WailaTrailTracer.TREE_DOT_RADIUS = 2.5
function WailaTrailTracer.treeDots(trees)
    local polygons, r = {}, WailaTrailTracer.TREE_DOT_RADIUS
    for _, t in ipairs(trees) do
        local polygon = {}
        for i = 0, 5 do
            local a = i * math.pi / 3
            polygon[#polygon + 1] = { t[1] + r * math.cos(a), t[2] + r * math.sin(a) }
        end
        polygons[#polygons + 1] = polygon
    end
    return polygons
end

-- Number of tree trunks within a box of half-size `half` around (x, z); 0 if the
-- engine function is missing.
-- halfHeight (optional): a tall box for big windows. The default box reaches 10 m below and 40 m above
-- the terrain at its own centre, fine for a 4 m cell but not for an 80 m window over a slope, where trees
-- standing lower than that were invisible; a given halfHeight is centred on the terrain itself.
function WailaTrailTracer.countTrees(x, z, half, halfHeight)
    if overlapBox == nil then
        return 0
    end
    local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + (halfHeight and 0 or 15)
    return overlapBox(x, y, z, 0, 0, 0, half, halfHeight or TREE_BOX_HALF_HEIGHT, half, "onTreeOverlap", treeOverlapTarget, CollisionFlag.TREE, false, false, true, false) or 0
end

--- Debug probe (Terrain tab, aimed at a tree): what the forest scan's own overlapBox query says
--- about the spot. Logs the trunk count in the 4 m scan cell that contains (x, z) -- cells
--- sit on a global grid from the map corner -- and in boxes of a few other sizes, and says
--- whether the scan would mark the cell as trees. Returns the 4 m cell's count and centre.
-- Lists what a box query finds: node id, name, and whether it is a cut-up split shape
-- (a stump keeps the TREE bit; the base game's own tree finder skips split shapes).
local probeTarget = { hits = {} }
function probeTarget:onProbeOverlap(nodeId)
    local entry = tostring(nodeId)
    if getName ~= nil then
        local ok, name = pcall(getName, nodeId)
        if ok then entry = entry .. " " .. tostring(name) end
    end
    if getHasClassId ~= nil and ClassIds ~= nil and ClassIds.MESH_SPLIT_SHAPE ~= nil then
        local ok, isMesh = pcall(getHasClassId, nodeId, ClassIds.MESH_SPLIT_SHAPE)
        if ok then entry = entry .. (isMesh and " (split shape)" or " (NOT a split shape)") end
    end
    if getIsSplitShapeSplit ~= nil then
        local ok, split = pcall(getIsSplitShapeSplit, nodeId)
        if ok then entry = entry .. (split and " [split: stump or cut]" or " [intact]") end
    end
    table.insert(self.hits, entry)
    return false
end

-- How many of the base game's own tracked trees (TreePlantManager: only trees planted at
-- runtime or restored from the savegame, not the ones authored into the map) sit within
-- `radius` of (x, z). Returns total growing, total split, and the number nearby.
function WailaTrailTracer.countManagedTreesNear(x, z, radius)
    local manager = g_treePlantManager
    if manager == nil or manager.treesData == nil then
        return nil
    end
    local nearby = 0
    local function scan(list)
        for _, tree in pairs(list or {}) do
            if tree.node ~= nil and (entityExists == nil or entityExists(tree.node)) then
                local tx, _, tz = getWorldTranslation(tree.node)
                if math.abs(tx - x) <= radius and math.abs(tz - z) <= radius then
                    nearby = nearby + 1
                end
            end
        end
    end
    scan(manager.treesData.growingTrees)
    scan(manager.treesData.splitTrees)
    return #(manager.treesData.growingTrees or {}), #(manager.treesData.splitTrees or {}), nearby
end

-- Every static collider near the point, whatever its bits (the terrain excluded): node id,
-- name, parent name, collision group. For finding out what a tree-like object that the
-- TREE-bit query misses (a palm) really is.
local allTarget = { hits = {} }
function allTarget:onAllOverlap(nodeId)
    if #self.hits >= 30 then
        return false
    end
    local group = 0
    if getCollisionFilterGroup ~= nil then
        local ok, g = pcall(getCollisionFilterGroup, nodeId)
        if ok and g ~= nil then group = g end
    end
    if group == 0x100 then
        return false -- the terrain
    end
    local name, parentName = "?", "?"
    if getName ~= nil then
        local ok, n = pcall(getName, nodeId)
        if ok then name = tostring(n) end
        if getParent ~= nil then
            local okParent, parent = pcall(getParent, nodeId)
            if okParent and parent ~= nil and parent ~= 0 then
                local okName, pn = pcall(getName, parent)
                if okName then parentName = tostring(pn) end
            end
        end
    end
    -- how tall it is, what it is made of: a standing tree is many metres, a stump (the lower part of a cut tree's own split shape) about one, and the tree type says what it was
    local height, species, body = "?", "?", "?"
    local okBox, minX, maxX, minY, maxY = pcall(getRigidBodyAABB, nodeId)
    if okBox and minY ~= nil and maxY ~= nil then
        height = string.format("%.1f", maxY - minY)
    end
    local okType, splitType = pcall(getSplitType, nodeId)
    if okType and splitType ~= nil and splitType ~= 0 then
        species = tostring(splitType)
        local desc = g_treePlantManager ~= nil and g_treePlantManager.getTreeTypeDescFromSplitType ~= nil and g_treePlantManager:getTreeTypeDescFromSplitType(splitType) or nil
        if desc ~= nil then
            species = tostring(desc.name)
        end
    end
    local okBody, bodyType = pcall(getRigidBodyType, nodeId)
    if okBody and bodyType ~= nil then
        body = tostring(bodyType)
    end
    table.insert(self.hits, string.format("%s %s <- %s [group 0x%X] %s m tall, split type %s, rigid body %s", tostring(nodeId), name, parentName, group, height, species, body))
    return false
end

function WailaTrailTracer.logTreeProbe(x, z)
    local terrainSize = (g_currentMission ~= nil and g_currentMission.terrainSize) or 2048
    local origin = -terrainSize * 0.5
    local cellSize = WailaTrailTracer.TREE_CELL_SIZE
    local cx = origin + (math.floor((x - origin) / cellSize) + 0.5) * cellSize
    local cz = origin + (math.floor((z - origin) / cellSize) + 0.5) * cellSize
    local inCell = WailaTrailTracer.countTrees(cx, cz, cellSize * 0.5)
    Logging.info("[WhatAmILookingAt] [LayerScan] tree probe at (%.1f, %.1f): scan cell %.0fm centred (%.1f, %.1f) holds %d trunk(s) -> %s; boxes around the point: 1m=%d 2m=%d 4m=%d 8m=%d",
        x, z, cellSize, cx, cz, inCell, inCell >= WailaTrailTracer.TREE_MIN_COUNT and "the scan marks it as trees" or "the scan does NOT mark it",
        WailaTrailTracer.countTrees(x, z, 1), WailaTrailTracer.countTrees(x, z, 2), WailaTrailTracer.countTrees(x, z, 4), WailaTrailTracer.countTrees(x, z, 8))
    local growing, split, nearby = WailaTrailTracer.countManagedTreesNear(x, z, 8)
    if growing ~= nil then
        Logging.info("[WhatAmILookingAt] [LayerScan] tree probe TreePlantManager: %d growing + %d split trees tracked in total, %d within 8m of the point",
            growing, split, nearby)
    else
        Logging.info("[WhatAmILookingAt] [LayerScan] tree probe TreePlantManager: not available")
    end
    if overlapBox ~= nil then
        probeTarget.hits = {}
        local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 15
        overlapBox(x, y, z, 0, 0, 0, 8, TREE_BOX_HALF_HEIGHT, 8, "onProbeOverlap", probeTarget, CollisionFlag.TREE, false, false, true, false)
        Logging.info("[WhatAmILookingAt] [LayerScan] tree probe shapes within 8m: %s", #probeTarget.hits > 0 and table.concat(probeTarget.hits, "; ") or "none")
        allTarget.hits = {}
        overlapBox(x, y, z, 0, 0, 0, 8, TREE_BOX_HALF_HEIGHT, 8, "onAllOverlap", allTarget, 0xFFFFFFFF, false, false, true, false)
        Logging.info("[WhatAmILookingAt] [LayerScan] tree probe ALL static colliders within 8m (any bit, first 30): %s", #allTarget.hits > 0 and table.concat(allTarget.hits, "; ") or "none")
    end
    return inCell, cx, cz
end

-- Rock: the same stone layer that is a placeable's flat pad on one map is a cliff or
-- a stone hill on another (Pirambeiras: the big scenic hills read as stone, single
-- layer, nothing else). A pad is flat, a rock face is steep: stone ground steeper than
-- this (rise over run across one cell) is left to the base map, not drawn as built ground.
WailaTrailTracer.LAYER_SCAN_ROCK_SLOPE = 0.45

local function isSteepAt(x, z, cell)
    local h0 = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    local hx = getTerrainHeightAtWorldPos(g_terrainNode, x + cell, 0, z)
    local hz = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z + cell)
    return math.max(math.abs(hx - h0), math.abs(hz - h0)) / cell > WailaTrailTracer.LAYER_SCAN_ROCK_SLOPE
end

-- Worn / built ground: dirt or gravel material, or stone material on a layer that
-- is neither road nor forest floor. The second case is a placeable's own ground
-- (a factory pad is a gray stone layer of its own): built ground belongs to the
-- yard around it however big it is, which a hole-size rule can never promise.
local function isWornCell(class, materialId, roadClass)
    if class == roadClass then
        return false
    end
    return WORN_MATERIALS[materialId] == true or (class == nil and materialId == STONE_MATERIAL)
end
-- closing radius that joins gaps in a worn path
WailaTrailTracer.LAYER_SCAN_TRAIL_CLOSE_RADIUS = 1

-- shared empty "protected" grid for the component cleaner (nothing is protected)
local noProtectedRows = setmetatable({}, { __index = function() return {} end })

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] [LayerScan] " .. formatString, ...)
end

-- Square-kernel dilate / erode, separable, with sliding-window counts (one
-- prefix sum per line). Cells outside the window are skipped, not treated as empty.
local function filterLine(line, n, radius, dilate)
    local prefix = { [-1] = 0 }
    for i = 0, n - 1 do
        prefix[i] = prefix[i - 1] + (line[i] and 1 or 0)
    end
    local out = {}
    for i = 0, n - 1 do
        local lo, hi = math.max(0, i - radius), math.min(n - 1, i + radius)
        local count = prefix[hi] - prefix[lo - 1]
        if dilate then
            out[i] = count > 0
        else
            out[i] = count == hi - lo + 1
        end
    end
    return out
end

local function separableFilter(mask, n, radius, dilate)
    local rows = {}
    for row = 0, n - 1 do
        rows[row] = filterLine(mask[row], n, radius, dilate)
    end
    local result = {}
    for row = 0, n - 1 do
        result[row] = {}
    end
    for col = 0, n - 1 do
        local column = {}
        for row = 0, n - 1 do
            column[row] = rows[row][col]
        end
        local filtered = filterLine(column, n, radius, dilate)
        for row = 0, n - 1 do
            result[row][col] = filtered[row]
        end
    end
    return result
end

local function dilateMask(mask, n, radius)
    return separableFilter(mask, n, radius, true)
end

local function erodeMask(mask, n, radius)
    return separableFilter(mask, n, radius, false)
end

local function newMask(n, value)
    local mask = {}
    for row = 0, n - 1 do
        local line = {}
        for col = 0, n - 1 do
            line[col] = value
        end
        mask[row] = line
    end
    return mask
end

local function cropInner(mask, halo, n)
    local inner = {}
    for row = 0, n - 1 do
        local line, source = {}, mask[row + halo]
        for col = 0, n - 1 do
            line[col] = source[col + halo]
        end
        inner[row] = line
    end
    return inner
end

-- Classifies one 64m chunk. Returns { forest = polygons, trail = polygons,
-- road = polygons } or nil if the chunk holds no learned layer at all.
-- waterMask (optional, n x n inner cells, from scanBuildingChunk): trail cells on
-- water are dropped.
function WailaTrailTracer.scanLayerChunk(minX, minZ, chunkSize, waterMask)
    local cell = WailaTrailTracer.LAYER_SCAN_CELL_SIZE
    local halo = WailaTrailTracer.LAYER_SCAN_HALO_CELLS
    local n = math.floor(chunkSize / cell)
    local w = n + 2 * halo
    local winX, winZ = minX - halo * cell, minZ - halo * cell
    local half = ((g_currentMission ~= nil and g_currentMission.terrainSize) or 2048) * 0.5
    local roadClass, forestClass = WailaTrailTracer.LAYER_CLASS_ROAD, WailaTrailTracer.LAYER_CLASS_FOREST
    local cellAt = WailaTrailTracer.getLayerCellAt

    -- trees: one overlap query over the whole window says whether any trunk is here
    local windowHalf = w * cell * 0.5
    local windowTreeCount, windowTrees, windowTreeNodes = WailaTrailTracer.collectTrees(winX + windowHalf, winZ + windowHalf, windowHalf, true, WailaTrailTracer.TREE_WINDOW_HALF_HEIGHT)
    -- positions also come from the per-cell queries below (small boxes, so a cap on the
    -- results of the big window query cannot hide trees); both lists are merged at the end
    local cellTrees, cellShapes = {}, 0
    local treesInWindow = windowTreeCount > 0

    -- prefilter: every 2nd cell in both axes; most chunks hold nothing
    local anyHit = treesInWindow
    for row = 0, w - 1, 2 do
        if anyHit then
            break
        end
        local z = winZ + (row + 0.5) * cell
        if z > -half and z < half then
            for col = 0, w - 1, 2 do
                local x = winX + (col + 0.5) * cell
                if x > -half and x < half then
                    local class, materialId = cellAt(x, z)
                    if class ~= nil or isWornCell(class, materialId, roadClass) then
                        anyHit = true
                        break
                    end
                end
            end
        end
        if anyHit then
            break
        end
    end
    if not anyHit then
        return nil
    end

    -- one terrain read per window cell (+ the foliage planes for forest-layer cells)
    local useFoliage = WailaTrailTracer.foliageAvailable()
    local hasFoliageAt = WailaTrailTracer.hasFoliageAt
    local forestMask, wornMask = {}, {}
    local roadInChunk, forestCells, wornCells = false, 0, 0

    -- tree cells (4m): a cell with enough trunks marks its 2m cells; closed below
    local treeMask = nil
    if treesInWindow then
        treeMask = newMask(w, false)
        local treeCell = WailaTrailTracer.TREE_CELL_SIZE
        local per = math.max(1, math.floor(treeCell / cell + 0.5))
        local treeHalf = treeCell * 0.5
        local minCount = WailaTrailTracer.TREE_MIN_COUNT
        for row = 0, w - 1, per do
            local z = winZ + (row + per * 0.5) * cell
            if z > -half and z < half then
                for col = 0, w - 1, per do
                    local x = winX + (col + per * 0.5) * cell
                    local cellCount, cellList = 0, nil
                    if x > -half and x < half then
                        cellCount, cellList = WailaTrailTracer.collectTrees(x, z, treeHalf)
                        cellShapes = cellShapes + cellCount
                        for _, p in ipairs(cellList) do
                            cellTrees[#cellTrees + 1] = p
                        end
                    end
                    if cellCount >= minCount then
                        for dr = 0, per - 1 do
                            for dc = 0, per - 1 do
                                if row + dr < w and col + dc < w then
                                    treeMask[row + dr][col + dc] = true
                                end
                            end
                        end
                    end
                end
            end
        end
        local closeRadius = WailaTrailTracer.TREE_CLOSE_RADIUS
        if closeRadius > 0 then
            treeMask = erodeMask(dilateMask(treeMask, w, closeRadius), w, closeRadius)
        end
    end

    for row = 0, w - 1 do
        local line, wornLine = {}, {}
        local z = winZ + (row + 0.5) * cell
        for col = 0, w - 1 do
            local x = winX + (col + 0.5) * cell
            local isForest, worn = false, false
            if x > -half and x < half and z > -half and z < half then
                local class, materialId = cellAt(x, z)
                worn = isWornCell(class, materialId, roadClass)
                if worn and class == nil and materialId == STONE_MATERIAL and isSteepAt(x, z, cell) then
                    worn = false
                end
                isForest = class == forestClass and (not useFoliage or hasFoliageAt(x, z))
                if (isForest or worn) and FSDensityMapUtil.getFieldDataAtWorldPosition(x, 0, z) then
                    isForest, worn = false, false
                elseif class == roadClass and row >= halo and row < halo + n and col >= halo and col < halo + n then
                    roadInChunk = true
                end
            end
            if treeMask ~= nil and treeMask[row][col] then
                isForest = true
            end
            line[col] = isForest
            wornLine[col] = worn
            if isForest then
                forestCells = forestCells + 1
            end
            if worn then
                wornCells = wornCells + 1
            end
        end
        forestMask[row] = line
        wornMask[row] = wornLine
    end

    local result = { forest = {}, trail = {}, road = {}, trees = nil,
        treeShapes = windowTreeCount, treeCallbacks = #windowTrees, treeNodes = windowTreeNodes, treeCellShapes = cellShapes }
    do
        local merged = {}
        for _, p in ipairs(windowTrees) do merged[#merged + 1] = p end
        for _, p in ipairs(cellTrees) do merged[#merged + 1] = p end
        result.trees = WailaTrailTracer.chunkTrees(merged, minX, minZ, chunkSize)
    end

    if forestCells > 0 or wornCells > 0 then
        local area = forestMask
        if forestCells > 0 then
            local closeRadius = WailaTrailTracer.LAYER_SCAN_FOREST_CLOSE_RADIUS
            if closeRadius > 0 then
                area = erodeMask(dilateMask(forestMask, w, closeRadius), w, closeRadius)
            end
            WailaTrailTracer.cleanComponents(area, noProtectedRows, w, WailaTrailTracer.LAYER_SCAN_MIN_AREA_CELLS, WailaTrailTracer.LAYER_SCAN_FOREST_MIN_HOLE_CELLS)
        end

        -- trail = worn material clear of the forest area's edge
        local trail, trailCells = wornMask, wornCells
        if wornCells > 0 then
            if forestCells > 0 then
                local near = dilateMask(area, w, WailaTrailTracer.LAYER_SCAN_TRAIL_EDGE_GAP_CELLS)
                -- the big worn components, kept even inside the forest area's margin
                local big = newMask(w, false)
                for row = 0, w - 1 do
                    for col = 0, w - 1 do
                        big[row][col] = wornMask[row][col]
                    end
                end
                WailaTrailTracer.cleanComponents(big, noProtectedRows, w, WailaTrailTracer.LAYER_SCAN_TRAIL_KEEP_CELLS, 0)
                trail, trailCells = newMask(w, false), 0
                for row = 0, w - 1 do
                    for col = 0, w - 1 do
                        if wornMask[row][col] and (big[row][col] or not near[row][col]) then
                            trail[row][col] = true
                            trailCells = trailCells + 1
                        end
                    end
                end
            end
            if trailCells > 0 then
                local closeRadius = WailaTrailTracer.LAYER_SCAN_TRAIL_CLOSE_RADIUS
                if closeRadius > 0 then
                    trail = erodeMask(dilateMask(trail, w, closeRadius), w, closeRadius)
                end
                WailaTrailTracer.cleanComponents(trail, noProtectedRows, w, WailaTrailTracer.LAYER_SCAN_MIN_THIN_CELLS, WailaTrailTracer.LAYER_SCAN_TRAIL_MIN_HOLE_CELLS)
            end
        end

        if forestCells > 0 then
            result.forest = WailaTrailTracer.traceMaskPolygons(cropInner(area, halo, n), minX, minZ, n, cell, WailaTrailTracer.LAYER_SCAN_FOREST_TOLERANCE)
        end
        if trailCells > 0 then
            local innerTrail = cropInner(trail, halo, n)
            if waterMask ~= nil then
                local removed = false
                for row = 0, n - 1 do
                    for col = 0, n - 1 do
                        if waterMask[row][col] and innerTrail[row][col] then
                            innerTrail[row][col] = false
                            removed = true
                        end
                    end
                end
                if removed then
                    WailaTrailTracer.cleanComponents(innerTrail, noProtectedRows, n, WailaTrailTracer.LAYER_SCAN_MIN_THIN_CELLS, 0)
                end
            end
            result.trail = WailaTrailTracer.traceMaskPolygons(innerTrail, minX, minZ, n, cell, WailaTrailTracer.LAYER_SCAN_TRAIL_TOLERANCE)
        end
    end

    if roadInChunk then
        result.road = WailaTrailTracer.scanRoadLayerChunk(minX, minZ, chunkSize)
    end

    return result
end

-- ===== Buildings by raycast =====
-- Real finding (placeable probe on the cement factory): the walls' rigid-body boxes
-- are far bigger than the building, but a downward ray lands on the roof and the
-- BUILDING hits trace the true, stepped outline. Measured: 3,581 rays in 5ms.
-- Real finding (Estancia Lapacho harbour): buildings baked into the map file
-- (node silosLOD) are group STATIC_OBJECT | PLACEMENT_BLOCKING with no BUILDING bit,
-- so the same ray also accepts STATIC_OBJECT hits. Statics are also fences, poles
-- and props: those need to be tall, and are only kept where the footprint is thick
-- (an opening removes anything 4 m wide or less) and large.
WailaTrailTracer.BUILDING_CELL_SIZE = 2.0
WailaTrailTracer.BUILDING_RAY_START_ABOVE = 60
WailaTrailTracer.BUILDING_MIN_HEIGHT = 1.5
WailaTrailTracer.BUILDING_MIN_CELLS = 4
WailaTrailTracer.BUILDING_MIN_HOLE_CELLS = 16
WailaTrailTracer.STATIC_MIN_HEIGHT = 2.5
WailaTrailTracer.STATIC_OPEN_RADIUS = 1
WailaTrailTracer.STATIC_MIN_CELLS = 12
-- Water: the same ray also accepts the WATER bit (Estancia: lake and river carry a
-- WATER plane). A cell is water when the plane is this far above the terrain; the mask
-- is grown a cell so the wet lakebed fringe goes too. Used to keep worn-ground
-- "trails" off lakebeds (the dirt/gravel material under a river reads as a path).
WailaTrailTracer.WATER_MIN_DEPTH = 0.15
WailaTrailTracer.WATER_GROW_CELLS = 1
WailaTrailTracer.WATER_MIN_CELLS = 6
WailaTrailTracer.WATER_MIN_HOLE_CELLS = 16
WailaTrailTracer.WATER_CURVE_TOLERANCE = 1.0

local buildingRayTarget = {}
function buildingRayTarget:onBuildingRayCallback(hitObjectId, x, y)
    if hitObjectId ~= nil and hitObjectId ~= 0 then
        self.hitNode, self.hitY = hitObjectId, y
    end
    return false
end

-- Building polygons for one chunk (curve-fitted loops; corners are kept by the fit).
-- Second return: the chunk's water mask (n x n, grown by a cell, for keeping trails off
-- lakebeds), nil when there is no water. Third: the water polygons (drawn as the water layer).
function WailaTrailTracer.scanBuildingChunk(minX, minZ, chunkSize)
    local cell = WailaTrailTracer.BUILDING_CELL_SIZE
    local n = math.floor(chunkSize / cell)
    local above = WailaTrailTracer.BUILDING_RAY_START_ABOVE
    local minHeight = WailaTrailTracer.BUILDING_MIN_HEIGHT
    local staticMinHeight = WailaTrailTracer.STATIC_MIN_HEIGHT
    local rayMask = bit32.bor(bit32.bor(CollisionFlag.BUILDING, CollisionFlag.STATIC_OBJECT), CollisionFlag.WATER)
    local waterDepth = WailaTrailTracer.WATER_MIN_DEPTH
    local mask, staticMask, waterMask, count, staticCount, waterCount = {}, {}, {}, 0, 0, 0
    for row = 0, n - 1 do
        local line, staticLine, waterLine = {}, {}, {}
        local z = minZ + (row + 0.5) * cell
        for col = 0, n - 1 do
            local x = minX + (col + 0.5) * cell
            local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
            buildingRayTarget.hitNode, buildingRayTarget.hitY = nil, nil
            raycastClosest(x, terrainY + above, z, 0, -1, 0, above + 5, "onBuildingRayCallback", buildingRayTarget, rayMask)
            local hit, staticHit, waterHit = false, false, false
            local node = buildingRayTarget.hitNode
            if node ~= nil then
                local height = buildingRayTarget.hitY - terrainY
                if CollisionFlag.getHasGroupFlagSet(node, CollisionFlag.WATER) then
                    -- a plane below the terrain (every land cell sees one) is no water
                    waterHit = height > waterDepth
                elseif height > minHeight and CollisionFlag.getHasGroupFlagSet(node, CollisionFlag.BUILDING) then
                    hit = true
                elseif height > staticMinHeight then
                    staticHit = true
                end
            end
            line[col] = hit
            staticLine[col] = staticHit
            waterLine[col] = waterHit
            if waterHit then
                waterCount = waterCount + 1
            end
            if hit then
                count = count + 1
            end
            if staticHit then
                staticCount = staticCount + 1
            end
        end
        mask[row] = line
        staticMask[row] = staticLine
        waterMask[row] = waterLine
    end

    local waterPolygons = {}
    if waterCount > 0 then
        local grown = dilateMask(waterMask, n, WailaTrailTracer.WATER_GROW_CELLS)
        -- the water layer is drawn from the true (ungrown) water cells, cleaned
        WailaTrailTracer.cleanComponents(waterMask, noProtectedRows, n, WailaTrailTracer.WATER_MIN_CELLS, WailaTrailTracer.WATER_MIN_HOLE_CELLS)
        waterPolygons = WailaTrailTracer.traceMaskPolygons(waterMask, minX, minZ, n, cell, WailaTrailTracer.WATER_CURVE_TOLERANCE)
        waterMask = grown
    else
        waterMask = nil
    end

    if staticCount > 0 then
        local radius = WailaTrailTracer.STATIC_OPEN_RADIUS
        staticMask = dilateMask(erodeMask(staticMask, n, radius), n, radius)
        WailaTrailTracer.cleanComponents(staticMask, noProtectedRows, n, WailaTrailTracer.STATIC_MIN_CELLS, 0)
        for row = 0, n - 1 do
            for col = 0, n - 1 do
                if staticMask[row][col] and not mask[row][col] then
                    mask[row][col] = true
                    count = count + 1
                end
            end
        end
    end

    if count == 0 then
        return {}, waterMask, waterPolygons
    end
    -- roof gaps (a ray between two roof parts) close; tiny specks go
    mask = erodeMask(dilateMask(mask, n, 1), n, 1)
    WailaTrailTracer.cleanComponents(mask, noProtectedRows, n, WailaTrailTracer.BUILDING_MIN_CELLS, WailaTrailTracer.BUILDING_MIN_HOLE_CELLS)
    return WailaTrailTracer.traceMaskPolygons(mask, minX, minZ, n, cell, WailaTrailTracer.BUILDING_LAYER_CURVE_TOLERANCE), waterMask, waterPolygons
end

-- ===== Roads by raycast (maps whose road meshes carry the ROAD collision bit) =====
-- Real finding (Estancia Lapacho): the asphalt is a mesh node in collision group
-- ROAD | AI_DRIVABLE, 0.1 m above the terrain, while its paint is the same as the
-- surrounding ground, so no learned layer can see it. WAILA's own crosshair reads
-- it from the collision stack; the scan can ask the same thing with a downward ray.
-- Not every map has it (CreativeHorizon's roads are terrain decals), so each map
-- is probed along its road splines first.
WailaTrailTracer.ROAD_RAY_CELL_SIZE = 2.0
WailaTrailTracer.ROAD_RAY_PREFILTER_STRIDE = 4.0
WailaTrailTracer.ROAD_RAY_START_ABOVE = 5.0
WailaTrailTracer.ROAD_RAY_LENGTH = 10.0
WailaTrailTracer.ROAD_RAY_PROBE_MIN_SHARE = 0.5
WailaTrailTracer.ROAD_RAY_PROBE_MAX_SAMPLES = 400
WailaTrailTracer.ROAD_RAY_MIN_CELLS = 6
WailaTrailTracer.ROAD_RAY_MIN_HOLE_CELLS = 16
WailaTrailTracer.ROAD_RAY_CURVE_TOLERANCE = 0.7

local roadRayTarget = {}
function roadRayTarget:onRoadRayCallback(hitObjectId)
    if hitObjectId ~= nil and hitObjectId ~= 0 then
        self.hit = true
    end
    return false
end

local function roadRayHitsAt(x, z)
    local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    roadRayTarget.hit = false
    raycastClosest(x, terrainY + WailaTrailTracer.ROAD_RAY_START_ABOVE, z, 0, -1, 0, WailaTrailTracer.ROAD_RAY_LENGTH, "onRoadRayCallback", roadRayTarget, CollisionFlag.ROAD)
    return roadRayTarget.hit
end

-- Share of road-spline samples that sit on a ROAD collider; a map where most of
-- them do has collision roads and the raycast pass is used.
function WailaTrailTracer.probeRoadCollision(chains)
    local total = 0
    for _, chain in ipairs(chains) do
        total = total + #chain
    end
    if total == 0 then
        return 0, 0, 0
    end
    local every = math.max(1, math.ceil(total / WailaTrailTracer.ROAD_RAY_PROBE_MAX_SAMPLES))
    local tested, hits, index = 0, 0, 0
    for _, chain in ipairs(chains) do
        for _, point in ipairs(chain) do
            index = index + 1
            if index % every == 0 then
                tested = tested + 1
                if roadRayHitsAt(point[1], point[2]) then
                    hits = hits + 1
                end
            end
        end
    end
    return tested > 0 and hits / tested or 0, hits, tested
end

-- Road polygons for one chunk: 4 m prefilter, then a 2 m grid, closed and traced.
function WailaTrailTracer.scanRoadRayChunk(minX, minZ, chunkSize)
    local stride = WailaTrailTracer.ROAD_RAY_PREFILTER_STRIDE
    local anyHit = false
    for dz = stride * 0.5, chunkSize, stride do
        for dx = stride * 0.5, chunkSize, stride do
            if roadRayHitsAt(minX + dx, minZ + dz) then
                anyHit = true
                break
            end
        end
        if anyHit then
            break
        end
    end
    if not anyHit then
        return {}
    end

    local cell = WailaTrailTracer.ROAD_RAY_CELL_SIZE
    local n = math.floor(chunkSize / cell)
    local mask, count = {}, 0
    for row = 0, n - 1 do
        local line = {}
        local z = minZ + (row + 0.5) * cell
        for col = 0, n - 1 do
            local hit = roadRayHitsAt(minX + (col + 0.5) * cell, z)
            line[col] = hit
            if hit then
                count = count + 1
            end
        end
        mask[row] = line
    end
    if count == 0 then
        return {}
    end
    mask = erodeMask(dilateMask(mask, n, 1), n, 1)
    WailaTrailTracer.cleanComponents(mask, noProtectedRows, n, WailaTrailTracer.ROAD_RAY_MIN_CELLS, WailaTrailTracer.ROAD_RAY_MIN_HOLE_CELLS)
    return WailaTrailTracer.traceMaskPolygons(mask, minX, minZ, n, cell, WailaTrailTracer.ROAD_RAY_CURVE_TOLERANCE)
end

-- ===== Roads from splines (maps whose paint does not show roads) =====
WailaTrailTracer.ROAD_SPLINE_FALLBACK_WIDTH = 6.0
WailaTrailTracer.ROAD_SPLINE_FALLBACK_STEP = 6.0

function WailaTrailTracer.collectRoadSplineChains()
    local chains = {}
    if g_currentMission ~= nil and g_currentMission.aiSystem ~= nil then
        for spline in pairs(g_currentMission.aiSystem:getRoadSplines()) do
            local chain = WailaTrailTracer.sampleSplineChain(spline, WailaTrailTracer.ROAD_SPLINE_FALLBACK_STEP)
            if chain ~= nil and #chain >= 2 then
                table.insert(chains, chain)
            end
        end
    end
    return chains
end

-- The map's own road splines as paths (kind "spline", not saved: rebuilt every session), so the road
-- follower and anything else that asks the path store finds them next to recorded drives. Done once
-- per session, on the first request. Each is sampled every 4 m in the spline's own direction.
WailaTrailTracer.PATH_SPLINE_STEP = 4.0
function WailaPathStore.importMapSplines()
    if WailaPathStore.mapSplinesImported then
        return 0
    end
    WailaPathStore.mapSplinesImported = true
    local count = 0
    if g_currentMission ~= nil and g_currentMission.aiSystem ~= nil then
        for spline in pairs(g_currentMission.aiSystem:getRoadSplines()) do
            local chain = WailaTrailTracer.sampleSplineChain(spline, WailaTrailTracer.PATH_SPLINE_STEP)
            if chain ~= nil and #chain >= 2 then
                local id = WailaPathStore.add({
                    points = chain, kind = "spline", source = "map", name = "road spline",
                    width = WailaTrailTracer.ROAD_SPLINE_FALLBACK_WIDTH, oneWay = false, transient = true,
                })
                if id ~= nil then
                    count = count + 1
                end
            end
        end
    end
    Logging.info("[WhatAmILookingAt] [Paths] imported %d map road spline(s) as paths", count)
    return count
end

-- ===== Probe: what are the map's road and traffic splines? =====
-- Debug (Terrain tab). Answers, from real map data: are the splines one centre-line per road or
-- one per lane, does their direction mean anything (paired splines running opposite ways), and what
-- else do the AI and traffic systems hold. Writes <savegame>/wailaSplines.xml (every road spline as a
-- point list, 5 m apart, in the spline's own direction) and logs the fields and methods of the
-- engine objects. The game deletes unknown savegame files on its next save, so read it before that.
WailaTrailTracer.SPLINE_DUMP_STEP = 5.0
WailaTrailTracer.SPLINE_DUMP_MAX_POINTS = 600

local function describeEngineObject(label, object)
    if object == nil then
        log("spline probe: %s is nil", label)
        return
    end
    local fields = {}
    for key, value in pairs(object) do
        local kind = type(value)
        if kind == "table" then
            local count = 0
            for _ in pairs(value) do count = count + 1 end
            kind = "table[" .. count .. "]"
        end
        fields[#fields + 1] = tostring(key) .. ":" .. kind
    end
    table.sort(fields)
    log("spline probe: %s fields: %s", label, table.concat(fields, ", "))
    local meta = getmetatable(object)
    local class = meta ~= nil and type(meta.__index) == "table" and meta.__index or nil
    if class ~= nil then
        local methods = {}
        for key, value in pairs(class) do
            if type(value) == "function" then methods[#methods + 1] = tostring(key) end
        end
        table.sort(methods)
        log("spline probe: %s methods (%d): %s", label, #methods, table.concat(methods, ", "))
    end
end

local function splinePointsString(spline)
    local length = getSplineLength(spline)
    if length == nil or length <= 0 then
        return nil, length
    end
    local step = math.max(WailaTrailTracer.SPLINE_DUMP_STEP, length / WailaTrailTracer.SPLINE_DUMP_MAX_POINTS)
    local parts = {}
    for distance = 0, length + step, step do
        local x, _, z = getSplinePosition(spline, math.min(distance / length, 1))
        parts[#parts + 1] = string.format("%.1f %.1f", x, z)
    end
    return table.concat(parts, " "), length
end

local function nodeName(node)
    local ok, name = pcall(getName, node)
    return ok and tostring(name) or "?"
end

function WailaTrailTracer.dumpRoadSplines()
    local mission = g_currentMission
    if mission == nil or mission.missionInfo == nil or mission.missionInfo.savegameDirectory == nil then
        log("spline probe: no mission / savegame directory")
        return
    end
    describeEngineObject("aiSystem", mission.aiSystem)
    describeEngineObject("trafficSystem", mission.trafficSystem)

    -- can a mod make a spline at runtime? (pairs(_G) does not list engine functions, so ask by name)
    local candidates = {
        "createSpline", "createSplineNode", "createSplineShape", "loadSplineFromFile", "setSplineCV", "setSplineCVs",
        "setSplineCVPosition", "addSplineCV", "removeSplineCV", "getSplineCV", "getSplineCVPosition", "getSplineNumOfCV",
        "getSplineNumCVs", "setSplineClosed", "getIsSplineClosed", "setSplineDirty", "updateSplineBoundingVolume",
        "getSplineLength", "getSplinePosition", "getSplineOrientation", "getSplineDirection", "getSplineTangent",
        "createTransformGroup", "loadI3DFile", "loadSharedI3DFile", "link", "delete",
    }
    local present, absent = {}, {}
    for _, name in ipairs(candidates) do
        if type(_G[name]) == "function" then present[#present + 1] = name else absent[#absent + 1] = name end
    end
    log("spline probe: engine functions present: %s", #present > 0 and table.concat(present, ", ") or "none")
    log("spline probe: not present: %s", table.concat(absent, ", "))

    local path = mission.missionInfo.savegameDirectory .. "/wailaSplines.xml"
    local xmlFile = XMLFile.create("wailaSplines", path, "wailaSplines")
    if xmlFile == nil then
        log("spline probe: XMLFile.create failed for %s", path)
        return
    end

    local counts = { ai = 0, other = 0 }
    local function dumpSpline(group, index, spline, value)
        local key = string.format("wailaSplines.%s(%d)", group, index)
        local points, length = splinePointsString(spline)
        if points == nil then
            return false
        end
        xmlFile:setString(key .. "#id", tostring(spline))
        xmlFile:setString(key .. "#name", nodeName(spline))
        local okParent, parent = pcall(getParent, spline)
        if okParent and parent ~= nil then
            xmlFile:setString(key .. "#parent", nodeName(parent))
        end
        xmlFile:setFloat(key .. "#length", length)
        xmlFile:setString(key .. "#value", type(value))
        xmlFile:setString(key .. "#points", points)
        return true
    end

    -- the road splines the AI uses (what WAILA reads)
    local roadSplines = mission.aiSystem ~= nil and mission.aiSystem:getRoadSplines() or {}
    for spline, value in pairs(roadSplines) do
        if dumpSpline("aiSpline", counts.ai, spline, value) then
            counts.ai = counts.ai + 1
        end
    end

    -- any table the traffic system holds whose numbers are spline nodes
    local groups = {}
    local trafficSystem = mission.trafficSystem
    if trafficSystem ~= nil then
        for field, value in pairs(trafficSystem) do
            if type(value) == "table" then
                local found = 0
                local tried = 0
                for key, entry in pairs(value) do
                    tried = tried + 1
                    if tried > 500 then break end
                    local candidate = type(entry) == "number" and entry or (type(key) == "number" and key or nil)
                    if candidate ~= nil then
                        local ok, length = pcall(getSplineLength, candidate)
                        if ok and type(length) == "number" and length > 0 then
                            if dumpSpline("trafficSpline", counts.other, candidate, entry) then
                                counts.other = counts.other + 1
                                found = found + 1
                            end
                        end
                    end
                end
                if found > 0 then
                    groups[#groups + 1] = tostring(field) .. "=" .. found
                end
            end
        end
    end
    xmlFile:save()
    xmlFile:delete()
    log("spline probe: %d AI road spline(s), %d spline(s) found in the traffic system (%s); written to %s",
        counts.ai, counts.other, #groups > 0 and table.concat(groups, ", ") or "no spline table", path)
end

-- Chains of {x, z} -> ribbon polygons (left edge forward, right edge back),
-- cut at chunk borders so each ribbon belongs to exactly one chunk (the save
-- file is per chunk): returns { ["col_row"] = { polygon, ... } }. A piece
-- takes one extra point from the next chunk so neighbouring pieces overlap.
function WailaTrailTracer.ribbonsFromChains(chains, width, originX, originZ, chunkSize)
    local half = width * 0.5
    local result = {}
    for _, chain in ipairs(chains) do
        local function chunkOf(point)
            return math.floor((point[1] - originX) / chunkSize), math.floor((point[2] - originZ) / chunkSize)
        end
        local startIndex = 1
        while startIndex < #chain do
            local col, row = chunkOf(chain[startIndex])
            local endIndex = startIndex
            while endIndex < #chain do
                local nextCol, nextRow = chunkOf(chain[endIndex + 1])
                if nextCol ~= col or nextRow ~= row then
                    break
                end
                endIndex = endIndex + 1
            end
            local lastIndex = math.min(endIndex + 1, #chain)
            if lastIndex > startIndex then
                local left, right = {}, {}
                for i = startIndex, lastIndex do
                    local a = chain[math.max(i - 1, startIndex)]
                    local b = chain[math.min(i + 1, lastIndex)]
                    local dx, dz = b[1] - a[1], b[2] - a[2]
                    local length = math.sqrt(dx * dx + dz * dz)
                    if length > 0 then
                        local nx, nz = -dz / length * half, dx / length * half
                        table.insert(left, { chain[i][1] + nx, chain[i][2] + nz })
                        table.insert(right, { chain[i][1] - nx, chain[i][2] - nz })
                    end
                end
                if #left >= 2 then
                    local polygon = {}
                    for _, point in ipairs(left) do table.insert(polygon, point) end
                    for i = #right, 1, -1 do table.insert(polygon, right[i]) end
                    local key = col .. "_" .. row
                    result[key] = result[key] or {}
                    table.insert(result[key], polygon)
                end
            end
            startIndex = endIndex + 1
        end
    end
    return result
end

-- Starts the whole-map scan (TaskMap's Shift+G). wholeMapScanState drives
-- TaskMap's progress bar and the save/load mutual-exclusion guards;
-- tickWholeMapScan runs tickLayerScanStep inside the per-frame budget.
-- Learns the map's layer classes and decides where roads come from (best first: ROAD colliders
-- under the splines, the learned paint layer, spline ribbons). Shared by the whole-map scan and
-- the area rescan, so both draw roads the same way. Returns splineRoads, roadRay.
local function prepareScanSources(terrainSize, chunkSize, tag)
    WailaTrailTracer.learnLayerClasses()
    if not WailaTrailTracer.layerClassLearned then
        -- Not fatal (Estancia Lapacho: the paint does not tell roads from
        -- ground): trees, worn ground and buildings need no learned class.
        log("%s: no layer classes learned on this map, scanning without them", tag)
    end
    local splineRoads, roadRay = nil, false
    local chains = WailaTrailTracer.collectRoadSplineChains()
    if #chains > 0 then
        local share, hits, tested = WailaTrailTracer.probeRoadCollision(chains)
        roadRay = share >= WailaTrailTracer.ROAD_RAY_PROBE_MIN_SHARE
        log("%s: road collision probe %d/%d spline samples on a ROAD collider (%.0f%%): %s",
            tag, hits, tested, share * 100, roadRay and "roads by raycast" or "not used")
    end
    WailaTrailTracer.roadSource = roadRay and "collision raycast" or (WailaTrailTracer.roadLayerLearned and "paint layer" or (#chains > 0 and "spline ribbons" or "none found"))
    if not roadRay and not WailaTrailTracer.roadLayerLearned then
        if #chains > 0 then
            splineRoads = WailaTrailTracer.ribbonsFromChains(chains, WailaTrailTracer.ROAD_SPLINE_FALLBACK_WIDTH, -terrainSize * 0.5, -terrainSize * 0.5, chunkSize)
            log("%s: no road layer learned, drawing %d road spline(s) as %.0fm ribbons", tag, #chains, WailaTrailTracer.ROAD_SPLINE_FALLBACK_WIDTH)
        end
    end
    return splineRoads, roadRay
end

-- A scan over the chunk range [colMin..colMax] x [rowMin..rowMax] (the whole map, or an area).
function WailaTrailTracer.newScanState(terrainSize, chunkSize, colMin, colMax, rowMin, rowMax, isArea, splineRoads, roadRay)
    return {
        originX = -terrainSize * 0.5,
        originZ = -terrainSize * 0.5,
        chunkSize = chunkSize,
        chunksPerSide = math.ceil(terrainSize / chunkSize),
        colMin = colMin, colMax = colMax, rowMin = rowMin, rowMax = rowMax,
        col = colMin,
        row = rowMin,
        chunksTotal = (colMax - colMin + 1) * (rowMax - rowMin + 1),
        chunksDone = 0,
        isArea = isArea,
        stats = { forestPolygons = 0, forestPoints = 0, trailPolygons = 0, trailPoints = 0, roadPolygons = 0, buildingPolygons = 0, waterPolygons = 0, trees = 0, treeShapes = 0, treeCallbacks = 0, treeNodes = 0, treeCellShapes = 0, emptyChunks = 0, totalMs = 0, maxMs = 0 },
        startTime = getTimeSec(),
        splineRoads = splineRoads,
        roadRay = roadRay,
    }
end

-- Moves to the next chunk of the state's range; true when the range is finished.
function WailaTrailTracer.advanceChunkCursor(state)
    state.chunksDone = state.chunksDone + 1
    state.col = state.col + 1
    if state.col > state.colMax then
        state.col = state.colMin
        state.row = state.row + 1
    end
    return state.row > state.rowMax
end

-- The chunk range of the square of (2 * radius + 1) chunks centred on the chunk holding (x, z),
-- clamped to the map.
function WailaTrailTracer.areaChunkRange(x, z, radius, terrainSize, chunkSize)
    local perSide = math.ceil(terrainSize / chunkSize)
    local col = math.max(0, math.min(perSide - 1, math.floor((x + terrainSize * 0.5) / chunkSize)))
    local row = math.max(0, math.min(perSide - 1, math.floor((z + terrainSize * 0.5) / chunkSize)))
    return math.max(0, col - radius), math.min(perSide - 1, col + radius), math.max(0, row - radius), math.min(perSide - 1, row + radius)
end

local function scanBusy()
    return WailaTrailTracer.loadState ~= nil or WailaTrailTracer.saveState ~= nil or WailaTrailTracer.imageSaveState ~= nil
        or WailaTrailTracer.wholeMapScanState ~= nil
end

-- Why a scan cannot start right now, for the HUD note ("Busy: restoring"); nil when it can.
local function busyReason()
    if WailaTrailTracer.wholeMapScanState ~= nil then
        return "scanning"
    elseif WailaTrailTracer.saveState ~= nil or WailaTrailTracer.imageSaveState ~= nil then
        return "saving"
    elseif WailaTrailTracer.loadState ~= nil then
        return "restoring"
    end
    return nil
end

-- A short-lived line in the HUD's task strip (WailaHud.collectTaskRows), so a refused key press
-- is not silent.
WailaTrailTracer.NOTE_SECONDS = 4
local function noteBusy(reason)
    WailaTrailTracer.statusNote = { text = "Busy: " .. reason, untilTime = getTimeSec() + WailaTrailTracer.NOTE_SECONDS }
end

-- Starts the whole-map scan (TaskMap's Shift+G). wholeMapScanState drives
-- TaskMap's progress bar and the save/load mutual-exclusion guards;
-- tickWholeMapScan runs tickLayerScanStep inside the per-frame budget.
function WailaTrailTracer.startWholeMapScan()
    -- a restore that has not finished is replaced by this scan anyway: cancel it instead of
    -- refusing (it waits a while after load, and a key press in that window did nothing)
    if WailaTrailTracer.wholeMapScanState == nil and WailaTrailTracer.saveState == nil then
        WailaTrailTracer.cancelRestore()
        -- layer images still waiting to be written describe the state this scan replaces
        WailaTrailTracer.imageSaveState = nil
    end
    if scanBusy() then
        log("startWholeMapScan: refused -- a scan, save or load is already in progress")
        noteBusy(busyReason())
        return
    end

    WailaTrailTracer.clearScanOverlays()
    WailaTrailTracer.savedRegionsByMaterial = { [1] = {}, [6] = {}, [7] = {} }
    WailaTrailTracer.savedRegions = { forest = {}, water = {}, road = {}, building = {} }

    local terrainSize = (g_currentMission ~= nil and g_currentMission.terrainSize) or 2048
    local chunkSize = WailaTrailTracer.WHOLE_MAP_SCAN_CHUNK_SIZE
    local chunksPerSide = math.ceil(terrainSize / chunkSize)
    local splineRoads, roadRay = prepareScanSources(terrainSize, chunkSize, "startWholeMapScan")
    WailaTrailTracer.wholeMapScanState = WailaTrailTracer.newScanState(terrainSize, chunkSize, 0, chunksPerSide - 1, 0, chunksPerSide - 1, false, splineRoads, roadRay)
    log("startWholeMapScan: %d chunk(s) (%.0fm each) queued", chunksPerSide * chunksPerSide, chunkSize)
end

-- Rescans the chunks around (x, z) (default radius 1: a 3 x 3 chunk area, 192 m) and replaces only
-- those chunks, through the same overlays, colours and stores as the whole-map scan. The same call
-- is meant for a later trigger (a vehicle driving over ground). Returns true when started.
WailaTrailTracer.AREA_SCAN_RADIUS_CHUNKS = 1
function WailaTrailTracer.startAreaScan(x, z, radius)
    if scanBusy() then
        log("startAreaScan: refused -- a scan, save or load is already in progress")
        noteBusy(busyReason())
        return false
    end
    local terrainSize = (g_currentMission ~= nil and g_currentMission.terrainSize) or 2048
    local chunkSize = WailaTrailTracer.WHOLE_MAP_SCAN_CHUNK_SIZE
    local colMin, colMax, rowMin, rowMax = WailaTrailTracer.areaChunkRange(x, z, radius or WailaTrailTracer.AREA_SCAN_RADIUS_CHUNKS, terrainSize, chunkSize)
    local splineRoads, roadRay = prepareScanSources(terrainSize, chunkSize, "startAreaScan")
    WailaTrailTracer.wholeMapScanState = WailaTrailTracer.newScanState(terrainSize, chunkSize, colMin, colMax, rowMin, rowMax, true, splineRoads, roadRay)
    log("startAreaScan: %d chunk(s) around (%.0f, %.0f) queued", WailaTrailTracer.wholeMapScanState.chunksTotal, x, z)
    return true
end

local function countPoints(polygons)
    local points = 0
    for _, polygon in ipairs(polygons) do
        points = points + #polygon
    end
    return points
end

-- One chunk per call; the per-frame budget loop in tickWholeMapScan decides how
-- many calls fit in a frame. Returns true when the whole map is done.
function WailaTrailTracer.tickLayerScanStep(state)
    local minX = state.originX + state.col * state.chunkSize
    local minZ = state.originZ + state.row * state.chunkSize
    local maxX, maxZ = minX + state.chunkSize, minZ + state.chunkSize
    local stats = state.stats

    local chunkStart = getTimeSec()
    if state.isArea then
        -- an area rescan replaces the chunk: wipe what is drawn there first
        WailaTrailTracer.clearChunkOverlays(minX, minZ, maxX, maxZ)
    end
    local buildings, waterMask, waterPolygons = WailaTrailTracer.scanBuildingChunk(minX, minZ, state.chunkSize)
    WailaTrailTracer.recordRegionPolygons("water", minX, minZ, maxX, maxZ, waterPolygons)
    if #waterPolygons > 0 then
        WailaTrailTracer.buildWaterLayerOverlayIncremental(waterPolygons)
        stats.waterPolygons = stats.waterPolygons + #waterPolygons
    end
    local result = WailaTrailTracer.scanLayerChunk(minX, minZ, state.chunkSize, waterMask)
    WailaTrailTracer.recordRegionPolygons("building", minX, minZ, maxX, maxZ, buildings)
    if #buildings > 0 then
        WailaTrailTracer.buildBuildingLayerOverlayIncremental(buildings)
        stats.buildingPolygons = stats.buildingPolygons + #buildings
    end
    if result == nil then
        stats.emptyChunks = stats.emptyChunks + 1
        WailaTrailTracer.recordRegionPolygons("forest", minX, minZ, maxX, maxZ, {})
        WailaTrailTracer.recordScannedPolygons(minX, minZ, maxX, maxZ, {})
    else
        WailaTrailTracer.recordRegionPolygons("forest", minX, minZ, maxX, maxZ, result.forest)
        WailaTrailTracer.recordScannedPolygons(minX, minZ, maxX, maxZ, { [6] = result.trail })
        if #result.forest > 0 then
            WailaTrailTracer.buildForestOverlayIncremental(result.forest)
        end
        if #result.trail > 0 then
            WailaTrailTracer.buildTestOverlay({ [6] = result.trail })
        end
        stats.forestPolygons = stats.forestPolygons + #result.forest
        stats.forestPoints = stats.forestPoints + countPoints(result.forest)
        stats.trailPolygons = stats.trailPolygons + #result.trail
        stats.trailPoints = stats.trailPoints + countPoints(result.trail)
    end

    if result ~= nil and #result.trees > 0 then
        WailaTrailTracer.buildTreeLayerOverlayIncremental(WailaTrailTracer.treeDots(result.trees))
        stats.trees = stats.trees + #result.trees
    end
    if result ~= nil then
        stats.treeShapes = stats.treeShapes + result.treeShapes
        stats.treeCallbacks = stats.treeCallbacks + result.treeCallbacks
        stats.treeNodes = stats.treeNodes + result.treeNodes
        stats.treeCellShapes = stats.treeCellShapes + result.treeCellShapes
    end

    local roads = (result ~= nil and result.road) or {}
    if state.roadRay then
        roads = WailaTrailTracer.scanRoadRayChunk(minX, minZ, state.chunkSize)
    elseif state.splineRoads ~= nil then
        roads = state.splineRoads[state.col .. "_" .. state.row] or {}
    end
    WailaTrailTracer.recordRegionPolygons("road", minX, minZ, maxX, maxZ, roads)
    if #roads > 0 then
        WailaTrailTracer.buildRoadLayerOverlayIncremental(roads)
        stats.roadPolygons = stats.roadPolygons + #roads
    end
    local chunkMs = (getTimeSec() - chunkStart) * 1000
    stats.totalMs = stats.totalMs + chunkMs
    stats.maxMs = math.max(stats.maxMs, chunkMs)

    if not WailaTrailTracer.advanceChunkCursor(state) then
        return false
    end

    WailaTrailTracer.linkTrailFragments()
    WailaTrailTracer.buildTestOverlay({}, true)
    WailaTrailTracer.buildForestOverlayIncremental({}, true)
    WailaTrailTracer.buildWaterLayerOverlayIncremental({}, true)
    WailaTrailTracer.buildTreeLayerOverlayIncremental({}, true)
    WailaTrailTracer.buildRoadLayerOverlayIncremental({}, true)
    WailaTrailTracer.buildBuildingLayerOverlayIncremental({}, true)
    local elapsedMs = (getTimeSec() - state.startTime) * 1000
    log("layer scan done%s: %d chunk(s) (%d empty), forest %d polygon(s) / %d point(s), trail %d / %d, road %d, building %d, water %d polygon(s), %d tree(s)",
        state.isArea and " (area)" or "", state.chunksTotal, stats.emptyChunks, stats.forestPolygons, stats.forestPoints,
        stats.trailPolygons, stats.trailPoints, stats.roadPolygons, stats.buildingPolygons, stats.waterPolygons, stats.trees)
    log("layer scan trees: %d dots; big window queries (overlap by the halo): %d shapes counted, %d callbacks, %d distinct node ids; per-cell 4m queries: %d shapes",
        stats.trees, stats.treeShapes, stats.treeCallbacks, stats.treeNodes, stats.treeCellShapes)
    log("layer scan cost: %.0fms of scan work (worst chunk %.0fms), %.1fs wall", stats.totalMs, stats.maxMs, elapsedMs / 1000)
    WailaTrailTracer.wholeMapScanState = nil

    -- One button, one scan: the field index sweeps right after the layers
    -- (not alongside them, so the per-frame cost stays what it was).
    local fieldIndex = Waila ~= nil and Waila.indices ~= nil and Waila.indices.field or nil
    if not state.isArea and fieldIndex ~= nil and fieldIndex.requestFullSweep ~= nil then
        fieldIndex:requestFullSweep()
    end
    return true
end

-- ===== Linking worn-path fragments =====
-- Real finding (IW path in open grass): the terrain only carries the wear where
-- it is heavy, so a long path arrives as separate dashes with unpainted gaps.
-- A map maker would draw it as one line. Two elongated fragments are one path
-- if the end of one points at the end of the other across a short gap: close
-- enough, and both fragment axes lined up with the gap direction. The link is a
-- narrow ribbon between the two ends, so the result reads as a path with worn
-- spots rather than a solid road.
WailaTrailTracer.LINK_MAX_GAP = 40.0
WailaTrailTracer.LINK_MAX_ANGLE_DEG = 25
WailaTrailTracer.LINK_MIN_LENGTH = 6.0
WailaTrailTracer.LINK_MIN_ELONGATION = 2.0
WailaTrailTracer.LINK_MAX_WIDTH = 12.0
WailaTrailTracer.LINK_WIDTH_FACTOR = 0.5
WailaTrailTracer.LINK_MIN_WIDTH = 1.5
WailaTrailTracer.LINK_REGION_KEY = "links"

-- PCA axis of a polygon's vertices -> centre line ends, or nil if it is not an
-- elongated fragment.
local function fragmentEnds(polygon)
    local count = #polygon
    if count < 3 then
        return nil
    end
    local cx, cz = 0, 0
    for _, point in ipairs(polygon) do
        cx, cz = cx + point[1], cz + point[2]
    end
    cx, cz = cx / count, cz / count
    local sxx, sxz, szz = 0, 0, 0
    for _, point in ipairs(polygon) do
        local dx, dz = point[1] - cx, point[2] - cz
        sxx, sxz, szz = sxx + dx * dx, sxz + dx * dz, szz + dz * dz
    end
    local angle = 0.5 * math.atan2(2 * sxz, sxx - szz)
    local ux, uz = math.cos(angle), math.sin(angle)
    local minAlong, maxAlong, minAcross, maxAcross = math.huge, -math.huge, math.huge, -math.huge
    for _, point in ipairs(polygon) do
        local dx, dz = point[1] - cx, point[2] - cz
        local along = dx * ux + dz * uz
        local across = -dx * uz + dz * ux
        minAlong, maxAlong = math.min(minAlong, along), math.max(maxAlong, along)
        minAcross, maxAcross = math.min(minAcross, across), math.max(maxAcross, across)
    end
    local length, width = maxAlong - minAlong, maxAcross - minAcross
    if length < WailaTrailTracer.LINK_MIN_LENGTH or width > WailaTrailTracer.LINK_MAX_WIDTH
        or length < WailaTrailTracer.LINK_MIN_ELONGATION * math.max(width, 1.0) then
        return nil
    end
    local midAcross = (minAcross + maxAcross) * 0.5
    local function at(along)
        return cx + ux * along - uz * midAcross, cz + uz * along + ux * midAcross
    end
    local ax, az = at(minAlong)
    local bx, bz = at(maxAlong)
    return { { ax, az, -ux, -uz }, { bx, bz, ux, uz } }, math.max(width, WailaTrailTracer.LINK_MIN_WIDTH)
end

-- Returns the number of links made. Reads every stored trail polygon (the
-- gravel slot of savedRegionsByMaterial), stores the bridge ribbons under
-- LINK_REGION_KEY and draws them.
function WailaTrailTracer.linkTrailFragments()
    local startTime = getTimeSec()
    local store = WailaTrailTracer.savedRegionsByMaterial[6]
    local ends, widths = {}, {}
    local fragments = 0
    for key, polygons in pairs(store) do
        if key ~= WailaTrailTracer.LINK_REGION_KEY then
            for _, polygon in ipairs(polygons) do
                local polygonEnds, width = fragmentEnds(polygon)
                if polygonEnds ~= nil then
                    fragments = fragments + 1
                    for _, endPoint in ipairs(polygonEnds) do
                        endPoint.fragment, endPoint.width = fragments, width
                        ends[#ends + 1] = endPoint
                    end
                end
            end
        end
    end

    local maxGap = WailaTrailTracer.LINK_MAX_GAP
    local cosLimit = math.cos(math.rad(WailaTrailTracer.LINK_MAX_ANGLE_DEG))
    local bucketSize = maxGap
    local buckets = {}
    local function bucketKey(x, z)
        return math.floor(x / bucketSize) * 100003 + math.floor(z / bucketSize)
    end
    for index, endPoint in ipairs(ends) do
        local key = bucketKey(endPoint[1], endPoint[2])
        buckets[key] = buckets[key] or {}
        table.insert(buckets[key], index)
    end

    -- best partner per end: nearest end ahead of this one, facing back at it
    local best = {}
    for index, a in ipairs(ends) do
        local bestIndex, bestDistance = nil, maxGap
        for dx = -1, 1 do
            for dz = -1, 1 do
                local key = (math.floor(a[1] / bucketSize) + dx) * 100003 + math.floor(a[2] / bucketSize) + dz
                for _, otherIndex in ipairs(buckets[key] or {}) do
                    local b = ends[otherIndex]
                    if b.fragment ~= a.fragment then
                        local vx, vz = b[1] - a[1], b[2] - a[2]
                        local distance = math.sqrt(vx * vx + vz * vz)
                        if distance < bestDistance and distance > 0.01 then
                            local ahead = (vx * a[3] + vz * a[4]) / distance
                            local facing = -(vx * b[3] + vz * b[4]) / distance
                            if ahead >= cosLimit and facing >= cosLimit then
                                bestIndex, bestDistance = otherIndex, distance
                            end
                        end
                    end
                end
            end
        end
        best[index] = bestIndex
    end

    local bridges = {}
    for index, otherIndex in pairs(best) do
        if otherIndex ~= nil and best[otherIndex] == index and index < otherIndex then
            local a, b = ends[index], ends[otherIndex]
            local vx, vz = b[1] - a[1], b[2] - a[2]
            local distance = math.sqrt(vx * vx + vz * vz)
            local halfWidth = math.max(WailaTrailTracer.LINK_MIN_WIDTH, math.min(a.width, b.width) * WailaTrailTracer.LINK_WIDTH_FACTOR) * 0.5
            local nx, nz = -vz / distance * halfWidth, vx / distance * halfWidth
            bridges[#bridges + 1] = {
                { a[1] + nx, a[2] + nz }, { b[1] + nx, b[2] + nz },
                { b[1] - nx, b[2] - nz }, { a[1] - nx, a[2] - nz },
            }
        end
    end

    store[WailaTrailTracer.LINK_REGION_KEY] = #bridges > 0 and bridges or nil
    if #bridges > 0 then
        WailaTrailTracer.buildTestOverlay({ [6] = bridges }, true)
    end
    log("linkTrailFragments: %d elongated fragment(s), %d link(s) within %.0fm, %.0fms", fragments, #bridges, maxGap, (getTimeSec() - startTime) * 1000)
    return #bridges
end
