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

-- Was always calling object:getRootVehicle() first, which for an
-- attached implement returns the *towing tractor* - the root of the
-- whole combo chain in GIANTS' vehicle-train model, not the specific
-- thing that was actually hit. Confirmed live: aiming straight at a
-- seeder implement's own body still showed "Vehicle: Case IH Steiger 785
-- Quadtrac" (the tractor), never the implement itself. If the hit object
-- already IS a vehicle in its own right (the implement), that's what was
-- physically hit and what inspection should report - getRootVehicle/
-- rootVehicle are only a fallback for resolving a raw non-vehicle
-- component up to *some* owning vehicle.
local function getRootVehicle(object)
    if object == nil then
        return nil
    end

    if object.isVehicle or (Vehicle ~= nil and object.isa ~= nil and object:isa(Vehicle)) then
        return object
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

    -- turnedOn/lowered are only meaningful (not just a default false) when
    -- the relevant spec is actually present - confirmed the hard way
    -- tonight debugging a seeder that "wasn't turned on" per
    -- getIsTurnedOn() despite having no engine to turn on at all, and
    -- similarly for getIsLowered() on something with no lowering
    -- mechanism. Reported as nil (not false) when the spec is missing,
    -- so it's visually obvious in the HUD which case is which.
    -- and/or can't be used here - a real false from getIsTurnedOn()/
    -- getIsLowered() would get silently swallowed into nil by the
    -- "x and y or z" pattern, exactly the distinction this exists to show.
    local hasMotor = vehicle.spec_motorized ~= nil
    local turnedOn = nil
    if hasMotor and vehicle.getIsTurnedOn ~= nil then
        turnedOn = WailaUtil.safeCall(nil, vehicle.getIsTurnedOn, vehicle)
    end

    local hasAttachable = vehicle.spec_attachable ~= nil
    local lowered = nil
    if hasAttachable and vehicle.getIsLowered ~= nil then
        lowered = WailaUtil.safeCall(nil, vehicle.getIsLowered, vehicle)
    end

    local hasFoldable = vehicle.spec_foldable ~= nil
    local unfolded = nil
    if hasFoldable and vehicle.getIsUnfolded ~= nil then
        unfolded = WailaUtil.safeCall(nil, vehicle.getIsUnfolded, vehicle)
    end

    local hasSowingMachine = vehicle.spec_sowingMachine ~= nil
    -- The one field that actually correlated with real sowing activity,
    -- confirmed via live dumps - turnedOn/lowered/unfolded above all
    -- turned out uncorrelated with it. Read directly as a table field,
    -- not a method - that's how it showed up in the dump. and/or would
    -- swallow a real false into nil here too, same bug as before.
    local isWorking = nil
    if hasSowingMachine then
        isWorking = vehicle.spec_sowingMachine.isWorking
    end

    local hasPushHandTool = vehicle.spec_pushHandTool ~= nil

    local workAreaTypes = nil
    if vehicle.spec_workArea ~= nil and vehicle.spec_workArea.workAreas ~= nil then
        workAreaTypes = {}
        for _, workArea in ipairs(vehicle.spec_workArea.workAreas) do
            table.insert(workAreaTypes, tostring(workArea.type))
        end
    end

    -- Confirmed real via base game source (dataS/scripts/vehicles/wheels/
    -- WheelPhysics.lua's getTireLoad, dataS/scripts/vehicles/wheels/
    -- WheelAxle.lua's real axle-load-balancing use of it) - combines the
    -- real getWheelShapeContactForce native with the wheel's own mass.
    -- NOT what drives the built-in tire-track visual rut depth though -
    -- that turned out to read a static terrain attribute instead, a
    -- separate, unrelated value. This is still a real, useful reading on
    -- its own, just don't assume it's "what makes ruts deeper".
    local wheelMass = nil
    local wheelTireLoad = nil
    if wheelIndex ~= nil then
        local wheel = wheels[wheelIndex]

        if wheel ~= nil then
            if wheel.getMass ~= nil then
                wheelMass = WailaUtil.safeCall(nil, wheel.getMass, wheel)
            end

            if wheel.physics ~= nil and wheel.physics.getTireLoad ~= nil then
                wheelTireLoad = WailaUtil.safeCall(nil, wheel.physics.getTireLoad, wheel.physics)
            end
        end
    end

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
        wheelMass = wheelMass,
        wheelTireLoad = wheelTireLoad,

        attacherJointCount = #attacherJoints,
        attacherJointIndex = attacherJointIndex,
        attacherJointNodeId = attacherJointNodeId,
        attacherJointNodeName = attacherJointNodeName,
        attacherJointType = attacherJointType,
        attacherJointTypeName = attacherJointTypeName,

        hasMotor = hasMotor,
        turnedOn = turnedOn,
        hasAttachable = hasAttachable,
        lowered = lowered,
        hasFoldable = hasFoldable,
        unfolded = unfolded,
        hasSowingMachine = hasSowingMachine,
        isWorking = isWorking,
        hasPushHandTool = hasPushHandTool,
        workAreaTypes = workAreaTypes
    }
end
