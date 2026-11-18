# FS25_whatAmILookingAt

Developer HUD / world inspector for Farming Simulator 25. Point at
anything - terrain, foliage, a vehicle, a tree, a physics object - and
see what the engine actually thinks it is.

Gradually becoming a base library other mods can depend on, not just a
standalone dev HUD. FS25 represents "what is this field" about 25
different, mutually inconsistent ways (a registered `Field` object, a
`Farmland` ownership polygon, raw density-map ground truth, a
`FieldState` reader that doesn't need either of the first two, tillage
that creates real farmable ground with no `Field` behind it at all, a
rice-paddy placeable that can span multiple unrelated `Field`s as one
visual/functional unit, ...) - this mod already had to work all of that
out just to answer "what am I looking at" honestly. Rather than every
consuming mod re-deriving that same knowledge independently
(`SmartMinimapAuto` did, before this), WAILA exposes it once, cleanly:
typed classes (`WailaField`, ...) with a stable `dumpHudJson`/
`dumpLogJson` contract, a background world index (`WailaFieldIndex`)
queryable via `Waila.get(type, x, z)` / `Waila.getAll(type)`, and
`g_messageCenter` events (`WailaFieldIndex.VEHICLE_LEFT_FIELD`) other
mods can subscribe to instead of running their own duplicate scan.

Pairs with [FS25_ImmersiveWeathering](https://github.com/ubuntu811/FS25_ImmersiveWeathering)
(soft dependency, not required - see below).

## Controls

All defaults below - Shift+letter combos can be rebound like any other
action via the in-game controls menu; the HUD always shows your actual
current binding, not the default.

| Key | Action |
|---|---|
| `Left Shift + M` | Toggle the full inspector HUD |
| `Left Shift + J` | Dump the currently inspected target to `log.txt` (only while HUD is enabled) |
| `Left Shift + K` | Dump the map's full foliage catalog to `log.txt` |
| `Left Shift + L` | Debug tools menu (terrain layer dump, density probes - not needed for normal play) |

A small always-on mini panel (vehicle name / foliage / terrain material
at a glance, plus FPS and scan time) is visible whether or not the full
HUD is toggled on - the full HUD slides open underneath it.

## Current inspection

- raycast target and node ID/name
- the hit node's real collision group/mask, decoded to flag names (`ROAD`, `BUILDING`, `AI_BLOCKING`, ...)
- terrain material, field state and ground type
- foliage layers at the target
- grouped terrain and foliage statistics for a 5×5 m area
- vehicle/placeable node object where available
- per-wheel mass and real ground contact force (tire load), where exposed by the engine
- tree/log/split-shape classification
- rigid-body type, split state, volume, mass and sleeping state where exposed by the engine
- current weather (rain scale, time since last rain, temperature, derived isRaining) - full HUD only

The always-on mini panel only runs a lightweight point raycast; the
heavier 10×10m area scan only runs while the full HUD is toggled on.

Plow a field over a path (or let a field grow or vanish) and the layers under it rescan by themselves: when a vehicle or you leave a field and its outline came out more than 3% different, the chunks under the old and new outline are queued as an area scan (one at a time, in the same per-frame budget, and only on a map that was scanned or restored once).

## Install

Drop `FS25_whatAmILookingAt` into your FS25 mods folder like any other
mod. Works standalone; ImmersiveWeathering is optional but recommended
if you want something to point the inspector at.

## The debug hub's layout

Topics on the left, the rows of the topic in the middle, the buttons of the selected row in a column of their own (14 slots of 44 px; its labels start 65 px right of the list, the same margin the list text has on its left). A tab marks related buttons with `button.group` (any value); where the group changes the hub leaves one empty slot, so a row of ten buttons reads as three or four blocks (IW's Textures and Foliage sets tabs do; a button without a group, like every older tab's, stays where it was). A button with a `layerId` shows that layer's picture inside its left padding. The picture of a row (a texture set's 8 x 8 preview, or one layer) sits bottom right in a light frame, its left edge on the button labels and above the footer bar. A tab can also give `getItemImage(item)` -> a picture file (a `$data/...` path is fine): that picture takes the place of the terrain picture when the row has none (IW's Foliage sets tab shows the game's store icon of a plant, on a black tile instead of the light frame).

## Map scan

WAILA can scan any map without knowing it in advance and draw water, forest, single
trees, trails, roads and buildings on the in-game map (via TaskMap), plus an index of
every field. Layers are saved as images, so a reload shows them in well under a second.
How it works, what it reads, how it is saved, the numbers and the gotchas:
[docs/MAP_SCAN.md](docs/MAP_SCAN.md).

## Engine API notes

[docs/engine-api/](docs/engine-api/README.md) - reverse-engineered reference
notes on FS25 natives that are missing or underdocumented in `scriptBinding.xml`
(foliage density maps, terrain paint, tree planting, collision flags, etc.),
built up while developing this mod and
[FS25_ImmersiveWeathering](https://github.com/ubuntu811/FS25_ImmersiveWeathering).

Dev environment / build tooling setup (Windows+Steam+WSL+Claude Code, the
`build.sh`/`deploy.sh` pattern, real gotchas hit along the way): see
[docs/AI_DEV_GUIDE.md](docs/AI_DEV_GUIDE.md).

## Credits

`docs/engine-api/` exists because these mods' authors published real,
working source that answered questions `scriptBinding.xml` alone
couldn't - specific real usage, not just general inspiration:

- **TerraFarm** - the terrain paint/deformation API (`TerrainDeformation.md`),
  the vehicle action-event registration pattern (`VehicleActionEvents.md`),
  and the map-directory resolution pattern (`baseDirectory` +
  `Utils.getDirectory`) both mods' `iw.xml`/config loaders use.
- **FS25_LumberJack** - confirmed `DensityMapModifier` construction/usage
  (`DensityMapModifier.md`).
- **FS25_PowerTools** - the `OptionDialog`-based debug menu pattern both
  mods' `Shift+L`/`Shift+Ctrl+M` debug tools menus are built on.
- **FS25_allTheFoliage** - map-directory resolution (alongside TerraFarm),
  and a real-world example pointing at `addFoliageTypeFromXML` as the
  likely primitive behind runtime foliage-type registration.

## License

GPLv3 - see [LICENSE](LICENSE).
