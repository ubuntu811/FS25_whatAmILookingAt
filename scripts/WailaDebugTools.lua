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
    -- FS25_CreativeHorizonIW's own layer set - the original list above
    -- predates that map's IW integration entirely, so none of its own
    -- decoFoliage regional variants or "cheese the system" crop layers
    -- (see that map's own iw-map.xml) were ever in this grid. Same
    -- "don't assume, read the result" reasoning - undefined on whatever
    -- map is currently loaded just means an empty cell, not an error.
    "decoFoliageAS", "decoFoliageUS", "decoBushEU", "decoStones", "poplar",
    "grass", "fieldGrass",
    -- This map's own "New crops" (per its modDesc.xml description) -
    -- the actual point of the complaint that led here: these were
    -- declared in iw-map.xml but never added to THIS grid, so the test
    -- rig couldn't show them regardless of how IW's own palette weighted
    -- them.
    "rye", "spelt", "triticale", "greenRye", "vetchRye", "mustard",
    "humusactive", "silageMaize", "floweringCatchCrop", "winterWheat",
    "winterBarley", "alfalfa", "clover",
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

function WailaDebugTools.new()
    local self = setmetatable({}, WailaDebugTools_mt)

    -- Registered once per TYPE, not per area instance -- see
    -- Waila.registerAreaType's own comment for why (an area restored
    -- from waila.xml has no live function fields of its own, only its
    -- type string survives). Covers every waila_foliage_testrig area
    -- regardless of whether it was just placed or restored from a save.
    Waila.registerAreaType(WailaDebugTools.TEST_RIG_AREA_TYPE, {
        actionLabel = "Reset foliage test rig",
        actionCallback = function(area)
            self:resetFoliageTestRig(area.metadata.originX, area.metadata.originZ, area.metadata.rotationY)
        end,
        deleteCallback = function(area)
            self:clearFoliageTestRigGrid(area.metadata.originX, area.metadata.originZ, area.metadata.rotationY)
            self:clearConcreteBorder(area.metadata.originX, area.metadata.originZ, area.metadata.rotationY)
        end,
    })

    return self
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

-- Real angle-control problem found live: the rig used to be pure
-- axis-aligned offsets from origin, no rotation input anywhere -- placed
-- via a raw debug button with whatever direction the last raycast
-- happened to face, no way to steer it, confirmed live running straight
-- across a road. rotationY (radians, defaults to 0 = old behavior
-- exactly) rotates every local offset around the origin before use --
-- shared by placement AND both clear paths, so a rig placed at an angle
-- gets cleared at that same angle, not wherever the axis-aligned version
-- would have painted.
local function rotateOffset(dx, dz, rotationY)
    if rotationY == nil or rotationY == 0 then
        return dx, dz
    end
    local cosR, sinR = math.cos(rotationY), math.sin(rotationY)
    return dx * cosR + dz * sinR, -dx * sinR + dz * cosR
end

-- The 4 corners of the border rectangle, in local (pre-rotation) space,
-- rotated and translated to world space, in edge order (each consecutive
-- pair is one straight edge -- true even after rotation, since rotating
-- a rectangle keeps its edges straight, just no longer axis-aligned).
-- Shared by the border painter AND computeTestRigBorderBounds, so a
-- rotated rig's declared-area box and its actual painted outline are
-- always derived from the identical 4 points.
local function computeTestRigBorderCorners(originX, originZ, rotationY)
    local borderMargin = 1.0
    local localMinX, localMaxX = -borderMargin, TEST_RIG_GRID_STATES * TEST_RIG_SPACING + borderMargin
    local localMinZ, localMaxZ = -borderMargin, (#TEST_RIG_GRID_LAYERS - 1) * TEST_RIG_SPACING + borderMargin
    local localCorners = {
        { localMinX, localMinZ }, { localMaxX, localMinZ },
        { localMaxX, localMaxZ }, { localMinX, localMaxZ },
    }
    local corners = {}
    for i, corner in ipairs(localCorners) do
        local dx, dz = rotateOffset(corner[1], corner[2], rotationY)
        corners[i] = { originX + dx, originZ + dz }
    end
    return corners
end

-- Axis-aligned bounding box around the (possibly rotated) corners --
-- WAILA's own box-type declared area has no rotation concept at all
-- (see WailaDeclaredArea.lua, plain minX/maxX/minZ/maxZ), so this is
-- deliberately a conservative box that fully contains the real rotated
-- shape, not the shape itself.
local function computeTestRigBorderBounds(originX, originZ, rotationY)
    local corners = computeTestRigBorderCorners(originX, originZ, rotationY)
    local minX, maxX = corners[1][1], corners[1][1]
    local minZ, maxZ = corners[1][2], corners[1][2]
    for i = 2, 4 do
        minX = math.min(minX, corners[i][1])
        maxX = math.max(maxX, corners[i][1])
        minZ = math.min(minZ, corners[i][2])
        maxZ = math.max(maxZ, corners[i][2])
    end
    return minX, maxX, minZ, maxZ
end

-- Steps along each of the 4 (possibly rotated) edges in AREA_FILL_STEP
-- increments, painting layerId at every step -- replaces the old fixed-
-- axis "step X at min/max Z, step Z at min/max X" loop, which only ever
-- traced an axis-aligned rectangle. Linear interpolation between two
-- corners still traces a straight line post-rotation (rotation preserves
-- straightness), so this is exact, not an approximation.
local function paintTestRigBorder(self, corners, layerId)
    for i = 1, 4 do
        local ax, az = corners[i][1], corners[i][2]
        local bx, bz = corners[i % 4 + 1][1], corners[i % 4 + 1][2]
        local edgeLength = math.sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az))
        local numSteps = math.max(1, math.floor(edgeLength / AREA_FILL_STEP))
        for step = 0, numSteps do
            local t = step / numSteps
            self:paintTerrainAtLayer(ax + (bx - ax) * t, az + (bz - az) * t, layerId)
        end
    end
end

-- Split out so a real placeable (see PlaceableWailaTestRig) can
-- re-assert its declared area on every reload without repainting
-- anything -- terrain writes persist on their own (density map data,
-- not placeable state), only WAILA's own in-memory registry needs
-- re-asserting. wailaID optional, nil lets Waila.registerArea
-- auto-generate one (the plain debug-hub button's own use case, no
-- stable identity to derive one from); a placeable passes its own
-- stable id (derived from getUniqueId()) so repeated calls upsert
-- instead of accumulating duplicates, same fix Daisychain's own
-- registerWithWaila needed for the identical reason.
-- Thin public wrapper so PlaceableWailaTestRig can draw a live preview
-- outline using the exact same 4 corners the real border painting uses
-- (see paintTestRigBorder) -- no separate shape math to drift out of
-- sync with what actually gets painted on finalize.
function WailaDebugTools:getTestRigBorderCorners(originX, originZ, rotationY)
    return computeTestRigBorderCorners(originX, originZ, rotationY or 0)
end

function WailaDebugTools:registerTestRigArea(originX, originZ, rotationY, wailaID)
    local minX, maxX, minZ, maxZ = computeTestRigBorderBounds(originX, originZ, rotationY)
    return Waila.registerArea({
        type = WailaDebugTools.TEST_RIG_AREA_TYPE,
        wailaID = wailaID,
        box = { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ },
        metadata = { originX = originX, originZ = originZ, rotationY = rotationY },
    })
end

-- clearExisting (default true) exists ONLY for the plain debug-hub
-- button's own original singleton behavior -- it never carried a stable
-- wailaID, so there was never more than one rig conceptually, and
-- re-running the button was always meant to replace it. Real bug found
-- live once this became a real, multi-instance placeable: placing a
-- SECOND rig wiped the first, because this whole block ran unconditionally
-- for every placement regardless of how many rigs already existed
-- elsewhere. PlaceableWailaTestRig now explicitly passes false.
function WailaDebugTools:placeFoliageTestRig(hx, hz, rotationY, wailaID, clearExisting)
    rotationY = rotationY or 0
    if clearExisting == nil then
        clearExisting = true
    end
    log("[TestRig] --- mapping grid (layer rows x state 0-15 columns), rotationY=%.3f clearExisting=%s ---", rotationY, tostring(clearExisting))

    -- Declared-area dogfood case: re-placing the rig should replace its
    -- own area, not accumulate a fresh stale rectangle on top of every
    -- past placement. Cleared by type (WailaAreaIndex:clear()), not via a
    -- remembered instance-field reference -- an area restored from
    -- waila.xml on load has no such reference pointing to it yet, but
    -- clearing by type name catches it correctly regardless.
    --
    -- BEFORE placing anything, not after -- confirmed live (Reset ending
    -- up as a bare dirt patch, no rig at all): this used to run AFTER
    -- the grid/border were freshly painted below, so on a Reset (same
    -- origin as the area being replaced) it immediately wiped the stuff
    -- this same function had just placed a few lines earlier.
    local existingIndex = clearExisting and Waila.indices[WailaDebugTools.TEST_RIG_AREA_TYPE] or nil
    if existingIndex ~= nil and existingIndex.className == WailaAreaIndex.MARKER then
        for _, existingArea in ipairs(existingIndex:getAll()) do
            self:clearFoliageTestRigGrid(existingArea.metadata.originX, existingArea.metadata.originZ, existingArea.metadata.rotationY)
            self:clearConcreteBorder(existingArea.metadata.originX, existingArea.metadata.originZ, existingArea.metadata.rotationY)
        end
        existingIndex:clear()
    end

    local concreteLayerId = self:getTerrainLayerIdByName("CONCRETEINDUSTRIAL")

    for row, layerName in ipairs(TEST_RIG_GRID_LAYERS) do
        local maxState = TEST_RIG_GRID_MAX_STATE[layerName] or TEST_RIG_GRID_STATES

        for state = 0, TEST_RIG_GRID_STATES do
            local dx, dz = rotateOffset(state * TEST_RIG_SPACING, (row - 1) * TEST_RIG_SPACING, rotationY)
            local px, pz = hx + dx, hz + dz
            local name = layerName .. "_s" .. state
            local ok = self:placeFoliage(px, pz, name)
            log("[TestRig] [grid %s x%d] %s at (%.2f %.2f) -> %s", layerName, state, name, px, pz, tostring(ok))

            if state > maxState and concreteLayerId ~= nil then
                self:paintTerrainAtLayer(px, pz, concreteLayerId)
            end
        end
    end

    local corners = computeTestRigBorderCorners(hx, hz, rotationY)

    if concreteLayerId ~= nil then
        paintTestRigBorder(self, corners, concreteLayerId)
        log("[TestRig] border painted around corners=%s", table.concat({
            string.format("(%.1f,%.1f)", corners[1][1], corners[1][2]),
            string.format("(%.1f,%.1f)", corners[2][1], corners[2][2]),
            string.format("(%.1f,%.1f)", corners[3][1], corners[3][2]),
            string.format("(%.1f,%.1f)", corners[4][1], corners[4][2]),
        }, " "))
    else
        log("[TestRig] CONCRETEINDUSTRIAL layer not found, skipping border")
    end

    -- actionLabel/actionCallback/deleteCallback deliberately NOT set
    -- here anymore -- they're registered once by TYPE instead (see
    -- WailaDebugTools.new()), which also covers an area restored from
    -- waila.xml, not just a freshly-placed one.
    self:registerTestRigArea(hx, hz, rotationY, wailaID)
    log("[TestRig] declared area registered, origin=(%.2f %.2f) rotationY=%.3f", hx, hz, rotationY)
end

-- Meters -- half-size of the clearing quad per grid point. Was 1.0
-- (exactly half of TEST_RIG_SPACING, i.e. zero overlap between
-- neighboring grid points' clear quads) -- confirmed live that this was
-- too tight: placeFoliage's own quad is randomly ROTATED, so its
-- corner-to-center distance can approach halfSize*sqrt(2) (~0.99m at
-- halfSize's own max of 0.7m), right at the edge of a 1.0m axis-aligned
-- clear quad with no margin for rounding. 2.0m gives real overlap with
-- every neighbor (clearing the same spot twice is a harmless no-op, see
-- clearFoliageQuad), trading a bit of redundant work for actually
-- reliable coverage.
local CLEAR_QUAD_HALF_SIZE = 2.0

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

-- Clears every grid point placeFoliageTestRig wrote to, without
-- replanting -- split out of resetFoliageTestRig so the declared area's
-- deleteCallback (see WailaDebugTools.new's type registration) can reuse
-- just the clearing half. Deco foliage is an overlay, not baked into the
-- terrain texture, so clearing it does reveal clean ground underneath --
-- doesn't touch the concrete BORDER though, that's a terrain PAINT
-- change, a completely separate subsystem (see clearConcreteBorder).
--
-- Also repaints dirt over placeFoliageTestRig's own INTERIOR concrete
-- dabs -- confirmed live (screenshot showed a visible row of leftover
-- dots after delete): forestGrass/forestBush cap out at
-- TEST_RIG_GRID_MAX_STATE=1, so placement paints an individual
-- CONCRETEINDUSTRIAL dab at every state beyond that (14 points per row,
-- see placeFoliageTestRig's own `state > maxState` check) -- these sit
-- well inside the grid, nowhere near the outer border the border-repaint
-- loop walks, so neither existing cleanup path touched them. Mirrors
-- placeFoliageTestRig's own condition exactly, just painting dirt01
-- instead of concrete.
function WailaDebugTools:clearFoliageTestRigGrid(originX, originZ, rotationY)
    rotationY = rotationY or 0
    local dirtLayerId = self:getTerrainLayerIdByName("dirt01")

    for row, layerName in ipairs(TEST_RIG_GRID_LAYERS) do
        local maxState = TEST_RIG_GRID_MAX_STATE[layerName] or TEST_RIG_GRID_STATES

        for state = 0, TEST_RIG_GRID_STATES do
            local dx, dz = rotateOffset(state * TEST_RIG_SPACING, (row - 1) * TEST_RIG_SPACING, rotationY)
            local px, pz = originX + dx, originZ + dz
            self:clearFoliageQuad(px, pz)

            if state > maxState and dirtLayerId ~= nil then
                self:paintTerrainAtLayer(px, pz, dirtLayerId)
            end
        end
    end
end

-- There's no "un-paint" primitive, only "paint over with something
-- else" -- repaints the exact same outline placeFoliageTestRig's own
-- border loop painted (computeTestRigBorderBounds, same math both
-- places), using "dirt01" (a real, confirmed layer name on this map --
-- see GROUND_LAYER_NAMES) as a reasonable default rather than trying to
-- remember/restore whatever layer was actually there before the rig was
-- placed, which was never recorded anywhere.
function WailaDebugTools:clearConcreteBorder(originX, originZ, rotationY)
    local dirtLayerId = self:getTerrainLayerIdByName("dirt01")
    if dirtLayerId == nil then
        log("[TestRig] dirt01 layer not found, skipping border cleanup")
        return
    end

    local corners = computeTestRigBorderCorners(originX, originZ, rotationY or 0)
    paintTestRigBorder(self, corners, dirtLayerId)
    log("[TestRig] border repainted with dirt01 around origin=(%.2f %.2f) rotationY=%.3f", originX, originZ, rotationY or 0)
end

-- Clears the grid, then re-places a fresh rig at the same origin -- the
-- "press [key] to reset" action attached to its declared area above
-- (also surfaced as a row in WailaDebugHubDialog's action list, see
-- area.actionLabel/actionCallback).
-- placeFoliageTestRig now clears whatever test rig area is already
-- registered (same type, same origin here) BEFORE placing, so this is
-- just a thin, differently-named entry point -- kept separate from a
-- bare placeFoliageTestRig call since "Reset" is a distinct, named
-- action in the hub/world-key UI, not because it needs different logic.
function WailaDebugTools:resetFoliageTestRig(originX, originZ, rotationY)
    log("[TestRig] Resetting at origin (%.2f %.2f) rotationY=%.3f", originX, originZ, rotationY or 0)
    self:placeFoliageTestRig(originX, originZ, rotationY)
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
