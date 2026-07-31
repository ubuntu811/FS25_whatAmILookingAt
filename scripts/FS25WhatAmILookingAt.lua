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

function FS25WhatAmILookingAt:updatePointInspection()
    local hit = self.raycaster:castFromCamera()
    if hit == nil then
        self.current = {hit = nil}
        return
    end

    self.current = self.current or {}
    self.current.hit = hit
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
