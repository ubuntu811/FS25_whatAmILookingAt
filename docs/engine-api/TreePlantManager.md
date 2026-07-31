# TreePlantManager

**Status:** confirmed via source only - not yet called by any of our own code

Base-game global `g_treePlantManager`. The real system behind tree placement -
a third system, distinct from both foliage deco density maps and terrain
texture paint. Trees are actual scene objects (split-shapes), not density-map
bits or blended textures.

## Real usage (from vanilla `TreePlanter` vehicle spec)

```lua
if g_treePlantManager:canPlantTree() then
    local treeTypeIndex = spec.currentTreeTypeIndex
    g_treePlantManager:plantTree(treeTypeIndex, x, y, z, 0, yRot, 0, 1, variationIndex)
end
```

Full signature (from the manager's own definition):

```lua
TreePlantManager:plantTree(
    treeTypeIndex, x, y, z, rx, ry, rz,
    growthStateI, variationIndex, isGrowing,
    nextGrowthTargetHour, existingSplitShapeFileId
)
```

## Looking up a tree type by name

```lua
local treeTypeIndex, variationIndex =
    g_treePlantManager:getTreeTypeIndexAndVariationFromName(treeTypeName, 1, variationName)
```

## References

- base-game `dataS/scripts/misc/TreePlantManager.lua`
- base-game `dataS/scripts/vehicles/specializations/TreePlanter.lua`
