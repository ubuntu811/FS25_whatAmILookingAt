WailaAnimalInspector = {}
local WailaAnimalInspector_mt = Class(WailaAnimalInspector)

function WailaAnimalInspector.new()
    return setmetatable({}, WailaAnimalInspector_mt)
end

-- A pasture animal is an engine object: its collision node ("proxy", group ANIMAL) resolves to (husbandryId, animalId) through getAnimalFromCollisionNode, the same call the game's own
-- animal panel (PlayerHUDUpdater) makes, and the husbandry's Lua side maps animalId to the cluster. Only a node in the ANIMAL collision group is asked (one flag test per inspection).
-- Returns nil for anything else, else a flat table: what the cluster is and which engine model (visual index) the game picked for it.
function WailaAnimalInspector:inspect(hit)
    if hit == nil or hit.nodeId == nil or getAnimalFromCollisionNode == nil or CollisionFlag == nil or CollisionFlag.ANIMAL == nil then
        return nil
    end

    local group = WailaUtil.safeGlobalCall("getCollisionFilterGroup", nil, hit.nodeId)
    if group == nil or bit32.band(group, CollisionFlag.ANIMAL) == 0 then
        return nil
    end

    local ok, husbandryId, animalId = pcall(getAnimalFromCollisionNode, hit.nodeId)
    if not ok or husbandryId == nil or husbandryId == 0 then
        return nil
    end

    local mission = g_currentMission
    local clusterHusbandry = mission ~= nil and mission.husbandrySystem ~= nil and mission.husbandrySystem:getClusterHusbandryById(husbandryId) or nil
    local cluster = clusterHusbandry ~= nil and clusterHusbandry:getClusterByAnimalId(animalId) or nil

    local info = { husbandryId = husbandryId, animalId = animalId }
    if clusterHusbandry == nil or cluster == nil then
        return info
    end

    local placeable = clusterHusbandry:getPlaceable()
    info.placeable = placeable ~= nil and placeable.getName ~= nil and WailaUtil.safeCall(nil, placeable.getName, placeable) or nil
    info.animalType = clusterHusbandry.animalTypeName
    info.clusterId = cluster.id
    info.name = cluster.name
    info.age = cluster.age
    info.health = cluster.health
    info.numAnimals = cluster.numAnimals
    info.subTypeIndex = cluster.subTypeIndex

    local animalSystem = mission.animalSystem
    local subType = animalSystem ~= nil and animalSystem:getSubTypeByIndex(cluster.subTypeIndex) or nil
    info.subTypeName = subType ~= nil and subType.name or nil

    -- the model the game chose for this age: index into the type's <animal> list (1-based; the engine is given index - 1), the age it starts at, the file
    local visual = WailaUtil.safeCall(nil, cluster.getVisual, cluster)
    if visual ~= nil then
        info.visualIndex = visual.visualAnimalIndex
        info.visualMinAge = visual.minAge
        info.visualFile = visual.visualAnimal ~= nil and visual.visualAnimal.filename or nil
    end

    return info
end
