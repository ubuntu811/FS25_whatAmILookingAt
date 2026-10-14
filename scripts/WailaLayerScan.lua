--[[
    WailaLayerScan.lua

    Whole-map scan driven by the learned terrain-layer classes
    (WailaTrailTracer.learnLayerClasses): ONE terrain read per cell gives the
    layer class (road / forest-floor / neither) and the material id, and the
    rest follows from shape.

      forest  = forest-floor-layer cells WITH foliage. The forest-floor layer alone
                is not enough: a parking lot or a worn path carries the same
                layer, but its foliage is empty (wear and placeables clear it)
      trail   = worn ground: dirt or gravel material outside the road layer and
                clear of the forest area (IW wear, yards, parking lots). Worn
                material is continuous where the layer signal fragments
      road    = the road layer, found by a 1m pass in chunks that have any

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
-- Worn ground stays this many cells away from the forest area.
WailaTrailTracer.LAYER_SCAN_TRAIL_EDGE_GAP_CELLS = 1
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
function WailaTrailTracer.scanLayerChunk(minX, minZ, chunkSize)
    local cell = WailaTrailTracer.LAYER_SCAN_CELL_SIZE
    local halo = WailaTrailTracer.LAYER_SCAN_HALO_CELLS
    local n = math.floor(chunkSize / cell)
    local w = n + 2 * halo
    local winX, winZ = minX - halo * cell, minZ - halo * cell
    local half = ((g_currentMission ~= nil and g_currentMission.terrainSize) or 2048) * 0.5
    local roadClass, forestClass = WailaTrailTracer.LAYER_CLASS_ROAD, WailaTrailTracer.LAYER_CLASS_FOREST
    local cellAt = WailaTrailTracer.getLayerCellAt

    -- prefilter: every 2nd cell in both axes; most chunks hold nothing
    local anyHit = false
    for row = 0, w - 1, 2 do
        local z = winZ + (row + 0.5) * cell
        if z > -half and z < half then
            for col = 0, w - 1, 2 do
                local x = winX + (col + 0.5) * cell
                if x > -half and x < half then
                    local class, materialId = cellAt(x, z)
                    if class ~= nil or WORN_MATERIALS[materialId] then
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
    for row = 0, w - 1 do
        local line, wornLine = {}, {}
        local z = winZ + (row + 0.5) * cell
        for col = 0, w - 1 do
            local x = winX + (col + 0.5) * cell
            local isForest, worn = false, false
            if x > -half and x < half and z > -half and z < half then
                local class, materialId = cellAt(x, z)
                worn = class ~= roadClass and WORN_MATERIALS[materialId] == true
                isForest = class == forestClass and (not useFoliage or hasFoliageAt(x, z))
                if (isForest or worn) and FSDensityMapUtil.getFieldDataAtWorldPosition(x, 0, z) then
                    isForest, worn = false, false
                elseif class == roadClass and row >= halo and row < halo + n and col >= halo and col < halo + n then
                    roadInChunk = true
                end
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

    local result = { forest = {}, trail = {}, road = {} }

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
                trail, trailCells = newMask(w, false), 0
                for row = 0, w - 1 do
                    for col = 0, w - 1 do
                        if wornMask[row][col] and not near[row][col] then
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
            result.trail = WailaTrailTracer.traceMaskPolygons(cropInner(trail, halo, n), minX, minZ, n, cell, WailaTrailTracer.LAYER_SCAN_TRAIL_TOLERANCE)
        end
    end

    if roadInChunk then
        result.road = WailaTrailTracer.scanRoadLayerChunk(minX, minZ, chunkSize)
    end

    return result
end

-- Starts the whole-map scan (TaskMap's Shift+G). wholeMapScanState drives
-- TaskMap's progress bar and the save/load mutual-exclusion guards;
-- tickWholeMapScan runs tickLayerScanStep inside the per-frame budget.
function WailaTrailTracer.startWholeMapScan()
    if WailaTrailTracer.loadState ~= nil or WailaTrailTracer.saveState ~= nil or WailaTrailTracer.wholeMapScanState ~= nil then
        log("startWholeMapScan: refused -- a scan, save or load is already in progress")
        return
    end

    WailaTrailTracer.clearScanOverlays()
    WailaTrailTracer.savedRegionsByMaterial = { [1] = {}, [6] = {}, [7] = {} }
    WailaTrailTracer.savedForestRegions = {}
    WailaTrailTracer.savedRoadRegions = {}
    WailaTrailTracer.learnLayerClasses()
    if not WailaTrailTracer.layerClassLearned then
        log("startWholeMapScan: no layer classes could be learned on this map, nothing to scan with")
        return
    end

    local terrainSize = (g_currentMission ~= nil and g_currentMission.terrainSize) or 2048
    local chunkSize = WailaTrailTracer.WHOLE_MAP_SCAN_CHUNK_SIZE
    local chunksPerSide = math.ceil(terrainSize / chunkSize)
    WailaTrailTracer.wholeMapScanState = {
        originX = -terrainSize * 0.5,
        originZ = -terrainSize * 0.5,
        chunkSize = chunkSize,
        chunksPerSide = chunksPerSide,
        col = 0,
        row = 0,
        stats = { forestPolygons = 0, forestPoints = 0, trailPolygons = 0, trailPoints = 0, roadPolygons = 0, emptyChunks = 0, totalMs = 0, maxMs = 0 },
        startTime = getTimeSec(),
    }
    log("startWholeMapScan: %d chunk(s) (%.0fm each) queued", chunksPerSide * chunksPerSide, chunkSize)
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
    local result = WailaTrailTracer.scanLayerChunk(minX, minZ, state.chunkSize)
    if result == nil then
        stats.emptyChunks = stats.emptyChunks + 1
        WailaTrailTracer.recordForestPolygons(minX, minZ, maxX, maxZ, {})
        WailaTrailTracer.recordRoadPolygons(minX, minZ, maxX, maxZ, {})
        WailaTrailTracer.recordScannedPolygons(minX, minZ, maxX, maxZ, {})
    else
        WailaTrailTracer.recordForestPolygons(minX, minZ, maxX, maxZ, result.forest)
        WailaTrailTracer.recordRoadPolygons(minX, minZ, maxX, maxZ, result.road)
        WailaTrailTracer.recordScannedPolygons(minX, minZ, maxX, maxZ, { [6] = result.trail })
        if #result.forest > 0 then
            WailaTrailTracer.buildForestOverlayIncremental(result.forest)
        end
        if #result.trail > 0 then
            WailaTrailTracer.buildTestOverlay({ [6] = result.trail })
        end
        if #result.road > 0 then
            WailaTrailTracer.buildRoadLayerOverlayIncremental(result.road)
        end
        stats.forestPolygons = stats.forestPolygons + #result.forest
        stats.forestPoints = stats.forestPoints + countPoints(result.forest)
        stats.trailPolygons = stats.trailPolygons + #result.trail
        stats.trailPoints = stats.trailPoints + countPoints(result.trail)
        stats.roadPolygons = stats.roadPolygons + #result.road
    end
    local chunkMs = (getTimeSec() - chunkStart) * 1000
    stats.totalMs = stats.totalMs + chunkMs
    stats.maxMs = math.max(stats.maxMs, chunkMs)

    state.col = state.col + 1
    if state.col >= state.chunksPerSide then
        state.col = 0
        state.row = state.row + 1
    end
    if state.row < state.chunksPerSide then
        return false
    end

    WailaTrailTracer.linkTrailFragments()
    WailaTrailTracer.buildTestOverlay({}, true)
    WailaTrailTracer.buildForestOverlayIncremental({}, true)
    WailaTrailTracer.buildRoadLayerOverlayIncremental({}, true)
    local elapsedMs = (getTimeSec() - state.startTime) * 1000
    log("layer scan done: %d chunk(s) (%d empty), forest %d polygon(s) / %d point(s), trail %d / %d, road %d polygon(s)",
        state.chunksPerSide * state.chunksPerSide, stats.emptyChunks, stats.forestPolygons, stats.forestPoints,
        stats.trailPolygons, stats.trailPoints, stats.roadPolygons)
    log("layer scan cost: %.0fms of scan work (worst chunk %.0fms), %.1fs wall", stats.totalMs, stats.maxMs, elapsedMs / 1000)
    WailaTrailTracer.wholeMapScanState = nil
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
