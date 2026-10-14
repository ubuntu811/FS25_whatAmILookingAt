--[[
    WailaPlaceableProbe.lua

    Debug probe: can we draw the real footprint of a placeable (the building,
    not the ground layer under it plus its apron)?

    Placeables describe rectangular areas with i3d nodes (foliage areas, test
    areas, ...): a start node plus a width and height node, or a start and an
    end node. This searches every placeable near the player for such areas in
    its specializations (tables named spec_*), logs which specialization and
    field each one came from, and draws the rectangles on the layer-class
    overlay (white) so they can be compared with the ground layer. Which spec
    carries the real outline is not known up front, hence the log.

    A building is rarely one rectangle (an L-shaped factory is several wings),
    so rectangles are painted into the same bitmap value: the picture is their
    union. Second source: the placeable's own collision shapes (static object /
    building flags) walked from its root node, each drawn as its bounding box
    (yellow), which follows the walls more closely than placement test areas.
]]

WailaPlaceableProbe = {}

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] [PlaceableProbe] " .. formatString, ...)
end

local MAX_DEPTH = 4
local MAX_TABLES = 3000
local RADIUS = 300

local function nodeXYZ(node)
    if type(node) ~= "number" or node == 0 then
        return nil
    end
    if entityExists ~= nil and not entityExists(node) then
        return nil
    end
    local ok, x, y, z = pcall(getWorldTranslation, node)
    if ok and x ~= nil then
        return x, y, z
    end
    return nil
end

-- Corner polygon (world x/z) of one node-defined area, or nil.
function WailaPlaceableProbe.areaCorners(area)
    local sx, sy, sz = nodeXYZ(area.startNode)
    if sx == nil then
        return nil
    end
    if area.widthNode ~= nil and area.heightNode ~= nil then
        local wx, _, wz = nodeXYZ(area.widthNode)
        local hx, _, hz = nodeXYZ(area.heightNode)
        if wx ~= nil and hx ~= nil then
            return { { sx, sz }, { wx, wz }, { wx + hx - sx, wz + hz - sz }, { hx, hz } }, "start+width+height"
        end
    end
    if area.endNode ~= nil then
        local ex, ey, ez = nodeXYZ(area.endNode)
        if ex ~= nil then
            -- rectangle spanned by start and end in the start node's own frame
            local ok, lx, _, lz = pcall(worldToLocal, area.startNode, ex, ey, ez)
            if ok and lx ~= nil then
                local corners = {}
                for _, c in ipairs({ { 0, 0 }, { lx, 0 }, { lx, lz }, { 0, lz } }) do
                    local okWorld, wx, _, wz = pcall(localToWorld, area.startNode, c[1], 0, c[2])
                    if not okWorld or wx == nil then
                        return nil
                    end
                    corners[#corners + 1] = { wx, wz }
                end
                return corners, "start+end"
            end
        end
    end
    return nil
end

-- All node-defined areas inside a placeable's specializations.
-- Returns { { path = "spec_x.areas.1", kind = ..., corners = {...} }, ... }.
function WailaPlaceableProbe.collectAreas(placeable)
    local found = {}
    local visited, count = {}, 0
    local function visit(tbl, path, depth)
        if visited[tbl] or depth > MAX_DEPTH or count > MAX_TABLES then
            return
        end
        visited[tbl] = true
        count = count + 1
        if type(tbl.startNode) == "number" and (tbl.widthNode ~= nil or tbl.endNode ~= nil) then
            local corners, kind = WailaPlaceableProbe.areaCorners(tbl)
            if corners ~= nil then
                found[#found + 1] = { path = path, kind = kind, corners = corners }
            end
            return
        end
        for key, value in pairs(tbl) do
            if type(value) == "table" then
                visit(value, path .. "." .. tostring(key), depth + 1)
            end
        end
    end
    for key, value in pairs(placeable) do
        if type(key) == "string" and key:sub(1, 5) == "spec_" and type(value) == "table" then
            visit(value, key, 1)
        end
    end
    return found
end

local MAX_NODES = 4000

-- World x/z corners of a node's physics body (engine: getRigidBodyAABB, world
-- space, output order minX, maxX, minY, maxY, minZ, maxZ -- nil if the node has
-- no rigid body). An axis-aligned box: exact for a wing aligned with the world
-- axes, larger than the wall for a rotated one.
local function shapeBoxCorners(node)
    if getRigidBodyAABB == nil then
        return nil
    end
    local ok, minX, maxX, _, _, minZ, maxZ = pcall(getRigidBodyAABB, node)
    if not ok or type(minX) ~= "number" or maxZ == nil then
        return nil
    end
    return { { minX, minZ }, { maxX, minZ }, { maxX, maxZ }, { minX, maxZ } }
end

-- A static collision body: static-object or building collision group.
local function isCollisionShape(node)
    if CollisionFlag == nil or CollisionFlag.getHasGroupFlagSet == nil then
        return false
    end
    local ok, hasStatic = pcall(CollisionFlag.getHasGroupFlagSet, node, CollisionFlag.STATIC_OBJECT)
    local ok2, hasBuilding = pcall(CollisionFlag.getHasGroupFlagSet, node, CollisionFlag.BUILDING)
    return (ok and hasStatic) or (ok2 and hasBuilding)
end

-- Static collision bodies under a placeable's root node -> { { name, corners }, ... }.
function WailaPlaceableProbe.collectShapeBoxes(rootNode)
    local boxes, visited = {}, 0
    local function walk(node, depth)
        if visited > MAX_NODES or depth > 14 then
            return
        end
        visited = visited + 1
        if isCollisionShape(node) then
            local corners = shapeBoxCorners(node)
            if corners ~= nil then
                local okName, name = pcall(getName, node)
                boxes[#boxes + 1] = { name = okName and name or "?", corners = corners }
            end
        end
        if getNumOfChildren ~= nil and getChildAt ~= nil then
            for index = 0, getNumOfChildren(node) - 1 do
                walk(getChildAt(node, index), depth + 1)
            end
        end
    end
    pcall(walk, rootNode, 0)
    return boxes, visited
end

local function placeableName(placeable)
    local ok, name = pcall(function() return placeable:getName() end)
    if ok and name ~= nil then
        return tostring(name)
    end
    return tostring(placeable.configFileName or "?")
end

function WailaPlaceableProbe.run(centerX, centerZ)
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if placeableSystem == nil or placeableSystem.placeables == nil then
        log("no placeableSystem.placeables")
        return
    end

    log("engine functions: getRigidBodyAABB=%s getNumOfChildren=%s getChildAt=%s worldToLocal=%s CollisionFlag.getHasGroupFlagSet=%s",
        type(getRigidBodyAABB), type(getNumOfChildren), type(getChildAt), type(worldToLocal),
        type(CollisionFlag ~= nil and CollisionFlag.getHasGroupFlagSet or nil))
    local polygons, shapePolygons, perPath = {}, {}, {}
    local placeablesSeen, withAreas, detailed, withShapes = 0, 0, 0, 0
    -- nearest first, so the detailed log lines describe what the player is standing next to
    local candidates = {}
    for _, placeable in ipairs(placeableSystem.placeables) do
        local px, _, pz = nodeXYZ(placeable.rootNode)
        if px ~= nil and (px - centerX) ^ 2 + (pz - centerZ) ^ 2 <= RADIUS * RADIUS then
            candidates[#candidates + 1] = { placeable = placeable, px = px, pz = pz, distance = (px - centerX) ^ 2 + (pz - centerZ) ^ 2 }
        end
    end
    table.sort(candidates, function(a, b) return a.distance < b.distance end)
    for _, candidate in ipairs(candidates) do
        local placeable, px, pz = candidate.placeable, candidate.px, candidate.pz
        do
            placeablesSeen = placeablesSeen + 1
            local areas = WailaPlaceableProbe.collectAreas(placeable)
            if #areas > 0 then
                withAreas = withAreas + 1
            end
            for _, area in ipairs(areas) do
                polygons[#polygons + 1] = area.corners
                -- group by spec + the field above the numeric index
                local group = area.path:gsub("%.%d+", ".#")
                perPath[group] = (perPath[group] or 0) + 1
            end
            local boxes, visitedNodes = WailaPlaceableProbe.collectShapeBoxes(placeable.rootNode)
            if #boxes > 0 then
                withShapes = withShapes + 1
            end
            for _, box in ipairs(boxes) do
                shapePolygons[#shapePolygons + 1] = box.corners
            end
            if detailed < 6 then
                detailed = detailed + 1
                local specs = {}
                for key, value in pairs(placeable) do
                    if type(key) == "string" and key:sub(1, 5) == "spec_" and type(value) == "table" then
                        specs[#specs + 1] = key
                    end
                end
                table.sort(specs)
                log("placeable '%s' at %.0f/%.0f: %d node area(s), %d collision shape box(es) in %d node(s); specializations: %s", placeableName(placeable), px, pz, #areas, #boxes, visitedNodes, table.concat(specs, ", "))
                for _, area in ipairs(areas) do
                    log("    %s (%s): %.0f/%.0f .. %.0f/%.0f", area.path, area.kind, area.corners[1][1], area.corners[1][2], area.corners[3][1], area.corners[3][2])
                end
            end
        end
    end
    log("%d placeable(s) within %dm, %d with node-defined areas (%d polygon(s)), %d with collision shape boxes (%d box(es))", placeablesSeen, RADIUS, withAreas, #polygons, withShapes, #shapePolygons)
    local groups = {}
    for group, count in pairs(perPath) do
        groups[#groups + 1] = string.format("%s x%d", group, count)
    end
    table.sort(groups)
    for _, line in ipairs(groups) do
        log("  area source: %s", line)
    end

    -- draw: the class overlay first (creates the overlay, shows the ground layers),
    -- then the rectangles on top in white
    WailaTrailTracer.buildLayerClassOverlay(centerX, centerZ)
    local map = WailaTrailTracer.layerClassOverlayMap
    local modifier = DensityMapModifier.new(map, 0, 3, g_terrainNode)
    -- a building is a union of rectangles: painting them all into one bitmap value
    -- gives that union (white = placement areas, yellow = collision shape boxes,
    -- drawn last so it shows where it differs)
    for value, list in ipairs({ polygons, shapePolygons }) do
        for _, corners in ipairs(list) do
            modifier:clearPolygonPoints()
            for _, corner in ipairs(corners) do
                modifier:addPolygonPointWorldCoords(corner[1], corner[2])
            end
            modifier:executeSet(value + 3)
        end
    end
    local overlay = WailaTrailTracer.layerClassOverlay
    resetDensityMapVisualizationOverlay(overlay)
    setDensityMapVisualizationOverlayStateColor(overlay, map, 0, 0, 0, 3, WailaTrailTracer.LAYER_CLASS_ROAD, 1.0, 0.35, 0.0)
    setDensityMapVisualizationOverlayStateColor(overlay, map, 0, 0, 0, 3, WailaTrailTracer.LAYER_CLASS_FOREST, 0.0, 0.9, 0.4)
    setDensityMapVisualizationOverlayStateColor(overlay, map, 0, 0, 0, 3, 3, 1.0, 0.0, 1.0)
    setDensityMapVisualizationOverlayStateColor(overlay, map, 0, 0, 0, 3, 4, 1.0, 1.0, 1.0)
    setDensityMapVisualizationOverlayStateColor(overlay, map, 0, 0, 0, 3, 5, 1.0, 0.9, 0.0)
    generateDensityMapVisualizationOverlay(overlay)
end
