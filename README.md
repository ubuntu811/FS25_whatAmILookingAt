# FS25_whatAmILookingAt

Early developer build of an in-game world inspector for Farming Simulator 25.

## Controls

- `Left Shift + M`: toggle inspector HUD
- `Left Shift + J`: dump the currently inspected target to `log.txt` (only while HUD is enabled)

## Current inspection

- raycast target and node ID/name
- terrain material, field state and ground type
- foliage layers at the target
- grouped terrain and foliage statistics for a 10×10 m area
- vehicle/placeable node object where available
- tree/log/split-shape classification
- rigid-body type, split state, volume, mass and sleeping state where exposed by the engine

The HUD performs no raycasts or area scans while disabled.
