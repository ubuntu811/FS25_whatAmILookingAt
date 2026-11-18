-- plain Lua: the nightly tidy of the live field list (pieces inside a bigger field go)
dofile("tests/stubs.lua")
Class = function(c) return { __index = c } end
nextMessageTypeId = function() return 1 end
dofile("scripts/WailaFieldIndex.lua")
local passed, failed = 0, 0
local realPrint = print
local function check(name, ok) if ok then passed = passed + 1 else failed = failed + 1; realPrint("  FAIL " .. name) end end
WailaUtil = WailaUtil or {}
WailaUtil.getIsPosInsidePolygon = function(poly, x, z)
    local v, n, r = poly:getVertices(), #poly:getVertices() / 2, false
    local j = n
    for i = 1, n do
        local xi, zi, xj, zj = v[2 * i - 1], v[2 * i], v[2 * j - 1], v[2 * j]
        if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then r = not r end
        j = i
    end
    return r
end
local function box(x0, z0, x1, z1) return { getVertices = function() return { x0, z0, x1, z0, x1, z1, x0, z1 } end } end
local function entry(id, x, z, b) return { wailaFieldId = id, sampleX = x, sampleZ = z, boundary = b } end
local big, piece, other = entry(1, 100, 100, box(0, 0, 200, 200)), entry(2, 50, 50, box(40, 40, 60, 60)), entry(3, 500, 500, box(400, 400, 600, 600))
local idx = setmetatable({ entries = { piece, big, other }, blobQueue = {} }, { __index = WailaFieldIndex })
local dropped = idx:tidyEntries()
check("the piece inside the big field is dropped", dropped == 1 and #idx.entries == 2)
check("the big field and the separate one stay", idx.entries[1] == big and idx.entries[2] == other)
idx.entries = { entry(2, 50, 50, box(40, 40, 60, 60)), big }
idx.blobQueue = { {} }
check("nothing is touched while a rescan is queued", idx:tidyEntries() == 0 and #idx.entries == 2)
idx.blobQueue = {}
idx.activeBlob = {}
check("nothing is touched while a trace runs", idx:tidyEntries() == 0 and #idx.entries == 2)
idx.activeBlob = nil
idx.isSweeping = true
check("nothing is touched during a sweep", idx:tidyEntries() == 0)
idx.isSweeping = false

-- an outline that changed asks for a rescan of its area
local function ring(x0, z0, x1, z1) return { { x0, z0 }, { x1, z0 }, { x1, z1 }, { x0, z1 } } end
check("the same outline (area within 3%) asks for nothing", WailaFieldIndex.changedRect(ring(0, 0, 100, 100), ring(0, 0, 101, 100)) == nil)
local r = WailaFieldIndex.changedRect(ring(0, 0, 100, 100), ring(0, 0, 150, 100))
check("a field that grew: the rectangle covers old and new", r ~= nil and r.minX == 0 and r.maxX == 150 and r.maxZ == 100)
r = WailaFieldIndex.changedRect(nil, ring(40, 40, 60, 60))
check("a field that was not there: its own rectangle", r ~= nil and r.minX == 40 and r.maxZ == 60)
r = WailaFieldIndex.changedRect(ring(40, 40, 60, 60), nil)
check("a field that is gone: the rectangle it had", r ~= nil and r.minX == 40 and r.maxX == 60)
check("neither: nothing", WailaFieldIndex.changedRect(nil, nil) == nil)
realPrint(string.format("field_tidy_test: %d/%d passed", passed, passed + failed))
os.exit(failed == 0 and 0 or 1)
