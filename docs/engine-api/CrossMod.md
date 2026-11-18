# Cross-mod communication: globals, events, and what's actually shared

**Status:** confirmed live, twice, the hard way - not something either
`scriptBinding.xml` or `modDesc.xsd` documents at all.

Two different questions, both covered here: how do you expose a queryable
API to another mod, and how do you fire/catch a one-shot event between
mods. The answer to both turns out to hinge on the same underlying fact:
FS25 mods do **not** share one flat global namespace the way most modding
guides imply.

## What's actually shared

- `g_currentMission` itself, and anything already hanging off it before your
  mod's code runs (`g_currentMission.vehicleSystem`, `.placeableSystem`,
  `.hud`, ...) - pre-existing engine object instances, not something any
  one mod declared.
- Base-game **classes** a mod can patch/extend - `SavegameController`,
  `BaseMission`, `MessageType`, `Vehicle`, etc. - via the standard
  `Utils.appendedFunction`/`Utils.overwrittenFunction` pattern. Works
  cross-mod because the class table is base-game-declared and pre-exists
  every mod's load, not because mod-to-mod visibility exists in general.
  Confirmed working repeatedly this session (`SavegameController.
  onSaveComplete`, `BaseMission.loadMap`) - but note both of *those*
  patches were a mod extending a **base-game** class, not one mod reading
  another mod's own declared table.
- `g_messageCenter` - a genuinely shared pub/sub bus (confirmed via
  decompiled `MessageCenter.lua`: `subscribe`/`publish` just key off
  whatever value you pass as `messageType`, zero validation against the
  `MessageType` enum, so any mod can mint its own key with
  `nextMessageTypeId()`). The *bus* is shared; the *key itself* is not -
  see below, this is the one gotcha that catches people out.

## What's NOT shared

Anything a mod declares itself at file scope - `SomeClass = {}`, a bare
module table, a class-level constant like `SomeClass.SOME_EVENT_ID =
nextMessageTypeId()` - stays invisible to every other mod's script, even
after that mod has fully loaded and successfully used the value itself.

Confirmed twice, independently:

1. `WailaHud`/`ImmersiveWeathering` HUD-docking coordinates - a bare
   `WailaHud` global read as `nil` from IW's side, despite WAILA having
   already run. Fixed by publishing the coordinates onto
   `g_currentMission` instead (`g_currentMission.wailaHudMiniLeft` etc.)
2. `Waila`/`WailaFieldIndex` (this mod's own field-index facade) - built
   as bare globals, `SmartMinimapAuto` read them as `nil` despite the log
   clearly showing WAILA's own `loadMap()` had *already completed*
   (including successfully calling `WailaFieldIndex.new()` itself) by the
   time `SmartMinimapAuto`'s check ran. Not a load-order race - the class
   simply isn't visible across the mod boundary, full stop.

## Exposing a queryable API to other mods

Don't design it as a bare global. Publish it as a field on
`g_currentMission` instead, set once your own `loadMap()` has real data to
offer:

```lua
-- WAILA's own FS25WhatAmILookingAt:loadMap()
self.fieldIndex = WailaFieldIndex.new()
self.fieldIndex:start()
Waila.indices.field = self.fieldIndex

-- The actual integration point - NOT the bare `Waila` global above,
-- which is invisible outside this mod's own script.
g_currentMission.waila = Waila
```

Another mod reads it back through `g_currentMission`, never your global by
name:

```lua
-- SmartMinimapAuto.lua
local entries = g_currentMission.waila.getAll("field")
```

## Firing and catching an event between mods

`g_messageCenter` is real, shared, and needs nothing built from scratch -
any mod can mint its own event key and use the exact same bus the base
game uses internally for e.g. `MessageType.FINISHED_GROWTH_PERIOD`:

```lua
-- Producing mod: mint a key once, anywhere at file scope
MyThing.SOMETHING_HAPPENED = nextMessageTypeId()

-- ...later, whenever the real event occurs
g_messageCenter:publish(MyThing.SOMETHING_HAPPENED, someArg, anotherArg)
```

The catch: `MyThing.SOMETHING_HAPPENED` is just as invisible cross-mod as
`MyThing` itself would be - a consuming mod can't reference it by name.
Publish the key the same way as any other cross-mod value, through
`g_currentMission`:

```lua
-- Waila.lua - re-exposing the key alongside the rest of the API
Waila.events = {
    vehicleLeftField = WailaFieldIndex.VEHICLE_LEFT_FIELD,
}
```

```lua
-- SmartMinimapAuto.lua - subscribing from the consuming mod
g_messageCenter:subscribe(g_currentMission.waila.events.vehicleLeftField, self.onVehicleLeftField, self)
```

`g_messageCenter:subscribe(messageType, callback, callbackTarget)` doesn't
care whether `messageType` is a base-game enum value or a number some mod
generated at runtime - it's used purely as a table key
(`self.subscribers[messageType]`), confirmed via the decompiled source. No
special registration step, no shared enum file to edit.

## Load order still isn't guaranteed - check lazily, not once

`modDesc.xml`'s `<dependencies>` element only gates whether a mod is
allowed to be *enabled* at all without the dependency installed - it does
**not** enforce that the dependency's `loadMap()` runs before the dependent
mod's own (confirmed via `ModManager.lua`: dependencies are stored as
metadata, no load-order enforcement found anywhere). A consuming mod
checking once inside its own `loadMap()` and giving up permanently if the
producer isn't ready yet is fragile for exactly that reason - check lazily
instead, on every `update()` tick, until it succeeds once:

```lua
function SmartMinimapAuto:update(dt)
    if not self.subscribedToEvents and g_currentMission ~= nil and g_currentMission.waila ~= nil then
        g_messageCenter:subscribe(g_currentMission.waila.events.vehicleLeftField, self.onVehicleLeftField, self)
        self.subscribedToEvents = true
    end
    ...
end
```

Every read of the shared API (`rebuildAllHotspots` etc.) should also
nil-check `g_currentMission.waila` defensively on its own, not assume the
lazy subscribe above has already run - the producing mod being absent
entirely (dependency not actually installed despite `modDesc.xml`) should
degrade to doing nothing, not crash.

## References

- `Waila.lua`, `WailaFieldIndex.lua`, `FS25WhatAmILookingAt.lua` (this mod)
  and `SmartMinimapAuto.lua` (the actual live before/after)
- `WailaHud.lua` (`g_currentMission.wailaHudMiniLeft`/`Right`/`Bottom`) -
  the first time this same lesson was learned, for HUD-panel docking
  coordinates rather than an API surface
- decompiled `dataS.gar/scripts/MessageCenter.lua` (`subscribe`/`publish`
  genericness) and `scripts/misc/ModManager.lua` (`<dependencies>` stored,
  not enforced)
