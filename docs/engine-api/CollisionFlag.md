# CollisionFlag

**Status:** confirmed via source + confirmed via our own testing (WAILA raycasts)

Bitmask enum passed as the last argument to `raycastClosest`/`raycastAll` and
similar, to filter which node types a raycast can hit.

## Real member names

Cross-checked against base-game `PlayerTargeter.lua`:

```
CollisionFlag.TERRAIN
CollisionFlag.TREE
CollisionFlag.VEHICLE
CollisionFlag.VEHICLE_FORK
CollisionFlag.STATIC_OBJECT   -- NOT "STATIC_WORLD" - see gotcha below
CollisionFlag.DYNAMIC_OBJECT
CollisionFlag.BUILDING
CollisionFlag.ROAD
CollisionFlag.ANIMAL
```

## Gotcha: STATIC_OBJECT, not STATIC_WORLD

`WailaRaycaster.lua` originally listed `"STATIC_WORLD"` in its
`getCollisionMask()` name table. That member doesn't exist, so
`CollisionFlag["STATIC_WORLD"]` silently resolved to `nil`, silently dropping
that bit from the mask, silently causing raycasts to pass straight through
static level geometry - no error anywhere, just wrong-looking hits. Fixed by
cross-referencing real base-game source instead of guessing from memory of
older FS versions.

## Real usage

```lua
raycastClosest(x, y, z, dirX, dirY, dirZ, 200, "callback", self, CollisionFlag.TERRAIN)
```

## References

- `WailaRaycaster.lua` (`getCollisionMask()`)
- base-game `dataS/scripts/.../PlayerTargeter.lua`
