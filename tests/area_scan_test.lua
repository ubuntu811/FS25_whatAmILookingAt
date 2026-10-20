dofile("tests/stubs.lua")
local T = loadTracer()

-- chunk range around a point (4096 m map, 64 m chunks: 64 per side, origin -2048)
local c0, c1, r0, r1 = T.areaChunkRange(0, 0, 1, 4096, 64)
check("a point at the map centre: 3 x 3 chunks around chunk 32", c0 == 31 and c1 == 33 and r0 == 31 and r1 == 33)
c0, c1, r0, r1 = T.areaChunkRange(-2040, -2040, 1, 4096, 64)
check("in the map corner the range is clamped to the map (2 x 2)", c0 == 0 and c1 == 1 and r0 == 0 and r1 == 1)
c0, c1, r0, r1 = T.areaChunkRange(5000, 5000, 1, 4096, 64)
check("a point outside the map is clamped, not an error", c1 == 63 and r1 == 63 and c0 == 62)
c0, c1, r0, r1 = T.areaChunkRange(100, 100, 0, 4096, 64)
check("radius 0: exactly the chunk holding the point (x 100 -> column 33)", c0 == c1 and r0 == r1 and c0 == 33)

-- cursor over a range
local state = T.newScanState(4096, 64, 31, 33, 31, 33, true, nil, false)
check("an area state knows its size and starts at the range's corner", state.chunksTotal == 9 and state.col == 31 and state.row == 31)
local visited, done, guard = {}, false, 0
while not done and guard < 100 do
    guard = guard + 1
    visited[#visited + 1] = state.col .. "_" .. state.row
    done = T.advanceChunkCursor(state)
end
check("the cursor visits all 9 chunks once, row by row", #visited == 9 and visited[1] == "31_31" and visited[4] == "31_32" and visited[9] == "33_33")
check("...and counts them", state.chunksDone == 9)

-- an area scan run through tickLayerScanStep with the heavy parts stubbed
g_currentMission.terrainSize = 4096
local cleared, recorded, regenerated, linked, sweeps = {}, {}, {}, 0, 0
T.clearChunkOverlays = function(minX, minZ, maxX, maxZ) cleared[#cleared + 1] = { minX, minZ, maxX, maxZ } end
T.scanBuildingChunk = function() return {}, nil, {} end
T.scanLayerChunk = function() return nil end
T.recordRegionPolygons = function(layer, minX, minZ) recorded[#recorded + 1] = layer .. ":" .. minX .. "," .. minZ end
T.recordScannedPolygons = function() end
T.linkTrailFragments = function() linked = linked + 1 end
for _, name in ipairs({ "buildTestOverlay", "buildForestOverlayIncremental", "buildWaterLayerOverlayIncremental", "buildTreeLayerOverlayIncremental", "buildRoadLayerOverlayIncremental", "buildBuildingLayerOverlayIncremental" }) do
    T[name] = function(_, force) if force then regenerated[name] = true end end
end
Waila = { indices = { field = { requestFullSweep = function() sweeps = sweeps + 1 end } } }
local area = T.newScanState(4096, 64, 31, 33, 31, 33, true, nil, false)
T.wholeMapScanState = area
local finished, ticks = false, 0
while not finished and ticks < 50 do
    ticks = ticks + 1
    finished = T.tickLayerScanStep(area)
end
check("area scan: 9 chunks, each wiped before it is redrawn", ticks == 9 and #cleared == 9)
check("area scan: the wiped rectangles are the chunks (first: x -64..0, z -64..0)", cleared[1][1] == -64 and cleared[1][2] == -64 and cleared[1][3] == 0 and cleared[1][4] == 0)
local roadRecords = 0
for _, r in ipairs(recorded) do if r:find("^road:") then roadRecords = roadRecords + 1 end end
check("area scan: every chunk's stored regions are replaced (one road record per chunk)", roadRecords == 9)
check("area scan: every overlay, water and trees included, is regenerated at the end", regenerated.buildWaterLayerOverlayIncremental and regenerated.buildTreeLayerOverlayIncremental and regenerated.buildTestOverlay and regenerated.buildRoadLayerOverlayIncremental)
check("area scan: trail links are redone, the state is released", linked == 1 and T.wholeMapScanState == nil)
check("area scan: it does NOT start a field sweep", sweeps == 0)

-- the whole-map scan still does not wipe per chunk, and still starts the field sweep
cleared, sweeps = {}, 0
local whole = T.newScanState(4096, 64, 0, 1, 0, 1, false, nil, false)
T.wholeMapScanState = whole
finished, ticks = false, 0
while not finished and ticks < 50 do ticks = ticks + 1 finished = T.tickLayerScanStep(whole) end
check("whole-map scan: no per-chunk wipe (it cleared everything up front)", #cleared == 0 and ticks == 4)
check("whole-map scan: the field sweep starts after it", sweeps == 1)

-- key presses while the layers are being restored / saved
T.wholeMapScanState = nil
local closed = 0
T.loadState = { index = 0, workItems = {}, xmlFile = { delete = function() closed = closed + 1 end } }
check("area scan during a restore: refused, with a note", T.startAreaScan(0, 0) == false and T.statusNote ~= nil and T.statusNote.text == "Busy: restoring")
check("...and the restore is left alone", T.loadState ~= nil and closed == 0)
T.statusNote = nil
T.clearScanOverlays = function() end
T.learnLayerClasses = function() end
T.collectRoadSplineChains = function() return {} end
T.startWholeMapScan()
check("whole-map scan during a restore: the restore is cancelled and the scan starts", T.loadState == nil and closed == 1 and T.wholeMapScanState ~= nil)
check("...without a busy note", T.statusNote == nil)
T.startWholeMapScan()
check("a second press while scanning is refused with a note", T.statusNote ~= nil and T.statusNote.text == "Busy: scanning")
T.wholeMapScanState = nil
T.saveState = { index = 1, workItems = {} }
T.startWholeMapScan()
check("whole-map scan during a save: refused, the save is not touched", T.saveState ~= nil and T.statusNote.text == "Busy: saving")
finish("area_scan_test")
