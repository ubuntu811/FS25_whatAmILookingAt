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
local drawn = { forest = 0, trail = 0, road = 0, building = 0, water = 0 }
T.buildForestOverlayIncremental = function(p) drawn.forest = drawn.forest + #p end
T.buildTestOverlay = function(p) for _, list in pairs(p) do drawn.trail = drawn.trail + #list end end
T.buildRoadLayerOverlayIncremental = function(p) drawn.road = drawn.road + #p end
T.buildBuildingLayerOverlayIncremental = function(p) drawn.building = drawn.building + #p end
T.buildWaterLayerOverlayIncremental = function(p) drawn.water = drawn.water + #p end

local square = { { 0, 0 }, { 8, 0 }, { 8, 8 }, { 0, 8 } }
T.savedRegions = { forest = {}, water = {}, road = {}, building = {} }
T.savedRegionsByMaterial = { [1] = {}, [6] = {}, [7] = {} }
T.recordRegionPolygons("forest", 0, 0, 64, 64, { square, square })
T.recordRegionPolygons("road", 0, 0, 64, 64, { square })
T.recordRegionPolygons("road", 64, 0, 128, 64, { square, square, square })
T.recordRegionPolygons("building", 0, 0, 64, 64, { square, square, square, square, square })
T.recordRegionPolygons("water", 0, 0, 64, 64, { square, square })
T.recordRegionPolygons("building", 64, 64, 128, 128, {})   -- an empty rescan stores nothing
T.recordScannedPolygons(0, 0, 64, 64, { [6] = { square } })

local ok = T.startSaveToXML()
check("save starts", ok == true)
local guard = 0
while T.saveState ~= nil and guard < 1000 do T.tickSaveToXML() guard = guard + 1 end
check("save finishes", T.saveState == nil)

T.savedRegions, T.savedRegionsByMaterial = { forest = {}, water = {}, road = {}, building = {} }, { [1] = {}, [6] = {}, [7] = {} }
T.LOAD_START_DELAY_SEC = 0
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
local waterPolygons = 0
for _, polygons in pairs(T.savedRegions.water) do waterPolygons = waterPolygons + #polygons end
check("water restored (2 polygons)", waterPolygons == 2)
check("overlays were fed on load", drawn.forest == 2 and drawn.road == 4 and drawn.trail == 1 and drawn.building == 5 and drawn.water == 2)

-- the restore waits out the post-load delay: nothing happens before it, then it runs
T.LOAD_START_DELAY_SEC = 3600
T.startLoadFromXML()
local before = T.tickLoadFromXML()
check("with a start delay the restore has not started (still queued)", T.loadState ~= nil and before == false)
T.loadState.notBefore = 0
guard = 0
while T.loadState ~= nil and guard < 1000 do T.tickLoadFromXML() guard = guard + 1 end
check("...and finishes once the delay is over", T.loadState == nil)

-- quitting while the save / restore is still running
T.recordRegionPolygons("forest", 128, 0, 192, 64, { square, square, square })
T.startSaveToXML()
T.tickSaveToXML()
local pendingBefore = T.saveState ~= nil
T.flushPendingIO()
check("teardown flush: an unfinished save is completed", T.saveState == nil)
T.LOAD_START_DELAY_SEC = 0
T.startLoadFromXML()
T.flushPendingIO()
check("teardown flush: a restore in flight is closed", T.loadState == nil)
check("teardown flush: nothing pending is a no-op", pcall(T.flushPendingIO))

-- ===== layer images =====
local disk = {}
fileExists = function(path) return disk[path] ~= nil end
createBitVectorMap = function(name) return { name = name } end
saveBitVectorMapToFile = function(map, path) disk[path] = { w = map.w, h = map.h, ch = map.ch, tag = map.tag } end
loadBitVectorMapFromFile = function(map, path, channels)
    local d = disk[path]
    if not d then return false end
    map.w, map.h, map.ch, map.tag = d.w, d.h, channels, d.tag
    return true
end
getBitVectorMapSize = function(map) return map.w, map.h end
createDensityMapVisualizationOverlay = function(name) return { name = name } end
resetDensityMapVisualizationOverlay = function() end
setDensityMapVisualizationOverlayStateColor = function() end
generateDensityMapVisualizationOverlay = function() end
T.IMAGE_SAVE_INTERVAL_SEC = 0
T.IMAGE_LOAD_DELAY_SEC = 0
T.LOAD_START_DELAY_SEC = 0

local function resetMaps()
    for _, field in ipairs({ "forestOverlayMap", "forestOverlay", "testOverlayMap", "testOverlay", "roadLayerOverlayMap", "roadLayerOverlay",
        "buildingLayerOverlayMap", "buildingLayerOverlay", "waterLayerOverlayMap", "waterLayerOverlay", "treeLayerOverlayMap", "treeLayerOverlay" }) do
        T[field] = nil
    end
end
resetMaps()
T.forestOverlayMap = { w = 2048, h = 2048, ch = 2, tag = "forest-data" }
T.roadLayerOverlayMap = { w = 2048, h = 2048, ch = 1, tag = "road-data" }
T.treeLayerOverlayMap = { w = 2048, h = 2048, ch = 1, tag = "tree-data" }

check("image save starts when layers exist", T.startImageSave() == true)
check("...and a second start while it runs is refused", T.startImageSave() == false)
guard = 0
while T.imageSaveState ~= nil and guard < 100 do T.tickImageSave() guard = guard + 1 end
check("image save finishes", T.imageSaveState == nil)
check("one file per existing layer (forest, road, tree), none for the others",
    disk["savegame/wailaLayer_forest.grle"] ~= nil and disk["savegame/wailaLayer_road.grle"] ~= nil and disk["savegame/wailaLayer_tree.grle"] ~= nil
    and disk["savegame/wailaLayer_water.grle"] == nil and disk["savegame/wailaLayer_trail.grle"] == nil)
resetMaps()
check("no layers, nothing to save", T.startImageSave() == false)

-- restore: layers with an image come from it, the polygon store still loads, only the rest is drawn
for key in pairs(drawn) do drawn[key] = 0 end
T.savedRegions, T.savedRegionsByMaterial = { forest = {}, water = {}, road = {}, building = {} }, { [1] = {}, [6] = {}, [7] = {} }
T.startLoadFromXML()
check("restore with images: queued", T.loadState ~= nil and #T.loadState.images.queue == 3)
guard = 0
while T.loadState ~= nil and guard < 1000 do T.tickLoadFromXML() guard = guard + 1 end
check("restore finishes", T.loadState == nil)
check("forest comes back from its image (the saved data, 2 channels)", T.forestOverlayMap ~= nil and T.forestOverlayMap.tag == "forest-data" and T.forestOverlayMap.ch == 2 and T.forestOverlay ~= nil)
check("road and trees come back from their images", T.roadLayerOverlayMap.tag == "road-data" and T.treeLayerOverlayMap.tag == "tree-data" and T.treeLayerOverlay ~= nil)
check("polygons of a restored layer are NOT drawn again (forest, road)", drawn.forest == 0 and drawn.road == 0)
check("a layer without an image is still drawn from its polygons (building)", drawn.building == 5)
local forestStored = 0
for _, polygons in pairs(T.savedRegions.forest) do forestStored = forestStored + #polygons end
check("the polygon store is loaded all the same (trail linking reads it)", forestStored >= 2)

-- a bad image falls back to the polygons
resetMaps()
disk["savegame/wailaLayer_forest.grle"].w = 512
for key in pairs(drawn) do drawn[key] = 0 end
T.savedRegions, T.savedRegionsByMaterial = { forest = {}, water = {}, road = {}, building = {} }, { [1] = {}, [6] = {}, [7] = {} }
T.startLoadFromXML()
guard = 0
while T.loadState ~= nil and guard < 1000 do T.tickLoadFromXML() guard = guard + 1 end
check("wrong-size image is rejected and the forest is drawn from its polygons", T.forestOverlayMap == nil and drawn.forest >= 2)
check("...while the good images are still used", T.roadLayerOverlayMap ~= nil and drawn.road == 0)

-- teardown writes what is still queued
resetMaps()
disk = {}
T.roadLayerOverlayMap = { w = 2048, h = 2048, ch = 1, tag = "road-2" }
T.startImageSave()
T.flushPendingIO()
check("teardown flush: queued images are written", T.imageSaveState == nil and disk["savegame/wailaLayer_road.grle"] ~= nil and disk["savegame/wailaLayer_road.grle"].tag == "road-2")
finish("persistence_test")
