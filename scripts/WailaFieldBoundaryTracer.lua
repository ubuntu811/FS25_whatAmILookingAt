--[[
    WailaFieldBoundaryTracer.lua

    Ports the base game's own BoundaryDetectionTask (confirmed via
    decompiling dataS.gar, scripts/field/course/BoundaryDetectionTask.l64 --
    the same class FieldCourseManager uses to get the smooth, non-jittery
    field outlines AI course generation draws) instead of approximating a
    field's shape from our own coarse WailaFieldGridScanner grid. Real
    boundary contour tracing, not flood-fill: starting from a point already
    known to be on-field, walks the density-map edge one
    terrainDetailResolution step at a time (checking front/left/right
    density to decide which way to turn) until it loops back to its own
    start point -- O(perimeter), not O(area), and precise at the density
    map's native resolution rather than our own CELL_SIZE=24 grid.

    Island/hole support (BoundaryDetectionTaskInsideOut + the multi-stage
    candidate search FieldCourseField.lua uses to even find where a hole
    might be) is deliberately NOT ported -- confirmed real and working in
    the base game, but a substantially separate piece (native batch-density
    modifier pre-filtering + per-cell transition scanning), not needed for
    WAILA's purposes yet. A field with a pond/obstacle in the middle will
    currently be treated as solid.

    Budgeted like WailaFieldGridScanner's own update(cellBudget) -- tracing
    a large/irregular (tillage-extended) boundary can take thousands of
    steps, so this runs across many WailaFieldIndex:update() ticks rather
    than blocking one frame.
]]

WailaFieldBoundaryTracer = {}
local WailaFieldBoundaryTracer_mt = Class(WailaFieldBoundaryTracer)

-- Same infinite-loop guard threshold the base game's own class uses --
-- if tracing goes this long without closing the loop, something's wrong
-- (density noise, a shape with no clean boundary), bail rather than hang.
WailaFieldBoundaryTracer.MAX_POSITIONS = 15000

-- Public: nil if (x, z) isn't actually on-field -- same contract as the
-- base game's own constructor. Callers must seed with a position already
-- confirmed on-field (WailaFieldIndex uses labelX/labelZ, an actual
-- visited flood-fill cell -- NOT sampleX/sampleZ, which is a centroid
-- that can land off-shape on a non-convex/tillage-extended blob).
--
-- Uses FSDensityMapUtil.getFieldDataAtWorldPosition -- NOT the base
-- game's own raw getDensityAtWorldPos(terrainDetailId, ...) == 0 check
-- this class originally ported. Confirmed live (a traced field stopping
-- at its original map-authored boundary and missing a real, contiguous
-- tillage extension beyond it) that those two aren't equivalent:
-- terrainDetailId is the same raw, unfiltered density map WailaFieldGrid
-- Scanner:isFieldCell's own (correct, already-proven-elsewhere-in-WAILA)
-- check reads from, but that raw value bit-packs MULTIPLE channels
-- together (ground type, weed state, stone, plow level, ...) -- "raw
-- value is nonzero" is true whenever ANY of those channels is set, not
-- specifically the ground-type one, so it can disagree with "is this
-- actually field" at exactly the kind of boundary a tillage extension
-- creates (confirmed via decompiling FSDensityMapUtil.lua:
-- getFieldDataAtWorldPosition extracts and checks only the GROUND_TYPE
-- channel specifically via bit32.band/rshift, not the raw value).
-- Unifying both onto the same check this class's own seed-finder already
-- trusts removes the disagreement entirely, rather than trying to keep
-- two different "is field" definitions in sync.
function WailaFieldBoundaryTracer.new(x, z)
    local self = setmetatable({}, WailaFieldBoundaryTracer_mt)
    self.startX = x
    self.startZ = z
    self.curX = x
    self.curZ = z
    self.boundaryPositions = {}

    -- Step size matched to the SAME density map getFieldDataAtWorldPosition
    -- actually reads from (fieldGroundSystem's GROUND_TYPE map), not
    -- terrainDetailMapSize -- confirmed live (a "traced boundary" that was
    -- really just 2-3 points on a straight line, oscillating instead of
    -- tracing) that those can be different-resolution density maps. Using
    -- terrainDetailMapSize's resolution as the step size while reading a
    -- DIFFERENT map's density meant each step could land inside the same
    -- groundType texel more than once, confusing the wall-follower.
    local groundTypeMapId = g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    self.terrainDetailResolution = g_currentMission.terrainSize / getDensityMapSize(groundTypeMapId)

    if not FSDensityMapUtil.getFieldDataAtWorldPosition(self.curX, 0, self.curZ) then
        return nil
    end
    return self
end

-- Direct port of BoundaryDetectionTask:update -- same wall-follower logic,
-- same variable shapes, only renamed to this codebase's conventions.
-- Returns true while still tracing (call again next tick), false once
-- finalize() has run (done, boundaryPositions is a closed loop).
function WailaFieldBoundaryTracer:update(frameBudget)
    local terrainDetailResolution = self.terrainDetailResolution
    local startTime = getTimeSec()

    while getTimeSec() - startTime < frameBudget do
        if #self.boundaryPositions == 0 then
            local isOnField = FSDensityMapUtil.getFieldDataAtWorldPosition(self.curX, 0, self.curZ)
            if isOnField then
                self.curZ = self.curZ + terrainDetailResolution
            else
                table.insert(self.boundaryPositions, { self.curX, self.curZ })
            end
        else
            local numPositions = #self.boundaryPositions
            local dirX, dirZ

            if numPositions >= 2 then
                dirX = self.boundaryPositions[numPositions][1] - self.boundaryPositions[numPositions - 1][1]
                dirZ = self.boundaryPositions[numPositions][2] - self.boundaryPositions[numPositions - 1][2]
            elseif not FSDensityMapUtil.getFieldDataAtWorldPosition(self.curX + terrainDetailResolution, 0, self.curZ) then
                dirX, dirZ = -1, 0
            elseif not FSDensityMapUtil.getFieldDataAtWorldPosition(self.curX, 0, self.curZ + terrainDetailResolution) then
                dirX, dirZ = 0, -1
            else
                dirX, dirZ = 1, 0
            end

            -- Confirmed live (real stack trace, not a guess this time):
            -- MathUtil.vector2Normalize divides by the vector's own
            -- length, which is zero here if dirX/dirZ are both zero.
            -- Real, reachable case: if rightValue == 0 further down, the
            -- whole curX/curZ-advancing block below is skipped entirely,
            -- so the SAME position gets inserted again next loop
            -- iteration -- the following iteration's dirX/dirZ (last
            -- position minus second-to-last) then come out (0,0) since
            -- they're now identical points. Ported faithfully from the
            -- base game's own BoundaryDetectionTask, which has this exact
            -- same shape -- whatever makes it rare enough not to matter
            -- there, our seed points (every on-field cell across the
            -- whole map, not just wherever a real machine happens to
            -- start a course from) hit it for real. Bail the trace
            -- (finalize with whatever's traced so far) rather than crash
            -- -- same pattern as the infinite-loop guard below.
            if dirX == 0 and dirZ == 0 then
                Logging.devWarning("[WhatAmILookingAt] WailaFieldBoundaryTracer: stalled (zero direction vector) at %d positions, giving up", numPositions)
                self:finalize()
                return false
            end

            dirX, dirZ = MathUtil.vector2Normalize(dirX, dirZ)
            dirX = dirX * terrainDetailResolution
            dirZ = dirZ * terrainDetailResolution

            local frontValue = FSDensityMapUtil.getFieldDataAtWorldPosition(self.curX + dirX, 0, self.curZ + dirZ)
            local leftValue = FSDensityMapUtil.getFieldDataAtWorldPosition(self.curX + dirZ, 0, self.curZ - dirX)
            local rightValue = FSDensityMapUtil.getFieldDataAtWorldPosition(self.curX - dirZ, 0, self.curZ + dirX)

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
                -- Confirmed live (real bug, not a guess): when rightValue
                -- is false, the base game's own original algorithm (ported
                -- faithfully at first) leaves curX/curZ completely
                -- unchanged -- nothing in this branch existed at all. That
                -- silently inserts a duplicate point (table.insert below
                -- still runs), which starves the NEXT iteration's
                -- direction computation (last two points now identical)
                -- into the zero-vector stall case above -- confirmed via
                -- step-by-step logging: two consecutive closure-check
                -- entries with the exact same "last" position, immediately
                -- followed by that stall firing and bailing the trace
                -- early, mistaking "hit a convex corner" for "trace done".
                -- rightValue false means the wall dropped away to the
                -- right -- pivot to follow it around the corner, using the
                -- same rotation already used to compute the right-sample
                -- offset itself, instead of freezing in place.
                self.curX = self.curX - dirZ
                self.curZ = self.curZ + dirX
            end

            table.insert(self.boundaryPositions, { self.curX, self.curZ })
        end

        local numPositions = #self.boundaryPositions
        if numPositions > 10 then
            local distance = MathUtil.vector2Length(
                self.boundaryPositions[numPositions][1] - self.boundaryPositions[1][1],
                self.boundaryPositions[numPositions][2] - self.boundaryPositions[1][2]
            )
            if distance < self.terrainDetailResolution then
                self:finalize()
                return false
            end
        end

        if numPositions > WailaFieldBoundaryTracer.MAX_POSITIONS then
            Logging.devWarning("[WhatAmILookingAt] WailaFieldBoundaryTracer: unable to close boundary loop, giving up at %d positions", numPositions)
            self:finalize()
            return false
        end
    end

    return true
end

-- Direct port of BoundaryDetectionTask:finalize -- reorders so the
-- polygon consistently starts from the same corner (max x*z) regardless
-- of which direction tracing happened to start walking, and closes the
-- loop by repeating the first point at the end.
function WailaFieldBoundaryTracer:finalize()
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
    table.insert(reordered, { reordered[1][1], reordered[1][2] })
    self.boundaryPositions = reordered
end

-- Meters -- perpendicular-distance tolerance for simplify() below. Small
-- enough to preserve real corners/shape detail, large enough to strip the
-- near-collinear noise a native-resolution trace produces along any
-- straight edge (which is most of a typical field's perimeter).
WailaFieldBoundaryTracer.SIMPLIFY_TOLERANCE = 0.5

-- Douglas-Peucker polyline simplification, iterative (explicit stack, not
-- language-level recursion -- a pathological input could recurse O(n)
-- deep otherwise, and a raw trace can have up to MAX_POSITIONS=15000
-- points). Collapses the (potentially thousands of points, one per
-- terrainDetailResolution step) raw trace down to the handful of points
-- actually needed to represent its shape within tolerance. Necessary, not
-- just nice-to-have: saving thousands of "x z" pairs per field into
-- waila.xml would be enormous and defeat its own "genuinely readable"
-- goal, and Polygon2D:getOffsetPolygon (a real method, confirmed via
-- decompile) rejects any polygon with an edge shorter than the requested
-- offset -- a raw trace's edges are all sub-meter, so offsetting it for
-- anything (e.g. inset label placement) would fail almost universally
-- without this first. points is a list of {x, z} pairs -- same shape
-- boundaryPositions already uses.
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

            for i = startIndex + 1, endIndex - 1 do
                -- Defensive: getDistanceToLineSegment2D divides by the
                -- segment's own squared length internally, zero for a
                -- degenerate (identical-endpoint) segment. toPolygon()
                -- below strips the one guaranteed case (finalize()'s own
                -- closing duplicate) before this ever runs, but this stays
                -- wrapped too as a backstop against any other case not
                -- accounted for -- falls back to straight point-to-point
                -- distance from the segment's start, which is exactly
                -- correct for a zero-length "segment" anyway.
                local dist = WailaUtil.safeCall(nil, MathUtil.getDistanceToLineSegment2D, ax, az, bx, bz, points[i][1], points[i][2])
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

-- Public: simplifies boundaryPositions in place, then flattens into the
-- {x1,z1,x2,z2,...} shape Polygon2D.new's vertexCoordinates argument
-- expects. finalize() closes the loop by duplicating the first point onto
-- the end (boundaryPositions[1] == boundaryPositions[n]) -- simplifying
-- with that duplicate still attached makes Douglas-Peucker's very first
-- anchor segment (points[1] to points[n]) zero-length on every single
-- call, guaranteed, not an edge case -- confirmed live (real crash,
-- MathUtil.getDistanceToLineSegment2D dividing by that segment's own
-- zero length). Simplified as an open ring (duplicate stripped) instead,
-- then re-closed the same way finalize() does.
function WailaFieldBoundaryTracer:toPolygon()
    local openRing = self.boundaryPositions
    local first, last = openRing[1], openRing[#openRing]
    if #openRing > 1 and first[1] == last[1] and first[2] == last[2] then
        openRing = {}
        for i = 1, #self.boundaryPositions - 1 do
            table.insert(openRing, self.boundaryPositions[i])
        end
    end

    local simplified = simplifyBoundary(openRing, WailaFieldBoundaryTracer.SIMPLIFY_TOLERANCE)
    table.insert(simplified, { simplified[1][1], simplified[1][2] })
    self.boundaryPositions = simplified

    local flatVertices = {}
    for _, position in ipairs(self.boundaryPositions) do
        table.insert(flatVertices, position[1])
        table.insert(flatVertices, position[2])
    end
    return Polygon2D.new(nil, flatVertices)
end
