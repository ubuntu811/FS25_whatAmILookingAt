--[[
    WailaPathStore.lua

    Paths: polylines on the map that mean "vehicles drive here", with a width, an optional direction
    and where they came from. One neutral store for every source (TerraFarm's road
    areas, the map's own splines, centre-lines derived from the scan) and every consumer (a map
    overlay, a road follower, a router). Published through g_currentMission.wailaPaths.

    A path = { id, kind, source, name, width, oneWay, points = { {x, z}, ... } }
      kind     "recorded" | "imported" | "spline" | "derived"  (free text; consumers may prefer some)
      oneWay   true when the direction of the points is meaningful (a driven lane), false for a
               road that is used both ways
    Saved in <savegame>/wailaPaths.xml. The game deletes savegame files it did not write itself on its
    own save, so WAILA rewrites this file in its save hook, like its other files; unsaved paths are
    lost with the session, the same as everything else in a savegame.
]]

WailaPathStore = {}

WailaPathStore.FILENAME = "wailaPaths.xml"
WailaPathStore.BUCKET_SIZE = 64

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] [Paths] " .. formatString, ...)
end

local paths = {}        -- id -> path
local order = {}        -- ids, oldest first
local buckets = {}      -- "col:row" -> { [id] = true }
local nextId = 1

local function bucketKey(col, row)
    return col .. ":" .. row
end

local function indexPath(path)
    local size = WailaPathStore.BUCKET_SIZE
    local seen = {}
    for i = 1, #path.points - 1 do
        local a, b = path.points[i], path.points[i + 1]
        local c0, c1 = math.floor(math.min(a[1], b[1]) / size), math.floor(math.max(a[1], b[1]) / size)
        local r0, r1 = math.floor(math.min(a[2], b[2]) / size), math.floor(math.max(a[2], b[2]) / size)
        for col = c0, c1 do
            for row = r0, r1 do
                local key = bucketKey(col, row)
                if not seen[key] then
                    seen[key] = true
                    buckets[key] = buckets[key] or {}
                    buckets[key][path.id] = true
                end
            end
        end
    end
end

local function unindexPath(path)
    for _, bucket in pairs(buckets) do
        bucket[path.id] = nil
    end
end

-- ===== geometry =====

function WailaPathStore.length(points)
    local total = 0
    for i = 2, #points do
        local dx, dz = points[i][1] - points[i - 1][1], points[i][2] - points[i - 1][2]
        total = total + math.sqrt(dx * dx + dz * dz)
    end
    return total
end

-- ===== the store =====

WailaPathStore.mapSplinesImported = false

function WailaPathStore.clear()
    paths, order, buckets, nextId = {}, {}, {}, 1
    WailaPathStore.mapSplinesImported = false
end

function WailaPathStore.count()
    return #order
end

function WailaPathStore.get(id)
    return paths[id]
end

function WailaPathStore.getAll()
    local list = {}
    for _, id in ipairs(order) do
        list[#list + 1] = paths[id]
    end
    return list
end

-- definition: { points = { {x, z}, ... } (at least 2), kind, source, name, width, oneWay }
-- returns the new id, or nil and a reason
function WailaPathStore.add(definition)
    if definition == nil or definition.points == nil or #definition.points < 2 then
        return nil, "a path needs at least two points"
    end
    local points = {}
    for i, p in ipairs(definition.points) do
        points[i] = { p[1], p[2] }
    end
    local path = {
        id = definition.id or nextId,
        kind = definition.kind or "recorded",
        source = definition.source or "",
        name = definition.name or "",
        width = definition.width or 4.0,
        oneWay = definition.oneWay == true,
        transient = definition.transient == true,
        points = points,
    }
    if paths[path.id] ~= nil then
        return nil, "id already in use"
    end
    nextId = math.max(nextId, path.id + 1)
    paths[path.id] = path
    order[#order + 1] = path.id
    indexPath(path)
    return path.id
end

function WailaPathStore.remove(id)
    local path = paths[id]
    if path == nil then
        return false
    end
    unindexPath(path)
    paths[id] = nil
    for i, value in ipairs(order) do
        if value == id then
            table.remove(order, i)
            break
        end
    end
    return true
end

-- Paths within `radius` metres of (x, z), nearest first. Each hit:
--   { path, id, distance, x, z (the closest point on the path), dx, dz (unit direction of the path
--     there, in the order of its points), along (metres from the path's start), index (segment) }
function WailaPathStore.findNear(x, z, radius)
    local size = WailaPathStore.BUCKET_SIZE
    local candidates = {}
    for col = math.floor((x - radius) / size), math.floor((x + radius) / size) do
        for row = math.floor((z - radius) / size), math.floor((z + radius) / size) do
            local bucket = buckets[bucketKey(col, row)]
            if bucket ~= nil then
                for id in pairs(bucket) do
                    candidates[id] = true
                end
            end
        end
    end
    local hits = {}
    for id in pairs(candidates) do
        local path = paths[id]
        local best = nil
        local along = 0
        for i = 1, #path.points - 1 do
            local ax, az = path.points[i][1], path.points[i][2]
            local bx, bz = path.points[i + 1][1], path.points[i + 1][2]
            local sx, sz = bx - ax, bz - az
            local lengthSq = sx * sx + sz * sz
            local segmentLength = math.sqrt(lengthSq)
            local t = 0
            if lengthSq > 1e-9 then
                t = math.max(0, math.min(1, ((x - ax) * sx + (z - az) * sz) / lengthSq))
            end
            local cx, cz = ax + sx * t, az + sz * t
            local distance = math.sqrt((x - cx) ^ 2 + (z - cz) ^ 2)
            if best == nil or distance < best.distance then
                local ux, uz = 0, 1
                if segmentLength > 1e-9 then
                    ux, uz = sx / segmentLength, sz / segmentLength
                end
                best = { path = path, id = id, distance = distance, x = cx, z = cz, dx = ux, dz = uz, along = along + segmentLength * t, index = i }
            end
            along = along + segmentLength
        end
        if best ~= nil and best.distance <= radius then
            hits[#hits + 1] = best
        end
    end
    table.sort(hits, function(a, b)
        if a.distance ~= b.distance then
            return a.distance < b.distance
        end
        return a.id < b.id
    end)
    return hits
end

-- ===== file =====

local function filePath()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    if info == nil or info.savegameDirectory == nil then
        return nil
    end
    return info.savegameDirectory .. "/" .. WailaPathStore.FILENAME
end

function WailaPathStore.save()
    local path = filePath()
    if path == nil then
        return false
    end
    local xmlFile = XMLFile.create("wailaPaths", path, "wailaPaths")
    if xmlFile == nil then
        log("save: XMLFile.create failed for %s", path)
        return false
    end
    local written = 0
    for _, id in ipairs(order) do
        local p = paths[id]
        if not p.transient then
            local key = string.format("wailaPaths.path(%d)", written)
            written = written + 1
            xmlFile:setString(key .. "#id", tostring(p.id))
            xmlFile:setString(key .. "#kind", p.kind)
            xmlFile:setString(key .. "#source", p.source)
            xmlFile:setString(key .. "#name", p.name)
            xmlFile:setFloat(key .. "#width", p.width)
            xmlFile:setBool(key .. "#oneWay", p.oneWay)
            local parts = {}
            for j, point in ipairs(p.points) do
                parts[j] = string.format("%.2f %.2f", point[1], point[2])
            end
            xmlFile:setString(key .. "#points", table.concat(parts, " "))
        end
    end
    xmlFile:save()
    xmlFile:delete()
    return true
end

function WailaPathStore.load()
    WailaPathStore.clear()
    local path = filePath()
    if path == nil then
        return false
    end
    local xmlFile = XMLFile.loadIfExists("wailaPaths", path)
    if xmlFile == nil then
        return false
    end
    local loaded = 0
    for _, key in xmlFile:iterator("wailaPaths.path") do
        local points = {}
        local numbers = {}
        for token in tostring(xmlFile:getString(key .. "#points") or ""):gmatch("%S+") do
            numbers[#numbers + 1] = tonumber(token)
        end
        for i = 1, #numbers - 1, 2 do
            if numbers[i] ~= nil and numbers[i + 1] ~= nil then
                points[#points + 1] = { numbers[i], numbers[i + 1] }
            end
        end
        local id = WailaPathStore.add({
            id = tonumber(xmlFile:getString(key .. "#id")),
            points = points,
            kind = xmlFile:getString(key .. "#kind"),
            source = xmlFile:getString(key .. "#source"),
            name = xmlFile:getString(key .. "#name"),
            width = xmlFile:getFloat(key .. "#width"),
            oneWay = xmlFile:getBool(key .. "#oneWay"),
        })
        if id ~= nil then
            loaded = loaded + 1
        end
    end
    xmlFile:delete()
    log("loaded %d path(s) from %s", loaded, path)
    return true
end
