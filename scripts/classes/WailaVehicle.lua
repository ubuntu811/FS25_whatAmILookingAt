--[[
    WailaVehicle.lua

    Typed result class for WailaVehicleInspector:inspect(). Unlike
    WailaField/WailaTerrain/WailaObject's constructors (which take raw
    values as separate parameters), this one takes a single already-built
    plain table and promotes it to an instance via setmetatable -- a
    positional parameter list here would run 30+ values deep, exactly the
    kind of thing that's easy to silently miscount or misorder. The
    inspector still does all the actual finding/derivation work
    (findComponent, findWheel, findAttacherJoint, ...); this class only
    gives that result a stable, named type with dumpHudJson/dumpLogJson,
    not a reshape.

    vehicle is the LIVE engine object reference, kept as a real instance
    field for existing internal consumers (WailaDebugDump reads
    inspection.vehicle.vehicle directly) -- deliberately left out of
    toTable()/dumpHudJson()/dumpLogJson(), same reasoning as WailaObject's
    object/rootVehicle.
]]

WailaVehicle = {}
local WailaVehicle_mt = Class(WailaVehicle)

function WailaVehicle.new(data)
    return setmetatable(data, WailaVehicle_mt)
end

function WailaVehicle:toTable()
    return {
        hitNodeId = self.hitNodeId,
        hitNodeName = self.hitNodeName,
        vehicleName = self.vehicleName,
        vehicleClass = self.vehicleClass,
        configFileName = self.configFileName,
        rootNodeId = self.rootNodeId,
        rootNodeName = self.rootNodeName,

        componentCount = self.componentCount,
        componentIndex = self.componentIndex,
        componentNodeId = self.componentNodeId,
        componentNodeName = self.componentNodeName,

        wheelCount = self.wheelCount,
        wheelIndex = self.wheelIndex,
        wheelNodeField = self.wheelNodeField,
        wheelNodeId = self.wheelNodeId,
        wheelNodeName = self.wheelNodeName,
        wheelMass = self.wheelMass,
        wheelTireLoad = self.wheelTireLoad,

        attacherJointCount = self.attacherJointCount,
        attacherJointIndex = self.attacherJointIndex,
        attacherJointNodeId = self.attacherJointNodeId,
        attacherJointNodeName = self.attacherJointNodeName,
        attacherJointType = self.attacherJointType,
        attacherJointTypeName = self.attacherJointTypeName,

        hasMotor = self.hasMotor,
        turnedOn = self.turnedOn,
        hasAttachable = self.hasAttachable,
        lowered = self.lowered,
        hasFoldable = self.hasFoldable,
        unfolded = self.unfolded,
        hasSowingMachine = self.hasSowingMachine,
        isWorking = self.isWorking,
        hasPushHandTool = self.hasPushHandTool,
        workAreaTypes = self.workAreaTypes,
    }
end

function WailaVehicle:dumpHudJson()
    return self:toTable()
end

function WailaVehicle:dumpLogJson()
    return self:toTable()
end
