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
    -- Real crop layer names (confirmed via the game install's own
    -- data/foliage/ folder listing, not guessed) - potato.xml turned out
    -- to use the exact same <foliageType>/<foliageLayer>/<foliageState>
    -- schema as meadowEU.xml, same density-map write mechanism, just a
    -- different layerName. Whether any of these actually resolve on THIS
    -- map (getIsDecoLayerDefined) is exactly what this grid is for -
    -- don't assume, read the result.
    "barley", "beetRoot", "canola", "carrot", "cotton", "grape",
    "greenBean", "maize", "oat", "oilseedRadish", "olive", "onion",
    "parsnip", "pea", "potato", "rice", "riceLongGrain", "sorghum",
    "soybean", "spinach", "sugarBeet", "sugarCane", "sunflower", "wheat",
}
local TEST_RIG_GRID_MAX_STATE = {
    forestGrass = 1,
    forestBush = 1,
}
local TEST_RIG_GRID_STATES = 15
local TEST_RIG_SPACING = 2.0
WailaDebugTools.TEST_RIG_AREA_TYPE = "waila_foliage_testrig"
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

    -- Declared-area dogfood case: re-placing the rig should replace its
    -- own area, not accumulate a fresh stale rectangle on top of every
    -- past placement. Cleared by type (WailaAreaIndex:clear()), not via a
    -- remembered instance-field reference -- an area restored from
    -- waila.xml on load has no such reference pointing to it yet, but
    -- clearing by type name catches it correctly regardless.
    local existingIndex = Waila.indices[WailaDebugTools.TEST_RIG_AREA_TYPE]
    if existingIndex ~= nil and existingIndex.className == WailaAreaIndex.MARKER then
        existingIndex:clear()
    end
    Waila.registerArea({
        type = WailaDebugTools.TEST_RIG_AREA_TYPE,
        box = { minX = borderMinX, maxX = borderMaxX, minZ = borderMinZ, maxZ = borderMaxZ },
        metadata = { originX = hx, originZ = hz },
        -- Proves declared areas can carry a real interaction, not just be
        -- informational -- walk onto the rig, press the bound key
        -- (WAILA_AREA_ACTION), it clears and rebuilds itself in place.
        actionLabel = "Reset foliage test rig",
        actionCallback = function(area)
            self:resetFoliageTestRig(area.metadata.originX, area.metadata.originZ)
        end,
    })
    log("[TestRig] declared area registered, origin=(%.2f %.2f)", hx, hz)
end

-- Meters -- half-size of the clearing quad per grid point, comfortably
-- covering placeFoliage's own randomized write footprint (halfSize up to
-- 0.7m there) without needing to match its exact random rotation.
local CLEAR_QUAD_HALF_SIZE = 1.0

-- Writes "grassShort" (a layer FSDensityMapUtil.clearDecoArea reliably
-- clears) then clears it, over the same fixed quad -- confirmed pattern
-- from ImmersiveWeathering's own tyre-effect code: clearDecoArea alone
-- doesn't reliably remove ambient "meadow"/"forestGrass" specifically,
-- both of which TEST_RIG_GRID_LAYERS includes, but normalize-then-clear
-- does.
function WailaDebugTools:clearFoliageQuad(x, z)
    local foliageSystem = g_currentMission.foliageSystem
    local x0, z0 = x - CLEAR_QUAD_HALF_SIZE, z - CLEAR_QUAD_HALF_SIZE
    local x1, z1 = x + CLEAR_QUAD_HALF_SIZE, z - CLEAR_QUAD_HALF_SIZE
    local x2, z2 = x - CLEAR_QUAD_HALF_SIZE, z + CLEAR_QUAD_HALF_SIZE

    if foliageSystem:getIsDecoLayerDefined("grassShort") then
        foliageSystem:applyDecoFoliage("grassShort", x0, z0, x1, z1, x2, z2)
    end
    FSDensityMapUtil.clearDecoArea(x0, z0, x1, z1, x2, z2)
end

-- Clears every grid point placeFoliageTestRig wrote to, then re-places a
-- fresh rig at the same origin -- the "press [key] to reset" action
-- attached to its declared area above. Doesn't try to un-paint the
-- concrete border -- placeFoliageTestRig repaints it fresh anyway.
function WailaDebugTools:resetFoliageTestRig(originX, originZ)
    log("[TestRig] Resetting at origin (%.2f %.2f)", originX, originZ)

    for row, layerName in ipairs(TEST_RIG_GRID_LAYERS) do
        local pz = originZ + (row - 1) * TEST_RIG_SPACING
        for state = 0, TEST_RIG_GRID_STATES do
            local px = originX + state * TEST_RIG_SPACING
            self:clearFoliageQuad(px, pz)
        end
    end

    self:placeFoliageTestRig(originX, originZ)
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

-- Investigation - no confirmed "is it raining" read anywhere: no Weather/
-- Rain/Environment category in scriptBinding.xml, no weather check
-- anywhere in TerraFarm's real source (searched, not just assumed
-- absent), dataS/scripts isn't browsable as loose files to check base
-- game Lua directly. map.xml does declare <environment filename=
-- "maps/config/environment.xml"/>, so g_currentMission.environment
-- almost certainly exists at runtime - dumping its real fields directly
-- (same pattern that found foliageSystem.decoFoliages) instead of
-- guessing native function names.
function WailaDebugTools:dumpEnvironment()
    if g_currentMission.environment == nil then
        log("[Environment] g_currentMission.environment is nil")
        return
    end

    log("[Environment] --- g_currentMission.environment fields (depth 2) ---")
    dumpTable(g_currentMission.environment, "environment.", 2, {})
    log("[Environment] --- end ---")
end

-- Public: player world position/facing + the currently-held hand tool's
-- own real rootNode world position, side by side - built specifically to
-- answer "is my held item rendering near me, or off in space somewhere,"
-- which no amount of staring at i3d node paths can answer on its own.
-- g_localPlayer (confirmed real, used directly in base game's own
-- TensionBelts.lua) and Player.rootNode/currentHandTool (both plain
-- fields, NOT the --#debug-gated DEBUG_DISPLAY_FLAG.HANDTOOLS overlay -
-- that one's dev-build-only and stripped from the retail game, confirmed
-- by every reference to it being commented out with --#debug in the
-- extracted source). HandTool.rootNode is the exact same field
-- HandTool.lua itself uses when it link()s the tool under the player's
-- hand/camera node, so this is reading the real, live, post-attachment
-- position, not a guess.
function WailaDebugTools:dumpPlayerAndHandTool()
    if g_localPlayer == nil then
        log("[Compass] g_localPlayer is nil")
        return
    end

    if g_localPlayer.rootNode == nil then
        log("[Compass] g_localPlayer.rootNode is nil")
        return
    end

    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local fx, fy, fz = localDirectionToWorld(g_localPlayer.rootNode, 0, 0, 1)
    log("[Compass] player pos=(%.3f %.3f %.3f) facing=(%.3f %.3f %.3f)", px, py, pz, fx, fy, fz)

    local handTool = g_localPlayer.currentHandTool
    if handTool == nil then
        log("[Compass] not currently holding any hand tool")
        return
    end

    log("[Compass] holding: %s", tostring(handTool.typeName))

    if handTool.rootNode == nil then
        log("[Compass] handTool.rootNode is nil")
        return
    end

    local hx, hy, hz = getWorldTranslation(handTool.rootNode)
    local dx, dy, dz = hx - px, hy - py, hz - pz
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    log("[Compass] handTool rootNode pos=(%.3f %.3f %.3f)", hx, hy, hz)
    log("[Compass] offset from player = (%.3f %.3f %.3f), distance=%.3fm", dx, dy, dz, distance)
end

-- Public: recursively dumps the LIVE scene-graph children of the
-- currently-held hand tool's rootNode, right now, in the running game -
-- not the static i3d file on disk. HandTool.lua's own onLoad runs every
-- node it considers a "component" through I3DUtil.loadI3DComponents,
-- re-parents each one straight to getRootNode() (the scene root, NOT a
-- child of rootNode anymore), and explicitly hides it - separately from
-- rootNode's own visibility toggle, which is the only thing later
-- setVisibility(self.rootNode, true) calls touch. If the visible mesh
-- got swept up as a "component", it would have silently vanished from
-- underneath rootNode entirely - this walk is how we'd actually see
-- that happening, since I3DUtil.lua's own exact "what counts as a
-- component" rule isn't in the extracted source to just read.
local function dumpNodeTreeRecursive(node, depth, maxDepth)
    if node == nil or depth > maxDepth then
        return
    end

    local indent = string.rep("  ", depth)
    local ok, name = pcall(getName, node)
    local okVis, visible = pcall(getVisibility, node)
    local okPos, x, y, z = pcall(getWorldTranslation, node)

    log(
        "[HandToolTree] %s%s visible=%s pos=%s",
        indent,
        ok and tostring(name) or "?",
        okVis and tostring(visible) or "?",
        okPos and string.format("(%.3f %.3f %.3f)", x, y, z) or "?"
    )

    local okCount, numChildren = pcall(getNumOfChildren, node)
    if not okCount then
        return
    end

    for i = 0, numChildren - 1 do
        local okChild, child = pcall(getChildAt, node, i)
        if okChild then
            dumpNodeTreeRecursive(child, depth + 1, maxDepth)
        end
    end
end

function WailaDebugTools:dumpHandToolNodeTree()
    if g_localPlayer == nil or g_localPlayer.currentHandTool == nil then
        log("[HandToolTree] not currently holding any hand tool")
        return
    end

    local handTool = g_localPlayer.currentHandTool
    log("[HandToolTree] holding: %s", tostring(handTool.typeName))

    if handTool.rootNode == nil then
        log("[HandToolTree] handTool.rootNode is nil")
        return
    end

    log("[HandToolTree] --- live scene-graph under rootNode ---")
    dumpNodeTreeRecursive(handTool.rootNode, 0, 6)
    log("[HandToolTree] --- end ---")
end
