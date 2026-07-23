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
