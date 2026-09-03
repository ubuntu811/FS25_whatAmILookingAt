--[[
    WailaTrailTracer.lua

    Finds worn dirt/gravel trails and areas anywhere on the map - not tied
    to fields, not tied to any specific mod's own writes (IW, base-game
    tyre wear, a placeable's foundation stamp, whatever painted it).
    Deliberately independent from WailaFieldBoundaryTracer.lua, NOT a
    generalization of it, even though the area-tracing half below is
    structurally similar (same wall-follower shape). Explicit call: don't
    touch/parameterize the field tracer while it's in active use - that
    class took real, hard-won live-debugging (documented in its own file:
    a zero-direction-vector stall case, a missing-pivot-on-corner bug,
    a resolution-mismatch bug) to get right, and destabilizing it isn't
    worth the shared-code savings. Merge later if it turns out safe once
    both have their own mileage.

    Two genuinely different reconstructions for two genuinely different
    shapes, decided empirically over a long design conversation, not
    assumed upfront:
      - PATH: a real trail's own boundary is NOT one continuous piece -
        wear intensity varies constantly along its length, so the
        dirt/grass transition fragments into many short, disconnected
        pieces. Reconstructed via a cheap coarse tile scan + PCA
        (principal component analysis) on each tile's dirt-hit positions:
        strongly elongated hit-scatter = path-like, classified without
        ever needing a continuous boundary at all. Neighboring
        path-tiles get stitched into a spline by proximity + axis
        alignment.
      - AREA: a real worn area's own boundary (a farmyard courtyard, a
        wide TerraFarm-style yard) genuinely IS one continuous piece, so
        it gets the real wall-follower treatment (fresh implementation
        below, not shared with the field tracer) for a precise outline.

    Hole/island detection for areas (a grass patch inside an otherwise-
    dirt courtyard) is a real, agreed-on piece of the design but
    deliberately NOT in this first version - it's the least-verified part
    of the whole plan and the one most likely to need real in-game tuning
    before it's worth building. Fast-follow once the rest is confirmed
    working, not a silent scope cut.
]]

WailaTrailTracer = {}
local WailaTrailTracer_mt = Class(WailaTrailTracer)

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] [TrailTracer] " .. formatString, ...)
end

-- Real, confirmed terrain material IDs - same constants
-- FS25_ImmersiveWeathering's own MATERIAL table uses (confirmed live
-- there over the same investigation this whole feature grew out of).
-- Duplicated here rather than imported - IW is not a dependency of
-- WAILA (the reverse is true: TaskMap depends on WAILA), and these are
-- just numeric engine IDs, not meaningfully "shared logic" worth
-- coupling two mods over.
local MATERIAL_DIRT = 1
local MATERIAL_GRAVEL = 6
local TRAIL_MATERIALS = { [MATERIAL_DIRT] = true, [MATERIAL_GRAVEL] = true }

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
local function isTrailMaterialAt(x, z)
    local isOnField = FSDensityMapUtil.getFieldDataAtWorldPosition(x, 0, z)
    if isOnField then
        return false
    end
    local _, _, _, _, materialId = getTerrainAttributesAtWorldPos(g_terrainNode, x, 0, z, true, true, true, true, false)
    return TRAIL_MATERIALS[materialId] == true
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

-- ============================================================
-- Tile scan + PCA classification (paths, and area seed-finding)
-- ============================================================

-- Meters. 8x8 matches the size the whole tile/PCA idea was proposed at -
-- untuned beyond that, first real in-game results should drive this, not
-- more up-front guessing.
WailaTrailTracer.TILE_SIZE = 8.0
WailaTrailTracer.SAMPLE_STEP = 1.0
-- Fewer hits than this in a tile is noise (a stray single wither dot),
-- not a real feature - same "don't get confused by scattered dots"
-- reasoning from the design conversation, same threshold reused for
-- both the noise filter and (later) the hole-size filter rather than
-- inventing a second number before either has real mileage.
WailaTrailTracer.MIN_HITS = 4
-- Eigenvalue ratio (dominant/minor variance) above this reads as
-- "elongated" (path); at or below reads as "roughly even in both
-- directions" (area).
WailaTrailTracer.PATH_ELONGATION_RATIO = 2.5

local function sampleTile(originX, originZ, tileSize, step)
    local hits = {}
    local steps = math.floor(tileSize / step)
    for i = 0, steps do
        for j = 0, steps do
            local x = originX + i * step
            local z = originZ + j * step
            if isTrailMaterialAt(x, z) then
                table.insert(hits, { x, z })
            end
        end
    end
    return hits
end

-- Closed-form 2x2 symmetric eigen-decomposition of the hit positions'
-- covariance matrix - no need for a general iterative eigensolver at
-- only 2 dimensions. Returns nil if there aren't enough hits to mean
-- anything.
local function pcaAnalyze(hits)
    local n = #hits
    if n == 0 then
        return nil
    end

    local meanX, meanZ = 0, 0
    for _, p in ipairs(hits) do
        meanX = meanX + p[1]
        meanZ = meanZ + p[2]
    end
    meanX = meanX / n
    meanZ = meanZ / n

    local sxx, szz, sxz = 0, 0, 0
    for _, p in ipairs(hits) do
        local dx, dz = p[1] - meanX, p[2] - meanZ
        sxx = sxx + dx * dx
        szz = szz + dz * dz
        sxz = sxz + dx * dz
    end
    sxx, szz, sxz = sxx / n, szz / n, sxz / n

    local trace = sxx + szz
    local det = sxx * szz - sxz * sxz
    local discriminant = math.sqrt(math.max(trace * trace / 4 - det, 0))
    local lambda1 = trace / 2 + discriminant
    local lambda2 = trace / 2 - discriminant

    local axisX, axisZ
    if sxz ~= 0 then
        axisX, axisZ = lambda1 - szz, sxz
    elseif sxx >= szz then
        axisX, axisZ = 1, 0
    else
        axisX, axisZ = 0, 1
    end
    local axisLength = math.sqrt(axisX * axisX + axisZ * axisZ)
    if axisLength > 0.0001 then
        axisX, axisZ = axisX / axisLength, axisZ / axisLength
    else
        axisX, axisZ = 1, 0
    end

    return {
        count = n,
        centroidX = meanX, centroidZ = meanZ,
        lambda1 = lambda1, lambda2 = lambda2,
        axisX = axisX, axisZ = axisZ,
    }
end

-- Public: samples one tile and classifies it. Returns
-- ("none"|"path"|"area", analysis-or-nil, rawHitCount). rawHitCount is
-- returned even on "none" (0 or few hits) - TEMPORARY, for the
-- "did we detect anything at all" debug pass: distinguishes "found zero
-- dirt/gravel material anywhere nearby" (rawHitCount always 0 - a real
-- material-check or scan-location problem) from "found hits, but they
-- didn't clear MIN_HITS/the elongation threshold" (a tuning problem,
-- not a detection problem).
function WailaTrailTracer.classifyTile(originX, originZ)
    local hits = sampleTile(originX, originZ, WailaTrailTracer.TILE_SIZE, WailaTrailTracer.SAMPLE_STEP)
    local analysis = pcaAnalyze(hits)

    if analysis == nil or analysis.count < WailaTrailTracer.MIN_HITS then
        return "none", nil, #hits
    end

    if analysis.lambda2 <= 0.0001 or analysis.lambda1 / analysis.lambda2 >= WailaTrailTracer.PATH_ELONGATION_RATIO then
        return "path", analysis, #hits
    end

    return "area", analysis, #hits
end

-- ============================================================
-- Path stitching - chain neighboring path-tiles into a spline
-- ============================================================

-- Meters - how far apart two path-tile centroids can be and still count
-- as the same trail. A bit more than TILE_SIZE so adjacent tiles that
-- both found the same trail actually connect.
WailaTrailTracer.STITCH_MAX_DISTANCE = WailaTrailTracer.TILE_SIZE * 1.5
-- Axis alignment threshold (abs of the dot product of two unit axes) -
-- close to 1 means "pointing the same or exactly opposite way" (a
-- PCA axis has no inherent sign, so opposite counts as aligned).
WailaTrailTracer.STITCH_MIN_ALIGNMENT = 0.7

-- Public: greedily chains a list of {centroidX, centroidZ, axisX, axisZ}
-- path-tile analyses into connected sequences. Returns a list of chains,
-- each chain a list of {x, z} points in stitched order (the tile
-- centroids themselves - this IS the spline, no separate simplification
-- needed since tiles are already coarse).
function WailaTrailTracer.stitchPathTiles(analyses)
    local visited = {}
    local chains = {}

    for startIndex = 1, #analyses do
        if not visited[startIndex] then
            visited[startIndex] = true
            local chain = { analyses[startIndex] }
            local current = analyses[startIndex]

            local extended = true
            while extended do
                extended = false
                local bestIndex, bestDistanceSq = nil, WailaTrailTracer.STITCH_MAX_DISTANCE * WailaTrailTracer.STITCH_MAX_DISTANCE

                for i = 1, #analyses do
                    if not visited[i] then
                        local candidate = analyses[i]
                        local dx = candidate.centroidX - current.centroidX
                        local dz = candidate.centroidZ - current.centroidZ
                        local distanceSq = dx * dx + dz * dz

                        if distanceSq <= bestDistanceSq then
                            local alignment = math.abs(current.axisX * candidate.axisX + current.axisZ * candidate.axisZ)
                            if alignment >= WailaTrailTracer.STITCH_MIN_ALIGNMENT then
                                bestIndex = i
                                bestDistanceSq = distanceSq
                            end
                        end
                    end
                end

                if bestIndex ~= nil then
                    visited[bestIndex] = true
                    current = analyses[bestIndex]
                    table.insert(chain, current)
                    extended = true
                end
            end

            local points = {}
            for _, entry in ipairs(chain) do
                table.insert(points, { entry.centroidX, entry.centroidZ })
            end
            table.insert(chains, points)
        end
    end

    return chains
end

-- ============================================================
-- Area boundary tracing - independent wall-follower, material-based
-- ============================================================

-- Meters - fixed step, unlike the field tracer's own resolution (which
-- it derives from the specific density map it reads). Terrain material
-- via getTerrainAttributesAtWorldPos has no equivalent "ask the map its
-- own resolution" call in what's confirmed so far - a fixed step is the
-- pragmatic choice for a first version, flagged as worth revisiting if
-- traced outlines look too coarse or too jittery in practice.
WailaTrailTracer.AREA_TRACE_STEP = 1.0
-- Real hang risk found live, not theoretical: this cap alone doesn't
-- bound wall-clock time -- the caller (scanRegion's own area loop)
-- wraps update() in `while stillTracing and guard < 1000 do
-- tracer:update(0.05) end`, so the OLD 15000 here meant up to 1000
-- calls x 50ms = 50 SECONDS of synchronous time for one pathological
-- trace (confirmed live: one real trace hit exactly this cap, "unable
-- to close boundary loop, giving up at 15001 positions"), and there can
-- be dozens of area clusters in one scanRegion call. Each step now also
-- does a real raycast (isSpotClearOfStructures), making the worst case
-- worse than when this number was picked. Dropped an order of magnitude
-- -- still generous for any real courtyard/trail-area shape, which
-- shouldn't need anywhere near this many raw points before
-- simplification, while keeping the actual worst-case wall-clock cost
-- sane. The guard cap below (scanRegion's own area-tracing loop) was
-- tightened to match -- see that comment for the real max-time math.
WailaTrailTracer.AREA_TRACE_MAX_POSITIONS = 1000
WailaTrailTracer.AREA_SIMPLIFY_TOLERANCE = 0.5

-- Meters - a real worn area (farmyard courtyard, TerraFarm-style yard)
-- has no business being bigger than this. Existing guards
-- (AREA_TRACE_MAX_POSITIONS, the per-trace tick cap in scanRegion)
-- bound how long a runaway trace takes to produce, but nothing stops
-- one from being kept once produced - and a seed that lands on/near a
-- real map road (permanent, paved, deliberately NOT something this
-- system should ever try to represent - a whole road network is huge,
-- interconnected, and exactly the "too many paths" crash risk already
-- hit once) can still balloon into a trace covering a huge span before
-- any tick/position cap kicks in. This is the actual "is this even a
-- legitimate area" check - discarded if too big, not tuned to trace
-- roads at all, tuned to reject a shape that plainly isn't a courtyard.
WailaTrailTracer.MAX_AREA_SPAN = 60.0

local function getPointsBoundingSpan(points)
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(points) do
        minX = math.min(minX, p[1])
        maxX = math.max(maxX, p[1])
        minZ = math.min(minZ, p[2])
        maxZ = math.max(maxZ, p[2])
    end
    return math.max(maxX - minX, maxZ - minZ)
end

WailaAreaTracer = {}
local WailaAreaTracer_mt = Class(WailaAreaTracer)

-- Public: nil if (x, z) isn't actually on trail material.
function WailaAreaTracer.new(x, z)
    local self = setmetatable({}, WailaAreaTracer_mt)
    self.curX = x
    self.curZ = z
    self.boundaryPositions = {}

    if not isTrailMaterialAt(self.curX, self.curZ) then
        return nil
    end
    return self
end

-- Same wall-follower shape as the field tracer (front/left/right density
-- checks, direction vector rotation) - independent implementation, see
-- this file's own header for why. isTrailMaterialAt is the "on-shape"
-- predicate instead of a field check.
function WailaAreaTracer:update(frameBudget)
    local step = WailaTrailTracer.AREA_TRACE_STEP
    local startTime = getTimeSec()

    while getTimeSec() - startTime < frameBudget do
        if #self.boundaryPositions == 0 then
            if isTrailMaterialAt(self.curX, self.curZ) then
                self.curZ = self.curZ + step
            else
                table.insert(self.boundaryPositions, { self.curX, self.curZ })
            end
        else
            local numPositions = #self.boundaryPositions
            local dirX, dirZ

            if numPositions >= 2 then
                dirX = self.boundaryPositions[numPositions][1] - self.boundaryPositions[numPositions - 1][1]
                dirZ = self.boundaryPositions[numPositions][2] - self.boundaryPositions[numPositions - 1][2]
            elseif not isTrailMaterialAt(self.curX + step, self.curZ) then
                dirX, dirZ = -1, 0
            elseif not isTrailMaterialAt(self.curX, self.curZ + step) then
                dirX, dirZ = 0, -1
            else
                dirX, dirZ = 1, 0
            end

            if dirX == 0 and dirZ == 0 then
                log("area trace stalled (zero direction vector) at %d positions, giving up", numPositions)
                self:finalize()
                return false
            end

            dirX, dirZ = MathUtil.vector2Normalize(dirX, dirZ)
            dirX = dirX * step
            dirZ = dirZ * step

            local frontValue = isTrailMaterialAt(self.curX + dirX, self.curZ + dirZ)
            local leftValue = isTrailMaterialAt(self.curX + dirZ, self.curZ - dirX)
            local rightValue = isTrailMaterialAt(self.curX - dirZ, self.curZ + dirX)

            if rightValue then
                if not frontValue then
                    self.curX = self.curX + dirX
                    self.curZ = self.curZ + dirZ
                elseif not rightValue then
                    self.curX = self.curX - dirZ
                    self.curZ = self.curZ + dirX
                elseif not leftValue then
                    self.curX = self.curX + dirZ
                    self.curZ = self.curZ - dirX
                else
                    self.curX = self.curX - dirX
                    self.curZ = self.curZ - dirZ
                end
            else
                self.curX = self.curX - dirZ
                self.curZ = self.curZ + dirX
            end

            -- Natural endpoint, not another pathological-boundary case
            -- to grind through: a real road/building sitting on ground
            -- still painted dirt/gravel underneath is indistinguishable
            -- from an open trail by material alone (see
            -- isSpotClearOfStructures' own comment). Stop the trace
            -- right here instead of wall-following across/through it --
            -- "we don't care about those."
            if not isSpotClearOfStructures(self.curX, self.curZ) then
                log("area trace hit a real structure/road at %d positions, stopping", #self.boundaryPositions)
                self:finalize()
                return false
            end

            table.insert(self.boundaryPositions, { self.curX, self.curZ })
        end

        local numPositions = #self.boundaryPositions
        if numPositions > 10 then
            local distance = MathUtil.vector2Length(
                self.boundaryPositions[numPositions][1] - self.boundaryPositions[1][1],
                self.boundaryPositions[numPositions][2] - self.boundaryPositions[1][2]
            )
            if distance < step then
                self:finalize()
                return false
            end
        end

        if numPositions > WailaTrailTracer.AREA_TRACE_MAX_POSITIONS then
            log("area trace unable to close boundary loop, giving up at %d positions", numPositions)
            self:finalize()
            return false
        end
    end

    return true
end

function WailaAreaTracer:finalize()
    local maxValue = -math.huge
    local maxValueIndex = 0
    for i, position in ipairs(self.boundaryPositions) do
        local value = position[1] * position[2] * 0.1
        if value > maxValue then
            maxValue = value
            maxValueIndex = i
        end
    end

    local reordered = {}
    for i = maxValueIndex, #self.boundaryPositions do
        table.insert(reordered, self.boundaryPositions[i])
    end
    for i = 1, maxValueIndex - 1 do
        table.insert(reordered, self.boundaryPositions[i])
    end
    if #reordered > 0 then
        table.insert(reordered, { reordered[1][1], reordered[1][2] })
    end
    self.boundaryPositions = reordered
end

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

-- Public: simplified {x, z} point list, open ring (no closing duplicate) -
-- callers doing line-segment rendering want that, not a Polygon2D.
function WailaAreaTracer:getSimplifiedPoints()
    local openRing = self.boundaryPositions
    local first, last = openRing[1], openRing[#openRing]
    if #openRing > 1 and first[1] == last[1] and first[2] == last[2] then
        openRing = {}
        for i = 1, #self.boundaryPositions - 1 do
            table.insert(openRing, self.boundaryPositions[i])
        end
    end

    return simplifyBoundary(openRing, WailaTrailTracer.AREA_SIMPLIFY_TOLERANCE)
end

-- ============================================================
-- Orchestration - scan a bounded region, return paths + areas
-- ============================================================

-- Meters - a full-map tile scan at TILE_SIZE=8 would be hundreds of
-- thousands of terrain queries on a large map (CreativeHorizonIW is a
-- "4x" map), far too expensive for one synchronous pass. Scoped to a
-- bounded radius around the player for this first version instead - a
-- deliberate, temporary scope limit, not the intended final shape.
-- Real whole-map coverage needs the same frame-budget-spreading pattern
-- WailaFieldGridScanner already uses (many small ticks across many
-- frames, not one big synchronous pass) - worth doing once the
-- classification/stitching/tracing approach itself is confirmed to
-- produce sensible results, not before.
WailaTrailTracer.SCAN_RADIUS = 100.0
-- User-specified real ceiling for the area-tracing phase's own total
-- wall-clock time, not the per-trace guard (~1s worst case) -- see that
-- guard's own comment and this deadline's usage in scanRegion for why
-- both are needed: the per-trace guard bounds one cluster, this bounds
-- the aggregate across however many a busy scan finds.
WailaTrailTracer.SWEEP_DEADLINE_SEC = 10.0

-- Real, confirmed live bug this whole grid exists to fix: the old dedup
-- (skip a candidate area seed if its centroid was within
-- TILE_SIZE*2 = 16m of an already-traced seed) only ever compared NEW
-- seeds against OLD SEEDS -- never against the actual footprint of a
-- completed trace. A wall-follower's boundary can run 50+ meters once
-- started, so any seed tile more than 16m from a prior seed (trivial
-- along any edge longer than ~16m) triggered a brand new, fully
-- redundant re-trace of the SAME physical boundary from a different
-- starting point -- confirmed live, screenshots showing the same edge
-- traced on the order of dozens of times, a dense thread-bundle of
-- near-identical overlapping lines.
--
-- Real, proven fix ported from WailaFieldGridScanner's own
-- claimPolygonCells (same problem, same map-scale scanning domain,
-- already solved there): mark every grid cell a completed trace's
-- polygon actually covers, bounding-box-limited, and skip any future
-- candidate whose cell is already claimed. Scoped locally to one
-- scanRegion() call (a flat table, not a persistent object) since this
-- is still one synchronous pass, not WailaFieldGridScanner's own
-- multi-tick incremental scan.
--
-- Same mechanism doubles as the fix for a second, related bug: paths
-- claim their own territory FIRST (see scanRegion below), so an
-- area-tile candidate landing on a cell a path already stitched through
-- is skipped before an area trace is even attempted on it -- "paths
-- always win first," per explicit instruction, since a track's wear
-- intensity varying along its length can locally misclassify a single
-- tile as an "area" (patchy dirt/gravel inside one 8x8m tile), and
-- without this that one tile could seed a wall-follower that traces the
-- whole track as a sprawling, jaggedly-retraced area instead.
local function claimedCellKey(col, row)
    return col * 100000 + row
end

local function worldToLocalCell(x, z, originX, originZ, cellSize)
    return math.floor((x - originX) / cellSize), math.floor((z - originZ) / cellSize)
end

local function isCellClaimed(claimed, x, z, originX, originZ, cellSize)
    local col, row = worldToLocalCell(x, z, originX, originZ, cellSize)
    return claimed[claimedCellKey(col, row)] == true
end

local function claimPolygonCells(claimed, points, originX, originZ, cellSize)
    if #points < 3 then
        return
    end

    local flatVertices = {}
    for _, p in ipairs(points) do
        table.insert(flatVertices, p[1])
        table.insert(flatVertices, p[2])
    end
    local polygon = Polygon2D.new(nil, flatVertices)

    local minX, maxX, minZ, maxZ = polygon:getBoundingBox()
    if minX == nil then
        return
    end

    local startCol, startRow = worldToLocalCell(minX, minZ, originX, originZ, cellSize)
    local endCol, endRow = worldToLocalCell(maxX, maxZ, originX, originZ, cellSize)

    for row = startRow, endRow do
        for col = startCol, endCol do
            local key = claimedCellKey(col, row)
            if not claimed[key] then
                local x = originX + (col + 0.5) * cellSize
                local z = originZ + (row + 0.5) * cellSize
                if WailaUtil.getIsPosInsidePolygon(polygon, x, z) then
                    claimed[key] = true
                end
            end
        end
    end
end

-- A stitched path chain isn't a closed shape, so claimPolygonCells'
-- inside-the-polygon test doesn't apply -- claim a small radius of
-- cells around each point along the chain instead, wide enough to cover
-- the tile a real trail tile-scan would classify as belonging to this
-- same track (TILE_SIZE-wide tiles feeding the classifier this chain
-- was stitched from in the first place).
local function claimPathCells(claimed, points, originX, originZ, cellSize)
    for _, p in ipairs(points) do
        local col, row = worldToLocalCell(p[1], p[2], originX, originZ, cellSize)
        for dRow = -1, 1 do
            for dCol = -1, 1 do
                claimed[claimedCellKey(col + dCol, row + dRow)] = true
            end
        end
    end
end

-- Public: scans a SCAN_RADIUS box centered on (centerX, centerZ),
-- classifies every tile, stitches path-tiles into splines, traces
-- area-tiles into simplified outlines. Runs the area tracer to
-- completion synchronously per cluster (bounded by
-- AREA_TRACE_MAX_POSITIONS) rather than spreading it across frames -
-- acceptable for a periodic (not per-frame) rebuild call, same
-- reasoning TaskMap's own existing rebuildAllHotspots already uses.
-- Returns { paths = { {x,z}, {x,z}, ... }, areas = { {x,z}, ... } } -
-- one entry per path list is a spline (already-simplified point
-- sequence, ready to render as line segments), one entry per areas list
-- is a closed-ish outline (open ring, same shape).
function WailaTrailTracer.scanRegion(centerX, centerZ)
    local radius = WailaTrailTracer.SCAN_RADIUS
    local tileSize = WailaTrailTracer.TILE_SIZE
    local minX, maxX = centerX - radius, centerX + radius
    local minZ, maxZ = centerZ - radius, centerZ + radius

    local pathAnalyses = {}
    local areaAnalyses = {}

    -- TEMPORARY diagnostic counters - "did we detect anything at all"
    -- debug pass. tilesWithHits/maxHitsSeen answer "is the material check
    -- finding dirt/gravel at all near the scan center" independent of
    -- whether classification/stitching later accepts or discards it.
    local tilesScanned, tilesNone, tilesPath, tilesArea = 0, 0, 0, 0
    local tilesWithHits, maxHitsSeen = 0, 0

    local z = minZ
    while z < maxZ do
        local x = minX
        while x < maxX do
            local kind, analysis, rawHitCount = WailaTrailTracer.classifyTile(x, z)
            tilesScanned = tilesScanned + 1
            if rawHitCount ~= nil and rawHitCount > 0 then
                tilesWithHits = tilesWithHits + 1
                maxHitsSeen = math.max(maxHitsSeen, rawHitCount)
            end
            if kind == "path" then
                tilesPath = tilesPath + 1
                table.insert(pathAnalyses, analysis)
            elseif kind == "area" then
                tilesArea = tilesArea + 1
                table.insert(areaAnalyses, analysis)
            else
                tilesNone = tilesNone + 1
            end
            x = x + tileSize
        end
        z = z + tileSize
    end

    log("scanRegion center=(%.1f,%.1f) radius=%.0f tileSize=%.0f -> tilesScanned=%d tilesWithHits=%d maxHitsInOneTile=%d (of %d samples/tile) classified: none=%d path=%d area=%d",
        centerX, centerZ, radius, tileSize, tilesScanned, tilesWithHits, maxHitsSeen,
        (math.floor(tileSize / WailaTrailTracer.SAMPLE_STEP) + 1) ^ 2, tilesNone, tilesPath, tilesArea)

    -- Real, confirmed-necessary outer deadline, not a "maybe someday":
    -- the per-trace guard above (~1s worst case) bounds each individual
    -- area, but not the AGGREGATE across however many distinct clusters
    -- a busy scan finds -- confirmed live, one real scan hit the position
    -- cap on dozens of genuinely separate areas (53 traced total), which
    -- the claimed-cell dedup above can't help with since these weren't
    -- redundant re-traces of the same spot, just a lot of real messy
    -- ground near the scan center. Up to ~1s x 53 is a real, serious
    -- cumulative stall, every TRAIL_SCAN_INTERVAL. Killed on our own
    -- terms once the area-tracing phase alone (the dominant cost -- tile
    -- classification is cheap density reads, no raycasts) crosses this,
    -- returning whatever's already been traced instead of pushing
    -- through the remaining clusters.
    local sweepStartTime = getTimeSec()

    -- Real, confirmed-live bug (reported directly, screenshots of a
    -- clearly path-shaped worn track traced as a sprawling jagged
    -- "area" instead): this used to run area-tracing FIRST, claim
    -- territory, and only filter path-tiles against that claimed grid
    -- afterward - meaning a single tile along an obviously elongated
    -- track that happened to locally misclassify as "area" (patchy
    -- material inside one 8x8m tile) could seed a wall-follower that
    -- traces the ENTIRE track, and any correctly-classified path-tiles
    -- nearby then got thrown away for "already being inside an area" -
    -- exactly backwards. Paths now claim their own territory FIRST;
    -- area candidates already inside a claimed path cell are skipped
    -- before an area trace is even attempted on them, not filtered out
    -- of the result afterward (also saves the wasted trace work itself).
    local claimed = {}

    local paths = WailaTrailTracer.stitchPathTiles(pathAnalyses)
    for _, chain in ipairs(paths) do
        claimPathCells(claimed, chain, minX, minZ, tileSize)
    end

    local areas = {}
    local areaCandidateCount = 0
    for _, analysis in ipairs(areaAnalyses) do
        if getTimeSec() - sweepStartTime > WailaTrailTracer.SWEEP_DEADLINE_SEC then
            log("scanRegion area-tracing phase hit its %.0fs sweep deadline with %d/%d area clusters left unprocessed, stopping early",
                WailaTrailTracer.SWEEP_DEADLINE_SEC, #areaAnalyses - areaCandidateCount, #areaAnalyses)
            break
        end

        if not isCellClaimed(claimed, analysis.centroidX, analysis.centroidZ, minX, minZ, tileSize) then
            areaCandidateCount = areaCandidateCount + 1
            local tracer = WailaAreaTracer.new(analysis.centroidX, analysis.centroidZ)
            if tracer ~= nil then
                local stillTracing = true
                local guard = 0
                -- Real hang risk found live: guard < 1000 x 50ms budget
                -- per update() call = up to 50 SECONDS of synchronous
                -- time for one pathological trace, with dozens of area
                -- clusters possibly needing this per scanRegion call.
                -- AREA_TRACE_MAX_POSITIONS dropping 15000 -> 1000 (see
                -- its own comment) cuts real worst-case work by the same
                -- order of magnitude, but this guard is the actual
                -- wall-clock backstop -- 20 x 50ms = 1 second absolute
                -- max per trace, regardless of how expensive any single
                -- step turns out to be (each now does a real raycast,
                -- not just cheap density reads).
                while stillTracing and guard < 20 do
                    stillTracing = tracer:update(0.05)
                    guard = guard + 1
                end
                local points = tracer:getSimplifiedPoints()
                if #points >= 3 and getPointsBoundingSpan(points) <= WailaTrailTracer.MAX_AREA_SPAN then
                    table.insert(areas, points)
                    claimPolygonCells(claimed, points, minX, minZ, tileSize)
                end
            end
        end
    end

    log("scanRegion result: %d path chain(s) from %d path-tile(s), %d traced area(s) from %d area-tile(s) (%d suppressed as inside a path's own claimed territory)",
        #paths, #pathAnalyses, #areas, #areaAnalyses, #areaAnalyses - areaCandidateCount)

    return { paths = paths, areas = areas }
end
