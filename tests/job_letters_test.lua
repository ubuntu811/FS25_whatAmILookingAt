dofile("tests/stubs.lua")

-- engine pieces the job definitions touch
FruitType = { UNKNOWN = 0, GRASS = 7 }
FieldGroundType = { GRASS = 1, GRASS_CUT = 2, SOWN = 3 }
g_fruitTypeManager = { getFruitTypeByIndex = function(_, index)
    if index == FruitType.GRASS then return { minHarvestingGrowthState = 3, maxHarvestingGrowthState = 4 } end
end }
g_currentMission = { missionInfo = { weedsEnabled = false } }
dofile("scripts/WailaJobDefinitions.lua")

-- only the harvest rule: the other jobs need a whole game state to evaluate
local harvest
for _, d in ipairs(WailaJobDefinitions.DEFINITIONS) do
    if d.type == "ready_to_harvest" then harvest = d end
end
WailaJobDefinitions.DEFINITIONS = { harvest }

local ripeGrassField = { groundType = FieldGroundType.GRASS, fruitTypeIndex = FruitType.GRASS, growthState = 3 }
local jobs = WailaJobDefinitions.evaluate(ripeGrassField, {})
check("a grass field with ripe grass on grass ground gets the harvest job", #jobs == 1 and jobs[1] == "ready_to_harvest")
check("...and its letter is H", WailaJobDefinitions.getLetter(jobs[1]) == "H")
check("cut-grass ground works the same", #WailaJobDefinitions.evaluate({ groundType = FieldGroundType.GRASS_CUT, fruitTypeIndex = FruitType.GRASS, growthState = 4 }, {}) == 1)
check("unripe grass: no letter", #WailaJobDefinitions.evaluate({ groundType = FieldGroundType.GRASS, fruitTypeIndex = FruitType.GRASS, growthState = 1 }, {}) == 0)
check("bare grass ground without a crop: no letter", #WailaJobDefinitions.evaluate({ groundType = FieldGroundType.GRASS, fruitTypeIndex = FruitType.UNKNOWN, growthState = 0 }, {}) == 0)
finish("job_letters_test")
