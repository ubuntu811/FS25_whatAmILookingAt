dofile("tests/stubs.lua")
local T = loadTracer()
T.layerClassLearned = true

-- Synthetic chunk (0..64): forest disc r=18 at (30,30) with dirt flecks among grass;
-- an IW-style worn path (gravel material, 3m wide, (0,55)->(64,45)) whose LAYER signal is only dashes;
-- a road 4m wide along z=10.
local function world(x, z)
    if math.abs(z - 10) <= 2 then return T.LAYER_CLASS_ROAD, 7 end
    if (x - 30) ^ 2 + (z - 30) ^ 2 <= 18 * 18 then
        return T.LAYER_CLASS_FOREST, (math.floor(x / 3) % 4 == 0) and 1 or 2
    end
    local lz = 55 - (10 / 64) * x
    if math.abs(z - lz) <= 1.5 and x >= 0 and x <= 64 then
        return (math.floor(x / 6) % 3 == 0) and T.LAYER_CLASS_FOREST or nil, 6
    end
    return nil, 2
end
T.getLayerCellAt = world
T.scanRoadLayerChunk = function() return { { { 0, 8 }, { 64, 8 }, { 64, 12 }, { 0, 12 } } }, 1000 end

local r = T.scanLayerChunk(0, 0, 64)
check("chunk with content returns a result", r ~= nil)
check("forest: one polygon", #r.forest == 1)
local disc = math.pi * 18 * 18
check("forest area within 12% of the disc", math.abs(totalArea(r.forest) / disc - 1) < 0.12)
check("worn path becomes trail polygon(s)", #r.trail >= 1)
check("path is continuous, not dashes", #r.trail <= 2)
check("trail area plausible (3m x 64m minus the part by the disc)", totalArea(r.trail) > 192 * 0.6 and totalArea(r.trail) < 192 * 1.4)
local leak = false
for _, p in ipairs(r.trail) do
    local cx, cz = 0, 0
    for _, q in ipairs(p) do cx, cz = cx + q[1], cz + q[2] end
    cx, cz = cx / #p, cz / #p
    if (cx - 30) ^ 2 + (cz - 30) ^ 2 < 14 * 14 then leak = true end
end
check("forest-floor dirt inside the area is not a trail", not leak)
check("road comes from the road pass", #r.road == 1)
local points = 0
for _, list in ipairs({ r.forest, r.trail }) do for _, p in ipairs(list) do points = points + #p end end
check("few points (curve fit)", points < 150)
T.getLayerCellAt = function() return nil, 2 end
check("empty chunk returns nil", T.scanLayerChunk(1000, 1000, 64) == nil)
finish("layer_scan_test")
