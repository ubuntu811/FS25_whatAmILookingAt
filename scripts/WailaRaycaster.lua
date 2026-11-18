WailaRaycaster = {}
local WailaRaycaster_mt = Class(WailaRaycaster)

function WailaRaycaster.new()
    local self = setmetatable({}, WailaRaycaster_mt)
    self.hit = nil
    self.maxDistance = 200
    return self
end

function WailaRaycaster:getCollisionMask()
    local mask = 0
    local names = {"DEFAULT", "TERRAIN", "TREE", "VEHICLE", "VEHICLE_FORK", "STATIC_OBJECT", "DYNAMIC_OBJECT", "BUILDING", "ROAD", "ANIMAL"}

    for _, name in ipairs(names) do
        if CollisionFlag ~= nil and CollisionFlag[name] ~= nil then
            mask = mask + CollisionFlag[name]
        end
    end

    if mask == 0 and CollisionFlag ~= nil and CollisionFlag.DEFAULT ~= nil then
        mask = CollisionFlag.DEFAULT
    end

    return mask
end

function WailaRaycaster:castFromCamera()
    self.hit = nil

    local camera = nil
    if g_localPlayer ~= nil and g_localPlayer.getCurrentCameraNode ~= nil then
        camera = g_localPlayer:getCurrentCameraNode()
    end
    if camera == nil and g_cameraManager ~= nil then
        camera = g_cameraManager:getActiveCamera()
    end
    if camera == nil then
        return nil
    end

    local x, y, z = getWorldTranslation(camera)
    local dx, dy, dz = localDirectionToWorld(camera, 0, 0, -1)

    raycastClosest(
        x, y, z,
        dx, dy, dz,
        self.maxDistance,
        "raycastCallback",
        self,
        self:getCollisionMask()
    )

    return self.hit
end

function WailaRaycaster:raycastCallback(hitObjectId, x, y, z, distance, nx, ny, nz, subShapeIndex, shapeId)
    if hitObjectId ~= nil and hitObjectId ~= 0 then
        self.hit = {
            nodeId = hitObjectId,
            shapeId = shapeId,
            subShapeIndex = subShapeIndex,
            x = x,
            y = y,
            z = z,
            distance = distance,
            normalX = nx,
            normalY = ny,
            normalZ = nz
        }
    end

    return false
end
