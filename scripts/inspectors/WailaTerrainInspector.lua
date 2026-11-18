WailaTerrainInspector = {}
local WailaTerrainInspector_mt = Class(WailaTerrainInspector)

function WailaTerrainInspector.new()
    return setmetatable({}, WailaTerrainInspector_mt)
end

-- Real request: raycastClosest (used everywhere else in WAILA, e.g.
-- WailaTrailTracer's own isSpotClearOfStructures) can only ever answer
-- "what's the SINGLE nearest thing here" -- confirmed live, a road with
-- no collision shape of its own reports as plain "terrain", indistinguishable
-- from open ground. raycastAll instead calls its own callback once per hit
-- ALONG the ray, not just the closest -- real, confirmed native contract,
-- same signature FS25_0_TerraFarm's own Machine:raycastCallbackShovelFillVolume
-- already uses for real (hitActorId, x, y, z, distance, nx, ny, nz,
-- subShapeIndex, hitShapeId, isLast). This is what makes "you're standing
-- on a road, with gravel underneath" answerable at all: a thin road
-- collision shape sitting just above bare terrain shows up as ONE entry
-- in this stack, terrain as another, instead of raycastClosest only ever
-- returning whichever one happens to be nearest.
local COLLISION_STACK_MAX_HITS = 8
local COLLISION_STACK_PROBE_HEIGHT = 3.0
local COLLISION_STACK_PROBE_DEPTH = 6.0

-- Real object as the raycast target, not a nil-target/global-name-lookup
-- fallback -- same reasoning WailaTrailTracer's own raycastTarget comment
-- already covers (a nil target relies on a global-name lookup a `local
-- function` never satisfies).
local collisionStackTarget = {}

function collisionStackTarget:onCollisionStackRaycastCallback(hitActorId, x, y, z, distance, nx, ny, nz, subShapeIndex, hitShapeId, isLast)
    if hitActorId ~= nil and hitActorId ~= 0 then
        table.insert(self.hits, { nodeId = hitActorId, distance = distance })
    end
    -- isLast (the callback's own final argument) marks the real end of
    -- the ray's hit list -- MAX_HITS is still a real safety backstop on
    -- top of it, same "never trust a native loop to bound itself alone"
    -- reasoning the rest of this mod's own guards already use.
    if isLast or #self.hits >= COLLISION_STACK_MAX_HITS then
        return false
    end
    return true
end

-- Public: every collision hit along a straight-down ray through (x, y, z),
-- closest first -- not just the nearest one. safeGlobalCall guards both
-- lookups per hit the same way WailaObject already resolves a node's own
-- name (getName) -- an arbitrary hit actor from a broad raycastAll mask
-- is exactly the kind of "might not be a normal object" case that needs
-- it, same lesson the RightHandRing2/RightHandRing3 brute-force-probe bug
-- already taught this mod.
function WailaTerrainInspector:inspectCollisionStack(x, y, z)
    collisionStackTarget.hits = {}
    raycastAll(
        x, y + COLLISION_STACK_PROBE_HEIGHT, z, 0, -1, 0, COLLISION_STACK_PROBE_DEPTH,
        "onCollisionStackRaycastCallback", collisionStackTarget, bit32.bnot(0)
    )

    table.sort(collisionStackTarget.hits, function(a, b)
        return a.distance < b.distance
    end)

    local result = {}
    for _, hit in ipairs(collisionStackTarget.hits) do
        table.insert(result, {
            nodeId = hit.nodeId,
            nodeName = WailaUtil.safeGlobalCall("getName", nil, hit.nodeId),
            group = WailaUtil.safeGlobalCall("getCollisionFilterGroup", nil, hit.nodeId),
            distance = hit.distance,
        })
    end
    return result
end

function WailaTerrainInspector:inspectPoint(x, y, z)
    local isOnField, densityBits, groundType = FSDensityMapUtil.getFieldDataAtWorldPosition(x, y, z)
    local r, g, b, depth, materialId = getTerrainAttributesAtWorldPos(
        g_terrainNode, x, y, z, true, true, true, true, false
    )

    -- Ground texture alone can't tell a real road/building apart from
    -- ground that's still painted dirt/gravel/stone underneath it (this
    -- map's roads are separate mesh objects sitting on top of the terrain
    -- paint, not a distinct paint layer - confirmed live: a road tile read
    -- back as plain STONE, same coarse bucket as open ground). Reuses
    -- WailaTrailTracer's own real, proven raycast check rather than
    -- duplicating it - see its comment for why a nil-target callback would
    -- have silently never fired.
    local isClearOfStructures = WailaTrailTracer.isSpotClearOfStructures(x, z)

    return WailaTerrain.new(x, y, z, isOnField, densityBits, groundType, r, g, b, depth, materialId, isClearOfStructures)
end

function WailaTerrainInspector:scanArea(centerX, centerZ, size, step)
    local half = size * 0.5
    local materials = {}
    local layers = {}
    local fieldSamples = 0
    local samples = 0

    for x = centerX - half, centerX + half - 0.0001, step do
        for z = centerZ - half, centerZ + half - 0.0001, step do
            local lr, lg, lb, lw, materialId = getTerrainAttributesAtWorldPos(
                g_terrainNode, x, 0, z, true, true, true, true, false
            )
            local isOnField = FSDensityMapUtil.getFieldDataAtWorldPosition(x, 0, z)

            samples = samples + 1
            local layerKey = string.format("%.4f/%.4f/%.4f/%.4f", lr or 0, lg or 0, lb or 0, lw or 0)
            layers[layerKey] = (layers[layerKey] or 0) + 1
            local materialName = WailaTerrain.getMaterialName(materialId)
            materials[materialName] = (materials[materialName] or 0) + 1
            if isOnField then
                fieldSamples = fieldSamples + 1
            end
        end
    end

    return WailaTerrainArea.new(samples, WailaUtil.sortedCounts(materials, samples), samples > 0 and fieldSamples / samples * 100 or 0, WailaUtil.sortedCounts(layers, samples))
end
