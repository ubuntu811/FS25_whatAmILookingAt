--[[
    WailaLayerScan.lua

    Whole-map scan driven by the learned terrain-layer classes
    (WailaTrailTracer.learnLayerClasses): ONE terrain read per cell says
    road / forest-floor / neither, and everything else follows from shape.

      forest  = the thick parts of the forest-floor-layer mask (what survives
                a morphological opening)
      trail   = the thin remainder of that same mask -- IW wear shares the
                forest-floor layer, but it is a line where forest is an area
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
-- Opening radius in cells: a structure narrower than 2*radius+1 cells (10m)
-- is a line, not an area.
WailaTrailTracer.LAYER_SCAN_OPEN_RADIUS = 2
-- Position-independent island/hole rule (a component touching the window edge
-- is never judged, so seams are consistent): smaller than this is dropped.
WailaTrailTracer.LAYER_SCAN_MIN_AREA_CELLS = 25
WailaTrailTracer.LAYER_SCAN_MIN_THIN_CELLS = 6
WailaTrailTracer.LAYER_SCAN_FOREST_TOLERANCE = 2.0
WailaTrailTracer.LAYER_SCAN_TRAIL_TOLERANCE = 1.0

-- shared empty "protected" grid for the component cleaner (nothing is protected)
local noProtectedRows = setmetatable({}, { __index = function() return {} end })

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] [LayerScan] " .. formatString, ...)
end

-- dilate by radius cells with a square kernel (separable, edge cells skipped)
local function dilateMask(mask, n, radius)
    local function pass(source, horizontal)
        local result = {}
        for a = 0, n - 1 do
            result[a] = {}
        end
        for a = 0, n - 1 do
            for b = 0, n - 1 do
                local value = false
                for k = math.max(0, b - radius), math.min(n - 1, b + radius) do
                    local cell
                    if horizontal then
                        cell = source[a][k]
                    else
                        cell = source[k][a]
                    end
                    if cell then
                        value = true
                        break
                    end
                end
                if horizontal then
                    result[a][b] = value
                else
                    result[b][a] = value
                end
            end
        end
        return result
    end
    return pass(pass(mask, true), false)
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
    local classAt = WailaTrailTracer.getLayerClassAt

    -- prefilter: every 2nd cell in both axes; most chunks hold nothing
    local anyHit = false
    for row = 0, w - 1, 2 do
        local z = winZ + (row + 0.5) * cell
        if z > -half and z < half then
            for col = 0, w - 1, 2 do
                local x = winX + (col + 0.5) * cell
                if x > -half and x < half and classAt(x, z) ~= nil then
                    anyHit = true
                    break
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

    -- one terrain read per window cell
    local forestMask = {}
    local roadInChunk, forestCells = false, 0
    for row = 0, w - 1 do
        local line = {}
        local z = winZ + (row + 0.5) * cell
        for col = 0, w - 1 do
            local x = winX + (col + 0.5) * cell
            local class = nil
            if x > -half and x < half and z > -half and z < half then
                class = classAt(x, z)
                if class == forestClass and FSDensityMapUtil.getFieldDataAtWorldPosition(x, 0, z) then
                    class = nil
                end
            end
            line[col] = class == forestClass
            if class == forestClass then
                forestCells = forestCells + 1
            elseif class == roadClass and row >= halo and row < halo + n and col >= halo and col < halo + n then
                roadInChunk = true
            end
        end
        forestMask[row] = line
    end

    local result = { forest = {}, trail = {}, road = {} }

    if forestCells > 0 then
        local radius = WailaTrailTracer.LAYER_SCAN_OPEN_RADIUS
        local area = WailaTrailTracer.openMask(forestMask, w, radius)
        WailaTrailTracer.cleanComponents(area, noProtectedRows, w, WailaTrailTracer.LAYER_SCAN_MIN_AREA_CELLS, WailaTrailTracer.LAYER_SCAN_MIN_AREA_CELLS)

        -- thin = forest-layer cells not within `radius` of the cleaned area
        local near = dilateMask(area, w, radius)
        local thin = newMask(w, false)
        local thinCells = 0
        for row = 0, w - 1 do
            for col = 0, w - 1 do
                if forestMask[row][col] and not near[row][col] then
                    thin[row][col] = true
                    thinCells = thinCells + 1
                end
            end
        end
        if thinCells > 0 then
            WailaTrailTracer.cleanComponents(thin, noProtectedRows, w, WailaTrailTracer.LAYER_SCAN_MIN_THIN_CELLS, 0)
        end

        result.forest = WailaTrailTracer.traceMaskPolygons(cropInner(area, halo, n), minX, minZ, n, cell, WailaTrailTracer.LAYER_SCAN_FOREST_TOLERANCE)
        if thinCells > 0 then
            result.trail = WailaTrailTracer.traceMaskPolygons(cropInner(thin, halo, n), minX, minZ, n, cell, WailaTrailTracer.LAYER_SCAN_TRAIL_TOLERANCE)
        end
    end

    if roadInChunk then
        result.road = WailaTrailTracer.scanRoadLayerChunk(minX, minZ, chunkSize)
    end

    return result
end

-- Starts a whole-map layer scan. Uses the same wholeMapScanState (so TaskMap's
-- progress bar and the mutual-exclusion guards keep working); layerMode makes
-- tickWholeMapScanStep hand each tick to tickLayerScanStep below.
function WailaTrailTracer.startLayerScan()
    if WailaTrailTracer.loadState ~= nil or WailaTrailTracer.saveState ~= nil or WailaTrailTracer.wholeMapScanState ~= nil then
        log("startLayerScan: refused -- a scan, save or load is already in progress")
        return
    end

    WailaTrailTracer.clearScanOverlays()
    WailaTrailTracer.savedRegionsByMaterial = { [1] = {}, [6] = {}, [7] = {} }
    WailaTrailTracer.savedForestRegions = {}
    WailaTrailTracer.learnLayerClasses()
    if not WailaTrailTracer.layerClassLearned then
        log("startLayerScan: no layer classes could be learned on this map, nothing to scan with")
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
        layerMode = true,
        stats = { forestPolygons = 0, forestPoints = 0, trailPolygons = 0, trailPoints = 0, roadPolygons = 0, emptyChunks = 0, totalMs = 0, maxMs = 0 },
        startTime = getTimeSec(),
    }
    log("startLayerScan: %d chunk(s) (%.0fm each) queued", chunksPerSide * chunksPerSide, chunkSize)
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
        WailaTrailTracer.recordScannedPolygons(minX, minZ, maxX, maxZ, {})
    else
        WailaTrailTracer.recordForestPolygons(minX, minZ, maxX, maxZ, result.forest)
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
