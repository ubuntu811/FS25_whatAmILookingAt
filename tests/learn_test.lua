dofile("tests/stubs.lua")
local T = loadTracer()

-- (samples of 1000, whole-map share)
local function road(samples, mapShare) return (T.isRoadLayerStat(samples, 1000, mapShare)) end
check("main road paint (45% of splines, 2% of map)", road(450, 0.02))
check("main paint that is everywhere is not road", not road(450, 0.30))
check("road shoulder: 6% of splines, 0.5% of map", road(60, 0.005))
check("rock layer: 6% of splines but 20% of map", not road(60, 0.20))
check("weakly enriched layer (6% of splines, 3% of map) stays out", not road(60, 0.03))
check("a handful of samples is noise, however rare the layer", not road(8, 0.0001))
check("1% of splines is below the share floor", not road(10, 0.0001))
finish("learn_test")
