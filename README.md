# FS25_whatAmILookingAt

Developer HUD / world inspector for Farming Simulator 25. Point at
anything - terrain, foliage, a vehicle, a tree, a physics object - and
see what the engine actually thinks it is.

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
- terrain material, field state and ground type
- foliage layers at the target
- grouped terrain and foliage statistics for a 5×5 m area
- vehicle/placeable node object where available
- tree/log/split-shape classification
- rigid-body type, split state, volume, mass and sleeping state where exposed by the engine

The always-on mini panel only runs a lightweight point raycast; the
heavier 10×10m area scan only runs while the full HUD is toggled on.

## Install

Drop `FS25_whatAmILookingAt` into your FS25 mods folder like any other
mod. Works standalone; ImmersiveWeathering is optional but recommended
if you want something to point the inspector at.

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
