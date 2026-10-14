dofile("tests/stubs.lua")
local T = loadTracer()
local drawn
T.buildTestOverlay = function(polygons) drawn = polygons end
local function dash(cx, cz, len, w, a)
    local ux, uz = math.cos(a), math.sin(a)
    local pts = {}
    for _, s in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
        pts[#pts + 1] = { cx + ux * s[1] * len / 2 - uz * s[2] * w / 2, cz + uz * s[1] * len / 2 + ux * s[2] * w / 2 }
    end
    return pts
end
local store = { ["0_0"] = {}, ["1_0"] = {} }
T.savedRegionsByMaterial = { [6] = store }
local a = math.rad(80)
for i = 0, 9 do
    table.insert(i < 5 and store["0_0"] or store["1_0"], dash(100 + math.cos(a) * 28 * i, 200 + math.sin(a) * 28 * i, 8, 3, a))
end
table.insert(store["0_0"], dash(100 + math.cos(a) * 28 * 3 + 12, 200 + math.sin(a) * 28 * 3, 8, 3, a + math.pi / 2))
table.insert(store["0_0"], dash(300, 300, 3, 3, 0))
table.insert(store["1_0"], dash(500, 500, 8, 3, a))
local n = T.linkTrailFragments()
check("9 links between the 10 aligned dashes across two chunks", n == 9)
check("bridges stored under the links key", store.links ~= nil and #store.links == n)
local b = store.links[1]
check("bridge is the narrow 1.5m ribbon", math.abs(math.sqrt((b[1][1] - b[4][1]) ^ 2 + (b[1][2] - b[4][2]) ^ 2) - 1.5) < 0.05)
check("bridges drawn", drawn ~= nil and #drawn[6] == n)
check("second run replaces, not doubles", T.linkTrailFragments() == n)
finish("link_test")
