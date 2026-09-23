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
local TRAIL_MATERIALS = { [MATERIAL_DIRT] = true, [MATERIAL_GRAVEL] = true, [MATERIAL_STONE] = true }

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

-- Exposed on the module table (same reasoning as newScanner below: a
-- `local function` in this file is invisible to every OTHER file in this
-- same mod too, not just other mods -- FS25 sourceFiles don't share
-- chunk-scoped locals, only the module table/globals. WailaTerrainInspector
-- needs this same check for the general "Ground:" HUD line (ground texture
-- alone can't tell a road from a worn trail, see the comment above this
-- function) -- throttled to ~10/s by the point-inspection timer, nowhere
-- near the tile-scan hot path this function's own comment warns about.
WailaTrailTracer.isSpotClearOfStructures = isSpotClearOfStructures

-- ============================================================
-- Tile scan + PCA classification (paths, and area seed-finding)
-- ============================================================

-- Meters. Real request: this predates PATH_WIDTH being widened to 10.0 --
-- an 8x8m sampling window can't reliably see BOTH edges of a real
-- feature that's already wider than the window itself, so a tile
-- sampled entirely inside a wide road/shoulder can look artificially
-- uniform (low elongation) in the direction it can't see across,
-- reading as rounder/more "area"-like than the corridor actually is.
-- Widened past PATH_WIDTH so any tile has a real chance of seeing both
-- edges of even the widest realistic path. Total sample cost across a
-- fixed scan area is basically unchanged either way (more samples per
-- tile, proportionally fewer tiles) -- this is a resolution choice, not
-- a performance one.
WailaTrailTracer.TILE_SIZE = 16.0
WailaTrailTracer.SAMPLE_STEP = 1.0
-- Fewer hits than this in a tile is noise (a stray single wither dot),
-- not a real feature - same "don't get confused by scattered dots"
-- reasoning from the design conversation, same threshold reused for
-- both the noise filter and (later) the hole-size filter rather than
-- inventing a second number before either has real mileage.
-- Scaled up 4x alongside TILE_SIZE going from 8x8 to 16x16 (4x the
-- sample count, ~81 to ~289) -- the original 4 was calibrated relative
-- to the smaller tile's own sample count; left as an absolute count
-- while the tile quadrupled in area would have quietly made this filter
-- far weaker (a much smaller fraction of the tile needing to hit for
-- something to count as "not noise").
WailaTrailTracer.MIN_HITS = 16
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
        -- Real, reported-live gap this closes: elongation ratio ALONE
        -- isn't enough to call something a path -- a tile can read as
        -- locally elongated purely from where its own hit-scatter happens
        -- to land (a material seam, plain sampling noise) even while
        -- sitting deep inside one big continuous open area, where trail
        -- material plainly keeps going well past any real path's width if
        -- you actually look. Confirms narrowness directly: step off the
        -- tile's own dominant axis, perpendicular, by a real path's own
        -- width (PATH_WIDTH -- reusing the SAME number this file already
        -- uses to define how wide a path actually is, not a new invented
        -- threshold) on both sides. Still trail material out there on
        -- either side means whatever this is, it's already wider than a
        -- path can be, so it can't be one -- falls through to "area"
        -- below instead of trusting the ratio alone.
        local perpX, perpZ = -analysis.axisZ, analysis.axisX
        local checkDist = WailaTrailTracer.PATH_WIDTH
        local wideOnRight = isTrailMaterialAt(analysis.centroidX + perpX * checkDist, analysis.centroidZ + perpZ * checkDist)
        local wideOnLeft = isTrailMaterialAt(analysis.centroidX - perpX * checkDist, analysis.centroidZ - perpZ * checkDist)

        if not wideOnRight and not wideOnLeft then
            return "path", analysis, #hits
        end
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
-- Meters - how close the walk has to get back to its OWN first recorded
-- position before counting as a genuine closed loop. Real, confirmed-live
-- bug this replaces: the old check compared against AREA_TRACE_STEP
-- itself (1.0m) -- expecting the walk to land back on the exact starting
-- cell, which the path-width detour (isOpenAt hugging a path's real edge,
-- see its own comment) makes even less likely than plain step-quantization
-- noise already did on its own: a trace can come back around within a
-- couple meters of where it started without ever re-landing on that exact
-- cell, so it ran to AREA_TRACE_MAX_POSITIONS instead of recognizing it
-- was already home -- confirmed live, a burst of "unable to close boundary
-- loop, giving up at 1001 positions" log lines from what should have been
-- one straightforward field boundary, and (since nothing that never closes
-- gets claimed) every candidate tile nearby re-attempting and re-failing
-- the same near-miss walk, rendering as the exact tangled thread-bundle
-- this file's own header already flagged once before. A few step-lengths,
-- not one -- first tuned guess, same footing as AREA_TRACE_STEP's own
-- comment, flagged the same way as worth revisiting against real traced
-- shapes rather than assumed correct up front.
WailaTrailTracer.AREA_CLOSE_TOLERANCE = WailaTrailTracer.AREA_TRACE_STEP * 3
-- Radians -- how much of a full lap (2*pi) the walk must have actually
-- turned through before EITHER closure check below (close-to-start OR
-- self-history) is allowed to trust a proximity match at all. Real,
-- confirmed-live gap this closes: proximity alone can't tell "genuinely
-- came back around" apart from "two unrelated parts of a bigger, more
-- complex shape happen to pass close to each other" -- a shape missing a
-- real quarter of its own area, cut off by a coincidental 3m proximity
-- treated as a completed lap. A real geometric invariant, not a tuned
-- guess like this file's other constants: a simple polygon's exterior
-- turning angles always sum to exactly 360 degrees for one full lap,
-- regardless of concave/convex corners. 0.75 of a full lap (270 degrees)
-- is real slack for step-quantization noise, not the exact theoretical
-- value -- flagged the same way as worth revisiting against real traced
-- shapes if it turns out too strict or too loose in practice.
WailaTrailTracer.MIN_TURN_ANGLE_FOR_CLOSURE = 2 * math.pi * 0.75
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
-- Meters. Corner-cutting threshold, separate from AREA_SIMPLIFY_TOLERANCE
-- above -- real, confirmed live: Douglas-Peucker only drops a point when
-- its perpendicular deviation from a longer baseline is small, but a
-- staircase notch from the wall-follower's own axis-aligned stepping
-- (AREA_TRACE_STEP=1.0, cardinal directions only) can have a deviation
-- well above that tolerance even though both of its own edges are short
-- -- confirmed in a real traced screenshot, residual right-angle notches
-- surviving simplification. First guess at the "how short counts as a
-- quantization-scale notch, not real boundary shape" cutoff, flagged
-- like AREA_TRACE_STEP's own comment as worth revisiting once seen live
-- rather than assumed correct up front.
WailaTrailTracer.CORNER_CUT_MAX_SEGMENT_LENGTH = 3.0

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

-- Degrees. Real request: a needle-sharp corner (well under 30 degrees)
-- isn't something any real in-game feature can actually produce -- a
-- terrain brush has a minimum radius, a rectangle brush draws right
-- angles, and a tractor/TerraFarm implement physically can't turn on a
-- dime, so a real worn area's own corners are bounded by what those
-- tools can actually draw. A sharp spike showing up in a traced polygon
-- is a real, confirmed-live symptom of noise/an algorithm artifact (the
-- "stupid little things painted along roads"), not a legitimate corner --
-- same class of sanity check MAX_AREA_SPAN already is ("is this even a
-- legitimate area," not tuned to any specific real shape), just checking
-- corner sharpness instead of overall size.
WailaTrailTracer.MIN_INTERIOR_ANGLE_DEGREES = 30.0

-- Public: true if any vertex in a closed polygon (points is an open ring,
-- same convention getSimplifiedPoints/claimPolygonCells already use --
-- wraps around implicitly) has an interior angle sharper than minDegrees.
-- The angle between a vertex's own two adjacent edges (acos of their
-- normalized dot product) is well-defined regardless of winding
-- direction, so this needs no orientation/sign handling at all.
function WailaTrailTracer.hasSharpAngle(points, minDegrees)
    local n = #points
    if n < 3 then
        return false
    end

    local minAngleRad = math.rad(minDegrees)
    for i = 1, n do
        local prev = points[i == 1 and n or i - 1]
        local cur = points[i]
        local nxt = points[i == n and 1 or i + 1]

        local ax, az = prev[1] - cur[1], prev[2] - cur[2]
        local bx, bz = nxt[1] - cur[1], nxt[2] - cur[2]
        local aLen = MathUtil.vector2Length(ax, az)
        local bLen = MathUtil.vector2Length(bx, bz)

        if aLen > 0.0001 and bLen > 0.0001 then
            local cosAngle = (ax * bx + az * bz) / (aLen * bLen)
            cosAngle = math.max(-1, math.min(1, cosAngle))
            if math.acos(cosAngle) < minAngleRad then
                return true
            end
        end
    end
    return false
end

-- Real, confirmed-live gap the plain "close to the very first recorded
-- point" check below can't catch: a wall-follower that hits a dead end (a
-- narrow sliver/peninsula, or a small roundabout island where each lap
-- drifts slightly from the last under 1m-step quantization) either has to
-- double back along the OTHER side of the same narrow feature, or simply
-- never lands exactly back within tolerance of point[1] specifically even
-- though it's plainly retracing its own earlier path by lap two -- both
-- confirmed live (a farmyard dead-end doubling back close-parallel to
-- itself, and a roundabout island traced going around in circles several
-- times, nesting slightly inward each lap). This checks proximity to ANY
-- sufficiently-old point on the SAME walk, not just the first one -- own
-- small grid, separate from the scanner-wide claimed-cell grid
-- (claimedCellKey/worldToLocalCell below use a DIFFERENT cell size and
-- are defined later in this file, so not reusable as upvalues here
-- without reordering already-working code for no real benefit).
local SELF_HISTORY_CELL_SIZE = WailaTrailTracer.AREA_CLOSE_TOLERANCE
-- How many of the walk's OWN most recent steps stay OUT of the
-- self-history grid -- otherwise every single step trivially reads as
-- "near" the last few steps just taken, by construction
-- (AREA_TRACE_STEP is smaller than SELF_HISTORY_CELL_SIZE). Marking is
-- itself lagged by this many steps (see markSelfHistory's own call site),
-- not just excluded from the query, so the grid never contains anything
-- from inside this trailing window in the first place.
local SELF_HISTORY_LAG = 10

local function selfHistoryCellKey(col, row)
    return col * 100000 + row
end

local function worldToSelfHistoryCell(x, z)
    return math.floor(x / SELF_HISTORY_CELL_SIZE), math.floor(z / SELF_HISTORY_CELL_SIZE)
end

-- index (the point's own position in boundaryPositions) is stored, not
-- just a bare true/false -- real bug this fixes, confirmed live: a
-- closed shape missing roughly a quarter of its real area, cut off by
-- one long straight chord. finalize() always closes the walk back to
-- boundaryPositions[1] specifically (the ORIGINAL start point) -- correct
-- for the "close to point[1]" check above, since that IS point[1] by
-- definition, but WRONG for a self-history match against some OTHER,
-- later point: the real closed loop is [matchedIndex .. current], not
-- [1 .. current], and forcing point[1] as the closing anchor draws a
-- straight line across the shape's own interior instead of trimming to
-- the genuinely closed sub-loop. Knowing WHICH index matched (see
-- isNearSelfHistory's own return value and its call site's trim) is what
-- makes that trim possible.
local function markSelfHistory(visited, x, z, index)
    local col, row = worldToSelfHistoryCell(x, z)
    visited[selfHistoryCellKey(col, row)] = index
end

-- Returns the matched point's own index into boundaryPositions, or nil.
local function isNearSelfHistory(visited, x, z)
    local col, row = worldToSelfHistoryCell(x, z)
    for dRow = -1, 1 do
        for dCol = -1, 1 do
            local index = visited[selfHistoryCellKey(col + dCol, row + dRow)]
            if index ~= nil then
                return index
            end
        end
    end
    return nil
end

WailaAreaTracer = {}
local WailaAreaTracer_mt = Class(WailaAreaTracer)

-- Public: nil if (x, z) isn't actually on trail material. isBlockedFn is
-- optional (x, z) -> bool -- true means "treat this as a boundary," same
-- as hitting a structure or non-trail material. Covers everything the
-- walker itself has zero other way to know about: proximity to a stitched
-- path chain (distanceToPathsSq, a real geometric width test), AND
-- whether (x, z) has even left the scanner's own scanned window -- see
-- isOpenAt below for why the walk itself needs both, not just seed
-- selection.
function WailaAreaTracer.new(x, z, isBlockedFn)
    local self = setmetatable({}, WailaAreaTracer_mt)
    self.curX = x
    self.curZ = z
    self.isBlockedFn = isBlockedFn
    self.boundaryPositions = {}
    -- Own grid, real gap this closes -- see the comment above
    -- isNearSelfHistory's own declaration.
    self.selfHistoryVisited = {}
    -- Real gap both closure checks below share, per explicit request:
    -- proximity ALONE (to point[1], or to any older self-history point)
    -- can't tell "the walk genuinely came back around" apart from "two
    -- unrelated parts of a bigger, more complex shape just happen to
    -- pass close to each other" -- confirmed live, a shape missing a
    -- real quarter of its own area because a coincidental 3m proximity
    -- got treated as if it were a completed lap. A simple (non-self-
    -- intersecting) polygon's own exterior turning angles always sum to
    -- a net 360 degrees for exactly one full lap around it, regardless of
    -- how concave/convex its corners are -- a real, well-known geometric
    -- invariant, not a heuristic guess. Tracking it here (updated once
    -- per accepted step, see the table.insert call site below) lets both
    -- closure checks require "has actually gone most of the way around
    -- something," not just "is near a point," before trusting a match.
    self.cumulativeTurnAngle = 0
    -- Real, confirmed-live bug: finalize() below force-closes whatever
    -- partial trace exists into a polygon shape regardless of WHY the
    -- walk stopped -- a trace that got cut off early (hit a building, a
    -- stall, the position cap) looks identical, after finalize(), to one
    -- that genuinely walked all the way back to its own start. That
    -- produced small, tightly-clipped "areas" hugging whatever structure
    -- happened to abort the trace, instead of the real, much larger
    -- material boundary the walk never got to finish (confirmed live:
    -- a farmyard's dirt yard traced as a shape hugging the building's own
    -- silhouette instead of the visibly much bigger dirt-to-grass edge).
    -- Only the natural-closure branch below sets this true.
    self.closedNaturally = false
    -- Kept separate from curX/curZ, which mutate as the walk proceeds --
    -- needed after the trace finishes to check the trace actually bounds
    -- the region it was seeded in (see the seed-containment check in
    -- WailaTrailScanner:update, and its own comment for the real bug this
    -- fixes: a seed deep inside a giant dirt/gravel field can still walk
    -- straight into a small nearby non-trail island -- e.g. a placeable's
    -- own stone apron sitting well outside the placeable's actual
    -- collision footprint, confirmed live via WAILA itself: aiming at the
    -- apron reports plain terrain, no Placeable object, so
    -- isSpotClearOfStructures never fires there -- and wall-follow that
    -- island's tiny closed loop instead of the true, much larger outer
    -- boundary the seed was actually meant to bound.
    self.seedX, self.seedZ = x, z

    if not self:isOpenAt(self.curX, self.curZ) then
        return nil
    end
    return self
end

-- Real, confirmed-live gap this closes: path territory (paths stake their
-- own claim FIRST, see runStitchTransition's own comment for "paths always
-- win") used to only ever be consulted before STARTING a trace -- picking
-- a seed already inside claimed territory. Nothing stopped an area trace
-- legitimately seeded OUTSIDE that territory from wandering straight INTO
-- it mid-walk and along a path's own length once there -- materially a
-- worn path is identical dirt/gravel to the field it runs through, so
-- isTrailMaterialAt alone can never tell the two apart. Reported live: the
-- same giant-field seed repeatedly hit AREA_TRACE_MAX_POSITIONS without
-- ever closing, consistent with the walk escaping down a path corridor
-- instead of following the field's own much shorter true edge.
--
-- A SECOND, more fundamental gap this same predicate now also closes,
-- reported live: this walk operates on raw world coordinates via
-- isTrailMaterialAt alone -- it had ZERO awareness of the scanner's own
-- SCAN_RADIUS window. A track running past the edge of that window is
-- simply unclassified territory out there -- no tile scan, no path
-- chain, no claim, nothing -- so no amount of fixing path-exclusion
-- INSIDE the window stops a trace from wandering straight out past its
-- edge into never-scanned ground and just keeps walking. isBlockedFn now
-- also carries a real bounds check (self.minX/maxX/minZ/maxZ from
-- WailaTrailScanner, see its own construction call site) so the window
-- boundary itself acts as a wall, exactly like a structure hit already
-- does -- a trace can no longer escape the region it was actually scanned
-- against.
--
-- Either check is a real geometric test, not the old grid-blob claim --
-- so this doesn't just block the walker, it makes the walker's own
-- already-generic boundary-following logic hug the real edge (a path's
-- width, or the scan window itself), then naturally resume ordinary
-- material-based wall-following the moment it's clear, no separate
-- "entering/leaving" code needed for either case.
function WailaAreaTracer:isOpenAt(x, z)
    if self.isBlockedFn ~= nil and self.isBlockedFn(x, z) then
        return false
    end
    return isTrailMaterialAt(x, z)
end

-- Same wall-follower shape as the field tracer (front/left/right density
-- checks, direction vector rotation) - independent implementation, see
-- this file's own header for why. isOpenAt (trail material AND not
-- claimed path territory) is the "on-shape" predicate instead of a field
-- check.
function WailaAreaTracer:update(frameBudget)
    local step = WailaTrailTracer.AREA_TRACE_STEP
    local startTime = getTimeSec()

    while getTimeSec() - startTime < frameBudget do
        if #self.boundaryPositions == 0 then
            if self:isOpenAt(self.curX, self.curZ) then
                self.curZ = self.curZ + step
            else
                table.insert(self.boundaryPositions, { self.curX, self.curZ })
                -- Parallel to boundaryPositions -- turnAngleHistory[i] is
                -- cumulativeTurnAngle's own value at the moment
                -- boundaryPositions[i] was recorded. Needed so a
                -- self-history match against some earlier index can
                -- compute the turn accumulated OVER JUST that sub-loop
                -- (now minus then), not the whole walk's total -- see
                -- the self-history closure check's own comment for why
                -- the sub-loop's own turn is what actually matters there.
                self.turnAngleHistory = { self.cumulativeTurnAngle }
            end
        else
            local numPositions = #self.boundaryPositions
            local dirX, dirZ

            if numPositions >= 2 then
                dirX = self.boundaryPositions[numPositions][1] - self.boundaryPositions[numPositions - 1][1]
                dirZ = self.boundaryPositions[numPositions][2] - self.boundaryPositions[numPositions - 1][2]
            elseif not self:isOpenAt(self.curX + step, self.curZ) then
                dirX, dirZ = -1, 0
            elseif not self:isOpenAt(self.curX, self.curZ + step) then
                dirX, dirZ = 0, -1
            else
                dirX, dirZ = 1, 0
            end

            if dirX == 0 and dirZ == 0 then
                log("area trace stalled (zero direction vector) at %d positions, giving up", numPositions)
                self.stopReason = "stalled"
                self:finalize()
                return false
            end

            dirX, dirZ = MathUtil.vector2Normalize(dirX, dirZ)
            dirX = dirX * step
            dirZ = dirZ * step

            local frontValue = self:isOpenAt(self.curX + dirX, self.curZ + dirZ)
            local leftValue = self:isOpenAt(self.curX + dirZ, self.curZ - dirX)
            local rightValue = self:isOpenAt(self.curX - dirZ, self.curZ + dirX)

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
                self.stopReason = "structure"
                self:finalize()
                return false
            end

            table.insert(self.boundaryPositions, { self.curX, self.curZ })

            -- Signed turning angle at this new step, added to the
            -- running total -- see cumulativeTurnAngle's own comment in
            -- .new for why this exists. atan2(cross, dot) between the
            -- previous segment's own direction and this new one gives an
            -- exact signed angle for any two vectors, not just the
            -- axis-aligned ones this wall-follower happens to always
            -- produce -- no reason to special-case that.
            local n = #self.boundaryPositions
            if n >= 3 then
                local ax = self.boundaryPositions[n - 1][1] - self.boundaryPositions[n - 2][1]
                local az = self.boundaryPositions[n - 1][2] - self.boundaryPositions[n - 2][2]
                local bx = self.boundaryPositions[n][1] - self.boundaryPositions[n - 1][1]
                local bz = self.boundaryPositions[n][2] - self.boundaryPositions[n - 1][2]
                local cross = ax * bz - az * bx
                local dot = ax * bx + az * bz
                self.cumulativeTurnAngle = self.cumulativeTurnAngle + math.atan2(cross, dot)
            end
            table.insert(self.turnAngleHistory, self.cumulativeTurnAngle)
        end

        local numPositions = #self.boundaryPositions
        if numPositions > 10 then
            local distance = MathUtil.vector2Length(
                self.boundaryPositions[numPositions][1] - self.boundaryPositions[1][1],
                self.boundaryPositions[numPositions][2] - self.boundaryPositions[1][2]
            )
            -- Gated on cumulativeTurnAngle too now -- see
            -- MIN_TURN_ANGLE_FOR_CLOSURE's own comment: proximity to
            -- point[1] alone doesn't prove the walk actually went around
            -- anything, a real pinch/neck in a bigger shape can pass
            -- close to its own start without having completed a lap.
            if distance < WailaTrailTracer.AREA_CLOSE_TOLERANCE
                and math.abs(self.cumulativeTurnAngle) >= WailaTrailTracer.MIN_TURN_ANGLE_FOR_CLOSURE then
                self.closedNaturally = true
                self.stopReason = "closed_at_start"
                self:finalize()
                return false
            end
        end

        -- Lagged marking, real reason (see isNearSelfHistory's own
        -- comment): never mark a point into the walk's own history grid
        -- until it's already SELF_HISTORY_LAG steps old, so the query
        -- right below can never trivially match the walk's own last few
        -- steps just taken.
        local historyIndex = numPositions - SELF_HISTORY_LAG
        if historyIndex >= 1 then
            local historyPoint = self.boundaryPositions[historyIndex]
            markSelfHistory(self.selfHistoryVisited, historyPoint[1], historyPoint[2], historyIndex)
        end

        -- Real, confirmed-live gap the "close to point[1] specifically"
        -- check above can't catch on its own -- see isNearSelfHistory's
        -- own declaration comment for the two real confirmed cases
        -- (a dead-end doubling back, a roundabout island lapped more than
        -- once). Topologically this IS the same kind of event the check
        -- above already treats as a real closure -- the walk returned to
        -- somewhere on its own boundary, just not point[1] specifically --
        -- so closedNaturally is set true here too, same as above. The
        -- degenerate case (a thin dead-end sliver forced "closed" here) is
        -- still caught downstream by the existing span/seed-containment
        -- checks in WailaTrailScanner:update, same backstop that already
        -- has to catch it regardless of which check flagged closure.
        if numPositions > SELF_HISTORY_LAG then
            local current = self.boundaryPositions[numPositions]
            local matchedIndex = isNearSelfHistory(self.selfHistoryVisited, current[1], current[2])
            -- Gated on the SUB-LOOP's own turn, not the whole walk's
            -- total -- see MIN_TURN_ANGLE_FOR_CLOSURE's own comment.
            -- turnAngleHistory[matchedIndex] is a snapshot of
            -- cumulativeTurnAngle from back when that point was recorded
            -- -- now minus then is exactly how much turning happened
            -- OVER [matchedIndex .. numPositions], independent of
            -- whatever the walk did before ever reaching matchedIndex.
            local subLoopTurn = matchedIndex ~= nil
                and (self.cumulativeTurnAngle - self.turnAngleHistory[matchedIndex])
                or nil

            if matchedIndex ~= nil and math.abs(subLoopTurn) >= WailaTrailTracer.MIN_TURN_ANGLE_FOR_CLOSURE then
                -- Real bug this fixes, confirmed live: a closed shape
                -- missing roughly a quarter of its real area, cut off by
                -- one long straight chord. finalize() always closes back
                -- to boundaryPositions[1] -- correct for the
                -- "close-to-start" branch above, wrong here: the real
                -- closed loop is [matchedIndex .. numPositions], not
                -- [1 .. numPositions], and everything before matchedIndex
                -- is a real but IRRELEVANT lead-in the walk took before
                -- ever reaching its own true loop. Trimming here, before
                -- finalize() runs, means finalize()'s own "close back to
                -- position[1]" is now closing back to the actual matched
                -- point, not an unrelated one that happens to still be at
                -- index 1.
                local trimmed = {}
                for i = matchedIndex, numPositions do
                    table.insert(trimmed, self.boundaryPositions[i])
                end
                self.boundaryPositions = trimmed

                log("area trace came back near its own earlier path (index %d of %d, sub-loop turn=%.0f degrees, not the start point specifically) -- trimmed to the real closed loop (%d points), stopping",
                    matchedIndex, numPositions, math.deg(subLoopTurn), #trimmed)
                self.closedNaturally = true
                self.stopReason = "closed_at_self_history"
                self:finalize()
                return false
            end
        end

        if numPositions > WailaTrailTracer.AREA_TRACE_MAX_POSITIONS then
            log("area trace unable to close boundary loop, giving up at %d positions", numPositions)
            self.stopReason = "position_cap"
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

-- ============================================================
-- Path width - a stitched path chain is a centerline plus a real width,
-- not just a bare line
-- ============================================================
--
-- Meters. A stitched path chain (stitchPathTiles' own output) is only
-- ever a centerline -- real, confirmed live: nothing about it carries
-- width, and the old grid-blob claim (claimPathCells, a 3x3-TILE_SIZE
-- radius per point) was a crude stand-in for "how wide is this path"
-- rather than an actual measurement. This is a first tuned guess, same
-- as AREA_TRACE_STEP's own comment -- not yet derived from any real
-- per-tile width signal (the PCA minor-axis variance, lambda2, is
-- probably the real future source for this once there's live mileage to
-- tune against), flagged the same way as worth revisiting rather than
-- assumed correct up front.
--
-- Bumped from the original 5.0, real request: a real in-game road plus
-- its own gravel shoulder/side-strip is wider than a bare dirt trail, but
-- it's still one "long thing," not a reason to spawn a separate "area"
-- declaration for a strip nobody actually wants represented that way --
-- this single constant governs the classification width-check
-- (classifyTile), the ribbon render width (offsetChain), AND the area
-- walker's own exclusion buffer (distanceToPathsSq) all at once, so
-- widening it here makes a road+shoulder combo classify as path, render
-- as a wider ribbon, and keep the area walker further away from it, all
-- consistently.
WailaTrailTracer.PATH_WIDTH = 10.0

local function normalize2D(x, z)
    local length = MathUtil.vector2Length(x, z)
    if length < 0.0001 then
        return 0, 0
    end
    return x / length, z / length
end

-- Public: offsets a chain's own centerline points perpendicular to their
-- local direction by `offset` meters (signed -- positive/negative pick
-- which side). Per-vertex direction is the average of its two adjacent
-- segment directions, a bisector approximation rather than a true mitered
-- join -- good enough since chains stitched from tile centroids are
-- already coarse and fairly straight by construction
-- (STITCH_MIN_ALIGNMENT already rejects sharp direction changes when
-- chaining tiles together), not worth true miter-join complexity here.
-- Used both to render a path chain as a real two-edge ribbon (not just
-- its bare centerline) and, via distanceToPathsSq below, to give the area
-- wall-follower a real geometric "how close is too close to a path" test.
function WailaTrailTracer.offsetChain(chain, offset)
    local n = #chain
    if n < 2 then
        return chain
    end

    local result = {}
    for i = 1, n do
        local dirX, dirZ = 0, 0
        if i > 1 then
            local ax, az = normalize2D(chain[i][1] - chain[i - 1][1], chain[i][2] - chain[i - 1][2])
            dirX, dirZ = dirX + ax, dirZ + az
        end
        if i < n then
            local bx, bz = normalize2D(chain[i + 1][1] - chain[i][1], chain[i + 1][2] - chain[i][2])
            dirX, dirZ = dirX + bx, dirZ + bz
        end
        dirX, dirZ = normalize2D(dirX, dirZ)
        -- Perpendicular: rotate direction by 90 degrees.
        local normalX, normalZ = -dirZ, dirX
        table.insert(result, { chain[i][1] + normalX * offset, chain[i][2] + normalZ * offset })
    end
    return result
end

-- Real geometric "how close is (x, z) to any stitched path chain" check,
-- returned squared (callers compare against a squared half-width, same
-- "avoid the sqrt" reasoning pcaAnalyze's own lambda comparisons already
-- use). Real, confirmed-live improvement over the old grid-blob claim
-- check this replaces for the area wall-follower's own boundary test
-- (isOpenAt below): walking the actual chain segments means the SAME
-- generic "trace the boundary between open and closed" wall-following
-- logic already used for material transitions now naturally hugs a
-- road's real edge when it gets this close, and naturally resumes
-- ordinary material-based wall-following the moment it's clear of the
-- road -- no separate special-case "entering/leaving a road" code needed,
-- since it's still just the same boolean predicate the walker already
-- knows how to trace the edge of.
local function distanceToPathsSq(paths, x, z)
    local minDistSq = math.huge
    for _, chain in ipairs(paths) do
        for i = 1, #chain - 1 do
            local ax, az = chain[i][1], chain[i][2]
            local bx, bz = chain[i + 1][1], chain[i + 1][2]
            local segLenSq = (bx - ax) * (bx - ax) + (bz - az) * (bz - az)
            local dist

            if segLenSq > MIN_SEGMENT_LENGTH_SQ then
                dist = WailaUtil.safeCall(nil, MathUtil.getDistanceToLineSegment2D, ax, az, bx, bz, x, z)
            end
            if dist == nil then
                dist = MathUtil.vector2Length(x - ax, z - az)
            end

            local distSq = dist * dist
            if distSq < minDistSq then
                minDistSq = distSq
            end
        end
    end
    return minDistSq
end

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

-- Chaikin-style single-pass corner cutting: for a vertex whose BOTH
-- adjacent edges are short (<= maxSegmentLength), replace that vertex
-- with a segment between each edge's own midpoint instead of the sharp
-- corner point -- removes the artificial right angle while leaving the
-- overall direction intact. Deliberately gated on short edges only, not
-- applied everywhere: a long edge is real boundary shape, not a
-- quantization artifact, and smoothing it would distort the actual
-- traced outline instead of just cleaning up staircase noise. Endpoints
-- (first/last point) are never touched, same reasoning
-- simplifyBoundary's own "keep = {[1]=true,[n]=true}" already uses.
local function cutShortCorners(points, maxSegmentLength)
    local n = #points
    if n < 3 then
        return points
    end

    local result = { points[1] }
    for i = 2, n - 1 do
        local prev, cur, nxt = points[i - 1], points[i], points[i + 1]
        local lenA = MathUtil.vector2Length(cur[1] - prev[1], cur[2] - prev[2])
        local lenB = MathUtil.vector2Length(nxt[1] - cur[1], nxt[2] - cur[2])

        if lenA <= maxSegmentLength and lenB <= maxSegmentLength then
            table.insert(result, { (prev[1] + cur[1]) * 0.5, (prev[2] + cur[2]) * 0.5 })
            table.insert(result, { (cur[1] + nxt[1]) * 0.5, (cur[2] + nxt[2]) * 0.5 })
        else
            table.insert(result, cur)
        end
    end
    table.insert(result, points[n])

    return result
end

-- Public: simplified {x, z} point list, open ring (no closing duplicate) -
-- callers doing line-segment rendering want that, not a Polygon2D.
-- Corner-cutting runs AFTER Douglas-Peucker, not instead of it -- the two
-- solve different problems (DP drops redundant points along a long
-- baseline, corner-cutting smooths short residual staircase notches DP's
-- own tolerance wasn't aggressive enough to remove) and DP already did
-- the expensive point-count reduction, so corner-cutting only ever runs
-- against the already-small simplified list.
function WailaAreaTracer:getSimplifiedPoints()
    local openRing = self.boundaryPositions
    local first, last = openRing[1], openRing[#openRing]
    if #openRing > 1 and first[1] == last[1] and first[2] == last[2] then
        openRing = {}
        for i = 1, #self.boundaryPositions - 1 do
            table.insert(openRing, self.boundaryPositions[i])
        end
    end

    local simplified = simplifyBoundary(openRing, WailaTrailTracer.AREA_SIMPLIFY_TOLERANCE)
    return cutShortCorners(simplified, WailaTrailTracer.CORNER_CUT_MAX_SEGMENT_LENGTH)
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

-- ============================================================
-- Incremental scanner object - replaces the old one-shot scanRegion
-- ============================================================
--
-- Real lag spike found live: scanRegion used to be one big synchronous
-- call, still true even after SWEEP_DEADLINE_SEC bounded its worst case
-- to 10s -- that's still one frame blocking for up to 10 seconds, not
-- spread out. The file's own original header already flagged this as
-- the known, deferred shape ("Real whole-map coverage needs the same
-- frame-budget-spreading pattern WailaFieldGridScanner already uses,
-- many small ticks across many frames, not one big synchronous pass --
-- worth doing once the classification/stitching/tracing approach itself
-- is confirmed to produce sensible results, not before"). That condition
-- is satisfied now. WailaFieldGridScanner is the direct blueprint here:
-- a persistent object with its own real instance state (not a closure
-- over locals), driven by repeated small :update(timeBudgetSec) calls
-- from the caller instead of one blocking call.
--
-- Three phases, matching the real pipeline shape: TILES (classify one
-- tile at a time), then a quick one-shot STITCH transition (cheap
-- relative to area-tracing, not worth its own incremental phase), then
-- AREAS (continue an in-progress trace, or start the next unclaimed
-- candidate) -- same phase-machine style WailaFieldGridScanner:update
-- uses for its own "continue activeTracer, else advance the seed scan"
-- branch.
WailaTrailScanner = {}
local WailaTrailScanner_mt = Class(WailaTrailScanner)

local PHASE_TILES = 1
local PHASE_AREAS = 2
local PHASE_DONE = 3

function WailaTrailScanner.new(centerX, centerZ)
    local self = setmetatable({}, WailaTrailScanner_mt)

    local radius = WailaTrailTracer.SCAN_RADIUS
    self.centerX, self.centerZ = centerX, centerZ
    self.tileSize = WailaTrailTracer.TILE_SIZE
    self.minX, self.maxX = centerX - radius, centerX + radius
    self.minZ, self.maxZ = centerZ - radius, centerZ + radius
    self.cols = math.ceil((self.maxX - self.minX) / self.tileSize)
    self.rows = math.ceil((self.maxZ - self.minZ) / self.tileSize)

    self.tileIndex = 0
    self.pathAnalyses = {}
    self.areaAnalyses = {}
    self.tilesScanned, self.tilesNone, self.tilesPath, self.tilesArea = 0, 0, 0, 0
    self.tilesWithHits, self.maxHitsSeen = 0, 0

    self.claimed = {}
    self.paths = nil
    self.areas = {}
    self.rejectedIslands = {}
    self.rejectedIncomplete = {}
    self.areaIndex = 0
    self.areaCandidateCount = 0
    self.activeAreaTracer = nil
    self.areaSweepStartTime = nil

    self.phase = PHASE_TILES
    self.isComplete = false
    self.result = nil

    return self
end

function WailaTrailScanner:cellToWorld(col, row)
    return self.minX + col * self.tileSize, self.minZ + row * self.tileSize
end

function WailaTrailScanner:isCellClaimed(x, z)
    return isCellClaimed(self.claimed, x, z, self.minX, self.minZ, self.tileSize)
end

-- Runs once, on the TILES -> AREAS transition -- paths claim territory
-- before any area candidate is even considered (see the real bug this
-- ordering fixes, below) and stitching itself is cheap (O(n^2) over the
-- typically-small pathAnalyses list, not worth its own incremental
-- phase the way area-tracing needs).
--
-- Real, confirmed-live bug this ordering fixes (reported directly,
-- screenshots of a clearly path-shaped worn track traced as a sprawling
-- jagged "area" instead): tracing areas first and filtering paths
-- against that claimed grid afterward meant a single tile along an
-- obviously elongated track that happened to locally misclassify as
-- "area" (patchy material inside one 8x8m tile) could seed a
-- wall-follower that traces the ENTIRE track, and any correctly
-- classified path-tiles nearby then got thrown away for "already being
-- inside an area" -- exactly backwards. Paths now claim their own
-- territory FIRST; area candidates already inside a claimed path cell
-- are skipped before an area trace is even attempted on them.
function WailaTrailScanner:runStitchTransition()
    self.paths = WailaTrailTracer.stitchPathTiles(self.pathAnalyses)
    for _, chain in ipairs(self.paths) do
        claimPathCells(self.claimed, chain, self.minX, self.minZ, self.tileSize)
    end
    self.areaSweepStartTime = getTimeSec()
    self.phase = PHASE_AREAS
end

function WailaTrailScanner:finish()
    log("scanRegion result: %d path chain(s) from %d path-tile(s), %d accepted area(s) + %d island-rejected + %d incomplete-rejected area(s) from %d area-tile(s) (%d suppressed as inside a path's own claimed territory)",
        #self.paths, #self.pathAnalyses, #self.areas, #self.rejectedIslands, #self.rejectedIncomplete, #self.areaAnalyses, #self.areaAnalyses - self.areaCandidateCount)

    -- Real request: a path chain is a centerline plus a real width, not
    -- just a bare line -- callers (TaskMap's own map painting) need the
    -- actual two-edge ribbon to draw/paint that width, not just the
    -- centerline stitchPathTiles produces. Computed once here, not per
    -- render call -- cheap (a handful of chains, each already coarse from
    -- tile-stitching) and the shape is final once the scan itself is done.
    local pathEdges = {}
    local halfWidth = WailaTrailTracer.PATH_WIDTH * 0.5
    for _, chain in ipairs(self.paths) do
        table.insert(pathEdges, {
            left = WailaTrailTracer.offsetChain(chain, halfWidth),
            right = WailaTrailTracer.offsetChain(chain, -halfWidth),
        })
    end

    self.result = {
        paths = self.paths, pathEdges = pathEdges, areas = self.areas,
        rejectedIslands = self.rejectedIslands, rejectedIncomplete = self.rejectedIncomplete,
    }
    self.isComplete = true
    self.phase = PHASE_DONE
end

-- Advances up to timeBudgetSec of work. Returns true once this scan is
-- fully complete (self.result is then the final { paths, areas } table,
-- same shape the old scanRegion returned directly) -- false means keep
-- calling this on subsequent ticks. Same real shape as
-- WailaFieldGridScanner:update's own "budget in, boolean done-or-not
-- out" contract.
function WailaTrailScanner:update(timeBudgetSec)
    if self.isComplete then
        return true
    end

    local startTime = getTimeSec()
    while getTimeSec() - startTime < timeBudgetSec do
        if self.phase == PHASE_TILES then
            if self.tileIndex >= self.cols * self.rows then
                log("scanRegion center=(%.1f,%.1f) radius=%.0f tileSize=%.0f -> tilesScanned=%d tilesWithHits=%d maxHitsInOneTile=%d (of %d samples/tile) classified: none=%d path=%d area=%d",
                    self.centerX, self.centerZ, WailaTrailTracer.SCAN_RADIUS, self.tileSize, self.tilesScanned, self.tilesWithHits, self.maxHitsSeen,
                    (math.floor(self.tileSize / WailaTrailTracer.SAMPLE_STEP) + 1) ^ 2, self.tilesNone, self.tilesPath, self.tilesArea)
                self:runStitchTransition()
            else
                local col = self.tileIndex % self.cols
                local row = math.floor(self.tileIndex / self.cols)
                self.tileIndex = self.tileIndex + 1

                local x, z = self:cellToWorld(col, row)
                local kind, analysis, rawHitCount = WailaTrailTracer.classifyTile(x, z)
                self.tilesScanned = self.tilesScanned + 1
                if rawHitCount ~= nil and rawHitCount > 0 then
                    self.tilesWithHits = self.tilesWithHits + 1
                    self.maxHitsSeen = math.max(self.maxHitsSeen, rawHitCount)
                end
                if kind == "path" then
                    self.tilesPath = self.tilesPath + 1
                    table.insert(self.pathAnalyses, analysis)
                elseif kind == "area" then
                    self.tilesArea = self.tilesArea + 1
                    table.insert(self.areaAnalyses, analysis)
                else
                    self.tilesNone = self.tilesNone + 1
                end
            end
        elseif self.phase == PHASE_AREAS then
            if self.activeAreaTracer ~= nil then
                local remaining = timeBudgetSec - (getTimeSec() - startTime)
                local stillTracing = self.activeAreaTracer:update(math.max(remaining, 0))

                if not stillTracing then
                    local tracer = self.activeAreaTracer
                    local points = tracer:getSimplifiedPoints()

                    if #points >= 3 then
                        -- Territory-claiming (the dedup that stops future
                        -- candidates re-tracing the same shape, and the
                        -- signal that this is a genuine accepted area, not
                        -- debug noise) still requires the full trustworthy
                        -- bar: naturally closed, a sane span, AND contains
                        -- its own seed (see that check's own comment for
                        -- the island-hijack bug it catches). An open/capped
                        -- trace's own bounding box would otherwise be able
                        -- to wrongly claim -- and so suppress -- unrelated
                        -- future candidates far from where it actually
                        -- wandered.
                        local isTrustworthy = false
                        -- Real request: an "island" rejection (closed
                        -- fine, just around the WRONG region -- see the
                        -- log line below) is a categorically different
                        -- finding than "never really closed at all"
                        -- (structure hit / stall / position cap / too
                        -- big a span) -- one topologically succeeded and
                        -- got the wrong answer, the others just didn't
                        -- finish. Both used to render identically gray,
                        -- making "what actually happened here" a guessing
                        -- game from a screenshot alone.
                        local isIslandRejection = false

                        -- Real request: a needle-sharp corner (< 30
                        -- degrees) isn't something any real in-game
                        -- feature can produce (brush minimum radius,
                        -- rectangle-brush right angles, a tractor/
                        -- TerraFarm implement that physically can't turn
                        -- on a dime) -- same "is this even legitimate"
                        -- sanity check MAX_AREA_SPAN already is, just for
                        -- corner sharpness instead of overall size.
                        local sharpAngle = WailaTrailTracer.hasSharpAngle(points, WailaTrailTracer.MIN_INTERIOR_ANGLE_DEGREES)

                        if tracer.closedNaturally and getPointsBoundingSpan(points) <= WailaTrailTracer.MAX_AREA_SPAN and not sharpAngle then
                            local flatVertices = {}
                            for _, p in ipairs(points) do
                                table.insert(flatVertices, p[1])
                                table.insert(flatVertices, p[2])
                            end
                            local polygon = Polygon2D.new(nil, flatVertices)

                            if WailaUtil.getIsPosInsidePolygon(polygon, tracer.seedX, tracer.seedZ) then
                                isTrustworthy = true
                                claimPolygonCells(self.claimed, points, self.minX, self.minZ, self.tileSize)
                            else
                                isIslandRejection = true
                                log("area trace closed (%d points) but doesn't contain its own seed (%.1f,%.1f) -- traced a nearby island/obstacle instead of the seeded region, not claimed (still drawn for debugging)",
                                    #points, tracer.seedX, tracer.seedZ)
                            end
                        elseif tracer.closedNaturally and sharpAngle then
                            log("area trace closed (%d points) but has a corner sharper than %.0f degrees -- not something a real brush/vehicle could draw, not claimed (still drawn for debugging)",
                                #points, WailaTrailTracer.MIN_INTERIOR_ANGLE_DEGREES)
                        end

                        -- Debug visibility, real request: an open/capped
                        -- trace (hit AREA_TRACE_MAX_POSITIONS, a structure,
                        -- or a stall) used to be silently discarded, drawing
                        -- nothing -- impossible to tell "genuinely huge
                        -- boundary, needs a bigger cap" apart from "wall-
                        -- follower stuck oscillating" from a screenshot.
                        -- Still draw every finished trace regardless of
                        -- isTrustworthy -- half a visible line beats no
                        -- line for that question -- but into ONE OF THREE
                        -- SEPARATE LISTS now (accepted / island-rejected /
                        -- incomplete-rejected), not lumped together: real,
                        -- confirmed-live problem with drawing them all the
                        -- same way -- when the true boundary keeps failing
                        -- to close/qualify, EVERY candidate tile nearby
                        -- independently re-attempts and re-fails it, and
                        -- with no visual distinction between "closed
                        -- around the wrong thing" and "never closed at
                        -- all," that pile of near-misses just reads as an
                        -- unreadable tangled mess. Does NOT affect claimed
                        -- territory above, only which list (and so which
                        -- render color, see TaskMap's own use of
                        -- result.rejectedIslands/rejectedIncomplete) a
                        -- finished trace ends up in.
                        if isTrustworthy then
                            table.insert(self.areas, points)
                        elseif isIslandRejection then
                            table.insert(self.rejectedIslands, points)
                        else
                            table.insert(self.rejectedIncomplete, points)
                        end
                    end

                    self.activeAreaTracer = nil
                end
            elseif getTimeSec() - self.areaSweepStartTime > WailaTrailTracer.SWEEP_DEADLINE_SEC then
                log("scanRegion area-tracing phase hit its %.0fs sweep deadline with %d/%d area clusters left unprocessed, stopping early",
                    WailaTrailTracer.SWEEP_DEADLINE_SEC, #self.areaAnalyses - self.areaCandidateCount, #self.areaAnalyses)
                self:finish()
            elseif self.areaIndex >= #self.areaAnalyses then
                self:finish()
            else
                self.areaIndex = self.areaIndex + 1
                local analysis = self.areaAnalyses[self.areaIndex]
                if not self:isCellClaimed(analysis.centroidX, analysis.centroidZ) then
                    self.areaCandidateCount = self.areaCandidateCount + 1
                    -- WailaAreaTracer.new returns nil if (x,z) isn't
                    -- actually trail material -- loop just continues to
                    -- the next candidate next iteration in that case,
                    -- same as leaving activeAreaTracer nil does above.
                    -- Two real checks passed through so the walk itself,
                    -- not just this seed check, treats both a path's real
                    -- width AND the scanned window's own edge as a
                    -- boundary -- see WailaAreaTracer:isOpenAt's own
                    -- comment for the two separate bugs this fixes (a
                    -- trace escaping down a path corridor, and a trace
                    -- escaping past SCAN_RADIUS into never-scanned
                    -- ground entirely).
                    local halfPathWidthSq = (WailaTrailTracer.PATH_WIDTH * 0.5) ^ 2
                    self.activeAreaTracer = WailaAreaTracer.new(analysis.centroidX, analysis.centroidZ, function(x, z)
                        if x < self.minX or x > self.maxX or z < self.minZ or z > self.maxZ then
                            return true
                        end
                        return distanceToPathsSq(self.paths, x, z) <= halfPathWidthSq
                    end)
                end
            end
        else
            return true
        end
    end

    return false
end

-- Public factory, called cross-mod as
-- g_currentMission.wailaTrailTracer.newScanner(...) -- WailaTrailScanner
-- itself is a bare global (only visible inside this mod's own sandbox,
-- same rule g_currentMission.wailaTrailTracer itself exists to work
-- around), so this reuses the ALREADY-published cross-mod entry point
-- instead of publishing a second g_currentMission.* global for the same
-- purpose.
function WailaTrailTracer.newScanner(centerX, centerZ)
    return WailaTrailScanner.new(centerX, centerZ)
end

-- ============================================================
-- Single-point debug trace - deterministic, reproducible, isolated
-- ============================================================
--
-- Real request: scanRegion/WailaTrailScanner can fire dozens of
-- independent seeds across a whole window at once (confirmed live,
-- burst logs of 20+ traces in under a second) with no way to tell which
-- rendered line came from which seed -- genuinely hard to build any
-- "does the algorithm do what I expect FROM THIS SPECIFIC POINT" debug
-- loop out of that. This runs the SAME real classifyTile/WailaAreaTracer
-- code, but exactly once, seeded at exactly (x, z), with no other seeds
-- and no path exclusion -- isolating the algorithm's own raw behavior
-- from one controlled, reproducible starting point instead of a whole
-- area's worth of simultaneous, uncorrelated activity.
-- Deliberately NOT wired through WailaTrailScanner at all -- that class
-- exists to solve the incremental/whole-window problem, this solves the
-- opposite problem (a single point, run to completion synchronously,
-- same "unbudgeted by design, bounded to one trace not a whole sweep"
-- tradeoff WailaFieldGridScanner:scanBlobAt already makes for its own
-- single-field debug case).
--
-- Real, confirmed live risk this bounds: an unbounded trace could
-- wander over a genuinely huge or open-ended shape before ever
-- reporting anything -- the "infinity problem" a bare step/cell cap
-- doesn't really solve, just delays.
--
-- Real request: a FIXED tile grid, not a square re-centered on whatever
-- point happens to trigger tracing -- "the tile I'm on" is then a real,
-- stable, addressable thing (a future per-tile update button, or a real
-- "vehicle drove over new ground" event, can both target it directly),
-- and it's the same real building block the eventual whole-map
-- production system would use, just centered on wherever a debug call
-- happens to land for now instead of snapped to a persistent map-wide
-- pitch. Same origin convention WailaFieldGridScanner:reset() already
-- uses (-terrainSize*0.5) -- not a new, one-off convention, so this
-- tool's own tile boundaries would already line up with a real
-- production tiling system built the same way later.
-- Halved back down from 512 to 256, real request ("let's make sure we
-- can actually fill the test area completely"): at 512 (262,144 cells),
-- real material coverage routinely blew past DEBUG_MAX_CELL_BOXES
-- (3000), truncating the debug view before it ever showed the true full
-- coverage -- confirmed live. Shrinking the scanned area (not raising
-- the box cap) keeps the fix on the side that doesn't risk the
-- already-confirmed "too many debug objects lag things out" problem.
-- 256 is still a real, addressable tile on the same 8x8-style whole-map
-- grid (4096/16 = 256, a 16x16 grid would cover CreativeHorizonIW),
-- just a finer pitch.
WailaTrailTracer.DEBUG_TILE_SIZE = 256.0

-- Public: which fixed tile (world-space bounds) contains (x, z). Real,
-- deliberate side benefit noted live: if these tiles get painted with a
-- solid fill color later, a shape spanning multiple tiles reads as one
-- continuous area/path to the human eye even though it's actually
-- several independent per-tile polygons sharing exact borders -- the
-- hard "stitch a cross-tile shape into one seamless polygon" problem
-- never needs solving at all for that deliverable.
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
-- Grid-based region extraction - real alternative to the wall-follower
-- ============================================================
--
-- Real request, after a whole session of patching the wall-follower's
-- own recurring failure family (island hijacking, corridor escapes,
-- junction ambiguity, self-crossing knots): every one of those bugs
-- comes from the SAME root cause -- the wall-follower decides the shape
-- one greedy LOCAL step at a time, with no view of the whole region, so
-- it can only react to trouble after it's already walked into it. This
-- is the real fix, not another patch: rasterize the region into a
-- filled/empty grid FIRST (cheap -- a 120x120m area at 1m resolution is
-- only 14,400 cells), then extract the boundary from the COMPLETED grid
-- via Moore-neighbor tracing, a real, standard raster-boundary-tracing
-- algorithm, not something novel. Holes, junctions, and branching
-- corridors are just facts about the finished grid at that point -- an
-- interior island simply never becomes a boundary cell for the outer
-- trace, no special-case needed, unlike the wall-follower's own
-- island-hijack failure mode this whole approach exists to avoid.
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

-- Clockwise from north, matching standard Moore-neighbor tracing
-- convention. Index 1=N, 2=NE, 3=E, 4=SE, 5=S, 6=SW, 7=W, 8=NW.
local MOORE_DIRECTIONS = {
    { 0, -1 }, { 1, -1 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 }
}

local function oppositeMooreDirection(dirIndex)
    return ((dirIndex + 4 - 1) % 8) + 1
end

-- Rasterizes a (2*radius)x(2*radius) square centered on (centerX,
-- centerZ). grid[row][col] is true if that cell's own center is real
-- trail material. Real, direct cost: (2*radius/cellSize)^2 raw
-- isTrailMaterialAt calls, all synchronous -- same unbudgeted-by-design
-- tradeoff every other single-shot debug helper in this file already
-- makes (WailaFieldGridScanner:scanBlobAt, debugTraceAt's own area
-- trace).
-- isBlockedFn is optional (x, z) -> bool, same convention
-- WailaAreaTracer's own isBlockedFn already uses -- true means "treat
-- this cell as unfilled," on top of the raw material check. Needed for
-- the exact same reason the wall-follower needed it: a path is
-- materially CONTIGUOUS with an area it connects to (same dirt/gravel,
-- no real gap), so raw material connectivity alone would rasterize
-- blob+corridor as one region here too -- flood/Moore-tracing doesn't
-- know about "path vs area" classification any more than the
-- wall-follower did, only real material.
--
-- Takes explicit (minX, minZ, maxX, maxZ) bounds, not a center+radius
-- -- real request: a FIXED tile grid needs to rasterize exactly one
-- tile's own bounds, which generally sit somewhere other than centered
-- on whatever seed point triggered tracing it.
local function rasterizeRegion(minX, minZ, maxX, maxZ, cellSize, isBlockedFn)
    local size = math.ceil((maxX - minX) / cellSize)
    local grid = {}
    for row = 0, size - 1 do
        local gridRow = {}
        for col = 0, size - 1 do
            local worldX = minX + (col + 0.5) * cellSize
            local worldZ = minZ + (row + 0.5) * cellSize
            gridRow[col] = isTrailMaterialAt(worldX, worldZ) and not (isBlockedFn ~= nil and isBlockedFn(worldX, worldZ))
        end
        grid[row] = gridRow
    end
    return grid, minX, minZ, size
end

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

-- Real Moore-neighbor boundary tracing. Walks the 8-neighborhood
-- clockwise starting just past the direction it arrived from
-- (backtrackDir), taking the first filled neighbor found as the next
-- boundary cell -- a real "hug the wall" walk over the ALREADY-COMPLETE
-- grid, not a greedy decision made without seeing the rest of the
-- shape. Any boundary cell with a confirmed-empty neighbor in the
-- backtrack direction is a valid, correct starting point for a
-- simply-connected region, regardless of whether it's the shape's own
-- topmost/leftmost point -- the walk still traces the full outer
-- contour either way, same topological guarantee the wall-follower's
-- own turn-angle invariant already relies on (a consistently-turning
-- walk around a simple closed curve returns to its start after one real
-- lap, independent of where it started).
local MOORE_MAX_STEPS = 20000

local function traceOuterBoundary(grid, size, startCol, startRow)
    local boundary = { { startCol, startRow } }
    local backtrackDir = 7 -- W, guaranteed empty by the caller's own west-walk
    local curCol, curRow = startCol, startRow
    local hitGridEdge = false

    for _ = 1, MOORE_MAX_STEPS do
        local foundDir = nil
        for i = 1, 8 do
            local dirIndex = ((backtrackDir + i - 1) % 8) + 1
            local dCol, dRow = MOORE_DIRECTIONS[dirIndex][1], MOORE_DIRECTIONS[dirIndex][2]
            local nCol, nRow = curCol + dCol, curRow + dRow
            if nCol < 0 or nCol >= size or nRow < 0 or nRow >= size then
                hitGridEdge = true
            elseif isFilledCell(grid, size, nCol, nRow) then
                foundDir = dirIndex
                break
            end
        end

        if foundDir == nil then
            break
        end

        curCol = curCol + MOORE_DIRECTIONS[foundDir][1]
        curRow = curRow + MOORE_DIRECTIONS[foundDir][2]
        backtrackDir = oppositeMooreDirection(foundDir)

        if curCol == startCol and curRow == startRow then
            break
        end

        table.insert(boundary, { curCol, curRow })
    end

    return boundary, hitGridEdge
end

-- Public: real grid-based alternative to WailaAreaTracer's own wall-
-- follower. Rasterizes the explicit (minX, minZ, maxX, maxZ) region,
-- walks west from (seedX, seedZ)'s own cell until leaving trail material
-- (a real, always-valid Moore-tracing starting point -- its own west
-- neighbor is now confirmed empty), then traces the outer boundary
-- directly from the completed grid. Returns {points, hitGridEdge}, or
-- nil if (seedX, seedZ) isn't itself trail material, or falls outside
-- the given bounds. points is an open ring, same convention
-- getSimplifiedPoints/claimPolygonCells already use, already run
-- through the SAME Douglas-Peucker + corner-cutting simplification the
-- wall-follower's own output gets -- one consistent output shape
-- regardless of which tracing method produced it.
--
-- seedX/seedZ are separate from the bounds on purpose -- real request:
-- a fixed tile grid's own bounds generally aren't centered on whatever
-- point triggered tracing it (a player standing anywhere within a
-- tile, not necessarily its center).
function WailaTrailTracer.traceRegionGrid(seedX, seedZ, minX, minZ, maxX, maxZ, cellSize, isBlockedFn)
    cellSize = cellSize or WailaTrailTracer.GRID_CELL_SIZE
    local grid, originX, originZ, size = rasterizeRegion(minX, minZ, maxX, maxZ, cellSize, isBlockedFn)

    local startCol = math.floor((seedX - originX) / cellSize)
    local startRow = math.floor((seedZ - originZ) / cellSize)

    if not isFilledCell(grid, size, startCol, startRow) then
        return nil
    end

    while isFilledCell(grid, size, startCol - 1, startRow) do
        startCol = startCol - 1
    end

    local boundaryCells, hitGridEdge = traceOuterBoundary(grid, size, startCol, startRow)

    local rawPoints = {}
    for _, cell in ipairs(boundaryCells) do
        table.insert(rawPoints, {
            originX + (cell[1] + 0.5) * cellSize,
            originZ + (cell[2] + 0.5) * cellSize,
        })
    end

    local simplified = simplifyBoundary(rawPoints, WailaTrailTracer.AREA_SIMPLIFY_TOLERANCE)
    local points = cutShortCorners(simplified, WailaTrailTracer.CORNER_CUT_MAX_SEGMENT_LENGTH)

    return { points = points, hitGridEdge = hitGridEdge }
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

-- Real erosion: a cell is core only if EVERY cell in the
-- (2*radiusCells+1)^2 square centered on it is also filled. Breaks out
-- on the first unfilled neighbor found, so a cell near any real edge
-- (the common case for corridor cells) fails fast rather than scanning
-- its whole window.
local function erodeGrid(grid, size, radiusCells)
    local core = {}
    for row = 0, size - 1 do
        local coreRow = {}
        for col = 0, size - 1 do
            local isCore = false
            if isFilledCell(grid, size, col, row) then
                isCore = true
                for dRow = -radiusCells, radiusCells do
                    for dCol = -radiusCells, radiusCells do
                        if not isFilledCell(grid, size, col + dCol, row + dRow) then
                            isCore = false
                            break
                        end
                    end
                    if not isCore then
                        break
                    end
                end
            end
            coreRow[col] = isCore
        end
        core[row] = coreRow
    end
    return core
end

-- Real request: IW's own wear system deliberately fragments a trail
-- into many small, physically disconnected patches along its length
-- (wear intensity varies constantly, not a uniform strip -- this
-- file's own original header already said so). Treating "directly
-- touching" as the only kind of connectivity means this whole file's
-- basic premise (one worn trail = one shape) never holds for a real
-- IW-painted trail at all -- confirmed live, a whole row of separate
-- wear blotches only ever traced the couple that happened to touch.
-- Meters -- how big a real grass gap between separate wear patches
-- should still count as "the same path." A first tuned guess, same
-- footing as this file's other untuned constants, flagged the same way
-- as worth revisiting against real IW trails rather than assumed
-- correct up front.
WailaTrailTracer.GAP_TOLERANCE = 2.0

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

-- Real dilation: a cell counts as filled if ANY cell within radiusCells
-- (the same square-window shape erodeGrid already uses) is filled in
-- the ORIGINAL grid -- the inverse operation.
local function dilateGrid(grid, size, radiusCells)
    local dilated = {}
    for row = 0, size - 1 do
        local dilatedRow = {}
        for col = 0, size - 1 do
            local isFilled = false
            for dRow = -radiusCells, radiusCells do
                for dCol = -radiusCells, radiusCells do
                    if isFilledCell(grid, size, col + dCol, row + dRow) then
                        isFilled = true
                        break
                    end
                end
                if isFilled then
                    break
                end
            end
            dilatedRow[col] = isFilled
        end
        dilated[row] = dilatedRow
    end
    return dilated
end

-- Real morphological closing: dilate then erode by the SAME radius --
-- the standard technique for exactly this "bridge small gaps without
-- materially inflating the shape's own real size" problem. Bare
-- dilation alone would puff every shape's boundary outward by
-- GAP_TOLERANCE everywhere, not just at the gaps; closing bridges gaps
-- smaller than 2x the radius while restoring the true edges almost
-- everywhere else.
local function closeGrid(grid, size, radiusCells)
    return erodeGrid(dilateGrid(grid, size, radiusCells), size, radiusCells)
end

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

-- Public: "test 1" -- the dumbest possible whole-tile scan. Rasterize,
-- and hand back exactly what was sampled as one flat border-segment
-- list. Real, explicit scope cut, not a refactor for its own sake: no
-- region grouping (see collectBorderSegments's own header), and -- for
-- this specific test -- no GAP_TOLERANCE closing and no erosion either,
-- even though both still exist below for whenever they're wanted again. Real
-- request: confirm raw sampled positions actually land in the right
-- spot in the world FIRST, before any post-processing (bridging gaps,
-- splitting corridors, merging cells) has a chance to muddy whether a
-- visual mismatch is a real coordinate bug or just a side effect of one
-- of those later steps -- exactly the ambiguity that made the "offset?"
-- and "74,640-cell region" screenshots hard to diagnose.
function WailaTrailTracer.scanTileCells(minX, minZ, maxX, maxZ, cellSize)
    cellSize = cellSize or WailaTrailTracer.GRID_CELL_SIZE
    local grid, originX, originZ, size = rasterizeRegion(minX, minZ, maxX, maxZ, cellSize)
    local result = collectBorderSegments(grid, originX, originZ, size, cellSize)
    -- "Step 2," real request: chain the border segments above into
    -- closed loops, then smooth each one (see chainBorderLoops and
    -- smoothClosedLoop's own headers). result.polygons is the real
    -- deliverable -- an actually-closed polygon per connected region,
    -- with no tracing/simplify-tolerance fragility in it.
    result.polygons = {}
    for _, loop in ipairs(WailaTrailTracer.chainBorderLoops(result.segments)) do
        table.insert(result.polygons, WailaTrailTracer.smoothClosedLoop(loop))
    end
    return result
end

-- Public: single-point debug trace -- "test 1," a dumb whole-tile scan
-- only (see scanTileCells's own header for the explicit scope cut: no
-- closing, no erosion, no region grouping, for now). No classifyTile, no
-- PCA, no seed-material gate, no path/area decision of any kind -- (x, z)
-- only picks WHICH TILE to scan (getTileBounds). Not gated on (x, z)
-- itself having material at all -- standing anywhere in a tile shows you
-- everything that tile contains.
--
-- Known, deliberate gap in this first version: isSpotClearOfStructures
-- (the wall-follower's own real/road exclusion) is NOT checked here --
-- raycasting every rasterized cell would be a real performance
-- regression (that's exactly why it was never baked into
-- isTrailMaterialAt itself either). A building sitting on ground still
-- painted dirt/gravel underneath will currently get rasterized as if it
-- were open trail material, and a real road's own terrain paint reading
-- as trail material (confirmed live -- not every road is protected by
-- its paint being a different material) will get scanned too.
-- Real, explicit switch, not a refactor for its own sake: this used to
-- write one setParallelogramWorldCoords + executeSet PER FILLED CELL
-- (thousands of native calls). Real find, confirmed live against
-- FieldManager.lua's own field-farmland-ownership check (clearPolygonPoints
-- + a loop of addPolygonPointWorldCoords + one execute call): a
-- DensityMapModifier can fill an arbitrary POLYGON directly, not just an
-- oriented rectangle. Our already-computed smoothed polygons (chainBorderLoops
-- + smoothClosedLoop) are exactly the right input -- one execute call PER
-- REGION now, not per cell. Takes pre-computed polygons rather than
-- re-scanning the tile itself -- debugTraceAt already scans once via
-- scanTileCells, and this ran a full second (then third) redundant
-- rasterize pass when it re-scanned independently. Real, explicit fix:
-- used to size this scratch map to the tile's own cell count -- see
-- OVERLAY_RESOLUTION's own comment for why that's wrong (a
-- density-map-visualization overlay always spans the WHOLE terrain,
-- not just the tile).
function WailaTrailTracer.testDensityMapWrite(polygons)
    local size = WailaTrailTracer.OVERLAY_RESOLUTION
    local map = createBitVectorMap("wailaTrailTestMap")
    loadBitVectorMapNew(map, size, size, 1, false)
    local modifier = DensityMapModifier.new(map, 0, 1, g_terrainNode)

    local startTime = getTimeSec()
    for _, polygon in ipairs(polygons) do
        modifier:clearPolygonPoints()
        for _, point in ipairs(polygon) do
            modifier:addPolygonPointWorldCoords(point[1], point[2])
        end
        modifier:executeSet(1)
    end
    local elapsedMs = (getTimeSec() - startTime) * 1000

    delete(map)

    log("testDensityMapWrite: %d polygon(s) written in %.2fms", #polygons, elapsedMs)

    return #polygons, elapsedMs
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
-- constant's own comment).
function WailaTrailTracer.buildTestOverlay(polygons)
    local size = WailaTrailTracer.OVERLAY_RESOLUTION
    if WailaTrailTracer.testOverlayMap == nil then
        WailaTrailTracer.testOverlayMap = createBitVectorMap("wailaTrailOverlayTestMap")
        loadBitVectorMapNew(WailaTrailTracer.testOverlayMap, size, size, 1, false)
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
    local modifier = DensityMapModifier.new(map, 0, 1, g_terrainNode)

    for _, polygon in ipairs(polygons) do
        modifier:clearPolygonPoints()
        for _, point in ipairs(polygon) do
            modifier:addPolygonPointWorldCoords(point[1], point[2])
        end
        modifier:executeSet(1)
    end

    -- (overlay, mapId, filterMapId, filterMask, firstChannel,
    -- numChannels, value, r, g, b) -- confirmed live against
    -- MapOverlayGenerator:buildFieldMapOverlay's own call shape. No
    -- filter map needed (filterMapId=0, filterMask=0), same "no filter"
    -- pattern that function uses too.
    resetDensityMapVisualizationOverlay(WailaTrailTracer.testOverlay)
    -- Real request: "turn this gray" -- cyan was just a loud, easy-to-spot
    -- test color, not a final choice.
    setDensityMapVisualizationOverlayStateColor(WailaTrailTracer.testOverlay, map, 0, 0, 0, 1, 1, 0.5, 0.5, 0.5)
    generateDensityMapVisualizationOverlay(WailaTrailTracer.testOverlay)
end

function WailaTrailTracer.debugTraceAt(x, z)
    -- Real request: a FIXED tile, not a square re-centered on wherever
    -- (x, z) happens to be -- see DEBUG_TILE_SIZE's own comment (a
    -- stable, addressable tile, the same real building block a
    -- production whole-map system would use). result.debugBounds is the
    -- tile's own real bounds, drawn honestly as the rectangle it is.
    local minX, minZ, maxX, maxZ = WailaTrailTracer.getTileBounds(x, z)
    local result = {
        x = x, z = z,
        debugBounds = { { minX, minZ }, { maxX, minZ }, { maxX, maxZ }, { minX, maxZ }, { minX, minZ } },
    }

    local scan = WailaTrailTracer.scanTileCells(minX, minZ, maxX, maxZ)
    result.segments = scan.segments
    result.cellCount = scan.cellCount
    result.touchesTileEdge = scan.touchesTileEdge
    result.truncated = scan.truncated
    result.polygons = scan.polygons

    -- Real fix: testDensityMapWrite/buildTestOverlay used to each
    -- independently re-rasterize the same tile from scratch (a second,
    -- then third, full scan per debug press) -- they take the polygons
    -- already computed above now, not the raw world bounds to re-scan
    -- themselves. Resolution is WailaTrailTracer.OVERLAY_RESOLUTION now,
    -- a fixed terrain-wide constant, not derived from the tile at all.

    -- Real request ("let's just test it"): run the density-map write
    -- benchmark on the same tile every debug press, log-only for now --
    -- nothing rendered from this yet, this is purely "is it fast enough
    -- to be worth building on."
    result.densityWritePolygonCount, result.densityWriteMs = WailaTrailTracer.testDensityMapWrite(scan.polygons)

    -- "Test 2": also bake the same tile into the persistent overlay
    -- texture -- TaskMap renders WailaTrailTracer.testOverlay directly
    -- once it's ready, not through this result table.
    WailaTrailTracer.buildTestOverlay(scan.polygons)

    return result
end

-- Real, explicit removal, not a refactor for its own sake: this used to
-- run all 256 tiles synchronously in ONE call -- confirmed live, "either
-- too slow or game got killed." Real, hard-learned project rule this
-- broke (see feedback_waila_performance_is_non_negotiable in this
-- session's own memory): every scan needs a real PER-TICK budget, not a
-- single blocking call, no matter how clearly the risk is flagged in a
-- comment. Real fix: a genuine incremental state machine now -- meant
-- to be driven from TaskMap's own update(dt), the same "bounded work per
-- frame" shape the production wall-follower's own scanRegion loop
-- already uses elsewhere in this codebase. Start with
-- startWholeMapScan(), then call tickWholeMapScan() once per frame
-- until it returns true (done).
--
-- Real follow-up request ("how do we keep this from blocking the game?
-- smaller tiles maybe?"): yes -- one full DEBUG_TILE_SIZE (256m,
-- 65,536-cell) tile per tick was still a real, noticeable per-frame
-- hitch for the whole scan's duration, confirmed live ("very slow").
-- Total work across the whole map is fixed either way (same total area,
-- same cell count) -- chunking finer doesn't reduce that, it just
-- spreads the SAME total work across more, individually-cheaper ticks,
-- trading total wall-clock time for per-frame smoothness. Deliberately
-- a SEPARATE constant from DEBUG_TILE_SIZE, not a change to it --
-- DEBUG_TILE_SIZE is still the real, addressable tile size the
-- single-press debug tool and any future production system would use;
-- this is purely the whole-map scan's own tick granularity.
-- 64m = 4,096 cells/chunk, 16x cheaper per tick than the old 256m/tile
-- (65,536 cells) -- a first, moderate guess balancing "no longer a
-- visible per-frame hitch" against "doesn't take forever to finish"
-- (4,096 total chunks for this 4096m map, vs 256 tiles before), same
-- "worth revisiting once seen live" footing as this file's other first
-- guesses.
WailaTrailTracer.WHOLE_MAP_SCAN_CHUNK_SIZE = 64.0
function WailaTrailTracer.startWholeMapScan()
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
        totalCells = 0,
        totalPolygons = 0,
        startTime = getTimeSec(),
    }

    log("startWholeMapScan: %d chunk(s) (%dx%d, %.0fm each) queued, one per tick", chunksPerSide * chunksPerSide, chunksPerSide, chunksPerSide, chunkSize)
end

-- Public: call once per frame while a scan is in progress. Returns true
-- once the whole grid is done (or if no scan is running at all, so a
-- caller can unconditionally call this every tick without checking
-- first). Bounded at ONE CHUNK (WHOLE_MAP_SCAN_CHUNK_SIZE, not
-- DEBUG_TILE_SIZE) per call -- see that constant's own header for why
-- a full 256m tile per tick was still a real, visible hitch.
function WailaTrailTracer.tickWholeMapScan()
    local state = WailaTrailTracer.wholeMapScanState
    if state == nil then
        return true
    end

    local minX, minZ = state.originX + state.col * state.chunkSize, state.originZ + state.row * state.chunkSize
    local scan = WailaTrailTracer.scanTileCells(minX, minZ, minX + state.chunkSize, minZ + state.chunkSize)
    WailaTrailTracer.buildTestOverlay(scan.polygons)
    state.totalCells = state.totalCells + scan.cellCount
    state.totalPolygons = state.totalPolygons + #scan.polygons

    state.col = state.col + 1
    if state.col >= state.chunksPerSide then
        state.col = 0
        state.row = state.row + 1
    end

    if state.row >= state.chunksPerSide then
        local elapsedMs = (getTimeSec() - state.startTime) * 1000
        log("tickWholeMapScan done: %d chunk(s), %d cell(s), %d polygon(s), %.0fms total (%.1fs)",
            state.chunksPerSide * state.chunksPerSide, state.totalCells, state.totalPolygons, elapsedMs, elapsedMs / 1000)
        WailaTrailTracer.wholeMapScanState = nil
        return true
    end

    return false
end
