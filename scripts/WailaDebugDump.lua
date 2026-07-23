WailaDebugDump = {}

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] " .. formatString, ...)
end

local function dumpTable(value, prefix, depth, seen)
    if type(value) ~= "table" or depth <= 0 or seen[value] then
        return
    end

    seen[value] = true
    for key, nested in pairs(value) do
        log("%s%s = %s (%s)", prefix, tostring(key), tostring(nested), type(nested))
        if type(nested) == "table" then
            dumpTable(nested, prefix .. "  ", depth - 1, seen)
        end
    end
end

function WailaDebugDump.dump(inspection)
    if inspection == nil or inspection.hit == nil then
        log("No current target")
        return
    end

    log("------------------------------------------------------------")
    log("TARGET node=%s pos=(%.3f, %.3f, %.3f) distance=%.3f",
        tostring(inspection.hit.nodeId), inspection.hit.x, inspection.hit.y, inspection.hit.z, inspection.hit.distance or -1)

    if inspection.object ~= nil then
        for key, value in pairs(inspection.object) do
            log("object.%s = %s (%s)", tostring(key), tostring(value), type(value))
        end
        if inspection.object.object ~= nil then
            dumpTable(inspection.object.object, "object.object.", 2, {})
        end
    end

    if inspection.terrain ~= nil then
        for key, value in pairs(inspection.terrain) do
            log("terrain.%s = %s", tostring(key), tostring(value))
        end
    end

    log("------------------------------------------------------------")
end
