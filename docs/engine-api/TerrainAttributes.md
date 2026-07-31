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

## References

- `ImmersiveWeathering.lua` (`fieldIsMaterial`)
