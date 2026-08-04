WailaObjectInspector = {}
local WailaObjectInspector_mt = Class(WailaObjectInspector)

function WailaObjectInspector.new()
    return setmetatable({}, WailaObjectInspector_mt)
end

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

    return {x = x, y = y, z = z}
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

local function getObjectName(object)
    if object == nil then
        return nil
    end

    for _, methodName in ipairs({"getFullName", "getName"}) do
        local method = object[methodName]
        if method ~= nil then
            local value = WailaUtil.safeCall(nil, method, object)
            if value ~= nil and value ~= "" then
                return tostring(value)
            end
        end
    end

    return object.configFileName or object.className
end

function WailaObjectInspector:inspect(hit)
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

    return {
        kind = kind,
        nodeId = nodeId,
        nodeName = nodeName,
        nodePosition = getWorldPosition(nodeId),
        parentNodeId = parent,
        parentNodeName = parentNodeName,
        parentIsTerrainRootNode = parentIsTerrainRootNode,
        parentIsTerrainNode = parentIsTerrainNode,
        object = object,
        objectClass = WailaUtil.className(object),
        objectName = getObjectName(object),
        ownerFarmId = ownerFarmId,
        rootVehicle = rootVehicle,
        rootVehicleClass = WailaUtil.className(rootVehicle),
        rootVehicleName = getObjectName(rootVehicle),
        rootVehicleNodeId = rootVehicleNodeId,
        rootVehiclePosition = getWorldPosition(rootVehicleNodeId),
        rigidBodyType = rigidBodyType,
        rigidBodyTypeName = WailaUtil.rigidBodyTypeName(rigidBodyType),
        isSplitShape = isSplitShape,
        splitType = splitType,
        isSplit = split,
        volume = isSplitShape and WailaUtil.safeGlobalCall("getVolume", nil, nodeId) or nil,
        mass = WailaUtil.safeGlobalCall("getMass", nil, nodeId),
        isSleeping = WailaUtil.safeGlobalCall("getIsSleeping", nil, nodeId)
    }
end
