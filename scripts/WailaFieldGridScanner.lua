--[[
    WailaFieldGridScanner.lua

    Rewritten this session to use real boundary tracing (see
    WailaFieldBoundaryTracer.lua -- a port of the base game's own
    BoundaryDetectionTask, the class FieldCourseManager uses for AI course
    generation) as the PRIMARY discovery mechanism, not grid-based
    flood-fill grouping. Previous version flood-filled a coarse CELL_SIZE
    grid and stopped merging at farmland/Field boundaries (canJoinBlob),
    with a rice-field-polygon override for the one confirmed case where
    that boundary is wrong. That fixed rice paddies specifically but not
    the general case: a real, live, confirmed bug -- a single tillage-
    extended field spanning multiple administratively-separate farmland
    IDs came out as several separate WAILA field entries (several "S"
    labels in one visually-contiguous blob) because canJoinBlob correctly
    (by its own rules) refused to merge across the farmland boundary.

    Boundary tracing sidesteps this entirely: it only reads the density map
    (front/left/right density checks, exactly what MapOverlayGenerator's
    own minimap field coloring reads too), never consults farmland/Field
    identity at all, so one continuous farmed area traces as ONE polygon
    regardless of how many farmland IDs it crosses underneath -- same
    reason rice paddies now need no special-case override either, they
    just fall out of the general case for free.

    The grid (CELL_SIZE=24, unchanged) is kept for exactly one job now:
    cheaply finding untraced on-field SEED points to hand to the tracer,
    not for grouping/boundary decisions -- those are the tracer's job
    entirely. Once a trace finishes, every grid cell inside its polygon
    gets marked "claimed" (claimPolygonCells) so the seed scan skips the
    whole area instead of re-tracing the same physical field repeatedly.
]]

WailaFieldGridScanner = {}
local WailaFieldGridScanner_mt = Class(WailaFieldGridScanner)

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] " .. formatString, ...)
end

WailaFieldGridScanner.CELL_SIZE = 24

-- Real m^2 now (Polygon2D:getArea()), not a coarse cell count -- a proper
-- boundary trace has no "cell list" to count anymore. Chosen to reject
-- deco-patch-noise-scale false positives (a handful of m^2) while keeping
-- any real farmed patch -- same intent MIN_BLOB_CELLS had, just expressed
-- in the units tracing actually produces.
WailaFieldGridScanner.MIN_BLOB_AREA_SQM = 200

function WailaFieldGridScanner.new(customMt)
    local self = setmetatable({}, customMt or WailaFieldGridScanner_mt)
    self:reset()
    return self
end

function WailaFieldGridScanner:reset()
    local terrainSize = (g_currentMission ~= nil and g_currentMission.terrainSize) or 2048
    self.originX = -terrainSize * 0.5
    self.originZ = -terrainSize * 0.5
    self.cols = math.max(1, math.ceil(terrainSize / WailaFieldGridScanner.CELL_SIZE))
    self.rows = self.cols
    self.claimed = {}
    self.sweepIndex = 0
    self.activeTracer = nil
    self.lastLoggedRow = -1
end

function WailaFieldGridScanner:cellToWorld(col, row)
    local x = self.originX + (col + 0.5) * WailaFieldGridScanner.CELL_SIZE
    local z = self.originZ + (row + 0.5) * WailaFieldGridScanner.CELL_SIZE
    return x, z
end

function WailaFieldGridScanner:worldToCell(x, z)
    local col = math.floor((x - self.originX) / WailaFieldGridScanner.CELL_SIZE)
    local row = math.floor((z - self.originZ) / WailaFieldGridScanner.CELL_SIZE)
    return col, row
end

function WailaFieldGridScanner:isFieldCell(col, row)
    if col < 0 or col >= self.cols or row < 0 or row >= self.rows then
        return false
    end
    local x, z = self:cellToWorld(col, row)
    return FSDensityMapUtil.getFieldDataAtWorldPosition(x, 0, z) == true
end

function WailaFieldGridScanner:isClaimed(col, row)
    return self.claimed[row * self.cols + col] == true
end

function WailaFieldGridScanner:markClaimed(col, row)
    self.claimed[row * self.cols + col] = true
end

-- Marks every grid cell whose center falls inside polygon as claimed --
-- the seed scan below skips claimed cells entirely, so the physical area
-- this trace just covered never gets re-traced. Bounding-box-limited
-- (Polygon2D:getBoundingBox(), a real method) rather than scanning the
-- whole grid every time.
function WailaFieldGridScanner:claimPolygonCells(polygon)
    local minX, maxX, minZ, maxZ = polygon:getBoundingBox()
    if minX == nil then
        return
    end

    local minCol, minRow = self:worldToCell(minX, minZ)
    local maxCol, maxRow = self:worldToCell(maxX, maxZ)

    for row = math.max(0, minRow), math.min(self.rows - 1, maxRow) do
        for col = math.max(0, minCol), math.min(self.cols - 1, maxCol) do
            if not self:isClaimed(col, row) then
                local x, z = self:cellToWorld(col, row)
                if WailaUtil.getIsPosInsidePolygon(polygon, x, z) then
                    self:markClaimed(col, row)
                end
            end
        end
    end
end

-- Metadata only now, not a merge decision -- see file header. A single
-- rice-field placeable can span multiple farmland IDs, but boundary
-- tracing already merges that ground into one polygon regardless; this
-- just tags the finished entry with which rice field (if any) it is, the
-- same {polygon, height, waterHeight, areaSqm, capacity} data
-- WailaFieldIndex writes into waila.xml's <riceField> block. Duck-typed
-- via placeable.getFields ~= nil, same as before (confirmed via dataS.gar,
-- PlaceableRiceField.registerFunction).
function WailaFieldGridScanner:getRiceFieldAt(x, z)
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem
    if placeableSystem == nil then
        return nil
    end
    for _, placeable in ipairs(placeableSystem.placeables) do
        if placeable.getFields ~= nil then
            for _, field in ipairs(placeable:getFields()) do
                if field.polygon ~= nil and WailaUtil.getIsPosInsidePolygon(field.polygon, x, z) then
                    return field
                end
            end
        end
    end
    return nil
end

local function polygonCentroid(polygon)
    local vertices = polygon:getVertices()
    local sumX, sumZ, count = 0, 0, 0
    for i = 1, #vertices, 2 do
        sumX = sumX + vertices[i]
        sumZ = sumZ + vertices[i + 1]
        count = count + 1
    end
    if count == 0 then
        return nil
    end
    return sumX / count, sumZ / count
end

-- Meters -- how far to shrink the polygon inward before placing the label,
-- so it sits with real clearance from the field's own edges instead of
-- possibly landing right up against one (confirmed live: a label right at
-- a field's own top edge on a plain rectangular field). Only usable now
-- that boundaries are simplified (see WailaFieldBoundaryTracer.lua's
-- Douglas-Peucker pass) -- Polygon2D:getOffsetPolygon (a real method,
-- confirmed via decompile) rejects any polygon with an edge shorter than
-- the requested offset, which the RAW trace (thousands of sub-meter
-- edges) would fail almost universally, but a simplified field boundary
-- (a handful of real corners, tens of meters per edge) handles fine.
local LABEL_INSET_METERS = 8

-- Tries the inset polygon's centroid first (see LABEL_INSET_METERS), then
-- the raw polygon's own centroid, then the trace's start point (always
-- real, on-field, just not guaranteed central) -- each step only used if
-- the previous one failed or landed outside the field, which a concave/
-- tillage-extended shape can do even after insetting. Not the base game's
-- own MathUtil.getPolygonLabel -- that requires i3d NODE ids (confirmed
-- via decompile: it calls getWorldTranslation on each entry), not usable
-- on raw density-traced {x,z} points without creating throwaway nodes for
-- every boundary vertex just to call it.
local function computeInteriorPoint(polygon, fallbackX, fallbackZ)
    local offsetPolygon = WailaUtil.safeCall(nil, polygon.getOffsetPolygon, polygon, LABEL_INSET_METERS)
    if offsetPolygon ~= nil then
        local cx, cz = polygonCentroid(offsetPolygon)
        if cx ~= nil and WailaUtil.getIsPosInsidePolygon(polygon, cx, cz) then
            return cx, cz
        end
    end

    local cx, cz = polygonCentroid(polygon)
    if cx ~= nil and WailaUtil.getIsPosInsidePolygon(polygon, cx, cz) then
        return cx, cz
    end

    return fallbackX, fallbackZ
end

-- Advances up to timeBudgetSec of work -- either continuing an in-progress
-- boundary trace, or advancing the row-major seed scan to find the next
-- untraced on-field cell to start one from. Returns (labelX, labelZ,
-- sampleX, sampleZ, areaSqm, riceField, sweepCompleted, boundary):
-- labelX/Z and sampleX/Z are now the same point (computeInteriorPoint) --
-- keeping both names is just for WailaFieldIndex's existing call shape,
-- there's no longer a reason to pick two different points now that both
-- come from a real polygon instead of a coarse grid's separate "nearest
-- interior cell" vs "cell average" approximations. boundary is the real
-- Polygon2D, nil if nothing finished this call. sweepCompleted is true
-- exactly once per full pass over the grid.
function WailaFieldGridScanner:update(timeBudgetSec)
    local sweepCompleted = false
    local startTime = getTimeSec()

    while getTimeSec() - startTime < timeBudgetSec do
        if self.activeTracer ~= nil then
            local remaining = timeBudgetSec - (getTimeSec() - startTime)
            local stillTracing = self.activeTracer:update(math.max(remaining, 0))

            if not stillTracing then
                local polygon = self.activeTracer:toPolygon()
                local seedX, seedZ = self.activeTracer.startX, self.activeTracer.startZ
                self.activeTracer = nil

                self:claimPolygonCells(polygon)

                local areaSqm = polygon:getArea()
                if Waila.debugFieldTracing then
                    local vertexParts = {}
                    for _, v in ipairs(polygon:getVertices()) do
                        table.insert(vertexParts, string.format("%.2f", v))
                    end
                    log("[WailaFieldGridScanner] trace finished: points=%d area=%s (min=%d) vertices=[%s]",
                        #polygon:getVertices() / 2, tostring(areaSqm), WailaFieldGridScanner.MIN_BLOB_AREA_SQM, table.concat(vertexParts, " "))
                end
                if areaSqm ~= nil and areaSqm >= WailaFieldGridScanner.MIN_BLOB_AREA_SQM then
                    local labelX, labelZ = computeInteriorPoint(polygon, seedX, seedZ)
                    local riceField = self:getRiceFieldAt(seedX, seedZ)
                    return labelX, labelZ, labelX, labelZ, areaSqm, riceField, sweepCompleted, polygon
                end
                -- Too small (deco-patch-scale noise) -- claimed already,
                -- discarded, keep scanning for the next seed.
            end
        else
            if self.sweepIndex >= self.cols * self.rows then
                self:reset()
                sweepCompleted = true
            end

            local col = self.sweepIndex % self.cols
            local row = math.floor(self.sweepIndex / self.cols)
            self.sweepIndex = self.sweepIndex + 1

            if row ~= self.lastLoggedRow then
                self.lastLoggedRow = row
                if Waila.debugFieldTracing then
                    log("[WailaFieldGridScanner] seed scan: row %d/%d", row + 1, self.rows)
                end
            end

            if not self:isClaimed(col, row) then
                if self:isFieldCell(col, row) then
                    local x, z = self:cellToWorld(col, row)
                    if Waila.debugFieldTracing then
                        log("[WailaFieldGridScanner] seed candidate at cell(%d,%d) world(%.1f, %.1f)", col, row, x, z)
                    end
                    self.activeTracer = WailaFieldBoundaryTracer.new(x, z)
                    if Waila.debugFieldTracing then
                        log("[WailaFieldGridScanner] tracer start %s", self.activeTracer ~= nil and "OK" or "FAILED (constructor returned nil)")
                    end
                    if self.activeTracer == nil then
                        -- Shouldn't normally happen right after isFieldCell
                        -- just confirmed on-field, but avoid retrying this
                        -- exact cell forever if it does.
                        self:markClaimed(col, row)
                    end
                else
                    self:markClaimed(col, row)
                end
            end
        end
    end

    return nil, nil, nil, nil, nil, nil, sweepCompleted, nil
end

-- Synchronous, single-field version of the same trace -- starting from
-- the field cell at world position (x, z), not part of the incremental
-- full-map sweep above (own local tracer, doesn't touch self.claimed/
-- self.sweepIndex, so it can't collide with an in-progress budgeted
-- sweep). Intended caller: WailaFieldIndex, right after a vehicle leaves
-- a field it was just standing on -- catches a boundary change (new
-- tillage, a merge, meadow conversion) far sooner than waiting for the
-- next full sweep would. Returns (labelX, labelZ, sampleX, sampleZ,
-- areaSqm, riceField, boundary), or nil if (x, z) isn't field ground.
-- Unbudgeted/blocking by design (same tradeoff the old flood-fill version
-- made: safe because it's bounded to one field, not the whole map) --
-- native-resolution tracing is finer-grained than the old grid flood-fill
-- was, so a very large field may take noticeably longer than before did.
function WailaFieldGridScanner:scanBlobAt(x, z)
    local tracer = WailaFieldBoundaryTracer.new(x, z)
    if tracer == nil then
        return nil
    end

    while tracer:update(0.05) do
        -- keep advancing in reasonably-sized slices until finalize() runs
    end

    local polygon = tracer:toPolygon()
    local areaSqm = polygon:getArea()
    local labelX, labelZ = computeInteriorPoint(polygon, x, z)
    local riceField = self:getRiceFieldAt(x, z)

    return labelX, labelZ, labelX, labelZ, areaSqm, riceField, polygon
end
