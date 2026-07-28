WailaVehicleInspector = {}
local WailaVehicleInspector_mt = Class(WailaVehicleInspector)

function WailaVehicleInspector.new()
    return setmetatable({}, WailaVehicleInspector_mt)
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

local function findOwningVehicle(nodeId, object)
    local vehicle = getRootVehicle(object)
    if vehicle ~= nil then
        return vehicle
    end

    local searchNode = nodeId
    while searchNode ~= nil and searchNode ~= 0 do
        local nodeObject = g_currentMission ~= nil and g_currentMission:getNodeObject(searchNode) or nil
        vehicle = getRootVehicle(nodeObject)
        if vehicle ~= nil then
            return vehicle
        end

        searchNode = WailaUtil.safeGlobalCall("getParent", 0, searchNode)
    end

    return nil
end

local function isNodeBelow(nodeId, possibleParent)
    if nodeId == nil or nodeId == 0 or possibleParent == nil or possibleParent == 0 then
        return false
    end

    local current = nodeId
    while current ~= nil and current ~= 0 do
        if current == possibleParent then
            return true
        end
        current = WailaUtil.safeGlobalCall("getParent", 0, current)
    end

    return false
end

local function findComponent(vehicle, hitNodeId)
    local components = vehicle.components or {}
    for index, component in ipairs(components) do
        local componentNode = component.node
        if componentNode ~= nil and isNodeBelow(hitNodeId, componentNode) then
            return index, componentNode, WailaUtil.safeGlobalCall("getName", nil, componentNode)
        end
    end
    return nil, nil, nil
end

local function findWheel(vehicle, hitNodeId)
    local spec = vehicle.spec_wheels
    local wheels = spec ~= nil and spec.wheels or {}

    for index, wheel in ipairs(wheels) do
        local candidates = {
            {"node", wheel.node},
            {"repr", wheel.repr},
            {"driveNode", wheel.driveNode},
            {"wheelShape", wheel.wheelShape},
            {"visualNode", wheel.visualNode}
        }

        for _, candidate in ipairs(candidates) do
            local fieldName = candidate[1]
            local nodeId = candidate[2]
            if nodeId ~= nil and isNodeBelow(hitNodeId, nodeId) then
                return index, fieldName, nodeId, WailaUtil.safeGlobalCall("getName", nil, nodeId)
            end
        end
    end

    return nil, nil, nil, nil
end

local function findAttacherJoint(vehicle, hitNodeId)
    local spec = vehicle.spec_attacherJoints
    local joints = spec ~= nil and spec.attacherJoints or {}

    for index, joint in ipairs(joints) do
        local nodeId = joint.jointTransform or joint.rootNode or joint.node
        if nodeId ~= nil and (isNodeBelow(hitNodeId, nodeId) or isNodeBelow(nodeId, hitNodeId)) then
            local jointType = joint.jointType
            local jointTypeName = nil
            if AttacherJoints ~= nil and AttacherJoints.jointTypeNameToInt ~= nil then
                for name, value in pairs(AttacherJoints.jointTypeNameToInt) do
                    if value == jointType then
                        jointTypeName = name
                        break
                    end
                end
            end

            return index, nodeId, WailaUtil.safeGlobalCall("getName", nil, nodeId), jointType, jointTypeName
        end
    end

    return nil, nil, nil, nil, nil
end

function WailaVehicleInspector:inspect(hit, objectInspection)
    local hitNodeId = hit.nodeId
    local hitObject = objectInspection ~= nil and objectInspection.object or nil
    local vehicle = findOwningVehicle(hitNodeId, hitObject)

    if vehicle == nil then
        return nil
    end

    local componentIndex, componentNodeId, componentNodeName = findComponent(vehicle, hitNodeId)
    local wheelIndex, wheelNodeField, wheelNodeId, wheelNodeName = findWheel(vehicle, hitNodeId)
    local attacherJointIndex, attacherJointNodeId, attacherJointNodeName, attacherJointType, attacherJointTypeName = findAttacherJoint(vehicle, hitNodeId)

    local components = vehicle.components or {}
    local wheels = vehicle.spec_wheels ~= nil and vehicle.spec_wheels.wheels or {}
    local attacherJoints = vehicle.spec_attacherJoints ~= nil and vehicle.spec_attacherJoints.attacherJoints or {}

    return {
        hitNodeId = hitNodeId,
        hitNodeName = WailaUtil.safeGlobalCall("getName", nil, hitNodeId),
        vehicle = vehicle,
        vehicleName = getObjectName(vehicle),
        vehicleClass = WailaUtil.className(vehicle),
        configFileName = vehicle.configFileName,
        rootNodeId = vehicle.rootNode,
        rootNodeName = vehicle.rootNode ~= nil and WailaUtil.safeGlobalCall("getName", nil, vehicle.rootNode) or nil,

        componentCount = #components,
        componentIndex = componentIndex,
        componentNodeId = componentNodeId,
        componentNodeName = componentNodeName,

        wheelCount = #wheels,
        wheelIndex = wheelIndex,
        wheelNodeField = wheelNodeField,
        wheelNodeId = wheelNodeId,
        wheelNodeName = wheelNodeName,

        attacherJointCount = #attacherJoints,
        attacherJointIndex = attacherJointIndex,
        attacherJointNodeId = attacherJointNodeId,
        attacherJointNodeName = attacherJointNodeName,
        attacherJointType = attacherJointType,
        attacherJointTypeName = attacherJointTypeName
    }
end
