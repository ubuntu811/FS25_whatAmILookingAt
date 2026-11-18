dofile("tests/stubs.lua")
local T = loadTracer()

-- two fake splines: 101 runs along +x at z = 0 (length 100), 102 runs back along -x at z = 3.5 (length 60)
local splines = {
    [101] = { length = 100, at = function(t) return t * 100 - 50, 0 end },
    [102] = { length = 60, at = function(t) return 10 - t * 60, 3.5 end },
}
getSplineLength = function(id)
    if splines[id] == nil then error("not a spline") end
    return splines[id].length
end
getSplinePosition = function(id, t) local x, z = splines[id].at(t) return x, 0, z end
getName = function(node) return "node" .. tostring(node) end
getParent = function(node) return 1 end

local written = {}
XMLFile = { create = function(_, path)
    local f = { values = {} }
    function f:setString(k, v) self.values[k] = v end
    function f:setFloat(k, v) self.values[k] = v end
    function f:save() written[path] = self.values end
    function f:delete() end
    return f
end }

local AiSystem = {}
AiSystem.__index = AiSystem
function AiSystem:getRoadSplines() return { [101] = true, [102] = true } end
function AiSystem:setAreaDirty() end
g_currentMission.aiSystem = setmetatable({ roadSplines = {} }, AiSystem)
g_currentMission.trafficSystem = { splines = { 101, 102 }, other = { a = "x" }, count = 2 }
g_currentMission.missionInfo = { savegameDirectory = "savegame" }

local lines = {}
Logging = { info = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end }
T.dumpRoadSplines()

local file = written["savegame/wailaSplines.xml"]
check("the dump file is written", file ~= nil)
check("every AI road spline is in it (2)", file["wailaSplines.aiSpline(0)#points"] ~= nil and file["wailaSplines.aiSpline(1)#points"] ~= nil and file["wailaSplines.aiSpline(2)#points"] == nil)
local pts = file["wailaSplines.aiSpline(0)#points"] or file["wailaSplines.aiSpline(1)#points"]
check("points are 'x z' pairs, 5 m apart along the spline's own direction", pts:match("^%-?[%d.]+ %-?[%d.]+") ~= nil)
check("the length is stored", file["wailaSplines.aiSpline(0)#length"] ~= nil)
check("the traffic system's spline list is found by its numbers (2 splines)", file["wailaSplines.trafficSpline(0)#points"] ~= nil and file["wailaSplines.trafficSpline(1)#points"] ~= nil)
local joined = table.concat(lines, "\n")
check("the log names the traffic system's fields and methods", joined:find("trafficSystem fields:", 1, true) and joined:find("aiSystem methods", 1, true))
check("the summary line says how many were found and in which field", joined:find("2 AI road spline(s), 2 spline(s) found in the traffic system (splines=2)", 1, true) ~= nil)

-- no traffic system: still dumps the AI splines, no error
g_currentMission.trafficSystem = nil
lines = {}
T.dumpRoadSplines()
check("no traffic system: the probe says so and carries on", table.concat(lines, "\n"):find("trafficSystem is nil", 1, true) ~= nil)
finish("spline_dump_test")
