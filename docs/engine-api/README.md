# Engine API notes

Reverse-engineered reference notes for FS25 native functions/classes that either
aren't in `scriptBinding.xml` at all, or are listed there without enough detail
to actually use.

## Why this exists

`scriptBinding.xml` (bundled with the GE10 modding tools) reads like a checklist
an apprentice was told to fill in by hand, not documentation generated from the
real C++ source. Confirmed gaps: `TerrainDeformation`, `getTerrainNumOfLayers`,
`getTerrainLayerName`, `getTerrainLayerNumOfSubLayers` are all real, working,
callable natives that don't appear in it at all. Entries that ARE present are
often a single line with no behavior notes, no gotchas, no worked example.

Nothing here comes from decompiled C++ or official docs. It's reconstructed by
either:

1. reading real, working mod source (TerraFarm, LumberJack, GIANTS Editor
   scripts) and base-game Lua (`dataS/scripts/`) that calls the function
   successfully, or
2. calling it ourselves from WAILA/ImmersiveWeathering and checking what
   actually happened in-game.

Every page below says which of those two applies, and cites the exact file it
came from. Treat "confirmed via source, not yet run by us" as a solid lead, not
a guarantee - the real test is calling it and checking the result.

## Topics

- [CollisionFlag.md](CollisionFlag.md) - raycast filter bitmask
- [TerrainAttributes.md](TerrainAttributes.md) - reading ground material at a point
- [FoliageDensityMap.md](FoliageDensityMap.md) - deco vegetation (grass/bush/etc)
- [FSDensityMapUtil.md](FSDensityMapUtil.md) - clear/sow/field-check helpers
- [TerrainDeformation.md](TerrainDeformation.md) - terrain shape + ground texture paint
- [TreePlantManager.md](TreePlantManager.md) - tree placement
- [DensityMapModifier.md](DensityMapModifier.md) - low-level density map writes (unverified)
- [VehicleActionEvents.md](VehicleActionEvents.md) - the correct way to bind a key that only works in-vehicle
