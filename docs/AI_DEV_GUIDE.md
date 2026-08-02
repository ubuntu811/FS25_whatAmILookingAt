# AI-assisted FS25 modding — dev environment guide

How this repo (and its companion [FS25_whatAmILookingAt](https://github.com/ubuntu811/FS25_whatAmILookingAt)) actually get built, tested, and debugged, for anyone — human or AI — starting from zero. Written from an actual working setup, not a hypothetical one. Prefer this over prose explanations elsewhere: every claim below is a command you can run.

## 1. The environment

- **Windows + Steam**: Farming Simulator 25 installed normally via Steam.
- **WSL2** (Ubuntu) on the same machine, with the Windows C: drive mounted at `/mnt/c`.
- **Two different folders, do not confuse them**:
  - Game **install** (read-only reference material): `/mnt/c/Program Files (x86)/Steam/steamapps/common/Farming Simulator 25/`
  - Game **user data** (mods, saves, logs, settings): `/mnt/c/Users/<you>/Documents/My Games/FarmingSimulator2025/` — usually symlinked to something like `~/fs25/` inside WSL for convenience.
- **Claude Code** runs inside WSL, editing files under `~/my_mods/<ModName>/` (a git repo per mod), building, and deploying straight into `~/fs25/mods/<ModName>/` as a loose unzipped folder for FS25's hot-reload.

Finding the install path the first time: don't blind-`find` all of `/mnt/c` (WSL↔Windows crossing is slow, real timeouts happen). Target a known filename instead:

```bash
find / -iname "mission00.xsd" 2>/dev/null
```

## 2. Toolchain

FS25's scripting engine is **Lua 5.1**. Ubuntu/WSL usually only has `lua5.4` preinstalled — its `luac5.4 -p` will happily accept Lua 5.2+-only syntax (`goto`/labels) that the real game engine rejects at load time with a cryptic in-game compiler error. Install the right version:

```bash
sudo apt-get install -y lua5.1
```

Then point build scripts at `luac5.1 -p`, not `luac5.4`.

## 3. Repo layout convention

Every mod repo has:

```
modDesc.xml
scripts/
l10n/
icon*.dds
build/
  build.sh     # compile-check + XML-validate + zip
  deploy.sh    # unzip build.sh's output into ~/fs25/mods/<ModName>/
```

`build.sh` (this repo's, condensed):

```bash
find . -name '*.lua' -print0 | xargs -0 -n1 luac5.1 -p
find . -name '*.xml' -print0 | xargs -0 -n1 python3 -c \
  'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])'
# ...then copies scripts/, l10n/, modDesc.xml, icon into a staging dir and zips it
```

The XML check exists because a single stray/duplicate closing tag in `modDesc.xml` will pass every Lua check and still hard-fail the game load (`XML_ERROR_MISMATCHED_ELEMENT`) — this bit us for real, once.

`deploy.sh` runs `build.sh` if needed, then `rm -rf` + `unzip` the zip straight into `~/fs25/mods/<ModName>/` as a loose folder (not a zip) so FS25 hot-reloads it without a repackage step every time.

**Workflow rule**: after every code edit, run both — don't wait to be asked. In-game testing is the only real verification; local syntax checks only catch a subset of what can go wrong.

## 4. Authoritative references — check these before guessing

The game ships real, unpacked reference material. Use it instead of inferring behavior from trial-and-error or decompiled snippets:

- **XML schemas** (map.xml, modDesc.xml, vehicle XML, etc.): `<install>/shared/xml/schema/*.xsd` — e.g. `mission00.xsd` is the authoritative map.xml structure.
- **Every Lua-callable engine function**, with real params/types: `<install>/sdk/debugger/scriptBinding.xml`.
- **Real, currently-installed reference mods**: when unsure whether a pattern is genuinely supported, grep an existing working mod's actual source rather than guessing (e.g. `FS25_AdditionalContracts`'s own `InGameMenu.onMenuOpened` hook confirmed the real settings-page injection point after a first guess, `BaseMission.loadMapFinished`, silently rendered nothing).

## 5. The debug-loop pattern

WAILA (`FS25_whatAmILookingAt`) exists specifically to make "what field do I actually need to check" answerable at runtime instead of by guessing:

1. Add a temporary field dump to `WailaDebugDump.lua` bound to a debug key (e.g. `Shift+J`).
2. Reproduce the in-game situation.
3. Read the real log output — real field names, real values, real nesting — instead of assuming from decompiled Lua or forum posts.
4. Wire the confirmed-real field into actual mod logic; leave (or remove) the dump.

This is how `spec_sowingMachine.isWorking` was found as the real "is this seeder actively working" signal, after three wrong guesses (`getIsTurnedOn()`, `getIsLowered()`, the towing vehicle's engine state) that were each individually plausible and each individually wrong.

**Step 3 in practice**: the game writes its live log straight to `~/fs25/log.txt` (real path, not a guess — confirmed by grepping it all session). `print()`/`debugPrint()` calls from any loaded mod land there in real time while the game runs, so a `grep`/`tail` from WSL reads what just happened in-game without needing to alt-tab or touch the game's own log viewer:

```bash
grep "\[TestRig\]" ~/fs25/log.txt | tail -50      # everything a specific tagged debug print logged
tail -f ~/fs25/log.txt                            # follow live while reproducing something in-game
```

No special access, no in-game console needed — it's a plain text file the whole time, sitting on the Windows-visible filesystem like everything else under `~/fs25/`.

## 6. Concrete gotchas hit building this mod pair

One-liners, cause → fix, most expensive first:

- **`Utils.appendedFunction` doesn't forward return values.** Hooking `SowingMachine.processSowingMachineArea` this way broke real gameplay (`WorkArea.lua:278: attempt to compare number < nil`) because the engine's own update loop depends on that function's return value. Fix: don't hook functions whose return value the engine consumes; hook a side-effect-only function instead (`WheelDestruction.update` here).
- **`category="ONFOOT"`/`"VEHICLE"` on a `modDesc.xml` `<action>`** silently deactivates that keybind by context at the engine level, regardless of how carefully you manage registration in Lua. Omit the attribute if you want manual control.
- **Lua 5.1 vs 5.4** — see §2. A build that passes local syntax checks can still fail to load in-game.
- **`getRootVehicle()` on an arbitrary hit object** resolves all the way up to the root (e.g. the towing tractor) even when the object itself is already the vehicle you care about. Check `object.isVehicle`/`object:isa(Vehicle)` first.
- **Collision-mask raycasts that include `"VEHICLE"`** and fire from at/near the player's own vehicle will always hit that vehicle first, silently breaking every check downstream. Easy to add for a plausible reason (exclude structures) and not notice the regression until "it just stopped working."
- **`<mapping name=".." layerName=".." state="..">` in map.xml is not optional.** `applyDecoFoliage`/`getIsDecoLayerDefined` only accept names with an explicit `<mapping>` entry — a raw, genuinely-declared `<decoFoliage layerName="...">` name alone does **not** work. Confirmed by live A/B log testing: 9 "obviously real" raw layer names all returned `false`; 4 newly-added custom `<mapping>` entries all returned `true`.
- **`addFoliageTypeFromXML`** (scriptBinding.xml, category `Foliage`) registers a brand-new decorative foliage layer at runtime, independent of what a map declares — likely the actual primitive behind mods like `FS25_allTheFoliage`. It is **not** connected to the fruit-type/growth system (e.g. real "meadow" growth stages) — purely decorative, same tier as any `decoFoliage` layer.
- **A community UI helper class (`UIHelper`) is not a base-game class.** Two independently-installed mods can each vendor their own copy of the same global table name; guard vendored copies with `if UIHelper == nil then ... end` so load order doesn't cause one to silently clobber the other.
- **Settings-page injection must happen from `InGameMenu.onMenuOpened`**, not `BaseMission.loadMapFinished` — the latter fires before the settings page's GUI elements reliably exist.

## 7. Where to actually start, from zero

1. Install FS25 via Steam, run it once so user-data folders exist.
2. Set up WSL2 + a distro, confirm `/mnt/c` is mounted.
3. `sudo apt-get install -y lua5.1 unzip zip python3`.
4. Find the install path (§1), skim `shared/xml/schema/mission00.xsd` and `sdk/debugger/scriptBinding.xml` once, just to know they exist.
5. Copy this repo's `build/build.sh` + `build/deploy.sh` pattern for a new mod skeleton (`modDesc.xml`, `scripts/`, `l10n/`).
6. Build a tiny debug-dump keybind first, before writing real mechanics — it pays for itself immediately the first time an assumption about a field name turns out wrong.
