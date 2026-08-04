FS25WhatAmILookingAt = {}

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] " .. formatString, ...)
end

function FS25WhatAmILookingAt:loadMap()
    self.enabled = false
    self.raycaster = WailaRaycaster.new()
    self.terrainInspector = WailaTerrainInspector.new()
    self.foliageInspector = WailaFoliageInspector.new()
    self.objectInspector = WailaObjectInspector.new()
    self.vehicleInspector = WailaVehicleInspector.new()
    self.hud = WailaHud.new()
    self.debugTools = WailaDebugTools.new()

    self.areaSize = 5
    self.areaStep = 0.5
    self.pointIntervalMs = 100
    self.areaIntervalMs = 400
    self.pointTimer = 0
    self.areaTimer = 0
    self.lastAreaX = nil
    self.lastAreaZ = nil
    self.current = nil

    log("loaded; Shift+M toggles the inspector HUD")
end

function FS25WhatAmILookingAt:deleteMap()
    g_inputBinding:removeActionEventsByTarget(self)
end

function FS25WhatAmILookingAt:registerActionEvents()
    local _, toggleId = g_inputBinding:registerActionEvent(
        InputAction.WAILA_TOGGLE_HUD,
        self,
        self.onToggleHud,
        false, true, false, true, nil, true
    )
    if toggleId ~= nil then
        g_inputBinding:setActionEventTextPriority(toggleId, GS_PRIO_NORMAL)
        g_inputBinding:setActionEventTextVisibility(toggleId, true)
    end

    local _, dumpId = g_inputBinding:registerActionEvent(
        InputAction.WAILA_DUMP_TARGET,
        self,
        self.onDumpTarget,
        false, true, false, true, nil, true
    )
    if dumpId ~= nil then
        g_inputBinding:setActionEventTextPriority(dumpId, GS_PRIO_LOW)
        g_inputBinding:setActionEventTextVisibility(dumpId, false)
    end

    local _, catalogId = g_inputBinding:registerActionEvent(
        InputAction.WAILA_DUMP_FOLIAGE_CATALOG,
        self,
        self.onDumpFoliageCatalog,
        false, true, false, true, nil, true
    )
    if catalogId ~= nil then
        g_inputBinding:setActionEventTextPriority(catalogId, GS_PRIO_LOW)
        g_inputBinding:setActionEventTextVisibility(catalogId, false)
    end

    local _, debugMenuId = g_inputBinding:registerActionEvent(
        InputAction.WAILA_DEBUG_MENU,
        self,
        self.onDebugMenu,
        false, true, false, true, nil, true
    )
    if debugMenuId ~= nil then
        g_inputBinding:setActionEventTextPriority(debugMenuId, GS_PRIO_LOW)
        g_inputBinding:setActionEventTextVisibility(debugMenuId, false)
    end
end

function FS25WhatAmILookingAt:onToggleHud()
    self.enabled = not self.enabled
    self.pointTimer = 0
    self.areaTimer = 0

    log("HUD %s", self.enabled and "enabled" or "disabled")
end

function FS25WhatAmILookingAt:onDumpTarget()
    if self.enabled then
        WailaDebugDump.dump(self.current)
    end
end

function FS25WhatAmILookingAt:onDumpFoliageCatalog()
    WailaDebugDump.dumpFoliageCatalog(
        self.foliageInspector:listAvailableFoliage(),
        self.foliageInspector:listWritableDecoLayers(),
        self.foliageInspector:listFoliageSystemFields()
    )
end

function FS25WhatAmILookingAt:onDebugMenu()
    self:showDebugMenu()
end

-- These four all act at the current crosshair target (self.current.hit,
-- already continuously maintained by the point raycast every frame) -
-- unlike their original IW versions, no fresh raycast needed here.
function FS25WhatAmILookingAt:onPlaceFoliageTestRig()
    if self.current == nil or self.current.hit == nil then
        log("[TestRig] No current terrain target")
        return
    end

    self.debugTools:placeFoliageTestRig(self.current.hit.x, self.current.hit.z)
end

function FS25WhatAmILookingAt:onDumpTerrainLayers()
    self.debugTools:dumpTerrainLayers()
end

function FS25WhatAmILookingAt:onPlaceTerrainLayerTestRow()
    if self.current == nil or self.current.hit == nil then
        log("[LayerTest] No current terrain target")
        return
    end

    self.debugTools:placeTerrainLayerTestRow(self.current.hit.x, self.current.hit.z)
end

function FS25WhatAmILookingAt:onDumpDensityProbe()
    if self.current == nil or self.current.hit == nil then
        log("[DensityProbe] No current terrain target")
        return
    end

    self.debugTools:dumpDensityProbe(self.current.hit.x, self.current.hit.y, self.current.hit.z)
end

function FS25WhatAmILookingAt:onDumpGroundDensityProbe()
    if self.current == nil or self.current.hit == nil then
        log("[GroundProbe] No current terrain target")
        return
    end

    self.debugTools:dumpGroundDensityProbe(self.current.hit.x, self.current.hit.y, self.current.hit.z)
end

function FS25WhatAmILookingAt:onDumpEnvironment()
    self.debugTools:dumpEnvironment()
end

-- Same OptionDialog pattern as IW's own debug menu (ImmersiveWeathering:
-- showDebugMenu) - a real base-game GUI class (dataS/gui/dialogs/, same
-- family as YesNoDialog/TextInputDialog), not a dependency between the
-- two mods, just a shared pattern. This is meant to be the landing spot
-- for world-inspection debug tools currently living in IW (terrain layer
-- dump, paint layer test row, density probe) that architecturally belong
-- here instead - not moved yet, this is the menu they'll move into.
function FS25WhatAmILookingAt:showDebugMenu()
    local actions = {
        { "Dump inspected target", self.onDumpTarget },
        { "Dump foliage catalog for this map", self.onDumpFoliageCatalog },
        { "Place foliage test rig", self.onPlaceFoliageTestRig },
        { "Dump terrain layers", self.onDumpTerrainLayers },
        { "Paint layer test row", self.onPlaceTerrainLayerTestRow },
        { "Dump density probe", self.onDumpDensityProbe },
        { "Dump ground layer dataPlane probe", self.onDumpGroundDensityProbe },
        { "Dump environment/weather state", self.onDumpEnvironment },
    }

    local options = {}
    for index, action in ipairs(actions) do
        options[#options + 1] = index .. ") " .. action[1]
    end

    local target = self
    local function onDebugMenuSelected(callbackTarget, selectedOption, args)
        log("[DebugMenu] callback fired, selectedOption=%s", tostring(selectedOption))

        if type(selectedOption) ~= "number" or selectedOption == 0 then
            return
        end

        local action = actions[selectedOption]

        if action ~= nil and action[2] ~= nil then
            log("[DebugMenu] running action %d: %s", selectedOption, action[1])
            action[2](target)
        end
    end

    OptionDialog.createFromExistingGui({
        options = options,
        optionText = "Choose a debug action",
        optionTitle = "WAILA Debug Tools",
        callbackFunc = onDebugMenuSelected,
    }, "WailaDebugMenuOptionDialog")

    local optionDialog = OptionDialog.INSTANCE
    optionDialog.optionElement:setState(1)
    optionDialog:setCallback(onDebugMenuSelected, target, {})
end

function FS25WhatAmILookingAt:update(dt)
    if g_currentMission == nil or g_gui:getIsGuiVisible() then
        return
    end

    -- dt is milliseconds here (pointIntervalMs is compared against it
    -- directly below) - smoothed rather than raw 1000/dt, which jitters
    -- too much frame to frame to read.
    if dt > 0 then
        local instantFps = 1000 / dt
        self.fps = self.fps and (self.fps * 0.9 + instantFps * 0.1) or instantFps
    end

    -- The lightweight point raycast now runs regardless of self.enabled,
    -- so the always-on mini HUD summary has something current to show
    -- even with the full inspector toggled off - timed directly so we can
    -- actually see whether that background scanning costs anything,
    -- rather than guessing from overall FPS (which every other mod and
    -- the base game itself also feed into). The heavier area/foliage scan
    -- stays gated behind self.enabled below - only the full detailed view
    -- needs it, no reason to pay for it just for a one-line summary.
    self.pointTimer = self.pointTimer - dt

    if self.pointTimer <= 0 then
        self.pointTimer = self.pointIntervalMs
        local startTime = getTimeSec()
        self:updatePointInspection()
        self.lastScanMs = (getTimeSec() - startTime) * 1000
    end

    if not self.enabled then
        return
    end

    self.areaTimer = self.areaTimer - dt

    if self.current ~= nil and self.current.hit ~= nil then
        local x = self.current.hit.x
        local z = self.current.hit.z
        local moved = self.lastAreaX == nil or MathUtil.vector2Length(x - self.lastAreaX, z - self.lastAreaZ) >= 0.5

        if self.areaTimer <= 0 and moved then
            self.areaTimer = self.areaIntervalMs
            self:updateAreaInspection(x, z)
            self.lastAreaX = x
            self.lastAreaZ = z
        end
    end
end

-- Confirmed real via base game source (dataS/scripts/vehicles/
-- specializations/Washable.lua), not scriptBinding.xml - see
-- docs/engine-api/Weather.md. isRaining is the base game's own three-part
-- formula, not a simple flag - copying just rainScale > 0.1 alone would
-- also count fresh snow as rain.
function FS25WhatAmILookingAt:readWeather()
    if g_currentMission == nil or g_currentMission.environment == nil or g_currentMission.environment.weather == nil then
        return nil
    end

    local weather = g_currentMission.environment.weather
    local ok, rainScale, timeSinceLastRain, temperature = pcall(function()
        return weather:getRainFallScale(), weather:getTimeSinceLastRain(), weather:getCurrentTemperature()
    end)

    if not ok then
        return nil
    end

    return {
        rainScale = rainScale,
        timeSinceLastRain = timeSinceLastRain,
        temperature = temperature,
        isRaining = rainScale > 0.1 and timeSinceLastRain < 30 and temperature > 0,
    }
end

function FS25WhatAmILookingAt:updatePointInspection()
    -- Read unconditionally, before the no-hit early return below - weather
    -- is global state, not tied to whether the crosshair is over terrain.
    local weather = self:readWeather()

    local hit = self.raycaster:castFromCamera()
    if hit == nil then
        self.current = {hit = nil, weather = weather}
        return
    end

    self.current = self.current or {}
    self.current.hit = hit
    self.current.weather = weather
    self.current.object = self.objectInspector:inspect(hit)
    self.current.vehicle = self.vehicleInspector:inspect(hit, self.current.object)

    if self.current.vehicle == nil then
        self.current.terrain = self.terrainInspector:inspectPoint(hit.x, hit.y, hit.z)
        self.current.foliagePoint = self.foliageInspector:inspectPoint(hit.x, hit.z)
    else
        self.current.terrain = nil
        self.current.foliagePoint = nil
        self.current.terrainArea = nil
        self.current.foliageArea = nil
    end
end

function FS25WhatAmILookingAt:updateAreaInspection(x, z)
    if self.current.vehicle ~= nil then
        return
    end

    self.current.terrainArea = self.terrainInspector:scanArea(x, z, self.areaSize, self.areaStep)
    self.current.foliageArea = self.foliageInspector:scanArea(x, z, self.areaSize, self.areaStep)
end

function FS25WhatAmILookingAt:draw()
    if g_gui:getIsGuiVisible() then
        return
    end

    -- Mini summary always draws, same corner regardless of whether the
    -- full inspector is toggled on - Shift+M just decides whether the
    -- full detailed panel slides open beneath it.
    self.hud:drawMini(self.current, {fps = self.fps, scanMs = self.lastScanMs})

    if self.enabled then
        self.hud:draw(self.current, self.areaSize, self.areaStep)
    end
end

PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
    PlayerInputComponent.registerGlobalPlayerActionEvents,
    function()
        FS25WhatAmILookingAt:registerActionEvents()
    end
)

addModEventListener(FS25WhatAmILookingAt)
