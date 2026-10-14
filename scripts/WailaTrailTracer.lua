--[[
    WailaTrailTracer.lua

    Whole-map terrain scan behind the TaskMap overlays: where the forest is,
    where worn trails are, where the roads are -- independent of fields and
    of whichever mod painted the ground (IW, tyre wear, a placeable's
    foundation stamp, the map author).

    Current pipeline, per 64m chunk, one chunk phase per frame inside a
    per-frame time budget (see tickWholeMapScan):
      - forest: 16m window classifier, 1m border refinement, smoothing,
        Bezier curve fit of the outline
      - road: terrain-layer fingerprints learned per map (learnLayerClasses),
        found by a 4m prefilter and a 1m pass
      - trails: the 1m material scan (dirt/gravel/stone), skipping forest,
        fields and real roads
    Results are baked into density-map overlays (one per layer) and persisted
    as polygons in the savegame (startSaveToXML / startLoadFromXML).

    Independent from WailaFieldBoundaryTracer.lua on purpose.
]]

WailaTrailTracer = {}
local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] [TrailTracer] " .. formatString, ...)
end

-- Real, confirmed terrain material IDs - DIRT/GRAVEL are the same
-- constants FS25_ImmersiveWeathering's own MATERIAL table uses (confirmed
-- live there over the same investigation this whole feature grew out of).
-- Duplicated here rather than imported - IW is not a dependency of
-- WAILA (the reverse is true: TaskMap depends on WAILA), and these are
-- just numeric engine IDs, not meaningfully "shared logic" worth
-- coupling two mods over.
--
-- STONE added later, confirmed live via WAILA's own "Ground:" line: a
-- placeable's concrete apron on this map reads back as plain STONE, same
-- id a real stone/rock outcrop would -- there's no separate concrete
-- material. Without this, a tile straddling the seam between a dirt yard
-- and its own concrete apron only ever samples DIRT hits on the dirt
-- side, clustered right along that seam -- a straight line of hits reads
-- as "elongated" to the PCA classifier, misclassifying the seam itself as
-- a path (confirmed live: a dead-straight "path" line traced right down
-- the dirt/concrete boundary of one big open yard). Same mechanism
-- explained the small islands traced around placeables sitting on
-- concrete/stone ground -- their apron was never trail material at all,
-- so the wall-follower treated it as a hole exactly like a real rock
-- outcrop would be.
local MATERIAL_DIRT = 1
local MATERIAL_GRAVEL = 6
local MATERIAL_STONE = 7
-- Real request ("split all 3?"): the order the whole-tile scan processes
-- (and later colors) each material in -- see scanTileCells's own header.
local SPLIT_MATERIALS = { MATERIAL_DIRT, MATERIAL_GRAVEL, MATERIAL_STONE }
-- Density-map VALUE each material writes as -- needs >= 2 bits/channels
-- to represent (0=empty plus 3 real materials), unlike the old single-
-- material version's plain 1-bit "is this filled" value.
local MATERIAL_VALUE = { [MATERIAL_DIRT] = 1, [MATERIAL_GRAVEL] = 2, [MATERIAL_STONE] = 3 }
-- Real request ("so they'd go green instead of white, because forests on
-- these maps happen to have stone underneath at times"): STONE gets its
-- own distinct green, separate from dirt/gravel's gray family -- the
-- whole point of splitting by material at all.
local MATERIAL_COLOR = {
    [MATERIAL_DIRT] = { 0.5, 0.5, 0.5 },
    [MATERIAL_GRAVEL] = { 0.6, 0.55, 0.45 },
    [MATERIAL_STONE] = { 0.2, 0.5, 0.2 },
}
-- Debug colour mode (debug hub toggle): every layer gets a loud, distinct
-- colour so overlays can be told apart at a glance. Normal colours stay
-- the tasteful defaults.
local MATERIAL_COLOR_DEBUG = {
    [MATERIAL_DIRT] = { 1.0, 1.0, 0.0 },
    [MATERIAL_GRAVEL] = { 1.0, 0.5, 0.0 },
    [MATERIAL_STONE] = { 0.0, 1.0, 1.0 },
}
WailaTrailTracer.debugColors = false
WailaTrailTracer.PALETTE = {
    normal = { forest = { 0.02, 0.2, 0.04 }, road = { 0.12, 0.12, 0.12 } },
    debug = { forest = { 0.2, 1.0, 0.2 }, road = { 1.0, 0.4, 0.0 } },
}
local function paletteColor(name)
    return WailaTrailTracer.PALETTE[WailaTrailTracer.debugColors and "debug" or "normal"][name]
end
local function materialColor(materialId)
    return (WailaTrailTracer.debugColors and MATERIAL_COLOR_DEBUG or MATERIAL_COLOR)[materialId]
end

-- Real, confirmed live bug (229,673 polygons written in one blocking
-- call froze the game -- same class of mistake as the earlier whole-map-
-- scan freeze, see feedback_waila_performance_is_non_negotiable): the
-- first version of this accumulator was a flat, ever-growing list with
-- NO dedup at all -- every rescan (whole-map or debug) just appended more
-- copies of the same ground forever, on top of already being fully
-- synchronous to write. Real, two-part fix:
--   1) keyed by REGION (the exact minX/minZ/maxX/maxZ scanTileCells was
--      called with) so re-scanning the same area REPLACES its entry
--      instead of duplicating it -- required anyway for the planned
--      periodic/vehicle-triggered rescans, which by design will
--      re-touch the same ground repeatedly.
--   2) stores the FINAL polygons -- Bezier curve-fit outlines of ~10
--      points, same as forest. This used to store raw 1m loops and
--      Chaikin-smooth them on load (x8 points): 7,792 trail polygons /
--      152k raw points became ~1.2M points through the engine, which is
--      what made a restore take 113-214s (measured). Old saves hold raw
--      loops and load as staircases until the next scan.
-- Each savedRegionsByMaterial[materialId] is { [regionKey] = polygons }.
WailaTrailTracer.savedRegionsByMaterial = { [MATERIAL_DIRT] = {}, [MATERIAL_GRAVEL] = {}, [MATERIAL_STONE] = {} }

-- Real design choice: persists the POLYGON data, not the raw bit-vector
-- density map itself. Checked for a native "save this bit-vector map to
-- file" call to mirror loadBitVectorMapFromFile (real, confirmed via the
-- base game's own FieldGroundSystem loading ITS density maps this way) --
-- no such call exists in decompiled source. The engine appears to persist
-- its OWN registered density maps (fruit/foliage/field-ground) at a level
-- below anything Lua can call into, not something reachable for a map we
-- created ourselves via createBitVectorMap. Polygon data is also just far
-- smaller to write/read than a full map dump would be.
WailaTrailTracer.SAVEGAME_FILENAME = "wailaTrail.xml"

-- Records one scan's freshly-produced polygons under
-- their region's key, replacing whatever was there before for that exact
-- region. Called from scanTileCells itself (not each individual caller)
-- so every present AND future scan path (whole-map ticks, single-tile
-- debug traces, a future vehicle-triggered local rescan) is captured
-- automatically, with nothing to remember at each call site.
-- Real, confirmed live gap ("any chance we're not saving the forest areas
-- yet?"): forest polygons were never persisted at all -- and since forest
-- ground is EXCLUDED from the detailed material scan, a restart restored
-- only thin edge outlines and left the whole forest interior empty. Same
-- region-keyed replace-on-rescan shape as the material store; regions
-- with no forest are stored as nothing (nil), so an empty rescan also
-- removes a stale entry. Polygons here are already simplified outlines
-- (see traceForestPolygonsFromGrid), so unlike material polygons they are
-- NOT re-smoothed on load.
WailaTrailTracer.savedForestRegions = {}
-- Same shape for the road layer (without it a restored map has no roads on top).
WailaTrailTracer.savedRoadRegions = {}

function WailaTrailTracer.recordRoadPolygons(minX, minZ, maxX, maxZ, polygons)
    local regionKey = string.format("%.1f_%.1f_%.1f_%.1f", minX, minZ, maxX, maxZ)
    WailaTrailTracer.savedRoadRegions[regionKey] = #polygons > 0 and polygons or nil
end

function WailaTrailTracer.recordForestPolygons(minX, minZ, maxX, maxZ, polygons)
    local regionKey = string.format("%.1f_%.1f_%.1f_%.1f", minX, minZ, maxX, maxZ)
    WailaTrailTracer.savedForestRegions[regionKey] = #polygons > 0 and polygons or nil
end

function WailaTrailTracer.recordScannedPolygons(minX, minZ, maxX, maxZ, polygonsByMaterial)
    local regionKey = string.format("%.1f_%.1f_%.1f_%.1f", minX, minZ, maxX, maxZ)
    for _, materialId in ipairs(SPLIT_MATERIALS) do
        WailaTrailTracer.savedRegionsByMaterial[materialId][regionKey] = polygonsByMaterial[materialId] or {}
    end
end

-- Real, confirmed live via debug-line visualization: on-field ground
-- reads as dirt/gravel material too (tillage/crop base layers, IW's own
-- tyre-wear domain), producing dense internal scribble noise bounded
-- exactly by the field's own outline -- not just a reeds/foliage-overlay
-- problem, the same chaos showed up in a plain plowed field AND an
-- off-field meadow circle, both traced with a clean outer boundary but
-- chaotic interior. Excluding registered fields makes sense on its own
-- merits too, not just as a patch: WAILA already has a real, dedicated,
-- working field boundary tracer (WailaFieldBoundaryTracer) -- the trail
-- tracer's whole point was finding non-field wear, so on-field ground
-- was never something it should have tried to cover at all.
-- FSDensityMapUtil.getFieldDataAtWorldPosition is the same real,
-- already-proven "is this on a field" check WailaFieldInspector already
-- uses -- a density-map read, same cost class as the material check
-- right below, not an expensive raycast, safe to add to this hot path
-- (confirmed live: up to ~80 calls per tile, hundreds of tiles per scan).
-- Real request ("lets try i guess, maybe split all 3?"): returns the
-- actual matched material id (MATERIAL_DIRT/GRAVEL/STONE) instead of
-- collapsing it into a boolean -- isTrailMaterialAt below is now just a
-- thin wrapper over this, same exact behavior for its existing callers
-- (the production wall-follower), nothing about it changed. The new
-- grid pipeline (rasterizeRegionByMaterial) uses this directly instead,
-- to color dirt/gravel/stone regions differently rather than lumping
-- them into one "is this trail material" signal -- real motivation:
-- forests on this map often read as STONE underneath, so splitting the
-- color by material is a free (already-queried) way to visually tell
-- likely-forest apart from likely-real-trail, without an expensive
-- per-cell tree raycast.
-- Real request ("roads are declared in the map data... we could subtract
-- these to start with"): excludes cells within real-road-ribbon-width of
-- an actual road spline from ever being classified as trail material at
-- all -- same "early nil-out" pattern the on-field check below already
-- uses, done BEFORE tracing rather than trying to untangle a road from a
-- forest blob after the fact (the real precision problem flagged live:
-- roads cross/hug forest areas). getTrailMaterialKindAt is the hot path
-- (potentially millions of calls across a whole-map scan, see
-- isTrailMaterialAt's own header) so this can't be a naive "check
-- distance to every road spline point" -- built as a spatial hash
-- instead (segments bucketed by a coarse grid, NUMERIC keys, not string
-- concatenation, to avoid GC pressure at this call volume), so a typical
-- cell (nowhere near any road) hits a couple of empty bucket lookups and
-- returns immediately; only cells actually near a road pay for real
-- distance checks, against the handful of segments in their own
-- neighborhood, never the whole road network.
local ROAD_EXCLUSION_BUCKET_SIZE = 32.0
local ROAD_EXCLUSION_MARGIN = 2.0
local ROAD_EXCLUSION_SAMPLE_STEP = 8.0
local roadExclusionBuckets = nil

local function addRoadExclusionSegment(buckets, x1, z1, x2, z2)
    local minCol = math.floor(math.min(x1, x2) / ROAD_EXCLUSION_BUCKET_SIZE)
    local maxCol = math.floor(math.max(x1, x2) / ROAD_EXCLUSION_BUCKET_SIZE)
    local minRow = math.floor(math.min(z1, z2) / ROAD_EXCLUSION_BUCKET_SIZE)
    local maxRow = math.floor(math.max(z1, z2) / ROAD_EXCLUSION_BUCKET_SIZE)
    for col = minCol, maxCol do
        local colBucket = buckets[col]
        if colBucket == nil then
            colBucket = {}
            buckets[col] = colBucket
        end
        for row = minRow, maxRow do
            local cellBucket = colBucket[row]
            if cellBucket == nil then
                cellBucket = {}
                colBucket[row] = cellBucket
            end
            table.insert(cellBucket, { x1, z1, x2, z2 })
        end
    end
end

-- Real, one-time (per session) cost -- roads are static map data, never
-- change mid-session, so this builds once, lazily, on first use, and is
-- cached forever after. Same real getSplineLength/getSplinePosition
-- sampling sampleSplineChain (below, for the road overlay) already
-- uses -- kept separate rather than shared, since this needs plain
-- segments for the spatial hash, not a full point chain.
local function buildRoadExclusionBuckets()
    local buckets = {}
    if g_currentMission == nil or g_currentMission.aiSystem == nil then
        return buckets
    end
    local splines = g_currentMission.aiSystem:getRoadSplines()
    for spline in pairs(splines) do
        local length = getSplineLength(spline)
        if length ~= nil and length > 0 then
            local stepSize = ROAD_EXCLUSION_SAMPLE_STEP / length
            local prevX, prevZ = nil, nil
            for t = 0, 1 + stepSize, stepSize do
                local clampedT = math.clamp(t, 0, 1)
                local x, _, z = getSplinePosition(spline, clampedT)
                if prevX ~= nil then
                    addRoadExclusionSegment(buckets, prevX, prevZ, x, z)
                end
                prevX, prevZ = x, z
            end
        end
    end
    return buckets
end

local function distancePointToSegmentSq(px, pz, x1, z1, x2, z2)
    local dx, dz = x2 - x1, z2 - z1
    local lengthSq = dx * dx + dz * dz
    if lengthSq < 0.0001 then
        local ddx, ddz = px - x1, pz - z1
        return ddx * ddx + ddz * ddz
    end
    local t = math.clamp(((px - x1) * dx + (pz - z1) * dz) / lengthSq, 0, 1)
    local closestX, closestZ = x1 + t * dx, z1 + t * dz
    local ddx, ddz = px - closestX, pz - closestZ
    return ddx * ddx + ddz * ddz
end

local function isNearRealRoad(x, z)
    if roadExclusionBuckets == nil then
        roadExclusionBuckets = buildRoadExclusionBuckets()
    end
    local col = math.floor(x / ROAD_EXCLUSION_BUCKET_SIZE)
    local row = math.floor(z / ROAD_EXCLUSION_BUCKET_SIZE)
    local thresholdSq = (WailaTrailTracer.ROAD_SPLINE_RIBBON_WIDTH * 0.5 + ROAD_EXCLUSION_MARGIN) ^ 2
    for dCol = -1, 1 do
        local colBucket = roadExclusionBuckets[col + dCol]
        if colBucket ~= nil then
            for dRow = -1, 1 do
                local cellBucket = colBucket[row + dRow]
                if cellBucket ~= nil then
                    for _, segment in ipairs(cellBucket) do
                        if distancePointToSegmentSq(x, z, segment[1], segment[2], segment[3], segment[4]) <= thresholdSq then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

-- Real, proven pattern ported from FS25_ImmersiveWeathering's own
-- isSpotClearForFoliage -- ground texture material alone can't tell a
-- worn dirt trail apart from a real road/building sitting on ground
-- that's still painted dirt/gravel underneath (IW's own comment states
-- this exact problem). Raycast straight down; only bare terrain (no
-- object) counts as clear. CollisionFlag/raycastClosest are real native
-- globals, not an IW dependency -- same "just reusing a known-good
-- pattern, not coupling two mods" reasoning TRAIL_MATERIALS' own comment
-- above already applies to the duplicated material IDs.
--
-- Deliberately NOT wired into isTrailMaterialAt itself -- that function
-- is the hot path (up to ~80 calls per tile during classification,
-- hundreds of tiles per scan region, confirmed live: "tilesScanned=625"
-- for one real scan). A raycast per call there would be a real
-- performance regression, not a theoretical one -- WAILA's own
-- performance discipline (every scan needs a real per-tick budget, not
-- "seems fine") rules that out. Only called from the boundary tracer's
-- own step loop instead, at most once per accepted step -- already
-- rate-limited by frameBudget ticking, nowhere near the tile-scan's call
-- volume.
local STRUCTURE_COLLISION_FLAG_NAMES = {
    "TREE", "VEHICLE_FORK", "STATIC_OBJECT", "DYNAMIC_OBJECT", "BUILDING", "ROAD", "ANIMAL"
}
local structureCollisionMask = nil

-- Real object as the raycast target, not a nil-target/global-name-lookup
-- fallback -- IW's own working version passes a real self, method-style
-- (self:onWeatheringRaycastCallback), and a nil target with a bare local
-- function name would rely on a global lookup that a `local function`
-- never satisfies (silent failure: callback never fires, hit stays nil
-- forever, "clear" always reports true even when something's there).
-- This table is that same real, valid target, self-contained instead of
-- polluting _G.
local raycastTarget = {}

function raycastTarget:onStructureRaycastCallback(hitObjectId)
    if hitObjectId ~= nil and hitObjectId ~= 0 then
        self.hit = hitObjectId
    end
    return false
end

local function getStructureCollisionMask()
    if structureCollisionMask == nil then
        local mask = 0
        for _, name in ipairs(STRUCTURE_COLLISION_FLAG_NAMES) do
            if CollisionFlag[name] ~= nil then
                mask = bit32.bor(mask, CollisionFlag[name])
            end
        end
        structureCollisionMask = mask
    end
    return structureCollisionMask
end

local function isSpotClearOfStructures(x, z)
    local terrainHeight = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    raycastTarget.hit = nil
    raycastClosest(x, terrainHeight + 3, z, 0, -1, 0, 6, "onStructureRaycastCallback", raycastTarget, getStructureCollisionMask())
    return raycastTarget.hit == nil
        or raycastTarget.hit == g_terrainNode
        or raycastTarget.hit == g_currentMission.terrainRootNode
end

-- Exposed on the module table (a `local function` in this file is invisible
-- to every OTHER file in this mod -- FS25 sourceFiles don't share
-- chunk-scoped locals, only the module table/globals). WailaTerrainInspector
-- needs this same check for the general "Ground:" HUD line (ground texture
-- alone can't tell a road from a worn trail, see the comment above this
-- function) -- throttled to ~10/s by the point-inspection timer, nowhere
-- near the tile-scan hot path this function's own comment warns about.
WailaTrailTracer.isSpotClearOfStructures = isSpotClearOfStructures

-- ============================================================
-- Polyline helpers (road spline ribbons, curve-fit fallback)
-- ============================================================

-- Real length in meters, not squared -- squared units read as
-- surprisingly tiny at a glance (0.0001 looks negligible, but is
-- actually a full 1cm segment). This pass exists to simplify anyway, so
-- there's no fidelity lost being generous here -- a couple points
-- folding into their neighbor at this scale is exactly the point.
local MIN_SEGMENT_LENGTH = 0.1

local MIN_SEGMENT_LENGTH_SQ = MIN_SEGMENT_LENGTH * MIN_SEGMENT_LENGTH

-- Iterative Douglas-Peucker, own copy (see this file's own header for
-- why it's not shared with the field tracer's identical-shaped one).
local function simplifyBoundary(points, tolerance)
    local n = #points
    if n < 3 then
        return points
    end

    local keep = { [1] = true, [n] = true }
    local stack = { { 1, n } }

    while #stack > 0 do
        local range = table.remove(stack)
        local startIndex, endIndex = range[1], range[2]

        if endIndex - startIndex > 1 then
            local ax, az = points[startIndex][1], points[startIndex][2]
            local bx, bz = points[endIndex][1], points[endIndex][2]
            local maxDist, maxIndex = 0, nil

            -- Real crash found live: getDistanceToLineSegment2D divides
            -- by the segment's own squared length internally -- a
            -- genuine "Script error: Divide by zero", not a normal Lua
            -- error, and it propagated straight through safeCall's own
            -- pcall (the full call stack up through main.lua:update was
            -- still logged, meaning the engine's own divide-by-zero trap
            -- isn't reliably caught by pcall the way an ordinary Lua
            -- error would be) despite the designed vector2Length
            -- fallback already sitting right here for exactly this case.
            -- Checking for a degenerate (zero-length) segment BEFORE
            -- calling in, instead of trying to catch the fault after the
            -- fact, is the only actually-safe fix -- a real, not
            -- theoretical, case too: two consecutive traced boundary
            -- points can legitimately land on the same cell.
            local segLenSq = (bx - ax) * (bx - ax) + (bz - az) * (bz - az)

            for i = startIndex + 1, endIndex - 1 do
                local dist
                if segLenSq > MIN_SEGMENT_LENGTH_SQ then
                    dist = WailaUtil.safeCall(nil, MathUtil.getDistanceToLineSegment2D, ax, az, bx, bz, points[i][1], points[i][2])
                end
                if dist == nil then
                    dist = MathUtil.vector2Length(points[i][1] - ax, points[i][2] - az)
                end
                if dist > maxDist then
                    maxDist, maxIndex = dist, i
                end
            end

            if maxIndex ~= nil and maxDist > tolerance then
                keep[maxIndex] = true
                table.insert(stack, { startIndex, maxIndex })
                table.insert(stack, { maxIndex, endIndex })
            end
        end
    end

    local simplified = {}
    for i = 1, n do
        if keep[i] then
            table.insert(simplified, points[i])
        end
    end
    return simplified
end


-- Fixed 256m tiles aligned to the terrain origin; the single-tile debug overlays
-- (tree/water) work on one of these at a time.
WailaTrailTracer.DEBUG_TILE_SIZE = 256.0

-- World-space bounds of the fixed tile that contains (x, z).
function WailaTrailTracer.getTileBounds(x, z)
    local terrainSize = (g_currentMission ~= nil and g_currentMission.terrainSize) or 2048
    local originX, originZ = -terrainSize * 0.5, -terrainSize * 0.5
    local tileSize = WailaTrailTracer.DEBUG_TILE_SIZE
    local col = math.floor((x - originX) / tileSize)
    local row = math.floor((z - originZ) / tileSize)
    local minX, minZ = originX + col * tileSize, originZ + row * tileSize
    return minX, minZ, minX + tileSize, minZ + tileSize
end

-- ============================================================
-- Grid constants and the material rasterizer for the 1m trail scan
-- ============================================================

WailaTrailTracer.GRID_CELL_SIZE = 1.0

-- Real bug this fixes, confirmed live ("why is this fading out in the
-- first place, the fields are just a line?"): a density-map-visualization
-- overlay's declared width/height (see createDensityMapVisualizationOverlay
-- calls below) always spans the WHOLE TERRAIN, not just whatever small
-- world region was actually written into it -- confirmed live against
-- FSDensityMapUtil.getFieldTypeAtWorldPos's own world-to-pixel formula
-- (`width * (worldX + terrainSize*0.5) / terrainSize`). The overlay was
-- being sized to match our TILE's own cell count (256), but that's a
-- texel count spread across the ENTIRE terrain, not our 256m tile --
-- on this 4096m map that's 4096/256 = 16m per texel, and bilinear
-- filtering between texels that huge is exactly what produced the big
-- soft blur (and made a 1-2m real trail balloon out to look many meters
-- wide). Decoupled from tile/cell size entirely -- matches the high end
-- of what MapOverlayGenerator itself uses for real field overlays
-- (2048, from OVERLAY_RESOLUTION.FIELDS={512,512} * 4 on high graphics
-- settings), giving ~2m/texel on this map instead of 16m.
WailaTrailTracer.OVERLAY_RESOLUTION = 2048

-- Real request ("split all 3?"): the persistent overlay's own bit-vector
-- map now stores one of 4 values per cell (0=empty, 1=dirt, 2=gravel,
-- 3=stone -- see MATERIAL_VALUE), not a plain 1-bit "is this filled" --
-- needs 2 channels (2 bits, values 0-3) to represent that, not 1.
WailaTrailTracer.OVERLAY_NUM_CHANNELS = 2

-- Out-of-grid cells read as unfilled -- the grid's own edge acts as an
-- automatic wall, same "clip to what was actually sampled" honesty the
-- debug radius already has for the wall-follower (see traceRegionGrid's
-- own hitGridEdge tracking below).
local function isFilledCell(grid, size, col, row)
    if col < 0 or col >= size or row < 0 or row >= size then
        return false
    end
    return grid[row][col] == true
end

-- Real, explicit removal, not a refactor for its own sake: this used to
-- be a real per-region noise floor (reject any connected component under
-- 9 cells), which required flood-fill CONNECTIVITY GROUPING to even
-- compute a "how big is this region" number in the first place. Real
-- request: "is trying to figure out regions while you're still in the
-- grid scan process not premature? would you not do that post process,
-- just on the square geometry?" -- yes. Grouping cells into named,
-- counted, individually-capped "regions" is itself a form of
-- understanding the shape, and it was happening BEFORE rendering, for no
-- reason rendering actually needs (a square doesn't care what region
-- it's in). It was also the direct cause of a real crash: closeGrid's
-- own gap-bridging chained a huge chunk of one tile's road/driveway/yard
-- network into a single 74,640-cell "region" (confirmed live, 28% of
-- the whole tile), which blew straight through the per-region cap this
-- noise floor was paired with. No more region concept here at all --
-- see collectBorderSegments below.

-- Real request: "bump the cap, calculate it so that it fills the tile...
-- I take a few s of lag spike" -- to actually PROVE full coverage (no
-- more silent truncation), the cap needs to cover every cell the tile
-- could possibly have, not a guessed-safe number. (DEBUG_TILE_SIZE /
-- GRID_CELL_SIZE)^2 is exactly that -- the tile's own real cell count,
-- so this cap can never truncate the current tile/resolution
-- combination. Was a flat 3000 as a real draw-call safety cap
-- (drawDebugLine PER FILLED CELL, EVERY FRAME); explicitly, deliberately
-- traded away for this one-time "does it actually fill the whole thing"
-- proof -- the scan itself was confirmed live at ms-scale, so the only
-- cost this can possibly reintroduce is render-side lag, accepted on
-- purpose here.
WailaTrailTracer.DEBUG_MAX_CELL_BOXES = math.floor((WailaTrailTracer.DEBUG_TILE_SIZE / WailaTrailTracer.GRID_CELL_SIZE) ^ 2)

-- Real, reusable step: flat row-major pass over the grid, no flood-fill,
-- no region grouping, no tracing, no simplification. Real, explicit
-- request ("test 1, let's see that we get the raw squares into the right
-- spot"): this is deliberately the dumbest possible scan -- every filled
-- cell becomes its own box, globally capped (see DEBUG_MAX_CELL_BOXES),
-- nothing else. Understanding shape (which cells belong "together",
-- which clusters are noise) is real work for a later step, once raw
-- positions are confirmed correct -- doing it here, before that, is
-- exactly the premature complexity that caused the 74,640-cell region
-- crash. touchesTileEdge is a simple global flag now (true if ANY filled
-- cell reaches the tile's own boundary), not a per-region concept.
-- Real request ("step 1.5"): "draw the actual edge squares a different
-- color -- anything that is not surrounded by other squares on 4
-- sides." Real, live-confirmed follow-up fix: classifying a whole CELL
-- as "edge" and then drawing all 4 of its sides was still too coarse --
-- a cell touching filled neighbors on 3 sides and open on 1 is a real
-- edge cell, but 3 of its 4 drawn sides were shared borders with other
-- filled cells, which is exactly the "lines still drawn in the center
-- grid" mess. Real fix, per the follow-up request ("delete the lines
-- between any squares that meet"): classify per EDGE, not per cell --
-- for each filled cell, only its side facing an UNFILLED neighbor (or
-- the tile's own edge) is ever emitted as a segment. Two touching
-- filled cells never emit their shared border at all, from either side.
-- A fully-interior cell (all 4 neighbors filled) emits nothing, so the
-- old separate "is this cell interior" check isn't needed anymore --
-- it falls out of this for free. Still pure local per-cell/per-edge
-- checks, no tracing, no chaining, no connectivity walk.
local function collectBorderSegments(grid, originX, originZ, size, cellSize)
    local segments = {}
    local cellCount = 0
    local touchesTileEdge = false
    local withinCap = true

    for row = 0, size - 1 do
        for col = 0, size - 1 do
            if isFilledCell(grid, size, col, row) then
                cellCount = cellCount + 1
                if col == 0 or row == 0 or col == size - 1 or row == size - 1 then
                    touchesTileEdge = true
                end

                local x0, z0 = originX + col * cellSize, originZ + row * cellSize
                local x1, z1 = x0 + cellSize, z0 + cellSize

                local sides = {
                    { isFilledCell(grid, size, col - 1, row), { x0, z0 }, { x0, z1 } }, -- left
                    { isFilledCell(grid, size, col + 1, row), { x1, z0 }, { x1, z1 } }, -- right
                    { isFilledCell(grid, size, col, row - 1), { x0, z0 }, { x1, z0 } }, -- top
                    { isFilledCell(grid, size, col, row + 1), { x0, z1 }, { x1, z1 } }, -- bottom
                }

                for _, side in ipairs(sides) do
                    local neighborFilled, a, b = side[1], side[2], side[3]
                    if not neighborFilled then
                        if withinCap and #segments >= WailaTrailTracer.DEBUG_MAX_CELL_BOXES then
                            withinCap = false
                        elseif withinCap then
                            table.insert(segments, { a, b })
                        end
                    end
                end
            end
        end
    end

    return {
        segments = segments,
        cellCount = cellCount,
        touchesTileEdge = touchesTileEdge,
        truncated = not withinCap,
    }
end

-- Real, explicit removal, not a refactor for its own sake: "step 2" used
-- to be row-run centerline tracing -- confirmed live, repeatedly, dead
-- wrong for anything but a true 1-wide corridor (three separate wide
-- areas in three separate screenshots all produced scribble, not a real
-- line -- collapsing a 2D area to a 1D skeleton just throws its width
-- away). The actual request ("who ever said i need a center line...  i
-- meant center of each 1-px segment... like the pink line, just
-- smoothing the corners") was about the BOUNDARY itself, not the whole
-- shape's interior -- take the already-correct border segments (see
-- collectBorderSegments), chain them into an ordered closed loop, then
-- replace each vertex with the midpoint of its own edge. Real reasoning
-- this actually works, same as the row-centerline idea's own reasoning
-- but applied to the right thing this time: a staircase corner's own
-- vertex is the +-1 cell noise; the MIDPOINT of the edge leading into
-- and out of it sits closer to the true line, so replacing every vertex
-- with its edge's midpoint smooths the staircase without needing
-- Douglas-Peucker or corner-cutting's own tolerance tuning at all.

-- Real request: "how many polygons you need will be a result of this
-- function, not earlier" -- no region grouping happens before this.
-- Segments are chained purely by shared endpoints: each closed loop
-- found this way already IS one real, valid, always-closed polygon (a
-- simple boundary's every corner has exactly 2 border segments meeting
-- there), not a guess. Fixed-precision string keys are exact here, not
-- a float-tolerance risk -- every point is a cell corner, an exact
-- multiple of cellSize.
local function pointKey(p)
    return string.format("%.4f:%.4f", p[1], p[2])
end

function WailaTrailTracer.chainBorderLoops(segments)
    local byEndpoint = {}
    for i, seg in ipairs(segments) do
        for endIndex = 1, 2 do
            local point, other = seg[endIndex], seg[3 - endIndex]
            local key = pointKey(point)
            byEndpoint[key] = byEndpoint[key] or {}
            table.insert(byEndpoint[key], { segmentIndex = i, other = other })
        end
    end

    local usedSegment = {}
    local loops = {}

    for startIndex, startSeg in ipairs(segments) do
        if not usedSegment[startIndex] then
            usedSegment[startIndex] = true
            local loop = { startSeg[1], startSeg[2] }
            local startKey = pointKey(startSeg[1])
            local currentPoint = startSeg[2]

            while pointKey(currentPoint) ~= startKey do
                local candidates = byEndpoint[pointKey(currentPoint)]
                local nextEntry = nil
                for _, entry in ipairs(candidates or {}) do
                    if not usedSegment[entry.segmentIndex] then
                        nextEntry = entry
                        break
                    end
                end
                if nextEntry == nil then
                    break -- dead end -- shouldn't happen on a simple boundary, bail safely
                end
                usedSegment[nextEntry.segmentIndex] = true
                currentPoint = nextEntry.other
                table.insert(loop, currentPoint)
            end

            -- Real bug this fixes, confirmed live (one corner staying
            -- sharp while the other 3 rounded off): the append above
            -- always fires, including on the very step that closes the
            -- loop back to its own start -- loop ends up {A, B, C, D, A}
            -- instead of the open-ring {A, B, C, D} every other closed
            -- shape in this file uses (wraparound is implicit via
            -- (i % n) + 1). That duplicate final point made the seam's
            -- own "closing edge" zero-length, which can't take part in
            -- Chaikin's corner-cutting the way a real edge does -- so
            -- the corner at the seam never got cut while the other 3 did.
            if #loop >= 2 and pointKey(loop[#loop]) == pointKey(loop[1]) then
                table.remove(loop)
            end

            if #loop >= 3 then
                table.insert(loops, loop)
            end
        end
    end

    return loops
end

-- Real, explicit fix -- confirmed live, a single midpoint per edge just
-- relocates the same sharp corners ("rotate the problem by 45deg and
-- still have corners everywhere"), it can never converge to smooth no
-- matter where along the edge that one point sits. Real Chaikin corner-
-- cutting instead: TWO new points per edge, at 1/4 and 3/4 along it
-- (not the midpoint), replacing the original vertex entirely. One pass
-- of that alone still has real corners too -- what actually smooths is
-- RUNNING IT AGAIN on its own output, repeatedly (see
-- WailaTrailTracer.SMOOTH_ITERATIONS below) -- each pass cuts the
-- previous pass's corners further, converging toward an actual smooth
-- curve, not just a rotated/relocated polygon with the same corner
-- count.
local function chaikinPass(loop)
    local n = #loop
    local result = {}
    for i = 1, n do
        local a, b = loop[i], loop[(i % n) + 1]
        local dx, dz = b[1] - a[1], b[2] - a[2]
        table.insert(result, { a[1] + dx * 0.25, a[2] + dz * 0.25 })
        table.insert(result, { a[1] + dx * 0.75, a[2] + dz * 0.75 })
    end
    return result
end

-- Real cost worth knowing, not just a magic number: point count DOUBLES
-- every iteration (a real, big region's loop can already be hundreds of
-- points before this even starts), so this trades render/line-count
-- cost for smoothness on purpose -- 3 iterations = 8x the original
-- point count. Debug-tool-only for now, same "accepted lag for a real
-- proof" footing as DEBUG_MAX_CELL_BOXES's own recent bump.
WailaTrailTracer.SMOOTH_ITERATIONS = 3

function WailaTrailTracer.smoothClosedLoop(loop)
    local n = #loop
    -- Real, confirmed-live exception: a minimal single-cell loop is
    -- exactly 4 points, and EVERY one of them is a sharp corner with no
    -- straight run buffering it from the next -- unlike a bigger
    -- rectangle (colinear points along each straight side absorb the
    -- Chaikin shift harmlessly, only its real corners round off),
    -- smoothing all 4 at once collapses the whole square inward instead
    -- of rounding anything. Leave it as the original square -- there's
    -- no real staircase here to smooth in the first place.
    if n <= 4 then
        return loop
    end

    local smoothed = loop
    for _ = 1, WailaTrailTracer.SMOOTH_ITERATIONS do
        smoothed = chaikinPass(smoothed)
    end
    return smoothed
end

-- Real request ("I thought we'd just paint polygons again like it's
-- doing with fields" -- confirmed live, that IS how fields are painted:
-- a baked density-map texture via MapOverlayGenerator, not vector
-- polygons). "Test 2": actually bake our own written cells into a
-- colored overlay texture the SAME native way, and hand back a handle
-- TaskMap can renderOverlay() directly -- see MapOverlayGenerator.lua's
-- own buildFieldMapOverlay/generateOverlay for the pattern this copies.
-- Persistent (map + overlay created once, reused every call) unlike
-- testDensityMapWrite's throwaway scratch map -- an overlay texture is
-- meant to be redrawn every frame, not rebuilt from scratch each time.
-- Same polygon-fill switch as testDensityMapWrite above -- see that
-- function's own header for why. Same OVERLAY_RESOLUTION fix too (used
-- to size this to the tile's own cell count, which is wrong -- see that
-- constant's own comment). Real request ("split all 3?"): takes
-- polygonsByMaterial (scanTileCells' own field) now, not a flat list --
-- each material writes its own MATERIAL_VALUE and gets its own
-- MATERIAL_COLOR, all baked into the one persistent overlay together.
-- Real request ("i see the overlay in the minimap constantly flash on/
-- off... it's useless"): resetDensityMapVisualizationOverlay +
-- generateDensityMapVisualizationOverlay was running on EVERY call to
-- this function -- once per chunk during a whole-map scan, i.e.
-- potentially every single frame -- and that regenerate is not
-- instantaneous (matches this file's own logs already showing
-- "notReady"/"rendering" alternating rapidly during active scans, never
-- investigated as a visual problem until now). The underlying DATA
-- (the DensityMapModifier writes) is cheap and always current regardless
-- -- only the TEXTURE regenerate needs throttling. forceRegenerate lets
-- tickWholeMapScan's own completion always get one final regenerate,
-- even if it lands inside the throttle window, so the last few scanned
-- chunks aren't missing from what's actually shown.
WailaTrailTracer.OVERLAY_REGENERATE_INTERVAL_SEC = 0.3
WailaTrailTracer.lastOverlayRegenerateTime = nil

function WailaTrailTracer.buildTestOverlay(polygonsByMaterial, forceRegenerate)
    local size = WailaTrailTracer.OVERLAY_RESOLUTION
    local numChannels = WailaTrailTracer.OVERLAY_NUM_CHANNELS
    if WailaTrailTracer.testOverlayMap == nil then
        WailaTrailTracer.testOverlayMap = createBitVectorMap("wailaTrailOverlayTestMap")
        loadBitVectorMapNew(WailaTrailTracer.testOverlayMap, size, size, numChannels, false)
        WailaTrailTracer.testOverlay = createDensityMapVisualizationOverlay("wailaTrailOverlayTest", size, size)
    end

    -- Real, explicit reversal: briefly "fixed" this to clear on every
    -- press, on the theory that multiple accumulated tiles were just
    -- confusing position/scale debugging. Wrong call -- real request:
    -- "ultimately we want to draw the whole map, and being able to see
    -- multiple tiles line up helps right now." Accumulating across
    -- presses is the feature that actually lets tile-to-tile alignment
    -- get checked at all -- clearing every time would throw that away.
    -- Deliberately never reset here -- the map is only ever allocated
    -- once, above, and every debug press just adds to it.
    local map = WailaTrailTracer.testOverlayMap
    local modifier = DensityMapModifier.new(map, 0, numChannels, g_terrainNode)

    for _, materialId in ipairs(SPLIT_MATERIALS) do
        local value = MATERIAL_VALUE[materialId]
        for _, polygon in ipairs(polygonsByMaterial[materialId] or {}) do
            modifier:clearPolygonPoints()
            for _, point in ipairs(polygon) do
                modifier:addPolygonPointWorldCoords(point[1], point[2])
            end
            modifier:executeSet(value)
        end
    end

    local now = getTimeSec()
    if not forceRegenerate and WailaTrailTracer.lastOverlayRegenerateTime ~= nil
        and now - WailaTrailTracer.lastOverlayRegenerateTime < WailaTrailTracer.OVERLAY_REGENERATE_INTERVAL_SEC then
        return
    end
    WailaTrailTracer.lastOverlayRegenerateTime = now

    -- (overlay, mapId, filterMapId, filterMask, firstChannel,
    -- numChannels, value, r, g, b) -- confirmed live against
    -- MapOverlayGenerator:buildFieldMapOverlay's own call shape. No
    -- filter map needed (filterMapId=0, filterMask=0), same "no filter"
    -- pattern that function uses too. One call per material now, each
    -- with its own MATERIAL_VALUE and MATERIAL_COLOR.
    resetDensityMapVisualizationOverlay(WailaTrailTracer.testOverlay)
    for _, materialId in ipairs(SPLIT_MATERIALS) do
        local color = materialColor(materialId)
        setDensityMapVisualizationOverlayStateColor(WailaTrailTracer.testOverlay, map, 0, 0, 0, numChannels, MATERIAL_VALUE[materialId], color[1], color[2], color[3])
    end
    generateDensityMapVisualizationOverlay(WailaTrailTracer.testOverlay)
end

WailaTrailTracer.ROAD_SPLINE_RIBBON_WIDTH = 10.0

-- Samples a real spline node into a flat {x,z} chain every stepMeters of
-- real spline length -- same getSplineLength/getSplinePosition(spline, t)
-- calls the base game's own TrafficSystem:validateSplines() already uses
-- (confirmed via decompile), just a coarser, fixed-meter step (that
-- function uses ~1m for collision validation; we only need enough points
-- to look like a smooth road on a map, not sub-meter precision).
local function sampleSplineChain(spline, stepMeters)
    local length = getSplineLength(spline)
    if length == nil or length <= 0 then
        return nil
    end
    local stepSize = stepMeters / length
    local chain = {}
    for t = 0, 1 + stepSize, stepSize do
        local clampedT = math.clamp(t, 0, 1)
        local x, _, z = getSplinePosition(spline, clampedT)
        table.insert(chain, { x, z })
    end
    return chain
end

-- Real request ("a scanner that sees where trees are is valuable input
-- for IW's replant feature too... go ahead, make sure both are drawn in
-- distinct colors"): CollisionFlag.TREE (bit 11, "A tree") and
-- CollisionFlag.WATER (bit 31, "A water plane") are both real, confirmed
-- collision flags (decompiled CollisionFlag.lua directly) -- same family
-- as CollisionFlag.ROAD/BUILDING this file's own isSpotClearOfStructures
-- already raycasts against, just never asked WHICH flag matched before,
-- only "is anything here at all". One raycast per point (combined
-- TREE|WATER mask), then CollisionFlag.getHasGroupFlagSet on the hit to
-- tell which one it actually was -- not two separate raycasts, same
-- "don't multiply the expensive part" reasoning rasterizeRegionMaterials
-- already applies to terrain queries. Deliberately its own separate
-- probe, NOT wired into isTrailMaterialAt (the hot per-cell path) --
-- same reasoning isSpotClearOfStructures' own header already gives for
-- why a raycast belongs nowhere near that call volume.
local FEATURE_COLLISION_MASK = bit32.bor(CollisionFlag.TREE, CollisionFlag.WATER)
local featureRaycastTarget = {}
function featureRaycastTarget:onFeatureRaycastCallback(hitObjectId)
    if hitObjectId ~= nil and hitObjectId ~= 0 then
        self.hit = hitObjectId
    end
    return false
end

-- Returns "TREE", "WATER", or nil. Raycast starts well above typical
-- tree canopy height (real trees can be tens of meters tall, unlike the
-- structure check's +3/-3m window which only needs to clear low
-- buildings/vehicles) and travels down through it -- relies on canopy
-- geometry having no real collision (a standard perf optimization,
-- collision usually lives on the trunk only), same assumption any
-- forestry-adjacent raycast in this game already has to make.
local function classifyGroundFeatureAt(x, z)
    local terrainHeight = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    featureRaycastTarget.hit = nil
    raycastClosest(x, terrainHeight + 40, z, 0, -1, 0, 45, "onFeatureRaycastCallback", featureRaycastTarget, FEATURE_COLLISION_MASK)
    if featureRaycastTarget.hit == nil then
        return nil
    end
    if CollisionFlag.getHasGroupFlagSet(featureRaycastTarget.hit, CollisionFlag.TREE) then
        return "TREE"
    end
    if CollisionFlag.getHasGroupFlagSet(featureRaycastTarget.hit, CollisionFlag.WATER) then
        return "WATER"
    end
    return nil
end

-- Deliberately coarse -- this isn't tracing a precise material boundary
-- (that's what the 1m trail scan is for), just "is there forest/water
-- roughly here", so a much bigger cell is the right tradeoff: raycasts
-- are real per-call cost, unlike the pure density-map reads the material
-- scan uses.
WailaTrailTracer.FEATURE_SCAN_CELL_SIZE = 8.0

local FEATURE_TREE = 1
local FEATURE_WATER = 2
local FEATURE_COLOR = {
    [FEATURE_TREE] = { 0.05, 0.35, 0.05 },
    [FEATURE_WATER] = { 0.15, 0.35, 0.85 },
}

-- Same grid shape as rasterizeRegion/rasterizeRegionMaterials, but
-- driven by classifyGroundFeatureAt instead of a terrain-material read --
-- kept as its own function rather than generalizing those two, since
-- they're the hot path and don't need the extra indirection cost.
local function rasterizeFeatureRegion(minX, minZ, maxX, maxZ, cellSize)
    local size = math.ceil((maxX - minX) / cellSize)
    local treeGrid, waterGrid = {}, {}
    for row = 0, size - 1 do
        local treeRow, waterRow = {}, {}
        for col = 0, size - 1 do
            local worldX = minX + (col + 0.5) * cellSize
            local worldZ = minZ + (row + 0.5) * cellSize
            local feature = classifyGroundFeatureAt(worldX, worldZ)
            treeRow[col] = feature == "TREE"
            waterRow[col] = feature == "WATER"
        end
        treeGrid[row] = treeRow
        waterGrid[row] = waterRow
    end
    return treeGrid, waterGrid, minX, minZ, size
end

-- Public: one debug-tile-sized area around (x, z) (same DEBUG_TILE_SIZE
-- footprint the single-press material debug tool uses, see
-- getTileBounds), scanned once, synchronously -- a real cost measurement
-- first (this logs cells/elapsed/ms-per-cell), same "measure the small
-- case before committing to a whole-map incremental scanner" discipline
-- the original material scan followed too. Reuses collectBorderSegments/
-- chainBorderLoops/smoothClosedLoop completely unchanged -- those only
-- ever cared about a plain boolean grid, never about what a cell being
-- "filled" actually means, so tree/water shapes come out through the
-- exact same, already-proven boundary tracer as the material scan.
function WailaTrailTracer.buildFeatureOverlay(x, z)
    local minX, minZ, maxX, maxZ = WailaTrailTracer.getTileBounds(x, z)
    local cellSize = WailaTrailTracer.FEATURE_SCAN_CELL_SIZE

    local startTime = getTimeSec()
    local treeGrid, waterGrid, originX, originZ, size = rasterizeFeatureRegion(minX, minZ, maxX, maxZ, cellSize)

    local treeResult = collectBorderSegments(treeGrid, originX, originZ, size, cellSize)
    local waterResult = collectBorderSegments(waterGrid, originX, originZ, size, cellSize)

    local treePolygons = {}
    for _, loop in ipairs(WailaTrailTracer.chainBorderLoops(treeResult.segments)) do
        table.insert(treePolygons, WailaTrailTracer.smoothClosedLoop(loop))
    end
    local waterPolygons = {}
    for _, loop in ipairs(WailaTrailTracer.chainBorderLoops(waterResult.segments)) do
        table.insert(waterPolygons, WailaTrailTracer.smoothClosedLoop(loop))
    end

    local overlaySize = WailaTrailTracer.OVERLAY_RESOLUTION
    if WailaTrailTracer.featureOverlayMap == nil then
        WailaTrailTracer.featureOverlayMap = createBitVectorMap("wailaFeatureOverlayMap")
        loadBitVectorMapNew(WailaTrailTracer.featureOverlayMap, overlaySize, overlaySize, 2, false)
        WailaTrailTracer.featureOverlay = createDensityMapVisualizationOverlay("wailaFeatureOverlay", overlaySize, overlaySize)
    end

    local map = WailaTrailTracer.featureOverlayMap
    local modifier = DensityMapModifier.new(map, 0, 2, g_terrainNode)

    for _, polygon in ipairs(treePolygons) do
        modifier:clearPolygonPoints()
        for _, point in ipairs(polygon) do
            modifier:addPolygonPointWorldCoords(point[1], point[2])
        end
        modifier:executeSet(FEATURE_TREE)
    end
    for _, polygon in ipairs(waterPolygons) do
        modifier:clearPolygonPoints()
        for _, point in ipairs(polygon) do
            modifier:addPolygonPointWorldCoords(point[1], point[2])
        end
        modifier:executeSet(FEATURE_WATER)
    end

    -- Dark forest green vs a saturated blue -- deliberately distinct from
    -- both the trail overlay's gray/tan/green AND the road overlay's
    -- yellow, so all three layers stay visually unambiguous stacked on
    -- the same map.
    resetDensityMapVisualizationOverlay(WailaTrailTracer.featureOverlay)
    local treeColor = FEATURE_COLOR[FEATURE_TREE]
    local waterColor = FEATURE_COLOR[FEATURE_WATER]
    setDensityMapVisualizationOverlayStateColor(WailaTrailTracer.featureOverlay, map, 0, 0, 0, 2, FEATURE_TREE, treeColor[1], treeColor[2], treeColor[3])
    setDensityMapVisualizationOverlayStateColor(WailaTrailTracer.featureOverlay, map, 0, 0, 0, 2, FEATURE_WATER, waterColor[1], waterColor[2], waterColor[3])
    generateDensityMapVisualizationOverlay(WailaTrailTracer.featureOverlay)

    local elapsedMs = (getTimeSec() - startTime) * 1000
    local cellCount = size * size
    log("buildFeatureOverlay: %dx%d cells (%.0fm each), %d tree polygon(s), %d water polygon(s), %.0fms total (%.3fms/cell)",
        size, size, cellSize, #treePolygons, #waterPolygons, elapsedMs, elapsedMs / cellCount)

    return true, cellCount, #treePolygons, #waterPolygons, elapsedMs
end

-- Real request ("classify space first, then construct new geometry" --
-- forwarded from a ChatGPT design discussion, "go ahead with the
-- forests"): a genuinely different classifier from everything else in
-- this file -- not material ID, not a raycast, pure STATISTICS over
-- several density-map reads per coarse cell. The insight: forest floor
-- isn't "the wrong material," it's "several DIFFERENT materials mixed
-- together in the same small area" (confirmed live via ground-level
-- screenshot -- real, deliberate map art, dirt/stone/gravel deliberately
-- sprinkled together), which a field or a real gravel patch never is
-- (one material, overwhelmingly dominant). Sample several points per
-- cell, count how many DISTINCT trail materials show up and whether any
-- one of them dominates -- "high diversity, no clear winner" is the
-- forest signature; "one material, everything else near zero" is a real
-- uniform surface (field, real road, real gravel patch, etc).
-- Deliberately scoped to ONE debug tile (getTileBounds, same as the
-- production material debug tool) -- a real test of the hypothesis
-- before committing to rewriting anything at whole-map scale, same
-- "prove the small case first" discipline the original material scan
-- itself followed.
WailaTrailTracer.FOREST_CELL_SIZE = 16.0
WailaTrailTracer.FOREST_SAMPLES_PER_AXIS = 3
-- Real, confirmed live regression: this was tightened to 3 (all of
-- dirt/gravel/stone) to suppress isolated false-positive blobs, but with
-- only 9 samples per 16m cell, real forest almost never shows all three
-- -- whole-map scans dropped from 12262 forest cells to 0-4, so nothing
-- got classified or excluded and the raw mottled material overlay showed
-- through everywhere. 2 is the value that detected the forest correctly;
-- the stray blobs are the min-size filter's job (FOREST_MIN_CELLS), not
-- this threshold's.
WailaTrailTracer.FOREST_MIN_DIVERSITY = 2
WailaTrailTracer.FOREST_MAX_DOMINANT_FRACTION = 0.75
-- Real request ("dirt + stone = forest, only dirt = dirt"): a factory
-- yard of dirt mixed with a lighter surface read as forest on diversity
-- alone. Forest floor on this map has STONE under it; require at least
-- one stone sample (nil = off, i.e. any two materials). Per-map taste --
-- see the per-map tuning note: this is a default, not a truth.
WailaTrailTracer.FOREST_REQUIRED_MATERIAL = MATERIAL_STONE

local FOREST_TRACKED_MATERIALS = { MATERIAL_DIRT, MATERIAL_GRAVEL, MATERIAL_STONE }

-- Real, deliberate exclusion: on-field ground gets the SAME treatment
-- getTrailMaterialKindAt already gives it (registered fields have their
-- own real boundary tracer, WailaFieldBoundaryTracer -- this was never
-- forest's problem to solve). A cell counts as "on field" if ANY sample
-- lands on one, not just the center -- a cell straddling a field edge
-- should not get classified as forest just because its center happens to
-- miss the boundary by a meter.
-- Real, confirmed live bug ("last version scanned exactly these fields
-- as forest"): the symmetric hole-filler below (smoothForestGrid) works
-- on a plain boolean grid with no idea WHY a cell is false -- a real
-- registered field poking a small notch into forest reads as just
-- another small non-forest hole, and gets filled back in as forest,
-- silently undoing the exclusion this function already correctly applied.
-- Same risk for roads. Real fix: return a SECOND value, isProtected --
-- true for field/road cells specifically (real ground truth, never
-- eligible for filling regardless of component size), false for cells
-- that are merely statistically below the forest threshold (genuinely
-- fair game for the noise filter).
local function classifyForestCell(cellMinX, cellMinZ, cellSize, samplesPerAxis)
    local counts = {}
    local totalSamples = 0

    local step = cellSize / samplesPerAxis
    for i = 0, samplesPerAxis - 1 do
        for j = 0, samplesPerAxis - 1 do
            local sampleX = cellMinX + (i + 0.5) * step
            local sampleZ = cellMinZ + (j + 0.5) * step
            if FSDensityMapUtil.getFieldDataAtWorldPosition(sampleX, 0, sampleZ) then
                return false, true, false
            end
            -- Real, confirmed live gap: this classifier had zero road
            -- awareness -- a coarse cell straddling or running alongside
            -- a real road reads as "high diversity" the same way forest
            -- dithering does (road material + nearby forest material in
            -- the same cell), so roads were silently getting absorbed
            -- into the forest blob instead of staying their own thing.
            -- Same real road-spline exclusion getTrailMaterialKindAt
            -- already uses (isNearRealRoad, built earlier this session) --
            -- any sample near a real road means this cell is never
            -- forest, same "any sample disqualifies the whole cell"
            -- conservatism the field check above already uses.
            if isNearRealRoad(sampleX, sampleZ) then
                return false, true, true
            end
            local _, _, _, _, materialId = getTerrainAttributesAtWorldPos(g_terrainNode, sampleX, 0, sampleZ, true, true, true, true, false)
            counts[materialId] = (counts[materialId] or 0) + 1
            totalSamples = totalSamples + 1
        end
    end

    if totalSamples == 0 then
        return false, false, false
    end

    local diversity = 0
    local maxCount = 0
    for _, materialId in ipairs(FOREST_TRACKED_MATERIALS) do
        local count = counts[materialId] or 0
        if count > 0 then
            diversity = diversity + 1
        end
        if count > maxCount then
            maxCount = count
        end
    end

    local requiredMaterial = WailaTrailTracer.FOREST_REQUIRED_MATERIAL
    if requiredMaterial ~= nil and (counts[requiredMaterial] or 0) == 0 then
        return false, false, false
    end

    local dominantFraction = maxCount / totalSamples
    -- Real, confirmed live regression (reverted, see git history/session
    -- notes): a tree-presence requirement was tried here to rule out a
    -- quarry/yard's edge reading as forest via material mix alone, but it
    -- broke real forest detection that worked correctly without it, in
    -- the same area -- likely because classifyGroundFeatureAt's own
    -- header-flagged assumption ("canopy has no real collision") doesn't
    -- hold on this map's tree assets. Material diversity + the min-size
    -- filter is the committable baseline; the quarry problem stays open.
    return diversity >= WailaTrailTracer.FOREST_MIN_DIVERSITY and dominantFraction < WailaTrailTracer.FOREST_MAX_DOMINANT_FRACTION, false, false
end

-- Debug survey: which terrain layer fingerprints (r/g/b/w, the first four
-- returns of getTerrainAttributesAtWorldPos) exist on this map, and where
-- they occur -- inside forest-classified cells, in protected (road/field
-- margin) cells, or in plain open ground. Answers "does forest floor ever
-- share the road layer's fingerprint?" without standing in forests by hand.
-- Samples the centre of every 2nd coarse cell in each axis (~4k cells, ~40k
-- terrain reads) -- a one-shot debug action, not part of any scan.
function WailaTrailTracer.logLayerFingerprintSurvey()
    local terrainSize = (g_currentMission ~= nil and g_currentMission.terrainSize) or 2048
    local worldMin = -terrainSize * 0.5
    local cell = WailaTrailTracer.FOREST_CELL_SIZE
    local cells = math.floor(terrainSize / cell)
    local startTime = getTimeSec()
    local stats, total, skippedFields = {}, 0, 0

    for gx = 1, cells - 1, 2 do
        for gz = 1, cells - 1, 2 do
            local minX, minZ = worldMin + gx * cell, worldMin + gz * cell
            local cx, cz = minX + cell * 0.5, minZ + cell * 0.5
            if FSDensityMapUtil.getFieldDataAtWorldPosition(cx, 0, cz) then
                skippedFields = skippedFields + 1
            else
                local isForest, isProtected = classifyForestCell(minX, minZ, cell, WailaTrailTracer.FOREST_SAMPLES_PER_AXIS)
                local r, g, b, w, materialId = getTerrainAttributesAtWorldPos(g_terrainNode, cx, 0, cz, true, true, true, true, false)
                local key = string.format("%.4f/%.4f/%.4f/%.4f", r or 0, g or 0, b or 0, w or 0)
                local entry = stats[key]
                if entry == nil then
                    entry = { count = 0, forest = 0, protected = 0, material = materialId }
                    stats[key] = entry
                end
                entry.count = entry.count + 1
                if isForest then
                    entry.forest = entry.forest + 1
                elseif isProtected then
                    entry.protected = entry.protected + 1
                end
                total = total + 1
            end
        end
    end

    local rows = {}
    for key, entry in pairs(stats) do
        rows[#rows + 1] = { key = key, entry = entry }
    end
    table.sort(rows, function(a, b) return a.entry.count > b.entry.count end)

    log("LayerSurvey: %d cell centre(s) sampled (%d on fields skipped), %d distinct layer fingerprint(s), %.0fms",
        total, skippedFields, #rows, (getTimeSec() - startTime) * 1000)
    log("LayerSurvey: fingerprint r/g/b/w | material | cells | %% in forest cells | %% in road/field-margin cells")
    for index = 1, math.min(30, #rows) do
        local entry = rows[index].entry
        log("LayerSurvey: %s | %s [%s] | %d | %.0f%% | %.0f%%", rows[index].key, WailaTerrain.getMaterialName(entry.material), tostring(entry.material),
            entry.count, entry.forest / entry.count * 100, entry.protected / entry.count * 100)
    end
end

-- ===== Learned terrain-layer classes =====
-- Real finding (layer survey on CreativeHorizon): the first four returns
-- of getTerrainAttributesAtWorldPos (r/g/b/w) name the dominant paint
-- LAYER exactly, while the material id attached to the same layer varies
-- by position (the forest-floor layer read GRASS, GRAVEL and DIRT in
-- different places). The road layer was 100% distinct from forest floor
-- and from open grass, and rare (~2% of the map). So instead of
-- material statistics + thresholds, each map TEACHES the classes:
--   road   = layers common along the aiSystem road splines (ground
--            truth) but rare on the whole map
--   forest = layers that are mostly inside cells the older statistical
--            classifier calls forest (bootstrap)
-- One terrain read per cell then classifies it -- no windows, no jitter.
WailaTrailTracer.LAYER_LEARN_MIN_SPLINE_SHARE = 0.25
WailaTrailTracer.LAYER_LEARN_MAX_MAP_SHARE = 0.10
WailaTrailTracer.LAYER_LEARN_MIN_FOREST_SHARE = 0.60
WailaTrailTracer.LAYER_LEARN_MIN_FOREST_CELLS = 8
WailaTrailTracer.LAYER_CLASS_ROAD = 1
WailaTrailTracer.LAYER_CLASS_FOREST = 2
WailaTrailTracer.layerClassLearned = false
local layerClassByKey = {}

local function layerKey(r, g, b, w)
    return math.floor((r or 0) * 1000 + 0.5) * 1000000000 + math.floor((g or 0) * 1000 + 0.5) * 1000000
        + math.floor((b or 0) * 1000 + 0.5) * 1000 + math.floor((w or 0) * 1000 + 0.5)
end

local function layerKeyToString(key)
    local w = key % 1000
    local b = math.floor(key / 1000) % 1000
    local g = math.floor(key / 1000000) % 1000
    local r = math.floor(key / 1000000000)
    return string.format("%.4f/%.4f/%.4f/%.4f", r / 1000, g / 1000, b / 1000, w / 1000)
end

-- "0.1570/0.1410/0.1220/0.0000" (the HUD's fingerprint text) -> class or nil
function WailaTrailTracer.getLayerClassOfFingerprint(text)
    local r, g, b, w = string.match(text or "", "^([%d%.]+)/([%d%.]+)/([%d%.]+)/([%d%.]+)$")
    if r == nil then
        return nil
    end
    return layerClassByKey[layerKey(tonumber(r), tonumber(g), tonumber(b), tonumber(w))]
end

-- Foliage presence at a point. Real finding (parking lot read as forest): the lot
-- carries the forest-floor LAYER but its foliage is empty, while real forest is
-- full of groundFoliage / forestPlants / decoBush. Reads the foliage density
-- planes that carry type information (WailaFoliageInspector resolves them, see
-- its header): about two reads per call on this map. nil when the map has none,
-- so callers can fall back to "assume foliage".
local foliagePlanes = nil
local function resolveFoliagePlanes()
    if foliagePlanes ~= nil then
        return foliagePlanes
    end
    foliagePlanes = {}
    if WailaFoliageInspector ~= nil then
        local inspector = WailaFoliageInspector.new()
        local data = inspector:loadFoliageDebugData()
        if data ~= nil then
            inspector:resolveFoliagePlaneIds(data)
            for _, layer in ipairs(data.multilayers) do
                if layer.terrainDataPlaneId ~= nil and (layer.numTypeIndexChannels or 0) > 0 then
                    foliagePlanes[#foliagePlanes + 1] = {
                        id = layer.terrainDataPlaneId,
                        channels = layer.numTypeIndexChannels,
                        typeMask = 2 ^ layer.numTypeIndexChannels - 1,
                    }
                end
            end
        end
    end
    return foliagePlanes
end

function WailaTrailTracer.foliageAvailable()
    return #resolveFoliagePlanes() > 0
end

function WailaTrailTracer.hasFoliageAt(x, z)
    for _, plane in ipairs(foliagePlanes or resolveFoliagePlanes()) do
        local bits = getDensityAtWorldPos(plane.id, x, 0, z)
        if bits > 0 and bitAND(bits, plane.typeMask) > 0 and bitShiftRight(bits, plane.channels) > 0 then
            return true
        end
    end
    return false
end

-- One terrain read, both answers: the learned class (nil = open ground,
-- details, ...) and the position's material id.
function WailaTrailTracer.getLayerCellAt(x, z)
    local r, g, b, w, materialId = getTerrainAttributesAtWorldPos(g_terrainNode, x, 0, z, true, true, true, true, false)
    return layerClassByKey[layerKey(r, g, b, w)], materialId
end

-- One terrain read. nil = not a learned class (open ground, details, ...).
function WailaTrailTracer.getLayerClassAt(x, z)
    local r, g, b, w = getTerrainAttributesAtWorldPos(g_terrainNode, x, 0, z, true, true, true, true, false)
    return layerClassByKey[layerKey(r, g, b, w)]
end

function WailaTrailTracer.learnLayerClasses()
    local startTime = getTimeSec()
    layerClassByKey = {}
    WailaTrailTracer.layerClassLearned = false

    local terrainSize = (g_currentMission ~= nil and g_currentMission.terrainSize) or 2048
    local worldMin = -terrainSize * 0.5
    local cell = WailaTrailTracer.FOREST_CELL_SIZE
    local cells = math.floor(terrainSize / cell)

    -- whole-map layer shares + forest association, every 4th coarse cell per axis
    local mapCounts, forestCounts, mapTotal = {}, {}, 0
    for gx = 1, cells - 1, 4 do
        for gz = 1, cells - 1, 4 do
            local minX, minZ = worldMin + gx * cell, worldMin + gz * cell
            local cx, cz = minX + cell * 0.5, minZ + cell * 0.5
            if not FSDensityMapUtil.getFieldDataAtWorldPosition(cx, 0, cz) then
                local isForest = classifyForestCell(minX, minZ, cell, WailaTrailTracer.FOREST_SAMPLES_PER_AXIS)
                local r, g, b, w = getTerrainAttributesAtWorldPos(g_terrainNode, cx, 0, cz, true, true, true, true, false)
                local key = layerKey(r, g, b, w)
                mapCounts[key] = (mapCounts[key] or 0) + 1
                if isForest then
                    forestCounts[key] = (forestCounts[key] or 0) + 1
                end
                mapTotal = mapTotal + 1
            end
        end
    end

    -- ground truth for roads: layers along the real road splines
    local splineCounts, splineTotal, splineCount = {}, 0, 0
    if g_currentMission ~= nil and g_currentMission.aiSystem ~= nil then
        for spline in pairs(g_currentMission.aiSystem:getRoadSplines()) do
            local chain = sampleSplineChain(spline, 6.0)
            if chain ~= nil then
                splineCount = splineCount + 1
                for _, point in ipairs(chain) do
                    local r, g, b, w = getTerrainAttributesAtWorldPos(g_terrainNode, point[1], 0, point[2], true, true, true, true, false)
                    local key = layerKey(r, g, b, w)
                    splineCounts[key] = (splineCounts[key] or 0) + 1
                    splineTotal = splineTotal + 1
                end
            end
        end
    end

    local roadKeys, forestKeys = 0, 0
    for key, count in pairs(splineCounts) do
        local splineShare = count / splineTotal
        local mapShare = (mapCounts[key] or 0) / math.max(1, mapTotal)
        if splineShare >= WailaTrailTracer.LAYER_LEARN_MIN_SPLINE_SHARE and mapShare <= WailaTrailTracer.LAYER_LEARN_MAX_MAP_SHARE then
            layerClassByKey[key] = WailaTrailTracer.LAYER_CLASS_ROAD
            roadKeys = roadKeys + 1
            log("LayerClasses: ROAD   %s  (%.0f%% of spline samples, %.1f%% of map)", layerKeyToString(key), splineShare * 100, mapShare * 100)
        end
    end
    for key, count in pairs(mapCounts) do
        local forest = forestCounts[key] or 0
        if layerClassByKey[key] == nil and forest >= WailaTrailTracer.LAYER_LEARN_MIN_FOREST_CELLS
            and forest / count >= WailaTrailTracer.LAYER_LEARN_MIN_FOREST_SHARE then
            layerClassByKey[key] = WailaTrailTracer.LAYER_CLASS_FOREST
            forestKeys = forestKeys + 1
            log("LayerClasses: FOREST %s  (%.0f%% of its %d cells in forest cells, %.1f%% of map)", layerKeyToString(key), forest / count * 100, count, count / math.max(1, mapTotal) * 100)
        end
    end

    WailaTrailTracer.layerClassLearned = roadKeys + forestKeys > 0
    log("LayerClasses: learned %d road + %d forest layer(s) from %d spline(s) / %d spline sample(s), %d map cell(s), %.0fms",
        roadKeys, forestKeys, splineCount, splineTotal, mapTotal, (getTimeSec() - startTime) * 1000)
end

-- Debug overlay: classify a square of 1m cells around (x, z) with the learned
-- table, one terrain read per cell, and draw as row-run rectangles on their own
-- overlay (TaskMap draws it): road (value 1), forest = forest-floor layer WITH
-- foliage (value 2), forest-floor layer WITHOUT foliage (value 3: parking lot,
-- worn path, clearing).
WailaTrailTracer.LAYER_OVERLAY_HALF_SIZE = 96
function WailaTrailTracer.buildLayerClassOverlay(centerX, centerZ)
    if not WailaTrailTracer.layerClassLearned then
        WailaTrailTracer.learnLayerClasses()
    end
    local size = WailaTrailTracer.OVERLAY_RESOLUTION
    if WailaTrailTracer.layerClassOverlayMap == nil then
        WailaTrailTracer.layerClassOverlayMap = createBitVectorMap("wailaLayerClassOverlayMap")
        loadBitVectorMapNew(WailaTrailTracer.layerClassOverlayMap, size, size, 3, false)
        WailaTrailTracer.layerClassOverlay = createDensityMapVisualizationOverlay("wailaLayerClassOverlay", size, size)
    end

    local startTime = getTimeSec()
    local half = WailaTrailTracer.LAYER_OVERLAY_HALF_SIZE
    local minX, minZ = math.floor(centerX) - half, math.floor(centerZ) - half
    local modifier = DensityMapModifier.new(WailaTrailTracer.layerClassOverlayMap, 0, 3, g_terrainNode)
    WailaTrailTracer.clearLayerOverlayWindow(modifier, minX, minZ, half * 2)
    local cellsPerSide = half * 2
    local rects, reads = 0, 0

    -- pass 1: one terrain read per cell (+ foliage for forest-layer cells) -> class grid
    local classGrid = {}
    local useFoliage = WailaTrailTracer.foliageAvailable()
    local forestCells, bareCells = 0, 0
    for zi = 0, cellsPerSide - 1 do
        local classRow = {}
        local z = minZ + zi + 0.5
        for xi = 0, cellsPerSide - 1 do
            local x = minX + xi + 0.5
            local class = WailaTrailTracer.getLayerClassAt(x, z)
            reads = reads + 1
            if class == WailaTrailTracer.LAYER_CLASS_FOREST then
                if useFoliage and not WailaTrailTracer.hasFoliageAt(x, z) then
                    class = 3
                    bareCells = bareCells + 1
                else
                    forestCells = forestCells + 1
                end
            end
            classRow[xi] = class
        end
        classGrid[zi] = classRow
    end

    -- pass 3: draw row runs
    for zi = 0, cellsPerSide - 1 do
        local row = classGrid[zi]
        local runClass, runStart = nil, nil
        for xi = 0, cellsPerSide do
            local class = nil
            if xi < cellsPerSide then
                class = row[xi]
            end
            if class ~= runClass then
                if runClass ~= nil then
                    modifier:clearPolygonPoints()
                    modifier:addPolygonPointWorldCoords(minX + runStart, minZ + zi)
                    modifier:addPolygonPointWorldCoords(minX + xi, minZ + zi)
                    modifier:addPolygonPointWorldCoords(minX + xi, minZ + zi + 1)
                    modifier:addPolygonPointWorldCoords(minX + runStart, minZ + zi + 1)
                    modifier:executeSet(runClass)
                    rects = rects + 1
                end
                runClass, runStart = class, xi
            end
        end
    end

    resetDensityMapVisualizationOverlay(WailaTrailTracer.layerClassOverlay)
    setDensityMapVisualizationOverlayStateColor(WailaTrailTracer.layerClassOverlay, WailaTrailTracer.layerClassOverlayMap, 0, 0, 0, 3, WailaTrailTracer.LAYER_CLASS_ROAD, 1.0, 0.35, 0.0)
    setDensityMapVisualizationOverlayStateColor(WailaTrailTracer.layerClassOverlay, WailaTrailTracer.layerClassOverlayMap, 0, 0, 0, 3, WailaTrailTracer.LAYER_CLASS_FOREST, 0.0, 0.9, 0.4)
    setDensityMapVisualizationOverlayStateColor(WailaTrailTracer.layerClassOverlay, WailaTrailTracer.layerClassOverlayMap, 0, 0, 0, 3, 3, 1.0, 0.0, 1.0)
    generateDensityMapVisualizationOverlay(WailaTrailTracer.layerClassOverlay)
    log("buildLayerClassOverlay: %dx%dm around %.0f/%.0f, %d read(s), forest %d cell(s), forest layer without foliage %d cell(s), %d rectangle(s), %.0fms",
        half * 2, half * 2, centerX, centerZ, reads, forestCells, bareCells, rects, (getTimeSec() - startTime) * 1000)
end

-- protectedGrid marks cells that are false for a real, ground-truth
-- reason (field/road, see classifyForestCell) rather than merely falling
-- below the statistical forest threshold -- those cells never get
-- flipped to forest by the fill direction below, no matter how small
-- the surrounding false component is.
-- voidGrid (optional): cells OUTSIDE the map. They are not ground at all,
-- so they must not take part in any component: without this, a hole at
-- the map border flood-filled straight into the out-of-map margin of the
-- window, "touched the window edge", and was never filled (confirmed
-- live: specks along the map border survived the hole filter).
local function smoothForestGrid(grid, protectedGrid, size, minIslandCells, minHoleCells, voidGrid)
    local visited = {}
    for row = 0, size - 1 do
        visited[row] = {}
        if voidGrid ~= nil then
            for col = 0, size - 1 do
                if voidGrid[row][col] then
                    visited[row][col] = true
                end
            end
        end
    end

    local function getCell(row, col)
        local gridRow = grid[row]
        return gridRow ~= nil and gridRow[col] == true
    end

    local function isProtected(row, col)
        local protectedRow = protectedGrid[row]
        return protectedRow ~= nil and protectedRow[col] == true
    end

    -- Flat parallel arrays instead of a {row, col} table per cell and a
    -- neighbour table per step: this ran for every chunk and the
    -- allocations were most of the forest pass's cost (measured).
    local function floodFill(startRow, startCol, value)
        local stackR, stackC, top = { startRow }, { startCol }, 1
        local cellsR, cellsC, count = {}, {}, 0
        local touchesEdge = false
        visited[startRow][startCol] = true
        local last = size - 1
        while top > 0 do
            local row, col = stackR[top], stackC[top]
            top = top - 1
            count = count + 1
            cellsR[count], cellsC[count] = row, col
            if row == 0 or col == 0 or row == last or col == last then
                touchesEdge = true
            end
            for direction = 1, 4 do
                local nRow, nCol = row, col
                if direction == 1 then nRow = row - 1
                elseif direction == 2 then nRow = row + 1
                elseif direction == 3 then nCol = col - 1
                else nCol = col + 1 end
                if nRow >= 0 and nRow <= last and nCol >= 0 and nCol <= last
                    and not visited[nRow][nCol] and getCell(nRow, nCol) == value then
                    visited[nRow][nCol] = true
                    top = top + 1
                    stackR[top], stackC[top] = nRow, nCol
                end
            end
        end
        return cellsR, cellsC, count, touchesEdge
    end

    for row = 0, size - 1 do
        for col = 0, size - 1 do
            if not visited[row][col] then
                local value = getCell(row, col)
                local cellsR, cellsC, count, touchesEdge = floodFill(row, col, value)
                local threshold = value and minIslandCells or minHoleCells
                if not touchesEdge and count < threshold then
                    for i = 1, count do
                        local cellRow, cellCol = cellsR[i], cellsC[i]
                        if not isProtected(cellRow, cellCol) then
                            grid[cellRow][cellCol] = not value
                        end
                    end
                end
            end
        end
    end
end

-- Display-grade tolerance: the overlay texel is ~2m, so detail below
-- that costs points and shows nothing. Roads are drawn on top of the
-- forest layer anyway, nobody sees a metre of forest edge.
WailaTrailTracer.FOREST_REFINE_SIMPLIFY_TOLERANCE = 2.0
-- Shared by both buildForestOverlay (debug button) and tickWholeMapScan
-- (whole-map, per chunk) -- takes an ALREADY-rasterized (and size-
-- filtered) grid, since tickWholeMapScan needs that same grid for the
-- detailed-scan exclusion lookup too and shouldn't rasterize twice.
-- Real request ("1 outline, couple of points, done"): forest polygons
-- were Chaikin-smoothed, which MULTIPLIES the point count (~8x for 3
-- iterations) -- the opposite of what a 16m coarse outline needs. A grid
-- trace puts a vertex at every cell-corner step; Douglas-Peucker with a
-- tolerance of ~0.75 cell collapses a staircase into straight runs
-- (the largest a 16m stair-step can deviate from its diagonal is ~11m)
-- while still keeping real features like a one-cell notch (16m deep).
-- Real, confirmed live: 12m was TOO aggressive -- polygons visibly cut
-- corners and drifted off the actual forest edge ("simplifying too
-- much"). 6m (~0.4 cell) still merges straight/collinear runs but
-- keeps single-cell steps, so the outline follows the classified cells.
-- Closed-loop wrapper around the existing open-polyline simplifyBoundary
-- (which has a real prior divide-by-zero history, so reused rather than
-- rewritten): split at the vertex farthest from vertex 1 so neither half
-- gets a near-degenerate baseline, simplify each half, rejoin without
-- duplicated endpoints (open-ring convention, same as every loop here).
WailaTrailTracer.FOREST_SIMPLIFY_TOLERANCE = 6.0

local function simplifyClosedLoop(loop, tolerance)
    local n = #loop
    if n <= 4 then
        return loop
    end

    local farIndex, farDistSq = 2, 0
    for i = 2, n do
        local dx, dz = loop[i][1] - loop[1][1], loop[i][2] - loop[1][2]
        local distSq = dx * dx + dz * dz
        if distSq > farDistSq then
            farDistSq, farIndex = distSq, i
        end
    end

    local firstHalf, secondHalf = {}, {}
    for i = 1, farIndex do
        table.insert(firstHalf, loop[i])
    end
    for i = farIndex, n do
        table.insert(secondHalf, loop[i])
    end
    table.insert(secondHalf, loop[1])

    local simplifiedFirst = simplifyBoundary(firstHalf, tolerance)
    local simplifiedSecond = simplifyBoundary(secondHalf, tolerance)

    local result = {}
    for i = 1, #simplifiedFirst do
        table.insert(result, simplifiedFirst[i])
    end
    for i = 2, #simplifiedSecond - 1 do
        table.insert(result, simplifiedSecond[i])
    end

    if #result < 3 then
        return loop
    end
    return result
end

-- ===== Curve fit for the final forest outline =====
-- Real request ("any stairs immediately make a human think bug ... has
-- to look like we have this under control"): the traced 1m outline is
-- smooth at the bitmap level but still a pixel staircase as a polygon.
-- A human sees a few smooth arcs that meet at corners (the user's own
-- "2 bezier curves" drawing), so: split the outline at its real corners,
-- fit ONE cubic Bezier per section (Schneider's least-squares fit,
-- Graphics Gems I), flatten back to a sparse polyline for drawing
-- (DensityMapModifier only takes straight polygon points). Chunk seams
-- are straight cuts and stay exactly straight: vertices on the tile
-- boundary are fixed breakpoints, never smoothed across.
WailaTrailTracer.FOREST_CURVE_FIT = true
WailaTrailTracer.FOREST_CURVE_TOLERANCE = 1.5
WailaTrailTracer.FOREST_CURVE_CORNER_ANGLE_DEG = 75
WailaTrailTracer.FOREST_CURVE_CORNER_WINDOW = 5
WailaTrailTracer.FOREST_CURVE_FLATTEN_STEP = 5.0

local function normalize2(x, z, fallbackX, fallbackZ)
    local length = math.sqrt(x * x + z * z)
    if length < 1e-9 then
        local fallbackLength = math.sqrt(fallbackX * fallbackX + fallbackZ * fallbackZ)
        if fallbackLength < 1e-9 then
            return 1, 0
        end
        return fallbackX / fallbackLength, fallbackZ / fallbackLength
    end
    return x / length, z / length
end

local function bezierPoint(b, t)
    local mt = 1 - t
    local b0, b1, b2, b3 = mt * mt * mt, 3 * t * mt * mt, 3 * t * t * mt, t * t * t
    return b0 * b[1][1] + b1 * b[2][1] + b2 * b[3][1] + b3 * b[4][1],
        b0 * b[1][2] + b1 * b[2][2] + b2 * b[3][2] + b3 * b[4][2]
end

local function bezierDerivative(b, t)
    local mt = 1 - t
    local c0, c1, c2 = 3 * mt * mt, 6 * mt * t, 3 * t * t
    return c0 * (b[2][1] - b[1][1]) + c1 * (b[3][1] - b[2][1]) + c2 * (b[4][1] - b[3][1]),
        c0 * (b[2][2] - b[1][2]) + c1 * (b[3][2] - b[2][2]) + c2 * (b[4][2] - b[3][2])
end

local function bezierSecondDerivative(b, t)
    local mt = 1 - t
    local ax, az = b[3][1] - 2 * b[2][1] + b[1][1], b[3][2] - 2 * b[2][2] + b[1][2]
    local bx, bz = b[4][1] - 2 * b[3][1] + b[2][1], b[4][2] - 2 * b[3][2] + b[2][2]
    return 6 * (mt * ax + t * bx), 6 * (mt * az + t * bz)
end

local function chordLengthParameterize(d, first, last)
    local u = { [first] = 0 }
    for i = first + 1, last do
        local dx, dz = d[i][1] - d[i - 1][1], d[i][2] - d[i - 1][2]
        u[i] = u[i - 1] + math.sqrt(dx * dx + dz * dz)
    end
    local total = u[last]
    if total < 1e-9 then
        for i = first + 1, last do
            u[i] = (i - first) / (last - first)
        end
    else
        for i = first + 1, last do
            u[i] = u[i] / total
        end
    end
    return u
end

local function generateBezier(d, first, last, u, t1x, t1z, t2x, t2z)
    local p0, p3 = d[first], d[last]
    local c00, c01, c11, x0, x1 = 0, 0, 0, 0, 0
    for i = first, last do
        local t = u[i]
        local mt = 1 - t
        local b0, b1, b2, b3 = mt * mt * mt, 3 * t * mt * mt, 3 * t * t * mt, t * t * t
        local a1x, a1z = t1x * b1, t1z * b1
        local a2x, a2z = t2x * b2, t2z * b2
        c00 = c00 + a1x * a1x + a1z * a1z
        c01 = c01 + a1x * a2x + a1z * a2z
        c11 = c11 + a2x * a2x + a2z * a2z
        local tmpX = d[i][1] - (p0[1] * (b0 + b1) + p3[1] * (b2 + b3))
        local tmpZ = d[i][2] - (p0[2] * (b0 + b1) + p3[2] * (b2 + b3))
        x0 = x0 + a1x * tmpX + a1z * tmpZ
        x1 = x1 + a2x * tmpX + a2z * tmpZ
    end

    local detC0C1 = c00 * c11 - c01 * c01
    local alphaL, alphaR = 0, 0
    if math.abs(detC0C1) > 1e-12 then
        alphaL = (x0 * c11 - x1 * c01) / detC0C1
        alphaR = (c00 * x1 - c01 * x0) / detC0C1
    end

    local segLength = math.sqrt((p3[1] - p0[1]) ^ 2 + (p3[2] - p0[2]) ^ 2)
    local epsilon = 1e-6 * segLength
    if alphaL < epsilon or alphaR < epsilon then
        alphaL, alphaR = segLength / 3, segLength / 3
    end

    return {
        { p0[1], p0[2] },
        { p0[1] + t1x * alphaL, p0[2] + t1z * alphaL },
        { p3[1] + t2x * alphaR, p3[2] + t2z * alphaR },
        { p3[1], p3[2] },
    }
end

local function reparameterize(d, first, last, u, bez)
    local result = {}
    for i = first, last do
        local qx, qz = bezierPoint(bez, u[i])
        local q1x, q1z = bezierDerivative(bez, u[i])
        local q2x, q2z = bezierSecondDerivative(bez, u[i])
        local numerator = (qx - d[i][1]) * q1x + (qz - d[i][2]) * q1z
        local denominator = q1x * q1x + q1z * q1z + (qx - d[i][1]) * q2x + (qz - d[i][2]) * q2z
        if math.abs(denominator) < 1e-12 then
            result[i] = u[i]
        else
            result[i] = math.min(1, math.max(0, u[i] - numerator / denominator))
        end
    end
    return result
end

local function computeMaxCurveError(d, first, last, bez, u)
    local maxDist, splitIndex = 0, math.floor((first + last) / 2)
    for i = first + 1, last - 1 do
        local px, pz = bezierPoint(bez, u[i])
        local dist = math.sqrt((px - d[i][1]) ^ 2 + (pz - d[i][2]) ^ 2)
        if dist >= maxDist then
            maxDist, splitIndex = dist, i
        end
    end
    return maxDist, splitIndex
end

local function fitCubic(d, first, last, t1x, t1z, t2x, t2z, tolerance, out)
    if last - first == 1 then
        local dist = math.sqrt((d[last][1] - d[first][1]) ^ 2 + (d[last][2] - d[first][2]) ^ 2) / 3
        out[#out + 1] = {
            { d[first][1], d[first][2] },
            { d[first][1] + t1x * dist, d[first][2] + t1z * dist },
            { d[last][1] + t2x * dist, d[last][2] + t2z * dist },
            { d[last][1], d[last][2] },
        }
        return
    end

    local u = chordLengthParameterize(d, first, last)
    local bez = generateBezier(d, first, last, u, t1x, t1z, t2x, t2z)
    local maxDist, splitIndex = computeMaxCurveError(d, first, last, bez, u)
    if maxDist < tolerance then
        out[#out + 1] = bez
        return
    end

    if maxDist < tolerance * 2 then
        for _ = 1, 4 do
            u = reparameterize(d, first, last, u, bez)
            bez = generateBezier(d, first, last, u, t1x, t1z, t2x, t2z)
            maxDist, splitIndex = computeMaxCurveError(d, first, last, bez, u)
            if maxDist < tolerance then
                out[#out + 1] = bez
                return
            end
        end
    end

    local cx, cz = normalize2(d[splitIndex - 1][1] - d[splitIndex + 1][1], d[splitIndex - 1][2] - d[splitIndex + 1][2], t1x, t1z)
    fitCubic(d, first, splitIndex, t1x, t1z, cx, cz, tolerance, out)
    fitCubic(d, splitIndex, last, -cx, -cz, t2x, t2z, tolerance, out)
end

-- Appends the flattened curve (excluding its start point) to `out`.
local function flattenBezier(bez, step, out)
    local function lineDist(p)
        local dx, dz = bez[4][1] - bez[1][1], bez[4][2] - bez[1][2]
        local length = math.sqrt(dx * dx + dz * dz)
        if length < 1e-9 then
            return math.sqrt((p[1] - bez[1][1]) ^ 2 + (p[2] - bez[1][2]) ^ 2)
        end
        return math.abs((p[1] - bez[1][1]) * dz - (p[2] - bez[1][2]) * dx) / length
    end
    local flatness = math.max(lineDist(bez[2]), lineDist(bez[3]))
    if flatness < 0.3 then
        out[#out + 1] = { bez[4][1], bez[4][2] }
        return
    end
    local function segLen(a, b)
        return math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
    end
    local arc = (segLen(bez[1], bez[2]) + segLen(bez[2], bez[3]) + segLen(bez[3], bez[4]) + segLen(bez[1], bez[4])) * 0.5
    local n = math.min(64, math.max(2, math.ceil(arc / step)))
    for i = 1, n - 1 do
        local x, z = bezierPoint(bez, i / n)
        out[#out + 1] = { x, z }
    end
    out[#out + 1] = { bez[4][1], bez[4][2] }
end

-- Open polyline -> points spaced `spacing` apart along its length, first
-- and last point preserved exactly.
local function resamplePolyline(points, spacing)
    local result = { { points[1][1], points[1][2] } }
    local carried = 0
    for i = 2, #points do
        local ax, az = points[i - 1][1], points[i - 1][2]
        local dx, dz = points[i][1] - ax, points[i][2] - az
        local segLength = math.sqrt(dx * dx + dz * dz)
        local position = spacing - carried
        while position <= segLength + 1e-9 do
            local t = position / segLength
            result[#result + 1] = { ax + dx * t, az + dz * t }
            position = position + spacing
        end
        carried = segLength - (position - spacing)
    end
    local last = points[#points]
    local tail = result[#result]
    if (tail[1] - last[1]) ^ 2 + (tail[2] - last[2]) ^ 2 > 1e-6 then
        result[#result + 1] = { last[1], last[2] }
    else
        result[#result] = { last[1], last[2] }
    end
    return result
end

-- Indices (into R) of sharp corners, by the turn angle between the
-- chords `window` points before/after. Non-maximum suppressed. `ring`
-- wraps the index instead of truncating the window at the ends.
local function detectCorners(R, window, thresholdDeg, ring)
    local count = #R
    local angles = {}
    local threshold = math.rad(thresholdDeg)
    for i = 1, count do
        local before, after
        if ring then
            before = R[(i - 1 - window) % count + 1]
            after = R[(i - 1 + window) % count + 1]
        else
            local reach = math.min(window, i - 1, count - i)
            if reach >= 2 then
                before, after = R[i - reach], R[i + reach]
            end
        end
        if before ~= nil then
            local ax, az = R[i][1] - before[1], R[i][2] - before[2]
            local bx, bz = after[1] - R[i][1], after[2] - R[i][2]
            local la, lb = math.sqrt(ax * ax + az * az), math.sqrt(bx * bx + bz * bz)
            if la > 1e-9 and lb > 1e-9 then
                local cosine = math.max(-1, math.min(1, (ax * bx + az * bz) / (la * lb)))
                angles[i] = math.acos(cosine)
            end
        end
    end
    local corners = {}
    for i = 1, count do
        local angle = angles[i]
        if angle ~= nil and angle >= threshold then
            local isMax = true
            for offset = -window, window do
                local j = i + offset
                if ring then
                    j = (j - 1) % count + 1
                end
                local other = angles[j]
                if j ~= i and other ~= nil and (other > angle or (other == angle and j < i)) then
                    isMax = false
                    break
                end
            end
            if isMax then
                corners[#corners + 1] = i
            end
        end
    end
    return corners
end

-- Fits curves along an OPEN chain (ends are fixed). tStart/tEnd: optional
-- tangent overrides (smooth joins); otherwise one-sided estimates.
-- Appends flattened points (excluding the chain's first point) to out.
local function fitOpenChain(chain, tolerance, tStart, tEnd, out)
    local R = resamplePolyline(chain, 1.0)
    local count = #R
    if count < 3 then
        for i = 2, #chain do
            out[#out + 1] = { chain[i][1], chain[i][2] }
        end
        return
    end

    local splits = { 1 }
    for _, index in ipairs(detectCorners(R, WailaTrailTracer.FOREST_CURVE_CORNER_WINDOW, WailaTrailTracer.FOREST_CURVE_CORNER_ANGLE_DEG, false)) do
        if index > 1 and index < count then
            splits[#splits + 1] = index
        end
    end
    splits[#splits + 1] = count

    local tangentReach = 3
    for s = 1, #splits - 1 do
        local first, last = splits[s], splits[s + 1]
        local reach = math.min(tangentReach, last - first)
        local t1x, t1z = normalize2(R[first + reach][1] - R[first][1], R[first + reach][2] - R[first][2], R[last][1] - R[first][1], R[last][2] - R[first][2])
        local t2x, t2z = normalize2(R[last - reach][1] - R[last][1], R[last - reach][2] - R[last][2], R[first][1] - R[last][1], R[first][2] - R[last][2])
        if s == 1 and tStart ~= nil then
            t1x, t1z = tStart[1], tStart[2]
        end
        if s == #splits - 1 and tEnd ~= nil then
            t2x, t2z = tEnd[1], tEnd[2]
        end
        local beziers = {}
        fitCubic(R, first, last, t1x, t1z, t2x, t2z, tolerance, beziers)
        for _, bez in ipairs(beziers) do
            flattenBezier(bez, WailaTrailTracer.FOREST_CURVE_FLATTEN_STEP, out)
        end
    end
end

local function dropCollinearRing(loop)
    local n = #loop
    local out = {}
    for i = 1, n do
        local p, c, q = loop[(i - 2) % n + 1], loop[i], loop[i % n + 1]
        local cross = (c[1] - p[1]) * (q[2] - c[2]) - (c[2] - p[2]) * (q[1] - c[1])
        if math.abs(cross) > 1e-6 then
            out[#out + 1] = c
        end
    end
    return out
end

-- bounds = { minX, minZ, maxX, maxZ } of the tile this loop was traced
-- in. Returns a closed ring (no repeated end point) of sparse points, or
-- nil if the loop is too degenerate to fit (caller falls back).
local function fitLoopCurves(loop, bounds, tolerance)
    local ring = dropCollinearRing(loop)
    local n = #ring
    if n < 6 then
        return nil
    end

    local eps = 1e-3
    local function lineMask(p)
        local mask = 0
        if p[1] <= bounds.minX + eps then mask = mask + 1 end
        if p[1] >= bounds.maxX - eps then mask = mask + 2 end
        if p[2] <= bounds.minZ + eps then mask = mask + 4 end
        if p[2] >= bounds.maxZ - eps then mask = mask + 8 end
        return mask
    end
    local masks = {}
    for i = 1, n do
        masks[i] = lineMask(ring[i])
    end
    local isBreak = {}
    local breakCount = 0
    local function isSeamEdge(i)
        return bit32.band(masks[i], masks[i % n + 1]) ~= 0
    end
    for i = 1, n do
        if isSeamEdge(i) then
            if not isBreak[i] then isBreak[i] = true breakCount = breakCount + 1 end
            local nextIndex = i % n + 1
            if not isBreak[nextIndex] then isBreak[nextIndex] = true breakCount = breakCount + 1 end
        end
    end

    local out = {}
    if breakCount > 0 then
        local startIndex
        for i = 1, n do
            if isBreak[i] then startIndex = i break end
        end
        out[1] = { ring[startIndex][1], ring[startIndex][2] }
        local chain = { ring[startIndex] }
        for step = 1, n do
            local index = (startIndex - 1 + step) % n + 1
            chain[#chain + 1] = ring[index]
            if isBreak[index] then
                if #chain == 2 then
                    out[#out + 1] = { chain[2][1], chain[2][2] }
                else
                    fitOpenChain(chain, tolerance, nil, nil, out)
                end
                chain = { ring[index] }
            end
        end
        -- last point equals the first (ring closed) -- drop the duplicate
        out[#out] = nil
    else
        -- no seam contact: a free-standing loop. Close the ring, find
        -- corners on the resampled closed polyline.
        local closed = {}
        for i = 1, n do closed[i] = ring[i] end
        closed[n + 1] = ring[1]
        local R = resamplePolyline(closed, 1.0)
        R[#R] = nil
        local corners = detectCorners(R, WailaTrailTracer.FOREST_CURVE_CORNER_WINDOW, WailaTrailTracer.FOREST_CURVE_CORNER_ANGLE_DEG, true)
        local count = #R
        local rotated = {}
        local tStart, tEnd
        local startAt = corners[1] or 1
        for i = 0, count - 1 do
            rotated[i + 1] = R[(startAt - 1 + i) % count + 1]
        end
        rotated[count + 1] = rotated[1]
        if corners[1] == nil then
            local reach = 3
            local tx, tz = normalize2(R[(startAt - 1 + reach) % count + 1][1] - R[(startAt - 1 - reach) % count + 1][1], R[(startAt - 1 + reach) % count + 1][2] - R[(startAt - 1 - reach) % count + 1][2], 1, 0)
            tStart, tEnd = { tx, tz }, { -tx, -tz }
        end
        out[1] = { rotated[1][1], rotated[1][2] }
        fitOpenChain(rotated, tolerance, tStart, tEnd, out)
        out[#out] = nil
    end

    if #out < 3 then
        return nil
    end
    return out
end
-- Used by the 1m trail scan (scanTileCells) too; trail strips are only a few
-- metres wide, so the tolerance is tighter than the forest outline's.
WailaTrailTracer.fitLoopCurves = fitLoopCurves
-- ===== end curve fit =====

local curveFitFailureLogged = false

local function traceForestPolygonsFromGrid(grid, originX, originZ, size, cellSize, curveTolerance)
    local result = collectBorderSegments(grid, originX, originZ, size, cellSize)
    local polygons = {}
    local fine = cellSize < WailaTrailTracer.FOREST_CELL_SIZE
    local bounds = { minX = originX, minZ = originZ, maxX = originX + size * cellSize, maxZ = originZ + size * cellSize }
    for _, loop in ipairs(WailaTrailTracer.chainBorderLoops(result.segments)) do
        local polygon
        if fine and WailaTrailTracer.FOREST_CURVE_FIT then
            local ok, fitted = pcall(fitLoopCurves, loop, bounds, curveTolerance or WailaTrailTracer.FOREST_CURVE_TOLERANCE)
            if ok then
                polygon = fitted
            elseif not curveFitFailureLogged then
                curveFitFailureLogged = true
                log("traceForestPolygonsFromGrid: curve fit failed (%s), falling back to Douglas-Peucker", tostring(fitted))
            end
        end
        if polygon == nil then
            local tolerance = WailaTrailTracer.FOREST_SIMPLIFY_TOLERANCE
            if fine then
                tolerance = WailaTrailTracer.FOREST_REFINE_SIMPLIFY_TOLERANCE
            end
            polygon = simplifyClosedLoop(loop, tolerance)
        end
        table.insert(polygons, polygon)
    end
    return polygons, result.cellCount
end

function WailaTrailTracer.clearLayerOverlayWindow(modifier, minX, minZ, size)
    modifier:clearPolygonPoints()
    modifier:addPolygonPointWorldCoords(minX, minZ)
    modifier:addPolygonPointWorldCoords(minX + size, minZ)
    modifier:addPolygonPointWorldCoords(minX + size, minZ + size)
    modifier:addPolygonPointWorldCoords(minX, minZ + size)
    modifier:executeSet(0)
end

-- ===== Road layer pass =====
-- Real request ("road should give a simple spline, and that goes on top of
-- whatever the forest does"): roads are found by their learned paint layer
-- (learnLayerClasses), completely independent of the forest classification,
-- so they can no longer vanish when the forest edge jitters across them.
-- Per chunk: a 4m-stride prefilter (256 terrain reads); only chunks with a
-- hit get the 1m pass (4096 reads), traced into thin polygons with the
-- same loop tracer + curve fit the forest uses (tight tolerance: roads are
-- only a few metres wide). Drawn on its own overlay, on top.
WailaTrailTracer.ROAD_LAYER_PREFILTER_STRIDE = 4
WailaTrailTracer.ROAD_LAYER_CURVE_TOLERANCE = 0.7
WailaTrailTracer.ROAD_LAYER_OVERLAY_REGENERATE_INTERVAL_SEC = 3.0

function WailaTrailTracer.scanRoadLayerChunk(minX, minZ, chunkSize)
    if not WailaTrailTracer.layerClassLearned then
        return {}, 0
    end
    local roadClass = WailaTrailTracer.LAYER_CLASS_ROAD
    local stride = WailaTrailTracer.ROAD_LAYER_PREFILTER_STRIDE
    local anyHit = false
    for dz = stride * 0.5, chunkSize, stride do
        for dx = stride * 0.5, chunkSize, stride do
            if WailaTrailTracer.getLayerClassAt(minX + dx, minZ + dz) == roadClass then
                anyHit = true
                break
            end
        end
        if anyHit then
            break
        end
    end
    if not anyHit then
        return {}, 0
    end

    local cells = math.floor(chunkSize)
    local grid, roadCells = {}, 0
    for row = 0, cells - 1 do
        local gridRow = {}
        local z = minZ + row + 0.5
        for col = 0, cells - 1 do
            local isRoad = WailaTrailTracer.getLayerClassAt(minX + col + 0.5, z) == roadClass
            gridRow[col] = isRoad
            if isRoad then
                roadCells = roadCells + 1
            end
        end
        grid[row] = gridRow
    end
    if roadCells == 0 then
        return {}, 0
    end
    local polygons = traceForestPolygonsFromGrid(grid, minX, minZ, cells, 1.0, WailaTrailTracer.ROAD_LAYER_CURVE_TOLERANCE)
    return polygons, roadCells
end

WailaTrailTracer.lastRoadLayerOverlayRegenerateTime = nil
function WailaTrailTracer.buildRoadLayerOverlayIncremental(polygons, forceRegenerate)
    local size = WailaTrailTracer.OVERLAY_RESOLUTION
    if WailaTrailTracer.roadLayerOverlayMap == nil then
        WailaTrailTracer.roadLayerOverlayMap = createBitVectorMap("wailaRoadLayerOverlayMap")
        loadBitVectorMapNew(WailaTrailTracer.roadLayerOverlayMap, size, size, 1, false)
        WailaTrailTracer.roadLayerOverlay = createDensityMapVisualizationOverlay("wailaRoadLayerOverlay", size, size)
    end

    local modifier = DensityMapModifier.new(WailaTrailTracer.roadLayerOverlayMap, 0, 1, g_terrainNode)
    for _, polygon in ipairs(polygons) do
        modifier:clearPolygonPoints()
        for _, point in ipairs(polygon) do
            modifier:addPolygonPointWorldCoords(point[1], point[2])
        end
        modifier:executeSet(1)
    end

    local now = getTimeSec()
    if not forceRegenerate and WailaTrailTracer.lastRoadLayerOverlayRegenerateTime ~= nil
        and now - WailaTrailTracer.lastRoadLayerOverlayRegenerateTime < WailaTrailTracer.ROAD_LAYER_OVERLAY_REGENERATE_INTERVAL_SEC then
        return
    end
    WailaTrailTracer.lastRoadLayerOverlayRegenerateTime = now

    local color = paletteColor("road")
    resetDensityMapVisualizationOverlay(WailaTrailTracer.roadLayerOverlay)
    setDensityMapVisualizationOverlayStateColor(WailaTrailTracer.roadLayerOverlay, WailaTrailTracer.roadLayerOverlayMap, 0, 0, 0, 1, 1, color[1], color[2], color[3])
    generateDensityMapVisualizationOverlay(WailaTrailTracer.roadLayerOverlay)
end

-- Debug colour mode: re-colour every existing overlay (one regenerate each).
function WailaTrailTracer.setDebugColors(enabled)
    WailaTrailTracer.debugColors = enabled == true
    if WailaTrailTracer.testOverlayMap ~= nil then
        WailaTrailTracer.buildTestOverlay({}, true)
    end
    if WailaTrailTracer.forestOverlayMap ~= nil then
        WailaTrailTracer.buildForestOverlayIncremental({}, true)
    end
    if WailaTrailTracer.roadLayerOverlayMap ~= nil then
        WailaTrailTracer.buildRoadLayerOverlayIncremental({}, true)
    end
    log("overlay colours: %s mode", WailaTrailTracer.debugColors and "DEBUG (loud)" or "normal")
end

function WailaTrailTracer.toggleDebugColors()
    WailaTrailTracer.setDebugColors(not WailaTrailTracer.debugColors)
end

-- Real integration, extracted from buildForestOverlay's own original
-- body: the write+regenerate half, shared by BOTH the debug-button one-
-- shot tool (forced regenerate, since it's a single press) and
-- tickWholeMapScan's own per-chunk incremental accumulation (throttled,
-- same 0.3s pattern buildTestOverlay already established, for the exact
-- same "constant flashing" reason during an active scan). Both paths
-- write into the SAME forestOverlayMap/forestOverlay -- one shared piece
-- of state, not two independently-created overlays depending on how you
-- triggered it.
WailaTrailTracer.FOREST_OVERLAY_REGENERATE_INTERVAL_SEC = 0.3
WailaTrailTracer.lastForestOverlayRegenerateTime = nil

-- refinedMarks (optional, debug): { grid, evaluated, originX, originZ,
-- cellSize } -- cells that are forest AND came from the border
-- re-evaluation get value 2 (own colour), written AFTER the polygon fill
-- so it isn't overwritten. Horizontal runs become one rectangle each.
function WailaTrailTracer.buildForestOverlayIncremental(polygons, forceRegenerate, refinedMarks)
    local size = WailaTrailTracer.OVERLAY_RESOLUTION
    if WailaTrailTracer.forestOverlayMap == nil then
        WailaTrailTracer.forestOverlayMap = createBitVectorMap("wailaForestOverlayMap")
        loadBitVectorMapNew(WailaTrailTracer.forestOverlayMap, size, size, 2, false)
        WailaTrailTracer.forestOverlay = createDensityMapVisualizationOverlay("wailaForestOverlay", size, size)
    end

    local map = WailaTrailTracer.forestOverlayMap
    local modifier = DensityMapModifier.new(map, 0, 2, g_terrainNode)
    for _, polygon in ipairs(polygons) do
        modifier:clearPolygonPoints()
        for _, point in ipairs(polygon) do
            modifier:addPolygonPointWorldCoords(point[1], point[2])
        end
        modifier:executeSet(1)
    end

    if refinedMarks ~= nil and refinedMarks.evaluated ~= nil then
        local cell = refinedMarks.cellSize
        for row, gridRow in pairs(refinedMarks.grid) do
            local evaluatedRow = refinedMarks.evaluated[row]
            local z0 = refinedMarks.originZ + row * cell
            local col = 0
            while gridRow[col] ~= nil do
                if gridRow[col] and evaluatedRow[col] then
                    local runStart = col
                    while gridRow[col + 1] and evaluatedRow[col + 1] do
                        col = col + 1
                    end
                    local x0 = refinedMarks.originX + runStart * cell
                    local x1 = refinedMarks.originX + (col + 1) * cell
                    modifier:clearPolygonPoints()
                    modifier:addPolygonPointWorldCoords(x0, z0)
                    modifier:addPolygonPointWorldCoords(x1, z0)
                    modifier:addPolygonPointWorldCoords(x1, z0 + cell)
                    modifier:addPolygonPointWorldCoords(x0, z0 + cell)
                    modifier:executeSet(2)
                end
                col = col + 1
            end
        end
    end

    local now = getTimeSec()
    if not forceRegenerate and WailaTrailTracer.lastForestOverlayRegenerateTime ~= nil
        and now - WailaTrailTracer.lastForestOverlayRegenerateTime < WailaTrailTracer.FOREST_OVERLAY_REGENERATE_INTERVAL_SEC then
        return
    end
    WailaTrailTracer.lastForestOverlayRegenerateTime = now

    resetDensityMapVisualizationOverlay(WailaTrailTracer.forestOverlay)
    local forestColor = paletteColor("forest")
    setDensityMapVisualizationOverlayStateColor(WailaTrailTracer.forestOverlay, map, 0, 0, 0, 2, 1, forestColor[1], forestColor[2], forestColor[3])
    setDensityMapVisualizationOverlayStateColor(WailaTrailTracer.forestOverlay, map, 0, 0, 0, 2, 2, 0.85, 0.45, 0.05)
    generateDensityMapVisualizationOverlay(WailaTrailTracer.forestOverlay)
end

WailaTrailTracer.WHOLE_MAP_SCAN_CHUNK_SIZE = 64.0
-- Real, confirmed live bug: a scan and a load/save running at once
-- looked harmless (both are independent, tick-budgeted state machines)
-- but aren't -- tickLoadFromXML's own completion does a HARD
-- reassignment of the whole savedRegionsByMaterial table (see its own
-- header), not a merge, so any region a concurrent scan freshly wrote
-- during the load's 2+ minute runtime gets silently discarded the
-- instant the load finishes. Real data loss, not just wasted CPU.
-- Simplest robust fix, not a clever concurrent-merge: just refuse to
-- start one while the other (or a save) is already running, with a
-- clear log explaining why, same "prefer simple/robust" bias this file
-- already leans on elsewhere.
-- The overlay bitmaps are persistent and every write only ADDS -- nothing
-- ever cleared them, so a rescan painted on top of whatever an earlier
-- scan or a loaded save had left there (confirmed live: stale 16m forest
-- squares from an older scan stuck out around the new refined outline).
-- A whole-map scan rewrites every region, so start from blank.
function WailaTrailTracer.clearScanOverlays()
    local terrainSize = (g_currentMission ~= nil and g_currentMission.terrainSize) or 2048
    local half = terrainSize * 0.5
    local function clearMap(map, numChannels)
        if map == nil then
            return
        end
        local modifier = DensityMapModifier.new(map, 0, numChannels, g_terrainNode)
        modifier:clearPolygonPoints()
        modifier:addPolygonPointWorldCoords(-half, -half)
        modifier:addPolygonPointWorldCoords(half, -half)
        modifier:addPolygonPointWorldCoords(half, half)
        modifier:addPolygonPointWorldCoords(-half, half)
        modifier:executeSet(0)
    end
    clearMap(WailaTrailTracer.testOverlayMap, WailaTrailTracer.OVERLAY_NUM_CHANNELS)
    clearMap(WailaTrailTracer.forestOverlayMap, 2)
    clearMap(WailaTrailTracer.roadLayerOverlayMap, 1)
    if WailaTrailTracer.testOverlayMap ~= nil then
        WailaTrailTracer.buildTestOverlay({}, true)
    end
    if WailaTrailTracer.forestOverlayMap ~= nil then
        WailaTrailTracer.buildForestOverlayIncremental({}, true)
    end
    if WailaTrailTracer.roadLayerOverlayMap ~= nil then
        WailaTrailTracer.buildRoadLayerOverlayIncremental({}, true)
    end
end

-- Real, measured (log): scans took 372-418s, mostly NOT compute -- the scan
-- ran exactly ONE phase per frame however cheap it was (solid forest/open
-- chunks cost ~2ms), so wall time was frames, not work: 4096 chunks x 2-3
-- phases at 26-50fps. Now phases run back to back until the per-frame
-- budget is spent (always at least one, so a heavy phase still completes
-- in a single frame as before).
WailaTrailTracer.WHOLE_MAP_SCAN_FRAME_BUDGET_SEC = 0.008

function WailaTrailTracer.tickWholeMapScan()
    local state = WailaTrailTracer.wholeMapScanState
    if state == nil then
        return true
    end
    local frameStart = getTimeSec()
    local done = false
    repeat
        done = WailaTrailTracer.tickLayerScanStep(state)
    until done or getTimeSec() - frameStart >= WailaTrailTracer.WHOLE_MAP_SCAN_FRAME_BUDGET_SEC
    return done
end

-- Real, confirmed live crash: the original saveToXML wrote 229,673
-- polygons in ONE synchronous call ("game went unresponsive") -- same
-- hard rule this whole file already learned once for scanning
-- (feedback_waila_performance_is_non_negotiable), just violated again in
-- the save path instead. Real, two-part fix, both required:
--   1) recordScannedPolygons now dedupes by region (see its own header) --
--      cuts the total polygon count for real, not just spreads the
--      writing out.
--   2) even deduped, a genuinely fragmented map (forests reading as
--      scattered STONE patches, see MATERIAL_COLOR's own header) can
--      still be tens of thousands of polygons -- so the actual per-
--      polygon point-string writing (the expensive part, scales with
--      polygon count) is now a tick-budgeted state machine
--      (startSaveToXML + tickSaveToXML), same shape as
--      startWholeMapScan/tickWholeMapScan. The cheap part -- one
--      #id/#key attribute per material/region, at most a few thousand --
--      is still written synchronously up front in startSaveToXML; only
--      the part that scaled to 229k is deferred.
-- Meant to be called from SavegameController.onSaveComplete (see
-- FS25WhatAmILookingAt.lua) via startSaveToXML, then ticked every frame
-- via FS25WhatAmILookingAt:update -- same "always safe to call, no-ops
-- when nothing is running" contract tickWholeMapScan already uses.
-- Region/material structure written as "x z x z ..." flat point strings
-- (confirmed real via the base game's own FieldCourseField:saveToXMLFile)
-- and materialId as a string (setString/getString, not xmlFile:setInt --
-- getInt was never confirmed against real decompiled source).
WailaTrailTracer.SAVE_TICK_BUDGET_SEC = 0.005

function WailaTrailTracer.startSaveToXML()
    if WailaTrailTracer.saveState ~= nil then
        return false, "a save is already in progress"
    end
    if WailaTrailTracer.wholeMapScanState ~= nil then
        return false, "a whole-map scan is in progress -- wait for it to finish so the save reflects its results"
    end
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return false, "no current mission"
    end
    local savegameDirectory = g_currentMission.missionInfo.savegameDirectory
    if savegameDirectory == nil then
        return false, "no savegame directory"
    end

    local path = savegameDirectory .. "/" .. WailaTrailTracer.SAVEGAME_FILENAME
    local xmlFile = XMLFile.create("wailaTrail", path, "wailaTrail")
    if xmlFile == nil then
        return false, "XMLFile.create failed"
    end

    local workItems = {}
    for materialIndex, materialId in ipairs(SPLIT_MATERIALS) do
        local materialKey = string.format("wailaTrail.materials.material(%d)", materialIndex - 1)
        xmlFile:setString(materialKey .. "#id", tostring(materialId))

        local regionIndex = 0
        for regionKey, polygons in pairs(WailaTrailTracer.savedRegionsByMaterial[materialId]) do
            local regionElementKey = string.format("%s.region(%d)", materialKey, regionIndex)
            regionIndex = regionIndex + 1
            xmlFile:setString(regionElementKey .. "#key", regionKey)

            for polyIndex, polygon in ipairs(polygons) do
                table.insert(workItems, {
                    key = string.format("%s.polygon(%d)#points", regionElementKey, polyIndex - 1),
                    polygon = polygon,
                })
            end
        end
    end

    local forestRegionIndex = 0
    for regionKey, polygons in pairs(WailaTrailTracer.savedForestRegions) do
        local regionElementKey = string.format("wailaTrail.forest.region(%d)", forestRegionIndex)
        forestRegionIndex = forestRegionIndex + 1
        xmlFile:setString(regionElementKey .. "#key", regionKey)
        for polyIndex, polygon in ipairs(polygons) do
            table.insert(workItems, {
                key = string.format("%s.polygon(%d)#points", regionElementKey, polyIndex - 1),
                polygon = polygon,
            })
        end
    end

    local roadRegionIndex = 0
    for regionKey, polygons in pairs(WailaTrailTracer.savedRoadRegions) do
        local regionElementKey = string.format("wailaTrail.road.region(%d)", roadRegionIndex)
        roadRegionIndex = roadRegionIndex + 1
        xmlFile:setString(regionElementKey .. "#key", regionKey)
        for polyIndex, polygon in ipairs(polygons) do
            table.insert(workItems, {
                key = string.format("%s.polygon(%d)#points", regionElementKey, polyIndex - 1),
                polygon = polygon,
            })
        end
    end

    WailaTrailTracer.saveState = {
        xmlFile = xmlFile,
        path = path,
        workItems = workItems,
        index = 1,
        startTime = getTimeSec(),
    }
    log("startSaveToXML: %d polygon(s) queued (%d forest region(s)), writing incrementally", #workItems, forestRegionIndex)
    return true
end

-- Public: call once per frame. Returns true once done (or if no save is
-- running, so callers can call this unconditionally every tick, same
-- contract as tickWholeMapScan).
function WailaTrailTracer.tickSaveToXML()
    local state = WailaTrailTracer.saveState
    if state == nil then
        return true
    end

    local tickStart = getTimeSec()
    while state.index <= #state.workItems do
        local item = state.workItems[state.index]
        local parts = {}
        for _, point in ipairs(item.polygon) do
            table.insert(parts, string.format("%.2f %.2f", point[1], point[2]))
        end
        state.xmlFile:setString(item.key, table.concat(parts, " "))
        state.index = state.index + 1

        if getTimeSec() - tickStart > WailaTrailTracer.SAVE_TICK_BUDGET_SEC then
            return false
        end
    end

    state.xmlFile:save()
    state.xmlFile:delete()
    local elapsedMs = (getTimeSec() - state.startTime) * 1000
    log("tickSaveToXML done: %d polygon(s) written to %s in %.0fms (%.1fs)", #state.workItems, state.path, elapsedMs, elapsedMs / 1000)
    WailaTrailTracer.saveState = nil
    return true
end

-- Symmetric with startSaveToXML/tickSaveToXML above, same reasoning: the
-- expensive parts (per-polygon point-string parsing AND the native
-- DensityMapModifier writes buildTestOverlay makes) are deferred into a
-- tick-budgeted state machine instead of one synchronous call replaying
-- a potentially huge dataset at once. Cheap structure (material/region
-- keys) is still read up front in startLoadFromXML. Rebuilds
-- savedRegionsByMaterial with its REAL region keys (not synthetic ones)
-- so a save made right after a load -- with no new scanning in between --
-- still dedupes correctly against what was loaded.
WailaTrailTracer.LOAD_TICK_BUDGET_SEC = 0.005

-- Real, confirmed live bug: every early-return path here was completely
-- silent -- confirmed via log, startLoadFromXML logged its "queued"
-- message exactly ONCE across an entire session's worth of repeated
-- restarts (field-index sweeps restarting fresh each time proved
-- loadMap()/setupComponents() really was running every time -- this
-- function just wasn't visibly doing anything on any of those later
-- calls). Real "why nothing happens on load" root cause: no way to tell
-- WHICH of the three early-return conditions was silently firing. Every
-- branch now logs, so the next test tells us exactly what's happening
-- instead of needing another guess.
function WailaTrailTracer.startLoadFromXML()
    if WailaTrailTracer.loadState ~= nil then
        log("startLoadFromXML: a load is already in progress, skipping duplicate call")
        return
    end
    if WailaTrailTracer.wholeMapScanState ~= nil then
        log("startLoadFromXML: refused -- a whole-map scan is already in progress, wait for it to finish first")
        return
    end
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        log("startLoadFromXML: g_currentMission or missionInfo not ready yet, skipping")
        return
    end
    local savegameDirectory = g_currentMission.missionInfo.savegameDirectory
    if savegameDirectory == nil then
        log("startLoadFromXML: missionInfo.savegameDirectory is nil, skipping")
        return
    end

    local path = savegameDirectory .. "/" .. WailaTrailTracer.SAVEGAME_FILENAME
    local xmlFile = XMLFile.loadIfExists("wailaTrail", path)
    if xmlFile == nil then
        log("startLoadFromXML: no file at %s (or failed to load), nothing to restore", path)
        return
    end

    local loadedRegions = { [MATERIAL_DIRT] = {}, [MATERIAL_GRAVEL] = {}, [MATERIAL_STONE] = {} }
    local workItems = {}

    for _, materialElementKey in xmlFile:iterator("wailaTrail.materials.material") do
        local materialId = tonumber(xmlFile:getString(materialElementKey .. "#id"))
        if materialId ~= nil and loadedRegions[materialId] ~= nil then
            for _, regionElementKey in xmlFile:iterator(materialElementKey .. ".region") do
                local regionKey = xmlFile:getString(regionElementKey .. "#key")
                if regionKey ~= nil then
                    local polygons = {}
                    loadedRegions[materialId][regionKey] = polygons
                    for _, polygonElementKey in xmlFile:iterator(regionElementKey .. ".polygon") do
                        table.insert(workItems, { materialId = materialId, polygons = polygons, polygonElementKey = polygonElementKey })
                    end
                end
            end
        end
    end

    local loadedForest = {}
    for _, regionElementKey in xmlFile:iterator("wailaTrail.forest.region") do
        local regionKey = xmlFile:getString(regionElementKey .. "#key")
        if regionKey ~= nil then
            local polygons = {}
            loadedForest[regionKey] = polygons
            for _, polygonElementKey in xmlFile:iterator(regionElementKey .. ".polygon") do
                table.insert(workItems, { isForest = true, polygons = polygons, polygonElementKey = polygonElementKey })
            end
        end
    end

    local loadedRoad = {}
    for _, regionElementKey in xmlFile:iterator("wailaTrail.road.region") do
        local regionKey = xmlFile:getString(regionElementKey .. "#key")
        if regionKey ~= nil then
            local polygons = {}
            loadedRoad[regionKey] = polygons
            for _, polygonElementKey in xmlFile:iterator(regionElementKey .. ".polygon") do
                table.insert(workItems, { isRoad = true, polygons = polygons, polygonElementKey = polygonElementKey })
            end
        end
    end

    WailaTrailTracer.loadState = {
        xmlFile = xmlFile,
        workItems = workItems,
        index = 1,
        loadedRegions = loadedRegions,
        loadedForest = loadedForest,
        loadedRoad = loadedRoad,
        pendingRoad = {},
        pendingForest = {},
        pendingByMaterial = { [MATERIAL_DIRT] = {}, [MATERIAL_GRAVEL] = {}, [MATERIAL_STONE] = {} },
        startTime = getTimeSec(),
        lastProgressLogTime = getTimeSec(),
        polygonCount = 0,
    }
    local forestRegionCount = 0
    for _ in pairs(loadedForest) do
        forestRegionCount = forestRegionCount + 1
    end
    log("startLoadFromXML: %d polygon(s) queued (%d forest region(s)), restoring incrementally", #workItems, forestRegionCount)
end

-- Flushes whatever raw polygons tickLoadFromXML has parsed so far into
-- the live overlay -- called at least once per tick (bounded batch size,
-- never the whole dataset at once) and once more at the very end.
local function flushPendingLoadBatch(state)
    if #state.pendingForest > 0 then
        WailaTrailTracer.buildForestOverlayIncremental(state.pendingForest)
        state.pendingForest = {}
    end
    if #state.pendingRoad > 0 then
        WailaTrailTracer.buildRoadLayerOverlayIncremental(state.pendingRoad)
        state.pendingRoad = {}
    end

    local hasAny = false
    for _, materialId in ipairs(SPLIT_MATERIALS) do
        if #state.pendingByMaterial[materialId] > 0 then
            hasAny = true
        end
    end
    if not hasAny then
        return
    end
    WailaTrailTracer.buildTestOverlay(state.pendingByMaterial)
    for _, materialId in ipairs(SPLIT_MATERIALS) do
        state.pendingByMaterial[materialId] = {}
    end
end

-- Public: call once per frame. Returns true once done (or if no load is
-- running), same contract as tickSaveToXML/tickWholeMapScan.
-- Real, confirmed live bug: the first version of this only time-budgeted
-- the cheap parse loop below and left the actual flushPendingLoadBatch
-- call (real DensityMapModifier native writes -- the expensive part)
-- completely unbounded. Since parsing is fast, thousands of raw polygons
-- could pile up in a single tick before one, uncapped flush -- defeating
-- the whole point of ticking this at all (confirmed live: restoring
-- 229,845 polygons never printed "done" even after ~90s of real
-- gameplay). Flushing in small, FIXED-SIZE batches (LOAD_MAX_BATCH_SIZE),
-- not just once per tick, bounds the native call's own cost too, not
-- only the parsing around it.
WailaTrailTracer.LOAD_MAX_BATCH_SIZE = 50

function WailaTrailTracer.tickLoadFromXML()
    local state = WailaTrailTracer.loadState
    if state == nil then
        return true
    end

    local tickStart = getTimeSec()
    local pendingCount = 0
    while state.index <= #state.workItems do
        local item = state.workItems[state.index]
        local pointsStr = state.xmlFile:getString(item.polygonElementKey .. "#points")
        if pointsStr ~= nil then
            local numbers = string.split(pointsStr, " ")
            local rawPolygon = {}
            for i = 1, #numbers, 2 do
                local px = tonumber(numbers[i])
                local pz = tonumber(numbers[i + 1])
                if px ~= nil and pz ~= nil then
                    table.insert(rawPolygon, { px, pz })
                end
            end
            table.insert(item.polygons, rawPolygon)
            if item.isForest then
                table.insert(state.pendingForest, rawPolygon)
            elseif item.isRoad then
                table.insert(state.pendingRoad, rawPolygon)
            else
                table.insert(state.pendingByMaterial[item.materialId], rawPolygon)
            end
            state.polygonCount = state.polygonCount + 1
            pendingCount = pendingCount + 1
        end
        state.index = state.index + 1

        if pendingCount >= WailaTrailTracer.LOAD_MAX_BATCH_SIZE then
            flushPendingLoadBatch(state)
            pendingCount = 0
        end

        if getTimeSec() - tickStart > WailaTrailTracer.LOAD_TICK_BUDGET_SEC then
            flushPendingLoadBatch(state)
            -- Real request-worthy gap: the first version gave no sign of
            -- life while restoring (no "done" line for 90+ seconds looked
            -- indistinguishable from "stuck", confirmed live). A periodic
            -- progress line (every ~2s of wall time) makes forward
            -- progress visible without waiting for full completion.
            local now = getTimeSec()
            if now - state.lastProgressLogTime > 2.0 then
                state.lastProgressLogTime = now
                log("tickLoadFromXML progress: %d / %d polygon(s) restored so far", state.index - 1, #state.workItems)
            end
            return false
        end
    end

    flushPendingLoadBatch(state)
    -- Same forced-regenerate reasoning as tickWholeMapScan's own
    -- completion -- the last flush could land inside the throttle
    -- window and never actually show without this.
    WailaTrailTracer.buildTestOverlay({}, true)
    WailaTrailTracer.buildForestOverlayIncremental({}, true)
    WailaTrailTracer.buildRoadLayerOverlayIncremental({}, true)
    state.xmlFile:delete()

    WailaTrailTracer.savedRegionsByMaterial = state.loadedRegions
    WailaTrailTracer.savedForestRegions = state.loadedForest
    WailaTrailTracer.savedRoadRegions = state.loadedRoad

    local elapsedMs = (getTimeSec() - state.startTime) * 1000
    log("tickLoadFromXML done: %d polygon(s) restored in %.0fms (%.1fs)", state.polygonCount, elapsedMs, elapsedMs / 1000)
    WailaTrailTracer.loadState = nil
    return true
end

-- Exposed for WailaLayerScan.lua: a separate file cannot see this chunk's locals.
WailaTrailTracer.traceMaskPolygons = traceForestPolygonsFromGrid
WailaTrailTracer.cleanComponents = smoothForestGrid
