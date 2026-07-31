# DensityMapModifier / DensityMapFilter

**Status:** confirmed available at runtime (seen used by LumberJack, a real
published mod) - recipe for arbitrary-state foliage writes found in a GIANTS
Editor script, never actually run by us

Low-level native classes underneath the higher-level `applyDecoFoliage`/
`FSDensityMapUtil` calls documented elsewhere in this folder. Bypasses both
entirely - direct density-map plane read/write.

## Construction (as seen in LumberJack)

```lua
local modifier = DensityMapModifier.new(planeId, startChannel, numChannels, terrainRootNode)
modifier:setParallelogramWorldCoords(x0, z0, x1, z1, x2, z2, ...)
```

## Filtered write

Recipe from a GIANTS Editor script, `FSG-FS25-RandomFoliageByPaint-v1.lua` -
**NOT yet tested at runtime by us**:

```lua
modifier:setNewTypeIndexMode(DensityIndexCompareMode.ZERO)
local filter = DensityMapFilter.new(...)
filter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
modifier:executeSet(value, filter)
```

`getTerrainDataPlaneByName()` was seen used to obtain a `planeId` in that same
editor script - unconfirmed whether it's available outside the GIANTS Editor
environment (as opposed to in-game).

## Why this is worth chasing

`applyDecoFoliage` only takes a parallelogram and a single growth state per
call, and custom deco names (`decoBush` etc.) fail unpredictably through it
(see [FoliageDensityMap.md](FoliageDensityMap.md)). This lower-level path
might explain why - or might just be more of the same. Not proven either way.
Natural next thing to verify if `applyDecoFoliage` keeps being flaky for
anything other than `grassShort`.

## References

- `FS25_LumberJack` (real published mod, unpacked for inspection)
- `FSG-FS25-RandomFoliageByPaint-v1.lua` (GIANTS Editor script from the
  ge10-scripts-modding-tools bundle, unpacked in `my_mods/`)
