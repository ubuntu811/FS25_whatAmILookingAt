--[[
    PlaceableWailaTestRig.lua

    Real placeable wrapper around WailaDebugTools:placeFoliageTestRig --
    the existing debug-hub button anchors the rig at whatever WAILA's
    last raycast hit happened to be, no way to steer position or angle.
    As a placeable, the standard engine construction flow gives that for
    free (mouse-follow preview, rotation controls), no custom
    ConstructionBrush class needed since this is plain point+rotation.
]]

PlaceableWailaTestRig = {}

function PlaceableWailaTestRig.prerequisitesPresent(specializations)
    return true
end

function PlaceableWailaTestRig.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableWailaTestRig)
    SpecializationUtil.registerEventListener(placeableType, "onPostFinalizePlacement", PlaceableWailaTestRig)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", PlaceableWailaTestRig)
end

function PlaceableWailaTestRig.registerSavegameXMLPaths(schema, basePath)
    schema:register(XMLValueType.FLOAT, basePath .. "#originX", "Test rig grid origin X")
    schema:register(XMLValueType.FLOAT, basePath .. "#originZ", "Test rig grid origin Z")
    schema:register(XMLValueType.FLOAT, basePath .. "#rotationY", "Test rig grid rotation (radians)")
end

function PlaceableWailaTestRig:onLoad(savegame)
    self.spec_wailaFoliageTestRig = self.spec_wailaFoliageTestRig or {}
end

function PlaceableWailaTestRig:loadFromXMLFile(xmlFile, key)
    local spec = self.spec_wailaFoliageTestRig
    spec.originX = xmlFile:getValue(key .. "#originX")
    spec.originZ = xmlFile:getValue(key .. "#originZ")
    spec.rotationY = xmlFile:getValue(key .. "#rotationY", 0)
    return true
end

function PlaceableWailaTestRig:saveToXMLFile(xmlFile, key)
    local spec = self.spec_wailaFoliageTestRig
    if spec.originX ~= nil then
        xmlFile:setValue(key .. "#originX", spec.originX)
        xmlFile:setValue(key .. "#originZ", spec.originZ)
        xmlFile:setValue(key .. "#rotationY", spec.rotationY or 0)
    end
end

-- spec.originX stays nil until either loadFromXMLFile (restoring a saved
-- placeable) or this function's own fresh-placement branch sets it --
-- same nil-check-as-fresh-placement-signal pattern Daisychain's own
-- spec.field already relies on.
function PlaceableWailaTestRig:onPostFinalizePlacement()
    if not self.isServer then
        return
    end

    local spec = self.spec_wailaFoliageTestRig
    local debugTools = g_currentMission.wailaDebugTools
    if debugTools == nil then
        return
    end

    local wailaID = "wailaFoliageTestRig_" .. self:getUniqueId()

    if spec.originX == nil then
        -- Fresh placement: actually generate the grid, once, at the
        -- real placed position/rotation instead of a raycast guess.
        local x, _, z = getWorldTranslation(self.rootNode)
        local _, rotY, _ = getRotation(self.rootNode)
        debugTools:placeFoliageTestRig(x, z, rotY, wailaID)
        spec.originX, spec.originZ, spec.rotationY = x, z, rotY
    else
        -- Reload: terrain painting already persisted on its own, only
        -- WAILA's in-memory registry needs re-asserting -- see
        -- registerTestRigArea's own comment for why this can't just rely
        -- on waila.xml alone.
        debugTools:registerTestRigArea(spec.originX, spec.originZ, spec.rotationY, wailaID)
    end
end

-- This object is responsible for cleaning up its own mess regardless of
-- what triggered the delete -- same reasoning Daisychain's own onDelete
-- documents. Real terrain cleanup here, not left to whatever the
-- Declared Areas hub's own Delete button happens to do (deleting the
-- placeable itself -- via a future collision-based Demolition Mode, or
-- any other real removal path -- must not leave a rig-shaped scar with
-- no way left to clean it up).
function PlaceableWailaTestRig:onDelete()
    if not self.isServer then
        return
    end

    local spec = self.spec_wailaFoliageTestRig
    if spec.originX == nil then
        return
    end

    local debugTools = g_currentMission.wailaDebugTools
    if debugTools ~= nil then
        debugTools:clearFoliageTestRigGrid(spec.originX, spec.originZ, spec.rotationY)
        debugTools:clearConcreteBorder(spec.originX, spec.originZ, spec.rotationY)
    end

    local index = Waila.indices[WailaDebugTools.TEST_RIG_AREA_TYPE]
    if index ~= nil and index.className == WailaAreaIndex.MARKER then
        local wailaID = "wailaFoliageTestRig_" .. self:getUniqueId()
        for _, area in ipairs(index:getAll()) do
            if area.wailaID == wailaID then
                Waila.unregisterArea(area)
            end
        end
    end
end
