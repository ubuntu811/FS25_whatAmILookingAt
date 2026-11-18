# Decompiling the base game (fs-utils)

**Status:** confirmed via our own testing (SmartMinimapAuto session, 2026-08-13)

`AI_DEV_GUIDE.md` §4 mentions this in one bullet; this page is the expanded
version, since a full session's worth of real use turned up enough gotchas
and payoff to be worth its own page.

## Why this beats scriptBinding.xml for base-game *Lua* classes

`scriptBinding.xml` only documents **native** (C++) functions exposed to
Lua. Most of the actual game logic - `FieldManager`, `Field`, `FieldState`,
`MapOverlayGenerator`, `MapHotspot` and every subclass, the `*Mission`
contract classes, `AIJobFieldWork` - is itself plain Lua, compiled to Luau
bytecode and shipped inside `dataS.gar`/`dataS2.gar`. None of that appears
in scriptBinding.xml at all, because it was never a native binding to begin
with. This is the same scripting layer mods themselves live in, not the
engine's C++ core - decompiling it reverses one step (Luau bytecode → Lua
source, like `luac`/`luadec` on any Lua project), not reverse-engineering
the engine binary.

## Setup

Tool lives at `~/my_mods/fs-utils`, not prebuilt:

```bash
cd ~/my_mods/fs-utils
cargo build --release -p fs-unpack -p fs-luau-decompile
```

**Gotcha:** this WSL environment didn't have `cargo` preinstalled. It's a
normal apt package, but installing it needs an interactive sudo password -
can't be done non-interactively from an AI-driven session. If the build
fails with `cargo: command not found`, ask the human to run
`sudo apt-get install -y cargo` in a terminal where they can type a
password, then retry the build.

Build takes a few minutes (pulls the `lantern` decompiler and its
dependencies from git). One-time cost per machine.

## Usage

```bash
# Unpack once - gives the real scripts/ tree as .l64 bytecode files with
# real paths/names, enough to find the right file by grep/find even before
# decompiling anything.
fs-unpack ~/fs25_bin/dataS.gar <out_dir>

# Decompile only the specific files you need - decompiling the whole
# archive is slow and unnecessary.
fs-luau-decompile <out_dir>/scripts/path/File.l64 output.lua -s
```

`dataS2.gar` also exists alongside `dataS.gar`, not yet explored.

## Keep the output, don't let it evaporate

Decompiled files land wherever you point the tool - if that's a session
scratchpad or `/tmp`, it's gone next session and every future question
about the same class re-pays the full unpack+decompile+read cost. Copy
anything worth keeping into `~/fs25_resources/dataS_decompiled/` (see
`AI_DEV_GUIDE.md` §1 for what that folder's for) instead of leaving it in
scratch space. Real example: this session alone pulled `Field.lua`,
`FieldManager.lua`, `FieldState.lua`, `MapHotspot.lua`,
`MapOverlayGenerator.lua`, `IngameMap.lua`, six `*Mission.lua` contract
classes, and the foliage system files - all now sitting there for the next
session to read directly instead of re-decompiling.

## What this found, as evidence it's worth the setup cost

Concrete gaps this closed in one session (all previously either guessed at
via a runtime "Discovery mode" log-dump scaffold, or not even attempted):

- `Field:getFieldState()` / `field:updateState()` give real per-field job
  state directly - no manual density-map sampling needed for something as
  simple as "does this field have weeds."
- `MapHotspot:setWorldPosition(x, z)` + `IngameMap:addMapHotspot()` handles
  all world-to-screen placement/rotation/zoom/clipping for map icons
  automatically - the same pipeline vehicle and mission icons use. Not
  discoverable from scriptBinding.xml at all, since `MapHotspot` is pure
  Lua.
- The `*Mission.isAvailableForField` static methods (`PlowMission`,
  `CultivateMission`, `WeedMission`, `SowMission`, `HarvestMission`,
  `FertilizeMission`) are the real, authoritative "does this field need X"
  eligibility logic the contract system itself uses - confirmed
  `PlowMission` and `CultivateMission`'s eligibility checks are byte-for-
  byte identical, meaning the base game genuinely does not disambiguate
  "needs plowing" from "needs cultivating" itself.
- Icons must read `self.scale` themselves in their own `render()` to track
  the map's zoom level (`IngameMap:drawHotspot` calls
  `hotspot:setScale(scale)` every frame, but that's inert unless the
  hotspot's own render code actually uses it) - a real bug this uncovered
  and fixed, not obvious from any documentation.

## References

- `~/my_mods/fs-utils/README.md` - full CLI usage for all tools in the kit,
  not just the two used here (`fs-shapes-unlock`, `fs-xml-format`, etc.)
- `~/my_mods/SmartMinimapAuto` - the mod session all of the above came from
