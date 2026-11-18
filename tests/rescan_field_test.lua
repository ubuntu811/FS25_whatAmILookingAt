-- plain Lua: Waila.rescanField traces a field again on request: no cooldown, queued once per call
dofile("tests/stubs.lua")
Class = function(c) return { __index = c } end
nextMessageTypeId = function() return 1 end
dofile("scripts/WailaFieldIndex.lua")
local passed, failed = 0, 0
local realPrint = print
local function check(name, ok) if ok then passed = passed + 1 else failed = failed + 1; realPrint("  FAIL " .. name) end end
local clock = 1000
getTimeSec = function() return clock end
local published = 0
g_messageCenter = { publish = function() published = published + 1 end }
local idx = setmetatable({ entries = { { wailaFieldId = 7, sampleX = 10, sampleZ = 10 } }, blobQueue = {}, blobRescanAt = {} }, { __index = WailaFieldIndex })
idx.getEntry = function() return { wailaFieldId = 7 } end
idx:rescanBlobAt(nil, 10, 10)
idx:rescanBlobAt(nil, 10, 10)
check("two ordinary rescans in a row: the second one is held back by the cooldown", #idx.blobQueue == 1 and published == 1)
idx:rescanBlobAt(nil, 10, 10, true)
check("a forced rescan goes into the queue whatever the cooldown says", #idx.blobQueue == 2)
WailaAreaTracker = { AREA_ENTERED = 2, AREA_LEFT = 3 }
dofile("scripts/Waila.lua")
Waila.indices.field = idx
check("Waila.rescanField queues the trace and says so", Waila.rescanField(10, 10) == true and #idx.blobQueue == 3)
Waila.indices.field = nil
check("without a field index it says false", Waila.rescanField(10, 10) == false)
realPrint(string.format("rescan_field_test: %d/%d passed", passed, passed + failed))
os.exit(failed == 0 and 0 or 1)
