# Foliage deco density maps

**Status:** confirmed via our own extensive testing (WAILA Shift+K dump +
ImmersiveWeathering read/write cycles, one full session)

The system behind "deco" vegetation - grass tufts, bushes, forest undergrowth,
etc. Completely separate from terrain texture (see
[TerrainDeformation.md](TerrainDeformation.md)) and from trees (see
[TreePlantManager.md](TreePlantManager.md)). It's a bit-packed density map:
each (x,z) pixel on a given plane stores a type-index + growth-value, per
plane.

**[check_foliage_sync.py](check_foliage_sync.py)** automates the two checks
below (missing `<decoFoliage>` backing, `numChannels` mismatches) against
any map's real `map.xml`/I3D instead of doing it by hand:
```
python3 check_foliage_sync.py /path/to/MapMod/maps/map.xml --game-install "/path/to/Farming Simulator 25"
```

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

## THE gotcha: write name != read name, and it's `<mapping>`, not the layer itself

What you write with (`applyDecoFoliage`'s `decoName` argument) and what you
read back (the type name in a multilayer's type list) can be **completely
different strings for the same physical layer**. Concretely, on the map we
tested against:

- write `"grassShort"` -> reads back as `"decoFoliage"` at growth state 9

Root cause, found in that map's own `maps/map.xml`:

```xml
<mapping name="grassShort" layerName="decoFoliage" state="9" />
```

**Confirmed (live A/B log test, `FS25_Estancia_Lapacho_orange`):**
`applyDecoFoliage`/`getIsDecoLayerDefined` only ever accept a name that has an
explicit `<mapping name="..." layerName="..." state="...">` entry in the
current map's `map.xml`. A raw, genuinely-declared
`<decoFoliage layerName="...">` name is **not** usable on its own - it must
also get a `<mapping>` alias before `getIsDecoLayerDefined` will return `true`
for it. Test: 9 previously-assumed-valid raw layer names (`decoFoliage`,
`decoBush`, `forestGrass`, etc.) all returned `false`; 4 newly-added custom
`<mapping>` entries (`iwTest1/2/3/5`, pointing at otherwise-unnamed states on
the same `decoFoliage` layer) all returned `true`. This retroactively explains
the "Custom deco names are flaky" behavior below - it was never flakiness, it
was simply "was this name ever given a `<mapping>` by this particular map."

`<mapping>` is declared in the same `<decoFoliages>` block as the
`<decoFoliage>` layer entries (see `mission00.xsd`,
`shared/xml/schema/mission00.xsd` in the game install - `<mapping>` is a
sibling element to `<decoFoliage>`, both `minOccurs="0" maxOccurs="unbounded"`
under `<decoFoliages>`). It is per-map, opt-in, and not guaranteed to exist for
any name beyond whatever the base game/map author actually declared -
`grassShort` -> `decoFoliage@9` shows up repeatedly because it's apparently a
convention base-game tools (mowers etc.) rely on, not because the engine
defines it implicitly.

**Rule**: `getIsDecoLayerDefined`/`applyDecoFoliage` require the target
`layerName` to have its own `<decoFoliage>` entry under `<decoFoliages>`.
A `<mapping>` alias is necessary but not sufficient - having real I3D
backing (a genuine `FoliageType`) or a `<paintableFoliage>` declaration is
also not sufficient on its own. Without a matching `<decoFoliage
layerName="X">`, every write silently fails: `getIsDecoLayerDefined`
returns `false`, `placeFoliage` bails before ever calling
`applyDecoFoliage`, nothing gets written, no error.

**How to prove it, on any layer**:
1. Confirm the layer has real I3D backing: WAILA `Shift+K`
   (`listAvailableFoliage`, dumps `FOLIAGE CATALOG` to the log) should show
   it with a `foliageXmlId` under some multilayer.
2. Add a `<mapping name="X_test" layerName="X" state="N" />` under
   `<decoFoliages>` **without** a `<decoFoliage layerName="X">` entry ->
   `getIsDecoLayerDefined("X_test")` returns `false`.
3. Add `<decoFoliage layerName="X" startChannel="0" numChannels="4"
   mowable="true"/>` (no I3D change needed if step 1 already found real
   backing) -> the same mapping now returns `true` and writes visible
   content.

**Worked example (`meadow` on `FS25_Estancia_Lapacho_orange`)**: declared
under `<paintableFoliages>` only, `<mapping name="meadowL4"
layerName="meadow" state="4" />` returned `false` for all of
`meadowL1`-`meadowL4`. `Shift+K` confirmed real backing (typeIndex 2,
`foliageXmlId="304"`, same multilayer as `decoFoliage`). Adding
`<decoFoliage layerName="meadow" startChannel="0" numChannels="4"
mowable="true"/>` alone - no I3D edit - made `meadow_s3`/`s4`/`s5` (paired
`<mapping>` entries) write and read back correctly via WAILA
(`meadow(4)[paintable]`, real area-scan percentages).

**Resources used**:
- `shared/xml/schema/mission00.xsd` (game install) - real map.xml schema;
  `<decoFoliage>`, `<mapping>`, `<paintableFoliage>` are siblings under
  different parent blocks, not interchangeable.
- `sdk/debugger/scriptBinding.xml` (game install) - `Foliage`-category
  native functions.
- `WailaFoliageInspector.lua` (`listAvailableFoliage`, bound to `Shift+K`)
  - real per-multilayer type catalog straight from the map's I3D,
  independent of what map.xml declares.

Real, physical `meadow(4)` foliage confirmed to exist and read back
correctly (`WailaFoliageInspector`, tagged `[paintable]` by
`getKindByLayerName` as expected) - but placed by the base game's own
construction/landscaping "PLANTS" menu, an entirely separate placement path
from `applyDecoFoliage`. Don't take "I found the foliage I expected nearby"
as confirmation of a specific write without checking the actual `[TestRig]`
log coordinates/results first - this is exactly the mistake made here.

## `<decoFoliage numChannels>` really does cap writable states - it clamps, doesn't reject

**Rule**: writing a state outside a layer's declared `numChannels` range
(e.g. state 2 on a `numChannels="1"` layer, valid range 0-1) does not fail
and does not honor the literal requested value - it silently **clamps to
the layer's max declared state**. `getIsDecoLayerDefined`/`applyDecoFoliage`
still return `true` either way, so write success alone can't tell the two
cases apart - only reading back the actual physical value can.

**How to prove it**:
1. Write to a state outside the declared range (e.g. `<mapping
   name="X_s2" layerName="X" state="2" />` where `X` has
   `numChannels="1"`) - `getIsDecoLayerDefined`/`applyDecoFoliage` report
   success.
2. Read back the exact written coordinates via WAILA - reports the layer's
   max valid state (1), not the requested one (2). A whole test row of
   "different" out-of-range states will all visually be the same species,
   since they've all clamped to the same one value.
3. Bump the layer's declared `numChannels` in `map.xml` (e.g. 1 -> 4) and
   write a **fresh** point (previously-written density bits don't
   retroactively change) - now the actual requested state gets honored and
   real, distinct content appears.

**Worked example (`forestGrass` on `FS25_Estancia_Lapacho_orange`)**: with
`numChannels="1"`, `forestGrass_s2` wrote successfully but read back as
`forestGrass(1)`, and the whole 0-15 test row looked like one species
repeated. Bumping to `numChannels="4"` and re-placing produced genuinely
distinct species across the row (including a dense fern/conifer-like bush
previously assumed to be outside the density-map system entirely - it was
just sitting at a state nothing was configured to reach).

**Resources used**: `WailaFoliageInspector`'s raw bit-decode
(`inspectPoint`/`decodeFoliageAt`) - reads the true physical density value
independent of whatever name was used to write it, which is what makes the
clamp detectable at all; write-success alone (`getIsDecoLayerDefined`)
cannot distinguish "wrote what was asked" from "silently clamped."

## `foliageSystem.decoFoliages` / `.paintableFoliages` are NOT the full writable list

`getIsDecoLayerDefined("grassShort")` returns true, and writes with it work -
but `"grassShort"` appears in **neither** `foliageSystem.decoFoliages` nor
`.paintableFoliages`. Those two lists are real (dumped via WAILA Shift+K) but
incomplete relative to what's actually writable - `<mapping>` names in
particular don't appear in either list even though they're the actual
writable/readable vocabulary. Don't use them as a instead-of
`getIsDecoLayerDefined` gate.

## Registering a brand-new foliage layer at runtime (map-independent)

Separate mechanism from everything above - `addFoliageTypeFromXML`
(`sdk/debugger/scriptBinding.xml`, category `Foliage`) creates a new
density-map-backed foliage layer from scratch at runtime:

```
addFoliageTypeFromXML(terrainNode, foliageDataPlaneId, name, xmlFilename) -> densityMapTypeId
```

This doesn't require the current map's `map.xml` to declare anything - it's
likely the actual primitive behind mods like `FS25_allTheFoliage` that add
their own decorative plant variety to any map. Important: this only reaches
the decorative foliage system, same tier as `decoBush`. It has no connection
to the fruit-type/growth system - a layer registered this way won't grow over
time, respond to weather, or count as mowable yield, even if built from a
real crop's visual asset. **Not yet used by us** - documented here because it
directly answers "can a mod add foliage variety without needing per-map
author cooperation," which the `<mapping>`-gating finding above raised.

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
