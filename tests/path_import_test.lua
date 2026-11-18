dofile("tests/stubs.lua")
local T = loadTracer()   -- loads the path store, the tracer and the layer scan (which defines the spline import)

-- two fake road splines: 101 runs east at z = 0 (100 m), 102 runs north at x = 200 (40 m)
local splines = {
    [101] = { length = 100, at = function(t) return t * 100, 0 end },
    [102] = { length = 40, at = function(t) return 200, t * 40 end },
}
getSplineLength = function(id) return splines[id].length end
getSplinePosition = function(id, t) local x, z = splines[id].at(t) return x, 0, z end
local AiSystem = {}
AiSystem.__index = AiSystem
function AiSystem:getRoadSplines() return { [101] = true, [102] = true } end
g_currentMission.aiSystem = setmetatable({}, AiSystem)

WailaPathStore.clear()
local n = WailaPathStore.importMapSplines()
check("both splines become paths", n == 2 and WailaPathStore.count() == 2)
local hit = WailaPathStore.findNear(50, 1, 5)[1]
check("a spline path is kind spline, source map, transient, two-way", hit.path.kind == "spline" and hit.path.source == "map" and hit.path.transient == true and hit.path.oneWay == false)
check("the spline's own direction is kept (east here)", math.abs(hit.dx - 1) < 1e-6)
local north = WailaPathStore.findNear(201, 20, 5)[1]
check("the second runs north", math.abs(north.dz - 1) < 1e-6 and math.abs(north.dx) < 1e-6)
check("points are about 4 m apart", #hit.path.points >= 25 and #hit.path.points <= 27)
check("a second import does nothing (once per session)", WailaPathStore.importMapSplines() == 0 and WailaPathStore.count() == 2)
WailaPathStore.clear()
g_currentMission.aiSystem = nil
check("no AI system: nothing imported, no error", WailaPathStore.importMapSplines() == 0)
finish("path_import_test")
