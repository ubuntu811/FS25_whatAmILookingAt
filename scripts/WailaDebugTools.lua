-- World-reverse-engineering debug tools, moved here from
-- FS25_ImmersiveWeathering - none of these ever read or wrote iw.xml/the
-- foliage palette, they're pure engine/map investigation (what layers
-- exist, what does a raw state look like, does a more granular
-- ground-type read exist) that only ended up in IW because its raycast/
-- paint helpers were already there to reuse. WAILA is the actual "world
-- inspector" mod, so this is where they belong. Reuses
-- FS25WhatAmILookingAt's own continuous raycast (self.current.hit)
-- instead of doing a fresh one per tool, unlike IW's original versions.
WailaDebugTools = {}
local WailaDebugTools_mt = Class(WailaDebugTools)

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] " .. formatString, ...)
end

-- Layer rows x state 0-15 columns - every writable deco layer this map
-- declares, at every state, laid out as a grid for visual/WAILA-readback
-- comparison. States 0-15 covers every layer regardless of its own real
-- numChannels/content count - reading nothing back at a given cell is
-- itself the useful signal (out of range/undefined), not a failure.
local TEST_RIG_GRID_LAYERS = {
    "decoFoliage", "decoFoliageEU", "forestPlants", "waterPlants",
    "decoBush", "decoBushUS", "groundFoliage", "forestGrass", "forestBush",
    "meadow",
}
local TEST_RIG_GRID_MAX_STATE = {
    forestGrass = 1,
    forestBush = 1,
}
local TEST_RIG_GRID_STATES = 15
local TEST_RIG_SPACING = 2.0
local AREA_FILL_STEP = 0.5

local PAINT_LAYER_TEST_ROW = {
    "grass01", "grass02", "grassDry01", "grassDry02", "grassPavement01",
    "GRASS", "GRASSDRY", "GRASSPAVEMENT",
}

-- Guesses at whether some named "terrain detail" density system exists
-- that's more granular than getTerrainAttributesAtWorldPos's coarse
-- materialId bucket - none confirmed to resolve to anything. Does NOT
-- reveal which of the map's real paint layers (dirt01/grass01/etc) is
-- under a point even in the best case - that's a separate subsystem
-- (TerrainDeformation paint layers) with no per-position read at all.
local DENSITY_PROBE_CANDIDATE_NAMES = {
    "groundType", "GROUND_TYPE", "material", "terrainType", "ground",
}

-- Every real layer= value from this map's own <groundTypeMappings> in
-- map.xml (27 entries, confirmed by grep, not guessed) - testing the
-- theory that ground/terrain textures are buried in the same kind of
-- named-dataPlane system foliage confirmably uses (see
-- ImmersiveWeathering:resolveFoliagePlaneIds - foliageSystem.decoFoliages
-- entries each carry their own .terrainDataPlaneId directly, no
-- name-lookup function needed). getTerrainDataPlaneByName is the
-- candidate function - untested against real layer names until now.
local GROUND_LAYER_NAMES = {
    "DIRT", "dirt01", "dirt02", "dirtDark01", "dirtDark02", "gravelDir02",
    "forestRoots01", "foresMossGroundLeaves01", "TARMAC", "GRAVEL",
    "tarmacDirt01", "tarmacDirt02", "GRASS", "grassDry01", "grassPavement01",
    "SAND", "sand01", "sand02", "sandGravel01", "sandGravel02", "mud01",
    "mud02", "CONCRETEINDUSTRIAL", "FORESTMOSSGROUND", "sidewalktiles01",
    "sidewalktiles02", "rock01",
}

function WailaDebugTools.new()
    return setmetatable({}, WailaDebugTools_mt)
end

function WailaDebugTools:getTerrainLayerIdByName(name)
    self.terrainLayerIdCache = self.terrainLayerIdCache or {}
    local cached = self.terrainLayerIdCache[name]

    if cached ~= nil then
        if cached == false then
            return nil
        end

        return cached
    end

    local numLayers = getTerrainNumOfLayers(g_terrainNode)

    for i = 0, numLayers - 1 do
        local layerName = getTerrainLayerName(g_terrainNode, i)

        if layerName ~= nil and layerName:upper() == name:upper() then
            self.terrainLayerIdCache[name] = i
            return i
        end
    end

    self.terrainLayerIdCache[name] = false
    return nil
end

function WailaDebugTools:paintTerrainAtLayer(x, z, layerId)
    local paint = TerrainDeformation.new(g_terrainNode)
    paint:enablePaintingMode()
    paint:addSoftCircleBrush(x, z, 0.4, 0.3, 0.6, layerId)

    local callbackTarget = { deformation = paint }
    function callbackTarget:onPaintApplied(code, volume)
        self.deformation:delete()
    end

    paint:apply(false, "onPaintApplied", callbackTarget)
end

-- Same raw write as IW's own placeFoliage, minus IW's gameplay gates
-- (field/material/clear-spot checks) - this is a deliberate manual test
-- write, not ambient weathering, so those don't apply here either.
function WailaDebugTools:placeFoliage(x, z, decoName)
    decoName = decoName or "grassShort"

    local foliageSystem = g_currentMission.foliageSystem
    if not foliageSystem:getIsDecoLayerDefined(decoName) then
        log("foliage layer '%s' is not defined", decoName)
        return false
    end

    local halfSize = 0.35 + math.random() * 0.35
    local angle = math.random() * math.pi * 2
    local cosA, sinA = math.cos(angle), math.sin(angle)

    local function corner(dx, dz)
        return x + dx * cosA - dz * sinA, z + dx * sinA + dz * cosA
    end

    local x0, z0 = corner(-halfSize, -halfSize)
    local x1, z1 = corner(halfSize, -halfSize)
    local x2, z2 = corner(-halfSize, halfSize)

    foliageSystem:applyDecoFoliage(decoName, x0, z0, x1, z1, x2, z2)

    return true
end

function WailaDebugTools:dumpTerrainLayers()
    local numLayers = getTerrainNumOfLayers(g_terrainNode)
    log("[TerrainLayers] %d layers declared on this map:", numLayers)

    for i = 0, numLayers - 1 do
        local layerName = getTerrainLayerName(g_terrainNode, i)
        log("[TerrainLayers] [%d] %s", i, tostring(layerName))
    end
end

function WailaDebugTools:placeTerrainLayerTestRow(hx, hz)
    for i, layerName in ipairs(PAINT_LAYER_TEST_ROW) do
        local px = hx + (i - 1) * TEST_RIG_SPACING
        local layerId = self:getTerrainLayerIdByName(layerName)

        if layerId == nil then
            log("[LayerTest] [%d] %s -> no such layer on this map", i, layerName)
        else
            self:paintTerrainAtLayer(px, hz, layerId)
            log("[LayerTest] [%d] %s (id=%d) painted at (%.2f %.2f)", i, layerName, layerId, px, hz)
        end
    end
end

function WailaDebugTools:dumpDensityProbe(hx, hy, hz)
    local okAttr, r, g, b, depth, materialId = pcall(
        getTerrainAttributesAtWorldPos, g_terrainNode, hx, hy, hz, false, false, false, false, true
    )
    log(
        "[DensityProbe] baseline getTerrainAttributesAtWorldPos: ok=%s materialId=%s",
        tostring(okAttr), tostring(okAttr and materialId or r)
    )

    log("[DensityProbe] g_currentMission.terrainDetailId = %s", tostring(g_currentMission.terrainDetailId))

    if g_currentMission.terrainDetailId ~= nil then
        local okType, typeIndex = pcall(getDensityTypeIndexAtWorldPos, g_currentMission.terrainDetailId, hx, hy, hz)
        local okStates, states = pcall(getDensityStatesAtWorldPos, g_currentMission.terrainDetailId, hx, hy, hz)
        log(
            "[DensityProbe] via terrainDetailId: typeIndex ok=%s val=%s | states ok=%s val=%s",
            tostring(okType), tostring(typeIndex), tostring(okStates), tostring(states)
        )
    end

    for _, name in ipairs(DENSITY_PROBE_CANDIDATE_NAMES) do
        local okId, detailId = pcall(getTerrainDetailByName, g_terrainNode, name)

        if okId and detailId ~= nil then
            local okType, typeIndex = pcall(getDensityTypeIndexAtWorldPos, detailId, hx, hy, hz)
            log(
                "[DensityProbe] getTerrainDetailByName('%s') -> id=%s | typeIndex ok=%s val=%s",
                name, tostring(detailId), tostring(okType), tostring(typeIndex)
            )
        else
            log("[DensityProbe] getTerrainDetailByName('%s') -> no result", name)
        end
    end
end

-- Resolves once, cached - tries every one of this map's 27 real ground
-- layer names against getTerrainDataPlaneByName, under BOTH g_terrainNode
-- and g_currentMission.terrainRootNode (unclear which, if either, is the
-- right terrainId - getTerrainLayerName works with g_terrainNode, but
-- that's a different function/subsystem). Every call pcall'd - a wrong
-- name/terrainId combination is expected far more often than a right one.
-- detailId == 0 excluded as invalid, same "not found" sentinel confirmed
-- on getTerrainDetailByName earlier.
function WailaDebugTools:resolveGroundDataPlaneIds()
    if self.groundDataPlaneIdsResolved then
        return
    end

    self.groundDataPlaneIdsResolved = true
    self.groundDataPlaneIds = {}

    local terrainIdCandidates = {
        g_terrainNode = g_terrainNode,
        terrainRootNode = g_currentMission.terrainRootNode,
    }

    -- Log the raw candidate values up front - if one is nil, that's a
    -- silently-skipped candidate, not a tested-and-failed one, and the
    -- attempt count below needs to reflect that honestly.
    for terrainIdLabel, terrainId in pairs(terrainIdCandidates) do
        log("[GroundProbe] candidate %s = %s", terrainIdLabel, tostring(terrainId))
    end

    local attempted = 0
    for terrainIdLabel, terrainId in pairs(terrainIdCandidates) do
        if terrainId ~= nil then
            for _, name in ipairs(GROUND_LAYER_NAMES) do
                attempted = attempted + 1
                log("[GroundProbe] looking up dataPlaneId for %s (%s) / '%s'", terrainIdLabel, tostring(terrainId), name)
                local ok, detailId, typeId = pcall(getTerrainDataPlaneByName, terrainId, name)

                if ok and detailId ~= nil and detailId ~= 0 then
                    local key = string.format("%s/%s", terrainIdLabel, name)
                    self.groundDataPlaneIds[key] = { detailId = detailId, typeId = typeId }
                    log(
                        "[GroundProbe]   -> RESOLVED detailId=%s typeId=%s",
                        tostring(detailId), tostring(typeId)
                    )
                elseif not ok then
                    log("[GroundProbe]   -> errored: %s", tostring(detailId))
                else
                    log("[GroundProbe]   -> no result (ok=%s detailId=%s)", tostring(ok), tostring(detailId))
                end
            end
        end
    end

    local count = 0
    for _ in pairs(self.groundDataPlaneIds) do
        count = count + 1
    end
    log("[GroundProbe] %d of %d actually-attempted combinations resolved (54 possible if both candidates are non-nil)", count, attempted)
end

function WailaDebugTools:dumpGroundDensityProbe(hx, hy, hz)
    self:resolveGroundDataPlaneIds()

    for key, ids in pairs(self.groundDataPlaneIds) do
        local okType, typeIndex = pcall(getDensityTypeIndexAtWorldPos, ids.detailId, hx, hy, hz)
        local okStates, states = pcall(getDensityStatesAtWorldPos, ids.detailId, hx, hy, hz)
        log(
            "[GroundProbe] %s (detailId=%s): typeIndex ok=%s val=%s | states ok=%s val=%s",
            key, tostring(ids.detailId), tostring(okType), tostring(typeIndex), tostring(okStates), tostring(states)
        )
    end
end

function WailaDebugTools:placeFoliageTestRig(hx, hz)
    log("[TestRig] --- mapping grid (layer rows x state 0-15 columns) ---")
    local concreteLayerId = self:getTerrainLayerIdByName("CONCRETEINDUSTRIAL")

    for row, layerName in ipairs(TEST_RIG_GRID_LAYERS) do
        local pz = hz + (row - 1) * TEST_RIG_SPACING
        local maxState = TEST_RIG_GRID_MAX_STATE[layerName] or TEST_RIG_GRID_STATES

        for state = 0, TEST_RIG_GRID_STATES do
            local px = hx + state * TEST_RIG_SPACING
            local name = layerName .. "_s" .. state
            local ok = self:placeFoliage(px, pz, name)
            log("[TestRig] [grid %s x%d] %s at (%.2f %.2f) -> %s", layerName, state, name, px, pz, tostring(ok))

            if state > maxState and concreteLayerId ~= nil then
                self:paintTerrainAtLayer(px, pz, concreteLayerId)
            end
        end
    end

    local borderMargin = 1.0
    local borderMinX = hx - borderMargin
    local borderMaxX = hx + TEST_RIG_GRID_STATES * TEST_RIG_SPACING + borderMargin
    local borderMinZ = hz - borderMargin
    local borderMaxZ = hz + (#TEST_RIG_GRID_LAYERS - 1) * TEST_RIG_SPACING + borderMargin

    if concreteLayerId ~= nil then
        for px = borderMinX, borderMaxX, AREA_FILL_STEP do
            self:paintTerrainAtLayer(px, borderMinZ, concreteLayerId)
            self:paintTerrainAtLayer(px, borderMaxZ, concreteLayerId)
        end
        for pz = borderMinZ, borderMaxZ, AREA_FILL_STEP do
            self:paintTerrainAtLayer(borderMinX, pz, concreteLayerId)
            self:paintTerrainAtLayer(borderMaxX, pz, concreteLayerId)
        end
        log("[TestRig] border painted: X[%.2f, %.2f] Z[%.2f, %.2f]", borderMinX, borderMaxX, borderMinZ, borderMaxZ)
    else
        log("[TestRig] CONCRETEINDUSTRIAL layer not found, skipping border")
    end
end
