# Terrain material / ground attributes

**Status:** confirmed via our own testing (read-only)

`getTerrainAttributesAtWorldPos` is the one terrain-material function actually
listed (barely) in `scriptBinding.xml`. It's read-only - there is no native
"set terrain material at this exact point" call. Ground texture painting is a
completely separate system, see [TerrainDeformation.md](TerrainDeformation.md).

## Signature (as called)

```lua
local waterY, blockedFlag, angle, blockedByShape, materialId =
    getTerrainAttributesAtWorldPos(g_terrainNode, x, 0, z, true, true, true, true, false)
```

Argument order/count found by matching real call sites, not independently
derived from any doc.

## Material IDs (confirmed at runtime - not guaranteed identical on every map)

```
DIRT   = 1
GRASS  = 2
SAND   = 3
GRAVEL = 6
STONE  = 7
```

Gaps (4, 5) exist and are unidentified - never hit them during testing.

## Real usage

```lua
function ImmersiveWeathering:fieldIsMaterial(x, z, materials)
    local _, _, _, _, material_id =
        getTerrainAttributesAtWorldPos(g_terrainNode, x, 0, z, true, true, true, true, false)
    local isOnField, _, _ = FSDensityMapUtil.getFieldDataAtWorldPosition(x, 0, z)
    return not isOnField and materials[material_id]
end
```

## `materialId` is the ONLY per-position ground-type read that exists - confirmed, not just untried

**Rule:** there is no way to read back which of a map's real paint layers
(`dirt01` vs `dirt02` vs `mud01`, etc.) is under a given position - only the
coarse ~5-value `materialId` bucket above. This was checked thoroughly, not
assumed absent.

**How to prove it:**
1. `scriptBinding.xml`'s `Terrain Detail`/`Precipitation` categories were
   searched exhaustively for a per-position layer-name read - nothing exists
   beyond `getTerrainAttributesAtWorldPos`'s own `materialId`.
2. Real TerraFarm source (a published mod with actual terrain-paint code)
   was extracted and searched - no per-position layer-name read anywhere,
   only the write-side layer enumeration (`getTerrainLayerName`/
   `getTerrainNumOfLayers`, see [TerrainDeformation.md](TerrainDeformation.md)).
3. Live confirmation: painted `mud01`/`mud02` (via
   `IWFoliagePalette:rollGroundMutation`, real distinct layers, visually
   obvious in-game) at a spot, then read it back with WAILA -
   `Ground: DIRT [1]`, indistinguishable from ordinary dirt. The engine's own
   bucket system doesn't separate them.

**Worked example (from FS25_ImmersiveWeathering's rain->mud feature):** the
mod paints mud fine (write side is genuinely per-layer, see
[TerrainDeformation.md](TerrainDeformation.md)), but can never later ask
"is this specific spot mud" - only "is it in the DIRT bucket" (which mud
also satisfies). Any feature wanting to act on "spots we previously painted
as X" has to track those positions itself; the engine will not hand them
back.

**Contrast with foliage, which HAS a real granular read:** the exact same
kind of question ("which specific species/layer is here") is fully
answerable for foliage via `foliageSystem.decoFoliages`/`.paintableFoliages`
entries, each carrying their own `terrainDataPlaneId` property - see
[FoliageDensityMap.md](FoliageDensityMap.md). Ground textures have no
equivalent object anywhere found. This isn't the same limitation showing up
twice, it's foliage having a capability terrain texture painting genuinely
lacks.

**Resources:**
- `sdk/debugger/scriptBinding.xml`, categories `Terrain Detail` and
  `Precipitation` - exhaustively checked, nothing beyond what's documented
  above and in `TerrainDeformation.md`.
- TerraFarm's real source (`FS25_0_TerraFarm_V1_6_3.zip`, locally available)
  - searched for any per-position layer read, found none.
- Live WAILA test: painted mud, read back `DIRT [1]`.

## References

- `ImmersiveWeathering.lua` (`fieldIsMaterial`)
