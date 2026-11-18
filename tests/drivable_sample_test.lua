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
-- trees
g_currentMission.terrainSize = 4096
check("no tree layer: no tree anywhere, no data", T.hasTreeData() == false and T.sampleTree(0, 0) == false)
T.treeLayerOverlayMap = fakeMap({ ["1024,1024"] = 1, ["1030,1024"] = 1 })
check("a tree dot pixel is a tree (world 0.5, 0.5 and 12.5, 0.5)", T.hasTreeData() and T.sampleTree(0.5, 0.5) and T.sampleTree(12.5, 0.5))
check("beside it is not", T.sampleTree(3.0, 0.5) == false and T.sampleTree(100, 100) == false)
check("outside the terrain: no tree, no error", T.sampleTree(-3000, 0) == false and T.sampleTree(0, 5000) == false)
-- buildings
check("no building layer: no building anywhere, no data", T.hasBuildingData() == false and T.sampleBuilding(0, 0) == false)
T.buildingLayerOverlayMap = fakeMap({ ["1030,1030"] = 1 })
check("a building pixel is a building (world 12.5, 12.5), its neighbour and a tree pixel are not", T.hasBuildingData() and T.sampleBuilding(12.5, 12.5) and not T.sampleBuilding(0.5, 0.5) and not T.sampleBuilding(14.5, 12.5))
check("outside the terrain: no building, no error", T.sampleBuilding(-3000, 0) == false)
finish("drivable_sample_test")
