dofile("tests/stubs.lua")
-- fake i3d nodes: id -> world position, rotation about Y (radians)
local nodes = {}
local function node(id, x, y, z, rot) nodes[id] = { x = x, y = y, z = z, rot = rot or 0 } return id end
entityExists = function(id) return nodes[id] ~= nil end
getWorldTranslation = function(id) local n = nodes[id] return n.x, n.y, n.z end
worldToLocal = function(id, x, y, z)
    local n = nodes[id]
    local dx, dz = x - n.x, z - n.z
    local c, s = math.cos(-n.rot), math.sin(-n.rot)
    return dx * c + dz * s, y - n.y, -dx * s + dz * c
end
localToWorld = function(id, lx, ly, lz)
    local n = nodes[id]
    local c, s = math.cos(n.rot), math.sin(n.rot)
    return n.x + lx * c + lz * s, n.y + ly, n.z - lx * s + lz * c
end
dofile("scripts/WailaPlaceableProbe.lua")
local P = WailaPlaceableProbe

-- start + width + height: a 10 x 6 rectangle at (100, 200)
local rect = P.areaCorners({ startNode = node(1, 100, 0, 200), widthNode = node(2, 110, 0, 200), heightNode = node(3, 100, 0, 206) })
check("start+width+height: 4 corners", rect ~= nil and #rect == 4)
check("start+width+height: area 60", math.abs(polygonArea(rect) - 60) < 1e-6)

-- start + end in an axis-aligned frame: 20 x 8
local rect2 = P.areaCorners({ startNode = node(4, 0, 0, 0), endNode = node(5, 20, 0, 8) })
check("start+end: area 160", rect2 ~= nil and math.abs(polygonArea(rect2) - 160) < 1e-6)

-- start + end in a ROTATED frame (45 degrees): same rectangle size, rotated corners
node(6, 50, 0, 50, math.rad(45))
local ex, ez = (function() local x, _, z = localToWorld(6, 20, 0, 8) return x, z end)()
node(7, ex, 0, ez)
local rect3 = P.areaCorners({ startNode = 6, endNode = 7 })
check("rotated start+end: area still 160", rect3 ~= nil and math.abs(polygonArea(rect3) - 160) < 1e-6)

-- missing nodes -> nil
check("area with a dead node is skipped", P.areaCorners({ startNode = 1, endNode = 999 }) == nil)

-- collectAreas finds areas nested in specs, ignores non-spec tables, survives cycles
local placeable = {
    rootNode = 1,
    spec_placement = { testAreas = { { startNode = 4, endNode = 5 }, { startNode = 1, widthNode = 2, heightNode = 3 } } },
    spec_other = { deep = { deeper = { startNode = 1, endNode = 5 } } },
    notASpec = { startNode = 1, endNode = 5 },
}
placeable.spec_placement.self = placeable.spec_placement   -- cycle
local found = P.collectAreas(placeable)
check("collectAreas: three areas in two specs, the non-spec table ignored", #found == 3)
local paths = {}
for _, f in ipairs(found) do paths[#paths + 1] = f.path end
table.sort(paths)
check("collectAreas: reports where each came from", paths[1]:find("spec_other") ~= nil and paths[2]:find("spec_placement") ~= nil)

-- collision bodies: only static / building bodies that have a rigid body count
local tree = {
    [100] = { name = "root", children = { 101, 102, 103, 104 } },
    [101] = { name = "wallA", flags = { STATIC_OBJECT = true }, aabb = { 10, 30, 0, 5, 10, 18 } },
    [102] = { name = "decoration", flags = {}, aabb = { 0, 3, 0, 3, 0, 3 } },
    [103] = { name = "wallB", flags = { BUILDING = true }, aabb = { 30, 36, 0, 4, 10, 24 } },
    [104] = { name = "static but no rigid body", flags = { STATIC_OBJECT = true } },
}
CollisionFlag.getHasGroupFlagSet = function(id, flag) return tree[id].flags[(flag == CollisionFlag.BUILDING) and "BUILDING" or "STATIC_OBJECT"] == true end
getName = function(id) return tree[id].name end
getNumOfChildren = function(id) return #(tree[id].children or {}) end
getChildAt = function(id, index) return tree[id].children[index + 1] end
-- engine order: minX, maxX, minY, maxY, minZ, maxZ
getRigidBodyAABB = function(id) if tree[id].aabb then return unpack(tree[id].aabb) end end
local boxes = P.collectShapeBoxes(100)
check("collision bodies: the two static/building bodies, not the decoration or the body-less node", #boxes == 2)
local areaSum = 0
for _, b in ipairs(boxes) do areaSum = areaSum + polygonArea(b.corners) end
check("collision bodies: world areas 20x8 + 6x14", math.abs(areaSum - (160 + 84)) < 1e-6)
check("collision bodies: corners are already in world space", math.abs(boxes[1].corners[1][1] - 10) < 1e-6 and math.abs(boxes[1].corners[1][2] - 10) < 1e-6)
finish("placeable_probe_test")
