--[[
    Waila.lua

    Public query facade other mods call into -- Waila.get(type, x, z) /
    Waila.getAll(type). Deliberately thin: just dispatches by type name to
    whichever index registered itself (Waila.indices[type] = ...).

    IMPORTANT: this table (Waila = {}, a mod-declared global) is NOT
    actually visible to other mods' scripts, despite looking like a plain
    shared global. Confirmed live, twice now, the hard way: WailaHud's
    docking coordinates hit this earlier this session (a bare WailaHud
    global read as nil from ImmersiveWeathering's side), and this file
    hit it again when SmartMinimapAuto tried to read a bare `Waila`
    global directly and got nil despite WAILA having already finished
    loading. Each mod gets its own script environment for mod-DECLARED
    globals -- only pre-existing engine objects (g_currentMission and
    whatever's already hanging off it, base-game classes like
    SavegameController/BaseMission that mods patch via Utils.
    appendedFunction, ...) are actually shared across mods. The fix both
    times: publish through g_currentMission (see
    FS25WhatAmILookingAt:loadMap(), g_currentMission.waila = Waila) --
    other mods read g_currentMission.waila, never this bare global
    directly. events.vehicleLeftField exists for the exact same reason --
    WailaFieldIndex.VEHICLE_LEFT_FIELD (a plain number from
    nextMessageTypeId()) is just as invisible cross-mod as the table
    itself would be, so it's re-exposed here too.

    "field" is WAILA's own purpose-built index (see WailaFieldIndex.lua).
    Any other type name is available for any mod to declare freely via
    Waila.registerArea below -- WailaAreaIndex.new(type) gets created on
    demand the first time that type name is registered, no core change
    needed per new type. getTypes(x, z) is the reverse lookup: given a
    position, which registered type names (WAILA's own or third-party)
    cover it -- a list, not a single value, since e.g. a flower patch can
    sit inside a field and both are simultaneously true.
]]

Waila = {}
Waila.indices = {}
Waila.events = {
    vehicleLeftField = WailaFieldIndex.VEHICLE_LEFT_FIELD,
    areaEntered = WailaAreaTracker.AREA_ENTERED,
    areaLeft = WailaAreaTracker.AREA_LEFT,
}

-- Gates both the in-world field-boundary/label debug overlay
-- (FS25WhatAmILookingAt:update()) and WailaFieldGridScanner's verbose
-- per-seed/per-trace logging -- default off, toggled via the debug menu
-- ("Toggle field-tracing debug view"). Was unconditional while chasing a
-- real live bug in the boundary tracer; now that it's fixed, both are
-- occasional-use diagnostics, not something that should run by default.
Waila.debugFieldTracing = false

-- Monotonic within this process, combined with getTimeSec() (real,
-- already used elsewhere in this codebase, e.g. FS25WhatAmILookingAt's
-- own scan timing) so ids stay unique even across separate game
-- sessions/savegames reusing the same counter start -- doesn't need to
-- be a true UUID, just never collide with anything already sitting in
-- waila.xml or created earlier this session.
Waila.nextAreaId = 0

function Waila.generateAreaId(typeName)
    Waila.nextAreaId = Waila.nextAreaId + 1
    return string.format("%s_%d_%d", tostring(typeName), math.floor(getTimeSec() * 1000), Waila.nextAreaId)
end

-- Takes a plain { type, polygon/box, metadata, wailaID } data table --
-- same shape WailaDeclaredArea.new expects -- builds the real instance,
-- and registers it under Waila.indices[area.type], creating that type's
-- WailaAreaIndex the first time it's seen. Refuses (logs, does not
-- crash) if that type name is already owned by a non-declared-area
-- index (WAILA's own "field", or another mod's custom index class) --
-- registerArea is only for the plain-declared-area path, not a generic
-- way to inject into someone else's purpose-built index.
--
-- wailaID is optional -- a fresh one is generated if not supplied (the
-- normal case: a mod placing a brand-new area). Restoring an area from
-- waila.xml passes the id IT was originally saved with (see
-- WailaFieldIndex:loadFromXML), so re-restoring the same persisted area
-- twice (e.g. two Waila.reloadAll() cycles re-running loadFromXML) lands
-- on the SAME id both times -- WailaAreaIndex:add then upserts instead
-- of appending a duplicate.
function Waila.registerArea(data)
    local index = Waila.indices[data.type]
    if index == nil then
        index = WailaAreaIndex.new(data.type)
        Waila.indices[data.type] = index
    elseif index.className ~= WailaAreaIndex.MARKER then
        Logging.warning("[WhatAmILookingAt] Waila.registerArea: type '%s' is already owned by a different index, refusing to register", tostring(data.type))
        return nil
    end
    data.wailaID = data.wailaID or Waila.generateAreaId(data.type)
    local area = WailaDeclaredArea.new(data)
    index:add(area)
    return area
end

function Waila.unregisterArea(area)
    local index = Waila.indices[area.type]
    if index ~= nil and index.className == WailaAreaIndex.MARKER then
        index:remove(area)
    end
end

-- Public: unregisters every declared area (any type, WAILA's own "field"
-- excluded -- that's not a declared area and isn't something a debug
-- action should be able to delete) covering (x, z). Returns a list of the
-- type names actually removed, empty if none matched. The only way to get
-- rid of a stale declared area otherwise was hand-editing waila.xml (a
-- deleted area just won't be there next time saveToXML runs, since that
-- always writes a fresh snapshot of whatever's currently registered) --
-- this is the in-game equivalent, not tied to any one mod's area type.
function Waila.deleteAreasAt(x, z)
    local removedTypes = {}
    for typeName, index in pairs(Waila.indices) do
        if index.className == WailaAreaIndex.MARKER then
            local area = index:get(x, z)
            if area ~= nil then
                index:remove(area)
                table.insert(removedTypes, typeName)
            end
        end
    end
    return removedTypes
end

-- Every registered type name whose index reports something at (x, z) --
-- loops all of Waila.indices, not just declared areas, so WAILA's own
-- "field" falls out of the same loop for free. Point-query cost only
-- (HUD display, "what's here"), never called from a sweep/scan -- see
-- WailaDeclaredArea.lua for why declared areas don't participate in
-- blob-merging the way rice-field polygons do.
-- Every currently-registered declared area across all types, flattened --
-- shared by drawDebugAreas below and WailaDebugHubDialog's "Declared
-- Areas" tab, so this loop only lives in one place (used to be
-- duplicated in both plus the old WailaAreaListDialog).
function Waila.getAllAreas()
    local areas = {}
    for _, index in pairs(Waila.indices) do
        if index.className == WailaAreaIndex.MARKER then
            for _, area in ipairs(index:getAll()) do
                table.insert(areas, area)
            end
        end
    end
    return areas
end

function Waila.getTypes(x, z)
    local types = {}
    for typeName, index in pairs(Waila.indices) do
        if index:get(x, z) ~= nil then
            table.insert(types, typeName)
        end
    end
    return types
end

-- Debug-only: draws every registered declared area's boundary (blue by
-- default) -- call every frame from update(), same immediate-mode
-- constraint as WailaDeclaredArea:drawDebug itself. Only visits
-- WailaAreaIndex-backed types, not WAILA's own "field" -- that already has
-- its own (much heavier, flood-fill-derived) visualization story if one
-- ever gets built, not this one.
function Waila.drawDebugAreas(r, g, b)
    r = r or 0.2
    g = g or 0.4
    b = b or 1

    for _, area in ipairs(Waila.getAllAreas()) do
        area:drawDebug(r, g, b)
    end
end

-- Shared debug/tools hub -- WailaDebugHubDialog.lua reads this list to
-- build its tab strip. Any mod (WAILA itself included -- see
-- FS25WhatAmILookingAt:loadMap, it registers its own tabs through this
-- exact same call, no special-casing for being the "owner") can add one.
-- Deliberately unopinionated about what's INSIDE getItems()'s results --
-- WailaDebugHubDialog only ever hands an item back through this same
-- descriptor's own describeItem/buttons callbacks, never inspects an
-- item's fields itself.
--
-- descriptor = {
--   id = "unique-string",
--   label = "Shown in the topic list",
--   icon = "optional, absolute path to a .dds (see Utils.getFilename)",
--   getItems = function() return {...} end,        -- called fresh every open/refresh
--   describeItem = function(item) return primaryText, secondaryText end,
--   buttons = { { label = "...", callback = function(item) ... end }, ... },
-- }
Waila.debugTabs = {}

function Waila.registerDebugTab(descriptor)
    table.insert(Waila.debugTabs, descriptor)
end

-- Removes every tab matching id -- used by a module's own reload
-- teardown (see Waila.registerReloadable below) so it can re-register
-- its OWN tabs cleanly without wiping the shared list (which may hold
-- other mods' tabs too).
function Waila.unregisterDebugTab(id)
    for i = #Waila.debugTabs, 1, -1 do
        if Waila.debugTabs[i].id == id then
            table.remove(Waila.debugTabs, i)
        end
    end
end

-- Shared "reload my scripts" registry -- see the wailaReload console
-- command / General debug tab (FS25WhatAmILookingAt.lua). Any mod can
-- register its own source files here to be re-source()'d together with
-- WAILA's, through the exact same one command -- the whole point being
-- not paying for a full savegame reload just to pick up a small script
-- fix. WAILA registers itself through this same public API.
--
-- descriptor = {
--   id = "unique-string",
--   modDirectory = ".../ModFolder/",         -- this mod's own g_currentModDirectory
--   sourceFiles = { "scripts/Foo.lua", ... }, -- relative to modDirectory
--   teardown = function() ... end,  -- unregister everything this module owns
--   setup = function() ... end,     -- recreate everything this module owns
-- }
--
-- Deliberately best-effort, not a guaranteed-safe live reload: source()
-- re-runs a file's top-level code, which for a class file means a FRESH
-- metatable (via Class(...)) -- any already-created instance keeps
-- pointing at the OLD one unless teardown/setup actually destroy and
-- recreate it. Fine for typical logic/typo fixes in files whose objects
-- get properly recreated; a structural change (new fields, a changed
-- class hierarchy, ...) may still need a real reload. Not every case
-- has to work for this to be worth having.
Waila.reloadables = {}

function Waila.registerReloadable(descriptor)
    table.insert(Waila.reloadables, descriptor)
end

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] " .. formatString, ...)
end

-- Runs teardown for every registrant (reverse registration order, so a
-- later/more-dependent module tears down before whatever it depends on),
-- then re-source()'s every registrant's files (registration order), then
-- runs setup for every registrant (registration order). Each step is
-- individually pcall'd -- one module's teardown/source/setup failing
-- doesn't stop the others from still getting reloaded.
function Waila.reloadAll()
    log("[Reload] Starting (%d registered module(s))...", #Waila.reloadables)

    for i = #Waila.reloadables, 1, -1 do
        local reloadable = Waila.reloadables[i]
        if reloadable.teardown ~= nil then
            local ok, err = pcall(reloadable.teardown)
            if not ok then
                log("[Reload] '%s' teardown failed: %s", tostring(reloadable.id), tostring(err))
            end
        end
    end

    for _, reloadable in ipairs(Waila.reloadables) do
        for _, relativePath in ipairs(reloadable.sourceFiles or {}) do
            local path = Utils.getFilename(relativePath, reloadable.modDirectory)
            local ok, err = pcall(source, path)
            if not ok then
                log("[Reload] '%s': failed sourcing %s: %s", tostring(reloadable.id), relativePath, tostring(err))
            end
        end
    end

    for _, reloadable in ipairs(Waila.reloadables) do
        if reloadable.setup ~= nil then
            local ok, err = pcall(reloadable.setup)
            if not ok then
                log("[Reload] '%s' setup failed: %s", tostring(reloadable.id), tostring(err))
            end
        end
    end

    log("[Reload] Done.")
end

function Waila.get(type, x, z)
    local index = Waila.indices[type]
    if index == nil then
        return nil
    end
    return index:get(x, z)
end

function Waila.getAll(type)
    local index = Waila.indices[type]
    if index == nil then
        return nil
    end
    return index:getAll()
end

-- Optional default presentation for a WailaField job type -- see
-- WailaJobDefinitions.lua for why this is offered rather than required.
function Waila.getJobLetter(jobType)
    return WailaJobDefinitions.getLetter(jobType)
end
