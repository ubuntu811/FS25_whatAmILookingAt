# TerrainDeformation

**Status:** confirmed via source (TerraFarm, base-game `PlaceableLeveling.lua`)
AND confirmed via our own testing (dirt-paint test rig, screenshot-verified
in-game, both as a standalone debug fill and firing live under tyre contact)

Native class for both terrain height changes and terrain texture (ground
material) painting. Completely undocumented in `scriptBinding.xml` - not a
single member appears there. Found entirely by reading TerraFarm's
`LandscapingOutput.lua` (a full player-facing implement built on this class)
and cross-checked against real base-game usage in `PlaceableLeveling.lua`,
`PlaceableRiceField.lua`, `PlaceableFence.lua` - all three under
`dataS/scripts/placeables/specializations/`, none under
`vehicles/specializations/`, meaning vanilla FS25 doesn't actually ship its
own vehicle-based dozer/land-plane tool; TerraFarm built the only one, on top
of this native.

## Lifecycle

```lua
local paint = TerrainDeformation.new(g_terrainNode)
paint:enablePaintingMode()               -- omit for a height-change deformation instead
paint:addSoftCircleBrush(x, z, radius, hardness, strength, terrainLayerId)
-- or :addSoftSquareBrush(x, z, sideLength, hardness, strength, terrainLayerId)
paint:apply(false, "callbackMethodName", callbackTarget)
-- callbackTarget:callbackMethodName(code, volume) fires async;
-- TerrainDeformation.STATE_SUCCESS on success
-- always paint:delete() (or :cancel() on failure) inside the callback
```

**Gotcha - don't reuse `self` as the callback target for concurrent calls.**
`apply` is async; if two calls are in flight at once (e.g. two wheels touching
ground the same tick) and both use the same shared object as the callback
target, the second `paint:delete()` clobbers/races the first. Give each call
its own disposable table instead:

```lua
local callbackTarget = { deformation = paint }
function callbackTarget:onWitherApplied(code, volume)
    self.deformation:delete()
end
paint:apply(false, "onWitherApplied", callbackTarget)
```

## Terrain layer IDs are per-map, resolved by name

```lua
local numLayers = getTerrainNumOfLayers(g_terrainNode)   -- also missing from scriptBinding.xml
for i = 0, numLayers - 1 do
    local name = getTerrainLayerName(g_terrainNode, i)   -- also missing
    if name:upper() == "DIRT" then ... end
end
```

`"DIRT"`/`"GRAVEL"` are the two names TerraFarm itself falls back to as
defaults (`LandscapingManager.DEFAULT_TERRAIN_LAYERS`), implying they're
common-enough conventions across maps to look up by name - not guaranteed on
every map, look it up, don't assume a fixed index.

## Real usage (confirmed working end-to-end - both debug fill and live tyre contact)

```lua
function ImmersiveWeathering:witherToDirt(x, z)
    local layerId = self:getDirtTerrainLayerId()
    if layerId == nil then return false end

    local paint = TerrainDeformation.new(g_terrainNode)
    paint:enablePaintingMode()
    paint:addSoftCircleBrush(x, z, 0.4, 0.3, 0.6, layerId)

    local callbackTarget = { deformation = paint }
    function callbackTarget:onWitherApplied(code, volume)
        self.deformation:delete()
    end
    paint:apply(false, "onWitherApplied", callbackTarget)
    return true
end
```

## References

- `ImmersiveWeathering.lua` (`getDirtTerrainLayerId`, `witherToDirt`)
- `TerraFarm/scripts/landscaping/LandscapingOutput.lua`, `LandscapingManager.lua`
- base-game `dataS/scripts/placeables/specializations/PlaceableLeveling.lua`
