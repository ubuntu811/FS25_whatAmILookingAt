dofile("tests/stubs.lua")

-- fake XMLFile: flat key -> value store with the iterator the store uses
local files = {}
local FakeXML = {}
FakeXML.__index = FakeXML
local function newFile(path, data) return setmetatable({ path = path, data = data or {} }, FakeXML) end
XMLFile = {
    create = function(_, path) return newFile(path) end,
    loadIfExists = function(_, path) return files[path] and newFile(path, files[path]) or nil end,
}
function FakeXML:setString(k, v) self.data[k] = tostring(v) end
function FakeXML:setFloat(k, v) self.data[k] = v end
function FakeXML:setBool(k, v) self.data[k] = v end
function FakeXML:getString(k) return self.data[k] end
function FakeXML:getFloat(k) return tonumber(self.data[k]) end
function FakeXML:getBool(k) return self.data[k] end
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
Logging = { info = function() end }
g_currentMission = { missionInfo = { savegameDirectory = "savegame" } }

dofile("scripts/WailaPathStore.lua")
local P = WailaPathStore
local function near(a, b, tolerance) return math.abs(a - b) <= tolerance end

-- adding
check("a path needs two points", P.add({ points = { { 0, 0 } } }) == nil)
local a = P.add({ points = { { 0, 0 }, { 100, 0 } }, kind = "imported", source = "TerraFarm", name = "north road", width = 6, oneWay = false })
local b = P.add({ points = { { 0, 3 }, { 100, 3 } }, oneWay = true })
check("ids are handed out in order", a == 1 and b == 2 and P.count() == 2)
check("fields are kept, defaults filled in", P.get(a).kind == "imported" and P.get(a).width == 6 and P.get(b).kind == "recorded" and P.get(b).width == 4)
local copyPoints = { { 0, 0 }, { 10, 0 } }
local c = P.add({ points = copyPoints })
copyPoints[1][1] = 999
check("the store keeps its own copy of the points", P.get(c).points[1][1] == 0)

-- finding paths near a point
local hits = P.findNear(50, 1, 5)
check("two lanes 3 m apart are both found, nearest first", #hits >= 2 and hits[1].id == a and hits[2].id == b)
check("the distance to a path is the distance to its closest point", near(hits[1].distance, 1, 1e-6) and near(hits[1].x, 50, 1e-6))
check("the direction is the path's own (east here), 'along' is metres from its start", near(hits[1].dx, 1, 1e-6) and near(hits[1].dz, 0, 1e-6) and near(hits[1].along, 50, 1e-6))
check("nothing beyond the radius", #P.findNear(50, 40, 5) == 0)
check("a point past the end snaps to the end point", near(P.findNear(120, 0, 30)[1].x, 100, 1e-6))
-- a path across several buckets (64 m) is found from any of them
local long = P.add({ points = { { 0, 500 }, { 400, 500 } } })
check("a long path is found from its far end", #P.findNear(390, 502, 5) == 1 and P.findNear(390, 502, 5)[1].id == long)
-- the direction follows the segment, not the whole path
local bend = P.add({ points = { { 1000, 0 }, { 1100, 0 }, { 1100, 100 } } })
local bh = P.findNear(1101, 60, 5)[1]
check("on the second leg the direction is that leg's (north)", bh.id == bend and near(bh.dz, 1, 1e-6) and near(bh.dx, 0, 1e-6) and near(bh.along, 160, 1e-6))

-- removing
check("remove takes it out of the list and the index", P.remove(c) == true and P.get(c) == nil and P.count() == 4)
check("removing twice is harmless", P.remove(c) == false)
local afterRemove = P.findNear(5, 0, 2)
check("a removed path is no longer found", #afterRemove == 1 and afterRemove[1].id == a)

-- the file
P.clear()
local one = P.add({ points = { { 0, 0 }, { 50.123, 0.5 }, { 120, 30 } }, kind = "imported", source = "TerraFarm", name = "a <b> & c", width = 7.5, oneWay = false })
local two = P.add({ points = { { 5, 5 }, { 105, 5 } }, oneWay = true, source = "RoadFollow" })
check("save succeeds", P.save() == true and files["savegame/wailaPaths.xml"] ~= nil)
P.clear()
check("cleared", P.count() == 0)
check("load succeeds", P.load() == true and P.count() == 2)
local l1, l2 = P.get(one), P.get(two)
check("ids, kind, source, name, width and direction flag survive", l1 ~= nil and l1.kind == "imported" and l1.source == "TerraFarm" and l1.name == "a <b> & c" and l1.width == 7.5 and l1.oneWay == false and l2.oneWay == true)
check("points survive to centimetres", #l1.points == 3 and near(l1.points[2][1], 50.12, 0.011) and near(l1.points[3][2], 30, 0.011))
check("the spatial index is rebuilt on load", #P.findNear(60, 5, 10) == 2 and P.findNear(60, 5, 10)[1].id == two)
local third = P.add({ points = { { 0, 0 }, { 9, 0 } } })
check("new ids continue after the loaded ones (no clash)", third == 3)
files["savegame/wailaPaths.xml"] = nil
check("no file: load says so, store is empty", P.load() == false and P.count() == 0)
-- transient paths (the map's splines) are never saved
P.clear()
local keep = P.add({ points = { { 0, 0 }, { 50, 0 } }, kind = "recorded" })
local transientId = P.add({ points = { { 0, 5 }, { 50, 5 } }, kind = "spline", transient = true })
check("a transient path is in the store", P.get(transientId).transient == true and P.count() == 2)
P.save()
P.clear()
P.load()
check("only the saved path comes back from the file", P.count() == 1 and P.get(keep) ~= nil)
check("clearing resets the spline-import flag", P.mapSplinesImported == false)
finish("path_store_test")
