dofile("tests/stubs.lua")

-- engine stubs the field scanner needs beyond the shared ones
Class = function(c) return { __index = c } end
Waila = { debugFieldTracing = false }
local function inside(vertices, x, z)
    local c, n = false, #vertices / 2
    local j = n
    for i = 1, n do
        local xi, zi, xj, zj = vertices[2 * i - 1], vertices[2 * i], vertices[2 * j - 1], vertices[2 * j]
        if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then c = not c end
        j = i
    end
    return c
end
Polygon2D = {}
Polygon2D.__index = Polygon2D
function Polygon2D.new(_, vertices) return setmetatable({ v = vertices }, Polygon2D) end
function Polygon2D:getVertices() return self.v end
function Polygon2D:getIsPosInside(x, z) return inside(self.v, x, z) end
function Polygon2D:getBoundingBox()
    local a, b, c, d = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, #self.v, 2 do
        a, b = math.min(a, self.v[i]), math.max(b, self.v[i])
        c, d = math.min(c, self.v[i + 1]), math.max(d, self.v[i + 1])
    end
    return a, b, c, d
end
function Polygon2D:getArea()
    local s, n = 0, #self.v / 2
    for i = 1, n do
        local j = i % n + 1
        s = s + self.v[2 * i - 1] * self.v[2 * j] - self.v[2 * j - 1] * self.v[2 * i]
    end
    return math.abs(s) / 2
end
function Polygon2D:getOffsetPolygon() return nil end
function WailaUtil.getIsPosInsidePolygon(p, x, z) return p ~= nil and p:getIsPosInside(x, z) end
g_currentMission = { terrainSize = 512, fieldGroundSystem = { getDensityMapData = function() return 1 end } }
FieldDensityMap = { GROUND_TYPE = 1 }
getDensityMapSize = function() return 512 end

MathUtil.vector2Normalize = function(x, z) local l = math.sqrt(x * x + z * z); if l == 0 then return 0, 0 end return x / l, z / l end

-- field: a 200 m square with a 120 m hole in the middle, its south-west
-- corner cut away so the FIRST cell the row-major seed scan meets sits
-- right below the hole (its +z walk runs into the hole, not out of the
-- field), plus a separate plain 60 x 60 field
local function isField(x, z)
    local inBig = math.abs(x) <= 100 and math.abs(z) <= 100
    local inHole = math.abs(x) <= 60 and math.abs(z) <= 60
    local notch = x <= -70 and z <= -70
    local inSmall = x >= 150 and x <= 210 and z >= -30 and z <= 30
    return (inBig and not inHole and not notch) or inSmall
end
FSDensityMapUtil = { getFieldDataAtWorldPosition = function(x, _, z) return isField(x, z) end }

dofile("scripts/WailaFieldBoundaryTracer.lua")
dofile("scripts/WailaFieldGridScanner.lua")

local scanner = WailaFieldGridScanner.new()
local found, done, guard = {}, false, 0
local maxSkipped, maxTraces = 0, 0
while not done and guard < 200000 do
    guard = guard + 1
    maxSkipped = math.max(maxSkipped, scanner.holeSeedsSkipped)
    maxTraces = math.max(maxTraces, scanner.tracesStarted)
    local lx, lz, _, _, area, _, completed, polygon = scanner:update(0.05)
    if lx ~= nil then table.insert(found, { x = lx, z = lz, area = area, polygon = polygon }) end
    done = completed
    if lx ~= nil and completed then table.remove(found) end -- first result of the NEXT pass
end

for i, f in ipairs(found) do print(string.format("    found %d: area=%.0f label=(%.0f,%.0f)", i, f.area, f.x, f.z)) end
check("sweep finishes", done)
check("two fields: one ring, one plain (not the hole, not repeats)", #found == 2)
local ringArea, smallArea = 200 * 200 - 120 * 120 - 30 * 30, 60 * 60
local sawRing, sawSmall = false, false
for _, f in ipairs(found) do
    if math.abs(f.area - ringArea) / ringArea < 0.1 or math.abs(f.area - 200 * 200) / (200 * 200) < 0.1 then sawRing = true end
    if math.abs(f.area - smallArea) / smallArea < 0.1 then sawSmall = true end
end
check("the ring field outline was found", sawRing)
check("the small field was found", sawSmall)
check("progress counters: seeds that ran into the known hole were skipped, not traced", maxSkipped >= 1)
check("progress counters: few real traces (hole once, outline, small field)", maxTraces - maxSkipped > 0 and maxTraces - maxSkipped <= 6)

-- the on-screen progress line's data
nextMessageTypeId = function() return 1 end
dofile("scripts/WailaFieldIndex.lua")
local now = 1000
getTimeSec = function() return now end
local fakeScanner = { cols = 10, rows = 10, sweepIndex = 25, holes = { 1, 2 }, holeSeedsSkipped = 3, tracesStarted = 7 }
local sweeping = { isSweeping = true, scanner = fakeScanner, pendingEntries = { 1, 2, 3 }, sweepStartTime = 990 }
local pr = WailaFieldIndex.getSweepProgress(sweeping)
check("progress: cells done / total", pr.done == 25 and pr.total == 100)
check("progress: fields found, holes known, seeds skipped, elapsed", pr.found == 3 and pr.holes == 2 and pr.skipped == 3 and pr.traces == 4 and pr.elapsed == 10)
check("progress: waiting for the startup delay", WailaFieldIndex.getSweepProgress({ startupSweepDelayMs = 12500 }).delaySec == 12.5)
local fin = WailaFieldIndex.getSweepProgress({ entries = { 1, 2 }, lastSweepFinishedAt = 995, lastSweepDurationSec = 3.3 })
check("progress: shows the final result for a few seconds", fin ~= nil and fin.finished and fin.found == 2 and fin.elapsed == 3.3)
check("progress: gone after the display time", WailaFieldIndex.getSweepProgress({ entries = { 1 }, lastSweepFinishedAt = 980 }) == nil)
check("progress: nothing to show when idle", WailaFieldIndex.getSweepProgress({}) == nil)

-- single-field rescans (vehicle leaves a field): queued, budgeted, rate-limited
local published = {}
g_messageCenter = { publish = function(_, _, entity, entry) table.insert(published, { entity = entity, entry = entry }) end }
local index = setmetatable({
    entries = {}, blobQueue = {}, blobRescanAt = {}, nextWailaFieldId = 1, vehicleFieldState = {},
    scanner = WailaFieldGridScanner.new(),
    fieldInspector = { inspectPoint = function() return {} end },
}, { __index = WailaFieldIndex })
now = 2000
index:rescanBlobAt("tractor", 180, 0)
check("rescan: queued, nothing traced or published yet", #index.blobQueue == 1 and #published == 0 and #index.entries == 0)
local ticks = 0
while (#index.blobQueue > 0 or index.activeBlob ~= nil) and ticks < 100000 do
    ticks = ticks + 1
    index:advanceBlobRescans()
end
check("rescan: the field is added and the leave event fires", #index.entries == 1 and #published == 1 and published[1].entry == index.entries[1])
check("rescan: the entry is the small field", math.abs(index.entries[1].boundary:getArea() - 3600) < 400)
index:rescanBlobAt("tractor", 180, 0)
check("rescan: same field inside the cooldown is not traced again", #index.blobQueue == 0 and index.activeBlob == nil)
check("rescan: ... but the event still fires with the known entry", #published == 2 and published[2].entry == index.entries[1])
now = 2000 + WailaFieldIndex.BLOB_RESCAN_COOLDOWN_SEC + 1
index:rescanBlobAt("tractor", 180, 0)
check("rescan: after the cooldown it is queued again", #index.blobQueue == 1)
finish("field_scan_test")
