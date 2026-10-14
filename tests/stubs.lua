-- Engine stubs so the real WailaTrailTracer.lua and WailaLayerScan.lua load and run under plain Lua 5.1.
Logging = { info = function() end }
CollisionFlag = { TREE = 1, WATER = 2, VEHICLE_FORK = 4, STATIC_OBJECT = 8, DYNAMIC_OBJECT = 16, BUILDING = 32, ROAD = 64, ANIMAL = 128 }
local function bitop(a, b, both)
    local result, bit = 0, 1
    while a > 0 or b > 0 do
        local x, y = a % 2 == 1, b % 2 == 1
        if (both and (x and y)) or (not both and (x or y)) then result = result + bit end
        a, b, bit = (a - a % 2) / 2, (b - b % 2) / 2, bit * 2
    end
    return result
end
bit32 = { band = function(a, b) return bitop(a, b, true) end, bor = function(a, b) return bitop(a, b, false) end }
math.clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end
MathUtil = {
    vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
    getDistanceToLineSegment2D = function(ax, az, bx, bz, px, pz)
        local dx, dz = bx - ax, bz - az
        local t = math.max(0, math.min(1, ((px - ax) * dx + (pz - az) * dz) / (dx * dx + dz * dz)))
        return math.sqrt((px - ax - t * dx) ^ 2 + (pz - az - t * dz) ^ 2)
    end,
}
WailaUtil = { safeCall = function(_, f, ...) return f(...) end }
g_currentMission = { terrainSize = 4096 }
FSDensityMapUtil = { getFieldDataAtWorldPosition = function() return false end }
getTimeSec = os.clock

function loadTracer()
    dofile("scripts/WailaTrailTracer.lua")
    dofile("scripts/WailaLayerScan.lua")
    return WailaTrailTracer
end

local failures, total = 0, 0
function check(name, condition)
    total = total + 1
    if not condition then failures = failures + 1 end
    print((condition and "  PASS " or "  FAIL ") .. name)
end
function finish(suite)
    print(string.format("%s: %d/%d passed", suite, total - failures, total))
    if failures > 0 then os.exit(1) end
end

-- polygon helpers
function polygonArea(poly)
    local s = 0
    for i = 1, #poly do
        local a, b = poly[i], poly[i % #poly + 1]
        s = s + a[1] * b[2] - b[1] * a[2]
    end
    return math.abs(s) / 2
end
function totalArea(list)
    local s = 0
    for _, p in ipairs(list) do s = s + polygonArea(p) end
    return s
end
