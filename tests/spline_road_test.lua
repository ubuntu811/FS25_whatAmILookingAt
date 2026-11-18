dofile("tests/stubs.lua")
local T = loadTracer()

-- a straight road along x, z = 10, from x = -100 to 100, one point every 6 m
local chain = {}
for x = -100, 100, 6 do table.insert(chain, { x, 10 }) end
local byChunk = T.ribbonsFromChains({ chain }, 6.0, -256, -256, 64)

local chunks, pieces, total = 0, 0, 0
for key, polys in pairs(byChunk) do
    chunks = chunks + 1
    for _, p in ipairs(polys) do pieces = pieces + 1; total = total + polygonArea(p) end
end
check("road crossing chunk borders is cut into several chunks", chunks >= 3)
check("one piece per chunk for a straight road", pieces == chunks)
local expected = 200 * 6.0
check("ribbon area is length x width (+ small seam overlaps)", total >= expected * 0.95 and total <= expected * 1.25)

-- every vertex of a piece lies within half the width of the road line
local worst = 0
for _, polys in pairs(byChunk) do
    for _, p in ipairs(polys) do
        for _, v in ipairs(p) do worst = math.max(worst, math.abs(v[2] - 10)) end
    end
end
check("ribbon stays within half the width of the centre line", worst <= 3.0 + 1e-6)

-- a curved road still gives closed, positive-area ribbons
local arc = {}
for i = 0, 40 do
    local a = i / 40 * math.pi
    table.insert(arc, { 80 * math.cos(a), 80 * math.sin(a) })
end
local arcRibbons = T.ribbonsFromChains({ arc }, 6.0, -256, -256, 64)
local arcArea = 0
for _, polys in pairs(arcRibbons) do for _, p in ipairs(polys) do arcArea = arcArea + polygonArea(p) end end
local arcLength = math.pi * 80
check("curved road: ribbon area close to length x width", arcArea > arcLength * 6 * 0.9 and arcArea < arcLength * 6 * 1.3)
check("a one-point chain gives nothing", next(T.ribbonsFromChains({ { { 0, 0 } } }, 6.0, -256, -256, 64)) == nil)
finish("spline_road_test")
