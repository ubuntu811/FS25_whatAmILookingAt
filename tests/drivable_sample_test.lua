dofile("tests/stubs.lua")
local T = loadTracer()

-- fake bit-vector maps: a set of pixels per map
local function fakeMap(pixels) return { pixels = pixels } end
getBitVectorMapPoint = function(map, x, y) return map.pixels[x .. "," .. y] or 0 end

g_currentMission.terrainSize = 4096   -- 2048 px: 2 m per pixel, origin at -2048
check("no maps: not drivable, no data", T.sampleDrivable(0, 0) == 0 and T.hasDrivableData() == false)

-- world (0, 0) is pixel (1024, 1024)
T.roadLayerOverlayMap = fakeMap({ ["1024,1024"] = 1 })
T.testOverlayMap = fakeMap({ ["1030,1024"] = 2, ["1024,1024"] = 3 })
check("data present", T.hasDrivableData() == true)
check("a road pixel reads 2", T.sampleDrivable(0.5, 0.5) == 2)
check("the road wins over a trail on the same pixel", T.sampleDrivable(1.9, 1.9) == 2)
check("a trail pixel reads 1 (world x 12 -> pixel 1030)", T.sampleDrivable(12.5, 0.5) == 1)
check("empty ground reads 0", T.sampleDrivable(100, 100) == 0)
check("pixel edges: -0.01 is pixel 1023, +0 is pixel 1024", T.sampleDrivable(-0.01, 0.5) == 0 and T.sampleDrivable(0.0, 0.0) == 2)
check("outside the terrain reads 0", T.sampleDrivable(-3000, 0) == 0 and T.sampleDrivable(0, 5000) == 0)
g_currentMission.terrainSize = nil
check("no terrain size known: 0, no error", T.sampleDrivable(0, 0) == 0)
finish("drivable_sample_test")
