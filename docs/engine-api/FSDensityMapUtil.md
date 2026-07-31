# FSDensityMapUtil

**Status:** confirmed via our own testing

Base-game utility namespace (not something we wrote) for higher-level
density-map operations layered on top of the raw foliage/field systems.

## clearDecoArea - reliable

```lua
FSDensityMapUtil.clearDecoArea(x0, z0, x1, z1, x2, z2)
```

Takes a parallelogram (same 3-corner convention as `applyDecoFoliage`).
Confirmed reliable all session - this is what both the tyre-clear mechanic and
the "annoying bush" displacement test used.

## updateSowingArea - field-only, check the return values

```lua
local changedArea, totalArea = FSDensityMapUtil.updateSowingArea(...)
```

**Only ever succeeds where the ground is already a registered field.**
`changedArea` is `0` off-field, every single time, confirmed by direct logging
all night - never assume success from the call not erroring, always check
`changedArea > 0`. Two real bugs in our own code came from not doing this:

- `sowFruit` originally returned `true` unconditionally regardless of `changedArea`
- `plantRandomFruit` one level up discarded `sowFruit`'s real return value and
  logged success anyway

Both fixed by threading the real `changedArea`/`totalArea` values all the way
up. This is also what proved meadow-sowing was a dead end for a mod whose
entire domain is deliberately off-field ground (see `isOnField` below) - not a
bug, just the wrong tool for off-field vegetation.

## getFieldDataAtWorldPosition - the field check

```lua
local isOnField, _, _ = FSDensityMapUtil.getFieldDataAtWorldPosition(x, 0, z)
```

The one true "is this a registered field" check. Used everywhere IW touches
ground, not just at placement time - a real farmed field reads identically to
anything IW planted once it's grown in, so this has to gate every write
action, not just initial seeding.

## References

- `ImmersiveWeathering.lua` (`sowFruit`, `plantRandomFruit`, `isOnField`, `fieldIsMaterial`)
