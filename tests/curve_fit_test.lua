dofile("tests/stubs.lua")
local T = loadTracer()
local fit = T.fitLoopCurves
local bounds = { minX = -1000, minZ = -1000, maxX = 1000, maxZ = 1000 }
local function ring(inside, x0, x1, z0, z1)
    local function ins(x, z) return inside(x + 0.5, z + 0.5) end
    local nxt = {}
    local function key(x, z) return x .. "," .. z end
    for x = x0, x1 do for z = z0, z1 do if ins(x, z) then
        if not ins(x, z - 1) then nxt[key(x, z)] = { x + 1, z } end
        if not ins(x + 1, z) then nxt[key(x + 1, z)] = nxt[key(x + 1, z)] or { x + 1, z + 1 } end
        if not ins(x, z + 1) then nxt[key(x + 1, z + 1)] = nxt[key(x + 1, z + 1)] or { x, z + 1 } end
        if not ins(x - 1, z) then nxt[key(x, z + 1)] = nxt[key(x, z + 1)] or { x, z } end
    end end end
    local sk
    for k in pairs(nxt) do sk = k break end
    local sx, sz = sk:match("(-?%d+),(-?%d+)")
    sx, sz = tonumber(sx), tonumber(sz)
    local r, cx, cz = { { sx, sz } }, sx, sz
    for _ = 1, 100000 do
        local v = nxt[key(cx, cz)]
        if not v then break end
        cx, cz = v[1], v[2]
        if cx == sx and cz == sz then break end
        r[#r + 1] = { cx, cz }
    end
    return r
end
local function maxDeviation(raw, poly)
    local worst = 0
    for _, p in ipairs(raw) do
        local best = 1e9
        for i = 1, #poly do
            local a, b = poly[i], poly[i % #poly + 1]
            local dx, dz = b[1] - a[1], b[2] - a[2]
            local l2 = dx * dx + dz * dz
            local t = l2 > 0 and math.max(0, math.min(1, ((p[1] - a[1]) * dx + (p[2] - a[2]) * dz) / l2)) or 0
            best = math.min(best, math.sqrt((p[1] - a[1] - t * dx) ^ 2 + (p[2] - a[2] - t * dz) ^ 2))
        end
        worst = math.max(worst, best)
    end
    return worst
end

local disc = ring(function(x, z) return (x - 50) ^ 2 + (z - 50) ^ 2 <= 400 end, 20, 80, 20, 80)
local f = fit(disc, bounds, 1.5)
check("disc: far fewer points than the raw staircase", f ~= nil and #f < #disc * 0.25)
check("disc: stays within tolerance of the raw loop", maxDeviation(disc, f) <= 2.2)
check("disc: area preserved", math.abs(polygonArea(f) / polygonArea(disc) - 1) < 0.03)

local strip = ring(function(x, z) return math.abs(x - z) <= 2.1 and x >= 10 and x <= 60 end, 5, 70, 5, 70)
local fs = fit(strip, bounds, 0.8)
check("trail strip: 3x fewer points, within 1.3m", fs ~= nil and #fs * 3 < #strip and maxDeviation(strip, fs) <= 1.3)

local lshape = ring(function(x, z) return (x >= 30 and x < 70 and z >= 30 and z < 50) or (x >= 30 and x < 50 and z >= 30 and z < 70) end, 20, 80, 20, 80)
local fl = fit(lshape, bounds, 1.5)
local hits = 0
for _, c in ipairs({ { 30, 30 }, { 70, 30 }, { 70, 50 }, { 50, 50 }, { 50, 70 }, { 30, 70 } }) do
    for _, p in ipairs(fl) do if math.sqrt((p[1] - c[1]) ^ 2 + (p[2] - c[2]) ^ 2) < 1.5 then hits = hits + 1 break end end
end
check("L shape: all 6 sharp corners kept", hits == 6)

local half = ring(function(x, z) return x >= 0 and x ^ 2 + (z - 50) ^ 2 <= 400 end, 0, 30, 20, 80)
local fh = fit(half, { minX = 0, minZ = -1000, maxX = 1000, maxZ = 1000 }, 1.5)
local crossed = false
for _, p in ipairs(fh) do if p[1] < -1e-6 then crossed = true end end
check("chunk seam stays straight (no point crosses x=0)", fh ~= nil and not crossed)
finish("curve_fit_test")
