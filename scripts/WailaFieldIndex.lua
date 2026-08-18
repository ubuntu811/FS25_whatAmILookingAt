--[[
    WailaFieldIndex.lua

    First concrete piece of the "waila.get(type, coords)" world-state
    index -- see the waila-field-index-migration memory. Ports
    SmartMinimapAuto's proven scanner/registry/vehicle-tracking/
    persistence design (see WailaFieldGridScanner.lua for why that's a
    separate class, not a shared file), but stores actual WailaField
    instances instead of raw position tuples, and fires a g_messageCenter
    event other mods can subscribe to instead of drawing anything itself
    -- this class has no rendering opinion at all, unlike SmartMinimapAuto.

    self.entries[i] = { wailaFieldId, labelX, labelZ, sampleX, sampleZ,
    field, riceField, boundary, boundaryPositions } -- field is a
    WailaField instance (see WailaField.lua), built via WailaFieldInspector
    (reused, not reimplemented) so this and the live point-inspection HUD
    path share the exact same "how do I read a field at a position" logic.
    wailaFieldId is a per-session counter (1, 2, 3, ...), but IS stable
    across sweeps now: findMatchingPreviousId reuses a field's existing id
    if the new sweep's sample point still falls inside that field's
    previous boundary, only minting a fresh id for a genuinely new/changed
    field. NOT persisted to waila.xml though -- reassigned fresh on load
    (loadFromXML), since there's no previous-sweep boundary to match
    against yet at that point. boundary is a real Polygon2D from WailaFieldGridScanner's
    boundary tracing (see there and WailaFieldBoundaryTracer.lua) -- the
    scanner now traces this as PART of discovery, not as a separate
    refinement step bolted on afterward (an earlier version of this file
    did exactly that, and it didn't fix the actual bug: farmland-ID-based
    blob splitting. See WailaFieldGridScanner.lua's header for the full
    story).

    get()/getAll() read from this registry only -- fast, may lag one sweep
    or rescan behind reality. WailaFieldInspector:inspectPoint() (used
    internally here too) stays the separate, always-live path for
    "what's literally under the crosshair right now" -- these are not
    meant to be merged, see the migration memory for why.
]]

WailaFieldIndex = {}
local WailaFieldIndex_mt = Class(WailaFieldIndex)

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] " .. formatString, ...)
end

-- Real MessageCenter mechanism, not a custom event system -- confirmed
-- generic (MessageCenter:subscribe just does self.subscribers[messageType]
-- = ..., zero validation against the MessageType enum) via decompiled
-- dataS.gar/scripts/MessageCenter.lua. Payload: (vehicleOrPlayer, entry)
-- where entry is this index's own registry entry table.
WailaFieldIndex.VEHICLE_LEFT_FIELD = nextMessageTypeId()

-- Time-budgeted now, not cell-count-budgeted -- WailaFieldGridScanner's
-- own update(timeBudgetSec) advances either the row-major seed scan or an
-- in-progress boundary trace, neither of which has a natural "cell" unit
-- anymore the way pure grid flood-fill did.
WailaFieldIndex.SCAN_BUDGET_SEC = 0.003
WailaFieldIndex.RESWEEP_FALLBACK_INTERVAL = 180000
WailaFieldIndex.VEHICLE_CHECK_INTERVAL = 500
WailaFieldIndex.BLOB_MATCH_RADIUS = 150
WailaFieldIndex.SAVEGAME_FILENAME = "waila.xml"

function WailaFieldIndex.new()
    local self = setmetatable({}, WailaFieldIndex_mt)

    self.scanner = nil -- created in start(), needs a real terrainSize
    self.fieldInspector = WailaFieldInspector.new()

    self.entries = nil
    self.pendingEntries = nil
    self.isSweeping = false
    self.nextWailaFieldId = 1
    -- True once a full sweep has actually finished THIS session -- a
    -- cache loaded from waila.xml (possibly empty, e.g. the very first
    -- session ever) sets self.entries to a non-nil table immediately on
    -- load, before any fresh sweep has run. Without this flag,
    -- saveToXML() couldn't tell "confirmed zero fields" apart from
    -- "haven't actually checked yet" and could write back a misleadingly
    -- empty file. See saveToXML().
    self.hasCompletedSweep = false
    self.sweepStartTime = nil
    self.lastSweepDurationSec = nil

    self.resweepFallbackTimer = 0
    self.vehicleCheckTimer = 0
    self.vehicleFieldState = {}

    -- Set by loadFromXML() when a cache existed -- true means "populate
    -- self.entries[*].field on the next safe update() tick, then stop".
    -- Not done directly in loadFromXML()/start() because reading a
    -- WailaField means density-map reads, which aren't bound that early
    -- (same load-order lesson SmartMinimapAuto already learned once).
    self.needsInitialRefresh = false

    return self
end

-- Call from loadMap() -- only restores the cache, does not create the
-- scanner or scan anything yet. WailaFieldGridScanner.new() reads
-- g_currentMission.terrainSize at creation time to size/place its grid --
-- confirmed live (a real sweep finishing suspiciously fast with zero
-- results) that terrainSize isn't reliably populated this early for every
-- mod. Deferred to the first update() tick instead, see there.
function WailaFieldIndex:start()
    self:loadFromXML()
    g_messageCenter:subscribe(MessageType.FINISHED_GROWTH_PERIOD, self.onFinishedGrowthPeriod, self)
end

-- Call from deleteMap().
function WailaFieldIndex:stop()
    g_messageCenter:unsubscribeAll(self)
end

function WailaFieldIndex:startFullSweep()
    self.scanner:reset()
    self.pendingEntries = {}
    self.isSweeping = true
    self.sweepStartTime = getTimeSec()
    log("[WailaFieldIndex] Field sweep started")
end

function WailaFieldIndex:onFinishedGrowthPeriod()
    self:startFullSweep()
end

-- Now that real polygon boundaries exist, id stability across sweeps is
-- just an exact containment test, not a heuristic -- checks whether
-- (sampleX, sampleZ) falls inside any PREVIOUS-sweep entry's boundary
-- (self.entries, about to be replaced by the sweep currently building
-- pendingEntries -- see advanceFieldScan) and reuses that id if so. This
-- replaced the old "wailaFieldId is NOT a stable identity" design, which
-- only existed because the earlier grid-flood-fill scanner had nothing
-- more reliable than fuzzy proximity to match blobs across sweeps with.
-- nil for a genuinely new field (or the very first sweep ever).
function WailaFieldIndex:findMatchingPreviousId(sampleX, sampleZ)
    if self.entries == nil then
        return nil
    end
    for _, entry in ipairs(self.entries) do
        if entry.boundary ~= nil and WailaUtil.getIsPosInsidePolygon(entry.boundary, sampleX, sampleZ) then
            return entry.wailaFieldId
        end
    end
    return nil
end

-- Builds a fresh entry (wailaFieldId + positions + a live WailaField read)
-- for one traced blob. Shared by the full sweep, rescanBlobAt, and the
-- initial-cache-refresh pass -- one place that knows how to turn "a
-- position + a boundary" into a registry entry. riceField is whatever
-- WailaFieldGridScanner:getRiceFieldAt() found covering this blob's seed
-- point, or nil -- metadata only now, not a merge decision (see
-- WailaFieldGridScanner.lua). boundary is the real traced Polygon2D, or
-- nil if this entry is being restored from an old cache with no saved
-- boundary (see loadFromXML) -- boundaryPositions is derived from it here
-- (flat vertices repaired back into {x,z} pairs) purely for saveToXML's
-- serialization, so callers never have to do that conversion themselves.
function WailaFieldIndex:buildEntry(labelX, labelZ, sampleX, sampleZ, riceField, boundary)
    local wailaFieldId = self:findMatchingPreviousId(sampleX, sampleZ)
    if wailaFieldId == nil then
        wailaFieldId = self.nextWailaFieldId
        self.nextWailaFieldId = self.nextWailaFieldId + 1
    end

    local boundaryPositions = nil
    if boundary ~= nil then
        boundaryPositions = {}
        local vertices = boundary:getVertices()
        for i = 1, #vertices, 2 do
            table.insert(boundaryPositions, { vertices[i], vertices[i + 1] })
        end
    end

    return {
        wailaFieldId = wailaFieldId,
        labelX = labelX,
        labelZ = labelZ,
        sampleX = sampleX,
        sampleZ = sampleZ,
        field = self.fieldInspector:inspectPoint(sampleX, 0, sampleZ),
        riceField = riceField,
        boundary = boundary,
        boundaryPositions = boundaryPositions,
    }
end

-- Advances the scanner by SCAN_BUDGET_SEC -- may finish a boundary trace
-- (a new blob entry), may just make partial progress on one (nothing
-- returned yet, same tick), or may complete a full sweep pass.
function WailaFieldIndex:advanceFieldScan()
    local labelX, labelZ, sampleX, sampleZ, areaSqm, riceField, sweepCompleted, boundary =
        self.scanner:update(WailaFieldIndex.SCAN_BUDGET_SEC)

    if labelX ~= nil then
        local entry = self:buildEntry(labelX, labelZ, sampleX, sampleZ, riceField, boundary)
        table.insert(self.pendingEntries, entry)
        log(string.format("[WailaFieldIndex] Field found: wailaFieldId=%d area=%.0fm^2 boundaryPoints=%d label=(%.1f, %.1f)",
            entry.wailaFieldId, areaSqm or -1, entry.boundaryPositions ~= nil and #entry.boundaryPositions or 0, labelX, labelZ))
    end

    if sweepCompleted then
        self.entries = self.pendingEntries
        self.pendingEntries = nil
        self.isSweeping = false
        self.hasCompletedSweep = true
        self.lastSweepDurationSec = self.sweepStartTime ~= nil and (getTimeSec() - self.sweepStartTime) or nil
        log(string.format("[WailaFieldIndex] Field sweep finished in %.1fs, %d entr%s found",
            self.lastSweepDurationSec or -1, #self.entries, #self.entries == 1 and "y" or "ies"))
    end
end

-- Exact match first: any entry whose real traced boundary contains
-- (x, z) -- authoritative, not an approximation, and the whole reason
-- that boundary gets traced at all. Falls back to the old nearest-
-- sample-within-radius heuristic only for entries that don't have a
-- boundary (an old cache entry whose trace hasn't been redone yet, see
-- needsInitialRefresh) -- "nearest entry to a position we know was
-- inside it a moment ago" is a safe, narrower substitute for those.
function WailaFieldIndex:findNearestEntryIndex(x, z)
    if self.entries == nil then
        return nil
    end

    for index, entry in ipairs(self.entries) do
        if entry.boundary ~= nil and WailaUtil.getIsPosInsidePolygon(entry.boundary, x, z) then
            return index
        end
    end

    local bestIndex, bestDistSq = nil, nil
    for index, entry in ipairs(self.entries) do
        if entry.boundary == nil then
            local dx = entry.sampleX - x
            local dz = entry.sampleZ - z
            local distSq = dx * dx + dz * dz
            if bestDistSq == nil or distSq < bestDistSq then
                bestIndex, bestDistSq = index, distSq
            end
        end
    end

    if bestDistSq ~= nil and bestDistSq <= WailaFieldIndex.BLOB_MATCH_RADIUS * WailaFieldIndex.BLOB_MATCH_RADIUS then
        return bestIndex
    end
    return nil
end

-- Re-scans just the one blob at (x, z) -- called right after a vehicle
-- leaves a field it was just standing on. Patches self.entries in place
-- (replace/add/remove) and fires VEHICLE_LEFT_FIELD with whatever entry
-- resulted (nil if the ground isn't field anymore).
function WailaFieldIndex:rescanBlobAt(vehicleOrPlayer, x, z)
    if self.entries == nil then
        return
    end

    local existingIndex = self:findNearestEntryIndex(x, z)
    local labelX, labelZ, sampleX, sampleZ, areaSqm, riceField, boundary = self.scanner:scanBlobAt(x, z)

    local resultEntry = nil

    if labelX == nil or areaSqm < WailaFieldGridScanner.MIN_BLOB_AREA_SQM then
        if existingIndex ~= nil then
            table.remove(self.entries, existingIndex)
        end
    else
        local entry = self:buildEntry(labelX, labelZ, sampleX, sampleZ, riceField, boundary)
        if existingIndex ~= nil then
            -- Keep the OLD labelX/labelZ -- scanBlobAt() anchors its own
            -- label pick to wherever ITS trace started (the vehicle's
            -- exit point), not the blob's stable full-sweep-order
            -- position -- overwriting it would make the label hop around
            -- every time a vehicle happens to leave from a different spot.
            entry.labelX = self.entries[existingIndex].labelX
            entry.labelZ = self.entries[existingIndex].labelZ
            self.entries[existingIndex] = entry
        else
            table.insert(self.entries, entry)
        end
        resultEntry = entry
    end

    -- Unconditional lifesign at the publish site itself, not just
    -- whatever a subscriber happens to log on its own end -- any mod can
    -- subscribe to this (Waila.events.vehicleLeftField), so "did WAILA
    -- actually fire this" needs to be independently confirmable from
    -- "did the subscriber handle it correctly".
    log("[VehicleTracking] firing VEHICLE_LEFT_FIELD entry=%s", tostring(resultEntry and resultEntry.wailaFieldId))
    g_messageCenter:publish(WailaFieldIndex.VEHICLE_LEFT_FIELD, vehicleOrPlayer, resultEntry)
end

-- Polls the player and every currently AI-active vehicle for an on-field
-- leave transition -- identical mechanism to SmartMinimapAuto's
-- checkVehicleFieldTransitions (see there for the getIsAIActive/
-- vehicleSystem.vehicles/g_localPlayer:getPosition() provenance).
function WailaFieldIndex:checkVehicleFieldTransitions()
    local relevant = {}

    local localPlayer = g_localPlayer
    if localPlayer ~= nil then
        local x, _, z = localPlayer:getPosition()
        relevant[localPlayer] = { x = x, z = z }
    end

    local vehicleSystem = g_currentMission ~= nil and g_currentMission.vehicleSystem
    if vehicleSystem ~= nil then
        for _, vehicle in ipairs(vehicleSystem.vehicles) do
            if vehicle.getIsAIActive ~= nil and vehicle.rootNode ~= nil and vehicle:getIsAIActive() then
                local x, _, z = getWorldTranslation(vehicle.rootNode)
                relevant[vehicle] = { x = x, z = z }
            end
        end
    end

    local previous = self.vehicleFieldState
    local current = {}
    for entity, pos in pairs(relevant) do
        local isOnField = FSDensityMapUtil.getFieldDataAtWorldPosition(pos.x, 0, pos.z) == true
        local previousState = previous[entity]
        if previousState ~= nil and previousState.onField and not isOnField then
            self:rescanBlobAt(entity, previousState.x, previousState.z)
        end
        current[entity] = { x = pos.x, z = pos.z, onField = isOnField }
    end
    self.vehicleFieldState = current
end

-- Public: nearest known entry's field within BLOB_MATCH_RADIUS of (x, z),
-- or nil. Registry-only, may lag reality -- see file header.
function WailaFieldIndex:get(x, z)
    local index = self:findNearestEntryIndex(x, z)
    if index == nil then
        return nil
    end
    return self.entries[index].field
end

-- Public: the full registry entry nearest (x, z), not just its .field --
-- get() above only ever hands back the field data, so there was no way to
-- see which blob/wailaFieldId a given live position actually belongs to.
function WailaFieldIndex:getEntry(x, z)
    local index = self:findNearestEntryIndex(x, z)
    if index == nil then
        return nil
    end
    return self.entries[index]
end

-- Public: every known entry, full tables, not just the WailaField
-- objects -- callers that only want the field data can pull .field
-- themselves, this keeps position/id/boundary available for whoever
-- needs it too.
function WailaFieldIndex:getAll()
    return self.entries or {}
end

-- type()-dispatched write -- entry.field:dumpLogJson() is an arbitrary
-- flat table (numbers/strings/booleans/nils), not something with its own
-- fixed schema to write field-by-field.
local function setXmlValue(xmlFile, key, value)
    if value == nil then
        return
    end
    local valueType = type(value)
    if valueType == "number" then
        -- Lua doesn't distinguish int/float at the language level, so
        -- "whole number" is the best available signal -- fieldId,
        -- growthState, weedState, sprayLevel etc. are all conceptually
        -- ints and would otherwise come out as e.g. fieldId="22.000000".
        -- areaHa (the one genuinely fractional field here) still goes
        -- through setFloat normally.
        if value == math.floor(value) then
            xmlFile:setInt(key, value)
        else
            xmlFile:setFloat(key, value)
        end
    elseif valueType == "boolean" then
        xmlFile:setBool(key, value)
    else
        xmlFile:setString(key, tostring(value))
    end
end

-- Writes positions AND each entry's full field:dumpLogJson() data -- the
-- point of this file isn't just "restore the registry on load" (which
-- only needs positions, see loadFromXML) but also being genuinely
-- readable on its own: open waila.xml and see real crop/growth/weed/
-- spray/lime data per field, an alternative to WailaDebugDump's log-only
-- dumps for the same information. Returns (true, path, entryCount) on
-- success, (false, reason) otherwise -- meant to be called both from the
-- SavegameController.onSaveComplete hook (return value ignored there) and
-- on-demand from the debug menu (where the caller wants to report status).
function WailaFieldIndex:saveToXML()
    if self.entries == nil then
        return false, "index not ready yet (still sweeping)"
    end
    -- An empty self.entries is only trustworthy once a real sweep has
    -- actually finished THIS session -- otherwise it's just whatever
    -- loadFromXML() found on disk a moment ago (possibly nothing at all,
    -- e.g. the very first session ever), not a confirmed "zero fields".
    -- A non-empty self.entries is fine to save regardless -- see
    -- needsInitialRefresh, cached entries already get their field data
    -- refreshed live before this could ever be called.
    if #self.entries == 0 and not self.hasCompletedSweep then
        return false, "index not confirmed yet (still on startup data, first sweep hasn't finished)"
    end
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return false, "no current mission"
    end
    local savegameDirectory = g_currentMission.missionInfo.savegameDirectory
    if savegameDirectory == nil then
        return false, "no savegame directory"
    end

    local path = savegameDirectory .. "/" .. WailaFieldIndex.SAVEGAME_FILENAME
    local xmlFile = XMLFile.create("wailaFieldIndex", path, "waila")
    if xmlFile == nil then
        return false, "XMLFile.create failed"
    end

    if self.lastSweepDurationSec ~= nil then
        xmlFile:setFloat("waila#lastSweepDurationSec", self.lastSweepDurationSec)
    end

    for index, entry in ipairs(self.entries) do
        local key = string.format("waila.fields.field(%d)", index - 1)
        -- Deliberately named differently from fieldId (the game's own,
        -- nullable, unregistered-ground-has-none Field ID, written below
        -- via the generic dumpLogJson() loop) so the two are never
        -- visually confused for the same thing.
        xmlFile:setInt(key .. "#wailaFieldId", entry.wailaFieldId)
        xmlFile:setFloat(key .. "#labelX", entry.labelX)
        xmlFile:setFloat(key .. "#labelZ", entry.labelZ)
        xmlFile:setFloat(key .. "#sampleX", entry.sampleX)
        xmlFile:setFloat(key .. "#sampleZ", entry.sampleZ)

        -- Real traced boundary (see WailaFieldBoundaryTracer.lua), written
        -- as a "x z x z ..." string -- same attribute name and shape the
        -- base game's own FieldCourseField:saveToXMLFile uses for its
        -- island boundaries (confirmed via decompile), not invented here.
        -- Still nil for an entry restored from an even older cache whose
        -- trace hasn't been redone yet -- falls back to the radius
        -- heuristic again on next load until a fresh trace completes.
        if entry.boundaryPositions ~= nil then
            local parts = {}
            for _, position in ipairs(entry.boundaryPositions) do
                table.insert(parts, string.format("%.2f %.2f", position[1], position[2]))
            end
            xmlFile:setString(key .. ".boundary#positions", table.concat(parts, " "))
        end

        if entry.field ~= nil then
            local fieldData = entry.field:dumpLogJson()
            -- jobs is a list, not a flat attribute -- written as <job
            -- type="..."/> children instead, per the requested shape.
            for fieldKey, value in pairs(fieldData) do
                if fieldKey ~= "jobs" then
                    setXmlValue(xmlFile, key .. "#" .. fieldKey, value)
                end
            end
            for jobIndex, jobType in ipairs(fieldData.jobs or {}) do
                xmlFile:setString(string.format("%s.job(%d)#type", key, jobIndex - 1), jobType)
            end
        end

        -- Real values embedded, not a reference -- PlaceableRiceField's
        -- own field data has no persistent ID to reference at all (only
        -- array position; confirmed via dataS.gar, PlaceableRiceField:
        -- createNewField), so embedding is the only option that's
        -- actually useful to a reader. height/waterHeight/areaSqm/
        -- capacity are the real runtime field names on that object (note:
        -- the XML the game itself writes calls height "worldHeight" --
        -- kept as height here to match the live Lua object, not the
        -- game's own on-disk save format).
        if entry.riceField ~= nil then
            local riceKey = key .. ".riceField"
            setXmlValue(xmlFile, riceKey .. "#height", entry.riceField.height)
            setXmlValue(xmlFile, riceKey .. "#waterHeight", entry.riceField.waterHeight)
            setXmlValue(xmlFile, riceKey .. "#areaSqm", entry.riceField.areaSqm)
            setXmlValue(xmlFile, riceKey .. "#capacity", entry.riceField.capacity)
        end
    end

    -- Declared areas (see Waila.registerArea/WailaDeclaredArea) written
    -- into the same waila.xml -- this method is the only "dump WAILA's
    -- current state" entry point that exists (wired to the debug menu),
    -- and areas are cheap/few, so a second file wasn't worth it. Only box
    -- areas are written -- polygon areas have no serialization story yet,
    -- not needed until something actually registers one. Restored on
    -- loadFromXML below via the exact same Waila.registerArea call any
    -- mod would use.
    --
    -- metadata written as <entry key=".." value=".."/> children, not flat
    -- attributes -- restoring flat attributes generically would need an
    -- "enumerate this element's attribute names" XMLFile method that
    -- doesn't exist. Children can be iterated by a fixed path without
    -- knowing the key names in advance, same trick the existing
    -- <job type="..."/> children already rely on.
    local areaIndex = 0
    for _, index in pairs(Waila.indices) do
        if index.className == WailaAreaIndex.MARKER then
            for _, area in ipairs(index:getAll()) do
                local areaKey = string.format("waila.declaredAreas.area(%d)", areaIndex)
                areaIndex = areaIndex + 1
                xmlFile:setString(areaKey .. "#type", area.type)
                if area.wailaID ~= nil then
                    xmlFile:setString(areaKey .. "#wailaID", area.wailaID)
                end
                if area.box ~= nil then
                    xmlFile:setFloat(areaKey .. ".box#minX", area.box.minX)
                    xmlFile:setFloat(areaKey .. ".box#maxX", area.box.maxX)
                    xmlFile:setFloat(areaKey .. ".box#minZ", area.box.minZ)
                    xmlFile:setFloat(areaKey .. ".box#maxZ", area.box.maxZ)
                end
                local metaIndex = 0
                for metaKey, value in pairs(area.metadata) do
                    local entryKey = string.format("%s.metadata.entry(%d)", areaKey, metaIndex)
                    metaIndex = metaIndex + 1
                    xmlFile:setString(entryKey .. "#key", metaKey)
                    xmlFile:setString(entryKey .. "#value", tostring(value))
                end
            end
        end
    end

    xmlFile:save()
    xmlFile:delete()

    return true, path, #self.entries
end

-- Only restores positions -- field is populated for each entry on the
-- next safe update() tick (see needsInitialRefresh), not here (density
-- maps aren't bound yet this early). wailaFieldId is NOT persisted --
-- unlike a full sweep (which can match against the previous sweep's still-
-- live boundaries, see findMatchingPreviousId), a fresh load has nothing
-- to match a cached position against yet, so ids are simply reassigned in
-- file order here. They'll settle back onto stable values once the first
-- real sweep after load runs.
function WailaFieldIndex:loadFromXML()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return
    end
    local savegameDirectory = g_currentMission.missionInfo.savegameDirectory
    if savegameDirectory == nil then
        return
    end

    local xmlFile = XMLFile.loadIfExists("wailaFieldIndex", savegameDirectory .. "/" .. WailaFieldIndex.SAVEGAME_FILENAME)
    if xmlFile == nil then
        return
    end

    local entries = {}
    for _, key in xmlFile:iterator("waila.fields.field") do
        local wailaFieldId = self.nextWailaFieldId
        self.nextWailaFieldId = self.nextWailaFieldId + 1

        -- Real traced boundary, symmetric with the write side in
        -- saveToXML -- "x z x z ..." parsed back into {x,z} pairs and
        -- wrapped in a Polygon2D directly, no fresh trace needed if this
        -- was saved. nil (both stay nil) if this entry predates boundary
        -- tracing entirely -- update()'s needsInitialRefresh pass queues
        -- a fresh trace for those.
        local boundaryPositions = nil
        local boundary = nil
        local boundaryStr = xmlFile:getString(key .. ".boundary#positions")
        if boundaryStr ~= nil then
            local numbers = string.split(boundaryStr, " ")
            boundaryPositions = {}
            local flatVertices = {}
            for i = 1, #numbers, 2 do
                local px = tonumber(numbers[i])
                local pz = tonumber(numbers[i + 1])
                if px ~= nil and pz ~= nil then
                    table.insert(boundaryPositions, { px, pz })
                    table.insert(flatVertices, px)
                    table.insert(flatVertices, pz)
                end
            end
            boundary = Polygon2D.new(nil, flatVertices)
        end

        table.insert(entries, {
            wailaFieldId = wailaFieldId,
            labelX = xmlFile:getFloat(key .. "#labelX"),
            labelZ = xmlFile:getFloat(key .. "#labelZ"),
            sampleX = xmlFile:getFloat(key .. "#sampleX"),
            sampleZ = xmlFile:getFloat(key .. "#sampleZ"),
            field = nil,
            boundaryPositions = boundaryPositions,
            boundary = boundary,
        })
    end
    -- Declared areas -- symmetric with the write side in saveToXML above.
    -- Box areas only (same limitation as the write side). Restored
    -- straight into Waila.indices via Waila.registerArea, same call any
    -- mod would use -- WailaFieldIndex doesn't hold onto these itself,
    -- it's just the thing that happened to read them off disk.
    for _, key in xmlFile:iterator("waila.declaredAreas.area") do
        local areaType = xmlFile:getString(key .. "#type")
        local boxKey = key .. ".box"
        if areaType ~= nil and xmlFile:hasProperty(boxKey) then
            local metadata = {}
            for _, entryKey in xmlFile:iterator(key .. ".metadata.entry") do
                local metaKey = xmlFile:getString(entryKey .. "#key")
                local rawValue = xmlFile:getString(entryKey .. "#value")
                if metaKey ~= nil then
                    -- Numbers round-trip as numbers (tonumber succeeds),
                    -- everything else stays a string -- there's no type
                    -- tag written alongside the value (see saveToXML), so
                    -- this is a best-effort guess, not a guarantee. Fine
                    -- for the metadata this session actually writes
                    -- (originX/originZ, plain floats).
                    metadata[metaKey] = tonumber(rawValue) or rawValue
                end
            end

            Waila.registerArea({
                type = areaType,
                -- nil for an area saved before this field existed -- falls
                -- back to Waila.registerArea generating a fresh one, same
                -- as any other id-less caller. That one legacy load may
                -- still duplicate on a second reload; it self-heals the
                -- next time saveToXML runs, since the newly-generated id
                -- gets persisted then.
                wailaID = xmlFile:getString(key .. "#wailaID"),
                box = {
                    minX = xmlFile:getFloat(boxKey .. "#minX"),
                    maxX = xmlFile:getFloat(boxKey .. "#maxX"),
                    minZ = xmlFile:getFloat(boxKey .. "#minZ"),
                    maxZ = xmlFile:getFloat(boxKey .. "#maxZ"),
                },
                metadata = metadata,
            })
        end
    end

    xmlFile:delete()

    self.entries = entries
    self.needsInitialRefresh = #entries > 0
end

function WailaFieldIndex:update(dt)
    if self.scanner == nil then
        -- First-ever tick(s) -- see start()'s comment on why the scanner
        -- isn't created there. Also waits on g_currentMission.terrainDetailId/
        -- terrainDetailMapSize specifically, not just terrainSize -- WailaField
        -- BoundaryTracer is the first piece of WAILA to touch those two at
        -- all (the old flood-fill scanner only ever used
        -- FSDensityMapUtil.getFieldDataAtWorldPosition, never
        -- terrainDetailId/getDensityAtWorldPos directly), and confirmed
        -- live that this is the exact same class of bug terrainSize
        -- already taught us about: an unready dependency doesn't error,
        -- it just makes every WailaFieldBoundaryTracer.new() silently
        -- return nil ("not on field" by its own check), so a full sweep
        -- runs suspiciously fast and finds zero entries instead of
        -- failing loudly. Retried every tick (not just once) until ready.
        if g_currentMission == nil
            or g_currentMission.terrainDetailId == nil
            or g_currentMission.terrainDetailMapSize == nil
            or g_currentMission.terrainDetailMapSize <= 0 then
            return
        end

        -- Logged once, permanently (not TEMP DEBUG) since "what grid size
        -- did this actually initialize with" is exactly the fact needed
        -- to confirm/rule out a misaligned scan without guessing again.
        self.scanner = WailaFieldGridScanner.new()
        log(string.format("[WailaFieldIndex] Scanner created: terrainSize=%s cols=%s terrainDetailMapSize=%s",
            tostring(g_currentMission.terrainSize), tostring(self.scanner.cols), tostring(g_currentMission.terrainDetailMapSize)))
        self:startFullSweep()
        return
    end

    if self.needsInitialRefresh then
        self.needsInitialRefresh = false
        for _, entry in ipairs(self.entries) do
            entry.field = self.fieldInspector:inspectPoint(entry.sampleX, 0, entry.sampleZ)
            -- Cache entry with no saved boundary (predates boundary
            -- tracing entirely) -- trace fresh, synchronously (bounded to
            -- one field, same tradeoff scanBlobAt already makes) instead
            -- of leaving it stuck on the radius-match fallback forever.
            if entry.boundary == nil then
                local labelX, labelZ, sampleX, sampleZ, areaSqm, riceField, boundary =
                    self.scanner:scanBlobAt(entry.sampleX, entry.sampleZ)
                if boundary ~= nil then
                    local refreshed = self:buildEntry(labelX, labelZ, sampleX, sampleZ, riceField, boundary)
                    entry.boundary = refreshed.boundary
                    entry.boundaryPositions = refreshed.boundaryPositions
                    entry.riceField = refreshed.riceField
                end
            end
        end
    end

    self.vehicleCheckTimer = self.vehicleCheckTimer + dt
    if self.vehicleCheckTimer >= WailaFieldIndex.VEHICLE_CHECK_INTERVAL then
        self.vehicleCheckTimer = 0
        self:checkVehicleFieldTransitions()
    end

    if self.isSweeping then
        self:advanceFieldScan()
        return
    end

    self.resweepFallbackTimer = self.resweepFallbackTimer + dt
    if self.resweepFallbackTimer >= WailaFieldIndex.RESWEEP_FALLBACK_INTERVAL then
        self.resweepFallbackTimer = 0
        self:startFullSweep()
    end
end
