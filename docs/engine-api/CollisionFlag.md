# CollisionFlag

**Status:** confirmed via the engine's own `gsCollisionFlagShowAll` console
command (authoritative, full enumeration) - supersedes the earlier
source-cross-checked partial list below.

Bitmask enum passed as the last argument to `raycastClosest`/`raycastAll` and
similar, to filter which node types a raycast can hit. Also readable off any
existing node via `getCollisionFilterGroup(nodeId)` (what it IS) and
`getCollisionFilterMask(nodeId)` (what it collides WITH) - both real, native,
confirmed present in `scriptBinding.xml`, and now surfaced live in WAILA's own
panel (see `WailaHud.lua`, the `Collision: group=.. mask=.. (names)` line).

## Full member list

Run `gsCollisionFlagShowAll` in the in-game console for the live, current
list (bit numbers can matter for manual mask math, e.g. reading a raw
`group`/`mask` integer off a node):

```
Bit 00: DEFAULT                   - The default bit
Bit 01: STATIC_OBJECT             - Static object (NOT "STATIC_WORLD" - see gotcha below)
Bit 02: CAMERA_BLOCKING           - Blocks the player camera from being inside
Bit 03: GROUND_TIP_BLOCKING       - Blocks tipping on the ground beneath/above
Bit 04: PLACEMENT_BLOCKING        - Blocks placing objects via construction
Bit 05: AI_BLOCKING               - Blocks vehicle navigation map beneath/above
Bit 06: PRECIPITATION_BLOCKING    - Masks all precipitation inside and below the collision
Bit 08: TERRAIN                   - Terrain without tip any or displacement
Bit 09: TERRAIN_DELTA             - Tip anything
Bit 10: TERRAIN_DISPLACEMENT      - Terrain displacement (tiretrack deformation)
Bit 11: TREE                      - A tree
Bit 12: BUILDING                  - A building
Bit 13: ROAD                      - A road
Bit 14: AI_DRIVABLE               - Blocks vehicle navigation map at the vertical faces of the mesh if they are above the terrain
Bit 16: VEHICLE                   - A vehicle
Bit 17: VEHICLE_FORK              - A vehicle fork tip for pallets or bales
Bit 18: DYNAMIC_OBJECT            - A dynamic object
Bit 19: TRAFFIC_VEHICLE           - A AI traffic vehicle
Bit 20: PLAYER                    - A player
Bit 21: ANIMAL                    - An Animal
Bit 22: ANIMAL_POSITIONING        - For animal to walk on (position is raycast from above)
Bit 23: ANIMAL_NAV_MESH_BLOCKING  - Area of the collision is excluded from generated nav meshes
Bit 24: TRAFFIC_VEHICLE_BLOCKING  - Blocks AI traffic vehicles
Bit 28: INTERACTABLE_TARGET       - An interactable trigger that the player can target
Bit 29: TRIGGER                   - A trigger
Bit 30: FILLABLE                  - A fillable node. For trailer fillNodes and unload triggers
Bit 31: WATER                     - A water plane
```

Note bits 07, 15, 25-27 are unused/reserved - not a transcription gap.

### Gotcha: ROAD alone doesn't mean "AI can drive here"

`ROAD` is descriptive, not functional - it doesn't by itself control AI
navigation. The actual navmesh-affecting flags are `AI_BLOCKING` (this
collision blocks AI navigation entirely - the opposite of what a road would
want) and `AI_DRIVABLE` (governs vertical-face blocking above terrain, a much
narrower case than "is this a road"). A real road mesh could carry `ROAD`
without `AI_BLOCKING`/`AI_DRIVABLE` saying anything about drivability, or vice
versa - don't assume one implies the other without checking a specific node's
actual `group` via `getCollisionFilterGroup`.

Confirmed live, not theoretical: on one map a paved road's surface raycast hit
was `name=terrain` with `Ground: STONE` - no separate collision object at all,
meaning the visual road there is a texture painted on/over terrain, not a
discrete `ROAD`-flagged mesh. On another map the same kind of road hit a real
named static node. Whether a given road segment is a discrete collision
object - and if so, which flags it actually carries - varies per map and even
per road segment on the same map. There is no general "is this a road" query
in the engine (`scriptBinding.xml` has zero hits for "road"); `ROAD` only
exists as this collision flag, set (or not) at the map author's discretion.

## Gotcha: STATIC_OBJECT, not STATIC_WORLD

`WailaRaycaster.lua` originally listed `"STATIC_WORLD"` in its
`getCollisionMask()` name table. That member doesn't exist, so
`CollisionFlag["STATIC_WORLD"]` silently resolved to `nil`, silently dropping
that bit from the mask, silently causing raycasts to pass straight through
static level geometry - no error anywhere, just wrong-looking hits. Fixed by
cross-referencing real base-game source instead of guessing from memory of
older FS versions.

## Real usage

Raycast mask (filter which node types a ray can hit):

```lua
raycastClosest(x, y, z, dirX, dirY, dirZ, 200, "callback", self, CollisionFlag.TERRAIN)
```

Reading the flags an already-hit node actually carries:

```lua
local group = getCollisionFilterGroup(hit.nodeId)  -- what this node IS
local mask = getCollisionFilterMask(hit.nodeId)    -- what it collides WITH
local isRoad = bit32.band(group, CollisionFlag.ROAD) ~= 0
```

## References

- `WailaRaycaster.lua` (`getCollisionMask()`)
- `WailaHud.lua` (`Collision: group=.. mask=.. (names)` panel line -
  `getCollisionFilterGroup`/`getCollisionFilterMask` usage)
- `WailaTrailTracer.lua` (`isSpotClearOfStructures` - raycast-based road/
  structure exclusion for automated trail detection)
- base-game `dataS/scripts/.../PlayerTargeter.lua`
- in-game console command `gsCollisionFlagShowAll`
