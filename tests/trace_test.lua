dofile("tests/stubs.lua")
local T = loadTracer()
local function mask(n, fn)
    local m = {}
    for r = 0, n - 1 do m[r] = {} for c = 0, n - 1 do m[r][c] = fn(r, c) end end
    return m
end
local function trace(m, n, cell) return T.traceMaskPolygons(m, 0, 0, n, cell or 1.0, 0.7) end
local P = trace(mask(40, function(r, c) return r >= 10 and r < 30 and c >= 10 and c < 30 end), 40)
check("square: one polygon", #P == 1)
check("square: area 400", math.abs(totalArea(P) - 400) < 8)
local P2 = trace(mask(40, function(r, c) return (r >= 5 and r < 15 and c >= 5 and c < 15) or (r >= 25 and r < 35 and c >= 25 and c < 35) end), 40)
check("two separate blobs: two polygons", #P2 == 2)
local P3 = trace(mask(40, function(r, c) return r >= 5 and r < 35 and c >= 5 and c < 35 and not (r >= 15 and r < 25 and c >= 15 and c < 25) end), 40)
check("blob with a hole: outer loop and hole loop", #P3 == 2)
check("net area = outer minus hole", math.abs(math.abs(polygonArea(P3[1]) - polygonArea(P3[2])) - 800) < 24)
local P4 = trace(mask(20, function(r, c) return (r == 5 and c == 5) or (r == 6 and c == 6) end), 20)
check("diagonal touch is not pinched into one loop", #P4 == 2)
finish("trace_test")
