dofile("tests/stubs.lua")
-- fake XMLFile: a flat key -> string store, with the tiny API the tracer uses
local files = {}
local FakeXML = {}
FakeXML.__index = FakeXML
local function newFile(path, data) return setmetatable({ path = path, data = data or {} }, FakeXML) end
XMLFile = {
    create = function(_, path) return newFile(path) end,
    loadIfExists = function(_, path) return files[path] and newFile(path, files[path]) or nil end,
}
function FakeXML:setString(key, value) self.data[key] = value end
function FakeXML:getString(key) return self.data[key] end
function FakeXML:save() files[self.path] = self.data end
function FakeXML:delete() end
function FakeXML:iterator(prefix)
    local seen, order = {}, {}
    for key in pairs(self.data) do
        local escaped = prefix:gsub("%p", "%%%0")
        local index = key:match("^" .. escaped .. "%((%d+)%)")
        if index and not seen[index] then seen[index] = true order[#order + 1] = tonumber(index) end
    end
    table.sort(order)
    local i = 0
    return function()
        i = i + 1
        if order[i] then return i, string.format("%s(%d)", prefix, order[i]) end
    end
end
function string.split(s, sep)
    local out = {}
    for token in s:gmatch("[^" .. sep .. "]+") do out[#out + 1] = token end
    return out
end
g_currentMission.missionInfo = { savegameDirectory = "savegame" }

local T = loadTracer()
local drawn = { forest = 0, trail = 0, road = 0, building = 0 }
T.buildForestOverlayIncremental = function(p) drawn.forest = drawn.forest + #p end
T.buildTestOverlay = function(p) for _, list in pairs(p) do drawn.trail = drawn.trail + #list end end
T.buildRoadLayerOverlayIncremental = function(p) drawn.road = drawn.road + #p end
T.buildBuildingLayerOverlayIncremental = function(p) drawn.building = drawn.building + #p end

local square = { { 0, 0 }, { 8, 0 }, { 8, 8 }, { 0, 8 } }
T.savedRegions = { forest = {}, road = {}, building = {} }
T.savedRegionsByMaterial = { [1] = {}, [6] = {}, [7] = {} }
T.recordRegionPolygons("forest", 0, 0, 64, 64, { square, square })
T.recordRegionPolygons("road", 0, 0, 64, 64, { square })
T.recordRegionPolygons("road", 64, 0, 128, 64, { square, square, square })
T.recordRegionPolygons("building", 0, 0, 64, 64, { square, square, square, square, square })
T.recordRegionPolygons("building", 64, 64, 128, 128, {})   -- an empty rescan stores nothing
T.recordScannedPolygons(0, 0, 64, 64, { [6] = { square } })

local ok = T.startSaveToXML()
check("save starts", ok == true)
local guard = 0
while T.saveState ~= nil and guard < 1000 do T.tickSaveToXML() guard = guard + 1 end
check("save finishes", T.saveState == nil)

T.savedRegions, T.savedRegionsByMaterial = { forest = {}, road = {}, building = {} }, { [1] = {}, [6] = {}, [7] = {} }
T.startLoadFromXML()
check("load starts", T.loadState ~= nil)
guard = 0
while T.loadState ~= nil and guard < 1000 do T.tickLoadFromXML() guard = guard + 1 end
check("load finishes", T.loadState == nil)
local roadRegions, roadPolygons = 0, 0
for _, polygons in pairs(T.savedRegions.road) do roadRegions = roadRegions + 1 roadPolygons = roadPolygons + #polygons end
check("road regions restored (2 regions, 4 polygons)", roadRegions == 2 and roadPolygons == 4)
local forestPolygons = 0
for _, polygons in pairs(T.savedRegions.forest) do forestPolygons = forestPolygons + #polygons end
check("forest restored (2 polygons)", forestPolygons == 2)
local trailPolygons = 0
for _, polygons in pairs(T.savedRegionsByMaterial[6]) do trailPolygons = trailPolygons + #polygons end
check("trail restored (1 polygon, stored final, no smoothing on load)", trailPolygons == 1 and #T.savedRegionsByMaterial[6]["0.0_0.0_64.0_64.0"][1] == 4)
local buildingPolygons = 0
for _, polygons in pairs(T.savedRegions.building) do buildingPolygons = buildingPolygons + #polygons end
check("building restored (5 polygons, the empty region was not stored)", buildingPolygons == 5)
check("overlays were fed on load", drawn.forest == 2 and drawn.road == 4 and drawn.trail == 1 and drawn.building == 5)
finish("persistence_test")
