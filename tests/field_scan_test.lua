dofile("tests/stubs.lua")

-- engine stubs the field scanner needs beyond the shared ones
Class = function(c) return { __index = c } end
Waila = { debugFieldTracing = false }
local function inside(vertices, x, z)
    local c, n = false, #vertices / 2
    local j = n
    for i = 1, n do
        local xi, zi, xj, zj = vertices[2 * i - 1], vertices[2 * i], vertices[2 * j - 1], vertices[2 * j]
        if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then c = not c end
        j = i
    end
    return c
end
Polygon2D = {}
Polygon2D.__index = Polygon2D
function Polygon2D.new(_, vertices) return setmetatable({ v = vertices }, Polygon2D) end
function Polygon2D:getVertices() return self.v end
function Polygon2D:getIsPosInside(x, z) return inside(self.v, x, z) end
function Polygon2D:getBoundingBox()
    local a, b, c, d = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, #self.v, 2 do
        a, b = math.min(a, self.v[i]), math.max(b, self.v[i])
        c, d = math.min(c, self.v[i + 1]), math.max(d, self.v[i + 1])
    end
    return a, b, c, d
end
function Polygon2D:getArea()
    local s, n = 0, #self.v / 2
    for i = 1, n do
        local j = i % n + 1
        s = s + self.v[2 * i - 1] * self.v[2 * j] - self.v[2 * j - 1] * self.v[2 * i]
    end
    return math.abs(s) / 2
end
function Polygon2D:getOffsetPolygon() return nil end
function WailaUtil.getIsPosInsidePolygon(p, x, z) return p ~= nil and p:getIsPosInside(x, z) end
g_currentMission = { terrainSize = 512, fieldGroundSystem = { getDensityMapData = function() return 1 end } }
FieldDensityMap = { GROUND_TYPE = 1 }
getDensityMapSize = function() return 512 end

MathUtil.vector2Normalize = function(x, z) local l = math.sqrt(x * x + z * z); if l == 0 then return 0, 0 end return x / l, z / l end

-- field: a 200 m square with a 120 m hole in the middle, its south-west
-- corner cut away so the FIRST cell the row-major seed scan meets sits
-- right below the hole (its +z walk runs into the hole, not out of the
-- field), plus a separate plain 60 x 60 field
local function isField(x, z)
    local inBig = math.abs(x) <= 100 and math.abs(z) <= 100
    local inHole = math.abs(x) <= 60 and math.abs(z) <= 60
    local notch = x <= -70 and z <= -70
    local inSmall = x >= 150 and x <= 210 and z >= -30 and z <= 30
    return (inBig and not inHole and not notch) or inSmall
end
FSDensityMapUtil = { getFieldDataAtWorldPosition = function(x, _, z) return isField(x, z) end }

dofile("scripts/WailaFieldBoundaryTracer.lua")
dofile("scripts/WailaFieldGridScanner.lua")

local scanner = WailaFieldGridScanner.new()
local found, done, guard = {}, false, 0
while not done and guard < 200000 do
    guard = guard + 1
    local lx, lz, _, _, area, _, completed, polygon = scanner:update(0.05)
    if lx ~= nil then table.insert(found, { x = lx, z = lz, area = area, polygon = polygon }) end
    done = completed
    if lx ~= nil and completed then table.remove(found) end -- first result of the NEXT pass
end

for i, f in ipairs(found) do print(string.format("    found %d: area=%.0f label=(%.0f,%.0f)", i, f.area, f.x, f.z)) end
check("sweep finishes", done)
check("two fields: one ring, one plain (not the hole, not repeats)", #found == 2)
local ringArea, smallArea = 200 * 200 - 120 * 120 - 30 * 30, 60 * 60
local sawRing, sawSmall = false, false
for _, f in ipairs(found) do
    if math.abs(f.area - ringArea) / ringArea < 0.1 or math.abs(f.area - 200 * 200) / (200 * 200) < 0.1 then sawRing = true end
    if math.abs(f.area - smallArea) / smallArea < 0.1 then sawSmall = true end
end
check("the ring field outline was found", sawRing)
check("the small field was found", sawSmall)
finish("field_scan_test")
