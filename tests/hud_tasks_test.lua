dofile("tests/stubs.lua")
Class = function(c) return { __index = c } end
dofile("scripts/WailaHud.lua")

local function rowsOf(tracer, fieldIndex) return WailaHud.collectTaskRows(tracer, fieldIndex) end

check("idle: no rows", #rowsOf({}, { getSweepProgress = function() return nil end }) == 0)
check("no tracer, no field index: no rows, no error", #rowsOf(nil, nil) == 0)

local r = rowsOf({ wholeMapScanState = { chunksTotal = 200, chunksDone = 50, isArea = false } }, nil)
check("whole-map scan row with its fraction", #r == 1 and r[1].label == "Map scan" and r[1].fraction == 0.25)
r = rowsOf({ wholeMapScanState = { chunksTotal = 9, chunksDone = 3, isArea = true } }, nil)
check("area rescan is labelled as such", r[1].label == "Area scan")
r = rowsOf({ wholeMapScanState = { chunksPerSide = 10, row = 2, col = 5 } }, nil)
check("older scan state without counters: derived from row and col", r[1].fraction == 0.25)

local sweeping = { getSweepProgress = function() return { total = 400, done = 100 } end }
r = rowsOf({}, sweeping)
check("field sweep row", #r == 1 and r[1].label == "Field sweep" and r[1].fraction == 0.25)
r = rowsOf({}, { getSweepProgress = function() return { waiting = true, delaySec = 12.2 } end })
check("startup delay: text only, no bar", #r == 1 and r[1].label == "Fields in 13s" and r[1].fraction == nil)
r = rowsOf({}, { getSweepProgress = function() return { finished = true, found = 17, elapsed = 2 } end })
check("a finished sweep shows nothing", #r == 0)

r = rowsOf({ loadState = { index = 30, workItems = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } }, saveState = { index = 5, workItems = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } } }, nil)
check("restore and save rows, in that order", #r == 2 and r[1].label == "Restore" and r[1].fraction == 1 and r[2].label == "Save" and r[2].fraction == 0.5)

r = rowsOf({ wholeMapScanState = { chunksTotal = 4, chunksDone = 1 }, loadState = { index = 0, workItems = {} } }, sweeping)
check("everything at once: scan, sweep, restore stacked", #r == 3 and r[3].fraction == nil)

-- live detail: what the scan has found so far
r = rowsOf({ wholeMapScanState = { chunksTotal = 100, chunksDone = 10, stats = { trees = 45633, forestPolygons = 1418, trailPolygons = 1103, roadPolygons = 884, buildingPolygons = 105, waterPolygons = 5 } } }, nil)
check("map scan row carries what it found so far", #r[1].detail == 3 and r[1].detail[1] == "trees 45.6k  forest 1418" and r[1].detail[2] == "trails 1103  roads 884" and r[1].detail[3] == "buildings 105  water 5")
r = rowsOf({}, { getSweepProgress = function() return { total = 10, done = 5, found = 7 } end })
check("field sweep row says how many fields it found", r[1].detail[1] == "7 fields found")
r = rowsOf({}, { getSweepProgress = function() return nil end, activeBlob = {}, blobQueue = { 1, 2 } })
check("a single-field rescan has a row, with the queue length", #r == 1 and r[1].label == "Field rescan" and r[1].detail[1] == "2 more waiting")
r = rowsOf({}, { getSweepProgress = function() return nil end, activeBlob = nil, blobQueue = {} })
check("no field rescan running: no row", #r == 0)

-- a restore still in its start delay shows a countdown, a refused key press a short note
local clock = 500
getTimeSec = function() return clock end
r = rowsOf({ loadState = { index = 0, workItems = {}, notBefore = 512.2 } }, nil)
check("restore waiting for its start delay: countdown, no bar", #r == 1 and r[1].label == "Restore in 13s" and r[1].fraction == nil)
r = rowsOf({ loadState = { index = 0, workItems = { 1, 2 }, notBefore = 400 } }, nil)
check("restore past its delay: a normal progress row", r[1].label == "Restore" and r[1].fraction == 0)
r = rowsOf({ statusNote = { text = "Busy: saving", untilTime = 504 } }, nil)
check("a busy note shows while it is fresh", #r == 1 and r[1].label == "Busy: saving")
clock = 505
check("...and goes away after its time", #rowsOf({ statusNote = { text = "Busy: saving", untilTime = 504 } }, nil) == 0)

-- layer images: restore and save phases
r = rowsOf({ loadState = { index = 0, workItems = {}, phase = "images", notBefore = 999, images = { index = 3, queue = { 1, 2, 3, 4 } } } }, nil)
check("restoring layer images: its own row with the layer count", r[1].label == "Restore images" and r[1].fraction == 0.5)
r = rowsOf({ imageSaveState = { index = 2, queue = { 1, 2, 3, 4 } } }, nil)
check("saving layer images: a row with progress", r[1].label == "Save images" and r[1].fraction == 0.25)

-- drawing: height matches the rows, nothing drawn when idle
local rects, texts = 0, 0
drawFilledRect = function() rects = rects + 1 end
renderText = function() texts = texts + 1 end
setTextColor, setTextAlignment = function() end, function() end
RenderText = { ALIGN_LEFT = 0, ALIGN_RIGHT = 1 }
local hud = setmetatable({ miniWidth = 0.085 }, { __index = WailaHud })
check("idle strip: height 0, nothing drawn", hud:drawTaskRows({}, 0.2, 0.88) == 0 and rects == 0)
local h = hud:drawTaskRows({ { label = "Map scan", fraction = 0.5 }, { label = "Save", fraction = 0.1 } }, 0.2, 0.88)
check("strip height is the same as the one drawMini reserves", math.abs(h - (2 * WailaHud.TASK_ROW_HEIGHT + 0.003)) < 1e-9 and h == WailaHud.taskStripHeight({ { label = "Map scan", fraction = 0.5 }, { label = "Save", fraction = 0.1 } }))
check("background + two bars per row, label and percent per row", rects == 1 + 2 * 2 and texts == 4)
check("a plain strip is as wide as the mini panel", hud:taskStripWidth({ { label = "x" } }) == 0.085)
local detailed = { { label = "Map scan", fraction = 0.5, detail = { "a", "b" } } }
check("a row with detail lines is taller and the strip wider", WailaHud.taskStripHeight(detailed) > WailaHud.taskStripHeight({ { label = "x" } }) and hud:taskStripWidth(detailed) > 0.085)
rects, texts = 0, 0
local h2 = hud:drawTaskRows(detailed, 0.2, 0.88)
check("detail lines are drawn (label, percent, 2 detail lines)", texts == 4 and math.abs(h2 - WailaHud.taskStripHeight(detailed)) < 1e-9)
finish("hud_tasks_test")
