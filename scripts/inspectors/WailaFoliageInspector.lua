-- ============================================================
-- WailaFoliageInspector
--
-- Foliage (grass/bush/etc.) lookup at a world position.
--
-- IMPORTANT: there is no engine API that hands you "what foliage
-- is planted here" directly. The foliage density map only stores
-- raw bits per FoliageMultiLayer; you have to:
--   1) know how many bits are used for the "type index" channel
--      on that layer (numTypeIndexChannels), which is only
--      declared in the map's I3D under FoliageMultiLayer/FoliageType
--   2) read the raw bits with getDensityAtWorldPos(planeId, x, 0, z)
--   3) split those bits into typeIndex (low bits) and value/growth
--      state (remaining bits) with bitAND / bitShiftRight
--   4) map typeIndex back to a name via the FoliageType list you
--      parsed from the I3D
--
-- This is exactly what ImmersiveWeathering:debugDumpFoliageLayers /
-- scanFoliageArea did. That logic got dropped in translation and
-- replaced with a made-up getDensityMapHeightTypeIndexAtWorldPos()
-- call that doesn't exist, so every lookup silently returned nil.
-- ============================================================

WailaFoliageInspector = {}
local WailaFoliageInspector_mt = Class(WailaFoliageInspector)

-- Capture the map's I3D filename as early as possible, same trick
-- ImmersiveWeathering uses. This has to happen at BaseMission.loadMap
-- time; by the time our mod's loadMap() runs it may already be gone.
WailaFoliageInspector.mapI3dFilename = nil

BaseMission.loadMap = Utils.overwrittenFunction(
    BaseMission.loadMap,
    function(mission, superFunc, filename, ...)
        WailaFoliageInspector.mapI3dFilename = filename
        return superFunc(mission, filename, ...)
    end
)

function WailaFoliageInspector.new()
    local self = setmetatable({}, WailaFoliageInspector_mt)
    self.debugData = nil -- parsed FoliageMultiLayer/FoliageType data from the map I3D
    return self
end

-- ------------------------------------------------------------
-- Step 1: parse FoliageMultiLayer / FoliageType defs from the map I3D
-- ------------------------------------------------------------
function WailaFoliageInspector:loadFoliageDebugData()
    if self.debugData ~= nil then
        return self.debugData
    end

    local filename = WailaFoliageInspector.mapI3dFilename

    if filename == nil then
        return nil
    end

    local xmlFile = XMLFile.load("WailaFoliageMapI3D", filename)

    if xmlFile == nil then
        return nil
    end

    local rootKey = "i3D.Scene.TerrainTransformGroup.Layers.FoliageSystem"

    local data = {
        multilayers = {}
    }

    local layerIndex = 0

    while true do
        local layerKey = string.format("%s.FoliageMultiLayer(%d)", rootKey, layerIndex)

        if not xmlFile:hasProperty(layerKey) then
            break
        end

        local layerData = {
            densityMapId = xmlFile:getInt(layerKey .. "#densityMapId"),
            numTypeIndexChannels = xmlFile:getInt(layerKey .. "#numTypeIndexChannels", 0),
            types = {}
        }

        local typeIndex = 0

        while true do
            local typeKey = string.format("%s.FoliageType(%d)", layerKey, typeIndex)

            if not xmlFile:hasProperty(typeKey) then
                break
            end

            -- Density-map type indices are effectively 1-based here.
            layerData.types[typeIndex + 1] = xmlFile:getString(typeKey .. "#name", "<unnamed>")

            typeIndex = typeIndex + 1
        end

        data.multilayers[layerIndex + 1] = layerData
        layerIndex = layerIndex + 1
    end

    xmlFile:delete()

    self.debugData = data

    return data
end

-- ------------------------------------------------------------
-- Step 2: match each parsed layer to its live terrainDataPlaneId by
-- cross-referencing FoliageType names against the loaded foliageSystem
-- ------------------------------------------------------------
function WailaFoliageInspector:resolveFoliagePlaneIds(data)
    if data == nil or data.planeIdsResolved then
        return
    end

    local foliageSystem = g_currentMission ~= nil and g_currentMission.foliageSystem or nil

    if foliageSystem == nil then
        return
    end

    local foliageByName = {}

    local function collect(foliages)
        for _, foliage in ipairs(foliages or {}) do
            if foliage.layerName ~= nil then
                foliageByName[foliage.layerName] = foliage
            end
        end
    end

    collect(foliageSystem.decoFoliages)
    collect(foliageSystem.paintableFoliages)

    for _, layerData in ipairs(data.multilayers) do
        for _, foliageName in pairs(layerData.types) do
            local foliage = foliageByName[foliageName]

            if foliage ~= nil and foliage.terrainDataPlaneId ~= nil then
                layerData.terrainDataPlaneId = foliage.terrainDataPlaneId
                break
            end
        end
    end

    data.planeIdsResolved = true
end

-- ------------------------------------------------------------
-- Step 3: decode the raw density bits at one world position for one layer
-- ------------------------------------------------------------
local function decodeFoliageAt(layerData, x, z)
    local planeId = layerData.terrainDataPlaneId
    local numTypeChannels = layerData.numTypeIndexChannels

    if planeId == nil or numTypeChannels == nil or numTypeChannels <= 0 then
        return nil
    end

    local bits = getDensityAtWorldPos(planeId, x, 0, z)
    local typeMask = 2 ^ numTypeChannels - 1
    local typeIndex = bitAND(bits, typeMask)

    if typeIndex <= 0 then
        return nil
    end

    local value = bitShiftRight(bits, numTypeChannels)

    if value <= 0 then
        return nil
    end

    local name = layerData.types[typeIndex] or string.format("<unknown type %d>", typeIndex)

    return name, value
end

-- ------------------------------------------------------------
-- Public: the raw, ground-truth list of layer names applyDecoFoliage/
-- getIsDecoLayerDefined actually accept, independent of whatever this
-- map's own I3D declares. A layer showing up as "paintable" in
-- listAvailableFoliage's I3D cross-reference does NOT mean it's writable
-- through applyDecoFoliage - only names in decoFoliages actually are, and
-- that array can be (and on this map is) a totally disjoint set from the
-- map's declared FoliageType names. This is what to check before ever
-- calling applyDecoFoliage with a new name again.
-- ------------------------------------------------------------
function WailaFoliageInspector:listWritableDecoLayers()
    local foliageSystem = g_currentMission ~= nil and g_currentMission.foliageSystem or nil

    if foliageSystem == nil then
        return nil
    end

    local function names(foliages)
        local result = {}
        for _, foliage in ipairs(foliages or {}) do
            if foliage.layerName ~= nil then
                table.insert(result, foliage.layerName)
            end
        end
        table.sort(result)
        return result
    end

    return {
        decoFoliages = names(foliageSystem.decoFoliages),
        paintableFoliages = names(foliageSystem.paintableFoliages),
    }
end

-- grassShort passes getIsDecoLayerDefined but was never in decoFoliages/
-- paintableFoliages when dumped above - meaning either it's checked
-- against something else on foliageSystem entirely, or there's a third
-- registry never looked at. Raw field dump instead of guessing further:
-- every top-level key on foliageSystem and its type, so anything relevant
-- actually shows up instead of staying invisible.
function WailaFoliageInspector:listFoliageSystemFields()
    local foliageSystem = g_currentMission ~= nil and g_currentMission.foliageSystem or nil

    if foliageSystem == nil then
        return nil
    end

    local fields = {}

    for key, value in pairs(foliageSystem) do
        table.insert(fields, {
            name = tostring(key),
            valueType = type(value),
            length = type(value) == "table" and #value or nil,
        })
    end

    table.sort(fields, function(a, b) return a.name < b.name end)

    return fields
end

-- kind = "deco"/"paintable"/"unknown" per layerName, built from
-- foliageSystem.decoFoliages/.paintableFoliages. Cached once per session -
-- these lists don't change after map load. NOTE: confirmed NOT the full
-- writable/readable vocabulary (see docs/engine-api/FoliageDensityMap.md) -
-- anything only reachable via a map.xml <mapping> alias (not this map's own
-- I3D-declared FoliageType name) will show up here as "unknown" even though
-- it's genuinely one or the other. Honest gap, not a bug.
function WailaFoliageInspector:getKindByLayerName()
    if self.kindByLayerName ~= nil then
        return self.kindByLayerName
    end

    local foliageSystem = g_currentMission ~= nil and g_currentMission.foliageSystem or nil
    local kindByLayerName = {}

    if foliageSystem ~= nil then
        for _, foliage in ipairs(foliageSystem.decoFoliages or {}) do
            if foliage.layerName ~= nil then
                kindByLayerName[foliage.layerName] = "deco"
            end
        end
        for _, foliage in ipairs(foliageSystem.paintableFoliages or {}) do
            if foliage.layerName ~= nil then
                -- A layer can be BOTH deco and paintable (this map declares
                -- decoFoliage/decoBush/forestBush/forestGrass under both
                -- blocks) - "paintable" wins the tag since it's the more
                -- specific claim (this layer is also editor/tool-paintable).
                kindByLayerName[foliage.layerName] = "paintable"
            end
        end
    end

    self.kindByLayerName = kindByLayerName

    return kindByLayerName
end

-- ------------------------------------------------------------
-- Public: what's under the crosshair right now
-- ------------------------------------------------------------
function WailaFoliageInspector:inspectPoint(x, z)
    local data = self:loadFoliageDebugData()

    if data == nil then
        return {}
    end

    self:resolveFoliagePlaneIds(data)

    local kindByLayerName = self:getKindByLayerName()
    local hits = {}

    for _, layerData in ipairs(data.multilayers) do
        local name, value = decodeFoliageAt(layerData, x, z)

        if name ~= nil then
            table.insert(hits, {name = name, density = value, kind = kindByLayerName[name] or "unknown"})
        end
    end

    return hits
end

-- ------------------------------------------------------------
-- Public: coverage stats over an area, same shape WailaTerrainInspector
-- returns (sampleCount + sortedCounts) so WailaHud can render both alike
-- ------------------------------------------------------------
-- ------------------------------------------------------------
-- Public: every foliage type this map defines, deco vs paintable,
-- so you don't have to reverse-engineer the map I3D by hand again.
-- ------------------------------------------------------------
function WailaFoliageInspector:listAvailableFoliage()
    local data = self:loadFoliageDebugData()

    if data == nil then
        return nil
    end

    self:resolveFoliagePlaneIds(data)

    local kindByLayerName = self:getKindByLayerName()
    local layers = {}

    for layerIndex, layerData in ipairs(data.multilayers) do
        local types = {}

        for typeIndex, name in pairs(layerData.types) do
            table.insert(types, {
                typeIndex = typeIndex,
                name = name,
                kind = kindByLayerName[name] or "unknown"
            })
        end

        table.sort(types, function(a, b) return a.typeIndex < b.typeIndex end)

        table.insert(layers, {
            layerIndex = layerIndex,
            densityMapId = layerData.densityMapId,
            terrainDataPlaneId = layerData.terrainDataPlaneId,
            numTypeIndexChannels = layerData.numTypeIndexChannels,
            types = types
        })
    end

    return layers
end

function WailaFoliageInspector:scanArea(centerX, centerZ, size, step)
    local data = self:loadFoliageDebugData()

    if data == nil then
        return {sampleCount = 0, foliage = {}}
    end

    self:resolveFoliagePlaneIds(data)

    local half = size * 0.5
    local counts = {}
    local samples = 0
    local occupiedSamples = 0

    for x = centerX - half, centerX + half - 0.0001, step do
        for z = centerZ - half, centerZ + half - 0.0001, step do
            samples = samples + 1
            local occupied = false

            for _, layerData in ipairs(data.multilayers) do
                local name, value = decodeFoliageAt(layerData, x, z)

                if name ~= nil then
                    -- Keep growth levels distinct: grass at density level 1
                    -- (freshly grown) and level 2 (grown further) are two
                    -- different farming-relevant states, not one bucket.
                    local key = string.format("%s L%d", name, value)
                    counts[key] = (counts[key] or 0) + 1
                    occupied = true
                end
            end

            if occupied then
                occupiedSamples = occupiedSamples + 1
            end
        end
    end

    counts["<empty>"] = math.max(0, samples - occupiedSamples)

    return {
        sampleCount = samples,
        foliage = WailaUtil.sortedCounts(counts, samples)
    }
end
