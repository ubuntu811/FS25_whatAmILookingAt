WailaUtil = {}

function WailaUtil.safeCall(defaultValue, fn, ...)
    if fn == nil then
        return defaultValue
    end

    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end

    return defaultValue
end

function WailaUtil.safeGlobalCall(name, defaultValue, ...)
    return WailaUtil.safeCall(defaultValue, _G[name], ...)
end

function WailaUtil.bool(value)
    if value == nil then
        return "-"
    end
    return value and "yes" or "no"
end

function WailaUtil.value(value)
    if value == nil then
        return "-"
    end
    return tostring(value)
end

-- Shared by WailaObject and WailaVehicleInspector -- was duplicated
-- identically in both before this existed.
function WailaUtil.getObjectName(object)
    if object == nil then
        return nil
    end

    for _, methodName in ipairs({ "getFullName", "getName" }) do
        local method = object[methodName]
        if method ~= nil then
            local value = WailaUtil.safeCall(nil, method, object)
            if value ~= nil and value ~= "" then
                return tostring(value)
            end
        end
    end

    return object.configFileName or object.className
end

function WailaUtil.className(object)
    if object == nil then
        return nil
    end

    if object.className ~= nil then
        return tostring(object.className)
    end

    if object.className ~= nil then
        return tostring(object.className)
    end

    if object.getName ~= nil then
        local name = WailaUtil.safeCall(nil, object.getName, object)
        if name ~= nil and name ~= "" then
            return tostring(name)
        end
    end

    return tostring(object)
end

function WailaUtil.rigidBodyTypeName(value)
    if value == nil then
        return "unknown"
    end

    if RigidBodyType ~= nil then
        if value == RigidBodyType.NONE then return "none" end
        if value == RigidBodyType.STATIC then return "static" end
        if value == RigidBodyType.DYNAMIC then return "dynamic" end
        if value == RigidBodyType.KINEMATIC then return "kinematic" end
    end

    return tostring(value)
end

-- Polygon2D:getIsPosInside does a horizontal ray-cast internally
-- (MathUtil.getLineSegmentsIntersection against a fixed (x,z)->(100000,z)
-- ray) -- confirmed live, spamming the log thousands of times per minute,
-- that this throws "Divide by zero error" when the polygon has an edge
-- exactly parallel to that ray (the line-intersection math's denominator
-- is a cross product, zero for parallel segments). The base game's own
-- hand-authored field polygons rarely have an exactly-horizontal edge;
-- WailaFieldBoundaryTracer's traced boundaries do constantly -- the
-- tracer only ever steps in the 4 cardinal directions, so a straight
-- (very common) field edge is often exactly horizontal by construction.
-- Wrapped everywhere WAILA calls getIsPosInside on any polygon (our own
-- traced ones AND rice fields' authored ones, for the same safety) rather
-- than only the confirmed-triggering call sites -- cheap, and the failure
-- mode (treat as "not inside", same as any other query miss) is safe
-- everywhere this gets called.
function WailaUtil.getIsPosInsidePolygon(polygon, x, z)
    if polygon == nil then
        return false
    end
    return WailaUtil.safeCall(false, polygon.getIsPosInside, polygon, x, z)
end

function WailaUtil.sortedCounts(counts, total)
    local rows = {}
    for key, count in pairs(counts or {}) do
        table.insert(rows, {
            name = tostring(key),
            count = count,
            percent = total > 0 and (count / total * 100) or 0
        })
    end

    table.sort(rows, function(a, b)
        if a.count == b.count then
            return a.name < b.name
        end
        return a.count > b.count
    end)

    return rows
end
