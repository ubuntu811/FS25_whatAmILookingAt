# Foliage deco density maps

**Status:** confirmed via our own extensive testing (WAILA Shift+K dump +
ImmersiveWeathering read/write cycles, one full session)

The system behind "deco" vegetation - grass tufts, bushes, forest undergrowth,
etc. Completely separate from terrain texture (see
[TerrainDeformation.md](TerrainDeformation.md)) and from trees (see
[TreePlantManager.md](TreePlantManager.md)). It's a bit-packed density map:
each (x,z) pixel on a given plane stores a type-index + growth-value, per
plane.

## Reading

`g_currentMission.foliageSystem` exposes the map's I3D-declared foliage
multilayers. Each layer has a `densityMapId`, a `terrainDataPlaneId`, and a
list of foliage types (name + typeIndex + kind). WAILA's Shift+K
(`WAILA_DUMP_FOLIAGE_CATALOG`) dumps this directly.

Low-level bit decode: `getDensityAtWorldPos` + `bitAND`/`bitShiftRight` to pull
the type-index and growth value back out of the packed value.

## Writing

```lua
foliageSystem:applyDecoFoliage(decoName, x0, z0, x1, z1, x2, z2, growthState)
```

Parallelogram only - there is no round-brush variant at this API level; the
`BrushType` enum some editor code references belongs to the GIANTS Editor /
construction-brush UI, not this call. Guard every write with
`foliageSystem:getIsDecoLayerDefined(decoName)` first - passing an undefined
name doesn't error, it just silently does nothing.

## THE gotcha: write name != read name

What you write with (`applyDecoFoliage`'s `decoName` argument) and what you
read back (the type name in a multilayer's type list) can be **completely
different strings for the same physical layer**. Concretely, on the map we
tested against:

- write `"grassShort"` -> reads back as `"decoFoliage"` at growth state 9

Root cause, found in that map's own `maps/map.xml`:

```xml
<mapping name="grassShort" layerName="decoFoliage" state="9" />
```

This is a per-map declaration, not an engine-wide constant - but a second map
with no such `<mapping>` entry behaved identically anyway (grassShort ->
decoFoliage@9 seeding worked the same way), so treat it as a likely
engine-level default that individual maps can also declare explicitly, not
something to assume is universal without checking a given map's own `map.xml`.

## `foliageSystem.decoFoliages` / `.paintableFoliages` are NOT the full writable list

`getIsDecoLayerDefined("grassShort")` returns true, and writes with it work -
but `"grassShort"` appears in **neither** `foliageSystem.decoFoliages` nor
`.paintableFoliages`. Those two lists are real (dumped via WAILA Shift+K) but
incomplete relative to what's actually writable. Don't use them as a
instead-of `getIsDecoLayerDefined` gate.

## One value per (x,z) per PLANE - "last write wins"

Multiple foliage type names can be co-resident on the *same* physical plane
(sharing one packed value per pixel) - writing a different type at the same
coordinate overwrites, it doesn't stack. Confirmed directly: a persistent,
plow-immune map decoration ("the annoying bush", genuinely deco foliage, not a
collidable static mesh) was fully displaced by stamping `grassShort` directly
over it via `placeFoliage`, and the resulting spot was then plowable like any
other grass patch - proving overwrite-in-place, not two independent layers
competing. Genuinely separate planes (different `densityMapId`) are
independent and do coexist; it's specifically same-plane types that clobber
each other.

## Custom deco names are flaky

Names confirmed present in `decoFoliages` (e.g. `"decoBush"`) intermittently
fail writes across sessions/attempts for reasons never pinned down (no C++
source to inspect). `grassShort` was the only name reliable with zero
exceptions all session. Treat any name other than `grassShort` as "try it,
verify the write actually took via `getFoliageNameAt`, don't trust it
blindly."

## Real usage

```lua
function ImmersiveWeathering:placeFoliage(x, z, decoName)
    local foliageSystem = g_currentMission.foliageSystem
    if not foliageSystem:getIsDecoLayerDefined(decoName) then
        return false
    end
    -- ... compute a randomized-rotation parallelogram ...
    foliageSystem:applyDecoFoliage(decoName, x0, z0, x1, z1, x2, z2, growthState)
end
```

## References

- `ImmersiveWeathering.lua` (`placeFoliage`, `getFoliageNameAt`)
- `WailaFoliageInspector.lua`, `WailaDebugDump.lua` (`dumpFoliageCatalog`)
