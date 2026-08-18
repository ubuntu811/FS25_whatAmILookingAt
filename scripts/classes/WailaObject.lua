--[[
    WailaObject.lua

    Typed result class for WailaObjectInspector:inspect() -- unlike
    WailaField/WailaTerrain, this one's constructor takes the raw raycast
    hit directly and does the entire derivation itself (kind
    classification, root-vehicle walk, name resolution, ...), since there
    isn't a distinct "inspector orchestrates several API calls, class just
    shapes the result" split here -- it's one pass over a single hit, in
    one place, so the inspector ends up a thin pass-through.

    object/rootVehicle are the LIVE engine object references, kept as
    real instance fields for existing internal consumers (WailaDebugDump's
    nested raw dump of inspection.object.object) -- but deliberately left
    out of toTable()/dumpHudJson()/dumpLogJson(), which are meant to be
    plain, JSON-safe snapshots. objectClass/objectName/rootVehicleClass/
    rootVehicleName already capture what's actually describable about
    them for an external consumer that has no business holding a live
    engine reference.
]]

WailaObject = {}
local WailaObject_mt = Class(WailaObject)

local function getWorldPosition(nodeId)
    if nodeId == nil or nodeId == 0 then
        return nil
    end

    if getWorldTranslation == nil then
        return nil
    end

    local ok, x, y, z = pcall(getWorldTranslation, nodeId)
    if not ok or x == nil or y == nil or z == nil then
        return nil
    end

    return { x = x, y = y, z = z }
end

local function getRootVehicle(object)
    if object == nil then
        return nil
    end

    if object.getRootVehicle ~= nil then
        local rootVehicle = WailaUtil.safeCall(nil, object.getRootVehicle, object)
        if rootVehicle ~= nil then
            return rootVehicle
        end
    end

    if object.rootVehicle ~= nil then
        return object.rootVehicle
    end

    if object.isVehicle or (Vehicle ~= nil and object.isa ~= nil and object:isa(Vehicle)) then
        return object
    end

    return nil
end

function WailaObject.new(hit)
    local self = setmetatable({}, WailaObject_mt)

    local nodeId = hit.nodeId
    local object = g_currentMission ~= nil and g_currentMission:getNodeObject(nodeId) or nil
    local rootVehicle = getRootVehicle(object)
    local rigidBodyType = WailaUtil.safeGlobalCall("getRigidBodyType", nil, nodeId)
    local nodeName = WailaUtil.safeGlobalCall("getName", nil, nodeId)
    local parent = WailaUtil.safeGlobalCall("getParent", nil, nodeId)
    local parentNodeName = parent ~= nil and WailaUtil.safeGlobalCall("getName", nil, parent) or nil
    local parentIsTerrainRootNode = parent ~= nil and parent == g_currentMission.terrainRootNode
    local parentIsTerrainNode = parent ~= nil and parent == g_terrainNode
    local isSplitShape = false

    if getHasClassId ~= nil and ClassIds ~= nil and ClassIds.MESH_SPLIT_SHAPE ~= nil then
        isSplitShape = getHasClassId(nodeId, ClassIds.MESH_SPLIT_SHAPE)
    end

    local splitType = isSplitShape and WailaUtil.safeGlobalCall("getSplitType", nil, nodeId) or nil
    local split = isSplitShape and WailaUtil.safeGlobalCall("getIsSplitShapeSplit", nil, nodeId) or nil

    local kind = "node"
    if nodeId == g_currentMission.terrainRootNode or nodeId == g_terrainNode then
        kind = "terrain"
    elseif isSplitShape then
        if rigidBodyType == RigidBodyType.STATIC and not split then
            kind = "tree"
        elseif rigidBodyType == RigidBodyType.STATIC and split then
            kind = "stump/static split shape"
        elseif rigidBodyType == RigidBodyType.DYNAMIC then
            kind = "log/branch"
        else
            kind = "split shape"
        end
    elseif rootVehicle ~= nil then
        kind = "vehicle"
    elseif object ~= nil then
        if Placeable ~= nil and object.isa ~= nil and object:isa(Placeable) then
            kind = "placeable"
        else
            kind = "game object"
        end
    end

    local ownerFarmId = nil
    if object ~= nil and object.getOwnerFarmId ~= nil then
        ownerFarmId = WailaUtil.safeCall(nil, object.getOwnerFarmId, object)
    end

    local rootVehicleNodeId = rootVehicle ~= nil and rootVehicle.rootNode or nil

    self.kind = kind
    self.nodeId = nodeId
    self.nodeName = nodeName
    self.nodePosition = getWorldPosition(nodeId)
    self.parentNodeId = parent
    self.parentNodeName = parentNodeName
    self.parentIsTerrainRootNode = parentIsTerrainRootNode
    self.parentIsTerrainNode = parentIsTerrainNode
    self.object = object
    self.objectClass = WailaUtil.className(object)
    self.objectName = WailaUtil.getObjectName(object)
    self.ownerFarmId = ownerFarmId
    self.rootVehicle = rootVehicle
    self.rootVehicleClass = WailaUtil.className(rootVehicle)
    self.rootVehicleName = WailaUtil.getObjectName(rootVehicle)
    self.rootVehicleNodeId = rootVehicleNodeId
    self.rootVehiclePosition = getWorldPosition(rootVehicleNodeId)
    self.rigidBodyType = rigidBodyType
    self.rigidBodyTypeName = WailaUtil.rigidBodyTypeName(rigidBodyType)
    self.isSplitShape = isSplitShape
    self.splitType = splitType
    self.isSplit = split
    self.volume = isSplitShape and WailaUtil.safeGlobalCall("getVolume", nil, nodeId) or nil
    self.mass = WailaUtil.safeGlobalCall("getMass", nil, nodeId)
    self.isSleeping = WailaUtil.safeGlobalCall("getIsSleeping", nil, nodeId)

    return self
end

function WailaObject:toTable()
    return {
        kind = self.kind,
        nodeId = self.nodeId,
        nodeName = self.nodeName,
        nodePosition = self.nodePosition,
        parentNodeId = self.parentNodeId,
        parentNodeName = self.parentNodeName,
        parentIsTerrainRootNode = self.parentIsTerrainRootNode,
        parentIsTerrainNode = self.parentIsTerrainNode,
        objectClass = self.objectClass,
        objectName = self.objectName,
        ownerFarmId = self.ownerFarmId,
        rootVehicleClass = self.rootVehicleClass,
        rootVehicleName = self.rootVehicleName,
        rootVehicleNodeId = self.rootVehicleNodeId,
        rootVehiclePosition = self.rootVehiclePosition,
        rigidBodyType = self.rigidBodyType,
        rigidBodyTypeName = self.rigidBodyTypeName,
        isSplitShape = self.isSplitShape,
        splitType = self.splitType,
        isSplit = self.isSplit,
        volume = self.volume,
        mass = self.mass,
        isSleeping = self.isSleeping,
    }
end

function WailaObject:dumpHudJson()
    return self:toTable()
end

function WailaObject:dumpLogJson()
    return self:toTable()
end
