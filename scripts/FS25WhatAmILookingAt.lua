FS25WhatAmILookingAt = {}

-- Captured at top level, not inside loadMap() -- g_currentModDirectory is
-- only reliably THIS mod's own folder during THIS file's own load, not
-- later once every mod has finished loading (confirmed pattern: real,
-- installed mod FS25_MapObjectsHider does the exact same thing,
-- MapObjectsHider.modDirectory = g_currentModDirectory as a top-level
-- assignment). Needed for g_gui:loadGui's XML path below.
FS25WhatAmILookingAt.MOD_DIRECTORY = g_currentModDirectory

-- Real, required registration -- confirmed missing entirely, caught live
-- via "no addConstructionTab refs in waila" while chasing why the new
-- wailaFoliageTestRig placeable's own <tab>waila</tab> reference never
-- produced an actual tab. Declaring a tab name in a store item's xml
-- does nothing by itself; the tab has to be created explicitly. Same
-- real, proven pattern (and the same two failed timing attempts before
-- it) Daisychain's own FS25Daisychain.lua already documents: top-level
-- code runs before the "decoration" category exists yet
-- (addConstructionTab silently no-ops on a nil category, no error at
-- all), loadMap() runs too late (well after loadMapData() has already
-- validated every store item's <brush><tab> reference). Overwriting
-- StoreManager.loadMapData itself lands exactly between those two
-- failure points -- superFunc() creates the category and queues (but
-- doesn't yet resolve) every store item's async load, so the tab exists
-- by the time any of them are actually checked against it.
local function loadConstructionTab(self, superFunc, xmlFile, missionInfo, baseDirectory)
    superFunc(self, xmlFile, missionInfo, baseDirectory)
    g_storeManager:addConstructionTab("decoration", "waila", "WAILA", nil, nil, FS25WhatAmILookingAt.MOD_DIRECTORY, nil)
end
StoreManager.loadMapData = Utils.overwrittenFunction(StoreManager.loadMapData, loadConstructionTab)

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] " .. formatString, ...)
end

-- Reads this mod's own <extraSourceFiles><sourceFile filename="..."/>
-- list straight out of its modDesc.xml -- single source of truth for
-- what "reload WAILA" re-source()'s, instead of hand-maintaining a
-- second copy of the file list that could drift. Same XMLFile API
-- already proven in WailaFieldIndex's own load/saveToXML.
--
-- FS25WhatAmILookingAt.lua and Waila.lua are deliberately skipped: both
-- have top-level code that isn't safe to re-run mid-session --
-- FS25WhatAmILookingAt.lua re-registering addModEventListener/
-- appendedFunction hooks would duplicate them, and Waila.lua's
-- `Waila.indices = {}` / `Waila.debugTabs = {}` / `Waila.reloadables =
-- {}` would wipe the very registries this reload is using (including,
-- for the last one, itself mid-loop). A structural change to either
-- file still needs a real reload -- everything else (inspectors, HUD,
-- debug tools, the field scanner, the GUI dialog) is fair game.
local RELOAD_EXCLUDED_FILES = { ["scripts/FS25WhatAmILookingAt.lua"] = true, ["scripts/Waila.lua"] = true }

function FS25WhatAmILookingAt.readOwnSourceFiles()
    local files = {}
    local xmlFile = XMLFile.loadIfExists("wailaModDesc", FS25WhatAmILookingAt.MOD_DIRECTORY .. "modDesc.xml")
    if xmlFile ~= nil then
        for _, key in xmlFile:iterator("modDesc.extraSourceFiles.sourceFile") do
            local filename = xmlFile:getString(key .. "#filename")
            if filename ~= nil and not RELOAD_EXCLUDED_FILES[filename] then
                table.insert(files, filename)
            end
        end
        xmlFile:delete()
    end
    return files
end

-- Everything loadMap() needs to (re)create -- split out so the same
-- logic can run again from Waila.reloadAll() without a real map/
-- savegame reload. Paired with teardownComponents() below.
function FS25WhatAmILookingAt:setupComponents()
    self.enabled = false
    self.raycaster = WailaRaycaster.new()
    self.terrainInspector = WailaTerrainInspector.new()
    self.foliageInspector = WailaFoliageInspector.new()
    self.objectInspector = WailaObjectInspector.new()
    self.vehicleInspector = WailaVehicleInspector.new()
    self.fieldInspector = WailaFieldInspector.new()
    self.hud = WailaHud.new()
    self.debugTools = WailaDebugTools.new()

    -- First piece of the "waila.get(type, coords)" world index -- see the
    -- waila-field-index-migration memory.
    self.fieldIndex = WailaFieldIndex.new()
    self.fieldIndex:start()
    Waila.indices.field = self.fieldIndex

    self.areaTracker = WailaAreaTracker.new()

    -- Real GUI screen registration -- g_gui:loadGui(xmlPath, name,
    -- controllerInstance) pairs the layout XML with its Lua controller
    -- under a string name, opened later via g_gui:showDialog(name) (see
    -- onOpenDebugHub). Confirmed pattern via reading FS25_MapObjectsHider's
    -- own source (a real, installed mod), not guessed.
    --
    -- First load only (self.debugHubGui == nil) -- confirmed live that
    -- re-registering the same GUI_NAME on a reload, after
    -- WailaDebugHubDialog.lua got re-source()'d, corrupts the screen tree
    -- badly enough to crash the whole game (stack overflow inside the
    -- engine's own TextElement:update, not even a catchable Lua error --
    -- the earlier pcall around this call couldn't save it). So: GUI/XML
    -- changes still need a real restart to show up; a reload just leaves
    -- the existing dialog instance alone and reloads everything else
    -- (inspectors, HUD, field index, debug tools) safely.
    if self.debugHubGui == nil then
        self.debugHubGui = g_gui:loadGui(
            FS25WhatAmILookingAt.MOD_DIRECTORY .. "gui/WailaDebugHubDialog.xml",
            WailaDebugHubDialog.GUI_NAME,
            WailaDebugHubDialog.new()
        )
    end

    -- WAILA's own built-in debug-hub tabs, registered through the exact
    -- same Waila.registerDebugTab API any other mod would use -- see
    -- WailaDebugHubDialog.lua for the tab contract and Waila.lua for
    -- registerDebugTab itself. Split along WAILA's own existing module
    -- boundaries (WailaTerrainInspector, WailaFoliageInspector, the
    -- field-scanning stack, declared areas) rather than one flat action
    -- list -- fits the 5 fixed tab slots exactly. "mod" captured so the
    -- run() closures below close over this loadMap() instance, not
    -- whatever "self" happens to be wherever they're later called from.
    local mod = self

    -- Shared by every action-style tab below (General/Terrain/Foliage/
    -- Field) -- only Declared Areas needs a different describeItem/
    -- buttons shape (it lists real WailaDeclaredArea objects, not
    -- {label, run} entries), so that one is registered separately.
    -- icon resolved via Utils.getFilename (confirmed real, standard
    -- mod-relative-path convention) against gui/icons/<id>.dds, the
    -- topic icons converted from assets/menu-icons/*.svg.
    local function registerActionTab(id, label, entries)
        Waila.registerDebugTab({
            id = id,
            label = label,
            icon = Utils.getFilename("gui/icons/" .. id .. ".dds", FS25WhatAmILookingAt.MOD_DIRECTORY),
            getItems = function() return entries end,
            describeItem = function(item) return item.label, nil end,
            buttons = { { label = "Run", callback = function(item) item.run() end } },
        })
    end

    registerActionTab("general", "General", {
        { label = "Dump inspected target", run = function() mod:onDumpTarget() end },
        { label = "Dump environment/weather state", run = function() mod:onDumpEnvironment() end },
        { label = "Dump player + held hand tool position", run = function() mod:onDumpPlayerAndHandTool() end },
        { label = "Dump held hand tool's live scene-graph tree", run = function() mod:onDumpHandToolNodeTree() end },
        -- Best-effort script reload, not a real map/savegame reload --
        -- see Waila.reloadAll/Waila.registerReloadable. Same console
        -- command also works from outside the HUD: wailaReload.
        { label = "Reload registered mod scripts (best-effort)", run = function() mod:onReloadScripts() end },
    })

    registerActionTab("terrain", "Terrain", {
        { label = "Dump terrain layers", run = function() mod:onDumpTerrainLayers() end },
        { label = "Paint layer test row", run = function() mod:onPlaceTerrainLayerTestRow() end },
        { label = "Dump density probe", run = function() mod:onDumpDensityProbe() end },
        { label = "Dump ground layer dataPlane probe", run = function() mod:onDumpGroundDensityProbe() end },
        { label = "Dump road nodes", run = function() mod:onDumpRoadNodes() end },
        { label = "Build road overlay (from real splines)", run = function() mod:onBuildRoadOverlay() end },
        { label = "Build tree/water overlay near player", run = function() mod:onBuildFeatureOverlay() end },
        { label = "Build diagonal test overlay (simplest possible)", run = function() mod:onBuildDiagonalTestOverlay() end },
        { label = "Build forest overlay near player (diversity classifier)", run = function() mod:onBuildForestOverlay() end },
    })

    registerActionTab("foliage", "Foliage", {
        { label = "Dump foliage catalog for this map", run = function() mod:onDumpFoliageCatalog() end },
        { label = "Place foliage test rig", run = function() mod:onPlaceFoliageTestRig() end },
    })

    registerActionTab("field", "Field", {
        { label = "Write WAILA state to waila.xml", run = function() mod:onDumpFieldIndex() end },
        { label = "Toggle field-tracing debug view", run = function() mod:onToggleFieldTracingDebug() end },
    })

    -- box only ever stores {minX, maxX, minZ, maxZ} (see
    -- WailaDeclaredArea.lua) -- no Y at all, so there's nothing to read
    -- back, only terrain height to sample. Same trick already used
    -- elsewhere in this file for field label rendering and
    -- WailaDeclaredArea:drawDebug's own corner lines -- not the area's
    -- true object-space Y (which could differ, e.g. a placeable root
    -- repositioned above/below its own footprint), just a reasonable
    -- stand-in so a list of areas isn't guessing whether one is buried.
    local function describeAreaPosition(area)
        if area.box ~= nil then
            local centerX = (area.box.minX + area.box.maxX) / 2
            local centerZ = (area.box.minZ + area.box.maxZ) / 2
            local centerY = getTerrainHeightAtWorldPos(g_terrainNode, centerX, 0, centerZ)
            return string.format("%.0f, %.0f, %.0f", centerX, centerY, centerZ)
        end
        return "-"
    end

    Waila.registerDebugTab({
        id = "areas",
        label = "Declared Areas",
        icon = Utils.getFilename("gui/icons/declared-areas.dds", FS25WhatAmILookingAt.MOD_DIRECTORY),
        getItems = Waila.getAllAreas,
        describeItem = function(area) return area.type, describeAreaPosition(area) end,
        -- Runs the area's own cleanup (if it or its type registered one,
        -- e.g. the foliage test rig clearing what it placed) before
        -- unregistering it -- Delete used to only remove WAILA's own
        -- tracking, leaving whatever the area actually placed in the
        -- world behind. Waila.resolveAreaField, not a bare area.
        -- deleteCallback read -- an area restored from waila.xml never
        -- carries its own function fields, only a type-level
        -- registration (Waila.registerAreaType) survives that.
        buttons = { { label = "Delete", callback = function(area)
            -- Real lifesign, not a temp diagnostic -- confirms which
            -- function actually ran, independent of what the hub's UI
            -- displayed.
            log("[DeclaredArea] Delete callback running for type='%s' wailaID=%s", tostring(area.type), tostring(area.wailaID))
            local deleteCallback = Waila.resolveAreaField(area, "deleteCallback")
            if deleteCallback ~= nil then
                deleteCallback(area)
            end
            Waila.unregisterArea(area)
        end } },
    })

    -- Published via g_currentMission, not the bare Waila global -- a
    -- mod's own declared globals aren't actually visible to OTHER mods'
    -- scripts (confirmed live, see Waila.lua's header for the full
    -- story) -- g_currentMission is the one thing that genuinely is
    -- shared. This is the real integration point for SmartMinimapAuto
    -- (or anything else) to read.
    g_currentMission.waila = Waila

    -- Same reasoning as g_currentMission.waila just above: even though
    -- the new wailaFoliageTestRig placeable lives in this same mod,
    -- plain Lua globals/instance fields still aren't reachable from a
    -- specialization file without some shared handle -- this is that
    -- handle, one instance, matching what the debug hub button already
    -- calls through self.debugTools.
    g_currentMission.wailaDebugTools = self.debugTools

    -- Same rule, same reason -- real bug found live: TaskMap's own
    -- rebuildTrailHotspots checks the bare WailaTrailTracer global and
    -- logged "nil (WAILA not loaded/too early?)" on an endless repeating
    -- timer, never once resolving no matter how long the session ran.
    -- Not a timing issue at all -- WailaTrailTracer.lua declares itself
    -- as a bare top-level global (WailaTrailTracer = {}), which only
    -- ever exists inside THIS mod's own sandbox. Every other cross-mod
    -- API here already goes through g_currentMission for exactly this
    -- reason (see Waila.lua's own header comment); this one simply never
    -- got the same treatment when it was built.
    g_currentMission.wailaTrailTracer = WailaTrailTracer

    -- Restores the trail overlay from <savegame>/wailaTrail.xml (if one
    -- exists) -- same spot fieldIndex:start() calls its own loadFromXML
    -- from, just above. Only queues the work here; startLoadFromXML's own
    -- header explains why the actual restore is tick-budgeted (see
    -- update() below) rather than done synchronously in one call.
    WailaTrailTracer.startLoadFromXML()

    -- Self-test: WAILA subscribing to its own event, just to confirm the
    -- whole pipeline (scan -> registry -> vehicle-leave detection -> fire)
    -- actually works end to end before any other mod depends on it.
    g_messageCenter:subscribe(WailaFieldIndex.VEHICLE_LEFT_FIELD, self.onVehicleLeftField, self)
    g_messageCenter:subscribe(WailaAreaTracker.AREA_ENTERED, self.onAreaEntered, self)
    g_messageCenter:subscribe(WailaAreaTracker.AREA_LEFT, self.onAreaLeft, self)

    self.areaSize = 5
    self.areaStep = 0.5
    self.pointIntervalMs = 100
    self.areaIntervalMs = 400
    self.pointTimer = 0
    self.areaTimer = 0
    self.lastAreaX = nil
    self.lastAreaZ = nil
    self.current = nil
end

-- Undoes everything setupComponents() sets up -- shared by the real
-- deleteMap() (real map unload, nothing to reuse afterward) and
-- Waila.reloadAll() (needs a clean slate before setupComponents() runs
-- again). Debug tabs are unregistered by id, not a wholesale
-- Waila.debugTabs wipe -- that list can hold other mods' tabs too.
--
-- Real bug found live (2026-08-30): Waila.indices (see Waila.lua) is a
-- plain mod-declared global table, created once at Lua load time for
-- the whole game process, NOT per-mission - g_currentMission.waila is
-- just a reference to this SAME table republished each load, never a
-- fresh one. Nothing here ever cleared it, so every area a third-party
-- mod registered (confirmed live: FS25_Daisychain's
-- PlaceableFlowerPolygonArea, one per placed flower patch) stayed
-- registered past its own placeable's deletion, across the entire
-- mission teardown. On exit, every one of those placeables' onDelete()
-- fires and calls back into Waila.unregisterArea, mutating this same
-- never-reset shared table while the rest of the world is also tearing
-- down - a real, confirmed crash-on-exit contributor (reproduced live:
-- disabling Daisychain, or manually clearing all WAILA areas before
-- exiting, both independently "fixed" it - consistent with this being
-- the actual shared cause, not two unrelated fixes). Same missing-
-- cleanup shape self.fieldIndex:stop() already handles for the field
-- index, just never extended to the generic area-index system.
-- WailaAreaIndex:clear() already existed for exactly this - reused, not
-- reinvented.
function FS25WhatAmILookingAt:teardownComponents()
    g_inputBinding:removeActionEventsByTarget(self)
    g_messageCenter:unsubscribeAll(self)
    if self.fieldIndex ~= nil then
        self.fieldIndex:stop()
    end
    -- Real bug found live in THIS fix, the same night it was added:
    -- Waila.indices doesn't exclusively hold WailaAreaIndex instances -
    -- Waila.indices.field is a WailaFieldIndex (see this file's own
    -- Waila.indices.field = self.fieldIndex, in setupComponents), which
    -- has no :clear() method at all (it's already handled two lines up,
    -- via self.fieldIndex:stop()). The blind pairs() loop crashed on it
    -- every time - "attempt to call missing method 'clear' of table",
    -- confirmed live via a real log.txt trace on exit. Same
    -- className == WailaAreaIndex.MARKER guard Waila.registerArea
    -- itself already uses to tell the two apart - reused, not
    -- reinvented, same as :clear() itself was meant to be.
    for _, index in pairs(Waila.indices) do
        if index.className == WailaAreaIndex.MARKER then
            index:clear()
        end
    end
    for _, id in ipairs({ "general", "terrain", "foliage", "field", "areas" }) do
        Waila.unregisterDebugTab(id)
    end
    if self.debugHubGui ~= nil then
        g_gui:closeDialogByName(WailaDebugHubDialog.GUI_NAME)
    end
end

function FS25WhatAmILookingAt:loadMap()
    self:setupComponents()

    -- One-time (NOT part of setupComponents -- must not double-register
    -- on every reload): register WAILA itself with the shared
    -- cross-mod reload registry through the exact same public API any
    -- other of ubuntu811's own mods would use. See Waila.
    -- registerReloadable in Waila.lua for the full contract/rationale.
    Waila.registerReloadable({
        id = "waila",
        modDirectory = FS25WhatAmILookingAt.MOD_DIRECTORY,
        sourceFiles = FS25WhatAmILookingAt.readOwnSourceFiles(),
        teardown = function() self:teardownComponents() end,
        setup = function() self:setupComponents() end,
    })

    addConsoleCommand(
        "wailaReload",
        "Best-effort reload of every module registered via Waila.registerReloadable (WAILA + anything else), without a full savegame reload",
        "onReloadScripts",
        self
    )

    log("loaded; Shift+M toggles the inspector HUD")
end

function FS25WhatAmILookingAt:deleteMap()
    self:teardownComponents()
end

function FS25WhatAmILookingAt:onReloadScripts()
    Waila.reloadAll()
end

-- Self-test handler for WailaFieldIndex.VEHICLE_LEFT_FIELD -- see the
-- subscription in loadMap(). entry is nil if the vehicle left ground that
-- isn't field anymore (rare - meadow conversion, tillage removed, ...).
function FS25WhatAmILookingAt:onVehicleLeftField(vehicleOrPlayer, entry)
    local entityName = "player"
    if vehicleOrPlayer ~= g_localPlayer then
        entityName = WailaUtil.getObjectName(vehicleOrPlayer) or "vehicle"
    end

    if entry == nil then
        log("[FieldIndex self-test] %s left field ground (no longer field)", entityName)
    else
        log("[FieldIndex self-test] %s left field #%d", entityName, entry.wailaFieldId)
    end
end

-- Self-test handlers for WailaAreaTracker.AREA_ENTERED/AREA_LEFT -- see
-- the subscriptions in loadMap(). Player-only right now (see
-- WailaAreaTracker.lua), so no entity-name branching needed here unlike
-- onVehicleLeftField above. Used to also drive a dedicated
-- WAILA_AREA_ACTION keybind's text/active state; that bind was removed
-- as a pure duplicate of the Declared Areas hub tab's own per-item
-- action button (Waila.resolveAreaField(area, "actionCallback"), same
-- resolution, reachable there without needing to stand in the area).
function FS25WhatAmILookingAt:onAreaEntered(typeName, area)
    log("[AreaTracker self-test] player entered area '%s'", typeName)
end

function FS25WhatAmILookingAt:onAreaLeft(typeName, area)
    log("[AreaTracker self-test] player left area '%s'", typeName)
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

    local _, debugHubId = g_inputBinding:registerActionEvent(
        InputAction.WAILA_DEBUG_HUB,
        self,
        self.onOpenDebugHub,
        false, true, false, true, nil, true
    )
    if debugHubId ~= nil then
        g_inputBinding:setActionEventTextPriority(debugHubId, GS_PRIO_LOW)
        g_inputBinding:setActionEventTextVisibility(debugHubId, false)
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

function FS25WhatAmILookingAt:onOpenDebugHub()
    g_gui:showDialog(WailaDebugHubDialog.GUI_NAME)
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

function FS25WhatAmILookingAt:onDumpRoadNodes()
    self.debugTools:dumpRoadNodes()
end

function FS25WhatAmILookingAt:onBuildRoadOverlay()
    local success, splineCountOrReason, polygonCount = WailaTrailTracer.buildRoadSplineOverlay()
    if success then
        log("[RoadOverlay] built from %d spline(s), %d ribbon polygon(s)", splineCountOrReason, polygonCount)
    else
        log("[RoadOverlay] failed: %s", tostring(splineCountOrReason))
    end
end

function FS25WhatAmILookingAt:onBuildDiagonalTestOverlay()
    WailaTrailTracer.buildDiagonalTestOverlay()
end

function FS25WhatAmILookingAt:onBuildForestOverlay()
    if self.current == nil or self.current.hit == nil then
        log("[ForestOverlay] No current terrain target")
        return
    end

    local success, cellCount, polygonCount, elapsedMs = WailaTrailTracer.buildForestOverlay(self.current.hit.x, self.current.hit.z)
    if success then
        log("[ForestOverlay] %d cell(s), %d polygon(s), %.0fms", cellCount, polygonCount, elapsedMs)
    end
end

function FS25WhatAmILookingAt:onBuildFeatureOverlay()
    if self.current == nil or self.current.hit == nil then
        log("[FeatureOverlay] No current terrain target")
        return
    end

    local success, cellCount, treeCount, waterCount, elapsedMs = WailaTrailTracer.buildFeatureOverlay(self.current.hit.x, self.current.hit.z)
    if success then
        log("[FeatureOverlay] %d cell(s), %d tree polygon(s), %d water polygon(s), %.0fms", cellCount, treeCount, waterCount, elapsedMs)
    end
end

-- Writes waila.xml on demand (not waiting for a real savegame save) --
-- readable field data (crop/growth/weed/spray/lime) per known field,
-- an alternative to reading the same information back out of a log dump.
function FS25WhatAmILookingAt:onDumpFieldIndex()
    if self.fieldIndex == nil then
        log("[FieldIndex] Not initialized")
        return
    end

    local success, pathOrReason, count = self.fieldIndex:saveToXML()
    if success then
        log("[FieldIndex] Wrote %d field(s) to %s", count, pathOrReason)
    else
        log("[FieldIndex] Could not write waila.xml: %s", pathOrReason)
    end
end

function FS25WhatAmILookingAt:onDumpEnvironment()
    self.debugTools:dumpEnvironment()
end

function FS25WhatAmILookingAt:onDumpPlayerAndHandTool()
    self.debugTools:dumpPlayerAndHandTool()
end

function FS25WhatAmILookingAt:onDumpHandToolNodeTree()
    self.debugTools:dumpHandToolNodeTree()
end

function FS25WhatAmILookingAt:onToggleFieldTracingDebug()
    Waila.debugFieldTracing = not Waila.debugFieldTracing
    log("[DebugMenu] field-tracing debug view: %s", Waila.debugFieldTracing and "ON" or "OFF")
end

function FS25WhatAmILookingAt:update(dt)
    if g_currentMission == nil then
        return
    end

    -- Background scanning/vehicle-tracking, independent of the HUD/menu
    -- state below -- shouldn't pause just because a menu is open.
    if self.fieldIndex ~= nil then
        self.fieldIndex:update(dt)
    end

    if self.areaTracker ~= nil then
        self.areaTracker:update(dt)
    end

    -- Trail overlay save/load, tick-budgeted -- both are safe to call
    -- unconditionally every frame (no-op when nothing is running), same
    -- contract as WailaTrailTracer.tickWholeMapScan. See
    -- startSaveToXML/startLoadFromXML's own headers for why this can't
    -- just be one synchronous call.
    WailaTrailTracer.tickSaveToXML()
    WailaTrailTracer.tickLoadFromXML()

    -- Same toggle as the field-boundary overlay below -- one switch for
    -- "show me WAILA's world-scanning debug view", not two separate ones.
    if Waila.debugFieldTracing then
        Waila.drawDebugAreas()
    end

    -- Draws only the ONE field boundary the player is currently in/near
    -- (via WailaFieldIndex:getEntry, the same lookup the HUD's own
    -- "WAILA field id" line uses) -- not every field on the map every
    -- frame, unlike declared areas there could realistically be hundreds
    -- of these across a real map. Polygon2D:renderEdges is the base
    -- game's own method (confirmed via decompile, PlaceableRiceField-
    -- adjacent code doesn't need this but Polygon2D itself already has
    -- it) -- reused directly rather than hand-rolling another debug-line
    -- loop.
    if Waila.debugFieldTracing and self.fieldIndex ~= nil and g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil then
        local px, _, pz = getWorldTranslation(g_localPlayer.rootNode)
        local entry = self.fieldIndex:getEntry(px, pz)
        if entry ~= nil and entry.boundary ~= nil then
            entry.boundary:renderEdges(nil, nil, true, false, false)

            -- Utils.renderTextAtWorldPosition is the base game's own
            -- screen-projected world text (confirmed via decompile,
            -- Utils.lua -- same function Polygon2D:renderEdges itself
            -- calls for edge-length labels), reused directly rather than
            -- building a separate text-rendering path.
            local labelY = getTerrainHeightAtWorldPos(g_terrainNode, entry.labelX, 0, entry.labelZ) + 1
            Utils.renderTextAtWorldPosition(entry.labelX, labelY, entry.labelZ, "WAILA #" .. entry.wailaFieldId, 0.02, nil, 1, 1, 0.3, 1)
        end
    end

    if g_gui:getIsGuiVisible() then
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
        self.current.field = self.fieldInspector:inspectPoint(hit.x, hit.y, hit.z)

        -- Real request: "can I have multiple collisions, so I get a
        -- 'standing on a road with gravel underneath' answer" -- a real
        -- raycastAll stack of every hit along the ray, not just the
        -- single closest one. Gated behind self.enabled, unlike
        -- terrain/foliagePoint/field above -- this is a heavier probe (up
        -- to COLLISION_STACK_MAX_HITS raycast hits, each resolving a name
        -- + collision group), the same "only pay for it when the full
        -- detailed view actually needs it" reasoning already gating the
        -- area/foliage scans below self.enabled's own check.
        if self.enabled then
            self.current.collisionStack = self.terrainInspector:inspectCollisionStack(hit.x, hit.y, hit.z)
        else
            self.current.collisionStack = nil
        end
    else
        self.current.terrain = nil
        self.current.foliagePoint = nil
        self.current.terrainArea = nil
        self.current.foliageArea = nil
        self.current.field = nil
        self.current.collisionStack = nil
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

-- SavegameController.onSaveComplete (real base-game class, confirmed via
-- FS25_0_TerraFarm's own SavegameControllerExtension.lua doing exactly
-- this for its own persistence, and already used the same way in
-- SmartMinimapAuto) fires once the game's own savegame write finishes
-- successfully -- the right moment to also write the field index cache.
local function onSavegameControllerSaveComplete(self, errorCode)
    if errorCode == Savegame.ERROR_OK and FS25WhatAmILookingAt.fieldIndex ~= nil then
        FS25WhatAmILookingAt.fieldIndex:saveToXML()
    end
    if errorCode == Savegame.ERROR_OK then
        WailaTrailTracer.startSaveToXML()
    end
end
SavegameController.onSaveComplete = Utils.appendedFunction(SavegameController.onSaveComplete, onSavegameControllerSaveComplete)
