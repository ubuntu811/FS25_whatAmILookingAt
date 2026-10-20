dofile("tests/stubs.lua")
Class = function(c) return { __index = c } end
dofile("scripts/WailaHud.lua")

local calls, now = 0, 100
getTimeSec = function() return now end
overlapBox = function() end
WailaTrailTracer = { countTrees = function(x, z, half) calls = calls + 1 return 5 end }
local hud = setmetatable({}, { __index = WailaHud })

check("trunk count comes from the forest scan's query", hud:getTreeEvidence(10.2, 20.7) == 5 and calls == 1)
check("same metre, within a quarter second: cached (no second query)", hud:getTreeEvidence(10.6, 20.1) == 5 and calls == 1)
now = 100.3
hud:getTreeEvidence(10.2, 20.7)
check("after a quarter second the query runs again", calls == 2)
hud:getTreeEvidence(12.5, 20.7)
check("another metre: a new query", calls == 3)
overlapBox = nil
check("no overlapBox in the engine: no evidence, no error", hud:getTreeEvidence(0, 0) == nil)
-- forest-family foliage share (the numbers from the forest screenshot: 24 + 22 + 12 + 8 forestPlants, 8 deco bush, 26 empty)
local rows = {
    { name = "<empty>", percent = 26 }, { name = "forestPlants L2", percent = 24 }, { name = "forestPlants L9", percent = 22 },
    { name = "forestPlants L5", percent = 12 }, { name = "decoBushUS L2", percent = 8 }, { name = "forestPlants L1", percent = 8 },
}
check("forest foliage: forestPlants of every level adds up (24 + 22 + 12 + 8 = 66)", WailaHud.forestFoliagePercent(rows) == 66)
check("forest foliage: that is over the verdict threshold", WailaHud.forestFoliagePercent(rows) >= WailaHud.FOREST_FOLIAGE_MIN_PERCENT)
check("forest foliage: a meadow (meadow L4, deco foliage, empty) is not forest", WailaHud.forestFoliagePercent({ { name = "meadow L4", percent = 77 }, { name = "decoFoliage L9", percent = 9 }, { name = "<empty>", percent = 14 } }) == 0)
check("forest foliage: no foliage data is 0, not an error", WailaHud.forestFoliagePercent(nil) == 0)
finish("hud_tree_test")
